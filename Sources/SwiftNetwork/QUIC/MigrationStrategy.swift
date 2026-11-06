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
// What a migration strategy can see of the connection.
//
// A strategy only runs once the handshake is confirmed, since neither side may migrate before
// then (RFC 9000 9).
@available(Network 0.1.0, *)
struct MigrationContext: Equatable, Sendable {
    struct PathSnapshot: Equatable {
        // Strategies get value snapshots rather than `QUICPath`, so they cannot change a path.
        let identifier: MultiplexingPathIdentifier
        let state: QUICPathState
        let isPrimary: Bool

        init(identifier: MultiplexingPathIdentifier, state: QUICPathState, isPrimary: Bool = false) {
            self.identifier = identifier
            self.state = state
            self.isPrimary = isPrimary
        }
    }

    let currentPath: PathSnapshot
    let otherPaths: [PathSnapshot]

    // The path the peer sent its highest-numbered non-probing packet on, if a server has
    // received one.
    var peerPathID: MultiplexingPathIdentifier? = nil
}

// Something that happened to one of the connection's paths. Strategies decide from the context;
// the event only says which path to look at.
@available(Network 0.1.0, *)
enum MigrationEvent: Equatable {
    // Something about the path changed: its state, its route being announced again (which is how
    // a change of primary path arrives), it becoming or no longer being the current path, or the
    // peer moving onto it. Once the handshake is confirmed, every path gets one.
    case pathChanged(MultiplexingPathIdentifier)
    // The peer sent a probing packet, or an older non-probing one, on a path that is not
    // validated yet. Unlike the rest, this is not recorded in the context.
    case peerProbed(MultiplexingPathIdentifier)

    var pathIdentifier: MultiplexingPathIdentifier {
        switch self {
        case .pathChanged(let identifier), .peerProbed(let identifier):
            return identifier
        }
    }
}

// Something a strategy wants done to a path.
//
// Decisions name a path by identifier rather than holding it: an earlier decision can change or
// remove the path, so the connection looks it up again and skips a decision that no longer
// applies.
@available(Network 0.1.0, *)
enum MigrationDecision: Equatable {
    case bringUp(MultiplexingPathIdentifier)
    case assignCID(MultiplexingPathIdentifier)
    case probe(MultiplexingPathIdentifier)
    case migrateTo(MultiplexingPathIdentifier)
    case tearDown(MultiplexingPathIdentifier)
}

// Decides what to do with the connection's paths when one of them changes.
//
// A strategy has no side effects. The connection applies its decisions and reports the changes
// they cause back to it as new events, so a strategy only ever takes one step at a time.
@available(Network 0.1.0, *)
protocol MigrationStrategyProtocol: Equatable {
    func pathEvent(
        _ event: MigrationEvent,
        now: NetworkClock.Instant,
        context: MigrationContext
    ) -> [MigrationDecision]
}

// The strategy a connection uses.
@available(Network 0.1.0, *)
enum MigrationStrategy: Equatable {
    case followPrimary(FollowPrimaryStrategy)
    case followPeer(FollowPeerStrategy)

    func pathEvent(
        _ event: MigrationEvent,
        now: NetworkClock.Instant,
        context: MigrationContext
    ) -> [MigrationDecision] {
        switch self {
        case .followPrimary(let strategy):
            return strategy.pathEvent(event, now: now, context: context)
        case .followPeer(let strategy):
            return strategy.pathEvent(event, now: now, context: context)
        }
    }
}

// Keeps a client on the primary path.
//
// The client brings up only the primary path, then assigns it a CID, probes it, and migrates to
// it once it is validated. A validated path that is not primary stays up, so the client can go
// back to it without probing again.
@available(Network 0.1.0, *)
struct FollowPrimaryStrategy: MigrationStrategyProtocol {
    func pathEvent(
        _ event: MigrationEvent,
        now: NetworkClock.Instant,
        context: MigrationContext
    ) -> [MigrationDecision] {
        let currentPath = context.currentPath
        if currentPath.isPrimary, !currentPath.state.isUnusable {
            return []
        }
        guard let primary = context.otherPaths.first(where: { $0.isPrimary && !$0.state.isUnusable }) else {
            return []
        }
        switch primary.state {
        case .routeAvailable:
            // Connect once per announcement; repeating it for unrelated events cannot help a
            // route that is still coming up.
            if event.pathIdentifier == primary.identifier {
                return [.bringUp(primary.identifier)]
            }
            return []
        case .routeEstablished:
            return [.assignCID(primary.identifier)]
        case .cidAssigned:
            return [.probe(primary.identifier)]
        case .validated:
            return [.migrateTo(primary.identifier)]
        case .probing, .invalid, .unreachable, .closing, .routeUnavailable:
            return []
        }
    }
}

// Keeps a server on the path the peer last sent a non-probing packet on.
//
// - A path whose route becomes available is brought up.
// - A path the peer sends a probing packet on is given a CID, and validated once it has one.
// - The path the peer sends its highest-numbered non-probing packet on is given a CID and
//   validated, and the server moves to it as soon as validation starts. A server that permits the
//   peer to migrate MUST send to its new address, which it does under the anti-amplification
//   limit until the address is validated (RFC 9000 9.3).
// - Until the path it moved to is validated, the server keeps the validated path it left. If that
//   validation fails, or the path goes away, the server goes back (RFC 9000 9.3.2). If the peer
//   goes back first, the server follows it there.
// - Once the server is on a validated path the peer is using, it has no use for any other path,
//   including one the peer is still probing.
@available(Network 0.1.0, *)
struct FollowPeerStrategy: MigrationStrategyProtocol {
    func pathEvent(
        _ event: MigrationEvent,
        now: NetworkClock.Instant,
        context: MigrationContext
    ) -> [MigrationDecision] {
        var decisions: [MigrationDecision] = []

        // Bring up the route the event is about. If the peer used it, give it a CID, and probe it
        // once it has one; the peer's own path is handled below.
        let identifier = event.pathIdentifier
        if let path = context.otherPaths.first(where: { $0.identifier == identifier }) {
            switch path.state {
            case .routeAvailable:
                decisions.append(.bringUp(identifier))
            case .routeEstablished where event == .peerProbed(identifier) && identifier != context.peerPathID:
                decisions.append(.assignCID(identifier))
            case .cidAssigned where identifier != context.peerPathID:
                decisions.append(.probe(identifier))
            default:
                break
            }
        }

        var followsPeer = false
        if let peerPathID = context.peerPathID,
            let peerPath = context.otherPaths.first(where: { $0.identifier == peerPathID })
        {
            switch peerPath.state {
            case .routeEstablished:
                decisions.append(.assignCID(peerPathID))
            case .cidAssigned:
                decisions.append(.probe(peerPathID))
            case .probing, .validated:
                decisions.append(.migrateTo(peerPathID))
                followsPeer = true
            default:
                break
            }
        }
        guard !followsPeer else {
            return decisions
        }

        let currentPath = context.currentPath
        if currentPath.state.isUnusable {
            if let fallback = context.otherPaths.first(where: { $0.state.isValidated }) {
                decisions.append(.migrateTo(fallback.identifier))
            }
        } else if event == .pathChanged(currentPath.identifier), currentPath.state.isValidated,
            context.peerPathID == currentPath.identifier
        {
            // Only for an event about the current path, such as it validating or the server moving
            // to it. An event about another path can be the peer starting to probe it, and that
            // path has to stay up.
            decisions += context.otherPaths.map { .tearDown($0.identifier) }
        }
        return decisions
    }
}
#endif
