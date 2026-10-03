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

protocol CubicLikeProtocol {
    static var beta: Double { get }
    static func minCongestionWindow(_ mss: Int) -> UInt64
    static func slowStartCongestionWindow(_ mss: Int) -> UInt64
    static func initialCongestionWindow(_ mss: Int) -> UInt64
}

extension CubicLikeProtocol {
    static func minCongestionWindow(_ mss: Int) -> UInt64 { UInt64(2 * mss) }
    static func slowStartCongestionWindow(_ mss: Int) -> UInt64 { UInt64(10 * mss) }
    static func idleTimeout(
        slowStartThreshold: UInt64,
        congestionWindow: UInt64,
        mss: Int
    ) -> UInt64 {

        max(
            slowStartThreshold,
            max(UInt64(Double(congestionWindow) * beta), initialCongestionWindow(mss))
        )
    }
    static func persistentCongestion(congestionWindow: UInt64, mss: Int) -> UInt64 {
        UInt64(max(Double(congestionWindow) * beta, Double(minCongestionWindow(mss))))
    }
}

@available(Network 0.1.0, *)
struct Cubic: CongestionControlProtocol, CubicLikeProtocol {
    var log: LogPrefixer

    var K: Double = 0
    var numCongestionEvents = 0
    var totalAcked = UInt64(0) /* total bytes acked for cubic */
    var tcpTotalAcked = UInt64(0) /* total bytes acked for TF */
    var lastMaxCongestionWindow = UInt64(0)
    var maxCongestionWindow = UInt64(0)
    var originPoint = UInt64(0)
    var epochStart = NetworkClock.Instant.zero
    var tcpCongestionWindow = UInt64(0)

    // 100ms, Only used to calculate startup pacer rate
    var pacingInitialRTT: NetworkDuration = .milliseconds(100)

    static let beta = 0.7
    static let oneSubBeta = 0.3
    static let oneAddBeta = 1.7
    static let cFactor = 0.4

    // 1/(2^10) = .000976s, we allow a burst queue of at least 976us,
    // we are using a higher burst than Prague because CUBIC will go
    // to classic queue with higher queuing threshold
    var burstQueueShift = 10
    static func initialCongestionWindow(_ mss: Int) -> UInt64 {
        UInt64(min(10 * mss, max(2 * mss, 14720)))
    }

    init(state: inout CongestionControlState, pacer: inout Pacer, mss: Int, qlog: QLog? = nil, logPrefixer: LogPrefixer)
    {
        self.log = logPrefixer
        reset(state: &state, mss: mss, qlog: qlog)
        if pacer.enabled {
            let startupRate =
                state.congestionWindow * System.Time.USEC_PER_SEC / UInt64(pacingInitialRTT.microseconds)
            let startupBurstSize = UInt64(mss)
            pacer.setInitialState(startupRate, UInt32(truncatingIfNeeded: startupBurstSize))
            pacer.reset()
        }
        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: nil)
    }

    private mutating func setK(state: CongestionControlState, mss: Int) {
        // K is the time period(s) that WCubic(t) function takes to increase
        // the current window size to WMax if there are no further
        // congestion events. Compute the cubic K using,
        // K = cubic_root(WMax(1-ß)/C)
        guard maxCongestionWindow > 0 else {
            K = 0
            return
        }
        guard maxCongestionWindow > state.congestionWindow else {
            K = 0
            if maxCongestionWindow < state.congestionWindow {
                // Log a fault for underflow cases. Don't log if it would just be zero.
                let maxCongestionWindow = maxCongestionWindow
                let congestionWindow = state.congestionWindow
                Logger.proto.fault(
                    "Max congestion window \(maxCongestionWindow) should be greater than congestion window \(congestionWindow)"
                )
            }
            return
        }

        K = Double(maxCongestionWindow - state.congestionWindow) / Cubic.cFactor
        K = K / Double(mss)
        #if !NETWORK_EMBEDDED
        K = cbrt(K)
        #else
        K = Cubic.cbrtPureSwift(K)
        #endif
    }

    private mutating func getTarget(
        state: CongestionControlState,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant
    ) -> UInt64 {
        if epochStart == .zero {
            // If we exit slow start without any packet
            // loss, CUBIC switches to CA where t is the elapsed
            // time since the beginning of the current CA. So, set
            // epochStart to now here.
            epochStart = now
            // Set originPoint for the start of epoch
            if state.congestionWindow < maxCongestionWindow {
                originPoint = maxCongestionWindow
                setK(state: state, mss: mss)
            } else {
                originPoint = state.congestionWindow
                K = 0
            }
            // Reset tcpCongestionWindow to be in sync with cubic
            tcpCongestionWindow = state.congestionWindow
            tcpTotalAcked = 0
        }
        // Compute target cubic window W(t+RTT) for the next RTT using,
        // W(t) = C(t-K)^3 + WMax
        let elapsedTime = epochStart.duration(to: now)
        var W = Double((elapsedTime + smoothedRTT).seconds) - K
        W *= W * W * Cubic.cFactor * Double(mss)

        let congestionWindow = W + Double(originPoint)
        let WCubicNext = congestionWindow > 0 ? congestionWindow : 0
        return UInt64(WCubicNext)
    }

    private mutating func updateTCPWindow(bytesAcked: UInt64, mss: Int) {
        // Compute TCP Friendly window using,
        //  W_est(t) = WMax*ß + [3*(1-ß)/(1+ß)] * (t/RTT), or
        //  W_est(t) = WMax*ß + [3*(1-ß)/(1+ß)] * (bytesAcked/tcpCongestionWindow)
        tcpTotalAcked += bytesAcked
        var alphaAIMD: Double = 1
        if tcpCongestionWindow < maxCongestionWindow {
            alphaAIMD = 3 * Cubic.oneSubBeta / Cubic.oneAddBeta
        }
        tcpCongestionWindow +=
            UInt64(alphaAIMD * Double(bytesAcked) * Double(mss) / Double(tcpCongestionWindow))
    }

    // Handle an in-sequence ACK in congestion avoidance phase
    private mutating func processAckCongestionAvoidance(
        state: inout CongestionControlState,
        bytesAcked: UInt64,
        smoothedRTT: NetworkDuration,
        mss: Int,
        now: NetworkClock.Instant
    ) {
        totalAcked += bytesAcked
        // compute W(t+RTT)
        let WCubicNext = getTarget(state: state, mss: mss, smoothedRTT: smoothedRTT, now: now)
        updateTCPWindow(bytesAcked: bytesAcked, mss: mss)
        if state.congestionWindow < WCubicNext {
            // Either concave or convex region
            // Total increase in 1RTT is (W(t+RTT) - congestionWindow).
            // To get increase per ACK, multiply by (bytesAcked / congestionWindow)
            let incr =
                Double((WCubicNext - state.congestionWindow))
                * (Double(totalAcked) / Double(state.congestionWindow))
            state.congestionWindow += min(UInt64(incr), Cubic.initialCongestionWindow(mss))
            totalAcked = 0
        }
        if state.congestionWindow < tcpCongestionWindow {
            // TCP friendly region
            state.congestionWindow = tcpCongestionWindow
            // When the congestionWindow is set based on TF region,
            // we should reset the totalAcked counter as we
            // have already used bytes acked equivalent to
            // tcpTotalAcked for TF congestionWindow.
            totalAcked = totalAcked > tcpTotalAcked ? totalAcked - tcpTotalAcked : 0
            tcpTotalAcked = 0
        }
        // Set WMax to congestionWindow to keep updating our current estimate of WMax
        // as we are probing for new limits at the start of connection
        if numCongestionEvents == 0 {
            maxCongestionWindow = state.congestionWindow
        }
    }

    private func updatePacerState(state: CongestionControlState, path: QUICPath?, smoothedRTT: NetworkDuration) {
        guard let path, path.pacer.enabled else {
            return
        }

        // A short RTT can round to zero: `RTT.processNewSample` stores the sample as whole
        // microseconds, so an ack duration under 500ns becomes 0µs and dividing by it below would
        // trap. Fall back to the initial estimate.
        let smoothedRTTInMicroseconds =
            smoothedRTT.microseconds == 0 ? pacingInitialRTT.microseconds : smoothedRTT.microseconds

        // Use 200% rate when in slow start
        let pacedWindow =
            state.congestionWindow < state.slowStartThreshold ? state.congestionWindow * 2 : state.congestionWindow
        let rateInBytesPerSecond =
            pacedWindow * System.Time.USEC_PER_SEC / UInt64(smoothedRTTInMicroseconds)
        let burstSize = rateInBytesPerSecond >> burstQueueShift

        path.pacer.setRate(rate: rateInBytesPerSecond)
        path.pacer.setBurstSize(burstSize: UInt32(truncatingIfNeeded: burstSize))
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
        updatePacerState(state: state, path: path, smoothedRTT: smoothedRTT)
        return reducedCongestionWindow
    }

    mutating func enterRecovery(
        state: inout CongestionControlState,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        log.datapath("Entering Recovery: current cwin=\(state.congestionWindow)")
        state.recoveryStartTime = now
        lastMaxCongestionWindow = maxCongestionWindow
        maxCongestionWindow = state.congestionWindow
        state.congestionWindow = UInt64(Double(state.lossFlightSize(log: log)) * Cubic.beta)
        if _slowPath(state.congestionWindow < Cubic.minCongestionWindow(mss)) {
            state.congestionWindow = UInt64(Cubic.minCongestionWindow(mss))
        }
        state.prevSlowStartThreshold = state.slowStartThreshold
        state.slowStartThreshold = state.congestionWindow
        // If Fast Convergence is supported, release more bandwidth
        // if saturation point is getting reduced due to new flows
        if maxCongestionWindow < lastMaxCongestionWindow {
            maxCongestionWindow = UInt64(
                max(
                    Double(maxCongestionWindow) * Cubic.oneAddBeta / 2.0,
                    Double(Cubic.minCongestionWindow(mss))
                )
            )
        }
        // Compute epoch period K(s) that the window will take to increase
        // to last_max again after backoff due to loss.
        // Note that K = 0 if we enter congestion avoidance without loss.
        setK(state: state, mss: mss)
        // Set the start of current congestion avoidance and the origin point
        epochStart = now
        originPoint = maxCongestionWindow
        // Reset tcpCongestionWindow to be in sync with cubic
        tcpCongestionWindow = state.congestionWindow
        tcpTotalAcked = 0
        numCongestionEvents += 1
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
        if packetsLost {
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
        if state.congestionWindow < state.slowStartThreshold {
            state.congestionWindow += min(
                state.bytesAcked,
                Cubic.slowStartCongestionWindow(mss)
            )
        } else {
            processAckCongestionAvoidance(
                state: &state,
                bytesAcked: state.bytesAcked,
                smoothedRTT: smoothedRTT,
                mss: mss,
                now: now
            )
        }
        // Should be a minimum of 2*MSS
        if _slowPath(state.congestionWindow < Cubic.minCongestionWindow(mss)) {
            state.congestionWindow = Cubic.minCongestionWindow(mss)
        }
        updatePacerState(state: state, path: path, smoothedRTT: smoothedRTT)
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
        // is not used by CUBIC. This state is relevant
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

        /* Update CE count even if we are already in CWR */
        state.ecnCECounter = ceCount

        // Received an ACK with new CE counts, reset bytesAcked so
        // we that we don't increase congestionWindow during ackEnd
        state.bytesAcked = 0

        if !state.rttElapsed(
            largestSentPN: state.largestSentPN,
            largestAckedPN: largestAckedPN
        ) {
            // Haven't elapsed one RTT yet from last CWR
            return
        }
        congestionEvent(state: &state, sentTime: largestAckedSentTime, mss: mss, now: now, qlog: qlog)
        // Update pacer state as congestionWindow has changed
        updatePacerState(state: state, path: path, smoothedRTT: smoothedRTT)
        // Start new round for CWR
        state.largestSentPN = largestSentPN
    }

    mutating func idleTimeout(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        // We want to ideally begin with slow start after idle period.
        // Set it to the larger of its current value, MAX (congestionWindow * Beta, IW)
        state.slowStartThreshold = Cubic.idleTimeout(
            slowStartThreshold: state.slowStartThreshold,
            congestionWindow: state.congestionWindow,
            mss: mss
        )
        // Set congestionWindow to initial congestion window
        state.congestionWindow = min(state.congestionWindow, Cubic.initialCongestionWindow(mss))
        state.logUpdate(log: log, qlog: qlog)
        resetInternal(state: &state)
    }

    mutating func persistentCongestion(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        state.slowStartThreshold = Cubic.persistentCongestion(
            congestionWindow: state.congestionWindow,
            mss: mss
        )
        // Set the minimum congestion window
        state.congestionWindow = Cubic.minCongestionWindow(mss)
        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: .persistentCongestion)
    }

    mutating func spuriousRetransmit(state: inout CongestionControlState, qlog: QLog? = nil) {
        guard maxCongestionWindow > 0 && state.prevSlowStartThreshold > 0 else { return }
        // Revert to the state before loss was detected
        state.congestionWindow = max(maxCongestionWindow, state.congestionWindow)
        state.slowStartThreshold = state.prevSlowStartThreshold
        state.logUpdate(log: log, qlog: qlog)
    }

    private mutating func resetInternal(state: inout CongestionControlState) {
        state.recoveryStartTime = .zero
        state.prevSlowStartThreshold = UInt64.max
        numCongestionEvents = 0
        K = 0
        totalAcked = 0
        epochStart = .zero
        originPoint = 0
        lastMaxCongestionWindow = 0
        maxCongestionWindow = state.congestionWindow
        // CWV state
        state.pipeAckSampleEnd = .zero
        state.initPipeAckSamples()
    }

    func filloutDataTransferSnapshot(state: CongestionControlState, dataTransferSnapshot: inout DataTransferSnapshot) {
        dataTransferSnapshot.transportCongestionWindow = state.congestionWindow
        dataTransferSnapshot.transportSlowStartThreshold = state.slowStartThreshold
    }

    mutating func reset(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        state.congestionWindow = Cubic.initialCongestionWindow(mss)
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
        // For Cubic, the old state will be stale and
        // as it will ramp up quickly in slow start, it
        // is best to start fresh. For congestion window
        // we can use the higher of last congestionWindow and initialCongestionWindow
        state.bytesInFlight = from.bytesInFlight
        state.congestionWindow = max(from.congestionWindow, Cubic.initialCongestionWindow(mss))
        state.slowStartThreshold = UInt64.max
        resetInternal(state: &state)
        state.logUpdate(log: log, qlog: qlog)
    }
}
#endif
