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

/// A compact 8-byte duration representation.
///
/// A shorter representation of `Swift.Duration`. Use `NetworkDuration` to represent times
/// relative to the system boot-up time or to the UNIX epoch. Although `NetworkDuration`
/// can represent durations that span several years, its purpose is limited to durations
/// relevant to networking protocols, which are usually under one hour.
#if !NETWORK_EMBEDDED
@_spi(Essentials)
@available(Network 0.1.0, *)
#endif
public struct NetworkDuration: DurationProtocol, Hashable, Equatable, CustomStringConvertible {
    public private(set) var nanoseconds: Int64

    // These are computed properties wrapping literals, and deliberately not
    // `static let`s. A `static let` becomes a lazily initialised global, so every
    // read carries a one-time-init guard, whereas a computed property returning a
    // literal constant-folds at each use site. Deriving them from
    // `System.Time.NSEC_PER_USEC` and friends would not fold either, because those
    // are themselves `static let`s.
    private static var nanosecondsPerMicrosecond: Int64 { 1_000 }
    private static var nanosecondsPerMillisecond: Int64 { 1_000_000 }
    private static var nanosecondsPerSecond: Int64 { 1_000_000_000 }
    private static var nanosecondsPerMinute: Int64 { 60 * nanosecondsPerSecond }
    private static var nanosecondsPerHour: Int64 { 60 * nanosecondsPerMinute }
    private static var nanosecondsPerDay: Int64 { 24 * nanosecondsPerHour }

    init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static var zero: NetworkDuration {
        NetworkDuration(nanoseconds: 0)
    }

    public static func + (lhs: NetworkDuration, rhs: NetworkDuration) -> NetworkDuration {
        NetworkDuration(nanoseconds: lhs.nanoseconds + rhs.nanoseconds)
    }

    public static func - (lhs: NetworkDuration, rhs: NetworkDuration) -> NetworkDuration {
        NetworkDuration(nanoseconds: lhs.nanoseconds - rhs.nanoseconds)
    }

    public static func += (lhs: inout NetworkDuration, rhs: NetworkDuration) {
        lhs.nanoseconds += rhs.nanoseconds
    }

    public static func -= (lhs: inout NetworkDuration, rhs: NetworkDuration) {
        lhs.nanoseconds -= rhs.nanoseconds
    }

    public static func / (lhs: NetworkDuration, rhs: Int) -> NetworkDuration {
        NetworkDuration(nanoseconds: lhs.nanoseconds / Int64(rhs))
    }

    public static func * (lhs: NetworkDuration, rhs: Int) -> NetworkDuration {
        NetworkDuration(nanoseconds: lhs.nanoseconds * Int64(rhs))
    }

    static func * (lhs: Double, rhs: NetworkDuration) -> NetworkDuration {
        NetworkDuration(nanoseconds: Int64(Double(rhs.nanoseconds) * lhs))
    }

    static func * (lhs: NetworkDuration, rhs: Double) -> NetworkDuration {
        NetworkDuration(nanoseconds: Int64(Double(lhs.nanoseconds) * rhs))
    }

    static func >> (lhs: NetworkDuration, rhs: Int) -> NetworkDuration {
        NetworkDuration(nanoseconds: lhs.nanoseconds >> rhs)
    }

    static func << (lhs: NetworkDuration, rhs: Int) -> NetworkDuration {
        NetworkDuration(nanoseconds: lhs.nanoseconds << rhs)
    }

    public static func / (lhs: NetworkDuration, rhs: NetworkDuration) -> Double {
        Double(lhs.nanoseconds) / Double(rhs.nanoseconds)
    }

    public static func < (lhs: NetworkDuration, rhs: NetworkDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public static func <= (lhs: NetworkDuration, rhs: NetworkDuration) -> Bool {
        lhs.nanoseconds <= rhs.nanoseconds
    }

    public static func > (lhs: NetworkDuration, rhs: NetworkDuration) -> Bool {
        lhs.nanoseconds > rhs.nanoseconds
    }

    public static func >= (lhs: NetworkDuration, rhs: NetworkDuration) -> Bool {
        lhs.nanoseconds >= rhs.nanoseconds
    }

    public static func == (lhs: NetworkDuration, rhs: NetworkDuration) -> Bool {
        lhs.nanoseconds == rhs.nanoseconds
    }

    public static func nanoseconds<T>(_ nanoseconds: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(nanoseconds))
    }

    public static func microseconds<T>(_ microseconds: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(microseconds) * NetworkDuration.nanosecondsPerMicrosecond)
    }

    public static func microseconds(_ microseconds: Double) -> NetworkDuration {
        NetworkDuration(nanoseconds: Int64(microseconds * Double(NetworkDuration.nanosecondsPerMicrosecond)))
    }

    public static func milliseconds<T>(_ milliseconds: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(milliseconds) * NetworkDuration.nanosecondsPerMillisecond)
    }

    public static func milliseconds(_ milliseconds: Double) -> NetworkDuration {
        NetworkDuration(nanoseconds: Int64(milliseconds * Double(NetworkDuration.nanosecondsPerMillisecond)))
    }

    public static func seconds<T>(_ seconds: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(seconds) * NetworkDuration.nanosecondsPerSecond)
    }

    public static func minutes<T>(_ minutes: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(minutes) * NetworkDuration.nanosecondsPerMinute)
    }

    public static func hours<T>(_ hours: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(hours) * NetworkDuration.nanosecondsPerHour)
    }

    public static func days<T>(_ days: T) -> NetworkDuration where T: BinaryInteger {
        NetworkDuration(nanoseconds: Int64(days) * NetworkDuration.nanosecondsPerDay)
    }

    // Render a duration of a minute or more as a whole coarse unit plus, when
    // non-zero, a whole sub-unit: "2 h", "1 h 30 min", "1 min 15 s".
    private func coarseDescription() -> String? {
        let units: [3 of (size: Int64, name: String, subSize: Int64, subName: String)] = [
            (NetworkDuration.nanosecondsPerDay, "d", NetworkDuration.nanosecondsPerHour, "h"),
            (NetworkDuration.nanosecondsPerHour, "h", NetworkDuration.nanosecondsPerMinute, "min"),
            (NetworkDuration.nanosecondsPerMinute, "min", NetworkDuration.nanosecondsPerSecond, "s"),
        ]
        for index in units.indices {
            let unit = units[index]
            let value = nanoseconds / unit.size
            guard value != 0 else { continue }
            let sub = abs((nanoseconds % unit.size) / unit.subSize)
            return sub == 0
                ? "\(value) \(unit.name)"
                : "\(value) \(unit.name) \(sub) \(unit.subName)"
        }
        return nil
    }

    public var description: String {
        coarseDescription() ?? fineDescription
    }

    // Description using no unit coarser than seconds.
    fileprivate var fineDescription: String {
        if self.seconds != 0 {
            return NetworkDuration.fractionalDescription(
                unit: "s",
                value: self.seconds,
                thousandth: self.milliseconds
            )
        } else if self.milliseconds != 0 {
            return NetworkDuration.fractionalDescription(
                unit: "ms",
                value: self.milliseconds,
                thousandth: self.microseconds
            )
        } else if self.microseconds != 0 {
            return NetworkDuration.fractionalDescription(
                unit: "μs",
                value: self.microseconds,
                thousandth: self.nanoseconds
            )
        } else {
            return "\(nanoseconds) ns"
        }
    }

    private static func fractionalDescription(unit: String, value: Int64, thousandth: Int64) -> String {
        let fractional = abs(thousandth % 1000)
        let hundreds = fractional / 100
        let tens = (fractional / 10) % 10
        let ones = fractional % 10
        if ones != 0 {
            return "\(value).\(hundreds)\(tens)\(ones) \(unit)"
        } else if tens != 0 {
            return "\(value).\(hundreds)\(tens) \(unit)"
        } else {
            return "\(value).\(hundreds) \(unit)"
        }
    }

    public var seconds: Int64 {
        nanoseconds / NetworkDuration.nanosecondsPerSecond
    }

    public var milliseconds: Int64 {
        nanoseconds / NetworkDuration.nanosecondsPerMillisecond
    }

    // The number of whole milliseconds in this duration, rounded up.
    // Zero and negative durations clamp to zero.
    public var roundedUpMilliseconds: Int64 {
        guard nanoseconds > 0 else {
            return 0
        }
        return (nanoseconds + NetworkDuration.nanosecondsPerMillisecond - 1)
            / NetworkDuration.nanosecondsPerMillisecond
    }

    public var microseconds: Int64 {
        nanoseconds / NetworkDuration.nanosecondsPerMicrosecond
    }

    // Returns the number of microseconds round to the nearest integer.
    public var roundedMicroseconds: Self {
        if nanoseconds == 0 {
            return self
        }
        let halfway = (NetworkDuration.nanosecondsPerMicrosecond / 2) * self.nanoseconds.signum()
        return .microseconds((self.nanoseconds + halfway) / NetworkDuration.nanosecondsPerMicrosecond)
    }
}

/// A continuous clock with a compact representation that tests can advance manually.
///
/// Mimics `Swift.ContinuousClock`, with two differences:
/// 1. It uses `NetworkDuration` internally so its size is 8 bytes.
/// 2. Tests can replace the OS clock with one they advance by hand,
///    which makes time-dependent behaviour deterministic.
#if !NETWORK_EMBEDDED
@_spi(Essentials)
// Availability due to `SwiftNetwork`'s `System.Time` (used by `Instant.now`)
@available(Network 0.1.0, *)
#endif
public struct NetworkClock: Clock {
    public struct Instant: InstantProtocol, CustomStringConvertible {
        var time: NetworkDuration

        #if NETWORK_INTERNAL_TESTS
        // Backing storage for the manual clock used by tests.
        //
        // This is a `static let` box rather than a `static var` on purpose.
        // Reading a mutable static emits a `swift_beginAccess` call for the
        // dynamic exclusivity check. A `let` does not.
        private final class ManualTime: @unchecked Sendable {
            var continuous: Instant = .zero
            var absolute: Instant = .zero
        }
        private static let manualTime = ManualTime()
        #endif

        internal static func useSystemTime() {
            #if NETWORK_INTERNAL_TESTS
            manualTime.continuous = .zero
            manualTime.absolute = .zero
            #endif
        }

        internal static func useManualTime(
            _ continuous: Instant,
            absolute: Instant? = nil
        ) {
            #if NETWORK_INTERNAL_TESTS
            let absolute = absolute ?? continuous
            precondition(continuous > .zero, "manual time must be greater than zero")
            precondition(absolute > .zero, "manual time must be greater than zero")
            manualTime.continuous = continuous
            manualTime.absolute = absolute
            #else
            fatalError("The manual clock requires building with -DNETWORK_INTERNAL_TESTS")
            #endif
        }

        internal static func advanceManualTime(by duration: NetworkDuration) {
            #if NETWORK_INTERNAL_TESTS
            precondition(duration >= .zero, "manual time must not go backwards")
            precondition(
                manualTime.continuous > .zero,
                "advanceManualTime(by:) requires useManualTime() first"
            )
            manualTime.continuous = manualTime.continuous.advanced(by: duration)
            manualTime.absolute = manualTime.absolute.advanced(by: duration)
            #else
            fatalError("The manual clock requires building with -DNETWORK_INTERNAL_TESTS")
            #endif
        }

        public func advanced(by duration: NetworkDuration) -> Self {
            NetworkClock.Instant(self.time + duration)
        }

        public func duration(to other: Self) -> NetworkDuration {
            other.time - self.time
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.time < rhs.time
        }

        public static func + (lhs: Self, rhs: NetworkDuration) -> Self {
            NetworkClock.Instant(lhs.time + rhs)
        }

        public static func - (lhs: Self, rhs: NetworkDuration) -> Self {
            NetworkClock.Instant(lhs.time - rhs)
        }

        public static func - (lhs: Self, rhs: NetworkClock.Instant) -> NetworkDuration {
            lhs.time - rhs.time
        }

        init(milliseconds: Int64) {
            time = .milliseconds(milliseconds)
        }

        init(microseconds: Int64) {
            time = .microseconds(microseconds)
        }

        init(nanoseconds: Int64) {
            time = .nanoseconds(nanoseconds)
        }

        init(_ time: NetworkDuration) {
            self.time = time
        }

        public static var now: Instant {
            #if NETWORK_INTERNAL_TESTS
            let manual = manualTime.continuous
            if _slowPath(manual != .zero) {
                return manual
            }
            #endif
            return Instant(microseconds: Int64(System.Time.now()))
        }

        public static var nowAbsolute: Instant {
            #if NETWORK_INTERNAL_TESTS
            let manual = manualTime.absolute
            if _slowPath(manual != .zero) {
                return manual
            }
            #endif
            return Instant(nanoseconds: Int64(System.Time.nowAbsoluteNanoseconds()))
        }

        public static var zero: Instant {
            Instant(microseconds: 0)
        }

        public static var maximum: Instant {
            Instant(nanoseconds: Int64.max)
        }

        public var description: String {
            // A NetworkClock.Instant is a time *since* an epoch rather
            // than an elapsed span, so rendering it with
            // coarse units makes it read like a duration.
            time.fineDescription
        }
    }

    public var now: Instant {
        Instant.now
    }

    public var minimumResolution: NetworkDuration {
        .nanoseconds(1)
    }
    #if !NETWORK_DRIVERKIT && !NETWORK_EMBEDDED  // no Swift Concurrency
    public func sleep(until deadline: Instant, tolerance: NetworkDuration?) async throws {
        fatalError("not implemented")
    }
    #endif
}

#if NETWORK_DRIVERKIT || NETWORK_EMBEDDED  // need Clock protocol from Swift _Concurrency
protocol Clock<Duration>: Sendable {
    associatedtype Duration where Self.Duration == Self.Instant.Duration
    associatedtype Instant: InstantProtocol
}
#endif
