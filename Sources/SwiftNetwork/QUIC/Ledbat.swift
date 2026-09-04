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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct Ledbat: CongestionControlProtocol, CubicLikeProtocol {
    let log: LogPrefixer

    var congestionWindow = UInt64(0)
    var bytesInFlight = UInt64(0)
    var packetsAcked = UInt64(0)
    var packetsMarked = UInt64(0)
    var ecnCECounter = 0
    var largestSentPN = Int64(0)
    var slowStartThreshold = UInt64(0)
    var prevSlowStartThreshold = UInt64(0)
    var recoveryStartTime = NetworkClock.Instant.zero
    var bytesAcked = UInt64(0)
    var pipeAckSamples = [UInt64(0)]
    var pipeAckValue = UInt64(0)
    var pipeAckSampleEnd = NetworkClock.Instant.zero
    var pipeAckAcked = UInt64(0)
    var pipeAckIndex = 0

    private var prevCongestionWindow = UInt64(0)
    private var slowDownTimestamp = NetworkClock.Instant.zero
    private var slowDownBegin = NetworkClock.Instant.zero
    private var slowDownEnd = NetworkClock.Instant.zero
    private var numSlowDownEvents = 0

    static let beta = 0.5
    static let target: NetworkDuration = .milliseconds(60)
    static let gain = 16
    static let defaultCongestionWindow = 2944
    static func initialCongestionWindow(_ mss: Int) -> UInt64 {
        UInt64(min(2 * mss, Ledbat.defaultCongestionWindow))
    }

    init(mss: Int, qlog: QLog? = nil, logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        congestionWindow = Ledbat.initialCongestionWindow(mss)
        slowStartThreshold = UInt64.max
        reset(mss: mss, qlog: qlog)
        logUpdate(qlog: qlog)
    }

    // GAIN is proportional to the ratio of base_delay
    // and TARGET delay, i.e., GAIN is smaller for bottlenecks
    // with small queues in order to ensure that LEDBAT yields
    // in those networks. It is larger for long delay networks
    // to provide better link utilization.
    private func gain(_ baseRTT: NetworkDuration) -> Double {
        #if NETWORK_EMBEDDED
        fatalError("not supported yet")
        #else
        let rttCeiling = ceil(Double(Ledbat.target.microseconds * 2) / Double(baseRTT.microseconds))
        return (1 / (min(Double(Ledbat.gain), rttCeiling)))
        #endif
    }

    @discardableResult
    mutating func packetLost(
        path: QUICPath? = nil,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        decrementBytesInFlight(UInt64(bytesLost))
        let reducedCongestionWindow = congestionEvent(
            sentTime: largestLostSentTime,
            mss: mss,
            now: now,
            qlog: qlog
        )
        return reducedCongestionWindow
    }

    mutating func enterRecovery(mss: Int, now: NetworkClock.Instant, qlog: QLog? = nil) {
        recoveryStartTime = now
        prevCongestionWindow = congestionWindow
        congestionWindow = UInt64(Double(lossFlightSize) * Ledbat.beta)
        if _slowPath(congestionWindow < Ledbat.minCongestionWindow(mss)) {
            congestionWindow = Ledbat.minCongestionWindow(mss)
        }
        prevSlowStartThreshold = slowStartThreshold
        slowStartThreshold = congestionWindow
        initPipeAckSamples()
        logUpdate(qlog: qlog)
        logState(qlog: qlog, state: .recovery, trigger: nil)
    }

    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath? = nil,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        guard packetsLost == false else {
            // one or more packets were marked lost during
            // this ACK processing
            return
        }
        if bytesAcked == 0 {
            // When we are in recovery period or received new CE counts
            return
        }
        let smoothedRTT = rtt.smoothedRTT
        if !revalidateCongestionWindow(smoothedRTT: smoothedRTT, now: now) {
            bytesAcked = 0
            return
        }
        let baseRTT = rtt.baseRTT
        let currentRTT = rtt.adjustedRTT
        guard currentRTT >= baseRTT else {
            log.fault("currentRTT lower than baseRTT")
            return
        }
        let qDelay = currentRTT - baseRTT
        // Slowdown period - first slowdown
        // is 2RTT after we exit initial slow start.
        // Subsequent slowdowns are after 9 times the
        // previous slow down durations.
        if slowDownTimestamp != .zero && now >= slowDownTimestamp {
            if slowDownBegin == .zero {
                slowDownBegin = now
                numSlowDownEvents += 1
            }
            if now < slowDownTimestamp + smoothedRTT * 2 {
                // Set cwnd to 2 packets and return
                if congestionWindow > Ledbat.minCongestionWindow(mss) {
                    slowStartThreshold = congestionWindow
                    congestionWindow = Ledbat.minCongestionWindow(mss)
                }
                return
            }
        }

        // Modified slow start with a dynamic GAIN
        // If the queuing delay is larger than 3/4
        // of the target delay, exit slow start, iff,
        // it is the initial slow start. After the initial
        // slow start, during CA, window growth will be bound
        // by ssthresh.
        let slowStartTarget = Ledbat.target * 0.75
        if congestionWindow < slowStartThreshold
            && (numSlowDownEvents > 0 || qDelay < slowStartTarget)
        {
            congestionWindow += UInt64(
                gain(baseRTT) * Double(min(bytesAcked, Ledbat.slowStartCongestionWindow(mss)))
            )
            // Reset the exit time
            if slowDownTimestamp != .zero {
                slowDownTimestamp = .zero
            }
        } else {
            // Set the next slowdown time
            // i.e. 9 times the duration of previous slowdown
            // except the initial slowdown
            if slowDownTimestamp == .zero {
                // On exit slow start due to higher queuing delay, cap
                // the ssthresh
                slowStartThreshold = min(slowStartThreshold, congestionWindow)
                if numSlowDownEvents > 0 && slowDownEnd == .zero {
                    // Set the slowdown end immediately after the
                    // previous slowdown event
                    slowDownEnd = now
                }
                let slowDownDuration = slowDownBegin.duration(to: slowDownEnd)
                slowDownTimestamp = now + 9 * slowDownDuration
                if slowDownDuration == .zero {
                    slowDownTimestamp = slowDownTimestamp.advanced(by: smoothedRTT * 2)
                }
                // Reset the start & end of slowdown
                slowDownBegin = .zero
                slowDownEnd = .zero
            }
            // Additive increase -> W += GAIN (per RTT)
            if qDelay < Ledbat.target {
                let tempIncrement = gain(baseRTT) * Double(bytesAcked)
                congestionWindow += UInt64(tempIncrement * Double(mss) / Double(congestionWindow))
            } else {
                // Multiplicative decrease ->
                // W -= min(W * (qdelay/target - 1), W/2) (per RTT)
                // To calculate per bytes acked, it becomes
                // W -= min((qdelay/target - 1), 1/2) * bytes_acked
                // Sometime bytes_acked > cwnd due to PTO, so lets
                // cap it to cwnd.
                let tempMin = min(
                    Double(qDelay.microseconds) / Double(Ledbat.target.microseconds) - 1,
                    0.5
                )
                congestionWindow -= UInt64(tempMin * Double(min(bytesAcked, congestionWindow)))
                // MD during Congestion Avoidance, limit ssthresh to
                // current cwnd
                slowStartThreshold = min(slowStartThreshold, congestionWindow)
            }
        }
        // Should be a minimum of 2*MSS
        if _slowPath(congestionWindow < Ledbat.minCongestionWindow(mss)) {
            congestionWindow = Ledbat.minCongestionWindow(mss)
            // ssthresh should be at least 2*MSS as well
            slowStartThreshold = max(slowStartThreshold, congestionWindow)
        }
        logUpdate(qlog: qlog)
    }

    mutating func processECN(
        path: QUICPath? = nil,
        ceCount: Int,
        packetsAcked: Int,
        largestSentPN: Int64,
        largestAckedPN: Int64,
        largestAckedSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        if _slowPath(ceCount < ecnCECounter) {
            log.fault(
                "New CE count \(ceCount) can't be less than current CE count \(ecnCECounter)"
            )
        }
        // Update packets acked and marked on every ACK, even if it
        // is not used by LEDBAT. This state is relevant
        // for Prague and needs to be updated by other CCs
        // esp. LEDBAT.
        packetsMarked = UInt64(ceCount)
        self.packetsAcked = UInt64(packetsAcked)

        if ceCount == ecnCECounter {
            // No change in CE
            return
        }
        log.datapath(
            "\(bytesAcked) bytes were ACKed with \(ecnCECounter) packets newly CE marked"
        )
        // Update CE count even if we are already in CWR
        ecnCECounter = ceCount

        // Received an ACK with new CE counts, reset bytes_acked so
        // we that we don't increase cwnd during ack_end
        bytesAcked = 0
        if !rttElapsed(largestSentPN: self.largestSentPN, largestAckedPN: largestAckedPN) {
            /* Haven't elapsed one RTT yet from last CWR */
            return
        }
        congestionEvent(sentTime: largestAckedSentTime, mss: mss, now: now)

        // Start new round for CWR
        self.largestSentPN = largestSentPN
    }

    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        guard prevCongestionWindow > 0 && prevSlowStartThreshold > 0 else { return }

        // Revert to the state before loss was detected
        congestionWindow = max(prevCongestionWindow, congestionWindow)
        slowStartThreshold = prevSlowStartThreshold
        logUpdate(qlog: qlog)
    }

    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        // Set the minimum congestion window
        let newCWND = Ledbat.minCongestionWindow(mss)
        slowStartThreshold = max(UInt64(Double(congestionWindow) * Ledbat.beta), newCWND)
        congestionWindow = newCWND
        logUpdate(qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: .persistentCongestion)
    }

    private mutating func resetInternal() {
        recoveryStartTime = .zero
        prevSlowStartThreshold = 0
        prevCongestionWindow = 0

        slowDownTimestamp = .zero
        slowDownBegin = .zero
        slowDownEnd = .zero
        numSlowDownEvents = 0

        // CWV state
        pipeAckSampleEnd = .zero
        initPipeAckSamples()
    }

    mutating func idleTimeout(mss: Int, qlog: QLog? = nil) {
        // We want to ideally begin with slow start after idle period.
        // Set it to the larger of its current value, MAX (cwnd * Beta, IW)
        slowStartThreshold = max(
            slowStartThreshold,
            max(UInt64(Double(congestionWindow) * Ledbat.beta), Ledbat.initialCongestionWindow(mss))
        )
        // Set cwnd to initial cwnd
        congestionWindow = min(congestionWindow, Ledbat.initialCongestionWindow(mss))
        resetInternal()
        logUpdate(qlog: qlog)
    }

    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        dataTransferSnapshot.transportCongestionWindow = congestionWindow
        dataTransferSnapshot.transportSlowStartThreshold = slowStartThreshold
    }

    mutating func reset(mss: Int, qlog: QLog? = nil) {
        congestionWindow = Ledbat.initialCongestionWindow(mss)
        slowStartThreshold = UInt64.max
        resetInternal()
        logUpdate(qlog: qlog)
    }

    mutating func inherit(from: CongestionControl, mss: Int, qlog: QLog?) {
        // LEDBAT has minimal state. We can continue using its own
        // ssthresh from old state as it is somewhat stable.
        // For congestion window, we can take the lower of
        // its own cwnd and previous controller's cwnd.
        switch from {
        case .cubic(let cubic):
            self.bytesInFlight = cubic.bytesInFlight
            self.congestionWindow = min(cubic.congestionWindow, congestionWindow)
        #if !NETWORK_EMBEDDED
        case .ledbat(let ledbat):
            self.bytesInFlight = ledbat.bytesInFlight
            self.congestionWindow = min(ledbat.congestionWindow, congestionWindow)
        case .prague(let prague):
            self.bytesInFlight = prague.bytesInFlight
            self.congestionWindow = min(prague.congestionWindow, congestionWindow)
        #endif
        }
        logUpdate(qlog: qlog)
        resetInternal()
    }
}
#endif
