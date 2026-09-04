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
enum CongestionControl {
    case cubic(algorithm: Cubic)
    #if !NETWORK_EMBEDDED
    case ledbat(algorithm: Ledbat)
    case prague(algorithm: Prague)
    #endif

    var congestionWindow: UInt64 {
        switch self {
        case .cubic(let cubic):
            return cubic.congestionWindow
        #if !NETWORK_EMBEDDED
        case .ledbat(let ledbat):
            return ledbat.congestionWindow
        case .prague(let prague):
            return prague.congestionWindow
        #endif
        }
    }

    var availableCongestionWindow: UInt64 {
        switch self {
        case .cubic(let cubic):
            return cubic.availableCongestionWindow
        #if !NETWORK_EMBEDDED
        case .ledbat(let ledbat):
            return ledbat.availableCongestionWindow
        case .prague(let prague):
            return prague.availableCongestionWindow
        #endif
        }
    }

    func canSend(packetLength: Int) -> Bool {
        switch self {
        case .cubic(let cubic):
            return cubic.canSend(packetLength: packetLength)
        #if !NETWORK_EMBEDDED
        case .ledbat(let ledbat):
            return ledbat.canSend(packetLength: packetLength)
        case .prague(let prague):
            return prague.canSend(packetLength: packetLength)
        #endif
        }
    }

    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        switch self {
        case .cubic(var cubic):
            cubic.persistentCongestion(mss: mss, qlog: qlog)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.persistentCongestion(mss: mss, qlog: qlog)
            self = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.persistentCongestion(mss: mss, qlog: qlog)
            self = .prague(algorithm: prague)
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
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.packetSent(bytesSent: bytesSent, qlog: qlog)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.packetSent(bytesSent: bytesSent, qlog: qlog)
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.packetSent(bytesSent: bytesSent, qlog: qlog)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func packetsLost(
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant
    ) -> Bool {
        switch self {
        case .cubic(algorithm: var cubic):
            let reducedCongestionWindow = cubic.packetLost(
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
            self = .cubic(algorithm: cubic)
            return reducedCongestionWindow
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            let reducedCongestionWindow = ledbat.packetLost(
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
            self = .ledbat(algorithm: ledbat)
            return reducedCongestionWindow
        case .prague(algorithm: var prague):
            let reducedCongestionWindow = prague.packetLost(
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
            self = .prague(algorithm: prague)
            return reducedCongestionWindow
        #endif
        }
    }

    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        switch self {
        case .cubic(var cubic):
            cubic.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
            self = .ledbat(algorithm: ledbat)
        case .prague(var prague):
            prague.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func ackBegin() {
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.ackBegin()
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.ackBegin()
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.ackBegin()
            self = .prague(algorithm: prague)
        #endif
        }
    }

    var bytesInFlight: UInt64 {
        switch self {
        case .cubic(algorithm: let cubic):
            return cubic.bytesInFlight
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: let ledbat):
            return ledbat.bytesInFlight
        case .prague(algorithm: let prague):
            return prague.bytesInFlight
        #endif
        }
    }

    var name: String {
        switch self {
        case .cubic(algorithm: _):
            return "CUBIC"
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: _):
            return "LEDBAT"
        case .prague(algorithm: _):
            return "PRAGUE"
        #endif
        }
    }

    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.spuriousRetransmit(qlog: qlog)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.spuriousRetransmit(qlog: qlog)
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.spuriousRetransmit(qlog: qlog)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func mssChanged(mss: Int) {
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.mssChanged(mss: mss, qlog: nil)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.mssChanged(mss: mss, qlog: nil)
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.mssChanged(mss: mss, qlog: nil)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    mutating func idleTimeout(mss: Int) {
        switch self {
        case .cubic(algorithm: var cubic):
            cubic.idleTimeout(mss: mss, qlog: nil)
            self = .cubic(algorithm: cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: var ledbat):
            ledbat.idleTimeout(mss: mss, qlog: nil)
            self = .ledbat(algorithm: ledbat)
        case .prague(algorithm: var prague):
            prague.idleTimeout(mss: mss, qlog: nil)
            self = .prague(algorithm: prague)
        #endif
        }
    }

    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        switch self {
        case .cubic(algorithm: let cubic):
            cubic.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        #if !NETWORK_EMBEDDED
        case .ledbat(algorithm: let ledbat):
            ledbat.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        case .prague(algorithm: let prague):
            prague.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        #endif
        }
    }
}

@available(Network 0.1.0, *)
protocol CongestionControlProtocol: PrefixedLoggable {
    var congestionWindow: UInt64 { get set }
    var bytesInFlight: UInt64 { get set }
    var packetsAcked: UInt64 { get set }
    var packetsMarked: UInt64 { get set }
    var ecnCECounter: Int { get set }
    var largestSentPN: Int64 { get set }
    var slowStartThreshold: UInt64 { get set }
    var prevSlowStartThreshold: UInt64 { get set }
    var recoveryStartTime: NetworkClock.Instant { get set }
    var bytesAcked: UInt64 { get set }
    var pipeAckSamples: [UInt64] { get set }
    var pipeAckValue: UInt64 { get set }
    var pipeAckSampleEnd: NetworkClock.Instant { get set }
    var pipeAckAcked: UInt64 { get set }
    var pipeAckIndex: Int { get set }

    mutating func inherit(
        from: CongestionControl,
        mss: Int,
        qlog: QLog?
    )
    mutating func reset(mss: Int, qlog: QLog?)
    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func spuriousRetransmit(qlog: QLog?)
    mutating func idleTimeout(mss: Int, qlog: QLog?)
    /// Opens a recovery period at `now`, the time the loss was detected.
    mutating func enterRecovery(mss: Int, now: NetworkClock.Instant, qlog: QLog?)
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
        qlog: QLog?
    )
    mutating func packetLost(
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant,
        qlog: QLog?
    ) -> Bool
    mutating func linkFlowControl(
        largestAckSentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog?
    )
    mutating func persistentCongestion(mss: Int, qlog: QLog?)
    mutating func mssChanged(mss: Int, qlog: QLog?)
    mutating func packetDiscarded(bytesSent: Int, qlog: QLog?)
    mutating func ackBegin()
    mutating func packetSent(bytesSent: Int, qlog: QLog?)
    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant)
}

@available(Network 0.1.0, *)
extension CongestionControlProtocol {
    var congestionWindowValidationSamples: Int {
        3
    }

    var availableCongestionWindow: UInt64 {
        if congestionWindow > bytesInFlight {
            return congestionWindow - bytesInFlight
        } else {
            return 0
        }
    }

    var congestionWindowValidated: Bool {
        if pipeAckValue == 0 {
            return true
        }
        // In slow-start, congestionWindow increases aggressively and pipeack
        // might be lagging behind. Thus, give it 4x the space.
        if congestionWindow < slowStartThreshold {
            let congestionWindowLimit = congestionWindow >> 2
            if pipeAckValue < congestionWindowLimit {
                log.datapath(
                    "congestion window not validated in slow-start, pipeack: \(pipeAckValue), congestionWindow \(congestionWindow)"
                )
                return false
            }
        } else {
            let congestionWindowLimit = congestionWindow >> 1
            if pipeAckValue < congestionWindowLimit {
                log.datapath(
                    "congestion window not validated in congestion-avoidance, pipeack: \(pipeAckValue), congestionWindow: \(congestionWindow) "
                )
                return false
            }
        }

        return true
    }

    var lossFlightSize: UInt64 {
        if !congestionWindowValidated {
            return max(pipeAckValue, bytesInFlight)
        } else {
            return congestionWindow
        }
    }

    mutating private func incrementBytesInFlight(_ bytesSent: Int) {
        bytesInFlight += UInt64(bytesSent)
        log.datapath("bytes in flight updated to \(bytesInFlight)")

        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    mutating func decrementBytesInFlight(_ bytes: UInt64) {
        let result = bytesInFlight.subtractingReportingOverflow(bytes)
        if result.overflow {
            log.fault("undeflow, \(bytes) decremented from \(bytesInFlight)")
            bytesInFlight = 0
        } else {
            bytesInFlight = result.partialValue
        }
        log.datapath("bytes in flight updated to \(bytesInFlight)")
        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    mutating func mssChanged(mss: Int, qlog: QLog? = nil) {
        congestionWindow = max(congestionWindow, UInt64(mss))
        logUpdate(qlog: qlog)
    }

    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        incrementBytesInFlight(bytesSent)
        logUpdate(qlog: qlog)
    }

    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        decrementBytesInFlight(UInt64(bytesSent))
        logUpdate(qlog: qlog)
    }

    mutating func ackBegin() {
        bytesAcked = 0
    }

    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        let bytesAcked = UInt64(bytesAcked)
        decrementBytesInFlight(bytesAcked)
        if packetInRecovery(sentTime: sentTime) {
            // Dont update the congestion window
            log.datapath("packet was sent before recovery, ignore")
            return
        }
        // Congestion window is updated later in ackEnd
        self.bytesAcked += bytesAcked
    }

    func packetInRecovery(sentTime: NetworkClock.Instant) -> Bool {
        sentTime <= recoveryStartTime
    }

    /// `sentTime` is when the packet went out, `now` when its loss was detected.
    @discardableResult
    mutating func congestionEvent(
        sentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) -> Bool {
        // If the packet was sent before recovery started, do nothing
        if packetInRecovery(sentTime: sentTime) { return false }
        // Enter recovery if the packet was sent
        // after start of the previous recovery period
        enterRecovery(mss: mss, now: now, qlog: qlog)
        return true
    }

    mutating func linkFlowControl(
        largestAckSentTime: NetworkClock.Instant,
        mss: Int,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        congestionEvent(sentTime: largestAckSentTime, mss: mss, now: now, qlog: qlog)
        log.debug(
            "Link was flow controlled, reduced congestion window is \(congestionWindow) bytes"
        )
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
        pipeAckSamples = Array(repeating: 0, count: congestionWindowValidationSamples)
        pipeAckIndex = 0
        pipeAckValue = 0
    }

    mutating func setPipeAckSample(sample: UInt64) {
        pipeAckSamples[pipeAckIndex] = sample
        pipeAckIndex &+= 1
        pipeAckIndex = pipeAckIndex % congestionWindowValidationSamples
    }

    mutating func pipeAckNewRound(target: NetworkClock.Instant) {
        pipeAckSampleEnd = target == .zero ? .init(microseconds: 1) : target
        pipeAckAcked = 0
    }

    mutating func updatePipeAckSamples() {
        setPipeAckSample(sample: pipeAckAcked)
        pipeAckValue = pipeAckAcked
        for index in 0..<congestionWindowValidationSamples {
            if pipeAckSamples[index] > pipeAckValue {
                pipeAckValue = pipeAckSamples[index]
            }
        }
    }

    mutating func revalidateCongestionWindow(smoothedRTT: NetworkDuration, now: NetworkClock.Instant) -> Bool {
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
        return congestionWindowValidated
    }

    func canSend(packetLength: Int) -> Bool {
        if availableCongestionWindow >= packetLength {
            log.datapath(
                "can send packet because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) <= congestionWindow \(congestionWindow)"
            )
            return true
        } else {
            log.datapath(
                "congestion limited because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) > congestionWindow \(congestionWindow)"
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
            log.datapath("congestion window set to \(congestionWindow) bytes, bytes in flight \(bytesInFlight)")
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
