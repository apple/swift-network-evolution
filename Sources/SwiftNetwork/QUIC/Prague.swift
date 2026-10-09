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
//  Provides implementation of the Prague Congestion Control algorithm
//  Prague is a scalable congestion control derived from DCTCP to achieve
//  steady state (2 CE signals per RTT) even when the flow rate scales.
//  This implementation uses concepts from DCTCP and
//  draft-briscoe-iccrg-prague-congestion-control. It differs from these
//  two as it performs CUBIC increase during congestion avoidance.

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

/// Indicates the RTT independence control type.
enum RTTControlType: UInt8 {
    /// Trades off some throughput balance at very low RTTs for scalability — that is, to get non-zero marks per RTT.
    case balanceRateScalable
    /// Gets near-perfect throughput equivalence at the cost of losing scalability for very low RTTs.
    case rateEquivalence
}

@available(Network 0.1.0, *)
struct Prague: CongestionControlProtocol, CubicLikeProtocol {
    let log: LogPrefixer

    private static let alphaShift = 20
    private static let gShift = 4
    private static let congestionWindowShift = 20
    private static let scalableCongestionWindowFactor: UInt64 = 1 << 20
    private static let maxAlpha: UInt64 = 1 << alphaShift
    private static let referenceRTTRate: NetworkDuration = .milliseconds(20)
    private static let referenceRTTScalable: NetworkDuration = .milliseconds(7)

    // CUBIC constants (shared with Cubic.swift)
    static let beta = 0.7
    static let oneSubBeta = 0.3
    static let oneAddBeta = 1.7
    static let cFactor = 0.4

    // 1/(2^12) = 0.000244s, we allow a burst queue of at least 250us
    private var burstQueueShift = 12

    // Only used to calculate startup pacer rate
    private var pacingInitialRTT: NetworkDuration = .milliseconds(100)

    // Prague-specific state
    //
    // Prague state includes:
    // 1. Exponentially Moving Weighted Average (EWMA) -> alpha, of fraction of CE marks [0,1]
    // 2. g is the estimation gain, a real number between 0 and 1, we use 1/2^4
    // 3. scaled_alpha is alpha / g or alpha << g_shift
    //
    private var numCongestionEventsLoss: UInt16 = 0
    private var numCongestionEventsCE: UInt16 = 0
    private var reducedDueToCE = false
    private var rttControl: RTTControlType = .rateEquivalence

    /// The largest sent packet number set at the start of the round for alpha.
    ///
    /// Differs from the common state, which tracks the round for CWR.
    private var largestSentPNForAlpha: Int64 = 0
    /// The scaled value of the DCTCP alpha.
    ///
    /// Stores the scaled `DCTCP.alpha`.
    private var scaledAlpha: UInt64 = 0
    /// The additive-increase alpha used after CE.
    ///
    /// Stores the `AI.alpha` value used after CE for additive increase.
    private var alphaAI: UInt64 = 0

    // Local link congestion info
    private var localCECount: UInt32 = 0
    private var localPktCount: UInt32 = 0
    private var localCEDelta: UInt32 = 0
    private var localPktDelta: UInt32 = 0

    // CUBIC/Reno window increase state
    private var cubicK: Double = 0
    private var cubicAcked: UInt64 = 0
    private var renoAcked: UInt64 = 0
    private var cubicLastMaxCongestionWindow: UInt64 = 0
    private var cubicMaxCongestionWindow: UInt64 = 0
    private var cubicOriginPoint: UInt64 = 0
    private var cubicEpochStart: NetworkClock.Instant = .zero
    private var renoCongestionWindow: UInt64 = 0

    static func initialCongestionWindow(_ mss: Int) -> UInt64 {
        UInt64(min(10 * mss, max(2 * mss, 14720)))
    }

    init(state: inout CongestionControlState, pacer: inout Pacer, mss: Int, qlog: QLog? = nil, logPrefixer: LogPrefixer)
    {
        self.log = logPrefixer
        state.congestionWindow = Prague.initialCongestionWindow(mss)
        state.slowStartThreshold = UInt64.max
        scaledAlpha = Prague.maxAlpha << Prague.gShift
        resetInternal(state: &state)
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

    /// Computes the cubic K factor for the current congestion window.
    ///
    /// `K` is the time period(s) that the `W_cubic(t)` function takes to increase
    /// the current window size to `W_max` if there are no further
    /// congestion events. Computes the cubic `K` using
    /// `K = cubic_root(W_max(1-ß)/C)`.
    private mutating func setCubicK(state: CongestionControlState, mss: Int) {
        guard cubicMaxCongestionWindow != 0 else {
            cubicK = 0
            return
        }
        var K = Double(cubicMaxCongestionWindow - state.congestionWindow) / Prague.cFactor
        K = K / Double(mss)
        #if !NETWORK_EMBEDDED
        K = cbrt(K)
        #else
        K = Cubic.cbrtPureSwift(K)
        #endif
        cubicK = K
    }

    private mutating func getCubicTarget(
        state: CongestionControlState,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant
    ) -> UInt64 {
        if cubicEpochStart == .zero {
            // If we exit slow start without any packet loss, CUBIC switches to CA
            // where t is the elapsed time since the beginning of the current CA.
            // So, set epoch_start to now here.
            cubicEpochStart = now
            // Set origin_point for the start of epoch
            if state.congestionWindow < cubicMaxCongestionWindow {
                cubicOriginPoint = cubicMaxCongestionWindow
                setCubicK(state: state, mss: mss)
            } else {
                cubicOriginPoint = state.congestionWindow
                cubicK = 0
            }
            // Reset reno_cwnd to be in sync with cubic
            renoCongestionWindow = state.congestionWindow
            renoAcked = 0
        }

        // Compute target cubic window W(t+RTT) for the next RTT using,
        // W(t) = C(t-K)^3 + W_max
        let elapsedTime = cubicEpochStart.duration(to: now)
        var W = Double((elapsedTime + smoothedRTT).seconds) - cubicK
        W *= W * W * Prague.cFactor * Double(mss)

        let cwnd = Double(cubicOriginPoint) + W
        let wCubicNext = cwnd > 0 ? UInt64(cwnd) : 0
        return wCubicNext
    }

    private mutating func updateRenoCongestionWindow(bytesAcked: UInt64, mss: Int) {
        // Compute Reno Friendly window using,
        // W_est(t) = W_max*ß + [3*(1-ß)/(1+ß)] * (bytes_acked/reno_cwnd)
        renoAcked += bytesAcked
        var alphaAIMD: Double = 0
        if renoCongestionWindow < cubicMaxCongestionWindow {
            alphaAIMD = 3 * Prague.oneSubBeta / Prague.oneAddBeta
        } else {
            alphaAIMD = 1
        }
        renoCongestionWindow += UInt64(
            alphaAIMD * Double(bytesAcked) * Double(mss) / Double(renoCongestionWindow)
        )
    }

    /// Handles an ACK in the congestion-avoidance phase after packet loss.
    private mutating func cubicProcessAckCA(
        state: inout CongestionControlState,
        bytesAcked: UInt64,
        smoothedRTT: NetworkDuration,
        mss: Int,
        now: NetworkClock.Instant
    ) {
        cubicAcked += bytesAcked

        // compute W(t+RTT)
        let wCubicNext = getCubicTarget(state: state, mss: mss, smoothedRTT: smoothedRTT, now: now)

        updateRenoCongestionWindow(bytesAcked: bytesAcked, mss: mss)

        if state.congestionWindow < wCubicNext {
            // Either concave or convex region
            // Total increase in 1RTT is (W(t+RTT) - cwnd).
            // To get increase per ACK, multiply by (bytes_acked / cwnd)
            let incr =
                Double(wCubicNext - state.congestionWindow)
                * Double(cubicAcked) / Double(state.congestionWindow)
            state.congestionWindow += min(UInt64(incr), Prague.initialCongestionWindow(mss))
            cubicAcked = 0
        }
        if state.congestionWindow < renoCongestionWindow {
            // TCP friendly region
            state.congestionWindow = renoCongestionWindow
            // When the cwnd is set based on Reno-Friendly region,
            // we should reset the cubic_acked counter as we
            // have already used bytes acked equivalent to
            // reno_acked for Reno-Friendly cwnd.
            cubicAcked = cubicAcked > renoAcked ? cubicAcked - renoAcked : 0
            renoAcked = 0
        }
        // Set W_max to cwnd to keep updating our current estimate of W_max
        // as we are probing for new limits at the start of connection
        if numCongestionEventsLoss == 0 {
            cubicMaxCongestionWindow = state.congestionWindow
        }
    }

    /// Computes RTT independence using the square of the RTT ratio to achieve rate fairness.
    ///
    /// Note that this loses scalable marking (one or two marks per RTT) for low RTT.
    /// For additive increase, `alpha = (RTT / REF_RTT) ^ 2`.
    private mutating func pragueAIAlphaRate(sRTT: NetworkDuration) {
        if sRTT > Prague.referenceRTTRate {
            alphaAI = 1 << Prague.congestionWindowShift
            return
        }

        let sRTTMicroseconds = UInt64(sRTT.microseconds)
        let referenceRTTMicroseconds = UInt64(Prague.referenceRTTRate.microseconds)
        let numer = sRTTMicroseconds << Prague.congestionWindowShift * sRTTMicroseconds
        let divisor = referenceRTTMicroseconds * referenceRTTMicroseconds

        alphaAI = (numer + (divisor >> 1)) / divisor
    }

    /// Achieves a balance between throughput equivalence and scalable marking every RTT.
    ///
    /// For additive increase, `alpha = C * lg(R/R0+2) / lg(R0/R+2)`.
    private mutating func pragueAIAlphaScalable(sRTT: NetworkDuration) {
        // If we don't have a SRTT, set to 1
        if sRTT == .zero {
            alphaAI = 1 << Prague.congestionWindowShift
            return
        }

        #if !NETWORK_EMBEDDED
        let sRTTMicroseconds = Double(sRTT.microseconds)
        let refRTTMicroseconds = Double(Prague.referenceRTTScalable.microseconds)
        var numer: Double = 0.72  // constant C
        numer *= log2(sRTTMicroseconds + 2 * refRTTMicroseconds) - log2(refRTTMicroseconds)
        let divisor = log2(refRTTMicroseconds + 2 * sRTTMicroseconds) - log2(sRTTMicroseconds)

        // Multiply by 10^6 (~1048576) to get 6 decimal point precision
        alphaAI = UInt64((numer / divisor) * Double(Prague.scalableCongestionWindowFactor))
        #else
        alphaAI = 1 << Prague.congestionWindowShift
        #endif
    }

    /// Handles an ACK in the congestion-avoidance phase after the decrease caused by CE.
    private mutating func pragueCAAfterCE(state: inout CongestionControlState, bytesAcked: UInt64, mss: Int) {
        var increase = bytesAcked * UInt64(mss) * alphaAI
        increase = (increase + (state.congestionWindow >> 1)) / state.congestionWindow
        state.congestionWindow += increase >> Prague.congestionWindowShift
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

    mutating func enterRecovery(
        state: inout CongestionControlState,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        log.datapath("Entering Recovery: current cwin=\(state.congestionWindow)")
        state.recoveryStartTime = now
        cubicLastMaxCongestionWindow = cubicMaxCongestionWindow
        cubicMaxCongestionWindow = state.congestionWindow

        state.congestionWindow = UInt64(Double(state.lossFlightSize(log: log)) * Prague.beta)
        if _slowPath(state.congestionWindow < Prague.minCongestionWindow(mss)) {
            state.congestionWindow = Prague.minCongestionWindow(mss)
        }
        state.prevSlowStartThreshold = state.slowStartThreshold
        state.slowStartThreshold = state.congestionWindow

        // If Fast Convergence is supported, release more bandwidth
        // if saturation point is getting reduced due to new flows
        if cubicMaxCongestionWindow < cubicLastMaxCongestionWindow {
            cubicMaxCongestionWindow = UInt64(
                max(
                    Double(cubicMaxCongestionWindow) * Prague.oneAddBeta / 2.0,
                    Double(Prague.minCongestionWindow(mss))
                )
            )
        }

        // Set CUBIC window increase state
        // Compute epoch period K(s) that the window will take to increase
        // to last_max again after backoff due to loss.
        // Note that K = 0 if we enter CA without loss.
        setCubicK(state: state, mss: mss)
        // Set the start of current CA and the origin point
        cubicEpochStart = now
        cubicOriginPoint = cubicMaxCongestionWindow
        // Reset renoCongestionWindow to be in sync with Prague
        renoCongestionWindow = state.congestionWindow
        renoAcked = 0

        numCongestionEventsLoss += 1
        reducedDueToCE = false
        state.initPipeAckSamples()
        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .recovery, trigger: nil)
    }

    /// Enters CWR for one RTT after receiving an ACK with new CE counts.
    private mutating func pragueCWR(
        state: inout CongestionControlState,
        largestAckedSentTime: NetworkClock.Instant,
        mss: Int,
        qlog: QLog? = nil
    ) {
        numCongestionEventsCE += 1

        // If the packet was sent before recovery started, do nothing
        if state.packetInRecovery(sentTime: largestAckedSentTime) {
            return
        }

        let alpha = scaledAlpha >> Prague.gShift

        // For Prague, the recovery time is only set during packet
        // loss and we allow any ACKs that don't have CE marks to
        // increase cwnd during ack_end, even in CWR state.
        //
        // On entering CWR, cwnd = cwnd * (1 - DCTCP.alpha) / 2
        let reduction = (state.congestionWindow * alpha) >> (Prague.alphaShift + 1)
        state.congestionWindow -= reduction

        // Should be at least 2 MSS
        if _slowPath(state.congestionWindow < Prague.minCongestionWindow(mss)) {
            state.congestionWindow = Prague.minCongestionWindow(mss)
        }
        state.slowStartThreshold = state.congestionWindow

        reducedDueToCE = true

        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .cwr, trigger: nil)
    }

    /// Updates alpha after receiving acknowledgments.
    private mutating func pragueUpdateAlpha(
        state: inout CongestionControlState,
        largestSentPN: Int64,
        largestAckedPN: Int64,
        packetsMarked: UInt64,
        packetsAcked: UInt64
    ) {
        if !state.rttElapsed(largestSentPN: largestSentPNForAlpha, largestAckedPN: largestAckedPN) {
            // One RTT hasn't elapsed yet, don't update alpha
            log.datapath("One RTT hasn't elapsed, not updating alpha")
            return
        }

        var newlyMarked: UInt64 = 0
        var newlyAcked: UInt64 = 0

        if packetsMarked > state.packetsMarked {
            newlyMarked = packetsMarked - state.packetsMarked
        }

        if packetsAcked > state.packetsAcked {
            newlyAcked = packetsAcked - state.packetsAcked
        } else {
            log.error("No new packets were ACK'ed, we shouldn't be called")
        }

        var scaledAlphaValue = scaledAlpha

        // We react to local AQM as well as network CE
        // Let p1 be the probability for local congestion marking
        // and p2 be the probability network CE marking. Then,
        // total reaction, p = p1 + p2(1-p1).
        var p1: UInt64 = 0
        if localPktDelta > 0 {
            // Update p1 if we have received local congestion info
            p1 = (UInt64(localCEDelta) << Prague.alphaShift) / UInt64(localPktDelta)

            // Once local feedback is used, reset it.
            localCEDelta = 0
            localPktDelta = 0
        }
        let p2 = (newlyMarked << Prague.alphaShift) / newlyAcked
        let p = p1 + p2 * (1 - p1)

        // Equation for alpha,
        // alpha = (1 - g) * alpha + g * F (fraction of marked / acked)
        // alpha = alpha - (alpha >> g_shift) + (marked << (alpha_shift - g_shift)) / acked, OR
        // scaled_alpha = scaled_alpha - (scaled_alpha >> g_shift) + (marked << alpha_shift) / acked
        scaledAlphaValue = scaledAlphaValue - (scaledAlphaValue >> Prague.gShift) + p
        scaledAlpha = min(Prague.maxAlpha << Prague.gShift, scaledAlphaValue)

        // New round for alpha
        largestSentPNForAlpha = largestSentPN
        state.packetsMarked = packetsMarked
        state.packetsAcked = packetsAcked
    }

    private mutating func pragueCongestionEvent(
        state: inout CongestionControlState,
        sentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        // If the packet was sent before recovery started, do nothing
        if state.packetInRecovery(sentTime: sentTime) {
            return false
        }

        enterRecovery(state: &state, mss: mss, now: now, qlog: qlog)
        return true
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
        let reducedCongestionWindow = pragueCongestionEvent(
            state: &state,
            sentTime: largestLostSentTime,
            mss: mss,
            now: now,
            qlog: qlog
        )
        updatePacerState(state: state, path: path, smoothedRTT: smoothedRTT)
        return reducedCongestionWindow
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
            state.congestionWindow += min(state.bytesAcked, Prague.slowStartCongestionWindow(mss))
        } else {
            if reducedDueToCE {
                pragueCAAfterCE(state: &state, bytesAcked: state.bytesAcked, mss: mss)
            } else {
                cubicProcessAckCA(
                    state: &state,
                    bytesAcked: state.bytesAcked,
                    smoothedRTT: smoothedRTT,
                    mss: mss,
                    now: now
                )
            }
        }

        // Should be a minimum of 2*MSS
        if _slowPath(state.congestionWindow < Prague.minCongestionWindow(mss)) {
            state.congestionWindow = Prague.minCongestionWindow(mss)
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

        // Update alpha of fraction of marked packets,
        // even when there are no new CE counts
        if packetsAcked > Int(state.packetsAcked) {
            pragueUpdateAlpha(
                state: &state,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                packetsMarked: UInt64(ceCount),
                packetsAcked: UInt64(packetsAcked)
            )
        }

        if ceCount == state.ecnCECounter {
            // No change in CE
            return
        }

        log.datapath(
            "\(state.bytesAcked) bytes were ACKed with \(ceCount - state.ecnCECounter) packets newly CE marked"
        )

        // Received an ACK with new CE counts, subtract CE marked bytes
        // from bytes_acked, so that we use only unmarked bytes to
        // increase cwnd during ack_end
        let ceBytes = UInt64(ceCount - state.ecnCECounter) * UInt64(mss)
        if state.bytesAcked > ceBytes {
            state.bytesAcked -= ceBytes
        } else {
            state.bytesAcked = 0
        }

        // Update CE count even if we are already in CWR
        state.ecnCECounter = ceCount

        // Update AIMD alpha as SRTT might have changed
        if rttControl == .rateEquivalence {
            pragueAIAlphaRate(sRTT: smoothedRTT)
        } else if rttControl == .balanceRateScalable {
            pragueAIAlphaScalable(sRTT: smoothedRTT)
        }

        if !state.rttElapsed(largestSentPN: state.largestSentPN, largestAckedPN: largestAckedPN) {
            // Haven't elapsed one RTT yet from last CWR
            log.datapath("Haven't elapsed one RTT yet from last CWR")
            return
        }

        // Enter or stay in CWR if new counts are received
        pragueCWR(state: &state, largestAckedSentTime: largestAckedSentTime, mss: mss, qlog: qlog)

        // Update pacer state as cwnd has changed
        updatePacerState(state: state, path: path, smoothedRTT: smoothedRTT)

        // Start new round for CWR
        state.largestSentPN = largestSentPN
    }

    mutating func spuriousRetransmit(state: inout CongestionControlState, qlog: QLog? = nil) {
        guard cubicMaxCongestionWindow > 0 && state.prevSlowStartThreshold > 0 else { return }

        // Revert to the state before loss was detected
        state.congestionWindow = max(cubicMaxCongestionWindow, state.congestionWindow)
        state.slowStartThreshold = state.prevSlowStartThreshold
        state.logUpdate(log: log, qlog: qlog)
    }

    mutating func persistentCongestion(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        // Set the minimum congestion window
        let newCWND = Prague.minCongestionWindow(mss)
        state.slowStartThreshold = max(UInt64(Double(state.congestionWindow) * Prague.beta), newCWND)
        state.congestionWindow = newCWND
        state.logUpdate(log: log, qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: .persistentCongestion)
    }

    private mutating func resetInternal(state: inout CongestionControlState) {
        state.recoveryStartTime = .zero
        state.prevSlowStartThreshold = 0
        numCongestionEventsLoss = 0
        numCongestionEventsCE = 0

        // CUBIC state
        cubicK = 0
        cubicAcked = 0
        cubicEpochStart = .zero
        cubicOriginPoint = 0
        cubicLastMaxCongestionWindow = 0
        cubicMaxCongestionWindow = state.congestionWindow

        // Prague state
        rttControl = .rateEquivalence
        alphaAI = 1 << Prague.congestionWindowShift

        // CWV state
        state.pipeAckSampleEnd = .zero
        state.initPipeAckSamples()
    }

    mutating func idleTimeout(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        // We want to ideally begin with slow start after idle period.
        // Set it to the larger of its current value, MAX (cwnd * Beta, IW)
        state.slowStartThreshold = max(
            state.slowStartThreshold,
            max(UInt64(Double(state.congestionWindow) * Prague.beta), Prague.initialCongestionWindow(mss))
        )
        // Set cwnd to initial cwnd
        state.congestionWindow = min(state.congestionWindow, Prague.initialCongestionWindow(mss))
        state.logUpdate(log: log, qlog: qlog)
        resetInternal(state: &state)
    }

    func filloutDataTransferSnapshot(state: CongestionControlState, dataTransferSnapshot: inout DataTransferSnapshot) {
        dataTransferSnapshot.transportCongestionWindow = state.congestionWindow
        dataTransferSnapshot.transportSlowStartThreshold = state.slowStartThreshold
    }

    mutating func reset(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        state.congestionWindow = Prague.initialCongestionWindow(mss)
        state.slowStartThreshold = UInt64.max
        scaledAlpha = Prague.maxAlpha << Prague.gShift
        resetInternal(state: &state)
        state.logUpdate(log: log, qlog: qlog)
    }

    mutating func inherit(
        from: CongestionControlState,
        state: inout CongestionControlState,
        mss: Int,
        qlog: QLog? = nil
    ) {
        // For Prague, the old state will be stale and
        // as it will ramp up quickly in slow start, it
        // is best to start fresh. For congestion window
        // we can use the higher of last cwnd and INITIAL_CWND
        state.bytesInFlight = from.bytesInFlight
        state.congestionWindow = max(from.congestionWindow, Prague.initialCongestionWindow(mss))
        state.slowStartThreshold = UInt64.max
        scaledAlpha = Prague.maxAlpha << Prague.gShift
        resetInternal(state: &state)
        state.logUpdate(log: log, qlog: qlog)
    }
}
#endif
