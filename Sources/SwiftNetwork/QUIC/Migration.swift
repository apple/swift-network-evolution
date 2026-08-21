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
    static let defaultMigrationVersion = 7
    static let defaultPTOThreshold = 3
    static let defaultKeepaliveThreshold = 2

    var timerID: Timer.TimerID?

    var primaryPathID: MultiplexingPathIdentifier = .none

    private(set) var activeMigrationDisabled = false
    mutating func disableActiveMigration() {
        activeMigrationDisabled = true
    }

    private func sendPendingChallenges(
        connection: QUICConnection,
        now: NetworkClock.Instant = NetworkClock.Instant.now
    ) {
        connection.applyToAllPaths { path in
            if path.hasPendingItems(now: now) {
                connection.sendFrames(on: path)
            }
        }
    }

    func resetTimer(connection: QUICConnection) {
        guard let timerID else {
            connection.log.fault("Attempt to arm the migration timer when timer ID is unset")
            return
        }

        let now = NetworkClock.Instant.now
        sendPendingChallenges(connection: connection, now: now)

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
                timerNow: connection.now
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
            timerNow: connection.now
        )
    }

    func timerFired(connection: QUICConnection) {
        connection.log.debug("Migration timer fired")

        sendPendingChallenges(connection: connection)
    }

    func migrate(to path: QUICPath, connection: QUICConnection) {
        guard connection.currentPath != path else {
            return
        }

        guard path.isValidated else {
            path.beginValidation()
            path.migrationPending = true
            return
        }

        let oldPath = connection.currentPath
        connection.log.notice("Migrating to path \(path.identifier)")
        connection.currentPath = path
        path.spinValue = connection.initialSpinValue
        connection.recovery.resetTimer(connection: connection)
        path.resetPacer()
        path.pmtudState.start(on: path)
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
            connection.sendFrames()
        }
        // TODO: Handle preferred address migration

        // Remove the path we just migrated away from.
        if let oldPath, oldPath != path {
            connection.tearDownMigratedPath(oldPath)
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

    func handshakeConfirmed(_ connection: QUICConnection) {
        // TODO: pending migration feature completion
    }

    func addPreferredAddress(_ preferredAddress: PreferredAddress) {
        // TODO: pending preferred address migration support
    }

    func newDCID(_ dcid: QUICConnectionID) {
        // TODO: pending DCID migration handling
    }

    func retireDCID(_ dcid: QUICConnectionID) {
        // TODO: pending DCID retirement during migration
    }

    func checkForKeepaliveLoss(outstandingCount: Int) {
        // TODO: pending keepalive loss detection for migration
    }
}

@available(Network 0.1.0, *)
extension QUICConnection {
    public func handlePathChanged(
        path pathID: MultiplexingPathIdentifier,
        event: MultiplexingPathEvent,
        isPrimary: Bool
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
                    invokeEstablish(path: pathID)
                }
            }
            break
        case .established:
            if !path.isRouteEstablished {
                path.changeState(to: .routeEstablished)
            }
            if isServer, path != currentPath, !path.isValidated {
                path.beginValidation()
                sendFrames(on: path)
                migration.resetTimer(connection: self)
            }
            break
        case .unavailable:
            retireOutboundCID(forPathGoingAway: path)
            path.changeState(to: .routeUnavailable)
            break
        }

        if isServer {
            for (id, path) in multiplexingPaths where path.state == .routeUnavailable {
                multiplexingPaths.removeValue(forKey: id)
            }
        }

        log.debug("Existing paths:")
        applyToAllPaths { path in
            log.debug(
                "Path \(path.identifier) \(path.state) over \(path.interface?.description ?? "nil")"
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
            deliverNetworkProtocolEvent(flow: .allFlows, event: .init(quicEvent: .pathChanged(pathInfo)))
        }

        // This is a new primary path. Migrate to it if we are the client.
        if !isServer, path != currentPath, isPrimary, path.isRouteEstablished {
            migration.migrate(to: path, connection: self)
            // Send packets if necessary
            sendFrames(on: path)
        }
    }

    // Retires a path's outbound CID and queues a RETIRE_CONNECTION_ID frame for it.
    func retireOutboundCID(forPathGoingAway path: QUICPath) {
        guard path.isOpenForSending, !path.hasPreAssignedCIDs, let dcid = path.dcid,
            let sequence = remoteCIDs.retire(connectionID: dcid)
        else {
            return
        }
        withPendingItems(for: .applicationData) {
            $0.addRetireConnectionID(FrameRetireConnectionID(sequence: sequence))
        }
    }

    // Removes a path we migrated away from.
    func tearDownMigratedPath(_ oldPath: QUICPath) {
        guard oldPath !== currentPath else {
            log.fault("Refusing to tear down the current path \(oldPath.identifier)")
            return
        }
        log.notice("Tearing down old path \(oldPath.identifier) after migration")

        retireOutboundCID(forPathGoingAway: oldPath)

        if oldPath.state.isValidStateChange(to: .routeUnavailable) {
            oldPath.changeState(to: .routeUnavailable)
        }
        oldPath.tearDownLowerStack()
        multiplexingPaths.removeValue(forKey: oldPath.identifier)
        sendFrames()
    }
}
#endif
