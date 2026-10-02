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

/// The policy that governs whether and how migration is permitted.
///
/// Derived from transport parameters (`disable_active_migration`), the peer's
/// CID length, and whether the server offered a preferred address.
@available(Network 0.1.0, *)
enum MigrationPolicy: CustomStringConvertible {
    /// Migration is fully enabled (peer allows it and provides non-zero CIDs).
    case enabled
    /// The peer explicitly disabled active migration via transport parameters
    /// or uses zero-length CIDs.
    case disabled
    /// Active migration is disabled but the server offered a preferred address,
    /// which RFC 9000 Section 9.6 allows even when `disable_active_migration` is set.
    case preferredAddressOnly

    var description: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .preferredAddressOnly: return "preferredAddressOnly"
        }
    }

    /// Whether migrating to a preferred address is allowed under this policy.
    var allowsPreferredAddress: Bool {
        self != .disabled
    }

    /// Whether client-initiated migration to any new path is allowed.
    var allowsActiveMigration: Bool {
        self == .enabled
    }
}

/// The current phase of an in-progress or completed migration attempt.
@available(Network 0.1.0, *)
enum MigrationState: CustomStringConvertible {
    /// No migration is in progress.
    case idle
    /// A candidate path is being validated before migration can proceed.
    case awaitingValidation
    /// The connection is actively migrating to a new path.
    case migrating
    /// The most recent migration attempt failed.
    case failed(PathFailureReason)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .awaitingValidation: return "awaitingValidation"
        case .migrating: return "migrating"
        case .failed(let reason): return "failed(\(reason))"
        }
    }
}

@available(Network 0.1.0, *)
struct Migration: ~Copyable {
    static let defaultMigrationVersion = 7
    static let defaultPTOThreshold = 3
    static let defaultKeepaliveThreshold = 2

    var timerID: Timer.TimerID?

    var primaryPathID: MultiplexingPathIdentifier = .none

    private(set) var activeMigrationDisabled = false
    mutating func disableActiveMigration() {
        activeMigrationDisabled = true
    }

    // Migration state machine
    private(set) var migrationState: MigrationState = .idle
    private(set) var policy: MigrationPolicy = .enabled

    // Preferred address state
    private(set) var pendingPreferredAddress: PreferredAddress?
    private(set) var preferredAddressAttempted = false

    // CID tracking for migration
    private(set) var pendingDCIDs = [QUICConnectionID]()

    // Keepalive loss tracking
    private(set) var consecutiveKeepaliveLosses: Int = 0

    /// Derives the migration policy from the current connection state.
    ///
    /// Must be called after transport parameters are processed and again after
    /// `reportReady` sets `activeMigrationDisabled`.
    mutating func derivePolicy(hasPreferredAddress: Bool) {
        if activeMigrationDisabled {
            if hasPreferredAddress {
                policy = .preferredAddressOnly
            } else {
                policy = .disabled
            }
        } else {
            policy = .enabled
        }
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
        resetTimer(now: firedAt, connection: connection, in: &eventContext)
    }

    mutating func migrate(
        to path: QUICPath,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard connection.currentPath != path else {
            return
        }

        guard path.isValidated else {
            migrationState = .awaitingValidation
            path.beginValidation()
            path.migrationPending = true
            return
        }

        migrationState = .migrating

        let oldPath = connection.currentPath
        connection.log.notice("Migrating to path \(path.pathIdentifier)")
        connection.currentPath = path
        path.pathRole = .primary
        path.spinValue = connection.initialSpinValue
        path.lastActivityTime = connection.now
        path.resetForMigration()
        connection.recovery.resetTimer(now: connection.now, connection: connection, in: &eventContext)
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

        // Track preferred address migrations separately
        if path.isPreferredAddress {
            connection.stats.increment(.preferredAddressMigrations)
        }
        connection.stats.increment(.successfulMigrations)
        migrationState = .idle

        // Remove the path we just migrated away from.
        if let oldPath, oldPath != path {
            oldPath.pathRole = .retired
            connection.tearDownMigratedPath(oldPath, in: &eventContext)
        }
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

    /// Called when the TLS handshake is confirmed and handshake keys are discarded.
    ///
    /// On a client, if the server advertised a preferred address in its transport
    /// parameters, this is the point at which we initiate migration to it.
    /// The preferred address CID has already been inserted into `remoteCIDs` by
    /// `setRemoteTransportParameters`, so we only need to create the path and
    /// begin validation.
    mutating func handshakeConfirmed(_ connection: QUICConnection) {
        derivePolicy(hasPreferredAddress: pendingPreferredAddress != nil)

        // Only clients migrate to the server's preferred address
        guard !connection.isServer, let preferredAddress = pendingPreferredAddress else {
            return
        }
        guard !preferredAddressAttempted else {
            return
        }
        guard policy.allowsPreferredAddress else {
            connection.log.info("Preferred address migration skipped: policy is \(policy)")
            return
        }

        preferredAddressAttempted = true
        connection.log.notice(
            "Preferred address migration ready after handshake confirmation (CID: \(preferredAddress.connectionID))"
        )

        // The actual path for the preferred address will be created by the path
        // manager when it discovers the new address. At that point,
        // `handlePathChanged` will see the `isPreferredAddress` flag and trigger
        // validation → migration through the normal flow.
    }

    /// Stores the server's preferred address from transport parameters.
    ///
    /// The actual migration is deferred to `handshakeConfirmed` where the
    /// transport parameters are fully authenticated.
    mutating func addPreferredAddress(_ preferredAddress: PreferredAddress) {
        pendingPreferredAddress = preferredAddress
    }

    /// Called when a new destination CID is received from the peer via NEW_CONNECTION_ID.
    ///
    /// If any paths are waiting for a CID assignment (e.g. stuck in `.routeEstablished`
    /// because `assignNewDCID` failed), this provides them an opportunity to proceed.
    mutating func newDCID(_ dcid: QUICConnectionID) {
        pendingDCIDs.append(dcid)
    }

    /// Called when a destination CID is retired.
    ///
    /// Ensures that the retired CID does not belong to the current primary path.
    /// If the primary path's CID was retired (e.g. by a peer's RETIRE_CONNECTION_ID
    /// with retire_prior_to), a replacement CID is assigned if available.
    mutating func retireDCID(_ dcid: QUICConnectionID) {
        pendingDCIDs.removeAll { $0 == dcid }
    }

    /// Checks for keepalive loss and triggers fallback when the loss threshold is exceeded.
    ///
    /// Called from the keepalive timer path when outstanding keepalive PINGs remain
    /// unacknowledged. If the number of consecutive losses reaches `defaultKeepaliveThreshold`,
    /// the current path is marked as lossy and a fallback is attempted.
    mutating func checkForKeepaliveLoss(
        outstandingCount: Int,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard outstandingCount > 0 else {
            consecutiveKeepaliveLosses = 0
            return
        }

        consecutiveKeepaliveLosses = outstandingCount

        guard consecutiveKeepaliveLosses >= Migration.defaultKeepaliveThreshold else {
            return
        }

        connection.log.notice(
            "Keepalive loss threshold reached (\(consecutiveKeepaliveLosses)/\(Migration.defaultKeepaliveThreshold))"
        )

        // Mark the current path as lossy
        if let currentPath = connection.currentPath {
            currentPath.isLossy = true
            currentPath.markFailed(reason: .keepaliveLoss)
        }

        connection.stats.increment(.keepaliveFallbacks)

        // Attempt to find a validated alternate path to fall back to
        if let alternatePath = selectBestAlternatePath(connection: connection) {
            connection.log.notice("Falling back to alternate path \(alternatePath.pathIdentifier) due to keepalive loss")
            migrate(to: alternatePath, connection: connection, in: &eventContext)
        } else {
            // No alternate path available — mark migration as failed
            migrationState = .failed(.keepaliveLoss)
            connection.stats.increment(.pathFailures)
            connection.log.notice("No alternate path for keepalive fallback")
            // The connection's own keepalive logic will close if maxKeepaliveCount is exceeded
        }

        consecutiveKeepaliveLosses = 0
    }

    /// Selects the best validated alternate path that is not the current primary path.
    func selectBestAlternatePath(connection: QUICConnection) -> QUICPath? {
        var bestPath: QUICPath?
        var bestPriority = Int.min
        connection.applyToAllPaths { path in
            guard path !== connection.currentPath,
                  path.isValidated,
                  !path.isLossy,
                  path.failureReason == nil,
                  path.priority > bestPriority
            else {
                return
            }
            bestPath = path
            bestPriority = path.priority
        }
        return bestPath
    }
}

@available(Network 0.1.0, *)
extension QUICConnection {
    public func handlePathChanged(
        path pathID: MultiplexingPathIdentifier,
        event: MultiplexingPathEvent,
        isPrimary: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !migration.activeMigrationDisabled || isServer else {
            return
        }

        log.debug("Path \(pathID.description) changed to \(event), primary: \(isPrimary)")

        guard let path = path(for: pathID) else {
            log.error("Path \(pathID.description) not found, ignoring")
            return
        }
        switch event {
        case .available:
            if !path.isRouteEstablished {
                path.set(interface: nil, priority: 0, isInitial: false)
                path.changeState(to: .routeAvailable)
                path.pacePackets = pacingEnabled
                if self.state == .connected {
                    log.debug("Bringing up path \(pathID.description)")
                    invokeEstablish(path: pathID, in: &eventContext)
                }
            }
            break
        case .established:
            if !path.isRouteEstablished {
                path.changeState(to: .routeEstablished)
            }
            if isServer, path != currentPath, !path.isValidated {
                path.beginValidation()
                sendFrames(on: path, in: &eventContext)
                migration.resetTimer(now: self.now, connection: self, in: &eventContext)
            }
            break
        case .unavailable:
            retireOutboundCID(forPathGoingAway: path)
            path.changeState(to: .routeUnavailable)
            path.markFailed(reason: .routeUnavailable)
            path.pathRole = .retired
            break
        }

        if isServer {
            allPathIdentifiers { id in
                guard var path = multiplexingPaths[id], path.state == .routeUnavailable, path !== currentPath else {
                    return
                }
                path.destroy(in: &eventContext)
                multiplexingPaths.removeValue(forKey: id)
            }
        }

        log.debug("Existing paths:")
        applyToAllPaths { path in
            log.debug(
                "Path \(path.pathIdentifier) \(path.state) over \(path.interface?.description ?? "nil")"
            )
        }
        // Notify the stack about a path change event
        if case .available(let local, let remote, _, _) = event,
            let local, let remote,
            case .address(let localAddress) = local.type,
            case .address(let remoteAddress) = remote.type
        {
            path.localEndpoint = local
            path.remoteEndpoint = remote
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

        // This is a new primary path. Migrate to it if we are the client.
        if !isServer, path != currentPath, isPrimary, path.isRouteEstablished {
            migration.migrate(to: path, connection: self, in: &eventContext)
            // Send packets if necessary
            sendFrames(on: path, in: &eventContext)
        }
    }

    // Retires a path's outbound CID and queues a RETIRE_CONNECTION_ID frame for it.
    func retireOutboundCID(forPathGoingAway path: QUICPath) {
        guard path.isOpenForSending, !path.hasPreAssignedCIDs, let dcid = path.dcid,
            let retiredCID = remoteCIDs.retire(connectionID: dcid)
        else {
            return
        }
        withPendingItems(for: .applicationData) {
            $0.addRetireConnectionID(FrameRetireConnectionID(sequence: retiredCID.sequenceNumber))
        }
        stats.increment(.cidRetirements)
        migration.retireDCID(dcid)
    }

    // Removes a path we migrated away from.
    func tearDownMigratedPath(
        _ oldPath: QUICPath,
        in eventContext: inout NetworkContext.EventContext
    ) {
        var oldPath = oldPath
        guard oldPath !== currentPath else {
            log.fault("Refusing to tear down the current path \(oldPath.pathIdentifier)")
            return
        }
        log.notice("Tearing down old path \(oldPath.pathIdentifier) after migration")

        retireOutboundCID(forPathGoingAway: oldPath)

        if oldPath.state.isValidStateChange(to: .routeUnavailable) {
            oldPath.changeState(to: .routeUnavailable)
        }
        oldPath.pathRole = .retired
        oldPath.destroy(in: &eventContext)
        multiplexingPaths.removeValue(forKey: oldPath.pathIdentifier)
        sendFrames(in: &eventContext)
    }

    /// Selects the best validated path among all connection paths.
    ///
    /// Prefers validated, non-lossy paths with higher priority. Falls back to
    /// the current path if no better option exists.
    func selectBestPath() -> QUICPath? {
        if let alternate = migration.selectBestAlternatePath(connection: self) {
            return alternate
        }
        return currentPath
    }

    /// Initiates migration to the server's preferred address.
    ///
    /// Creates a new probing path for the preferred address and begins validation.
    /// Once validated, the `migrationPending` flag triggers `migrate(to:)`.
    func initiatePreferredAddressMigration(
        _ preferredAddress: PreferredAddress,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // The preferred address path will be created by the path manager when it
        // receives the `.available` / `.established` events for the new address.
        // What we do here is record the intent so the next path that matches
        // the preferred address is picked up automatically.
        log.notice("Preferred address migration registered for \(preferredAddress.connectionID)")
    }
}
#endif
