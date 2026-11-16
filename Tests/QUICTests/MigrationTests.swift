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

#if canImport(SwiftNetworkTestSupport)
@_spi(Essentials) import SwiftNetworkTestSupport
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
let migrationTestsLogPrefixer: LogPrefixer = LogPrefixer("[MigrationTests]")

@available(Network 0.1.0, *)
final class MigrationTests: XCTestCase {
    var connection = NetworkContext.implicitContext.onQueue {
        QUICConnection(context: .implicitContext)
    }
    // The base linkages are storage-backed, so lower harnesses have to come from storage
    // rather than being wrapped in a bare linkage.
    let storage = TestNetworkProtocolStorage(context: .implicitContext)

    static let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
    static let newCID = QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!
    static let otherCID = QUICConnectionID([0xC1, 0xC2, 0xC3, 0xC4])!

    override func setUp() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.setUpConnection(parameters: nil)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // These connections never run a handshake, so most tests confirm it straight away: the
    // migration strategy does not run before then.
    private func setUpConnection(parameters: Parameters?, handshakeConfirmed: Bool = true) {
        try? self.connection.setup(remote: nil, local: nil, parameters: parameters, path: nil)
        self.connection.recovery = Recovery(logPrefixer: migrationTestsLogPrefixer)
        self.connection.recovery.connection = self.connection
        if handshakeConfirmed {
            confirmHandshake()
        }
    }

    // Confirms the handshake the way a real one does, minus the handshake itself, which
    // `confirmHandshake` otherwise waits for.
    private func confirmHandshake() {
        connection.state = .connected
        connection.fromExternal { eventContext in
            self.connection.confirmHandshake(in: &eventContext)
        }
    }

    // Replaces the connection `setUp` made with a fresh one. The old connection holds itself through
    // its metadata handlers and its recovery, and only closing it breaks those cycles, so it is torn
    // down here. `tearDown` does the same for whichever connection the test ends with.
    private func replaceConnection(parameters: Parameters?, handshakeConfirmed: Bool) {
        connection.destroyFromExternalTest()
        connection = QUICConnection(context: .implicitContext)
        setUpConnection(parameters: parameters, handshakeConfirmed: handshakeConfirmed)
    }

    // Replaces the client connection `setUp` made with a server one. Must be called before any
    // path is made.
    private func becomeServer(handshakeConfirmed: Bool = true) {
        var parameters = Parameters(context: .implicitContext)
        parameters.isServer = true
        replaceConnection(parameters: parameters, handshakeConfirmed: handshakeConfirmed)
    }

    override func tearDown() {
        self.connection.currentPathID = nil
        // The paths built by `makePath` outlive the test body, and migration only destroys the
        // one it migrated away from. Destroying the connection releases whatever is left.
        self.connection.context.onQueue {
            self.connection.destroyFromExternalTest()
        }
    }

    // Builds a path that is open for sending, backed by a lower harness, with its DCID
    // registered in `remoteCIDs` so it can be retired. `validated` drives it to the
    // validated state so `migrate(to:)` will accept it. Without `assignCID` the path stays in
    // `routeEstablished` and its CID is left in `remoteCIDs` for the connection to hand out, unless
    // `registerCID` is false, in which case the peer never issued it.
    private func makePath(
        dcid: QUICConnectionID,
        sequenceNumber: UInt64,
        validated: Bool,
        assignCID: Bool = true,
        registerCID: Bool = true
    ) -> MultiplexingPathIdentifier {
        makePathWithLower(
            dcid: dcid,
            sequenceNumber: sequenceNumber,
            validated: validated,
            assignCID: assignCID,
            registerCID: registerCID
        ).path
    }

    private func makePathWithLower(
        dcid: QUICConnectionID,
        sequenceNumber: UInt64,
        validated: Bool,
        assignCID: Bool = true,
        registerCID: Bool = true
    ) -> (path: MultiplexingPathIdentifier, lower: DatagramLowerHarness<TestDatagramLinkageFamily>) {
        let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
            identifier: "\(sequenceNumber)",
            context: .implicitContext
        )
        lower.fromExternal { eventContext in
            lower.connect(in: &eventContext)
        }
        // Every caller builds its paths from inside `context.async`, so this runs on the context.
        var path = QUICPath.makeFromExternalTest(parent: self.connection)
        path.set(interface: nil, priority: 1, isInitial: true)  // -> .routeEstablished
        if assignCID {
            connection.fromExternal { eventContext in
                path.assignDCID(dcid, in: &eventContext)  // -> .cidAssigned (open for sending)
            }
        }
        if validated {
            path.changeState(to: .probing)
            path.changeState(to: .validated)
        }
        // The path is a framework protocol, so it is bound through the base form of the
        // harness's linkage.
        _ = try? path.attachLowerProtocol(lowerLinkage.base)
        let upperLinkage = path.asUpperLinkage()
        // The path is reached through the connection's table, so it is in the table before its lower
        // protocol is given the linkage that leads back to it
        let pathID = connection.addTestPath(path)
        try? lowerLinkage.base.invokeAttachUpperProtocol(
            upperLinkage,
            remote: nil,
            local: nil,
            parameters: nil,
            path: nil
        )
        guard registerCID else {
            return (pathID, lower)
        }
        try? connection.remoteCIDs.insert(
            sequenceNumber: sequenceNumber,
            connectionID: dcid,
            token: QUICStatelessResetToken(Array(repeating: UInt8(sequenceNumber & 0xff), count: 16))!
        )
        if assignCID, let managedCID = connection.remoteCIDs.first(where: { $0.connectionID == dcid }) {
            connection.remoteCIDs.markUsed(managedCID)
        }
        return (pathID, lower)
    }

    // A path whose lower protocol disconnects (e.g. its netif was destroyed) is marked unavailable, but
    // stays the current path until a migration replaces it, as in libquic.
    func testDisconnectedCurrentPathIsKeptAndMarkedUnavailable() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let (path, lower) = self.makePathWithLower(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPathID = path

            lower.deliverDisconnectedEvent(error: .posix(ENOTCONN))

            XCTAssertEqual(
                self.connection.testPath(path) { $0.state },
                .routeUnavailable,
                "Disconnected path not marked unavailable"
            )
            XCTAssertEqual(self.connection.currentPathID, path, "Current path changed")
            XCTAssertTrue(self.connection.hasPath(path), "Current path removed")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The same holds for a client that cannot migrate, which used to ignore the event.
    func testDisconnectedPathIsMarkedUnavailableWhenMigrationDisabled() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.connection.disableActiveMigrationFromExternalTest()
            let (path, lower) = self.makePathWithLower(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPathID = path

            lower.deliverDisconnectedEvent(error: .posix(ENOTCONN))

            XCTAssertEqual(
                self.connection.testPath(path) { $0.state },
                .routeUnavailable,
                "Disconnected path not marked unavailable"
            )
            XCTAssertEqual(self.connection.currentPathID, path, "Current path changed")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Makes `oldPath` current and `newPath` another path, then migrates to `newPath`.
    private func migrate(from oldPath: MultiplexingPathIdentifier, to newPath: MultiplexingPathIdentifier) {
        connection.currentPathID = oldPath
        connection.fromExternal { eventContext in
            self.connection.migration.migrate(to: newPath, connection: self.connection, in: &eventContext)
        }
    }

    // A server follows the peer, so once it is on a validated path the peer is using every other
    // path goes: the one it left, and any the peer was still probing.
    func testServerMigrationRemovesAllOtherPathsAndRetiresTheirCIDs() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
            let probedPath = self.makePath(dcid: Self.otherCID, sequenceNumber: 3, validated: false)
            self.connection.testPath(probedPath) { $0.changeState(to: .probing) }
            self.connection.currentPathID = oldPath
            for path in [oldPath, newPath, probedPath] {
            }

            self.peerSentPacket(number: 10, on: newPath)

            for (path, cid) in [(oldPath, Self.oldCID), (probedPath, Self.otherCID)] {
                XCTAssertFalse(
                    self.connection.hasPath(path),
                    "Path \(path) not removed"
                )
                XCTAssertNil(
                    self.connection.remoteCIDs.retire(connectionID: cid),
                    "CID \(cid) not retired"
                )
            }

            // Only the new path remains, and it is now the current path.
            XCTAssertEqual(
                self.connection.pathCount,
                1,
                "Unexpected path count"
            )
            XCTAssertEqual(
                self.connection.currentPathID,
                newPath,
                "Current path not switched"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    private func peerSentPacket(number: PacketNumber, isNonProbing: Bool = true, on path: MultiplexingPathIdentifier) {
        connection.fromExternal { eventContext in
            self.connection.peerSentPacket(number: number, isNonProbing: isNonProbing, on: path, in: &eventContext)
        }
    }

    // A probing packet on a new path gets that path a CID and validated, but does not move the
    // server.
    func testServerValidatesPathThePeerProbes() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let probedPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false, assignCID: false)
            self.connection.currentPathID = currentPath
            XCTAssertEqual(self.connection.testPath(probedPath) { $0.state }, .routeEstablished)

            self.peerSentPacket(number: 10, isNonProbing: false, on: probedPath)

            XCTAssertEqual(self.connection.testPath(probedPath) { $0.dcid }, Self.newCID, "Probed path not given a CID")
            XCTAssertTrue(self.connection.testPath(probedPath) { $0.isProbing }, "Probed path not validated")
            XCTAssertEqual(self.connection.currentPathID, currentPath, "Moved on a probing packet")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Only the highest-numbered non-probing packet moves the server, so an older one that was
    // reordered or replayed on another path is ignored (RFC 9000 9.3, 9.3.3).
    func testServerFollowsHighestNumberedNonProbingPacket() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let firstPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let peerPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            let stalePath = self.makePath(dcid: Self.otherCID, sequenceNumber: 3, validated: true)
            self.connection.currentPathID = firstPath
            for path in [firstPath, peerPath, stalePath] {
            }

            // The peer's path is not validated yet, so the server keeps every other path.
            self.peerSentPacket(number: 10, on: peerPath)
            XCTAssertEqual(self.connection.currentPathID, peerPath, "Did not follow the peer")

            self.peerSentPacket(number: 5, on: stalePath)
            XCTAssertEqual(self.connection.currentPathID, peerPath, "Followed an older packet")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The peer moves to a new path and comes back before the server has validated it. The server
    // follows it both ways, and drops the new path once it is back on a validated one.
    func testServerFollowsThePeerBackBeforeValidation() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = oldPath

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertTrue(self.connection.testPath(newPath) { $0.isProbing }, "Peer path not validated")
            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not follow the peer")

            self.peerSentPacket(number: 11, on: oldPath)
            XCTAssertEqual(self.connection.currentPathID, oldPath, "Did not follow the peer back")
            XCTAssertFalse(
                self.connection.hasPath(newPath),
                "Server kept the path the peer left"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A non-probing packet on a new path gets it a CID and validated, and the server moves to it
    // straight away (RFC 9000 9.3). It keeps the validated path it left until the new one
    // validates.
    func testServerMovesToThePeerPathBeforeValidatingIt() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false, assignCID: false)
            self.connection.currentPathID = oldPath

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertEqual(self.connection.testPath(newPath) { $0.dcid }, Self.newCID, "Peer path not given a CID")
            XCTAssertTrue(self.connection.testPath(newPath) { $0.isProbing }, "Peer path not validated")
            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not move to the peer path")
            XCTAssertTrue(
                self.connection.hasPath(oldPath),
                "Server dropped the validated path before the new one validated"
            )

            let challenge = PendingChallenge(sentTime: self.connection.now)
            self.connection.testPath(newPath) { $0.pendingOutboundChallenges.append(challenge) }
            self.connection.fromExternal { eventContext in
                self.connection.handlePathChallengeResponse(path: newPath, data: challenge.data, in: &eventContext)
            }

            XCTAssertEqual(self.connection.currentPathID, newPath, "Left the validated peer path")
            XCTAssertFalse(
                self.connection.hasPath(oldPath),
                "Server kept the path it left"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The path the server followed the peer onto runs out of probes. The server goes back to the
    // validated path it left (RFC 9000 9.3.2) and drops the one that failed. The path becomes
    // unreachable while a packet is being built, so it is the migration timer that reports it.
    func testServerGoesBackWhenThePeerPathFailsValidation() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = oldPath

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not follow the peer")

            // Use up the challenges, then build one more packet, which marks the path unreachable.
            // Following the peer may already have sent the first challenge, at the connection's
            // clock.
            var now = self.connection.now
            for _ in 0...QUICPath.maximumPendingChallenges {
                now = now.advanced(by: .seconds(60))
                var pendingItems = PendingItems(packetNumberSpace: .applicationData)
                self.connection.fromExternal { eventContext in
                    self.connection.testPath(newPath) {
                        $0.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                    }
                }
            }
            XCTAssertEqual(self.connection.testPath(newPath) { $0.state }, .unreachable)
            XCTAssertEqual(self.connection.currentPathID, newPath, "Moved while building a packet")

            self.connection.fromExternal { eventContext in
                self.connection.migration.timerFired(at: now, connection: self.connection, in: &eventContext)
            }
            XCTAssertEqual(self.connection.currentPathID, oldPath, "Did not go back to the validated path")
            XCTAssertFalse(
                self.connection.hasPath(newPath),
                "Server kept the path that failed validation"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The handshake validates the path it ran on, which is never probed, so confirming it leaves
    // that path validated on both sides. A path that is not current still has to be probed.
    private func checkHandshakeValidatesTheCurrentPath(isServer: Bool) {
        let expectation = XCTestExpectation()
        connection.context.async {
            if isServer {
                self.becomeServer(handshakeConfirmed: false)
            } else {
                self.replaceConnection(parameters: nil, handshakeConfirmed: false)
            }
            let handshakePath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            let otherPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = handshakePath
            XCTAssertEqual(self.connection.testPath(handshakePath) { $0.state }, .cidAssigned)

            self.confirmHandshake()

            XCTAssertTrue(
                self.connection.testPath(handshakePath) { $0.isValidated },
                "Handshake path left in \(self.connection.testPath(handshakePath) { $0.state })"
            )
            XCTAssertFalse(
                self.connection.testPath(otherPath) { $0.isValidated },
                "Validated a path that was not probed"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testClientHandshakeValidatesTheCurrentPath() {
        checkHandshakeValidatesTheCurrentPath(isServer: false)
    }

    func testServerHandshakeValidatesTheCurrentPath() {
        checkHandshakeValidatesTheCurrentPath(isServer: true)
    }

    // As above, but the path the server goes back to is the one the handshake ran on, which was
    // never probed. The handshake validated it, so it is a path the server can return to.
    func testServerGoesBackToTheHandshakePathWhenThePeerPathFailsValidation() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer(handshakeConfirmed: false)
            let handshakePath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.currentPathID = handshakePath
            self.confirmHandshake()

            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not follow the peer")
            XCTAssertTrue(
                self.connection.hasPath(handshakePath),
                "Server dropped the handshake path before the new one validated"
            )
            XCTAssertTrue(
                self.connection.testPath(handshakePath) { $0.isValidated },
                "Server probed the handshake path again"
            )

            var now = self.connection.now
            for _ in 0...QUICPath.maximumPendingChallenges {
                now = now.advanced(by: .seconds(60))
                var pendingItems = PendingItems(packetNumberSpace: .applicationData)
                self.connection.fromExternal { eventContext in
                    self.connection.testPath(newPath) {
                        $0.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                    }
                }
            }
            XCTAssertEqual(self.connection.testPath(newPath) { $0.state }, .unreachable)

            self.connection.fromExternal { eventContext in
                self.connection.migration.timerFired(at: now, connection: self.connection, in: &eventContext)
            }
            XCTAssertEqual(self.connection.currentPathID, handshakePath, "Did not go back to the handshake path")
            XCTAssertFalse(
                self.connection.hasPath(newPath),
                "Server kept the path that failed validation"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Until it is validated, everything the server sends on the path it followed the peer onto
    // counts against three times what it received there. A path that is current without having
    // been validated is the handshake path before the handshake has been confirmed, and the
    // handshake enforces its own limit there. A client has no such limit.
    func testServerLimitsWhatItSendsOnAnUnvalidatedCurrentPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = oldPath
            XCTAssertEqual(self.connection.testPath(oldPath) { $0.state }, .cidAssigned)
            XCTAssertNil(
                self.connection.testPath(oldPath) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 0)
                },
                "Handshake path limited"
            )

            self.connection.testPath(newPath) { $0.pathStatistics.increment(.rxBytes, by: 100) }
            self.connection.testPath(newPath) { $0.pathStatistics.increment(.txBytes, by: 50) }
            XCTAssertNil(
                self.connection.testPath(newPath) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 0)
                },
                "Limited a path that is not current"
            )

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not follow the peer")
            XCTAssertTrue(self.connection.testPath(newPath) { $0.isProbing })
            XCTAssertEqual(
                self.connection.testPath(newPath) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 0)
                },
                250
            )
            XCTAssertEqual(
                self.connection.testPath(newPath) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 200)
                },
                50
            )
            XCTAssertEqual(
                self.connection.testPath(newPath) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 400)
                },
                0
            )

            let challenge = PendingChallenge(sentTime: self.connection.now)
            self.connection.testPath(newPath) { $0.pendingOutboundChallenges.append(challenge) }
            self.connection.fromExternal { eventContext in
                self.connection.handlePathChallengeResponse(path: newPath, data: challenge.data, in: &eventContext)
            }
            XCTAssertNil(
                self.connection.testPath(newPath) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 0)
                },
                "Limited a validated path"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testClientDoesNotLimitWhatItSendsOnTheCurrentPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.testPath(path) { $0.changeState(to: .probing) }
            self.connection.currentPathID = path
            XCTAssertNil(
                self.connection.testPath(path) {
                    self.connection.currentPathAmplificationBudget(on: $0, alreadySent: 0)
                }
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A client keeps the path it left so that it can go back to it without probing again.
    func testClientMigrationKeepsOldPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)

            self.migrate(from: oldPath, to: newPath)

            XCTAssertEqual(
                self.connection.currentPathID,
                newPath,
                "Current path not switched"
            )
            XCTAssertTrue(
                self.connection.hasPath(oldPath),
                "Old path removed"
            )
            XCTAssertTrue(self.connection.testPath(oldPath) { $0.isValidated }, "Old path no longer validated")
            XCTAssertNotNil(
                self.connection.remoteCIDs.retire(connectionID: Self.oldCID),
                "Old path CID retired"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A path that already has a CID becomes primary: the client probes it, and migrates once the
    // peer answers the challenge.
    func testClientMigratesToNewPrimaryPathOnceValidated() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = oldPath
            self.connection.testPath(newPath) { $0.pathIsPrimary = true }

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: newPath,
                    event: .established,
                    isPrimary: true,
                    in: &eventContext
                )
            }
            XCTAssertTrue(self.connection.testPath(newPath) { $0.isProbing }, "New primary path not probed")
            XCTAssertEqual(self.connection.currentPathID, oldPath, "Migrated before validation")

            let challenge = PendingChallenge(sentTime: self.connection.now)
            self.connection.testPath(newPath) { $0.pendingOutboundChallenges.append(challenge) }
            self.connection.fromExternal { eventContext in
                self.connection.handlePathChallengeResponse(path: newPath, data: challenge.data, in: &eventContext)
            }

            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not migrate to validated primary path")
            XCTAssertTrue(
                self.connection.hasPath(oldPath),
                "Validated old path removed"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A path that becomes primary during the handshake is left alone until the handshake is
    // confirmed, and picked up then.
    func testClientWaitsForHandshakeConfirmationBeforeMigrating() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.replaceConnection(parameters: nil, handshakeConfirmed: false)
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = oldPath
            self.connection.testPath(newPath) { $0.pathIsPrimary = true }

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: newPath,
                    event: .established,
                    isPrimary: true,
                    in: &eventContext
                )
            }
            XCTAssertEqual(
                self.connection.testPath(newPath) { $0.state },
                .cidAssigned,
                "Path probed during the handshake"
            )

            self.confirmHandshake()
            XCTAssertTrue(
                self.connection.testPath(newPath) { $0.isProbing },
                "Path not probed once the handshake was confirmed"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testHandshakeConfirmedInAPacketRunsTheStrategyAfterThePacket() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.replaceConnection(parameters: nil, handshakeConfirmed: false)
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = oldPath
            self.connection.testPath(newPath) { $0.pathIsPrimary = true }

            self.connection.isHandlingPacket = true
            self.confirmHandshake()
            XCTAssertEqual(
                self.connection.testPath(newPath) { $0.state },
                .cidAssigned,
                "Strategy ran in the middle of the packet"
            )

            self.connection.fromExternal { eventContext in
                self.connection.finishHandlingPacket(in: &eventContext)
            }
            XCTAssertTrue(
                self.connection.testPath(newPath) { $0.isProbing },
                "Path not probed once the packet was handled"
            )
            XCTAssertFalse(self.connection.isHandlingPacket)
            XCTAssertTrue(self.connection.pendingMigrationEvents.isEmpty)

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testPathValidatedInAPacketIsMigratedToAfterThePacket() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.testPath(newPath) { $0.changeState(to: .probing) }
            self.connection.currentPathID = oldPath
            self.connection.testPath(newPath) { $0.pathIsPrimary = true }

            self.connection.isHandlingPacket = true
            self.validate(newPath)
            XCTAssertTrue(self.connection.testPath(newPath) { $0.isValidated })
            XCTAssertEqual(self.connection.currentPathID, oldPath, "Migrated in the middle of the packet")

            self.connection.fromExternal { eventContext in
                self.connection.finishHandlingPacket(in: &eventContext)
            }
            XCTAssertEqual(self.connection.currentPathID, newPath, "Did not migrate once the packet was handled")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // An unusable path is torn down by the connection, whatever the strategy, unless it is the
    // current path.
    private func checkPathThatGoesAwayIsTornDown() {
        let currentPath = makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
        let otherPath = makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
        connection.currentPathID = currentPath

        connection.fromExternal { eventContext in
            self.connection.handlePathChanged(
                path: otherPath,
                event: .unavailable,
                isPrimary: false,
                in: &eventContext
            )
        }
        XCTAssertFalse(connection.hasPath(otherPath), "Unavailable path kept")

        // The current path is kept even when it goes away, since there is nothing to move to.
        connection.fromExternal { eventContext in
            self.connection.handlePathChanged(
                path: currentPath,
                event: .unavailable,
                isPrimary: false,
                in: &eventContext
            )
        }
        XCTAssertTrue(
            connection.hasPath(currentPath),
            "Current path removed"
        )
    }

    func testClientTearsDownPathThatGoesAway() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.checkPathThatGoesAwayIsTornDown()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testServerTearsDownPathThatGoesAway() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            self.checkPathThatGoesAwayIsTornDown()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A client that cannot migrate runs no strategy, but still has its unusable paths torn down.
    func testClientWithoutActiveMigrationTearsDownPathThatGoesAway() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.connection.disableActiveMigrationFromExternalTest()
            self.checkPathThatGoesAwayIsTornDown()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The peer sends a non-probing packet on a path that already failed validation. The path is
    // unusable and gets torn down, but not until the datagrams received on it have been handled,
    // since handling them still uses the path and its receive queue.
    func testServerDefersTearingDownThePathItIsReceivingOn() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let failedPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.testPath(failedPath) { $0.changeState(to: .probing) }
            self.connection.testPath(failedPath) { $0.changeState(to: .unreachable) }
            self.connection.currentPathID = currentPath

            self.connection.receivingPathID = failedPath
            self.peerSentPacket(number: 10, on: failedPath)
            XCTAssertTrue(
                self.connection.hasPath(failedPath),
                "Path torn down while its datagrams were being handled"
            )
            XCTAssertEqual(self.connection.deferredTeardownPathIDs, [failedPath])
            XCTAssertEqual(self.connection.currentPathID, currentPath, "Moved to an unusable path")

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertNil(self.connection.receivingPathID)
            XCTAssertTrue(self.connection.deferredTeardownPathIDs.isEmpty)
            XCTAssertFalse(
                self.connection.hasPath(failedPath),
                "Unusable path kept after its datagrams were handled"
            )
            XCTAssertEqual(self.connection.currentPathID, currentPath, "Current path changed")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Makes `currentPath` current with the peer on it, and asks for every other path to be torn
    // down while datagrams received on `receivingPath` are being handled.
    private func deferTearingDown(
        _ receivingPath: MultiplexingPathIdentifier,
        keeping currentPath: MultiplexingPathIdentifier
    ) {
        connection.currentPathID = currentPath
        connection.receivingPathID = receivingPath
        peerSentPacket(number: 10, on: currentPath)
        XCTAssertTrue(
            connection.hasPath(receivingPath),
            "Path torn down while its datagrams were being handled"
        )
        XCTAssertEqual(connection.deferredTeardownPathIDs, [receivingPath])
    }

    // A path the server no longer wants is torn down once its datagrams have been handled, even
    // though it is still usable.
    func testServerTearsDownADeferredPathItStillDoesNotWant() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let otherPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
            self.deferTearingDown(otherPath, keeping: currentPath)

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertFalse(self.connection.hasPath(otherPath), "Unwanted path kept")
            XCTAssertEqual(self.connection.currentPathID, currentPath, "Current path changed")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Later datagrams on the path the server was going to tear down move the peer, and the server,
    // back to it. It is the current path by the time they have been handled, so it stays.
    func testServerKeepsADeferredPathThatBecameCurrent() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let otherPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
            self.deferTearingDown(otherPath, keeping: currentPath)

            self.peerSentPacket(number: 11, on: otherPath)
            XCTAssertEqual(self.connection.currentPathID, otherPath, "Did not follow the peer")

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertTrue(
                self.connection.hasPath(otherPath),
                "Current path torn down"
            )
            XCTAssertEqual(self.connection.currentPathID, otherPath, "Current path changed")
            XCTAssertFalse(self.connection.hasPath(currentPath), "Path the peer left kept")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // As above, but the server cannot follow the peer yet, as the peer has issued no spare CID.
    // The path the peer is on stays, waiting for one.
    func testServerKeepsADeferredPathThePeerMovedTo() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let otherPath = self.makePath(
                dcid: Self.newCID,
                sequenceNumber: 2,
                validated: false,
                assignCID: false,
                registerCID: false
            )
            self.deferTearingDown(otherPath, keeping: currentPath)

            self.peerSentPacket(number: 11, on: otherPath)
            XCTAssertEqual(
                self.connection.testPath(otherPath) { $0.state },
                .routeEstablished,
                "Path got a CID the peer never issued"
            )
            XCTAssertEqual(self.connection.currentPathID, currentPath)

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertTrue(
                self.connection.hasPath(otherPath),
                "Path the peer moved to torn down"
            )
            XCTAssertEqual(self.connection.currentPathID, currentPath, "Current path changed")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A closed connection has no current path. Its paths going away is not a migration event, and
    // they are cleaned up with the connection.
    func testNoMigrationWithoutACurrentPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPathID = nil

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: path,
                    event: .unavailable,
                    isPrimary: false,
                    in: &eventContext
                )
            }
            XCTAssertTrue(self.connection.hasPath(path), "Path torn down")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A connection that received a CONNECTION_CLOSE keeps its current path while it waits to drain,
    // but it has already told the flows it disconnected, so a packet from the peer on another path
    // must not move it there.
    func testServerDoesNotMigrateWhileClosing() {
        let expectation = XCTestExpectation()
        connection.context.async {
            self.becomeServer()
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false, assignCID: false)
            self.connection.currentPathID = currentPath
            self.connection.state = .closing

            self.peerSentPacket(number: 10, on: newPath)

            XCTAssertEqual(self.connection.currentPathID, currentPath, "Migrated while closing")
            XCTAssertEqual(
                self.connection.testPath(newPath) { $0.state },
                .routeEstablished,
                "Path probed while closing"
            )
            XCTAssertTrue(self.connection.hasPath(currentPath))
            XCTAssertTrue(self.connection.hasPath(newPath))

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The system can report a path change while the connection drains. A client does not move to
    // a new primary path then either.
    func testClientDoesNotMigrateWhileDraining() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
            self.connection.currentPathID = currentPath
            self.connection.testPath(newPath) { $0.pathIsPrimary = true }
            self.connection.state = .draining

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: newPath,
                    event: .established,
                    isPrimary: true,
                    in: &eventContext
                )
            }

            XCTAssertEqual(self.connection.currentPathID, currentPath, "Migrated while draining")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Losing the current path moves the client to the validated primary path, and the path it lost
    // is torn down once it is no longer current.
    func testClientFailsOverAndTearsDownTheLostPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let lostPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let standbyPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
            self.connection.currentPathID = lostPath
            self.connection.testPath(standbyPath) { $0.pathIsPrimary = true }

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: lostPath,
                    event: .unavailable,
                    isPrimary: false,
                    in: &eventContext
                )
            }

            XCTAssertEqual(self.connection.currentPathID, standbyPath, "Did not fail over")
            XCTAssertFalse(self.connection.hasPath(lostPath), "Lost path kept")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // `Timer` fires an entry up to `Timer.timerThreshold` before its deadline and disables it
    // first, so the migration handler can be woken with an instant that precedes the challenge it
    // woke for. It must re-arm anyway; otherwise probing stalls on an otherwise idle path until an
    // unrelated event happens to arm the timer again.
    func testMigrationTimerRearmsWhenFiredInsideTimerLeeway() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.currentPathID = path
            self.connection.testPath(path) { $0.changeState(to: .probing) }

            // Send the first challenge, which sets the next challenge deadline and arms the timer.
            let base = NetworkClock.Instant.testBase
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            self.connection.fromExternal { eventContext in
                self.connection.testPath(path) {
                    $0.addPathChallenge(to: &pendingItems, now: base, in: &eventContext)
                    self.connection.forwardMigrationTimerResetRequest(from: &$0)
                }
                // The path asks for the migration timer to be armed once it is no longer borrowed
                self.connection.resetMigrationTimerIfPending(in: &eventContext)
            }
            guard let nextChallengeTime = (self.connection.testPath(path) { $0.nextChallengeTime }) else {
                XCTFail("First challenge did not schedule a follow-up")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(self.connection.timer.nextDeadline, nextChallengeTime)

            // Wake one microsecond early, which is inside the leeway window `Timer` allows. Go
            // through `Timer.timerFired`, since that is what disables the entry before handing the
            // instant to the handler.
            self.connection.fromExternal { eventContext in
                self.connection.timer.timerFired(
                    at: nextChallengeTime.advanced(by: .microseconds(-1)),
                    in: &eventContext
                )
            }

            XCTAssertEqual(
                self.connection.timer.nextDeadline,
                nextChallengeTime,
                "Migration timer left disarmed after an early fire"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Connection IDs

    static func cid(_ value: UInt8) -> QUICConnectionID {
        QUICConnectionID([value, value, value, value])!
    }

    private var queuedRetirements: [UInt64] {
        connection.queuedRetireConnectionIDSequences
    }

    private func newConnectionID(sequence: UInt64, retirePriorTo: UInt64 = 0) -> Bool {
        let frame = FrameNewConnectionID(
            sequence: sequence,
            retirePriorToSequence: retirePriorTo,
            connectionID: Self.cid(UInt8(sequence)),
            statelessResetToken: QUICStatelessResetToken(Array(repeating: UInt8(sequence), count: 16))!
        )
        var result = false
        connection.fromExternal { eventContext in
            result = self.connection.processNewConnectionIDFrame(frame, in: &eventContext)
        }
        return result
    }

    private func validate(_ path: MultiplexingPathIdentifier) {
        let challenge = PendingChallenge(sentTime: connection.now)
        connection.testPath(path) { $0.pendingOutboundChallenges.append(challenge) }
        connection.fromExternal { eventContext in
            self.connection.handlePathChallengeResponse(path: path, data: challenge.data, in: &eventContext)
        }
    }

    // Leaving any of the states that hold a CID retires it, once; moving between them does not.
    func testLeavingAStateThatHoldsACIDRetiresIt() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let transitions: [(from: QUICPathState, to: QUICPathState)] = [
                (.cidAssigned, .routeEstablished),
                (.cidAssigned, .routeUnavailable),
                (.probing, .unreachable),
                (.probing, .routeEstablished),
                (.probing, .routeUnavailable),
                (.validated, .unreachable),
                (.validated, .closing),
                (.validated, .routeEstablished),
                (.validated, .routeUnavailable),
            ]
            for (index, transition) in transitions.enumerated() {
                let sequence = UInt64(index + 1)
                let cid = Self.cid(UInt8(sequence))
                let path = self.makePath(dcid: cid, sequenceNumber: sequence, validated: false)
                if transition.from != .cidAssigned {
                    self.connection.testPath(path) { $0.changeState(to: .probing) }
                }
                if transition.from == .validated {
                    self.connection.testPath(path) { $0.changeState(to: .validated) }
                }
                XCTAssertEqual(self.connection.testPath(path) { $0.state }, transition.from)
                XCTAssertTrue(self.queuedRetirements.isEmpty, "Retired a CID while holding it")

                self.connection.testPath(path) { $0.changeState(to: transition.to) }
                let label = "\(transition.from) -> \(transition.to)"
                XCTAssertEqual(self.queuedRetirements, [sequence], label)
                XCTAssertNil(self.connection.testPath(path) { $0.dcid }, label)
                XCTAssertNil(self.connection.remoteCIDs.find(connectionID: cid), label)

                // The CID is gone, so leaving the next state retires nothing more.
                if transition.to.isValidStateChange(to: .routeUnavailable) {
                    self.connection.testPath(path) { $0.changeState(to: .routeUnavailable) }
                }
                XCTAssertEqual(self.queuedRetirements, [sequence], label)

                self.connection.queuedRetireConnectionIDSequences.removeAll()
                if let removed = self.connection.removePath(path) { removed.destroyFromExternalTest() }
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A path that runs out of probes becomes unreachable while a packet is being built, and its
    // CID is retired like any other. It used to be looked up among our own CIDs and never retired.
    func testPathThatRunsOutOfProbesRetiresItsCID() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let path = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.currentPathID = currentPath
            self.connection.testPath(path) { $0.changeState(to: .probing) }

            var now = self.connection.now
            for _ in 0...QUICPath.maximumPendingChallenges {
                now = now.advanced(by: .seconds(60))
                var pendingItems = PendingItems(packetNumberSpace: .applicationData)
                self.connection.fromExternal { eventContext in
                    self.connection.testPath(path) {
                        $0.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                    }
                }
            }
            XCTAssertEqual(self.connection.testPath(path) { $0.state }, .unreachable)
            XCTAssertEqual(self.queuedRetirements, [2])
            XCTAssertNil(self.connection.remoteCIDs.find(connectionID: Self.newCID))

            // The next send picks the frame up.
            var applicationPendingItems = PendingItems(packetNumberSpace: .applicationData)
            self.connection.addQueuedRetireConnectionIDs(to: &applicationPendingItems)
            XCTAssertEqual(applicationPendingItems.retireConnectionIDs.map(\.sequence), [2])
            XCTAssertTrue(self.queuedRetirements.isEmpty)

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A peer that issued only two CIDs: one each for Wi-Fi and cell. Going back and forth between
    // them needs no new CID, and neither path gives its CID up.
    func testClientMovesBetweenTwoKeptPathsWithoutNewCIDs() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let wifi = self.makePath(dcid: Self.cid(1), sequenceNumber: 1, validated: true)
            let cell = self.makePath(dcid: Self.cid(2), sequenceNumber: 2, validated: true)
            self.connection.currentPathID = wifi

            for (to, from) in [(cell, wifi), (wifi, cell), (cell, wifi), (wifi, cell)] {
                self.connection.testPath(from) { $0.pathIsPrimary = false }
                self.connection.testPath(to) { $0.pathIsPrimary = true }
                self.connection.fromExternal { eventContext in
                    self.connection.runMigrationStrategy(events: [.pathChanged(to)], in: &eventContext)
                }
                XCTAssertEqual(self.connection.currentPathID, to, "Did not move to path \(to)")
                XCTAssertTrue(self.connection.testPath(from) { $0.isValidated }, "Path left behind lost its validation")
            }
            XCTAssertEqual(self.connection.testPath(wifi) { $0.dcid }, Self.cid(1))
            XCTAssertEqual(self.connection.testPath(cell) { $0.dcid }, Self.cid(2))
            XCTAssertTrue(self.queuedRetirements.isEmpty, "Retired a CID")
            XCTAssertEqual(self.connection.remoteCIDs.count, 2)

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // A third path becomes primary while the peer's two CIDs are held by Wi-Fi and cell. It waits
    // in routeEstablished until Wi-Fi goes away, which retires its CID, and the peer replaces it.
    func testNewPrimaryPathWaitsForACID() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let wifi = self.makePath(dcid: Self.cid(1), sequenceNumber: 1, validated: true)
            let cell = self.makePath(dcid: Self.cid(2), sequenceNumber: 2, validated: true)
            let newWifi = self.makePath(
                dcid: Self.cid(3),
                sequenceNumber: 3,
                validated: false,
                assignCID: false,
                registerCID: false
            )
            self.connection.currentPathID = wifi
            for path in [wifi, cell, newWifi] {
            }
            self.connection.testPath(wifi) { $0.pathIsPrimary = false }
            self.connection.testPath(newWifi) { $0.pathIsPrimary = true }

            self.connection.fromExternal { eventContext in
                self.connection.runMigrationStrategy(events: [.pathChanged(newWifi)], in: &eventContext)
            }
            XCTAssertEqual(
                self.connection.testPath(newWifi) { $0.state },
                .routeEstablished,
                "Path got a CID the peer never issued"
            )
            XCTAssertEqual(self.connection.currentPathID, wifi)

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: wifi,
                    event: .unavailable,
                    isPrimary: false,
                    in: &eventContext
                )
            }
            XCTAssertEqual(self.queuedRetirements, [1], "Lost path did not give up its CID")
            XCTAssertEqual(self.connection.testPath(newWifi) { $0.state }, .routeEstablished)

            // The peer replaces the retired CID.
            XCTAssertTrue(self.newConnectionID(sequence: 4))
            XCTAssertEqual(
                self.connection.testPath(newWifi) { $0.dcid },
                Self.cid(4),
                "Waiting path did not get the new CID"
            )
            XCTAssertTrue(self.connection.testPath(newWifi) { $0.isProbing }, "Waiting path not probed")

            self.validate(newWifi)
            XCTAssertEqual(self.connection.currentPathID, newWifi, "Did not move to the new primary path")
            XCTAssertFalse(self.connection.hasPath(wifi), "Lost path kept")
            XCTAssertTrue(self.connection.testPath(cell) { $0.isValidated }, "Kept path lost its validation")
            XCTAssertEqual(self.connection.testPath(cell) { $0.dcid }, Self.cid(2))

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // The peer retires the CID a kept validated path is using. The path takes a spare one and
    // stays validated, like the current path does.
    func testRetiredCIDOnAKeptPathIsReplacedInPlace() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let wifi = self.makePath(dcid: Self.cid(1), sequenceNumber: 1, validated: true)
            let cell = self.makePath(dcid: Self.cid(2), sequenceNumber: 2, validated: true)
            try? self.connection.remoteCIDs.insert(
                sequenceNumber: 3,
                connectionID: Self.cid(3),
                token: QUICStatelessResetToken(Array(repeating: 3, count: 16))!
            )
            self.connection.currentPathID = wifi

            XCTAssertTrue(self.newConnectionID(sequence: 4, retirePriorTo: 3))

            let newCIDs = [Self.cid(3), Self.cid(4)]
            XCTAssertTrue(self.connection.testPath(wifi) { $0.isValidated })
            XCTAssertTrue(self.connection.testPath(cell) { $0.isValidated }, "Kept path lost its validation")
            XCTAssertTrue(
                newCIDs.contains { $0 == self.connection.testPath(wifi) { $0.dcid } },
                "Current path kept a retired CID"
            )
            XCTAssertTrue(
                newCIDs.contains { $0 == self.connection.testPath(cell) { $0.dcid } },
                "Kept path kept a retired CID"
            )
            XCTAssertNotEqual(
                self.connection.testPath(wifi) { $0.dcid },
                self.connection.testPath(cell) { $0.dcid },
                "Two paths share a CID"
            )
            XCTAssertTrue(self.queuedRetirements.isEmpty, "Retired a CID the peer already retired")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // With no spare CID, the kept path whose CID the peer retired waits for one, and retires
    // nothing itself: the peer's retirement already did.
    func testKeptPathWithoutASpareCIDWaitsForOne() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let wifi = self.makePath(dcid: Self.cid(1), sequenceNumber: 1, validated: true)
            let cell = self.makePath(dcid: Self.cid(2), sequenceNumber: 2, validated: true)
            self.connection.currentPathID = wifi

            XCTAssertTrue(self.newConnectionID(sequence: 3, retirePriorTo: 3))

            XCTAssertEqual(
                self.connection.testPath(wifi) { $0.dcid },
                Self.cid(3),
                "Current path not given the new CID"
            )
            XCTAssertEqual(self.connection.testPath(cell) { $0.state }, .routeEstablished)
            XCTAssertNil(self.connection.testPath(cell) { $0.dcid })
            XCTAssertTrue(self.queuedRetirements.isEmpty, "Retired a CID the peer already retired")

            // The next CID goes to it. It is not primary, so the client does not probe it.
            XCTAssertTrue(self.newConnectionID(sequence: 4))
            XCTAssertEqual(
                self.connection.testPath(cell) { $0.state },
                .routeEstablished,
                "Client brought up a path that is not primary"
            )
            self.connection.testPath(cell) { $0.pathIsPrimary = true }
            self.connection.testPath(wifi) { $0.pathIsPrimary = false }
            self.connection.fromExternal { eventContext in
                self.connection.runMigrationStrategy(events: [.pathChanged(cell)], in: &eventContext)
            }
            XCTAssertEqual(self.connection.testPath(cell) { $0.dcid }, Self.cid(4))
            XCTAssertTrue(self.connection.testPath(cell) { $0.isProbing })

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
