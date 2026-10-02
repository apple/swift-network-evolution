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

// An operation on whichever congestion controller is active.
@available(Network 0.1.0, *)
protocol CongestionControlOperation {
    associatedtype Result
    func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) -> Result
}

// A read of whichever congestion controller is active.
@available(Network 0.1.0, *)
protocol CongestionControlQuery {
    associatedtype Result
    func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> Result
}

@available(Network 0.1.0, *)
struct CongestionControl {
    enum Algorithm: UInt8 {
        case cubic
        #if !NETWORK_EMBEDDED
        case ledbat
        case prague
        #endif

        var name: String {
            switch self {
            case .cubic: return "CUBIC"
            #if !NETWORK_EMBEDDED
            case .ledbat: return "LEDBAT"
            case .prague: return "PRAGUE"
            #endif
            }
        }
    }

    private(set) var algorithm: Algorithm
    private var cubic: Cubic
    #if !NETWORK_EMBEDDED
    private var ledbat: Ledbat
    private var prague: Prague
    #endif

    // Placeholder initializer to allow non-Optional types.
    // CongestionControl is supposed to be initialized later.
    init() {
        let logPrefixer = LogPrefixer()
        self.algorithm = .cubic
        self.cubic = Cubic(placeholder: logPrefixer)
        #if !NETWORK_EMBEDDED
        self.ledbat = Ledbat(placeholder: logPrefixer)
        self.prague = Prague(placeholder: logPrefixer)
        #endif
    }

    init(
        algorithm: Algorithm,
        pacer: inout Pacer,
        mss: Int,
        qlog: QLog? = nil,
        logPrefixer: LogPrefixer
    ) {
        self.algorithm = algorithm
        self.cubic = Cubic(placeholder: logPrefixer)
        #if !NETWORK_EMBEDDED
        self.ledbat = Ledbat(placeholder: logPrefixer)
        self.prague = Prague(placeholder: logPrefixer)
        #endif
        // Reset and properly initialize the algorithm.
        reset(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
    }

    // Re-creates the active controller from scratch.
    mutating func reset(pacer: inout Pacer, mss: Int, qlog: QLog?, logPrefixer: LogPrefixer) {
        switch algorithm {
        case .cubic:
            cubic = Cubic(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
        #if !NETWORK_EMBEDDED
        case .ledbat:
            ledbat = Ledbat(mss: mss, qlog: qlog, logPrefixer: logPrefixer)
        case .prague:
            prague = Prague(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
        #endif
        }
    }

    #if !NETWORK_EMBEDDED
    private func handOff<Next: CongestionControlProtocol>(to next: inout Next, mss: Int, qlog: QLog?) {
        switch algorithm {
        case .cubic: next.inherit(from: cubic, mss: mss, qlog: qlog)
        case .ledbat: next.inherit(from: ledbat, mss: mss, qlog: qlog)
        case .prague: next.inherit(from: prague, mss: mss, qlog: qlog)
        }
    }

    // Switches to another algorithm, handing it the outgoing controller's state.
    mutating func switchTo(
        _ newAlgorithm: Algorithm,
        pacer: inout Pacer,
        mss: Int,
        qlog: QLog?,
        logPrefixer: LogPrefixer
    ) {
        guard newAlgorithm != algorithm else { return }
        switch newAlgorithm {
        case .cubic:
            var next = Cubic(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
            handOff(to: &next, mss: mss, qlog: qlog)
            cubic = next
        case .ledbat:
            var next = Ledbat(mss: mss, qlog: qlog, logPrefixer: logPrefixer)
            handOff(to: &next, mss: mss, qlog: qlog)
            ledbat = next
        case .prague:
            var next = Prague(pacer: &pacer, mss: mss, qlog: qlog, logPrefixer: logPrefixer)
            handOff(to: &next, mss: mss, qlog: qlog)
            prague = next
        }
        algorithm = newAlgorithm
    }
    #endif

    // Dispatches a mutating operation on the algorithm.
    @inline(always)
    private mutating func perform<Operation: CongestionControlOperation>(
        _ operation: Operation
    ) -> Operation.Result {
        switch algorithm {
        case .cubic: return operation(&cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat: return operation(&ledbat)
        case .prague: return operation(&prague)
        #endif
        }
    }

    // Dispatches a query operation on the algorithm.
    @inline(always)
    private func inspect<Query: CongestionControlQuery>(_ query: Query) -> Query.Result {
        switch algorithm {
        case .cubic: return query(cubic)
        #if !NETWORK_EMBEDDED
        case .ledbat: return query(ledbat)
        case .prague: return query(prague)
        #endif
        }
    }

    var name: String { algorithm.name }

    var congestionWindow: UInt64 { inspect(Read.CongestionWindow()) }
    var availableCongestionWindow: UInt64 { inspect(Read.AvailableCongestionWindow()) }
    var bytesInFlight: UInt64 { inspect(Read.BytesInFlight()) }
    func canSend(packetLength: Int) -> Bool { inspect(Read.CanSend(packetLength: packetLength)) }

    // `inout` arguments can't be stored in a query, so this one dispatches by hand.
    func filloutDataTransferSnapshot(dataTransferSnapshot: inout DataTransferSnapshot) {
        switch algorithm {
        case .cubic:
            cubic.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        #if !NETWORK_EMBEDDED
        case .ledbat:
            ledbat.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        case .prague:
            prague.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        #endif
        }
    }

    @inline(always)
    mutating func persistentCongestion(mss: Int, qlog: QLog? = nil) {
        perform(Op.PersistentCongestion(mss: mss, qlog: qlog))
    }

    // `RTT` is `~Copyable`, so it can't be stored in an operation; this one dispatches by hand.
    mutating func ackEnd(
        rtt: borrowing RTT,
        path: QUICPath?,
        mss: Int,
        packetsLost: Bool,
        now: NetworkClock.Instant,
        qlog: QLog? = nil
    ) {
        switch algorithm {
        case .cubic:
            cubic.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
        #if !NETWORK_EMBEDDED
        case .ledbat:
            ledbat.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
        case .prague:
            prague.ackEnd(rtt: rtt, path: path, mss: mss, packetsLost: packetsLost, now: now, qlog: qlog)
        #endif
        }
    }

    @inline(always)
    mutating func packetSent(bytesSent: Int, qlog: QLog? = nil) {
        perform(Op.PacketSent(bytesSent: bytesSent, qlog: qlog))
    }

    @inline(always)
    mutating func packetsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        perform(Op.PacketsAcked(bytesAcked: bytesAcked, sentTime: sentTime))
    }

    @inline(always)
    mutating func packetsLost(
        path: QUICPath?,
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        now: NetworkClock.Instant
    ) -> Bool {
        perform(
            Op.PacketsLost(
                path: path,
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                now: now
            )
        )
    }

    @inline(always)
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
        perform(
            Op.ProcessECN(
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
        )
    }

    @inline(always)
    mutating func packetDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        perform(Op.PacketDiscarded(bytesSent: bytesSent, qlog: qlog))
    }

    @inline(always)
    mutating func ackBegin() {
        perform(Op.AckBegin())
    }

    @inline(always)
    mutating func spuriousRetransmit(qlog: QLog? = nil) {
        perform(Op.SpuriousRetransmit(qlog: qlog))
    }

    @inline(always)
    mutating func mssChanged(mss: Int) {
        perform(Op.MSSChanged(mss: mss))
    }

    @inline(always)
    mutating func idleTimeout(mss: Int) {
        perform(Op.IdleTimeout(mss: mss))
    }
}

// MARK: - Operations and queries

@available(Network 0.1.0, *)
extension CongestionControl {
    fileprivate enum Read {
        struct CongestionWindow: CongestionControlQuery {
            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> UInt64 {
                controller.congestionWindow
            }
        }

        struct AvailableCongestionWindow: CongestionControlQuery {
            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> UInt64 {
                controller.availableCongestionWindow
            }
        }

        struct BytesInFlight: CongestionControlQuery {
            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> UInt64 {
                controller.bytesInFlight
            }
        }

        struct CanSend: CongestionControlQuery {
            let packetLength: Int

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: Controller) -> Bool {
                controller.canSend(packetLength: packetLength)
            }
        }
    }

    fileprivate enum Op {
        struct PersistentCongestion: CongestionControlOperation {
            let mss: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.persistentCongestion(mss: mss, qlog: qlog)
            }
        }

        struct PacketSent: CongestionControlOperation {
            let bytesSent: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.packetSent(bytesSent: bytesSent, qlog: qlog)
            }
        }

        struct PacketsAcked: CongestionControlOperation {
            let bytesAcked: Int
            let sentTime: NetworkClock.Instant

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
            }
        }

        struct PacketsLost: CongestionControlOperation {
            let path: QUICPath?
            let bytesLost: Int
            let largestLostSentTime: NetworkClock.Instant
            let mss: Int
            let smoothedRTT: NetworkDuration
            let now: NetworkClock.Instant

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) -> Bool {
                controller.packetLost(
                    path: path,
                    bytesLost: bytesLost,
                    largestLostSentTime: largestLostSentTime,
                    mss: mss,
                    smoothedRTT: smoothedRTT,
                    now: now,
                    qlog: nil
                )
            }
        }

        struct ProcessECN: CongestionControlOperation {
            let path: QUICPath?
            let ceCount: Int
            let packetsAcked: Int
            let largestSentPN: Int64
            let largestAckedPN: Int64
            let largestAckedSentTime: NetworkClock.Instant
            let mss: Int
            let smoothedRTT: NetworkDuration
            let now: NetworkClock.Instant
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.processECN(
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
            }
        }

        struct PacketDiscarded: CongestionControlOperation {
            let bytesSent: Int
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
            }
        }

        struct AckBegin: CongestionControlOperation {
            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.ackBegin()
            }
        }

        struct SpuriousRetransmit: CongestionControlOperation {
            let qlog: QLog?

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.spuriousRetransmit(qlog: qlog)
            }
        }

        struct MSSChanged: CongestionControlOperation {
            let mss: Int

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.mssChanged(mss: mss, qlog: nil)
            }
        }

        struct IdleTimeout: CongestionControlOperation {
            let mss: Int

            func callAsFunction<Controller: CongestionControlProtocol>(_ controller: inout Controller) {
                controller.idleTimeout(mss: mss, qlog: nil)
            }
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
        from other: some CongestionControlProtocol,
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
    // Opens a recovery period at `now`, the time the loss was detected.
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
                    "Congestion window not validated in slow-start, pipeack: \(pipeAckValue), congestionWindow \(congestionWindow)"
                )
                return false
            }
        } else {
            let congestionWindowLimit = congestionWindow >> 1
            if pipeAckValue < congestionWindowLimit {
                log.datapath(
                    "Congestion window not validated in congestion-avoidance, pipeack: \(pipeAckValue), congestionWindow: \(congestionWindow) "
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
        log.datapath("Bytes in flight updated to \(bytesInFlight)")

        QUICSignpost.bytesInFlight(bytesInFlight: Int(bytesInFlight))
    }

    mutating func decrementBytesInFlight(_ bytes: UInt64) {
        let result = bytesInFlight.subtractingReportingOverflow(bytes)
        if result.overflow {
            log.fault("Undeflow, \(bytes) decremented from \(bytesInFlight)")
            bytesInFlight = 0
        } else {
            bytesInFlight = result.partialValue
        }
        log.datapath("Bytes in flight updated to \(bytesInFlight)")
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
            log.datapath("Packet was sent before recovery, ignore")
            return
        }
        // Congestion window is updated later in ackEnd
        self.bytesAcked += bytesAcked
    }

    func packetInRecovery(sentTime: NetworkClock.Instant) -> Bool {
        sentTime <= recoveryStartTime
    }

    // `sentTime` is when the packet went out, `now` when its loss was detected.
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
                "Can send packet because bytesInFlight \(bytesInFlight) + packetLength \(packetLength) <= congestionWindow \(congestionWindow)"
            )
            return true
        } else {
            log.datapath(
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
            log.datapath("Congestion window set to \(congestionWindow) bytes, bytes in flight \(bytesInFlight)")
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
