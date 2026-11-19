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
@available(Network 0.1.0, *)
struct Migration: ~Copyable {
    static let defaultMigrationVersion = 9
    static let defaultPTOThreshold = 3
    static let defaultKeepaliveThreshold = 2

    var timerID: Timer.TimerID?

    var primaryPathID: MultiplexingPathIdentifier = .none

    let strategy: MigrationStrategy

    init(isServer: Bool) {
        if isServer {
            self.init(strategy: .followPeer(FollowPeerStrategy()))
        } else {
            self.init(strategy: .followPrimary(FollowPrimaryStrategy()))
        }
    }

    init(strategy: MigrationStrategy) {
        self.strategy = strategy
    }

    // Where the peer sent its highest-numbered non-probing packet.
    private(set) var peerPathID: MultiplexingPathIdentifier?
    private var largestNonProbingPacketNumber: PacketNumber?

    // Whether a non-probing packet from the peer moves the peer to a different path. Only the
    // highest-numbered one counts (RFC 9000 9.3).
    func nonProbingPacketMovesPeer(number: PacketNumber, on pathID: MultiplexingPathIdentifier) -> Bool {
        if let largestNonProbingPacketNumber, number <= largestNonProbingPacketNumber {
            return false
        }
        return peerPathID != pathID
    }

    /// What a non-probing packet from the peer means for where the peer is.
    enum PeerPacketResult: Equatable {
        /// The packet is older than the highest-numbered non-probing packet so far, so it says nothing about
        /// where the peer is now (RFC 9000 9.3).
        case olderThanLatest
        /// The packet is the newest, and came from the path the peer was already on.
        case peerStayedOnPath
        /// The packet is the newest, and came from a different path than the one the peer was on.
        case peerMovedToPath
    }

    // Records a non-probing packet from the peer, and reports what it means for where the peer is. Only the
    // highest-numbered one counts, so an older one is ignored. One look at the state does what
    // `nonProbingPacketMovesPeer` and `recordNonProbingPacket` do in two.
    mutating func notePeerPacket(number: PacketNumber, on pathID: MultiplexingPathIdentifier) -> PeerPacketResult {
        if let largestNonProbingPacketNumber, number <= largestNonProbingPacketNumber {
            return .olderThanLatest
        }
        largestNonProbingPacketNumber = number
        let moved = peerPathID != pathID
        peerPathID = pathID
        return moved ? .peerMovedToPath : .peerStayedOnPath
    }

    // Records a non-probing packet from the peer. An older one than the highest-numbered so far
    // is ignored.
    mutating func recordNonProbingPacket(number: PacketNumber, on pathID: MultiplexingPathIdentifier) {
        if let largestNonProbingPacketNumber, number <= largestNonProbingPacketNumber {
            return
        }
        largestNonProbingPacketNumber = number
        peerPathID = pathID
    }

    private(set) var activeMigrationDisabled = false
    mutating func disableActiveMigration() {
        activeMigrationDisabled = true
    }

    private func sendPendingChallenges(
        connection: QUICConnection,
        now: NetworkClock.Instant,
        in eventContext: inout NetworkContext.EventContext
    ) {
        connection.allPathIdentifiers { pathID in
            let hasPendingItems =
                connection.withPath(pathID) { (path: inout QUICPath) -> Bool in
                    path.hasPendingItems(now: now)
                } ?? false
            if hasPendingItems {
                connection.sendFrames(on: pathID, in: &eventContext)
            }
        }
    }

    func resetTimer(
        now: NetworkClock.Instant,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard let timerID else {
            connection.log.fault("Attempt to arm the migration timer when timer ID is unset")
            return
        }

        sendPendingChallenges(connection: connection, now: now, in: &eventContext)

        var firstChallengeTime: NetworkClock.Instant?
        connection.applyToAllPaths { (path: inout QUICPath) in
            if let nextChallengeTime = path.nextChallengeTime {
                guard now < nextChallengeTime else {
                    return
                }
                if let time = firstChallengeTime {
                    if nextChallengeTime < time {
                        firstChallengeTime = nextChallengeTime
                    }
                } else {
                    firstChallengeTime = nextChallengeTime
                }
            }
        }

        guard let firstChallengeTime else {
            // Disable the migration timer in place rather than remove() it: the entry
            // is inserted once at connection setup and reused, so a later resetTimer()
            // re-arms it via reschedule(fromNow: duration) below. remove() would orphan
            // the id, and that later reschedule would silently no-op (find() returns nil).
            connection.timer.reschedule(
                identifier: timerID,
                fromNow: .zero,
                timerNow: now,
                in: &eventContext
            )
            return
        }

        let duration = now.duration(to: firstChallengeTime)
        guard duration >= .zero else {
            connection.log.fault("Unexpectedly negative duration (\(duration)) for migration timer")
            return
        }
        connection.timer.reschedule(
            identifier: timerID,
            fromNow: duration,
            timerNow: now,
            in: &eventContext
        )
    }

    func timerFired(
        at firedAt: NetworkClock.Instant,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        connection.log.debug("Migration timer fired")

        // The timer must be re-armed even when no challenge is due: `Timer` fires up to
        // `Timer.timerThreshold` early and has already disabled the entry, so an early wakeup would
        // otherwise stall probing. `resetTimer` sends whatever is due before arming.
        resetTimerAndReportPaths(now: firedAt, connection: connection, in: &eventContext)
    }

    /// Resets the timer, and runs the migration strategy for what the reset found out.
    func resetTimerAndReportPaths(
        now: NetworkClock.Instant,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let before = connection.migrationPathStates
        resetTimer(now: now, connection: connection, in: &eventContext)

        // Sending a challenge can find a path has run out of probes and mark it unreachable.
        // That happens while frames are being built, where the strategy cannot run, so report it
        // from here. The send that did it may also have been an ordinary one before this timer
        // fired, so report every unusable path, not only the ones that changed just now: if it is
        // the current path, the strategy has to move off it.
        var events = connection.migrationEvents(since: before)
        connection.applyToAllPaths { (path: inout QUICPath) in
            if path.state.isUnusable, !events.contains(.pathChanged(path.pathIdentifier)) {
                events.append(.pathChanged(path.pathIdentifier))
            }
        }
        connection.runMigrationStrategy(events: events, in: &eventContext)
    }

    func migrate(
        to pathID: MultiplexingPathIdentifier,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard connection.currentPathID != pathID else {
            return
        }

        let isServer = connection.isServer
        let initialSpinValue = connection.initialSpinValue
        // What it takes to decide, taken in one borrow. The path is looked at again later, since
        // migrating calls out to the application and to the other paths.
        guard
            let candidate = connection.withPath(
                pathID,
                { (path: inout QUICPath) -> (isValidated: Bool, isProbing: Bool, local: Endpoint?, remote: Endpoint?) in
                    (path.isValidated, path.isProbing, path.localEndpoint, path.remoteEndpoint)
                }
            )
        else {
            return
        }

        // A server follows the peer onto a path while it validates it (RFC 9000 9.3). A client
        // only moves to a path it has validated.
        guard candidate.isValidated || (isServer && candidate.isProbing) else {
            connection.log.fault("Refusing to migrate to unvalidated path \(pathID)")
            return
        }

        connection.log.notice("Migrating to path \(pathID)")
        connection.currentPathID = pathID
        if let localEndpoint = candidate.local, let remoteEndpoint = candidate.remote,
            case .address(let localAddress) = localEndpoint.type,
            case .address(let remoteAddress) = remoteEndpoint.type
        {
            let pathInfo = QUICPathInfo(
                isValidated: candidate.isValidated,
                remote: remoteAddress,
                local: localAddress
            )
            connection.deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .pathCurrent(pathInfo)),
                in: &eventContext
            )
        } else {
            connection.log.error("Path \(pathID) is missing endpoints, not delivering pathCurrent")
        }
        _ = connection.withPath(pathID) { (path: inout QUICPath) in
            path.spinValue = initialSpinValue
        }
        connection.recovery.resetTimer(now: connection.now, connection: connection, in: &eventContext)
        // PMTUD sends probes, so the new current path is borrowed for work while it starts
        _ = connection.withPathWork(pathID, replayingSendsIn: &eventContext) { (path: inout QUICPath, ctx) in
            path.resetPacer()
            path.withPMTUDState { (state: inout PMTUDState, path: inout QUICPath) in
                state.start(on: &path, in: &ctx)
            }
        }
        var cursor = connection.startPathIteration()
        while let otherPathID = connection.nextPathIdentifier(&cursor) {
            if otherPathID == pathID { continue }
            _ = connection.withPath(otherPathID) { (otherPath: inout QUICPath) in
                otherPath.pmtudState.stop(connection: connection)
            }
        }
        if !connection.isServer {
            // Insert a PING frame if we have no ack eliciting frames to send.
            if !connection.applicationPendingItems.hasAckElicitingPendingItems {
                connection.withPendingItems(for: .applicationData) {
                    $0.ping = true
                }
            }
            connection.sendFrames(in: &eventContext)
        }
        // TODO: Handle preferred address migration

        // Which of the other paths to keep is up to the migration strategy.
    }

    func probingPathCount(_ connection: QUICConnection) -> Int {
        var probingPaths = 0
        connection.applyToAllPaths { (path: inout QUICPath) in
            if path.state.isProbing {
                probingPaths += 1
            }
        }
        return probingPaths
    }

    func addPreferredAddress(_ preferredAddress: PreferredAddress) {
        // TODO: pending preferred address migration support
    }

    func checkForKeepaliveLoss(outstandingCount: Int) {
        // TODO: pending keepalive loss detection for migration
    }
}

/// What waits for the frames of a packet to have been processed.
///
/// A path's update cannot look at the other paths or run the migration strategy, and the strategy
/// must not run in the middle of a packet. The work is noted here and done once the packet is handled.
/// It is one value so that the per-packet bookkeeping is one look at it, not one for each field.
@available(Network 0.1.0, *)
struct PacketMigrationWork {
    /// Migration events wait for the end of the packet, while this is set
    var isHandlingPacket = false
    var pendingMigrationEvents: [MigrationEvent] = []
    /// A path changed what the migration timer waits for, and the timer is reset at the end of the packet or send.
    var migrationTimerResetPending = false
    /// The time the path that asked for the reset was working at, which the reset is measured from
    var migrationTimerResetNow: NetworkClock.Instant = .zero

    /// Ends a packet whose handling was cut short. Whatever waited for its end is dropped.
    @inline(always)
    mutating func abandonPacket() {
        isHandlingPacket = false
        if !pendingMigrationEvents.isEmpty {
            pendingMigrationEvents.removeAll()
        }
    }

    /// Ends a packet, and hands back the work that waited for its end, or `nil` if nothing did.
    @inline(always)
    mutating func finishPacket() -> (events: [MigrationEvent], timerResetPending: Bool)? {
        isHandlingPacket = false
        guard !pendingMigrationEvents.isEmpty || migrationTimerResetPending else { return nil }
        let events = pendingMigrationEvents
        if !events.isEmpty {
            pendingMigrationEvents.removeAll()
        }
        return (events, migrationTimerResetPending)
    }

    /// Takes the request to reset the migration timer, with the time it was made at, if there is one.
    @inline(always)
    mutating func takeTimerReset() -> NetworkClock.Instant? {
        guard migrationTimerResetPending else { return nil }
        migrationTimerResetPending = false
        defer { migrationTimerResetNow = .zero }
        return migrationTimerResetNow
    }
}

// Every path's state, taken before a change so that the strategy can be told what changed.
@available(Network 0.1.0, *)
struct MigrationPathStates {
    let currentPathID: MultiplexingPathIdentifier?
    let paths: [MigrationContext.PathSnapshot]
}

@available(Network 0.1.0, *)
extension QUICPath {
    var migrationSnapshot: MigrationContext.PathSnapshot {
        MigrationContext.PathSnapshot(identifier: pathIdentifier, state: state, isPrimary: pathIsPrimary)
    }
}

@available(Network 0.1.0, *)
extension QUICConnection {
    // A strategy that keeps asking for changes after this many events is not settling.
    static let maximumMigrationEvents = 32

    public func handlePathChanged(
        path pathID: MultiplexingPathIdentifier,
        event: MultiplexingPathEvent,
        pathProperties: MultiplexingPathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // A path that is gone is marked unavailable whether or not active migration is enabled
        let pathIsGone = if case .unavailable = event { true } else { false }
        guard !migration.activeMigrationDisabled || isServer || pathIsGone else {
            return
        }

        log.debug("Path \(pathID.description) changed to \(event), primary: \(pathProperties.isPrimary)")

        guard hasPath(pathID) else {
            log.error("Path \(pathID.description) not found, ignoring")
            return
        }

        // A new path starts out with what the current path has learned about the peer. The current path is
        // looked at first, since the new path is borrowed for the update.
        let inheritedRemoteMaxAckDelay = withCurrentPath { (path: inout QUICPath) in path.rtt.remoteMaxAckDelay }
        let before = migrationPathStates
        let pacingEnabled = self.pacingEnabled
        let isValidated: Bool? = withPath(pathID) { (path: inout QUICPath) -> Bool in
            switch event {
            case .available:
                if path.state.isInvalid {
                    // Set before `set()`, which creates the pacer based on `pacePackets`.
                    path.pacePackets = pacingEnabled
                    path.set(
                        interface: nil,
                        priority: 0,
                        isInitial: false,
                        inheriting: QUICPath.Inheritance(
                            remoteMaxAckDelay: inheritedRemoteMaxAckDelay,
                            sharedInterfaceMSS: nil
                        )
                    )
                    setupL4S(on: &path)
                    path.state = .routeAvailable
                }
            case .established:
                if !path.isRouteEstablished {
                    path.state = .routeEstablished
                }
            case .unavailable:
                path.state = .routeUnavailable
            }
            return path.isValidated
        }
        guard let isValidated else { return }

        logExistingPaths()

        // Notify the stack about a path change event
        if case .available(let local, let remote, _, _) = event,
            let local, let remote,
            case .address(let localAddress) = local.type,
            case .address(let remoteAddress) = remote.type
        {
            let pathInfo = QUICPathInfo(
                isValidated: isValidated,
                remote: remoteAddress,
                local: localAddress
            )
            deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .pathChanged(pathInfo)),
                in: &eventContext
            )
        }

        var events = migrationEvents(since: before)
        if !events.contains(.pathChanged(pathID)) {
            events.append(.pathChanged(pathID))
        }
        runMigrationStrategy(events: events, in: &eventContext)
    }

    func logExistingPaths() {
        log.debug("Existing paths:")
        applyToAllPaths { (path: inout QUICPath) in
            log.debug(
                "Path \(path.pathIdentifier) \(path.state) over \(path.interface?.description ?? "nil")"
            )
        }
    }

    private func migrationContext(currentPathID: MultiplexingPathIdentifier) -> MigrationContext? {
        var currentSnapshot: MigrationContext.PathSnapshot?
        var otherPaths: [MigrationContext.PathSnapshot] = []
        otherPaths.reserveCapacity(pathCount)
        applyToAllPaths { (path: inout QUICPath) in
            if path.pathIdentifier == currentPathID {
                currentSnapshot = path.migrationSnapshot
            } else {
                otherPaths.append(path.migrationSnapshot)
            }
        }
        guard let currentSnapshot else { return nil }
        otherPaths.sort { $0.identifier < $1.identifier }
        return MigrationContext(
            currentPath: currentSnapshot,
            otherPaths: otherPaths,
            peerPathID: migration.peerPathID
        )
    }

    // What the paths look like now, so that `migrationEvents(since:)` can tell what changed.
    var migrationPathStates: MigrationPathStates {
        var paths: [MigrationContext.PathSnapshot] = []
        paths.reserveCapacity(pathCount)
        applyToAllPaths { (path: inout QUICPath) in
            paths.append(path.migrationSnapshot)
        }
        return MigrationPathStates(currentPathID: currentPathID, paths: paths)
    }

    // The changes made to the connection's paths since `before` was taken.
    func migrationEvents(since before: MigrationPathStates) -> [MigrationEvent] {
        let after = migrationPathStates
        var events: [MigrationEvent] = []
        for oldPath in before.paths {
            guard let newPath = after.paths.first(where: { $0.identifier == oldPath.identifier }) else {
                continue
            }
            let wasCurrent = oldPath.identifier == before.currentPathID
            let isCurrent = newPath.identifier == after.currentPathID
            if newPath.state != oldPath.state || wasCurrent != isCurrent {
                events.append(.pathChanged(oldPath.identifier))
            }
        }
        return events
    }

    // Reports every path as changed, for when the strategy could not run while they did.
    func runMigrationStrategyForAllPaths(in eventContext: inout NetworkContext.EventContext) {
        var pathIDs: [MultiplexingPathIdentifier] = []
        allPathIdentifiers { pathIDs.append($0) }
        runMigrationStrategy(events: pathIDs.sorted().map { .pathChanged($0) }, in: &eventContext)
    }

    // Gives `events` to the migration strategy and applies what it decides. The changes each
    // decision makes are fed back as further events until the strategy has nothing left to do.
    func runMigrationStrategy(events: [MigrationEvent], in eventContext: inout NetworkContext.EventContext) {
        // Neither side may migrate during the handshake. Confirming it reports every path as
        // changed, which lets the strategy catch up on everything dropped here.
        guard isHandshakeConfirmed else {
            return
        }
        guard !isHandlingPacket else {
            for event in events where !pendingMigrationEvents.contains(event) {
                pendingMigrationEvents.append(event)
            }
            return
        }
        if !migration.activeMigrationDisabled || isServer {
            applyMigrationStrategy(events: events, in: &eventContext)
        }
        if currentPathID != nil, !state.isTerminal {
            tearDownUnusablePaths(in: &eventContext)
        }
    }

    // Called once a packet's frames have been handled.
    func finishHandlingPacket(in eventContext: inout NetworkContext.EventContext) {
        // Nearly every packet has nothing waiting, which this finds in one look at the state
        guard let work = migrationWork.finishPacket() else { return }
        if !work.events.isEmpty {
            runMigrationStrategy(events: work.events, in: &eventContext)
        }
        // Running the strategy can ask for a reset too
        resetMigrationTimerIfPending(in: &eventContext)
    }

    // A path that sent a challenge, or got the answer to one, changed when the migration timer is due.
    // The timer looks at every path, which a path cannot do from inside its own update, so the path asks
    // for the reset and it runs here, once the paths are all back in the entries.
    func resetMigrationTimerIfPending(in eventContext: inout NetworkContext.EventContext) {
        guard var resetNow = migrationWork.takeTimerReset() else { return }
        guard migration.timerID != nil else { return }
        // Resetting the timer sends the challenges that are due, which can find that a path has run out of
        // probes, so the strategy is run for that, as it is when the timer fires. It can ask for another reset.
        var remainingResets = Self.maximumMigrationEvents
        while true {
            migration.resetTimerAndReportPaths(
                now: resetNow == .zero ? now : resetNow,
                connection: self,
                in: &eventContext
            )
            remainingResets -= 1
            guard remainingResets > 0, let again = migrationWork.takeTimerReset() else { return }
            resetNow = again
        }
    }

    private func applyMigrationStrategy(
        events: [MigrationEvent],
        in eventContext: inout NetworkContext.EventContext
    ) {
        var events = events
        var remainingEvents = Self.maximumMigrationEvents
        while !events.isEmpty {
            guard !state.isTerminal, let currentPathID else {
                return
            }
            guard remainingEvents > 0 else {
                log.fault("Migration strategy did not settle, dropping \(events.count) events")
                return
            }
            remainingEvents -= 1
            let event = events.removeFirst()
            guard let context = migrationContext(currentPathID: currentPathID) else {
                return
            }
            for decision in migration.strategy.pathEvent(event, now: now, context: context) {
                let before = migrationPathStates
                apply(decision, in: &eventContext)
                events += migrationEvents(since: before)
            }
        }
    }

    // A client keeps the paths that come from the system and only tears down injected ones. A
    // server's paths follow the peer, so it has no use for unusable ones.
    private func tearDownUnusablePaths(in eventContext: inout NetworkContext.EventContext) {
        var unusablePathIDs: [MultiplexingPathIdentifier] = []
        let currentPathID = self.currentPathID
        let isServer = self.isServer
        applyToAllPaths { (path: inout QUICPath) in
            if path.state.isUnusable, path.pathIdentifier != currentPathID, isServer || path.pathIsInjected {
                unusablePathIDs.append(path.pathIdentifier)
            }
        }
        for pathID in unusablePathIDs {
            tearDownPath(pathID, in: &eventContext)
        }
    }

    private func apply(_ decision: MigrationDecision, in eventContext: inout NetworkContext.EventContext) {
        switch decision {
        case .bringUp(let pathID):
            guard withPath(pathID, { (path: inout QUICPath) in path.state == .routeAvailable }) == true else { return }
            log.debug("Bringing up path \(pathID.description)")
            invokeEstablish(path: pathID, in: &eventContext)
        case .assignCID(let pathID):
            _ = withPath(pathID) { (path: inout QUICPath) in
                guard path.state == .routeEstablished else { return }
                assignNewDCID(to: &path, in: &eventContext)
            }
        // If it succeeds, the migration will get an event.
        case .probe(let pathID):
            let isReady = withPath(pathID) { (path: inout QUICPath) -> Bool in
                guard path.state == .cidAssigned else { return false }
                path.beginValidation(in: &eventContext)
                return true
            }
            guard isReady == true else { return }
            log.debug("Probing path \(pathID.description)")
            sendFrames(on: pathID, in: &eventContext)
            migration.resetTimer(now: now, connection: self, in: &eventContext)
        case .migrateTo(let pathID):
            let isEligible = withPath(pathID) { (path: inout QUICPath) -> Bool in
                path.isValidated || (isServer && path.isProbing)
            }
            guard isEligible == true, pathID != currentPathID else { return }
            migration.migrate(to: pathID, connection: self, in: &eventContext)
            sendFrames(on: pathID, in: &eventContext)
        case .tearDown(let pathID):
            guard pathID != currentPathID else { return }
            tearDownPath(pathID, in: &eventContext)
        }
    }

    // Retires one of the peer's CIDs that a path has given up, unless the peer has retired it
    // already. A path can give up its CID while a packet is being built, when the pending items
    // are in use, so the RETIRE_CONNECTION_ID frame is queued here and added on the next send.
    func retireOutboundCID(_ dcid: QUICConnectionID) {
        guard let retiredCID = remoteCIDs.retire(connectionID: dcid) else {
            return
        }
        queuedRetireConnectionIDSequences.append(retiredCID.sequenceNumber)
    }

    func addQueuedRetireConnectionIDs(to applicationPendingItems: inout PendingItems) {
        guard !queuedRetireConnectionIDSequences.isEmpty else {
            return
        }
        for sequence in queuedRetireConnectionIDSequences {
            applicationPendingItems.addRetireConnectionID(FrameRetireConnectionID(sequence: sequence))
        }
        queuedRetireConnectionIDSequences.removeAll()
    }

    // Destroys a path and removes it from the connection; its CID goes with its state. A path
    // whose datagrams are being handled waits until they have been; then `finishReceiving` asks the
    // strategy again whether it should go.
    func tearDownPath(
        _ pathID: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard pathID != currentPathID else {
            log.fault("Refusing to tear down the current path \(pathID)")
            return
        }
        guard pathID != receivingPathID else {
            log.debug("Deferring teardown of path \(pathID) until its datagrams are handled")
            if !deferredTeardownPathIDs.contains(pathID) {
                deferredTeardownPathIDs.append(pathID)
            }
            return
        }
        guard var path = removePath(pathID) else {
            return
        }
        log.notice("Tearing down path \(pathID) (\(path.state))")
        path.state = .routeUnavailable
        path.destroy(in: &eventContext)
        sendFrames(in: &eventContext)
    }

    // Called once the datagrams received on `receivingPathID` have been handled.
    func finishReceiving(in eventContext: inout NetworkContext.EventContext) {
        receivingPathID = nil
        let pathIDs = deferredTeardownPathIDs
        deferredTeardownPathIDs.removeAll()
        guard !pathIDs.isEmpty, !state.isTerminal, let currentPathID else {
            return
        }
        var events: [MigrationEvent] = [.pathChanged(currentPathID)]
        for pathID in pathIDs where pathID != currentPathID && hasPath(pathID) {
            events.append(.pathChanged(pathID))
        }
        runMigrationStrategy(events: events, in: &eventContext)
    }
}
#endif
