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

/// The state share by all algorithms Cubic, Ledbats, and Prague
///
/// This is the single, authoritative copy of this state that is used throughout each algorithm
@available(Network 0.1.0, *)
struct CongestionControlState {
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
    var pipeAckSamples: InlineArray<3, UInt64> = .init(repeating: 0)
    var pipeAckValue = UInt64(0)
    var pipeAckSampleEnd = NetworkClock.Instant.zero
    var pipeAckAcked = UInt64(0)
    var pipeAckIndex = 0
    #if DatapathLogging || (!DisableDebugLogging && !DisableDebugLogging)
    let log: LogPrefixer
    #endif

    static let congestionWindowValidationSamples = 3

    func log(
        _ type: LogType,
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        switch type {
        case .datapath:
            #if DatapathLogging
            log.datapath(message(), callingFunction: callingFunction)
            #endif
        case .debug:
            #if !DisableDebugLogging
            log.debug(message(), callingFunction: callingFunction)
            #endif
        case .info:
            #if !DisableDebugLogging
            log.info(message(), callingFunction: callingFunction)
            #endif
        case .error:
            #if !DisableErrorLogging
            log.error(message(), callingFunction: callingFunction)
            #endif
        }
    }

    var availableCongestionWindow: UInt64 {
        if congestionWindow > bytesInFlight {
            return congestionWindow - bytesInFlight
        } else {
            return 0
        }
    }

    func congestionWindowValidated() -> Bool {
        if pipeAckValue == 0 {
            return true
        }
        // In slow-start, congestionWindow increases aggressively and pipeack
        // might be lagging behind. Thus, give it 4x the space.
        if congestionWindow < slowStartThreshold {
            let congestionWindowLimit = congestionWindow >> 2
            if pipeAckValue < congestionWindowLimit {
                log(
                    .datapath,
                    "Congestion window not validated in slow-start, pipeack: \(pipeAckValue), congestionWindow \(congestionWindow)"
                )
                return false
            }
        } else {
            let congestionWindowLimit = congestionWindow >> 1
            if pipeAckValue < congestionWindowLimit {
                log(
                    .datapath,
                    "Congestion window not validated in congestion-avoidance, pipeack: \(pipeAckValue), congestionWindow: \(congestionWindow) "
                )
                return false
            }
        }

        return true
    }

    func lossFlightSize() -> UInt64 {
        if !congestionWindowValidated() {
            return max(pipeAckValue, bytesInFlight)
        } else {
            return congestionWindow
        }
    }

    mutating func incrementBytesInFlight(_ bytesSent: Int) {
        bytesInFlight += UInt64(bytesSent)
        log(.datapath, "Bytes in flight updated to \(bytesInFlight)")

        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    mutating func decrementBytesInFlight(_ bytes: UInt64) {
        let result = bytesInFlight.subtractingReportingOverflow(bytes)
        if result.overflow {
            log(.error, "Undeflow, \(bytes) decremented from \(bytesInFlight)")
            bytesInFlight = 0
        } else {
            bytesInFlight = result.partialValue
        }
        log(.datapath, "Bytes in flight updated to \(bytesInFlight)")
        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    func packetInRecovery(sentTime: NetworkClock.Instant) -> Bool {
        sentTime <= recoveryStartTime
    }

    mutating func ackBegin() {
        bytesAcked = 0
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        let bytesAcked = UInt64(bytesAcked)
        decrementBytesInFlight(bytesAcked)
        if packetInRecovery(sentTime: sentTime) {
            // Dont update the congestion window
            log(.datapath, "Packet was sent before recovery, ignore")
            return
        }
        // Congestion window is updated later in ackEnd
        self.bytesAcked += bytesAcked
    }

    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        incrementBytesInFlight(bytesSent)
        logUpdate(qlog: qlog)
    }

    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        decrementBytesInFlight(UInt64(bytesSent))
        logUpdate(qlog: qlog)
    }

    mutating func mssChanged(mss: Int, qlog: QLog? = nil) {
        congestionWindow = max(congestionWindow, UInt64(mss))
        logUpdate(qlog: qlog)
    }

    // Compute if 1RTT or 1 round has elapsed by measuring if the
    // packet sent after this instant has been acknowledged.
    // largest_sent_pn is set at the start of a round
    func rttElapsed(largestSentPN: Int64, largestAckedPN: Int64) -> Bool {
        // A packet with pn higher than largest sent pn at
        // the start of the round has been acknowledged
        (largestSentPN == 0) || (largestAckedPN > largestSentPN)
    }

    mutating func initPipeAckSamples() {
        assert(Self.congestionWindowValidationSamples == 3, "pipeAckSamples count should be 3")
        pipeAckSamples = .init(repeating: 0)
        pipeAckIndex = 0
        pipeAckValue = 0
    }

    mutating func setPipeAckSample(sample: UInt64) {
        assert(Self.congestionWindowValidationSamples == 3, "pipeAckSamples count should be 3")
        pipeAckSamples[pipeAckIndex] = sample
        pipeAckIndex &+= 1
        pipeAckIndex = pipeAckIndex % Self.congestionWindowValidationSamples
    }

    mutating func pipeAckNewRound(target: NetworkClock.Instant) {
        pipeAckSampleEnd = target == .zero ? .init(microseconds: 1) : target
        pipeAckAcked = 0
    }

    mutating func updatePipeAckSamples() {
        assert(Self.congestionWindowValidationSamples == 3, "pipeAckSamples count should be 3")
        setPipeAckSample(sample: pipeAckAcked)
        pipeAckValue = pipeAckAcked
        for index in 0..<Self.congestionWindowValidationSamples {
            if pipeAckSamples[index] > pipeAckValue {
                pipeAckValue = pipeAckSamples[index]
            }
        }
    }

    mutating func revalidateCongestionWindow(
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
    ) -> Bool {
        if pipeAckSampleEnd == .zero {
            pipeAckNewRound(target: now.advanced(by: smoothedRTT))
        }
        pipeAckAcked += bytesAcked
        // A full period passed? Update our pipeack samples
        if now > pipeAckSampleEnd {
            let period = pipeAckSampleEnd.duration(to: now)
            if period > smoothedRTT {
                // More than 1 RTT of inactivity, we need to set samples to 0
                setPipeAckSample(sample: 0)
                if period > smoothedRTT * 2 {
                    // Reset the next sample as well
                    setPipeAckSample(sample: 0)
                }
            }
            updatePipeAckSamples()
            pipeAckNewRound(target: now + smoothedRTT)
        }
        return congestionWindowValidated()
    }

    func canSend(packetLength: Int) -> Bool {
        if availableCongestionWindow >= packetLength {
            log(
                .datapath,
                "Can send packet because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) <= congestionWindow \(congestionWindow)"
            )
            return true
        } else {
            log(
                .datapath,
                "Congestion limited because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) > congestionWindow \(congestionWindow)"
            )
            QUICSignpost.congestionWindowLimited(
                bytesInFlight: Int(bytesInFlight),
                congestionWindow: Int(congestionWindow)
            )
            return false
        }
    }

    func logUpdate(qlog: QLog?) {
        if congestionWindow != UInt64.max {
            log(.datapath, "Congestion window set to \(congestionWindow) bytes, bytes in flight \(bytesInFlight)")
            QUICSignpost.congestionWindow(congestionWindow: Int(congestionWindow))
        }
        #if QlogOutput
        if let qlog {
            qlog.congestionControlUpdated(
                congestionWindow: congestionWindow,
                bytesInFlight: bytesInFlight,
                slowStartThresh: slowStartThreshold
            )
        }
        #endif
    }

    init(logPrefixer: LogPrefixer) {
        #if DatapathLogging || (!DisableDebugLogging && !DisableDebugLogging)
        self.log = logPrefixer
        #endif
    }
}

/// Owns the shared congestion control state plus the active algorithm
@available(Network 0.1.0, *)
struct CongestionControl: ~Copyable {
    enum Algorithm {
        case cubic(algorithm: Cubic)
        #if !NETWORK_EMBEDDED
        case ledbat(algorithm: Ledbat)
        case prague(algorithm: Prague)
        #endif
    }

    var state: CongestionControlState
    var algorithm: Algorithm

    init(state: CongestionControlState, algorithm: Algorithm) {
        self.state = state
        self.algorithm = algorithm
    }

    var congestionWindow: UInt64 {
        state.congestionWindow
    }

    var availableCongestionWindow: UInt64 {
        state.availableCongestionWindow
    }

    var bytesInFlight: UInt64 {
        state.bytesInFlight
    }

    var name: String {
        switch algorithm {
        case .cubic:
            return "CUBIC"
        #if !NETWORK_EMBEDDED
        case .ledbat:
            return "LEDBAT"
        case .prague:
            return "PRAGUE"
        #endif
        }
    }

    func canSend(packetLength: Int) -> Bool {
        state.canSend(packetLength: packetLength)
    }

    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        state.packetSent(bytesSent: bytesSent, qlog: qlog)
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        state.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
    }

    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        state.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
    }

    mutating func ackBegin() {
        state.ackBegin()
    }

    mutating func mssChanged(mss: Int) {
        state.mssChanged(mss: mss, qlog: nil)
    }

    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        switch algorithm {
        case .cubic(var cubic):
            cubic.persistentCongestion(state: &state, mss: mss, qlog: qlog)
            algorithm = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.persistentCongestion(state: &state, mss: mss, qlog: qlog)
            algorithm = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.persistentCongestion(state: &state, mss: mss, qlog: qlog)
            algorithm = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        switch algorithm {
        case .cubic(var cubic):
            cubic.ackEnd(state: &state, rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            algorithm = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.ackEnd(state: &state, rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            algorithm = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.ackEnd(state: &state, rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            algorithm = .prague(algorithm: prague)
        #endif
        }
    }

    @discardableResult
    mutating func packetsLost(
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant
    ) -> Bool {
        switch algorithm {
        case .cubic(var cubic):
            let reducedCongestionWindow = cubic.packetLost(
                state: &state,
                path: path,
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
            algorithm = .cubic(algorithm: cubic)
            return reducedCongestionWindow
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            let reducedCongestionWindow = ledbat.packetLost(
                state: &state,
                path: path,
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
            algorithm = .ledbat(algorithm: ledbat)
            return reducedCongestionWindow
        case .prague(var prague):
            let reducedCongestionWindow = prague.packetLost(
                state: &state,
                path: path,
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
            algorithm = .prague(algorithm: prague)
            return reducedCongestionWindow
        #endif
        }
    }

    mutating func processECN(
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
        switch algorithm {
        case .cubic(var cubic):
            cubic.processECN(
                state: &state,
                path: path,
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now,
                qlog: qlog
            )
            algorithm = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.processECN(
                state: &state,
                path: path,
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now,
                qlog: qlog
            )
            algorithm = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.processECN(
                state: &state,
                path: path,
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now,
                qlog: qlog
            )
            algorithm = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        switch algorithm {
        case .cubic(var cubic):
            cubic.spuriousRetransmit(state: &state, qlog: qlog)
            algorithm = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.spuriousRetransmit(state: &state, qlog: qlog)
            algorithm = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.spuriousRetransmit(state: &state, qlog: qlog)
            algorithm = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func idleTimeout(mss: Int) {
        switch algorithm {
        case .cubic(var cubic):
            cubic.idleTimeout(state: &state, mss: mss, qlog: nil)
            algorithm = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.idleTimeout(state: &state, mss: mss, qlog: nil)
            algorithm = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.idleTimeout(state: &state, mss: mss, qlog: nil)
            algorithm = .prague(algorithm: prague)
        #endif
        }
    }

    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        switch algorithm {
        case .cubic(let cubic):
            cubic.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        #if !NETWORK_EMBEDDED
        case .ledbat(let ledbat):
            ledbat.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        case .prague(let prague):
            prague.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        #endif
        }
    }
}

@available(Network 0.1.0, *)
protocol CongestionControlProtocol {
    mutating func inherit(
        from: CongestionControlState,
        state: inout CongestionControlState,
        mss: Int,
        qlog: QLog?
    )
    mutating func reset(state: inout CongestionControlState, mss: Int, qlog: QLog?)
    mutating func ackEnd(
        state: inout CongestionControlState,
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func spuriousRetransmit(state: inout CongestionControlState, qlog: QLog?)
    mutating func idleTimeout(state: inout CongestionControlState, mss: Int, qlog: QLog?)
    /// Opens a recovery period at `now`, the time the loss was detected.
    mutating func enterRecovery(state: inout CongestionControlState, mss: Int, now: NetworkClock.Instant, qlog: QLog?)
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
        qlog: QLog?
    )
    mutating func packetLost(
        state: inout CongestionControlState,
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog?
    ) -> Bool
    mutating func persistentCongestion(state: inout CongestionControlState, mss: Int, qlog: QLog?)
    func filloutDataTransferSnapshot(state: CongestionControlState, dataTransferSnapshot: inout DataTransferSnapshot)
}

@available(Network 0.1.0, *)
extension CongestionControlProtocol {
    mutating func packetSent(state: inout CongestionControlState, bytesSent: Int, qlog: QLog? = nil) {
        state.packetSent(bytesSent: bytesSent, qlog: qlog)
    }

    mutating func packetDiscarded(state: inout CongestionControlState, bytesSent: Int, qlog: QLog? = nil) {
        state.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
    }

    mutating func ackBegin(state: inout CongestionControlState) {
        state.ackBegin()
    }

    mutating func packetsAcked(state: inout CongestionControlState, bytesAcked: Int, sentTime: NetworkClock.Instant) {
        state.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
    }

    mutating func mssChanged(state: inout CongestionControlState, mss: Int, qlog: QLog? = nil) {
        state.mssChanged(mss: mss, qlog: qlog)
    }

    func canSend(state: CongestionControlState, packetLength: Int) -> Bool {
        state.canSend(packetLength: packetLength)
    }

    /// `sentTime` is when the packet went out, `now` when its loss was detected.
    @discardableResult
    mutating func congestionEvent(
        state: inout CongestionControlState,
        sentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        // If the packet was sent before recovery started, do nothing
        if state.packetInRecovery(sentTime: sentTime) { return false }
        // Enter recovery if the packet was sent
        // after start of the previous recovery period
        enterRecovery(state: &state, mss: mss, now: now, qlog: qlog)
        return true
    }

    mutating func linkFlowControl(
        state: inout CongestionControlState,
        largestAckSentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        congestionEvent(state: &state, sentTime: largestAckSentTime, mss: mss, now: now, qlog: qlog)
        state.log(
            .debug,
            "Link was flow controlled, reduced congestion window is \(state.congestionWindow) bytes"
        )
    }

    func logState(
        qlog: QLog? = nil,
        state: QLogCongestionState,
        trigger: QLogCongestionTrigger?
    ) {
        #if QlogOutput
        if let qlog {
            qlog.logCongestionStateUpdated(
                oldState: nil,
                newState: state,
                trigger: trigger
            )
        }
        #endif
    }
}
#endif
