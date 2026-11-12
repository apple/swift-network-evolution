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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

// The strategy only sees value snapshots, so none of these tests need a connection.
@available(Network 0.1.0, *)
final class MigrationStrategyTests: XCTestCase {
    typealias PathSnapshot = MigrationContext.PathSnapshot

    let clientStrategy = FollowPrimaryStrategy()
    let serverStrategy = FollowPeerStrategy()

    // Wi-Fi is the path the connection starts on, cell is the one that comes and goes.
    static let wifi: MultiplexingPathIdentifier = 1
    static let cell: MultiplexingPathIdentifier = 2
    static let other: MultiplexingPathIdentifier = 3

    private func decide(
        _ event: MigrationEvent,
        isServer: Bool = false,
        current: PathSnapshot,
        others: [PathSnapshot],
        peerPathID: MultiplexingPathIdentifier? = nil
    ) -> [MigrationDecision] {
        let context = MigrationContext(
            currentPath: current,
            otherPaths: others,
            peerPathID: peerPathID
        )
        if isServer {
            return serverStrategy.pathEvent(event, now: .zero, context: context)
        }
        return clientStrategy.pathEvent(event, now: .zero, context: context)
    }

    func testMigrationPicksTheStrategyForItsRole() {
        XCTAssertEqual(Migration(isServer: false).strategy, .followPrimary(FollowPrimaryStrategy()))
        XCTAssertEqual(Migration(isServer: true).strategy, .followPeer(FollowPeerStrategy()))
        XCTAssertEqual(
            Migration(strategy: .followPeer(FollowPeerStrategy())).strategy,
            .followPeer(FollowPeerStrategy())
        )
    }

    // MARK: - Client

    func testClientFollowsPrimaryPathUntilItMigrates() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let steps: [(state: QUICPathState, expected: [MigrationDecision])] = [
            (.routeAvailable, [.bringUp(Self.cell)]),
            (.routeEstablished, [.assignCID(Self.cell)]),
            (.cidAssigned, [.probe(Self.cell)]),
            (.probing, []),
            (.validated, [.migrateTo(Self.cell)]),
        ]
        for step in steps {
            let cell = PathSnapshot(identifier: Self.cell, state: step.state, isPrimary: true)
            XCTAssertEqual(
                decide(.pathChanged(Self.cell), current: wifi, others: [cell]),
                step.expected,
                "Primary path in \(step.state)"
            )
        }
    }

    func testClientMigratesWhenAValidatedPathBecomesPrimary() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .validated, isPrimary: true)
        XCTAssertEqual(decide(.pathChanged(Self.cell), current: wifi, others: [cell]), [.migrateTo(Self.cell)])
    }

    func testClientProbesAnEstablishedPathThatBecomesPrimary() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .cidAssigned, isPrimary: true)
        XCTAssertEqual(decide(.pathChanged(Self.cell), current: wifi, others: [cell]), [.probe(Self.cell)])
    }

    func testClientOnlyBringsUpThePrimaryPath() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated, isPrimary: true)
        let cell = PathSnapshot(identifier: Self.cell, state: .routeAvailable)
        XCTAssertEqual(decide(.pathChanged(Self.cell), current: wifi, others: [cell]), [])
    }

    // Connecting is only worth asking for when the primary path is announced, not every time
    // something happens to another path while it is still coming up.
    func testClientBringsUpOnlyForEventsAboutThePrimaryPath() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .routeAvailable, isPrimary: true)
        let other = PathSnapshot(identifier: Self.other, state: .routeEstablished)
        XCTAssertEqual(decide(.pathChanged(Self.other), current: wifi, others: [cell, other]), [])
        XCTAssertEqual(decide(.pathChanged(Self.wifi), current: wifi, others: [cell, other]), [])
    }

    func testClientKeepsValidatedPathsThatAreNotPrimary() {
        let cell = PathSnapshot(identifier: Self.cell, state: .validated, isPrimary: true)
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        XCTAssertEqual(decide(.pathChanged(Self.wifi), current: cell, others: [wifi]), [])
    }

    // Losing the current path moves the client to whichever validated path is now primary. Tearing
    // down the path it left is up to the connection, not the strategy.
    func testClientFailsOverWhenTheCurrentPathGoesAway() {
        let lostCell = PathSnapshot(identifier: Self.cell, state: .routeUnavailable)
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated, isPrimary: true)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), current: lostCell, others: [wifi]),
            [.migrateTo(Self.wifi)]
        )
        XCTAssertEqual(decide(.pathChanged(Self.cell), current: wifi, others: [lostCell]), [])
    }

    func testClientIgnoresAnUnusablePrimaryPath() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .unreachable, isPrimary: true)
        XCTAssertEqual(decide(.pathChanged(Self.cell), current: wifi, others: [cell]), [])
    }

    // MARK: - Server

    func testServerValidatesPathsThePeerProbes() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated, isPrimary: true)
        let cases: [(state: QUICPathState, expected: [MigrationDecision])] = [
            (.routeEstablished, [.assignCID(Self.cell)]),
            (.cidAssigned, [.probe(Self.cell)]),
        ]
        for testCase in cases {
            let peerPath = PathSnapshot(identifier: Self.cell, state: testCase.state)
            XCTAssertEqual(
                decide(.peerProbed(Self.cell), isServer: true, current: current, others: [peerPath]),
                testCase.expected,
                "Peer path in \(testCase.state)"
            )
        }
    }

    // Probing waits for the CID; the connection reports getting one as a change to the path.
    func testServerProbesAPathOnceItHasACID() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .cidAssigned)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: current, others: [cell]),
            [.probe(Self.cell)]
        )
    }

    // A route coming up is not a reason to validate it; the peer has to use it first.
    func testServerDoesNotValidateARouteThePeerHasNotUsed() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .routeEstablished)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: current, others: [cell]),
            []
        )
    }

    func testServerBringsUpEveryAnnouncedPath() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated, isPrimary: true)
        let peerPath = PathSnapshot(identifier: Self.cell, state: .routeAvailable)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: current, others: [peerPath]),
            [.bringUp(Self.cell)]
        )
    }

    // Being primary means nothing to a server; only the peer's packets move it.
    func testServerIgnoresThePrimaryPath() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .validated, isPrimary: true)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: current, others: [cell]),
            []
        )
    }

    func testServerMovesToAValidatedPeerPath() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .validated)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: current, others: [cell], peerPathID: Self.cell),
            [.migrateTo(Self.cell)]
        )
    }

    // The server moves as soon as it starts validating the peer's path, rather than waiting for
    // validation to finish (RFC 9000 9.3).
    func testServerMovesToThePeerPathOnceProbingStarts() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let steps: [(state: QUICPathState, expected: [MigrationDecision])] = [
            (.routeEstablished, [.assignCID(Self.cell)]),
            (.cidAssigned, [.probe(Self.cell)]),
            (.probing, [.migrateTo(Self.cell)]),
            (.validated, [.migrateTo(Self.cell)]),
        ]
        for step in steps {
            let cell = PathSnapshot(identifier: Self.cell, state: step.state)
            XCTAssertEqual(
                decide(
                    .pathChanged(Self.cell),
                    isServer: true,
                    current: current,
                    others: [cell],
                    peerPathID: Self.cell
                ),
                step.expected,
                "Peer path in \(step.state)"
            )
        }
    }

    // The peer went back to the current path before the other one validated, so validating it
    // later must not move the server.
    func testServerStaysWhenThePeerComesBack() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .validated)
        XCTAssertEqual(
            decide(
                .pathChanged(Self.cell),
                isServer: true,
                current: current,
                others: [cell],
                peerPathID: Self.wifi
            ),
            []
        )
    }

    // RFC 9000 9.3.2: a peer path that fails validation leaves the server where it was.
    func testServerStaysWhenThePeerPathFailsValidation() {
        let current = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .unreachable)
        XCTAssertEqual(
            decide(
                .pathChanged(Self.cell),
                isServer: true,
                current: current,
                others: [cell],
                peerPathID: Self.cell
            ),
            []
        )
    }

    // The server followed the peer onto a path that then failed validation, or went away. It goes
    // back to the validated path it left (RFC 9000 9.3.2).
    func testServerGoesBackWhenThePathItMovedToFails() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        for state in [QUICPathState.unreachable, .routeUnavailable] {
            let cell = PathSnapshot(identifier: Self.cell, state: state)
            XCTAssertEqual(
                decide(.pathChanged(Self.cell), isServer: true, current: cell, others: [wifi], peerPathID: Self.cell),
                [.migrateTo(Self.wifi)],
                "Current path in \(state)"
            )
        }
    }

    // With nothing validated to go back to, the server stays on the failed path.
    func testServerStaysOnAFailedPathWithNothingToGoBackTo() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .cidAssigned)
        let cell = PathSnapshot(identifier: Self.cell, state: .unreachable)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: cell, others: [wifi], peerPathID: Self.cell),
            []
        )
    }

    // The peer went back to the validated path before the server finished validating the one it
    // followed the peer onto.
    func testServerFollowsThePeerBackToTheValidatedPath() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .probing)
        XCTAssertEqual(
            decide(.pathChanged(Self.wifi), isServer: true, current: cell, others: [wifi], peerPathID: Self.wifi),
            [.migrateTo(Self.wifi)]
        )
    }

    // The path it left stays until the one the server moved to is validated.
    func testServerKeepsThePathItLeftUntilTheNewOneValidates() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .probing)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: cell, others: [wifi], peerPathID: Self.cell),
            []
        )
    }

    func testServerTearsDownOtherPathsOnceThePeerPathValidates() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let other = PathSnapshot(identifier: Self.other, state: .probing)
        let cell = PathSnapshot(identifier: Self.cell, state: .validated)
        XCTAssertEqual(
            decide(
                .pathChanged(Self.cell),
                isServer: true,
                current: cell,
                others: [wifi, other],
                peerPathID: Self.cell
            ),
            [.tearDown(Self.wifi), .tearDown(Self.other)]
        )
    }

    // A path the peer starts probing while the server is on a validated path is not torn down:
    // the event is about that path, not the current one.
    func testServerKeepsAPathThePeerStartsProbing() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .probing)
        XCTAssertEqual(
            decide(.pathChanged(Self.cell), isServer: true, current: wifi, others: [cell], peerPathID: Self.wifi),
            []
        )
    }

    // The peer has moved but the server has not caught up yet, so the path it is on is not one to
    // tidy up around.
    func testServerKeepsOtherPathsWhileThePeerIsElsewhere() {
        let wifi = PathSnapshot(identifier: Self.wifi, state: .validated)
        let cell = PathSnapshot(identifier: Self.cell, state: .unreachable)
        let other = PathSnapshot(identifier: Self.other, state: .validated)
        XCTAssertEqual(
            decide(
                .pathChanged(Self.wifi),
                isServer: true,
                current: wifi,
                others: [cell, other],
                peerPathID: Self.cell
            ),
            []
        )
    }
}

#endif
