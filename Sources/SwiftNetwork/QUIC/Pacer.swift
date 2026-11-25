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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct Pacer: ~Copyable {
    var packetSentTime: NetworkClock.Instant = .zero  // in nanoseconds and in absolute time, when we last sent a packet
    var startupRate: UInt64 = 0  // pacing rate during startup (includes reset, after idle etc)
    var rate: UInt64 = 0
    var startUpBurstSize: UInt32 = 0
    var burstSize: UInt32 = 0
    var currentSize: UInt32 = 0
    let enabled: Bool

    // The interval a burst of `burstLength` bytes takes at the current rate. A rate of zero shouldn't
    // happen: `rateWasZero` reports it, for the caller to log with what it knows about the path.
    private func getPacketInterval(burstLength: UInt32, rateWasZero: inout Bool) -> NetworkDuration {
        guard rate > 0 else {
            rateWasZero = true
            return Constants.maxBurstIntervalKernelPacing
        }
        let interval = UInt64(burstLength) * System.Time.NSEC_PER_SEC / rate
        let intervalConverted = NetworkClock.Instant(nanoseconds: Int64(interval))
        if intervalConverted.time.nanoseconds > Constants.maxBurstIntervalKernelPacing.nanoseconds {
            return Constants.maxBurstIntervalKernelPacing
        }
        return intervalConverted.time
    }

    /// Works out when a packet should be sent. Returns `true` if the pacing rate was zero, which
    /// shouldn't happen; the caller logs it.
    @discardableResult
    mutating func getSendTime(
        now continuousTime: NetworkClock.Instant,
        nowAbsolute absoluteTime: NetworkClock.Instant,
        packetLength: UInt16,
        sendTimeAbsolute: inout NetworkClock.Instant,
        sendTimeContinuous: inout NetworkClock.Instant
    ) -> Bool {
        var rateWasZero = false
        if packetSentTime == .zero {
            packetSentTime = absoluteTime
            currentSize = UInt32(packetLength)
        } else {
            if currentSize >= burstSize {
                // Increment sent time by the pacing interval and
                // reset size to the curent burst's len
                let pacingInterval = getPacketInterval(burstLength: currentSize, rateWasZero: &rateWasZero)
                packetSentTime = packetSentTime + pacingInterval
                currentSize = UInt32(packetLength)
                if absoluteTime > packetSentTime {
                    // If current time is bigger, then application
                    // has already paced the packet. Also, we can't
                    // set sent time in the past.
                    packetSentTime = absoluteTime
                }
            } else {
                currentSize += UInt32(packetLength)
            }
        }
        sendTimeAbsolute = packetSentTime
        sendTimeContinuous = packetSentTime + (continuousTime.time - absoluteTime.time)
        return rateWasZero
    }

    // Packet rate determines the outgoing rate and
    // is expressed in bytes per second. Caller can
    // compute it using cwnd/RTT.
    mutating func setRate(rate: UInt64) {
        self.rate = rate
    }

    // Burst size is in bytes and caller can compute this
    // by multiplying pacer rate with acceptable queue buildup
    // size expressed in time units(seconds)
    mutating func setBurstSize(burstSize: UInt32) {
        self.burstSize = burstSize
    }

    // Set the startup rate and burst size when the congestion control
    // is initialized with initial congestion window. These will be used
    // ONLY when the caller calls reset().
    mutating func setInitialState(_ startupRate: UInt64, _ startupBurstSize: UInt32) {
        self.startupRate = startupRate
        self.startUpBurstSize = startupBurstSize
    }

    mutating func reset() {
        self.rate = startupRate
        self.burstSize = startUpBurstSize
    }

    init(enabled: Bool = false) {
        self.enabled = enabled
    }
}
#endif
