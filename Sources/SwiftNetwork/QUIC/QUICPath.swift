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

// Note: It is CaseIterable only so that tests can ensure it checks all states
enum QUICPathState: CustomStringConvertible, CaseIterable {
    case invalid  // initial state. RX/TX NOT allowed
    case routeAvailable  // path manager has indicated this is a potential path. RX/TX NOT allowed
    case routeEstablished  // hardware backing the path is ready to send and receive. RX/TX NOT allowed
    case cidAssigned  // path is ready for QUIC transactions. RX/TX allowed
    case probing  // path is being validated. RX/TX allowed
    case validated  // path validation is complete. RX/TX allowed
    case unreachable  // path connectivity is lost. RX/TX NOT allowed
    case closing  // path is going away. RX/TX NOT allowed
    case routeUnavailable  // path has gone away. RX/TX NOT allowed

    var description: String {
        switch self {
        case .invalid: return "invalid"
        case .routeAvailable: return "routeAvailable"
        case .routeEstablished: return "routeEstablished"
        case .cidAssigned: return "cidAssigned"
        case .probing: return "probing"
        case .validated: return "validated"
        case .unreachable: return "unreachable"
        case .closing: return "closing"
        case .routeUnavailable: return "routeUnavailable"
        }
    }

    init(state: QUICPathState = .invalid) {
        self = state
    }

    func isValidStateChange(to newState: QUICPathState) -> Bool {
        switch (self, newState) {
        case (.invalid, .routeAvailable),
            (.invalid, .routeEstablished),
            (.routeAvailable, .routeEstablished),
            (.routeAvailable, .routeUnavailable),
            (.routeEstablished, .cidAssigned),
            (.routeEstablished, .routeUnavailable),
            (.cidAssigned, .probing),
            (.cidAssigned, .routeUnavailable),
            (.probing, .validated),
            (.probing, .unreachable),
            (.probing, .routeUnavailable),
            (.validated, .unreachable),
            (.validated, .probing),
            (.validated, .closing),
            (.validated, .routeEstablished),
            (.validated, .routeUnavailable),
            (.unreachable, .closing),
            (.unreachable, .routeUnavailable),
            (.closing, .routeUnavailable):
            return true
        default:
            return false
        }
    }

    var isOpenForSending: Bool {
        self == .cidAssigned || self == .probing || self == .validated
    }

    var isInvalid: Bool {
        self == .invalid
    }

    var isValidated: Bool {
        self == .validated
    }

    var isRouteEstablished: Bool {
        // All states other than available / unavailable have an established route
        self != .invalid && self != .routeAvailable && self != .routeUnavailable
    }

    var isProbing: Bool {
        self == .probing
    }

    var isUnusable: Bool {
        self == .routeUnavailable || self == .unreachable
    }
}

@available(Network 0.1.0, *)
struct PendingChallenge {
    let data = UInt64.random(in: 0..<UInt64.max)

    // Time filled in when challenge actually sent
    let sentTime: NetworkClock.Instant
}

@available(Network 0.1.0, *)
struct BandwidthDelayProduct {
    var currentBDP: Int = 0
    var count: Int = 0
    var timestamp: NetworkClock.Instant = .zero
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICPath: MultiplexingDatagramPath<QUICConnection>, Equatable, PrefixedLoggable {
    // Initial probe interval for resending PATH_CHALLENGE is 250 ms
    // Further probes will follow exponential backoff.
    static let initialProbeInterval: NetworkDuration = .milliseconds(250)

    static let slowInitialProbeInterval: NetworkDuration = .seconds(1)

    @_optimize(speed)
    override public var reference: ProtocolInstanceReference {
        var reference = ProtocolInstanceReference(quicPath: self)
        reference.parentReference = parentProtocol.reference
        return reference
    }

    private(set) var state: QUICPathState = QUICPathState()
    var priority: Int = 0  // Relative priority to other paths, used to gate migration decisions
    var interface: Interface?

    private(set) var dcid: QUICConnectionID?  // The DCID we assigned before probing
    private(set) var scid: QUICConnectionID?  // Contains the SCID we expect to see once we migrate.

    var pendingInboundChallenges = [UInt64]()  // Received challenges requiring a response

    var pendingOutboundChallenges = [PendingChallenge]()  // Sent challenges waiting for a response
    static let maximumPendingChallenges: Int = 6
    private(set) var challengesSent: Int = 0
    private(set) var lastChallengeSentTime: NetworkClock.Instant = .zero
    private(set) var nextChallengeDuration: NetworkDuration = .zero

    var rtt: RTT

    var bdp = BandwidthDelayProduct()

    private var congestionControl: CongestionControl?

    var pacer: Pacer

    var pmtudState = PMTUDState()
    var recoveryState = Recovery.PathState()
    var ecnState: ECNPathState?
    var pathStatistics = Statistics()

    var initialMSS = 0
    var mss = 0
    var maximumMSS = 0
    var minimumMSS = 0

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt16
        static let pacePackets = Flags(rawValue: 1 << 0)
        static let isInitialPath = Flags(rawValue: 1 << 1)
        static let isPrimaryPath = Flags(rawValue: 1 << 2)
        static let spinValue = Flags(rawValue: 1 << 3)
        static let useSlowProbeInterval = Flags(rawValue: 1 << 4)
        static let isPreferredAddress = Flags(rawValue: 1 << 5)
        static let migrationPending = Flags(rawValue: 1 << 6)
        static let isLossy = Flags(rawValue: 1 << 7)
        static let hasPreAssignedCIDs = Flags(rawValue: 1 << 8)
        static let isFlowControlled = Flags(rawValue: 1 << 9)
        static let l4sEnabled = Flags(rawValue: 1 << 10)
        static let reportedIdleEvent = Flags(rawValue: 1 << 11)
    }
    private var flags = Flags()

    var pacePackets: Bool {
        get { flags.contains(.pacePackets) }
        set { if newValue { flags.insert(.pacePackets) } else { flags.remove(.pacePackets) } }
    }
    var isInitialPath: Bool {
        get { flags.contains(.isInitialPath) }
        set { if newValue { flags.insert(.isInitialPath) } else { flags.remove(.isInitialPath) } }
    }
    var isPrimaryPath: Bool {
        get { flags.contains(.isPrimaryPath) }
        set { if newValue { flags.insert(.isPrimaryPath) } else { flags.remove(.isPrimaryPath) } }
    }
    var spinValue: Bool {
        get { flags.contains(.spinValue) }
        set { if newValue { flags.insert(.spinValue) } else { flags.remove(.spinValue) } }
    }
    var useSlowProbeInterval: Bool {
        get { flags.contains(.useSlowProbeInterval) }
        set { if newValue { flags.insert(.useSlowProbeInterval) } else { flags.remove(.useSlowProbeInterval) } }
    }
    var isPreferredAddress: Bool {
        get { flags.contains(.isPreferredAddress) }
        set { if newValue { flags.insert(.isPreferredAddress) } else { flags.remove(.isPreferredAddress) } }
    }

    // Pending validation, should migrate once validated
    var migrationPending: Bool {
        get { flags.contains(.migrationPending) }
        set { if newValue { flags.insert(.migrationPending) } else { flags.remove(.migrationPending) } }
    }
    var isLossy: Bool {
        get { flags.contains(.isLossy) }
        set { if newValue { flags.insert(.isLossy) } else { flags.remove(.isLossy) } }
    }
    var hasPreAssignedCIDs: Bool {
        get { flags.contains(.hasPreAssignedCIDs) }
        set { if newValue { flags.insert(.hasPreAssignedCIDs) } else { flags.remove(.hasPreAssignedCIDs) } }
    }
    var isFlowControlled: Bool {
        get { flags.contains(.isFlowControlled) }
        set { if newValue { flags.insert(.isFlowControlled) } else { flags.remove(.isFlowControlled) } }
    }
    var l4sEnabled: Bool {
        get { flags.contains(.l4sEnabled) }
        set { if newValue { flags.insert(.l4sEnabled) } else { flags.remove(.l4sEnabled) } }
    }
    var reportedIdleEvent: Bool {
        get { flags.contains(.reportedIdleEvent) }
        set { if newValue { flags.insert(.reportedIdleEvent) } else { flags.remove(.reportedIdleEvent) } }
    }

    var log: LogPrefixer {
        parentProtocol.logPrefixer
    }

    public static func == (lhs: QUICPath, rhs: QUICPath) -> Bool {
        lhs.identifier == rhs.identifier
    }

    var isOpenForSending: Bool { state.isOpenForSending }

    var isValidated: Bool { state.isValidated }

    var isProbing: Bool { state.isProbing }

    var isRouteEstablished: Bool { state.isRouteEstablished }

    var smoothedRTT: NetworkDuration {
        rtt.smoothedRTT
    }

    func withECNState(_ block: (inout ECNPathState) -> Void) {
        guard ecnState != nil else { return }
        block(&self.ecnState!)
    }

    func changeState(to newState: QUICPathState) {
        guard state.isValidStateChange(to: newState) else {
            log.fault("Invalid path transition: \(state) -> \(newState)")
            return
        }
        log.debug("Path state change: \(state) -> \(newState)")
        state = newState
    }

    func set(
        interface: Interface?,
        priority: Int,
        isInitial: Bool,
    ) {
        self.isInitialPath = isInitial
        self.priority = priority
        self.interface = interface

        if isInitial {
            // initial paths start with fully established routes
            self.state = .routeEstablished
        } else {
            parentProtocol.withCurrentPath {
                // Copy over remote max ack delay from current path
                self.rtt.remoteMaxAckDelay = $0.rtt.remoteMaxAckDelay
            }
        }
        self.setup()

        log.debug(
            "Set up new path \(identifier) (\(priority)), \(interface?.description ?? "<none>")"
        )
    }

    required init(parent: QUICConnection) {
        self.rtt = RTT(logPrefixer: parent.logPrefixer)
        self.pacer = Pacer()
        super.init(parent: parent)
    }

    private func setup() {
        self.initialMSS = parentProtocol.initialMSS
        self.maximumMSS =
            PMTUDState.maximumMTU - (IPProtocol.ipv6HeaderLength + UDPProtocol.headerLength)
        self.minimumMSS =
            PMTUDState.minimumMTU - (IPProtocol.ipv6HeaderLength + UDPProtocol.headerLength)

        self.mss = parentProtocol.initialMSS
        if !self.isInitialPath, let interface {
            // Search for other paths that share the same interface that have calculated another MSS
            var foundMSS = false
            parentProtocol.applyToAllPaths { otherPath in
                if !foundMSS, interface == otherPath.interface, otherPath.mss > 0 {
                    self.mss = otherPath.mss
                    log.debug(
                        "MSS \(otherPath.mss) copied from path \(otherPath.identifier.description), since they share the same interface \(interface)"
                    )
                    foundMSS = true
                }
            }
        }

        self.ecnState = ECNPathState(ecn: parentProtocol.ecn)

        let pacerEnabled = (pacePackets || QUICPreferences.shared.pacePackets)
        self.pacer = Pacer(enabled: pacerEnabled)
        self.congestionControl = .cubic(
            algorithm: Cubic(
                pacer: &self.pacer,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
        )

        self.spinValue = parentProtocol.initialSpinValue
    }

    func setSCID(_ scid: QUICConnectionID) {
        self.scid = scid
        log.datapath(
            "assigning SCID \(scid.description) to path ID \(self.identifier)"
        )
    }

    func assignDCID(_ dcid: QUICConnectionID) {
        self.dcid = dcid
        if case .routeEstablished = state {
            changeState(to: .cidAssigned)
        }
        log.datapath(
            "assigning DCID \(dcid.description) to path ID \(self.identifier)"
        )
    }

    func updateBDP(length: Int, now: NetworkClock.Instant = NetworkClock.Instant.now) {
        if bdp.timestamp == .zero {
            bdp.timestamp = now
        }

        if now >= bdp.timestamp + rtt.smoothedRTT {
            bdp.count += length
            bdp.currentBDP = bdp.count

            // Reset the measurement
            bdp.count = 0
            bdp.timestamp = .zero
        } else {
            bdp.count += length
        }
    }

    func resetPacer() {
        pacer.reset()
    }

    func resetCongestionControl() {
        switch self.congestionControl {
        case .cubic:
            self.congestionControl = .cubic(
                algorithm: Cubic(
                    pacer: &self.pacer,
                    mss: self.initialMSS,
                    qlog: parentProtocol.qLog,
                    logPrefixer: self.log
                )
            )
        #if !NETWORK_EMBEDDED
        case .ledbat:
            self.congestionControl = .ledbat(
                algorithm: Ledbat(
                    mss: self.initialMSS,
                    qlog: parentProtocol.qLog,
                    logPrefixer: self.log
                )
            )
        case .prague:
            self.congestionControl = .prague(
                algorithm: Prague(
                    pacer: &self.pacer,
                    mss: self.initialMSS,
                    qlog: parentProtocol.qLog,
                    logPrefixer: self.log
                )
            )
        #endif
        case .none:
            break
        }
    }

    func idleTimeoutCongestionControl() {
        self.congestionControl?.idleTimeout(mss: mss)
    }

    func setupL4SState(l4sEnabled: Bool?) {
        guard let l4sEnabled else {
            return
        }
        // Account for Developer / Carrier settings
        self.l4sEnabled = l4sEnabled
        if l4sEnabled {
            // Setup the pacer. Prague always has pacing enabled
            pacer = Pacer(enabled: true)
            // Add Prague congestion control for L4S
            self.resetPacer()
            resetCongestionControl()
        }
    }

    func markAsBackground(_ background: Bool) {
        #if !NETWORK_EMBEDDED
        // Use LEDBAT for background cases
        switch self.congestionControl {
        case .cubic:
            if !background { return }  // Nothing to do, already not background
            var ledbat = Ledbat(
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            ledbat.inherit(
                from: self.congestionControl!,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog
            )
            self.congestionControl = .ledbat(algorithm: ledbat)
        case .ledbat:
            if background { return }  // Nothing to do, already background
            self.congestionControl = .ledbat(
                algorithm: Ledbat(
                    mss: self.initialMSS,
                    qlog: parentProtocol.qLog,
                    logPrefixer: self.log
                )
            )
            var cubic = Cubic(
                pacer: &self.pacer,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            cubic.inherit(
                from: self.congestionControl!,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog
            )
            self.congestionControl = .cubic(algorithm: cubic)
        case .prague:
            if !background { return }  // Nothing to do, already not background
            var ledbat = Ledbat(
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            ledbat.inherit(
                from: self.congestionControl!,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog
            )
            self.congestionControl = .ledbat(algorithm: ledbat)
        case .none:
            break
        }
        #endif
    }

    func handlePathChallenge(_ challenge: UInt64) {
        log.debug("Path challenge received: \(challenge)")

        // Save the challenge, to schedule a response
        pendingInboundChallenges.append(challenge)

        // Initiate probing if needed
        beginValidation()
    }

    func beginValidation(ifNecessary: Bool = true) {
        if case .routeEstablished = state {
            // The route is established, but needs CID allocation
            guard parentProtocol.assignNewDCID(to: self) else {
                log.error("Failed to assign remote CID to path")
                return
            }
        }

        // Allowed to start probing in CID-Assigned (or Validated state if required)
        if state == .cidAssigned || (!ifNecessary && state == .validated) {
            // The path has a CID assigned. Time to start probing.
            changeState(to: .probing)
            pendingOutboundChallenges.removeAll()
            challengesSent = 0
            lastChallengeSentTime = .zero
            nextChallengeDuration = .zero
        }
    }

    var shouldSendPathResponses: Bool {
        !pendingInboundChallenges.isEmpty
    }

    func shouldSendPathChallenge(now: NetworkClock.Instant) -> Bool {
        guard case .probing = state else {
            return false
        }
        if challengesSent == 0 {
            // Still need to send first challenge
            return true
        }
        return now >= lastChallengeSentTime + nextChallengeDuration
    }

    var nextChallengeTime: NetworkClock.Instant? {
        guard case .probing = state else {
            return nil
        }
        if challengesSent == 0 {
            // Still need to send first challenge
            return nil
        }
        return lastChallengeSentTime + nextChallengeDuration
    }

    func hasPendingItems(now: NetworkClock.Instant) -> Bool {
        shouldSendPathResponses || shouldSendPathChallenge(now: now)
    }

    func addPathChallenge(
        to pendingItems: inout PendingItems,
        now: NetworkClock.Instant
    ) {
        guard shouldSendPathChallenge(now: now) else { return }

        guard challengesSent < QUICPath.maximumPendingChallenges else {
            // Exceeded limit, move to unreachable, and retire the CID
            changeState(to: .unreachable)
            if let dcid, !hasPreAssignedCIDs {
                if let sequenceNumber = parentProtocol.retireConnectionID(dcid) {
                    pendingItems.addRetireConnectionID(
                        FrameRetireConnectionID(sequence: sequenceNumber)
                    )
                }
            }
            return
        }

        let challenge = PendingChallenge(sentTime: now)
        pendingOutboundChallenges.append(challenge)
        pendingItems.addPathChallenge(FramePathChallenge(data: challenge.data))
        lastChallengeSentTime = now
        if useSlowProbeInterval {
            nextChallengeDuration = QUICPath.slowInitialProbeInterval * (1 << challengesSent)
        } else {
            nextChallengeDuration = QUICPath.initialProbeInterval * (1 << challengesSent)
        }
        challengesSent += 1

        parentProtocol.migration.resetTimer(connection: parentProtocol)
    }

    func addPendingItems(_ pendingItems: inout PendingItems, now: NetworkClock.Instant, ) {
        // Respond to any pending inbound challenges
        for challenge in pendingInboundChallenges {
            pendingItems.addPathResponse(FramePathResponse(data: challenge))
        }
        pendingInboundChallenges.removeAll()

        // Send path challenges as needed
        addPathChallenge(to: &pendingItems, now: now)
    }

    func handlePathChallengeResponse(_ data: UInt64) {
        guard case .probing = state else { return }
        guard
            let pendingOutboundChallenge = pendingOutboundChallenges.first(where: {
                $0.data == data
            })
        else {
            log.info("Received path response for unknown challenge \(data)")
            return
        }
        log.debug("Valid path challenge response received: \(data)")
        let now = NetworkClock.Instant.now
        let responseDuration = pendingOutboundChallenge.sentTime.duration(to: now)
        pendingOutboundChallenges.removeAll()
        challengesSent = 0
        lastChallengeSentTime = .zero
        changeState(to: .validated)
        // Initialize RTT based on the PATH_RESPONSE duration so that we have a proper RTT estimate when we reset the timers.
        rtt.processNewSample(ackDuration: responseDuration, packetAckedTime: now, ackDelay: .zero)
        parentProtocol.migration.resetTimer(connection: parentProtocol)
        if migrationPending {
            migrationPending = false
            parentProtocol.migration.migrate(to: self, connection: parentProtocol)
        }
    }
}

// Congestion Control access
@available(Network 0.1.0, *)
extension QUICPath {
    @inline(__always)
    var congestionControlWindow: UInt64 {
        congestionControl?.congestionWindow ?? 0
    }

    @inline(__always)
    var congestionControlAvailableCongestionWindow: UInt64 {
        congestionControl?.availableCongestionWindow ?? 0
    }

    @inline(__always)
    func congestionControlCanSend(packetLength: Int) -> Bool {
        congestionControl?.canSend(packetLength: packetLength) ?? false
    }

    @inline(__always)
    func congestionControlPersistentCongestion(mss: Int, qlog: QLog? = nil) {
        congestionControl?.persistentCongestion(mss: mss, qlog: qlog)
    }

    @inline(__always)
    func congestionControlAckEnd(rtt: borrowing RTT, path: QUICPath?, mss: Int, packetsLost: Bool, qlog: QLog? = nil) {
        congestionControl?.ackEnd(rtt: rtt, path: self, mss: mss, packetsLost: packetsLost, qlog: qlog)
    }

    @inline(__always)
    func congestionControlPacketsSent(bytesSent: Int, qlog: QLog? = nil) {
        congestionControl?.packetSent(bytesSent: bytesSent, qlog: qlog)
    }

    @inline(__always)
    func congestionControlPacketsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        congestionControl?.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
    }

    @inline(__always)
    func congestionControlPacketsLost(
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration
    ) -> Bool {
        congestionControl?.packetsLost(
            bytesLost: bytesLost,
            largestLostSentTime: largestLostSentTime,
            mss: mss,
            smoothedRTT: smoothedRTT
        ) ?? false
    }

    @inline(__always)
    func congestionControlPacketDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        congestionControl?.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
    }

    @inline(__always)
    func congestionControlAckBegin() {
        congestionControl?.ackBegin()
    }

    @inline(__always)
    var congestionControlBytesInFlight: UInt64 {
        congestionControl?.bytesInFlight ?? 0
    }

    @inline(__always)
    var congestionControlName: String {
        congestionControl?.name ?? "none"
    }

    @inline(__always)
    func congestionControlSpuriousRetransmit(qlog: QLog? = nil) {
        congestionControl?.spuriousRetransmit()
    }

    @inline(__always)
    func congestionControlMSSChanged(mss: Int) {
        congestionControl?.mssChanged(mss: mss)
    }

    @inline(__always)
    func congestionControlIdleTimeout(mss: Int) {
        congestionControl?.idleTimeout(mss: mss)
    }

    @inline(__always)
    func congestionControlProcessECN(
        ceCount: Int,
        packetsAcked: Int,
        largestSentPN: Int64,
        largestAckedPN: Int64,
        largestAckedSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        qlog: QLog? = nil
    ) {
        guard congestionControl != nil else { return }
        switch congestionControl! {
        case .cubic(var cubic):
            cubic.processECN(
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                qlog: qlog
            )
        #if !NETWORK_EMBEDDED
        case .ledbat(var ledbat):
            ledbat.processECN(
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                qlog: qlog
            )
        case .prague(var prague):
            prague.processECN(
                ceCount: ceCount,
                packetsAcked: packetsAcked,
                largestSentPN: largestSentPN,
                largestAckedPN: largestAckedPN,
                largestAckedSentTime: largestAckedSentTime,
                mss: mss,
                smoothedRTT: smoothedRTT,
                qlog: qlog
            )
        #endif
        }
    }

    @inline(__always)
    func congestionControlFilloutDataTransferSnapshot(snapshot: inout DataTransferSnapshot) {
        congestionControl?.filloutDataTransferSnapshot(dataTransferSnapshot: &snapshot)
    }
}

#endif
