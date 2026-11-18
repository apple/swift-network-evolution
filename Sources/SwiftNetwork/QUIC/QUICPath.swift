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

    func canTransition(to newState: QUICPathState) -> Bool {
        switch (self, newState) {
        // Route bring-up, as the path manager reports it.
        case (.invalid, .routeAvailable),  // route available
            (.invalid, .routeEstablished),  // initial path, its route already established
            (.routeAvailable, .routeEstablished):  // route established
            return true

        // Path validation (RFC 9000 §8.2).
        case (.routeEstablished, .cidAssigned),  // peer connection ID assigned
            (.cidAssigned, .probing),  // snd PATH_CHALLENGE
            (.validated, .probing),  // revalidate
            (.probing, .validated),  // rcv PATH_RESPONSE
            (.probing, .unreachable),  // challenges exhausted
            (.validated, .unreachable),
            (.validated, .routeEstablished),  // route re-established, needs a new connection ID
            (.cidAssigned, .routeEstablished),  // connection ID retired, none to replace it
            (.probing, .routeEstablished):  // connection ID retired, none to replace it
            return true

        // Teardown: a validated or unreachable path closes, and the path manager can take away
        // the route of a path in any state: one that was never set up, because the connection was
        // torn down before its lower protocol connected, or one whose route is already gone.
        case (.validated, .closing),
            (.unreachable, .closing),
            (_, .routeUnavailable):
            return true

        default:
            return false
        }
    }

    var isOpenForSending: Bool {
        self == .cidAssigned || self == .probing || self == .validated
    }

    // A path holds one of the peer's CIDs exactly while it can send, and gives it up on leaving
    // these states.
    var holdsCID: Bool {
        isOpenForSending
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
public struct QUICPath: ~Copyable, MultiplexingDatapathPath, AutomaticLowerDatagramProcessing, PrefixedLoggable {
    public typealias ParentProtocol = QUICConnection
    public typealias LowerProtocol = BaseOutboundDatagramLinkage

    // The generic path: identity, lower linkage and the queues shared with the lower protocol. A QUIC
    // path lives inline in its connection's path table, so nothing here is reference counted.
    @usableFromInline
    var base: MultiplexingDatagramPath<QUICConnection, BaseOutboundDatagramLinkage>

    // Initial probe interval for resending PATH_CHALLENGE is 250 ms
    // Further probes will follow exponential backoff.
    static let initialProbeInterval: NetworkDuration = .milliseconds(250)

    static let slowInitialProbeInterval: NetworkDuration = .seconds(1)

    var state: QUICPathState = QUICPathState() {
        didSet {
            log.debug("Path state change: \(oldValue) -> \(state)")
            if !oldValue.canTransition(to: state) {
                log.fault("Invalid path transition: \(oldValue) -> \(state)")
            }
            if oldValue.holdsCID && !state.holdsCID {
                releaseDCID()
            }
        }
    }
    var priority: Int = 0  // Relative priority to other paths, used to gate migration decisions
    var interface: Interface?
    var localEndpoint: Endpoint?
    var remoteEndpoint: Endpoint?

    private(set) var dcid: QUICConnectionID?  // The DCID we assigned before probing
    private(set) var scid: QUICConnectionID?  // Contains the SCID we expect to see once we migrate.

    var pendingInboundChallenges = [UInt64]()  // Received challenges requiring a response

    var pendingOutboundChallenges = [PendingChallenge]()  // Sent challenges waiting for a response

    /// Set when a challenge was sent or answered, which changes when the migration timer is due, with the
    /// time to measure that from. The connection takes it with `forwardMigrationTimerResetRequest` once
    /// the work on the path is done. It is kept here so that a send that sent no challenge, which is
    /// nearly every send, has nothing to look at beyond the path it already holds.
    var migrationTimerResetRequest: NetworkClock.Instant?
    static let maximumPendingChallenges: Int = 6
    private(set) var challengesSent: Int = 0
    private(set) var lastChallengeSentTime: NetworkClock.Instant = .zero
    private(set) var nextChallengeDuration: NetworkDuration = .zero

    var rtt: RTT

    var bdp = BandwidthDelayProduct()

    private var congestionControl: CongestionControl

    var pacer: Pacer

    var pmtudState = PMTUDState()
    var recoveryState = Recovery.PathState()
    var ecnState = ECNPathState()
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

    // MARK: Forwarded path state

    public var parentProtocol: QUICConnection {
        @inline(always) get { base.parentProtocol }
        @inline(always) set { base.parentProtocol = newValue }
    }
    public var lower: BaseOutboundDatagramLinkage {
        @inline(always) get { base.lower }
        @inline(always) set { base.lower = newValue }
    }
    public var eventManager: ProtocolEventManager {
        @inline(always) _read { yield base.eventManager }
        @inline(always) _modify { yield &base.eventManager }
    }
    public var pathIdentifier: MultiplexingPathIdentifier {
        @inline(always) get { base.pathIdentifier }
    }
    public var lowerSendQueue: FrameArray {
        @inline(always) _read { yield base.lowerSendQueue }
        @inline(always) _modify { yield &base.lowerSendQueue }
    }
    public var lowerReceiveQueue: FrameArray {
        @inline(always) _read { yield base.lowerReceiveQueue }
        @inline(always) _modify { yield &base.lowerReceiveQueue }
    }
    public var pathIsPrimary: Bool {
        @inline(always) get { base.pathIsPrimary }
        @inline(always) set { base.pathIsPrimary = newValue }
    }
    public var pathHasMigrationInfo: Bool {
        @inline(always) get { base.pathHasMigrationInfo }
        @inline(always) set { base.pathHasMigrationInfo = newValue }
    }
    public var identifier: InstanceIdentifier {
        @inline(always) get { base.identifier }
        @inline(always) set { base.identifier = newValue }
    }

    public mutating func serviceLowerReceiveQueue(in eventContext: inout NetworkContext.EventContext) {
        base.serviceLowerReceiveQueue(in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailable(in eventContext: inout NetworkContext.EventContext) {
        base.handleOutboundRoomAvailable(in: &eventContext)
    }

    public mutating func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }

    var log: LogPrefixer {
        parentProtocol.logPrefixer
    }

    /// Builds the linkage that reaches this path from its lower protocol. It names the connection and
    /// the path's place in the connection's table, since the path itself can only be reached by
    /// borrowing it from there.
    public func asUpperLinkage() -> LowerProtocol.PairedUpperLinkage {
        BaseInboundDatagramLinkage(quicConnection: parentProtocol, path: pathIdentifier, identifier: identifier)
    }

    var isOpenForSending: Bool { state.isOpenForSending }

    var isValidated: Bool { state.isValidated }

    var isProbing: Bool { state.isProbing }

    var isRouteEstablished: Bool { state.isRouteEstablished }

    @_optimize(speed)
    var smoothedRTT: NetworkDuration {
        rtt.smoothedRTT
    }

    mutating func withECNState(_ block: (inout ECNPathState) -> Void) {
        block(&self.ecnState)
    }

    // Gives the peer's CID back once the path can no longer send with it. The connection retires
    // it, unless the peer already has. A zero-length CID is not something the peer can run out
    // of, and a pre-assigned one belongs to the path, so those are kept.
    private mutating func releaseDCID() {
        guard let dcid, dcid.length > 0, !hasPreAssignedCIDs else {
            return
        }
        parentProtocol.retireOutboundCID(dcid)
        self.dcid = nil
    }

    /// What a new path takes from the paths the connection already has.
    ///
    /// The path is not in the connection's path table when it is set up, so the connection looks
    /// at its other paths first and hands over what the path needs from them.
    struct Inheritance {
        /// The remote max ack delay of the current path, for a path that is not the initial one.
        var remoteMaxAckDelay: NetworkDuration?
        /// The MSS another path on the same interface has already worked out, with that path's
        /// identifier for the log.
        var sharedInterfaceMSS: (mss: Int, pathIdentifier: MultiplexingPathIdentifier)?

        static let none = Inheritance(remoteMaxAckDelay: nil, sharedInterfaceMSS: nil)
    }

    mutating func set(
        interface: Interface?,
        priority: Int,
        isInitial: Bool,
        inheriting: Inheritance = .none
    ) {
        self.isInitialPath = isInitial
        self.priority = priority
        self.interface = interface

        if isInitial {
            // initial paths start with fully established routes
            self.state = .routeEstablished
        } else if let remoteMaxAckDelay = inheriting.remoteMaxAckDelay {
            // Copy over remote max ack delay from current path
            self.rtt.remoteMaxAckDelay = remoteMaxAckDelay
        }
        self.setup(sharedInterfaceMSS: inheriting.sharedInterfaceMSS)

        log.debug(
            "Set up new path \(pathIdentifier) (\(priority)), \(interface?.description ?? "<none>")"
        )
    }

    // These take the generic `fromExternal` entry point, which embedded Swift cannot specialize,
    // and nothing but the tests calls them.
    #if !NETWORK_EMBEDDED
    /// Creates a path from outside the protocol stack, for tests only.
    ///
    /// Path creation registers an event state, which needs the event context. Code already
    /// running inside the stack should use `init(parent:in:)` and thread its own state in;
    /// this convenience is for external entry points such as tests.
    ///
    /// A path built this way isn't in the parent's `multiplexingPaths`, so nothing tears it down.
    /// Pair it with `destroyFromExternalTest()` before letting it go.
    static func makeFromExternalTest(parent: QUICConnection) -> QUICPath {
        parent.fromExternal { eventContext in
            QUICPath(parent: parent, in: &eventContext)
        }
    }

    /// Destroys a path built with `makeFromExternalTest(parent:)`, for tests only.
    ///
    /// This is an external entry point; code inside the stack calls `destroy(in:)` with the
    /// state it already holds.
    consuming func destroyFromExternalTest() {
        let connection = parentProtocol
        var path = consume self
        connection.fromExternal { eventContext in
            path.destroy(in: &eventContext)
        }
    }
    #endif

    public init(parent: QUICConnection, in eventContext: inout NetworkContext.EventContext) {
        self.rtt = RTT(logPrefixer: parent.logPrefixer)
        self.pacer = Pacer()
        // Overwritten with the real mss/qlog once `setup()` runs; RX/TX aren't allowed on a
        // path until then, so this placeholder is never observed.
        var congestionControlState = CongestionControlState()
        let cubic = Cubic(
            state: &congestionControlState,
            pacer: &self.pacer,
            mss: 0,
            qlog: nil,
            logPrefixer: parent.logPrefixer
        )
        self.congestionControl = CongestionControl(state: congestionControlState, algorithm: .cubic(algorithm: cubic))
        self.base = MultiplexingDatagramPath(parent: parent, in: &eventContext)
    }

    /// Lends out the path's PMTUD state alongside the rest of the path.
    ///
    /// PMTUD looks at the path as it works, and the state is part of the path, so the two cannot be
    /// borrowed at once. The state is moved out for the duration of `body` and put back after.
    mutating func withPMTUDState<R>(_ body: (inout PMTUDState, inout QUICPath) -> R) -> R {
        var state = PMTUDState()
        swap(&state, &pmtudState)
        defer { swap(&state, &pmtudState) }
        return body(&state, &self)
    }

    deinit {
        // Ensure PMTUD timers are removed
        pmtudState.removeTimer(from: base.parentProtocol)
    }

    private mutating func setup(sharedInterfaceMSS: (mss: Int, pathIdentifier: MultiplexingPathIdentifier)?) {
        self.initialMSS = parentProtocol.initialMSS
        self.maximumMSS =
            PMTUDState.maximumMTU - (IPProtocol.ipv6HeaderLength + UDPProtocol.headerLength)
        self.minimumMSS =
            PMTUDState.minimumMTU - (IPProtocol.ipv6HeaderLength + UDPProtocol.headerLength)

        self.mss = parentProtocol.initialMSS
        if !self.isInitialPath, let interface, let shared = sharedInterfaceMSS {
            // Another path on the same interface has calculated another MSS
            self.mss = shared.mss
            log.debug(
                "MSS \(shared.mss) copied from path \(shared.pathIdentifier.description), since they share the same interface \(interface)"
            )
        }

        self.ecnState = ECNPathState(ecn: parentProtocol.ecn)

        let pacerEnabled = (pacePackets || QUICPreferences.shared.pacePackets)
        self.pacer = Pacer(enabled: pacerEnabled)
        var congestionControlState = CongestionControlState()
        let cubic = Cubic(
            state: &congestionControlState,
            pacer: &self.pacer,
            mss: self.initialMSS,
            qlog: parentProtocol.qLog,
            logPrefixer: self.log
        )
        self.congestionControl = CongestionControl(state: congestionControlState, algorithm: .cubic(algorithm: cubic))

        self.spinValue = parentProtocol.initialSpinValue
    }

    mutating func setSCID(_ scid: QUICConnectionID) {
        self.scid = scid
        log.datapath(
            "Assigning SCID \(scid.description) to path ID \(self.pathIdentifier)"
        )
    }

    mutating func assignDCID(_ dcid: QUICConnectionID, in eventContext: inout NetworkContext.EventContext) {
        self.dcid = dcid
        if case .routeEstablished = state {
            state = .cidAssigned
            if let localEndpoint, let remoteEndpoint,
                case .address(let localAddress) = localEndpoint.type,
                case .address(let remoteAddress) = remoteEndpoint.type
            {
                // If the cid is now assigned we can send and receive on the path
                let pathInfo = QUICPathInfo(
                    isValidated: self.isValidated,
                    remote: remoteAddress,
                    local: localAddress
                )
                parentProtocol.deliverNetworkProtocolEvent(
                    flow: .allFlows,
                    event: .init(quicEvent: .pathCIDAssigned(pathInfo)),
                    in: &eventContext
                )
            } else {
                log.error("Path \(pathIdentifier) is missing endpoints, not delivering pathCIDAssigned")
            }
        }
        log.datapath(
            "Assigning DCID \(dcid.description) to path ID \(self.pathIdentifier)"
        )
    }

    mutating func updateBDP(length: Int, now: NetworkClock.Instant) {
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

    mutating func resetPacer() {
        pacer.reset()
    }

    mutating func resetCongestionControl() {
        switch self.congestionControl.algorithm {
        case .cubic:
            var congestionControlState = CongestionControlState()
            let cubic = Cubic(
                state: &congestionControlState,
                pacer: &self.pacer,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            self.congestionControl = CongestionControl(
                state: congestionControlState,
                algorithm: .cubic(algorithm: cubic)
            )
        #if !NETWORK_EMBEDDED
        case .ledbat:
            var congestionControlState = CongestionControlState()
            let ledbat = Ledbat(
                state: &congestionControlState,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            self.congestionControl = CongestionControl(
                state: congestionControlState,
                algorithm: .ledbat(algorithm: ledbat)
            )
        case .prague:
            installPragueCongestionControl()
        #endif
        }
    }

    #if !NETWORK_EMBEDDED
    // Replaces the congestion controller with a fresh Prague bound to this path's pacer. Shared by
    // `resetCongestionControl()` and `setupL4SState(l4sEnabled:)` so Prague is built in one place.
    private mutating func installPragueCongestionControl() {
        var congestionControlState = CongestionControlState()
        let prague = Prague(
            state: &congestionControlState,
            pacer: &self.pacer,
            mss: self.initialMSS,
            qlog: parentProtocol.qLog,
            logPrefixer: self.log
        )
        self.congestionControl = CongestionControl(
            state: congestionControlState,
            algorithm: .prague(algorithm: prague)
        )
    }
    #endif

    mutating func idleTimeoutCongestionControl() {
        self.congestionControl.idleTimeout(mss: mss)
    }

    mutating func setupL4SState(l4sEnabled: Bool) {
        // Account for Developer / Carrier settings
        self.l4sEnabled = l4sEnabled
        if l4sEnabled {
            // Setup the pacer: Prague always has pacing enabled.
            pacer = Pacer(enabled: true)
            #if !NETWORK_EMBEDDED
            installPragueCongestionControl()
            #else
            // Prague isn't available; rebuild the current controller so it seeds the new pacer.
            resetCongestionControl()
            #endif
        }
    }

    mutating func markAsBackground(_ background: Bool) {
        #if !NETWORK_EMBEDDED
        // Use LEDBAT for background cases
        switch self.congestionControl.algorithm {
        case .cubic:
            if !background { return }  // Nothing to do, already not background
            let oldState = self.congestionControl.state
            var newState = CongestionControlState()
            var ledbat = Ledbat(
                state: &newState,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            ledbat.inherit(
                from: oldState,
                state: &newState,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog
            )
            self.congestionControl = CongestionControl(
                state: newState,
                algorithm: .ledbat(algorithm: ledbat)
            )
        case .ledbat:
            if background { return }  // Nothing to do, already background
            // Inherit from the current LEDBAT so bytes in flight (and the window) carry over.
            let oldState = self.congestionControl.state
            var newState = CongestionControlState()
            var cubic = Cubic(
                state: &newState,
                pacer: &self.pacer,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            cubic.inherit(
                from: oldState,
                state: &newState,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog
            )
            self.congestionControl = CongestionControl(
                state: newState,
                algorithm: .cubic(algorithm: cubic)
            )
        case .prague:
            if !background { return }  // Nothing to do, already not background
            let oldState = self.congestionControl.state
            var newState = CongestionControlState()
            var ledbat = Ledbat(
                state: &newState,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog,
                logPrefixer: self.log
            )
            ledbat.inherit(
                from: oldState,
                state: &newState,
                mss: self.initialMSS,
                qlog: parentProtocol.qLog
            )
            self.congestionControl = CongestionControl(
                state: newState,
                algorithm: .ledbat(algorithm: ledbat)
            )
        }
        #endif
    }

    mutating func handlePathChallenge(_ challenge: UInt64, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Path challenge received: \(challenge)")

        // Save the challenge, to schedule a response
        pendingInboundChallenges.append(challenge)

        // A server's migration strategy decides whether to validate a path the peer probes.
        if !parentProtocol.isServer {
            beginValidation(in: &eventContext)
        }
    }

    mutating func beginValidation(ifNecessary: Bool = true, in eventContext: inout NetworkContext.EventContext) {
        if case .routeEstablished = state {
            // The route is established, but needs CID allocation
            guard parentProtocol.assignNewDCID(to: &self, in: &eventContext) else {
                log.error("Failed to assign remote CID to path")
                return
            }
        }

        // Allowed to start probing in CID-Assigned (or Validated state if required)
        if state == .cidAssigned || (!ifNecessary && state == .validated) {
            // The path has a CID assigned. Time to start probing.
            state = .probing
            pendingOutboundChallenges.removeAll()
            challengesSent = 0
            lastChallengeSentTime = .zero
            nextChallengeDuration = .zero
        }
    }

    // The handshake validates the peer's address on the path it ran on (RFC 9000 8.1), so that
    // path is never probed. Takes it through probing to validated as if it had been, so that it
    // reads as a path the connection can use and go back to like any other.
    mutating func handshakeValidated() {
        guard state == .cidAssigned else {
            return
        }
        state = .probing
        state = .validated
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

    mutating func addPathChallenge(
        to pendingItems: inout PendingItems,
        now: NetworkClock.Instant,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard shouldSendPathChallenge(now: now) else { return }

        guard challengesSent < QUICPath.maximumPendingChallenges else {
            // Exceeded limit, move to unreachable, which gives up the CID
            state = .unreachable
            if let localEndpoint, let remoteEndpoint,
                case .address(let localAddress) = localEndpoint.type,
                case .address(let remoteAddress) = remoteEndpoint.type
            {
                let pathInfo = QUICPathInfo(
                    isValidated: self.isValidated,
                    remote: remoteAddress,
                    local: localAddress
                )
                parentProtocol.deliverNetworkProtocolEvent(
                    flow: .allFlows,
                    event: .init(quicEvent: .pathUnreachable(pathInfo)),
                    in: &eventContext
                )
            } else {
                log.error("Path \(pathIdentifier) is missing endpoints, not delivering pathUnreachable")
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

        // The timer looks at every path, so it is reset once the paths are all in the connection's
        // table again, measured from the time this challenge was sent.
        migrationTimerResetRequest = now
    }

    mutating func addPendingItems(
        _ pendingItems: inout PendingItems,
        now: NetworkClock.Instant,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Respond to any pending inbound challenges
        for challenge in pendingInboundChallenges {
            pendingItems.addPathResponse(FramePathResponse(data: challenge))
        }
        pendingInboundChallenges.removeAll()

        // Send path challenges as needed
        addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
    }

    /// Handles the answer to a PATH_CHALLENGE. Returns whether it validated the path.
    ///
    /// The migration strategy looks at every path, so it is left to the connection to run once the
    /// path is no longer borrowed: see `QUICConnection.handlePathChallengeResponse(path:data:in:)`.
    @discardableResult
    mutating func handlePathChallengeResponse(
        _ data: UInt64,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        guard case .probing = state else { return false }
        guard
            let pendingOutboundChallenge = pendingOutboundChallenges.first(where: {
                $0.data == data
            })
        else {
            log.info("Received path response for unknown challenge \(data)")
            return false
        }
        log.debug("Valid path challenge response received: \(data)")
        let now = parentProtocol.now
        let responseDuration = pendingOutboundChallenge.sentTime.duration(to: now)
        pendingOutboundChallenges.removeAll()
        challengesSent = 0
        lastChallengeSentTime = .zero
        state = .validated
        // Initialize RTT based on the PATH_RESPONSE duration so that we have a proper RTT estimate when we reset the timers.
        rtt.processNewSample(ackDuration: responseDuration, packetAckedTime: now, ackDelay: .zero)
        migrationTimerResetRequest = now
        // Notify the stack about the path becoming validated
        if let localEndpoint, let remoteEndpoint,
            case .address(let localAddress) = localEndpoint.type,
            case .address(let remoteAddress) = remoteEndpoint.type
        {
            let pathInfo = QUICPathInfo(
                isValidated: self.isValidated,
                remote: remoteAddress,
                local: localAddress
            )
            parentProtocol.deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .pathValidated(pathInfo)),
                in: &eventContext
            )
        } else {
            log.error("Path \(pathIdentifier) is missing endpoints, not delivering pathValidated")
        }
        return true
    }

}

@available(Network 0.1.0, *)
extension QUICPath {
    /// Works out when a packet should be sent, and fills in the times it should go out at.
    mutating func pacedSendTime(
        packetLength: UInt16,
        sendTimeAbsolute: inout NetworkClock.Instant,
        sendTimeContinuous: inout NetworkClock.Instant
    ) {
        let rateWasZero = pacer.getSendTime(
            now: parentProtocol.now,
            nowAbsolute: parentProtocol.nowAbsolute,
            packetLength: packetLength,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        if rateWasZero {
            let startupRate = pacer.startupRate
            let algorithm = congestionControlName
            let window = congestionControlWindow
            let smoothedRTTMilliseconds = smoothedRTT.milliseconds
            Logger.proto.fault(
                "Pacer rate shouldn't be 0, startup rate = \(startupRate), CCA is \(algorithm) (cwnd=\(window), smoothed rtt=\(smoothedRTTMilliseconds) ms)"
            )
        }
    }
}

// Congestion Control access
@available(Network 0.1.0, *)
extension QUICPath {
    @inline(always)
    var congestionControlWindow: UInt64 {
        congestionControl.congestionWindow
    }

    @inline(always)
    var congestionControlAvailableCongestionWindow: UInt64 {
        congestionControl.availableCongestionWindow
    }

    @inline(always)
    func congestionControlCanSend(packetLength: Int) -> Bool {
        congestionControl.canSend(packetLength: packetLength)
    }

    @inline(always)
    mutating func congestionControlPersistentCongestion(mss: Int, qlog: QLog? = nil) {
        congestionControl.persistentCongestion(mss: mss, qlog: qlog)
    }

    @inline(always)
    mutating func congestionControlAckEnd(
        mss: Int,
        packetsLost: Bool,
        qlog: QLog? = nil
    ) {
        congestionControl.ackEnd(
            rtt: rtt,
            pacer: &pacer,
            mss: mss,
            packetsLost: packetsLost,
            now: parentProtocol.now,
            qlog: qlog
        )
    }

    @inline(always)
    mutating func congestionControlPacketsSent(bytesSent: Int, qlog: QLog? = nil) {
        congestionControl.packetSent(bytesSent: bytesSent, qlog: qlog)
    }

    @inline(always)
    mutating func congestionControlPacketsAcked(bytesAcked: Int, sentTime: NetworkClock.Instant) {
        congestionControl.packetsAcked(bytesAcked: bytesAcked, sentTime: sentTime)
    }

    /// Reports the packets acked since the last flush in one call, within the ack bracket.
    @inline(always)
    mutating func congestionControlPacketsAcked(bytesAcked: Int, creditedBytes: Int) {
        congestionControl.packetsAcked(bytesAcked: bytesAcked, creditedBytes: creditedBytes)
    }

    /// Packets sent at or before this time do not grow the window.
    @inline(always)
    var congestionControlRecoveryStartTime: NetworkClock.Instant {
        congestionControl.state.recoveryStartTime
    }

    @inline(always)
    mutating func congestionControlPacketsLost(
        bytesLost: Int,
        largestLostSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration
    ) -> Bool {
        congestionControl.packetsLost(
            bytesLost: bytesLost,
            largestLostSentTime: largestLostSentTime,
            mss: mss,
            smoothedRTT: smoothedRTT,
            now: parentProtocol.now
        )
    }

    @inline(always)
    mutating func congestionControlPacketDiscarded(bytesSent: Int, qlog: QLog? = nil) {
        congestionControl.packetDiscarded(bytesSent: bytesSent, qlog: qlog)
    }

    @inline(always)
    mutating func congestionControlAckBegin() {
        congestionControl.ackBegin()
    }

    @inline(always)
    var congestionControlBytesInFlight: UInt64 {
        congestionControl.bytesInFlight
    }

    @inline(always)
    var congestionControlName: String {
        congestionControl.name
    }

    @inline(always)
    mutating func congestionControlSpuriousRetransmit(qlog: QLog? = nil) {
        congestionControl.spuriousRetransmit(qlog: qlog)
    }

    @inline(always)
    mutating func congestionControlMSSChanged(mss: Int) {
        congestionControl.mssChanged(mss: mss)
    }

    @inline(always)
    mutating func congestionControlIdleTimeout(mss: Int) {
        congestionControl.idleTimeout(mss: mss)
    }

    @inline(always)
    mutating func congestionControlProcessECN(
        ceCount: Int,
        packetsAcked: Int,
        largestSentPN: Int64,
        largestAckedPN: Int64,
        largestAckedSentTime: NetworkClock.Instant,
        mss: Int,
        smoothedRTT: NetworkDuration,
        qlog: QLog? = nil
    ) {
        congestionControl.processECN(
            ceCount: ceCount,
            packetsAcked: packetsAcked,
            largestSentPN: largestSentPN,
            largestAckedPN: largestAckedPN,
            largestAckedSentTime: largestAckedSentTime,
            mss: mss,
            smoothedRTT: smoothedRTT,
            now: parentProtocol.now,
            qlog: qlog
        )
    }

    @inline(always)
    func congestionControlFilloutDataTransferSnapshot(snapshot: inout DataTransferSnapshot) {
        congestionControl.filloutDataTransferSnapshot(dataTransferSnapshot: &snapshot)
    }
}

#endif
