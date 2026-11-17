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
        self.connection.currentPath = nil
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
    ) -> QUICPath {
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
    ) -> (path: QUICPath, lower: DatagramLowerHarness<TestDatagramLinkageFamily>) {
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
        try? lowerLinkage.base.invokeAttachUpperProtocol(
            path.asUpperLinkage(),
            remote: nil,
            local: nil,
            parameters: nil,
            path: nil
        )
        guard registerCID else {
            return (path, lower)
        }
        try? connection.remoteCIDs.insert(
            sequenceNumber: sequenceNumber,
            connectionID: dcid,
            token: QUICStatelessResetToken(Array(repeating: UInt8(sequenceNumber & 0xff), count: 16))!
        )
        if assignCID, let managedCID = connection.remoteCIDs.first(where: { $0.connectionID == dcid }) {
            connection.remoteCIDs.markUsed(managedCID)
        }
        return (path, lower)
    }

    // A path whose lower protocol disconnects (e.g. its netif was destroyed) is marked unavailable, but
    // stays the current path until a migration replaces it, as in libquic.
    func testDisconnectedCurrentPathIsKeptAndMarkedUnavailable() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let (path, lower) = self.makePathWithLower(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path

            lower.deliverDisconnectedEvent(error: .posix(ENOTCONN))

            XCTAssertEqual(path.state, .routeUnavailable, "Disconnected path not marked unavailable")
            XCTAssertEqual(self.connection.currentPath?.identifier, path.identifier, "Current path changed")
            XCTAssertNotNil(self.connection.multiplexingPaths[path.pathIdentifier], "Current path removed")
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
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path

            lower.deliverDisconnectedEvent(error: .posix(ENOTCONN))

            XCTAssertEqual(path.state, .routeUnavailable, "Disconnected path not marked unavailable")
            XCTAssertEqual(self.connection.currentPath?.identifier, path.identifier, "Current path changed")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Makes `oldPath` current and `newPath` another path, then migrates to `newPath`.
    private func migrate(from oldPath: QUICPath, to newPath: QUICPath) {
        connection.currentPath = oldPath
        connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
        connection.multiplexingPaths[newPath.pathIdentifier] = newPath
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
            probedPath.changeState(to: .probing)
            self.connection.currentPath = oldPath
            for path in [oldPath, newPath, probedPath] {
                self.connection.multiplexingPaths[path.pathIdentifier] = path
            }

            self.peerSentPacket(number: 10, on: newPath)

            for (path, cid) in [(oldPath, Self.oldCID), (probedPath, Self.otherCID)] {
                XCTAssertNil(
                    self.connection.multiplexingPaths[path.pathIdentifier],
                    "Path \(path.pathIdentifier) not removed"
                )
                XCTAssertNil(
                    self.connection.remoteCIDs.retire(connectionID: cid),
                    "CID \(cid) not retired"
                )
            }

            // Only the new path remains, and it is now the current path.
            XCTAssertEqual(
                self.connection.multiplexingPaths.count,
                1,
                "Unexpected path count"
            )
            XCTAssertEqual(
                self.connection.currentPath?.identifier,
                newPath.identifier,
                "Current path not switched"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    private func peerSentPacket(number: PacketNumber, isNonProbing: Bool = true, on path: QUICPath) {
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
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[probedPath.pathIdentifier] = probedPath
            XCTAssertEqual(probedPath.state, .routeEstablished)

            self.peerSentPacket(number: 10, isNonProbing: false, on: probedPath)

            XCTAssertEqual(probedPath.dcid, Self.newCID, "Probed path not given a CID")
            XCTAssertTrue(probedPath.isProbing, "Probed path not validated")
            XCTAssertTrue(self.connection.currentPath === currentPath, "Moved on a probing packet")

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
            self.connection.currentPath = firstPath
            for path in [firstPath, peerPath, stalePath] {
                self.connection.multiplexingPaths[path.pathIdentifier] = path
            }

            // The peer's path is not validated yet, so the server keeps every other path.
            self.peerSentPacket(number: 10, on: peerPath)
            XCTAssertTrue(self.connection.currentPath === peerPath, "Did not follow the peer")

            self.peerSentPacket(number: 5, on: stalePath)
            XCTAssertTrue(self.connection.currentPath === peerPath, "Followed an older packet")

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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertTrue(newPath.isProbing, "Peer path not validated")
            XCTAssertTrue(self.connection.currentPath === newPath, "Did not follow the peer")

            self.peerSentPacket(number: 11, on: oldPath)
            XCTAssertTrue(self.connection.currentPath === oldPath, "Did not follow the peer back")
            XCTAssertNil(
                self.connection.multiplexingPaths[newPath.pathIdentifier],
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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertEqual(newPath.dcid, Self.newCID, "Peer path not given a CID")
            XCTAssertTrue(newPath.isProbing, "Peer path not validated")
            XCTAssertTrue(self.connection.currentPath === newPath, "Did not move to the peer path")
            XCTAssertTrue(
                self.connection.multiplexingPaths[oldPath.pathIdentifier] === oldPath,
                "Server dropped the validated path before the new one validated"
            )

            let challenge = PendingChallenge(sentTime: self.connection.now)
            newPath.pendingOutboundChallenges.append(challenge)
            self.connection.fromExternal { eventContext in
                newPath.handlePathChallengeResponse(challenge.data, in: &eventContext)
            }

            XCTAssertTrue(self.connection.currentPath === newPath, "Left the validated peer path")
            XCTAssertNil(
                self.connection.multiplexingPaths[oldPath.pathIdentifier],
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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertTrue(self.connection.currentPath === newPath, "Did not follow the peer")

            // Use up the challenges, then build one more packet, which marks the path unreachable.
            // Following the peer may already have sent the first challenge, at the connection's
            // clock.
            var now = self.connection.now
            for _ in 0...QUICPath.maximumPendingChallenges {
                now = now.advanced(by: .seconds(60))
                var pendingItems = PendingItems(packetNumberSpace: .applicationData)
                self.connection.fromExternal { eventContext in
                    newPath.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                }
            }
            XCTAssertEqual(newPath.state, .unreachable)
            XCTAssertTrue(self.connection.currentPath === newPath, "Moved while building a packet")

            self.connection.fromExternal { eventContext in
                self.connection.migration.timerFired(at: now, connection: self.connection, in: &eventContext)
            }
            XCTAssertTrue(self.connection.currentPath === oldPath, "Did not go back to the validated path")
            XCTAssertNil(
                self.connection.multiplexingPaths[newPath.pathIdentifier],
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
            self.connection.currentPath = handshakePath
            self.connection.multiplexingPaths[handshakePath.pathIdentifier] = handshakePath
            self.connection.multiplexingPaths[otherPath.pathIdentifier] = otherPath
            XCTAssertEqual(handshakePath.state, .cidAssigned)

            self.confirmHandshake()

            XCTAssertTrue(handshakePath.isValidated, "Handshake path left in \(handshakePath.state)")
            XCTAssertFalse(otherPath.isValidated, "Validated a path that was not probed")

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
            self.connection.currentPath = handshakePath
            self.connection.multiplexingPaths[handshakePath.pathIdentifier] = handshakePath
            self.confirmHandshake()

            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertTrue(self.connection.currentPath === newPath, "Did not follow the peer")
            XCTAssertTrue(
                self.connection.multiplexingPaths[handshakePath.pathIdentifier] === handshakePath,
                "Server dropped the handshake path before the new one validated"
            )
            XCTAssertTrue(handshakePath.isValidated, "Server probed the handshake path again")

            var now = self.connection.now
            for _ in 0...QUICPath.maximumPendingChallenges {
                now = now.advanced(by: .seconds(60))
                var pendingItems = PendingItems(packetNumberSpace: .applicationData)
                self.connection.fromExternal { eventContext in
                    newPath.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                }
            }
            XCTAssertEqual(newPath.state, .unreachable)

            self.connection.fromExternal { eventContext in
                self.connection.migration.timerFired(at: now, connection: self.connection, in: &eventContext)
            }
            XCTAssertTrue(self.connection.currentPath === handshakePath, "Did not go back to the handshake path")
            XCTAssertNil(
                self.connection.multiplexingPaths[newPath.pathIdentifier],
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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            XCTAssertEqual(oldPath.state, .cidAssigned)
            XCTAssertNil(
                self.connection.currentPathAmplificationBudget(on: oldPath, alreadySent: 0),
                "Handshake path limited"
            )

            newPath.pathStatistics.increment(.rxBytes, by: 100)
            newPath.pathStatistics.increment(.txBytes, by: 50)
            XCTAssertNil(
                self.connection.currentPathAmplificationBudget(on: newPath, alreadySent: 0),
                "Limited a path that is not current"
            )

            self.peerSentPacket(number: 10, on: newPath)
            XCTAssertTrue(self.connection.currentPath === newPath, "Did not follow the peer")
            XCTAssertTrue(newPath.isProbing)
            XCTAssertEqual(self.connection.currentPathAmplificationBudget(on: newPath, alreadySent: 0), 250)
            XCTAssertEqual(self.connection.currentPathAmplificationBudget(on: newPath, alreadySent: 200), 50)
            XCTAssertEqual(self.connection.currentPathAmplificationBudget(on: newPath, alreadySent: 400), 0)

            let challenge = PendingChallenge(sentTime: self.connection.now)
            newPath.pendingOutboundChallenges.append(challenge)
            self.connection.fromExternal { eventContext in
                newPath.handlePathChallengeResponse(challenge.data, in: &eventContext)
            }
            XCTAssertNil(
                self.connection.currentPathAmplificationBudget(on: newPath, alreadySent: 0),
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
            path.changeState(to: .probing)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            XCTAssertNil(self.connection.currentPathAmplificationBudget(on: path, alreadySent: 0))
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
                self.connection.currentPath?.identifier,
                newPath.identifier,
                "Current path not switched"
            )
            XCTAssertTrue(
                self.connection.multiplexingPaths[oldPath.pathIdentifier] === oldPath,
                "Old path removed"
            )
            XCTAssertTrue(oldPath.isValidated, "Old path no longer validated")
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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            newPath.pathIsPrimary = true

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: newPath.pathIdentifier,
                    event: .established,
                    isPrimary: true,
                    in: &eventContext
                )
            }
            XCTAssertTrue(newPath.isProbing, "New primary path not probed")
            XCTAssertTrue(self.connection.currentPath === oldPath, "Migrated before validation")

            let challenge = PendingChallenge(sentTime: self.connection.now)
            newPath.pendingOutboundChallenges.append(challenge)
            self.connection.fromExternal { eventContext in
                newPath.handlePathChallengeResponse(challenge.data, in: &eventContext)
            }

            XCTAssertTrue(self.connection.currentPath === newPath, "Did not migrate to validated primary path")
            XCTAssertTrue(
                self.connection.multiplexingPaths[oldPath.pathIdentifier] === oldPath,
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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            newPath.pathIsPrimary = true

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: newPath.pathIdentifier,
                    event: .established,
                    isPrimary: true,
                    in: &eventContext
                )
            }
            XCTAssertEqual(newPath.state, .cidAssigned, "Path probed during the handshake")

            self.confirmHandshake()
            XCTAssertTrue(newPath.isProbing, "Path not probed once the handshake was confirmed")

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
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            newPath.pathIsPrimary = true

            self.connection.isHandlingPacket = true
            self.confirmHandshake()
            XCTAssertEqual(newPath.state, .cidAssigned, "Strategy ran in the middle of the packet")

            self.connection.fromExternal { eventContext in
                self.connection.finishHandlingPacket(in: &eventContext)
            }
            XCTAssertTrue(newPath.isProbing, "Path not probed once the packet was handled")
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
            newPath.changeState(to: .probing)
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            newPath.pathIsPrimary = true

            self.connection.isHandlingPacket = true
            self.validate(newPath)
            XCTAssertTrue(newPath.isValidated)
            XCTAssertTrue(self.connection.currentPath === oldPath, "Migrated in the middle of the packet")

            self.connection.fromExternal { eventContext in
                self.connection.finishHandlingPacket(in: &eventContext)
            }
            XCTAssertTrue(self.connection.currentPath === newPath, "Did not migrate once the packet was handled")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // An unusable path is torn down by the connection, whatever the strategy, unless it is the
    // current path.
    private func checkPathThatGoesAwayIsTornDown() {
        let currentPath = makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
        let otherPath = makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
        connection.currentPath = currentPath
        connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
        connection.multiplexingPaths[otherPath.pathIdentifier] = otherPath

        connection.fromExternal { eventContext in
            self.connection.handlePathChanged(
                path: otherPath.pathIdentifier,
                event: .unavailable,
                isPrimary: false,
                in: &eventContext
            )
        }
        XCTAssertNil(connection.multiplexingPaths[otherPath.pathIdentifier], "Unavailable path kept")

        // The current path is kept even when it goes away, since there is nothing to move to.
        connection.fromExternal { eventContext in
            self.connection.handlePathChanged(
                path: currentPath.pathIdentifier,
                event: .unavailable,
                isPrimary: false,
                in: &eventContext
            )
        }
        XCTAssertTrue(
            connection.multiplexingPaths[currentPath.pathIdentifier] === currentPath,
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
            failedPath.changeState(to: .probing)
            failedPath.changeState(to: .unreachable)
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[failedPath.pathIdentifier] = failedPath

            self.connection.receivingPathID = failedPath.pathIdentifier
            self.peerSentPacket(number: 10, on: failedPath)
            XCTAssertTrue(
                self.connection.multiplexingPaths[failedPath.pathIdentifier] === failedPath,
                "Path torn down while its datagrams were being handled"
            )
            XCTAssertEqual(self.connection.deferredTeardownPathIDs, [failedPath.pathIdentifier])
            XCTAssertTrue(self.connection.currentPath === currentPath, "Moved to an unusable path")

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertNil(self.connection.receivingPathID)
            XCTAssertTrue(self.connection.deferredTeardownPathIDs.isEmpty)
            XCTAssertNil(
                self.connection.multiplexingPaths[failedPath.pathIdentifier],
                "Unusable path kept after its datagrams were handled"
            )
            XCTAssertTrue(self.connection.currentPath === currentPath, "Current path changed")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Makes `currentPath` current with the peer on it, and asks for every other path to be torn
    // down while datagrams received on `receivingPath` are being handled.
    private func deferTearingDown(_ receivingPath: QUICPath, keeping currentPath: QUICPath) {
        connection.currentPath = currentPath
        connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
        connection.multiplexingPaths[receivingPath.pathIdentifier] = receivingPath
        connection.receivingPathID = receivingPath.pathIdentifier
        peerSentPacket(number: 10, on: currentPath)
        XCTAssertTrue(
            connection.multiplexingPaths[receivingPath.pathIdentifier] === receivingPath,
            "Path torn down while its datagrams were being handled"
        )
        XCTAssertEqual(connection.deferredTeardownPathIDs, [receivingPath.pathIdentifier])
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
            XCTAssertNil(self.connection.multiplexingPaths[otherPath.pathIdentifier], "Unwanted path kept")
            XCTAssertTrue(self.connection.currentPath === currentPath, "Current path changed")

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
            XCTAssertTrue(self.connection.currentPath === otherPath, "Did not follow the peer")

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertTrue(
                self.connection.multiplexingPaths[otherPath.pathIdentifier] === otherPath,
                "Current path torn down"
            )
            XCTAssertTrue(self.connection.currentPath === otherPath, "Current path changed")
            XCTAssertNil(self.connection.multiplexingPaths[currentPath.pathIdentifier], "Path the peer left kept")

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
            XCTAssertEqual(otherPath.state, .routeEstablished, "Path got a CID the peer never issued")
            XCTAssertTrue(self.connection.currentPath === currentPath)

            self.connection.fromExternal { eventContext in
                self.connection.finishReceiving(in: &eventContext)
            }
            XCTAssertTrue(
                self.connection.multiplexingPaths[otherPath.pathIdentifier] === otherPath,
                "Path the peer moved to torn down"
            )
            XCTAssertTrue(self.connection.currentPath === currentPath, "Current path changed")

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
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            self.connection.currentPath = nil

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: path.pathIdentifier,
                    event: .unavailable,
                    isPrimary: false,
                    in: &eventContext
                )
            }
            XCTAssertTrue(self.connection.multiplexingPaths[path.pathIdentifier] === path, "Path torn down")

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
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            self.connection.state = .closing

            self.peerSentPacket(number: 10, on: newPath)

            XCTAssertTrue(self.connection.currentPath === currentPath, "Migrated while closing")
            XCTAssertEqual(newPath.state, .routeEstablished, "Path probed while closing")
            XCTAssertTrue(self.connection.multiplexingPaths[currentPath.pathIdentifier] === currentPath)
            XCTAssertTrue(self.connection.multiplexingPaths[newPath.pathIdentifier] === newPath)

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
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            newPath.pathIsPrimary = true
            self.connection.state = .draining

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: newPath.pathIdentifier,
                    event: .established,
                    isPrimary: true,
                    in: &eventContext
                )
            }

            XCTAssertTrue(self.connection.currentPath === currentPath, "Migrated while draining")

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
            self.connection.currentPath = lostPath
            self.connection.multiplexingPaths[lostPath.pathIdentifier] = lostPath
            self.connection.multiplexingPaths[standbyPath.pathIdentifier] = standbyPath
            standbyPath.pathIsPrimary = true

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: lostPath.pathIdentifier,
                    event: .unavailable,
                    isPrimary: false,
                    in: &eventContext
                )
            }

            XCTAssertTrue(self.connection.currentPath === standbyPath, "Did not fail over")
            XCTAssertNil(self.connection.multiplexingPaths[lostPath.pathIdentifier], "Lost path kept")

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
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            path.changeState(to: .probing)

            // Send the first challenge, which sets the next challenge deadline and arms the timer.
            let base = NetworkClock.Instant.testBase
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            self.connection.fromExternal { eventContext in
                path.addPathChallenge(to: &pendingItems, now: base, in: &eventContext)
            }
            guard let nextChallengeTime = path.nextChallengeTime else {
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

    private func validate(_ path: QUICPath) {
        let challenge = PendingChallenge(sentTime: connection.now)
        path.pendingOutboundChallenges.append(challenge)
        connection.fromExternal { eventContext in
            path.handlePathChallengeResponse(challenge.data, in: &eventContext)
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
                    path.changeState(to: .probing)
                }
                if transition.from == .validated {
                    path.changeState(to: .validated)
                }
                XCTAssertEqual(path.state, transition.from)
                XCTAssertTrue(self.queuedRetirements.isEmpty, "Retired a CID while holding it")

                path.changeState(to: transition.to)
                let label = "\(transition.from) -> \(transition.to)"
                XCTAssertEqual(self.queuedRetirements, [sequence], label)
                XCTAssertNil(path.dcid, label)
                XCTAssertNil(self.connection.remoteCIDs.find(connectionID: cid), label)

                // The CID is gone, so leaving the next state retires nothing more.
                if transition.to.isValidStateChange(to: .routeUnavailable) {
                    path.changeState(to: .routeUnavailable)
                }
                XCTAssertEqual(self.queuedRetirements, [sequence], label)

                self.connection.queuedRetireConnectionIDSequences.removeAll()
                path.destroyFromExternalTest()
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
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            path.changeState(to: .probing)

            var now = self.connection.now
            for _ in 0...QUICPath.maximumPendingChallenges {
                now = now.advanced(by: .seconds(60))
                var pendingItems = PendingItems(packetNumberSpace: .applicationData)
                self.connection.fromExternal { eventContext in
                    path.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                }
            }
            XCTAssertEqual(path.state, .unreachable)
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
            self.connection.currentPath = wifi
            self.connection.multiplexingPaths[wifi.pathIdentifier] = wifi
            self.connection.multiplexingPaths[cell.pathIdentifier] = cell

            for (to, from) in [(cell, wifi), (wifi, cell), (cell, wifi), (wifi, cell)] {
                from.pathIsPrimary = false
                to.pathIsPrimary = true
                self.connection.fromExternal { eventContext in
                    self.connection.runMigrationStrategy(events: [.pathChanged(to.pathIdentifier)], in: &eventContext)
                }
                XCTAssertTrue(self.connection.currentPath === to, "Did not move to path \(to.pathIdentifier)")
                XCTAssertTrue(from.isValidated, "Path left behind lost its validation")
            }
            XCTAssertEqual(wifi.dcid, Self.cid(1))
            XCTAssertEqual(cell.dcid, Self.cid(2))
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
            self.connection.currentPath = wifi
            for path in [wifi, cell, newWifi] {
                self.connection.multiplexingPaths[path.pathIdentifier] = path
            }
            wifi.pathIsPrimary = false
            newWifi.pathIsPrimary = true

            self.connection.fromExternal { eventContext in
                self.connection.runMigrationStrategy(events: [.pathChanged(newWifi.pathIdentifier)], in: &eventContext)
            }
            XCTAssertEqual(newWifi.state, .routeEstablished, "Path got a CID the peer never issued")
            XCTAssertTrue(self.connection.currentPath === wifi)

            self.connection.fromExternal { eventContext in
                self.connection.handlePathChanged(
                    path: wifi.pathIdentifier,
                    event: .unavailable,
                    isPrimary: false,
                    in: &eventContext
                )
            }
            XCTAssertEqual(self.queuedRetirements, [1], "Lost path did not give up its CID")
            XCTAssertEqual(newWifi.state, .routeEstablished)

            // The peer replaces the retired CID.
            XCTAssertTrue(self.newConnectionID(sequence: 4))
            XCTAssertEqual(newWifi.dcid, Self.cid(4), "Waiting path did not get the new CID")
            XCTAssertTrue(newWifi.isProbing, "Waiting path not probed")

            self.validate(newWifi)
            XCTAssertTrue(self.connection.currentPath === newWifi, "Did not move to the new primary path")
            XCTAssertNil(self.connection.multiplexingPaths[wifi.pathIdentifier], "Lost path kept")
            XCTAssertTrue(cell.isValidated, "Kept path lost its validation")
            XCTAssertEqual(cell.dcid, Self.cid(2))

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
            self.connection.currentPath = wifi
            self.connection.multiplexingPaths[wifi.pathIdentifier] = wifi
            self.connection.multiplexingPaths[cell.pathIdentifier] = cell

            XCTAssertTrue(self.newConnectionID(sequence: 4, retirePriorTo: 3))

            let newCIDs = [Self.cid(3), Self.cid(4)]
            XCTAssertTrue(wifi.isValidated)
            XCTAssertTrue(cell.isValidated, "Kept path lost its validation")
            XCTAssertTrue(newCIDs.contains { $0 == wifi.dcid }, "Current path kept a retired CID")
            XCTAssertTrue(newCIDs.contains { $0 == cell.dcid }, "Kept path kept a retired CID")
            XCTAssertNotEqual(wifi.dcid, cell.dcid, "Two paths share a CID")
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
            self.connection.currentPath = wifi
            self.connection.multiplexingPaths[wifi.pathIdentifier] = wifi
            self.connection.multiplexingPaths[cell.pathIdentifier] = cell

            XCTAssertTrue(self.newConnectionID(sequence: 3, retirePriorTo: 3))

            XCTAssertEqual(wifi.dcid, Self.cid(3), "Current path not given the new CID")
            XCTAssertEqual(cell.state, .routeEstablished)
            XCTAssertNil(cell.dcid)
            XCTAssertTrue(self.queuedRetirements.isEmpty, "Retired a CID the peer already retired")

            // The next CID goes to it. It is not primary, so the client does not probe it.
            XCTAssertTrue(self.newConnectionID(sequence: 4))
            XCTAssertEqual(cell.state, .routeEstablished, "Client brought up a path that is not primary")
            cell.pathIsPrimary = true
            wifi.pathIsPrimary = false
            self.connection.fromExternal { eventContext in
                self.connection.runMigrationStrategy(events: [.pathChanged(cell.pathIdentifier)], in: &eventContext)
            }
            XCTAssertEqual(cell.dcid, Self.cid(4))
            XCTAssertTrue(cell.isProbing)

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
