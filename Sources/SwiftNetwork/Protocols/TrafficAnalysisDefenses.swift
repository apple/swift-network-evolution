//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !NETWORK_EMBEDDED

/// Padding and chaff against traffic analysis. Off by default; only Swift QUIC implements them.
@_spi(Essentials)
@available(Network 0.1.0, *)
public struct TrafficAnalysisDefenses: Sendable, Equatable {
    /// Sizes are capped at what the path can carry.
    public enum Padding: Sendable, Equatable {
        case fixedSize(Int)
        case roundUp(toMultipleOf: Int)
        case randomSize(ClosedRange<Int>)

        /// Turns sizes below one byte into no padding, and starts a random range at one byte.
        var normalized: Padding? {
            switch self {
            case .fixedSize(let size):
                return size > 0 ? self : nil
            case .roundUp(let multiple):
                return multiple > 0 ? self : nil
            case .randomSize(let range):
                guard range.upperBound > 0 else { return nil }
                return .randomSize(max(range.lowerBound, 1)...range.upperBound)
            }
        }

        /// Never less than `length`.
        func paddedLength(for length: Int) -> Int {
            switch self {
            case .fixedSize(let size):
                return max(size, length)
            case .roundUp(let multiple):
                // Avoids dividing by a zero that was not normalized.
                guard multiple > 0 else { return length }
                let remainder = length % multiple
                return remainder == 0 ? length : length + (multiple - remainder)
            case .randomSize(let range):
                var generator = SystemRandomNumberGenerator()
                return max(Int.random(in: range, using: &generator), length)
            }
        }
    }

    /// Packets sent while the connection is idle.
    public struct Chaff: Sendable, Equatable {
        /// Idle time before each chaff packet. Serialized in whole milliseconds.
        public let interval: NetworkDuration
        /// Random amount added to or taken from each interval. Serialized in whole milliseconds.
        public let jitter: NetworkDuration
        /// Chaff stops after this many in a row, once the total packets sent is a multiple of
        /// `roundTotalPacketsTo`.
        public let maximumConsecutiveChaff: Int
        public let roundTotalPacketsTo: Int

        /// Clamps the interval to between 1 ms to 1 hour, the jitter to below the interval, and the counts to at least 0 and 1.
        public init(
            interval: NetworkDuration,
            jitter: NetworkDuration = .zero,
            maximumConsecutiveChaff: Int,
            roundTotalPacketsTo: Int = 1
        ) {
            let interval = min(max(interval, .milliseconds(1)), .hours(1))
            self.interval = interval
            self.jitter = min(max(jitter, .zero), interval - .milliseconds(1))
            self.maximumConsecutiveChaff = max(maximumConsecutiveChaff, 0)
            self.roundTotalPacketsTo = max(roundTotalPacketsTo, 1)
        }

        /// The interval with random jitter applied. At least 1 ms.
        var nextDelay: NetworkDuration {
            guard jitter > .zero else { return interval }
            var generator = SystemRandomNumberGenerator()
            let jitter = jitter.nanoseconds
            return interval + .nanoseconds(Int64.random(in: -jitter...jitter, using: &generator))
        }

        /// Also stops `roundTotalPacketsTo` past the maximum, in case the total skips every multiple.
        func shouldStop(afterConsecutive consecutive: Int, totalPacketsSent: Int) -> Bool {
            guard consecutive >= maximumConsecutiveChaff else { return false }
            return totalPacketsSent % roundTotalPacketsTo == 0
                || consecutive >= maximumConsecutiveChaff + roundTotalPacketsTo
        }
    }

    public var padding: Padding? {
        didSet { padding = padding?.normalized }
    }
    public var chaff: Chaff?

    public init(padding: Padding? = nil, chaff: Chaff? = nil) {
        self.padding = padding?.normalized
        self.chaff = chaff
    }

    public var isEnabled: Bool {
        padding != nil || chaff != nil
    }
}

// MARK: - Serialized form

@available(Network 0.1.0, *)
extension TrafficAnalysisDefenses {
    static var serializedLength: Int { 18 }

    /// The form the QUIC options carry the defenses in:
    ///
    ///     UInt8   padding mode: 0 none, 1 fixed size, 2 round up, 3 random range
    ///     UInt16  size, multiple, or range start
    ///     UInt16  range end
    ///     UInt8   chaff present: 0 or 1
    ///     UInt32  chaff interval, milliseconds
    ///     UInt32  chaff jitter, milliseconds
    ///     UInt16  chaff maximum consecutive
    ///     UInt16  chaff round total packets to
    ///
    /// Fields that do not apply are 0; values too large for a field are clamped.
    var serializedBytes: [UInt8] {
        let (mode, first, second): (UInt8, UInt16, UInt16) =
            switch padding {
            case .none: (0, 0, 0)
            case .fixedSize(let size): (1, UInt16(clamping: size), 0)
            case .roundUp(let multiple): (2, UInt16(clamping: multiple), 0)
            case .randomSize(let range): (3, UInt16(clamping: range.lowerBound), UInt16(clamping: range.upperBound))
            }
        return Serializer.serialize { write in
            write.uint8(mode)
            write.uint16(first)
            write.uint16(second)
            write.uint8(chaff == nil ? 0 : 1)
            write.uint32(UInt32(clamping: chaff?.interval.milliseconds ?? 0))
            write.uint32(UInt32(clamping: chaff?.jitter.milliseconds ?? 0))
            write.uint16(UInt16(clamping: chaff?.maximumConsecutiveChaff ?? 0))
            write.uint16(UInt16(clamping: chaff?.roundTotalPacketsTo ?? 0))
        }
    }

    /// An unknown padding mode reads as no padding; bytes that do not parse read as no defenses.
    init(serializedBytes: [UInt8]) {
        var mode: UInt8 = 0
        var first: UInt16 = 0
        var second: UInt16 = 0
        var chaffPresent: UInt8 = 0
        var intervalMilliseconds: UInt32 = 0
        var jitterMilliseconds: UInt32 = 0
        var maximumConsecutiveChaff: UInt16 = 0
        var roundTotalPacketsTo: UInt16 = 0
        let result = Deserializer.deserialize(serializedBytes.span) { read throws(DeserializationError) in
            try read.uint8(&mode)
            try read.uint16(&first)
            try read.uint16(&second)
            try read.uint8(&chaffPresent)
            try read.uint32(&intervalMilliseconds)
            try read.uint32(&jitterMilliseconds)
            try read.uint16(&maximumConsecutiveChaff)
            try read.uint16(&roundTotalPacketsTo)
        }
        guard result.isValid else {
            self.init()
            return
        }

        let padding: Padding?
        switch mode {
        case 1:
            padding = .fixedSize(Int(first))
        case 2:
            padding = .roundUp(toMultipleOf: Int(first))
        case 3:
            padding = .randomSize(Int(first)...max(Int(first), Int(second)))
        default:
            padding = nil
        }
        self.init(
            padding: padding,
            chaff: chaffPresent == 0
                ? nil
                : Chaff(
                    interval: .milliseconds(intervalMilliseconds),
                    jitter: .milliseconds(jitterMilliseconds),
                    maximumConsecutiveChaff: Int(maximumConsecutiveChaff),
                    roundTotalPacketsTo: Int(roundTotalPacketsTo)
                )
        )
    }
}

#endif
