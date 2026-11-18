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
        connection.applyToAllPaths { path in
            if path.hasPendingItems(now: now) {
                connection.sendFrames(on: path, in: &eventContext)
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
        connection.applyToAllPaths { path in
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
        let before = connection.migrationPathStates
        resetTimer(now: firedAt, connection: connection, in: &eventContext)

        // Sending a challenge can find a path has run out of probes and mark it unreachable.
        // That happens while frames are being built, where the strategy cannot run, so report it
        // from here. The send that did it may also have been an ordinary one before this timer
        // fired, so report every unusable path, not only the ones that changed just now: if it is
        // the current path, the strategy has to move off it.
        var events = connection.migrationEvents(since: before)
        connection.applyToAllPaths { path in
            if path.state.isUnusable, !events.contains(.pathChanged(path.pathIdentifier)) {
                events.append(.pathChanged(path.pathIdentifier))
            }
        }
        connection.runMigrationStrategy(events: events, in: &eventContext)
    }

    func migrate(
        to path: QUICPath,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard connection.currentPath != path else {
            return
        }

        // A server follows the peer onto a path while it validates it (RFC 9000 9.3). A client
        // only moves to a path it has validated.
        guard path.isValidated || (connection.isServer && path.isProbing) else {
            connection.log.fault("Refusing to migrate to unvalidated path \(path.pathIdentifier)")
            return
        }

        connection.log.notice("Migrating to path \(path.pathIdentifier)")
        connection.currentPath = path
        if let localEndpoint = path.localEndpoint, let remoteEndpoint = path.remoteEndpoint,
            case .address(let localAddress) = localEndpoint.type,
            case .address(let remoteAddress) = remoteEndpoint.type
        {
            let pathInfo = QUICPathInfo(
                isValidated: path.isValidated,
                remote: remoteAddress,
                local: localAddress
            )
            connection.deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .pathCurrent(pathInfo)),
                in: &eventContext
            )
        } else {
            connection.log.error("Path \(path.pathIdentifier) is missing endpoints, not delivering pathCurrent")
        }
        path.spinValue = connection.initialSpinValue
        connection.recovery.resetTimer(now: connection.now, connection: connection, in: &eventContext)
        path.resetPacer()
        path.pmtudState.start(on: path, in: &eventContext)
        connection.applyToAllPaths { otherPath in
            if otherPath != path {
                otherPath.pmtudState.stop(on: otherPath)
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
        connection.applyToAllPaths { path in
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
        isPrimary: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // A path that is gone is marked unavailable whether or not active migration is enabled
        let pathIsGone = if case .unavailable = event { true } else { false }
        guard !migration.activeMigrationDisabled || isServer || pathIsGone else {
            return
        }

        log.debug("Path \(pathID.description) changed to \(event), primary: \(isPrimary)")

        guard let path = path(for: pathID) else {
            log.error("Path \(pathID.description) not found, ignoring")
            return
        }

        let before = migrationPathStates
        switch event {
        case .available:
            if path.state.isInvalid {
                // Set before `set()`, which creates the pacer based on `pacePackets`.
                path.pacePackets = pacingEnabled
                path.set(interface: nil, priority: 0, isInitial: false)
                setupL4S(on: path)
                path.state = .routeAvailable
            }
        case .established:
            if !path.isRouteEstablished {
                path.state = .routeEstablished
            }
        case .unavailable:
            path.state = .routeUnavailable
        }

        logExistingPaths()

        // Notify the stack about a path change event
        if case .available(let local, let remote, _, _) = event,
            let local, let remote,
            case .address(let localAddress) = local.type,
            case .address(let remoteAddress) = remote.type
        {
            let pathInfo = QUICPathInfo(
                isValidated: path.isValidated,
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
        applyToAllPaths { path in
            log.debug(
                "Path \(path.pathIdentifier) \(path.state) over \(path.interface?.description ?? "nil")"
            )
        }
    }

    private func migrationContext(currentPath: QUICPath) -> MigrationContext {
        var otherPaths: [MigrationContext.PathSnapshot] = []
        otherPaths.reserveCapacity(multiplexingPaths.count)
        applyToAllPaths { path in
            if path !== currentPath {
                otherPaths.append(path.migrationSnapshot)
            }
        }
        otherPaths.sort { $0.identifier < $1.identifier }
        return MigrationContext(
            currentPath: currentPath.migrationSnapshot,
            otherPaths: otherPaths,
            peerPathID: migration.peerPathID
        )
    }

    // What the paths look like now, so that `migrationEvents(since:)` can tell what changed.
    var migrationPathStates: MigrationPathStates {
        var paths: [MigrationContext.PathSnapshot] = []
        paths.reserveCapacity(multiplexingPaths.count)
        applyToAllPaths { path in
            paths.append(path.migrationSnapshot)
        }
        return MigrationPathStates(currentPathID: currentPath?.pathIdentifier, paths: paths)
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
        if currentPath != nil, !state.isTerminal {
            tearDownUnusablePaths(in: &eventContext)
        }
    }

    // Called once a packet's frames have been handled.
    func finishHandlingPacket(in eventContext: inout NetworkContext.EventContext) {
        isHandlingPacket = false
        guard !pendingMigrationEvents.isEmpty else {
            return
        }
        let events = pendingMigrationEvents
        pendingMigrationEvents.removeAll()
        runMigrationStrategy(events: events, in: &eventContext)
    }

    private func applyMigrationStrategy(
        events: [MigrationEvent],
        in eventContext: inout NetworkContext.EventContext
    ) {
        var events = events
        var remainingEvents = Self.maximumMigrationEvents
        while !events.isEmpty {
            guard !state.isTerminal, let currentPath else {
                return
            }
            guard remainingEvents > 0 else {
                log.fault("Migration strategy did not settle, dropping \(events.count) events")
                return
            }
            remainingEvents -= 1
            let event = events.removeFirst()
            let context = migrationContext(currentPath: currentPath)
            for decision in migration.strategy.pathEvent(event, now: now, context: context) {
                let before = migrationPathStates
                apply(decision, in: &eventContext)
                events += migrationEvents(since: before)
            }
        }
    }

    private func tearDownUnusablePaths(in eventContext: inout NetworkContext.EventContext) {
        var unusablePaths: [QUICPath] = []
        applyToAllPaths { path in
            if path.state.isUnusable, path !== currentPath {
                // TODO: paths that come from the system and are unreachable CANNOT be torn down
                unusablePaths.append(path)
            }
        }
        for path in unusablePaths {
            tearDownPath(path, in: &eventContext)
        }
    }

    private func apply(_ decision: MigrationDecision, in eventContext: inout NetworkContext.EventContext) {
        switch decision {
        case .bringUp(let pathID):
            guard let path = path(for: pathID), path.state == .routeAvailable else { return }
            log.debug("Bringing up path \(pathID.description)")
            invokeEstablish(path: pathID, in: &eventContext)
        case .assignCID(let pathID):
            guard let path = path(for: pathID), path.state == .routeEstablished else { return }
            assignNewDCID(to: path, in: &eventContext)
        // If it succeeds, the migration will get an event.
        case .probe(let pathID):
            guard let path = path(for: pathID), path.state == .cidAssigned else { return }
            log.debug("Probing path \(pathID.description)")
            path.beginValidation(in: &eventContext)
            sendFrames(on: path, in: &eventContext)
            migration.resetTimer(now: now, connection: self, in: &eventContext)
        case .migrateTo(let pathID):
            guard let path = path(for: pathID), path.isValidated || (isServer && path.isProbing),
                path !== currentPath
            else { return }
            migration.migrate(to: path, connection: self, in: &eventContext)
            sendFrames(on: path, in: &eventContext)
        case .tearDown(let pathID):
            guard let path = path(for: pathID), path !== currentPath else { return }
            tearDownPath(path, in: &eventContext)
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
        _ path: QUICPath,
        in eventContext: inout NetworkContext.EventContext
    ) {
        var path = path
        guard path !== currentPath else {
            log.fault("Refusing to tear down the current path \(path.pathIdentifier)")
            return
        }
        guard path.pathIdentifier != receivingPathID else {
            log.debug("Deferring teardown of path \(path.pathIdentifier) until its datagrams are handled")
            if !deferredTeardownPathIDs.contains(path.pathIdentifier) {
                deferredTeardownPathIDs.append(path.pathIdentifier)
            }
            return
        }
        log.notice("Tearing down path \(path.pathIdentifier) (\(path.state))")
        path.state = .routeUnavailable
        path.destroy(in: &eventContext)
        multiplexingPaths.removeValue(forKey: path.pathIdentifier)
        sendFrames(in: &eventContext)
    }

    // Called once the datagrams received on `receivingPathID` have been handled.
    func finishReceiving(in eventContext: inout NetworkContext.EventContext) {
        receivingPathID = nil
        let pathIDs = deferredTeardownPathIDs
        deferredTeardownPathIDs.removeAll()
        guard !pathIDs.isEmpty, !state.isTerminal, let currentPath else {
            return
        }
        var events: [MigrationEvent] = [.pathChanged(currentPath.pathIdentifier)]
        for pathID in pathIDs where pathID != currentPath.pathIdentifier && path(for: pathID) != nil {
            events.append(.pathChanged(pathID))
        }
        runMigrationStrategy(events: events, in: &eventContext)
    }
}
#endif
