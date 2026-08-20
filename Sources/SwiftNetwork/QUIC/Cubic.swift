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

    var congestionWindow = UInt64(0)
    var bytesInFlight = UInt64(0)
    var packetsAcked = UInt64(0)
    var packetsMarked = UInt64(0)
    var ecnCECounter = 0
    var largestSentPN = Int64(0)
    var slowStartThreshold = UInt64.max
    var prevSlowStartThreshold = UInt64.max
    var recoveryStartTime = NetworkClock.Instant.zero
    var bytesAcked = UInt64(0)
    var pipeAckSamples = [UInt64(0)]
    var pipeAckValue = UInt64(0)
    var pipeAckSampleEnd = NetworkClock.Instant.zero
    var pipeAckAcked = UInt64(0)
    var pipeAckIndex = 0

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

    init(pacer: inout Pacer, mss: Int, qlog: QLog? = nil, logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        reset(mss: mss, qlog: qlog)
        if pacer.enabled {
            let startupRate =
                congestionWindow * System.Time.USEC_PER_SEC / UInt64(pacingInitialRTT.microseconds)
            let startupBurstSize = UInt64(mss)
            pacer.setInitialState(startupRate, UInt32(truncatingIfNeeded: startupBurstSize))
            pacer.reset()
        }
        logUpdate(qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: nil)
    }

    private mutating func setK(mss: Int) {
        // K is the time period(s) that WCubic(t) function takes to increase
        // the current window size to WMax if there are no further
        // congestion events. Compute the cubic K using,
        // K = cubic_root(WMax(1-ß)/C)
        guard maxCongestionWindow > 0 else {
            K = 0
            return
        }
        guard maxCongestionWindow > congestionWindow else {
            K = 0
            if maxCongestionWindow < congestionWindow {
                // Log a fault for underflow cases. Don't log if it would just be zero.
                let maxCongestionWindow = maxCongestionWindow
                let congestionWindow = congestionWindow
                Logger.proto.fault(
                    "Max congestion window \(maxCongestionWindow) should be greater than congestion window \(congestionWindow)"
                )
            }
            return
        }

        K = Double(maxCongestionWindow - congestionWindow) / Cubic.cFactor
        K = K / Double(mss)
        #if !NETWORK_EMBEDDED
        K = cbrt(K)
        #else
        K = Cubic.cbrtPureSwift(K)
        #endif
    }

    private mutating func getTarget(mss: Int, smoothedRTT: NetworkDuration) -> UInt64 {
        let now = NetworkClock.Instant.now
        if epochStart == .zero {
            // If we exit slow start without any packet
            // loss, CUBIC switches to CA where t is the elapsed
            // time since the beginning of the current CA. So, set
            // epochStart to now here.
            epochStart = now
            // Set originPoint for the start of epoch
            if congestionWindow < maxCongestionWindow {
                originPoint = maxCongestionWindow
                setK(mss: mss)
            } else {
                originPoint = congestionWindow
                K = 0
            }
            // Reset tcpCongestionWindow to be in sync with cubic
            tcpCongestionWindow = congestionWindow
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
        bytesAcked: UInt64,
        smoothedRTT: NetworkDuration,
        mss: Int
    ) {
        totalAcked += bytesAcked
        // compute W(t+RTT)
        let WCubicNext = getTarget(mss: mss, smoothedRTT: smoothedRTT)
        updateTCPWindow(bytesAcked: bytesAcked, mss: mss)
        if congestionWindow < WCubicNext {
            // Either concave or convex region
            // Total increase in 1RTT is (W(t+RTT) - congestionWindow).
            // To get increase per ACK, multiply by (bytesAcked / congestionWindow)
            let incr =
                Double((WCubicNext - congestionWindow))
                * (Double(totalAcked) / Double(congestionWindow))
            congestionWindow += min(UInt64(incr), Cubic.initialCongestionWindow(mss))
            totalAcked = 0
        }
        if congestionWindow < tcpCongestionWindow {
            // TCP friendly region
            congestionWindow = tcpCongestionWindow
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
            maxCongestionWindow = congestionWindow
        }
    }

    private mutating func updatePacerState(path: QUICPath? = nil, smoothedRTT: NetworkDuration) {
        guard let path, path.pacer.enabled else {
            return
        }

        // Zero microseconds means either that no measurement has landed yet or that one rounded
        // down from under half a microsecond, and dividing by it below would trap. Fall back to the
        // initial estimate in both cases.
        let smoothedRTTInMicroseconds =
            smoothedRTT.microseconds == 0 ? pacingInitialRTT.microseconds : smoothedRTT.microseconds

        var rate = congestionWindow

        // Use 200% rate when in slow start
        if congestionWindow < slowStartThreshold {
            rate *= 2
        }
        rate = (rate * System.Time.USEC_PER_SEC) / UInt64(smoothedRTTInMicroseconds)
        let burst = rate >> burstQueueShift
        path.pacer.setRate(rate: rate)
        path.pacer.setBurstSize(burstSize: UInt32(truncatingIfNeeded: burst))
    }

    @discardableResult
    mutating func packetLost(
        path: QUICPath? = nil,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        qlog: QLog? = nil
    ) -> Bool {
        decrementBytesInFlight(UInt64(bytesLost))
        let reducedCongestionWindow = congestionEvent(
            sentTime: largestLostSentTime,
            mss: mss,
            qlog: qlog
        )
        updatePacerState(path: path, smoothedRTT: smoothedRTT)
        return reducedCongestionWindow
    }

    mutating func enterRecovery(mss: Int, qlog: QLog? = nil) {
        log.datapath("Entering Recovery: current cwin=\(congestionWindow)")
        let timeNow = NetworkClock.Instant.now
        recoveryStartTime = timeNow
        lastMaxCongestionWindow = maxCongestionWindow
        maxCongestionWindow = congestionWindow
        congestionWindow = UInt64(Double(lossFlightSize) * Cubic.beta)
        if _slowPath(congestionWindow < Cubic.minCongestionWindow(mss)) {
            congestionWindow = UInt64(Cubic.minCongestionWindow(mss))
        }
        prevSlowStartThreshold = slowStartThreshold
        slowStartThreshold = congestionWindow
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
        setK(mss: mss)
        // Set the start of current congestion avoidance and the origin point
        epochStart = timeNow
        originPoint = maxCongestionWindow
        // Reset tcpCongestionWindow to be in sync with cubic
        tcpCongestionWindow = congestionWindow
        tcpTotalAcked = 0
        numCongestionEvents += 1
        initPipeAckSamples()
        logUpdate(qlog: qlog)
        logState(qlog: qlog, state: .recovery, trigger: nil)
    }

    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath? = nil,
        mss: Int,
        packetsLost: Bool,
        qlog: QLog? = nil
    ) {
        if packetsLost {
            // one or more packets were marked lost during
            // this ACK processing
            return
        }
        if bytesAcked == 0 {
            // When we are in recovery period or received new CE counts
            return
        }
        let smoothedRTT = rtt.smoothedRTT
        if !revalidateCongestionWindow(smoothedRTT: smoothedRTT) {
            bytesAcked = 0
            return
        }
        if congestionWindow < slowStartThreshold {
            congestionWindow += min(
                bytesAcked,
                Cubic.slowStartCongestionWindow(mss)
            )
        } else {
            processAckCongestionAvoidance(
                bytesAcked: bytesAcked,
                smoothedRTT: smoothedRTT,
                mss: mss
            )
        }
        // Should be a minimum of 2*MSS
        if _slowPath(congestionWindow < Cubic.minCongestionWindow(mss)) {
            congestionWindow = Cubic.minCongestionWindow(mss)
        }
        updatePacerState(path: path, smoothedRTT: smoothedRTT)
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
        qlog: QLog? = nil
    ) {
        if _slowPath(ceCount < ecnCECounter) {
            log.fault(
                "New CE count \(ceCount) can't be less than current CE count \(ecnCECounter)"
            )
        }
        // Update packets acked and marked on every ACK, even if it
        // is not used by CUBIC. This state is relevant
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

        /* Update CE count even if we are already in CWR */
        ecnCECounter = ceCount

        // Received an ACK with new CE counts, reset bytesAcked so
        // we that we don't increase congestionWindow during ackEnd
        bytesAcked = 0

        if !rttElapsed(
            largestSentPN: self.largestSentPN,
            largestAckedPN: largestAckedPN
        ) {
            // Haven't elapsed one RTT yet from last CWR
            return
        }
        congestionEvent(sentTime: largestAckedSentTime, mss: mss, qlog: qlog)
        // Update pacer state as congestionWindow has changed
        updatePacerState(path: path, smoothedRTT: smoothedRTT)
        // Start new round for CWR
        self.largestSentPN = largestSentPN
    }

    mutating func idleTimeout(mss: Int, qlog: QLog? = nil) {
        // We want to ideally begin with slow start after idle period.
        // Set it to the larger of its current value, MAX (congestionWindow * Beta, IW)
        slowStartThreshold = Cubic.idleTimeout(
            slowStartThreshold: slowStartThreshold,
            congestionWindow: congestionWindow,
            mss: mss
        )
        // Set congestionWindow to initial congestion window
        congestionWindow = min(congestionWindow, Cubic.initialCongestionWindow(mss))
        logUpdate(qlog: qlog)
        resetInternal()
    }

    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        slowStartThreshold = Cubic.persistentCongestion(
            congestionWindow: congestionWindow,
            mss: mss
        )
        // Set the minimum congestion window
        congestionWindow = Cubic.minCongestionWindow(mss)
        logUpdate(qlog: qlog)
        logState(qlog: qlog, state: .slowStart, trigger: .persistentCongestion)
    }

    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        guard maxCongestionWindow > 0 && prevSlowStartThreshold > 0 else { return }
        // Revert to the state before loss was detected
        congestionWindow = max(maxCongestionWindow, congestionWindow)
        slowStartThreshold = prevSlowStartThreshold
        logUpdate(qlog: qlog)
    }

    private mutating func resetInternal() {
        recoveryStartTime = .zero
        prevSlowStartThreshold = UInt64.max
        numCongestionEvents = 0
        K = 0
        totalAcked = 0
        epochStart = .zero
        originPoint = 0
        lastMaxCongestionWindow = 0
        maxCongestionWindow = congestionWindow
        // CWV state
        pipeAckSampleEnd = .zero
        initPipeAckSamples()
    }

    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        dataTransferSnapshot.transportCongestionWindow = congestionWindow
        dataTransferSnapshot.transportSlowStartThreshold = slowStartThreshold
    }

    mutating func reset(mss: Int, qlog: QLog? = nil) {
        congestionWindow = Cubic.initialCongestionWindow(mss)
        slowStartThreshold = UInt64.max
        resetInternal()
        logUpdate(qlog: qlog)
    }

    mutating func inherit(from: CongestionControl, mss: Int, qlog: QLog?) {
        // For Cubic, the old state will be stale and
        // as it will ramp up quickly in slow start, it
        // is best to start fresh. For congestion window
        // we can use the higher of last congestionWindow and initialCongestionWindow
        switch from {
        case .cubic(let cubic):
            self.bytesInFlight = cubic.bytesInFlight
            self.congestionWindow = max(cubic.congestionWindow, Cubic.initialCongestionWindow(mss))
        #if !NETWORK_EMBEDDED
        case .ledbat(let ledbat):
            self.bytesInFlight = ledbat.bytesInFlight
            self.congestionWindow = max(ledbat.congestionWindow, Cubic.initialCongestionWindow(mss))
        case .prague(let prague):
            self.bytesInFlight = prague.bytesInFlight
            self.congestionWindow = max(prague.congestionWindow, Cubic.initialCongestionWindow(mss))
        #endif
        }
        slowStartThreshold = UInt64.max
        resetInternal()
        logUpdate(qlog: qlog)
    }
}
#endif
