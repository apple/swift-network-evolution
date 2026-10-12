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
struct RTT: ~Copyable, PrefixedLoggable {
    static let initialRTT: NetworkDuration = .milliseconds(333)
    static let historyInterval: NetworkDuration = .seconds(60)
    static let nbaseHistory = 10  // 10 minutes
    static let invalidRTT: NetworkDuration = .seconds(UInt32.max)

    var log: LogPrefixer
    private(set) var latestRTT = RTT.initialRTT
    var adjustedRTT: NetworkDuration = .microseconds(0)  // RTT adjusted by ackDelay
    var smoothedRTT = RTT.initialRTT
    private(set) var RTTVariance = RTT.initialRTT / 2
    var minRTT: NetworkDuration = RTT.invalidRTT

    // Base RTT history samples
    private var baseRTTs = [NetworkDuration](repeatElement(RTT.invalidRTT, count: RTT.nbaseHistory))

    // Start of the current history interval. Always a whole number of
    // `historyInterval`s after the first sample.
    private var lastRolloverTimestamp: NetworkClock.Instant? = nil

    // Smallest measured base rtt for specified history
    var baseRTT = RTT.invalidRTT

    private var baseRTTIndex = 0

    init(logPrefixer: LogPrefixer) {
        self.log = logPrefixer
    }

    // 0 ms used for initial and handshake
    private var _remoteMaxAckDelay: NetworkDuration = .microseconds(0)
    var remoteMaxAckDelay: NetworkDuration {
        get {
            _remoteMaxAckDelay
        }
        set {
            _remoteMaxAckDelay = newValue
            log.debug("New remoteMaxAckDelay: \(_remoteMaxAckDelay)")
        }
    }

    private var cachedAvgRTT = RTT.invalidRTT
    private var cachedMinRTT = RTT.invalidRTT
    private var cachedRTTVariance = RTT.invalidRTT
    private var routeFlags: Int32 = 0

    private(set) var hasInitialMeasurement: Bool = false

    private var validCachedRTT: Bool {
        // TODO: Fetch RTT values from system cache
        false
    }

    private mutating func updateBaseRTT(currentRTT: NetworkDuration, now: NetworkClock.Instant) {
        if !hasInitialMeasurement {
            baseRTTIndex = 0
            baseRTTs[baseRTTIndex] = currentRTT
            baseRTT = currentRTT
            lastRolloverTimestamp = now
            return
        }
        guard let lastRollover = lastRolloverTimestamp else {
            return
        }
        if now > lastRollover && lastRollover.duration(to: now) > RTT.historyInterval {
            let timeSinceLastRollover = lastRollover.duration(to: now)
            // Number of whole history intervals elapsed since the start of the
            // current interval.
            let rolloverIndex = Int(timeSinceLastRollover / RTT.historyInterval)
            let times = baseRTTIndex + rolloverIndex

            // Set the base rtt to invalid for idle periods. The slots strictly
            // between the old and new index had no samples. Once the gap
            // reaches nbaseHistory every slot (including the old index) is
            // stale, so cap the work instead of wrapping over the ring again
            // for each idle minute.
            let slotsToClear = min(rolloverIndex - 1, RTT.nbaseHistory)
            for i in stride(from: baseRTTIndex + 1, through: baseRTTIndex + slotsToClear, by: 1) {
                baseRTTs[i % RTT.nbaseHistory] = RTT.invalidRTT
            }
            baseRTTIndex = times % RTT.nbaseHistory
            baseRTTs[baseRTTIndex] = currentRTT
            // Advance by whole intervals so boundaries stay aligned to fixed
            // steps from the first sample, rather than drifting to whenever a
            // sample happens to arrive.
            lastRolloverTimestamp = lastRollover.advanced(by: RTT.historyInterval * rolloverIndex)

            baseRTT = baseRTTs[0]
            for i in 0..<RTT.nbaseHistory {
                if baseRTT > baseRTTs[i] {
                    baseRTT = baseRTTs[i]
                }
            }
        } else {
            baseRTTs[baseRTTIndex] = min(currentRTT, baseRTTs[baseRTTIndex])
            baseRTT = min(baseRTT, baseRTTs[baseRTTIndex])
        }

    }

    mutating func processNewSample(
        ackDuration: NetworkDuration,
        packetAckedTime: NetworkClock.Instant,
        ackDelay: NetworkDuration

    ) {
        latestRTT = ackDuration.roundedMicroseconds

        if !hasInitialMeasurement {
            minRTT = latestRTT
            smoothedRTT = latestRTT
            RTTVariance = latestRTT / 2
            updateBaseRTT(currentRTT: latestRTT, now: packetAckedTime)
            adjustedRTT = latestRTT
            hasInitialMeasurement = true
            log.datapath(
                "Initial RTT measurement: smoothed RTT \(smoothedRTT), variance \(RTTVariance)"
            )
            return
        }
        if latestRTT < minRTT {
            log.datapath(
                "New min RTT: \(latestRTT) (replacing previous value \(minRTT))"
            )
            minRTT = latestRTT
        }
        var validAckDelay = ackDelay
        if _slowPath(ackDelay > remoteMaxAckDelay) {
            validAckDelay = remoteMaxAckDelay
            log.datapath(
                "Limiting ackDelay to max from peer: \(remoteMaxAckDelay) (raw ack delay \(ackDelay))"
            )
        }
        var includeAckDelay = false
        adjustedRTT = latestRTT
        if _slowPath(validAckDelay > RTT.invalidRTT - minRTT) {
            log.error("ackDelay overflow")
        } else if latestRTT >= minRTT + validAckDelay {
            adjustedRTT = latestRTT - validAckDelay
            includeAckDelay = true
        }
        updateBaseRTT(currentRTT: adjustedRTT, now: packetAckedTime)

        let includingAckDelay = includeAckDelay ? "including" : "not including"
        log.datapath(
            "New RTT sample (\(includingAckDelay) ACK delay \(ackDelay)): \(latestRTT)"
        )

        smoothedRTT = (smoothedRTT * 7 / 8) + adjustedRTT / 8
        smoothedRTT = smoothedRTT.roundedMicroseconds
        let difference =
            smoothedRTT > adjustedRTT ? smoothedRTT - adjustedRTT : adjustedRTT - smoothedRTT
        RTTVariance = RTTVariance * 3 / 4 + difference / 4
        RTTVariance = RTTVariance.roundedMicroseconds
        log.datapath(
            "Calculated new smoothed RTT: \(smoothedRTT), variance: \(RTTVariance)"
        )
    }

    var cachedRTT: (NetworkDuration, NetworkDuration) {
        var rttInitial = RTT.initialRTT
        var rttVariance = RTT.initialRTT / 2

        if _slowPath(QUICPreferences.shared.disableCachedRTT) {
            return (RTT.initialRTT, RTT.initialRTT / 2)
        }

        if validCachedRTT {
            rttInitial = min(RTT.initialRTT, cachedAvgRTT)
            log.datapath("Initial RTT: \(rttInitial)")
            if cachedRTTVariance != RTT.invalidRTT && rttInitial < RTT.initialRTT {
                rttVariance = cachedRTTVariance
                log.datapath("Initial RTT variance: \(rttVariance)")
            }
        }

        return (rttInitial, rttVariance)
    }
}
#endif
