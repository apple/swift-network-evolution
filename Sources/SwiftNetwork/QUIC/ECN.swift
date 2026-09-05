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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

enum ECNState {
    /// The app explicitly asked to disable ECN.
    case disabled

    /// Sends a probe burst, then moves to the validate state.
    ///
    /// Sends 10 packets marked with `ECT(0)` or `ECT(1)`, then moves to the validate state.
    case probing

    /// Indicates that one or more packets have been successfully validated during probing.
    ///
    /// The establishment report uses this state to report ECN status before 10 packets have been sent.
    case handshakeValidationSuccess

    /// Optimistically sends ECN-capable packets in this state.
    ///
    /// On receiving `ACK_ECN`, moves to capable if validation succeeds; otherwise, moves to failed.
    case validate

    /// Validation succeeded.
    ///
    /// Always sends `ECT(0)` or `ECT(1)` packets in this state.
    /// Continues validating on each received `ACK_ECN`. If validation fails, transitions to the failed state.
    case capable

    /// Either ECN is disabled or validation failed.
    case unsupported

    /// Indicates that packets sent with ECN were dropped.
    ///
    /// The establishment report receives this state.
    case blackholed

    /// Indicates that mangling was detected.
    ///
    /// Once in the validate state, the system detects mangling if all sent packets are marked with CE.
    case manglingDetected

    var shouldNotUseECN: Bool {
        switch self {
        case .disabled, .unsupported, .blackholed, .manglingDetected:
            return true
        default:
            return false
        }
    }
}

// Global explicit congestion notification state
@available(Network 0.1.0, *)
struct ECN: ~Copyable, PrefixedLoggable {
    let log: LogPrefixer

    // We have one copy of ECN counters per packet number space
    var counters = NetworkRigidArray<ECNCounters>(
        repeating: ECNCounters(),
        count: PacketNumberSpace.allCases.count
    )

    var echoEnabled: Bool { flags.contains(.echoEnabled) }
    var markingEnabled: Bool { flags.contains(.markingEnabled) }
    var useECT1: Bool { flags.contains(.l4sEnabled) }
    var ectDisabled: Bool {
        get { flags.contains(.ectDisabled) }
        set { if newValue { flags.insert(.ectDisabled) } else { flags.remove(.ectDisabled) } }
    }

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let echoEnabled = Flags(rawValue: 1 << 0)
        static let markingEnabled = Flags(rawValue: 1 << 1)
        // Use ECT(1) for L4S
        static let l4sEnabled = Flags(rawValue: 1 << 2)
        // only used when switching to and from background
        static let ectDisabled = Flags(rawValue: 1 << 3)
    }
    var flags: Flags = Flags()

    init() {
        self.log = LogPrefixer()
    }

    init(
        echoEnabled: Bool,
        markingEnabled: Bool,
        l4sEnabled: Bool?,
        connection: QUICConnection,
        logPrefixer: LogPrefixer
    ) {
        self.log = logPrefixer
        if echoEnabled || markingEnabled {
            flags.insert(.echoEnabled)
        }
        if markingEnabled {
            flags.formUnion([.markingEnabled, .echoEnabled])
        } else if echoEnabled {
            flags.insert(.echoEnabled)
        }
        if let l4sEnabled, l4sEnabled == true {
            flags.insert(.l4sEnabled)
        }
        log.info(
            "ECN init - echo: \(echoEnabled), marking: \(markingEnabled), ECT(1): \(useECT1)"
        )

        // Create ECN path only for the initial path. Wait for
        // handshake completion for additional one
        if let currentPath = connection.currentPath,
            currentPath.isInitialPath
        {
            currentPath.ecnState = ECNPathState(ecn: self)
        }
    }

    func reset(path: QUICPath?) {
        if let path {
            if path.ecnState?.ecnMarkingEnabled ?? false {
                path.ecnState?.state = .probing
            } else {
                path.ecnState?.state = .disabled
            }
            path.ecnState?.resetValidationCounters()
            log.info(
                "Enable ECN echo: \(path.ecnState?.echoEnabled ?? false), enable ECN: \(path.ecnState?.ecnMarkingEnabled ?? false) use ECT(1): \(path.ecnState?.useECT1 ?? false)"
            )
        }
        for i in 0..<counters.count {
            let counter = counters[i]
            counter.reset()
            // Also reset the largest CE count, as the counts are packet number space specific.
            counter.largestCECount = 0
        }
    }

    // MARK: Convience Methods for processing ENCPath state

    static func processIPCodpoint(
        ecn: borrowing ECN,
        path: QUICPath?,
        stats: inout Statistics,
        packetNumberSpace: PacketNumberSpace,
        flag: IPProtocol.ECN
    ) -> Bool {
        guard let path else {
            return false
        }
        return path.ecnState?.processIPCodepoint(
            ecn: ecn,
            stats: &stats,
            packetNumberSpace: packetNumberSpace,
            flag: flag
        ) ?? false
    }

    static func outgoingIPCodepoint(
        ecn: borrowing ECN,
        path: QUICPath?,
        stats: inout Statistics,
        packet: inout SentPacketRecord
    ) -> IPProtocol.ECN {
        guard let path else {
            return .nonECT
        }
        return path.ecnState?.outgoingIPCodepoint(ecn: ecn, stats: &stats, packet: &packet)
            ?? .nonECT
    }
}

// Per path explicit congestion notification state
@available(Network 0.1.0, *)
struct ECNPathState: ~Copyable, PrefixedLoggable {
    let log: LogPrefixer

    static let validationThreshold = 10
    static let lossThreshold: (ect0: Int, ect1: Int) = (3, 10)

    // ECN counters for path
    private var counters: ECNCounters

    var state = ECNState.disabled
    private var validationSentPacketCount = 0
    private var validationAckElicitingLostPacketCount = 0

    var echoEnabled: Bool { flags.contains(.echoEnabled) }
    var markingEnabled: Bool { flags.contains(.markingEnabled) }
    var useECT1: Bool { flags.contains(.l4sEnabled) }
    var ectDisabled: Bool {
        get { flags.contains(.ectDisabled) }
        set { if newValue { flags.insert(.ectDisabled) } else { flags.remove(.ectDisabled) } }
    }
    var ecnMarkingEnabled: Bool {
        get { flags.contains(.markingEnabled) }
        set { if newValue { flags.insert(.markingEnabled) } else { flags.remove(.markingEnabled) } }
    }
    private var flags = ECN.Flags()

    init(ecn: borrowing ECN) {
        self.log = ecn.log
        self.flags = ecn.flags
        counters = ECNCounters()
        if markingEnabled {  // state is disabled by default
            state = .probing
        }
    }

    // returns ECN counters depending on the requested packet number space
    func ecnCounters(ecn: borrowing ECN, packetNumberSpace: PacketNumberSpace) -> ECNCounters {
        if packetNumberSpace == .applicationData {
            return counters
        } else {
            return ecn.counters[packetNumberSpace]
        }
    }

    mutating func reset(ecn: inout ECN, path: QUICPath? = nil) {
        state = markingEnabled ? .probing : .disabled
        validationSentPacketCount = 0
        validationAckElicitingLostPacketCount = 0

        ecn.reset(path: path)
        resetCounters()
        log.info("ECN reset - new state = \(state)")
    }

    mutating func resetValidationCounters() {
        validationSentPacketCount = 0
        validationAckElicitingLostPacketCount = 0
    }

    func resetCounters() {
        // This should be called when changing the application packet number in multipath.
        counters.reset()
        // Also reset the largest ce count, as the counts are packet number space specific.
        counters.largestCECount = 0
    }

    mutating private func fsmChange(state: ECNState) {
        log.debug("ECN path state: \(self.state) -> \(state)")
        self.state = state
    }

    mutating func validationPacketLost() {
        validationAckElicitingLostPacketCount += 1

        // Use higher threshold for lost packets for L4S experiments
        let lossThreshold =
            useECT1 ? ECNPathState.lossThreshold.ect1 : ECNPathState.lossThreshold.ect0
        if state == .validate || state == .probing,
            validationAckElicitingLostPacketCount >= lossThreshold
        {
            log.info(
                "ECN validation failed since at least \(lossThreshold) validation packets are lost"
            )
            fsmChange(state: .blackholed)
        }
    }

    // Process ECN codepoint in received packets and return true if we want to ack immediately,
    // for example when we receive CE marked packets.
    func processIPCodepoint(
        ecn: borrowing ECN,
        stats: inout Statistics,
        packetNumberSpace: PacketNumberSpace,
        flag: IPProtocol.ECN
    ) -> Bool {
        if !echoEnabled {
            // If feedback is disabled then there is nothing to do. Not reporting updated counts will
            // cause the sender to disable ECN anyway.
            return false
        }

        let counters = ecnCounters(ecn: ecn, packetNumberSpace: packetNumberSpace)

        var ackImmediately = false
        switch flag {
        case .ect0:
            stats.increment(.rxECT0)
            counters.rxECNPackets.ect0 += 1
        case .ect1:
            stats.increment(.rxECT1)
            counters.rxECNPackets.ect1 += 1
        case .ce:
            stats.increment(.rxECTCE)
            counters.rxECNPackets.ce += 1
            ackImmediately = true
        default:
            break
        }
        return ackImmediately
    }

    // Returns count of CE feedback received in the QUIC header
    mutating func validateAck(
        ecn: borrowing ECN,
        frame: borrowing FrameAck,
        previousLargestAcked: PacketNumber,
        newlyAckedECNPackets: UInt64
    ) -> Int {
        let largestAcked = frame.largest
        let packetNumberSpace = frame.packetNumberSpace
        let counters = ecnCounters(ecn: ecn, packetNumberSpace: packetNumberSpace)

        // An endpoint MUST NOT fail ECN validation as a result of processing an ACK frame that
        // does not increase the largest acknowledged packet number - which may happen due to
        // reordering of ACKs. Below is just an optimization as we already check for reordering
        // later based on ECN counts. Make sure that the first ACK is processed when the previous
        // largest acked is invalid.
        if previousLargestAcked != PacketNumber.none,
            largestAcked <= previousLargestAcked
        {
            return counters.largestCECount
        }
        if state.shouldNotUseECN {
            return 0
        }
        if frame.ecnCounter == nil, newlyAckedECNPackets > 0 {
            log.info(
                "ECN validation failed due to receiving an ACK without ECN even though we sent \(newlyAckedECNPackets) ECT packets"
            )
            fsmChange(state: .unsupported)
            return 0
        }
        guard let ackFrameECNCounter = frame.ecnCounter else {
            log.info(
                "Receiving ACK frame without ECN counts is ok only if newly ACKed packets were not originally sent with ECT"
            )
            return counters.largestCECount
        }

        // If L4S is not enabled, then we shouldn't receive ECT(1) counts
        if useECT1, ackFrameECNCounter.ect0 > 0 {
            log.info("ECN validation failed due to receiving an ACK with ECT(0) count > 0")
            fsmChange(state: .unsupported)
            return 0
        } else if !useECT1, ackFrameECNCounter.ect1 > 0 {
            log.info("ECN validation failed due to receiving an ACK with ECT(1) count > 0")
            fsmChange(state: .unsupported)
            return 0
        }

        // As ECT(1) packets may receive frequent markings, the below check is only for packets sent with ECT(0)
        if state == .validate, ackFrameECNCounter.ect0 == 0 || ackFrameECNCounter.ect1 == 0,
            ackFrameECNCounter.ce == counters.txECNPackets
        {
            log.info(
                "ECN validation failed since all (\(counters.txECNPackets)) packets originally sent with ECT(1) or ECT(0) are marked with CE"
            )
            fsmChange(state: .manglingDetected)
            return 0
        }

        let ectCount = useECT1 ? ackFrameECNCounter.ect1 : ackFrameECNCounter.ect0
        let totalCE = ackFrameECNCounter.ce + ectCount
        if totalCE > counters.txECNPackets {
            log.info(
                "ECN validation failed since total of received ECT(\(useECT1 ? 1 : 0)) (\(ectCount)) + CE (\(ackFrameECNCounter.ce)) feedback counts > total of packets sent with ECT1 (\(counters.txECNPackets))"
            )
            fsmChange(state: .unsupported)
            return 0
        }

        // Could happen if there is packet reordering OR if there is a bug in receiver side implementation
        var feedback = counters.currentECNFeedback
        if ackFrameECNCounter.ect0 < feedback.ect0 {
            log.error(
                "\(packetNumberSpace) received ECT(0) count \(ackFrameECNCounter.ect0) < current ECT(0) count \(feedback.ect0)"
            )
            return counters.largestCECount
        } else if ackFrameECNCounter.ect1 < feedback.ect1 {
            log.error(
                "\(packetNumberSpace) received ECT(1) count \(ackFrameECNCounter.ect1) < current ECT(1) count \(feedback.ect1)"
            )
            return counters.largestCECount
        } else if ackFrameECNCounter.ce < feedback.ce {
            log.error(
                "Received CE count \(ackFrameECNCounter.ce) < current CE count \(feedback.ce)"
            )
            return counters.largestCECount
        }

        var delta = ECNCounter(ect0: 0, ect1: 0, ce: 0)
        delta.ect0 = ackFrameECNCounter.ect0 - feedback.ect0
        delta.ect1 = ackFrameECNCounter.ect1 - feedback.ect1
        delta.ce = ackFrameECNCounter.ce - feedback.ce

        let deltaSum = delta.ce + (useECT1 ? delta.ect1 : delta.ect0)
        if deltaSum >= newlyAckedECNPackets {
            feedback.ect0 = ackFrameECNCounter.ect0
            feedback.ect1 = ackFrameECNCounter.ect1
            feedback.ce = ackFrameECNCounter.ce
            log.datapath(
                "received ECN feedback updated, pn_space: \(packetNumberSpace)), ECT(0) count: \(ackFrameECNCounter.ect0), ECT(1) count: \(ackFrameECNCounter.ect1), CE count: \(ackFrameECNCounter.ce), packets sent with ECT: \(counters.txECNPackets)"
            )
            counters.largestCECount = ackFrameECNCounter.ce

            if state == .probing {
                log.info("ECN validation during handshake succeeded")
                fsmChange(state: .handshakeValidationSuccess)
            } else if state == .validate {
                log.info("ECN validation succeeded")
                fsmChange(state: .capable)
            }

        } else {
            log.info(
                "ECN validation failed since sum of increase in ECT\(useECT1) (\(useECT1 ? delta.ect1 : delta.ect0)) and CE (\(delta.ce)) feedback counts < newly acked packets (\(newlyAckedECNPackets)) that were originally sent with an ECT(\(useECT1)) marking"
            )
            fsmChange(state: .unsupported)
            return 0
        }

        return counters.largestCECount
    }

    // Returns the IP ECN flag that should be set on the outgoing packet
    // based on the state machine
    mutating func outgoingIPCodepoint(
        ecn: borrowing ECN,
        stats: inout Statistics,
        packet: inout SentPacketRecord
    ) -> IPProtocol.ECN {
        switch state {
        case .probing, .handshakeValidationSuccess:
            if packet.isAckEliciting {
                // During probing, we are excluding non-ack eliciting (containing ACK,
                // PADDING or CONNECTION_CLOSE) packets as we wouldn't know if the packets
                // are getting dropped due to ECN marking until some ack-eliciting packet
                // with ECN marking is lost.
                packet.isECNValidationPacket = true
                validationSentPacketCount += 1
            }

            if validationSentPacketCount == ECNPathState.validationThreshold {
                log.info("ECN probing finished")
                fsmChange(state: .validate)
            }
            fallthrough

        case .validate, .capable:
            if !ectDisabled, packet.isAckEliciting || state == .capable {
                let counters = ecnCounters(ecn: ecn, packetNumberSpace: packet.numberSpace)
                counters.txECNPackets += 1
                // We mark all packets with ECN after we have validated the path
                if useECT1 {
                    stats.increment(.txECT1)
                    packet.ecn = .ect1
                    return .ect1
                } else {
                    stats.increment(.txECT0)
                    packet.ecn = .ect0
                    return .ect0
                }
            } else {
                return .nonECT
            }

        case .disabled, .unsupported, .blackholed, .manglingDetected:
            break
        }
        return .nonECT
    }
}

struct ECNCounter {
    var ect0: Int
    var ect1: Int
    var ce: Int

    var isEmpty: Bool {
        ect0 == 0 && ect1 == 0 && ce == 0
    }
}

// ECN state metadata for a packet number space
class ECNCounters {
    // Number of packets sent with ECT(1) or ECT(0) codepoint
    var txECNPackets = 0

    // Number of packets received with IP ECN codepoint
    var rxECNPackets = ECNCounter(ect0: 0, ect1: 0, ce: 0)

    // Current snapshot of ECN feedback
    var currentECNFeedback = ECNCounter(ect0: 0, ect1: 0, ce: 0)

    // Largest CE count seen, needed when reordered ACK is received
    var largestCECount = 0

    func reset() {
        txECNPackets = 0
        rxECNPackets = ECNCounter(ect0: 0, ect1: 0, ce: 0)
        currentECNFeedback = ECNCounter(ect0: 0, ect1: 0, ce: 0)
    }
}
#endif
