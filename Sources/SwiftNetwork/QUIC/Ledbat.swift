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

    init(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil, logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        state.congestionWindow = Ledbat.initialCongestionWindow(mss)
        state.slowStartThreshold = UInt64.max
        reset(state: &state, mss: mss, qlog: qlog)
        state.logUpdate(log: log, qlog: qlog)
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
        state: inout CongestionControlState,
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        state.decrementBytesInFlight(UInt64(bytesLost), log: log)
        let reducedCongestionWindow = congestionEvent(
            state: &state,
            sentTime: largestLostSentTime,
            mss: mss,
            now: now,
            qlog: qlog
        )
        return reducedCongestionWindow
    }

    mutating func enterRecovery(
        state: inout CongestionControlState,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        state.recoveryStartTime = now
        prevCongestionWindow = state.congestionWindow
        state.congestionWindow = UInt64(Double(state.lossFlightSize(log: log)) * Ledbat.beta)
        if _slowPath(state.congestionWindow < Ledbat.minCongestionWindow(mss)) {
            state.congestionWindow = Ledbat.minCongestionWindow(mss)
        }
        state.prevSlowStartThreshold = state.slowStartThreshold
        state.slowStartThreshold = state.congestionWindow
        state.initPipeAckSamples()
        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .recovery, trigger: nil)
    }

    mutating func ackEnd(
        state: inout CongestionControlState,
        rtt: borrowing RTT,
        path: QUICPath?,
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
        if state.bytesAcked == 0 {
            // When we are in recovery period or received new CE counts
            return
        }
        let smoothedRTT = rtt.smoothedRTT
        if !state.revalidateCongestionWindow(smoothedRTT: smoothedRTT, now: now, log: log) {
            state.bytesAcked = 0
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
                if state.congestionWindow > Ledbat.minCongestionWindow(mss) {
                    state.slowStartThreshold = state.congestionWindow
                    state.congestionWindow = Ledbat.minCongestionWindow(mss)
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
        if state.congestionWindow < state.slowStartThreshold
            && (numSlowDownEvents > 0 || qDelay < slowStartTarget)
        {
            state.congestionWindow += UInt64(
                gain(baseRTT) * Double(min(state.bytesAcked, Ledbat.slowStartCongestionWindow(mss)))
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
                state.slowStartThreshold = min(state.slowStartThreshold, state.congestionWindow)
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
                let tempIncrement = gain(baseRTT) * Double(state.bytesAcked)
                state.congestionWindow += UInt64(tempIncrement * Double(mss) / Double(state.congestionWindow))
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
                state.congestionWindow -= UInt64(tempMin * Double(min(state.bytesAcked, state.congestionWindow)))
                // MD during Congestion Avoidance, limit ssthresh to
                // current cwnd
                state.slowStartThreshold = min(state.slowStartThreshold, state.congestionWindow)
            }
        }
        // Should be a minimum of 2*MSS
        if _slowPath(state.congestionWindow < Ledbat.minCongestionWindow(mss)) {
            state.congestionWindow = Ledbat.minCongestionWindow(mss)
            // ssthresh should be at least 2*MSS as well
            state.slowStartThreshold = max(state.slowStartThreshold, state.congestionWindow)
        }
        state.logUpdate(log: log, qlog: qlog)
    }

    mutating func processECN(
        state: inout CongestionControlState,
        path: QUICPath?,
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
        if _slowPath(ceCount < state.ecnCECounter) {
            log.fault(
                "New CE count \(ceCount) can't be less than current CE count \(state.ecnCECounter)"
            )
        }
        // Update packets acked and marked on every ACK, even if it
        // is not used by LEDBAT. This state is relevant
        // for Prague and needs to be updated by other CCs
        // esp. LEDBAT.
        state.packetsMarked = UInt64(ceCount)
        state.packetsAcked = UInt64(packetsAcked)

        if ceCount == state.ecnCECounter {
            // No change in CE
            return
        }
        log.datapath(
            "\(state.bytesAcked) bytes were ACKed with \(state.ecnCECounter) packets newly CE marked"
        )
        // Update CE count even if we are already in CWR
        state.ecnCECounter = ceCount

        // Received an ACK with new CE counts, reset bytes_acked so
        // we that we don't increase cwnd during ack_end
        state.bytesAcked = 0
        if !state.rttElapsed(largestSentPN: state.largestSentPN, largestAckedPN: largestAckedPN) {
            /* Haven't elapsed one RTT yet from last CWR */
            return
        }
        congestionEvent(state: &state, sentTime: largestAckedSentTime, mss: mss, now: now)

        // Start new round for CWR
        state.largestSentPN = largestSentPN
    }

    mutating func spuriousRetransmit(state: inout CongestionControlState, qlog: QLog? = nil) {
        guard prevCongestionWindow > 0 && state.prevSlowStartThreshold > 0 else { return }

        // Revert to the state before loss was detected
        state.congestionWindow = max(prevCongestionWindow, state.congestionWindow)
        state.slowStartThreshold = state.prevSlowStartThreshold
        state.logUpdate(log: log, qlog: qlog)
    }

    mutating func persistentCongestion(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        // Set the minimum congestion window
        let newCWND = Ledbat.minCongestionWindow(mss)
        state.slowStartThreshold = max(UInt64(Double(state.congestionWindow) * Ledbat.beta), newCWND)
        state.congestionWindow = newCWND
        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: .persistentCongestion)
    }

    private mutating func resetInternal(state: inout CongestionControlState) {
        state.recoveryStartTime = .zero
        state.prevSlowStartThreshold = 0
        prevCongestionWindow = 0

        slowDownTimestamp = .zero
        slowDownBegin = .zero
        slowDownEnd = .zero
        numSlowDownEvents = 0

        // CWV state
        state.pipeAckSampleEnd = .zero
        state.initPipeAckSamples()
    }

    mutating func idleTimeout(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        // We want to ideally begin with slow start after idle period.
        // Set it to the larger of its current value, MAX (cwnd * Beta, IW)
        state.slowStartThreshold = max(
            state.slowStartThreshold,
            max(UInt64(Double(state.congestionWindow) * Ledbat.beta), Ledbat.initialCongestionWindow(mss))
        )
        // Set cwnd to initial cwnd
        state.congestionWindow = min(state.congestionWindow, Ledbat.initialCongestionWindow(mss))
        resetInternal(state: &state)
        state.logUpdate(log: log, qlog: qlog)
    }

    func filloutDataTransferSnapshot(state: CongestionControlState, dataTransferSnapshot: inout DataTransferSnapshot) {
        dataTransferSnapshot.transportCongestionWindow = state.congestionWindow
        dataTransferSnapshot.transportSlowStartThreshold = state.slowStartThreshold
    }

    mutating func reset(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        state.congestionWindow = Ledbat.initialCongestionWindow(mss)
        state.slowStartThreshold = UInt64.max
        resetInternal(state: &state)
        state.logUpdate(log: log, qlog: qlog)
    }

    mutating func inherit(
        from: CongestionControlState,
        state: inout CongestionControlState,
        mss: Int,
        qlog: QLog? = nil
    ) {
        // LEDBAT has minimal state. We can continue using its own
        // ssthresh from old state as it is somewhat stable.
        // For congestion window, we can take the lower of
        // its own cwnd and previous controller's cwnd.
        state.bytesInFlight = from.bytesInFlight
        state.congestionWindow = min(from.congestionWindow, state.congestionWindow)
        state.logUpdate(log: log, qlog: qlog)
        resetInternal(state: &state)
    }
}
#endif
