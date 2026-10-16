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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// Tests conditions that QUICConnectionScheduler should prevent
@available(Network 0.1.0, *)
let QUICTestOverlappingAccessTestsLogPrefixer: LogPrefixer = LogPrefixer("[QUICConnectionStateMachineTests]")

@available(Network 0.1.0, *)
final class QUICTestOverlappingAccessTests: XCTestCase {
    var connection = QUICConnection(context: .implicitContext)
    // The base linkages are storage-backed, so lower harnesses have to come from storage
    // rather than being wrapped in a bare linkage.
    let storage = TestNetworkProtocolStorage(context: .implicitContext)

    static let pathACID = QUICConnectionID([0xD1, 0xD2, 0xD3, 0xD4])!
    static let pathBCID = QUICConnectionID([0xD5, 0xD6, 0xD7, 0xD8])!
    static let pathCCID = QUICConnectionID([0xD9, 0xDA, 0xDB, 0xDC])!

    override func setUp() {
        let expectation = XCTestExpectation()
        connection.context.async {
            try? self.connection.setup(remote: nil, local: nil, parameters: nil, path: nil)
            self.connection.recovery = Recovery(logPrefixer: QUICTestOverlappingAccessTestsLogPrefixer)
            self.connection.recovery.connection = self.connection
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    override func tearDown() {
        self.connection.currentPath = nil
        self.connection.context.onQueue {
            for path in self.connection.multiplexingPaths.values {
                path.destroyFromExternalTest()
            }
        }
        self.connection.multiplexingPaths.removeAll()
    }

    // Builds a path open for sending, backed by a lower harness, with its DCID registered in
    // `remoteCIDs` so it can be retired. Mirrors `MigrationTests.makePath`.
    private func makePath(dcid: QUICConnectionID, sequenceNumber: UInt64, validated: Bool) -> QUICPath {
        let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
            identifier: "\(sequenceNumber)",
            context: .implicitContext
        )
        lower.fromExternal { eventContext in
            lower.connect(in: &eventContext)
        }
        var path = QUICPath.makeFromExternalTest(parent: self.connection)
        path.set(interface: nil, priority: 1, isInitial: true)  // -> .routeEstablished
        connection.fromExternal { eventContext in
            path.assignDCID(dcid, in: &eventContext)  // -> .cidAssigned (open for sending)
        }
        if validated {
            path.changeState(to: .probing)
            path.changeState(to: .validated)
        }
        _ = try? path.attachLowerProtocol(lowerLinkage.base)
        try? lowerLinkage.base.invokeAttachUpperProtocol(
            path.asUpperLinkage(),
            remote: nil,
            local: nil,
            parameters: nil,
            path: nil
        )
        try? connection.remoteCIDs.insert(
            sequenceNumber: sequenceNumber,
            connectionID: dcid,
            token: QUICStatelessResetToken(Array(repeating: UInt8(sequenceNumber & 0xff), count: 16))!
        )
        return path
    }

    // Mirrors `RecoveryTests.sentPacket`: records a packet as sent and in flight so the recovery
    // timer has something to find lost (and probe for) when it fires.
    private func recordSentPacket(_ sentPacket: consuming SentPacketRecord) {
        var packets = NetworkUniqueDeque<SentPacketRecord>()
        packets.append(sentPacket)
        connection.recovery.recordSentPackets(
            &packets,
            connection: connection,
            in: &connection.context.eventContext
        )
    }

    // Scenario: sendFrames(in:) -> QUICPath.addPendingItems -> addPathChallenge -> Migration.resetTimer ->
    // sendPendingChallenges -> sendFrames(on: waitingPath)
    func testSendFramesOnCurrentPathTriggersChallengeOnWaitingPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.pathACID, sequenceNumber: 1, validated: false)
            let waitingPath = self.makePath(dcid: Self.pathBCID, sequenceNumber: 2, validated: false)
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[waitingPath.pathIdentifier] = waitingPath

            self.connection.fromExternal { eventContext in
                currentPath.beginValidation(in: &eventContext)
                waitingPath.beginValidation(in: &eventContext)
                // `sendFrames(in:)` bails out before building a packet if nothing is already
                // queued, which is exactly where `addPathChallenge` would run -- so queue
                // something trivial first, mirroring what `Migration.migrate` does.
                self.connection.withPendingItems(for: .applicationData) { $0.ping = true }
                self.connection.sendFrames(in: &eventContext)
            }

            XCTAssertEqual(currentPath.challengesSent, 1)
            XCTAssertEqual(waitingPath.challengesSent, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Scenario: serviceReceivedDatagrams -> inboundStopping -> sendFrames(in:) -> addPendingItems ->
    // addPathChallenge -> Migration.resetTimer -> sendPendingChallenges ->
    // sendFrames(on: waitingPath)
    func testInboundStoppingTriggersChallengeOnWaitingPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.pathACID, sequenceNumber: 1, validated: false)
            let waitingPath = self.makePath(dcid: Self.pathBCID, sequenceNumber: 2, validated: false)
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[waitingPath.pathIdentifier] = waitingPath

            self.connection.fromExternal { eventContext in
                currentPath.beginValidation(in: &eventContext)
                waitingPath.beginValidation(in: &eventContext)
                // Simulate "a received frame unblocked a stream", which is what makes
                // `inboundStopping` decide there is something to flush. The nested `sendFrames(in:)`
                // still bails without a packet to build, so queue something trivial too.
                self.connection.applicationPendingItems.triggerAllStreamsUnblocked = true
                self.connection.withPendingItems(for: .applicationData) { $0.ping = true }
                self.connection.inboundStopping(path: currentPath.pathIdentifier, in: &eventContext)
            }

            XCTAssertEqual(currentPath.challengesSent, 1)
            XCTAssertEqual(waitingPath.challengesSent, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Scenario: Recovery.timerFired -> sendPTO -> retransmitOnePacketForced -> sendFramesFromRecovery ->
    // addPendingItems -> addPathChallenge -> Migration.resetTimer -> sendPendingChallenges ->
    // sendFrames(on: waitingPath)
    func testRecoveryPTOTimerTriggersChallengeOnWaitingPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.pathACID, sequenceNumber: 1, validated: false)
            let waitingPath = self.makePath(dcid: Self.pathBCID, sequenceNumber: 2, validated: false)
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[waitingPath.pathIdentifier] = waitingPath

            self.connection.fromExternal { eventContext in
                currentPath.beginValidation(in: &eventContext)
                waitingPath.beginValidation(in: &eventContext)
            }

            // Record an outstanding ack-eliciting packet on `currentPath` so the recovery timer
            // has something to probe for when it fires.
            var packet = SentPacketRecord()
            packet.identifier = .init(space: .applicationData, number: 0)
            packet.isInFlightEligible = true
            packet.isAckEliciting = true
            packet.totalLength = 20 + 96
            packet.transmittedItems.ping = true
            packet.sentPath = currentPath.pathIdentifier
            self.recordSentPacket(packet)

            self.connection.fromExternal { eventContext in
                // Match production exactly: the Timer registration always wraps
                // `recovery.timerFired` in `withSendPathBorrow`, which is what makes `isSendActive`
                // correctly reflect "a send-path operation is in progress" for the duration.
                self.connection.recovery.timerFired(at: NetworkClock.Instant.systemNow, in: &eventContext)
            }

            XCTAssertEqual(currentPath.challengesSent, 1)
            XCTAssertEqual(waitingPath.challengesSent, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Scenario: fireDelayedAckTimer -> Ack.timerFired -> sendFrames(delayedACK:true) -> addPendingItems ->
    // addPathChallenge -> Migration.resetTimer -> sendPendingChallenges ->
    // sendFrames(on: waitingPath)
    func testAckTimerTriggersChallengeOnWaitingPathWhileFlushingOwedAck() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.pathACID, sequenceNumber: 1, validated: false)
            let waitingPath = self.makePath(dcid: Self.pathBCID, sequenceNumber: 2, validated: false)
            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[waitingPath.pathIdentifier] = waitingPath

            self.connection.fromExternal { eventContext in
                currentPath.beginValidation(in: &eventContext)
                waitingPath.beginValidation(in: &eventContext)
            }

            // Make the client owe the peer a delayed ACK for `.applicationData`, so the timer has
            // something to assemble and send.
            self.connection.ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
            self.connection.ack.shouldTransmit(packetNumberSpace: .applicationData)
            // `sendFrames(delayedACK:true, in:)` still bails without a packet to build if the ACK
            // assembly didn't queue one, so queue something trivial too, same as the other tests.
            self.connection.withPendingItems(for: .applicationData) { $0.ping = true }

            self.connection.fromExternal { eventContext in
                self.connection.fireDelayedAckTimer(at: .systemNow, in: &eventContext)
            }

            XCTAssertEqual(currentPath.challengesSent, 1)
            XCTAssertEqual(waitingPath.challengesSent, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Scenario: QUICPath.handlePathChallengeResponse -> Migration.migrate -> sendFrames ->
    // Migration.tearDownMigratedPath -> sendFrames
    func testMigrateCompletingRoutesSendFramesFromMigrationThroughScheduler() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.pathACID, sequenceNumber: 1, validated: true)
            let migratingPath = self.makePath(dcid: Self.pathBCID, sequenceNumber: 2, validated: false)
            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[migratingPath.pathIdentifier] = migratingPath

            self.connection.fromExternal { eventContext in
                migratingPath.beginValidation(in: &eventContext)
            }
            let challenge = FramePathChallenge(data: 1)
            self.connection.fromExternal { eventContext in
                migratingPath.handlePathChallenge(challenge.data, in: &eventContext)
            }
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            self.connection.fromExternal { eventContext in
                migratingPath.addPendingItems(&pendingItems, now: .systemNow, in: &eventContext)
            }
            guard let outboundChallenge = pendingItems.pathChallenges.first?.data else {
                XCTFail("Expected an outbound challenge to have been queued")
                expectation.fulfill()
                return
            }
            migratingPath.migrationPending = true

            self.connection.fromExternal { eventContext in
                migratingPath.handlePathChallengeResponse(
                    outboundChallenge,
                    in: &eventContext
                )
            }

            XCTAssertEqual(self.connection.currentPath?.identifier, migratingPath.identifier)
            XCTAssertNil(self.connection.multiplexingPaths[oldPath.pathIdentifier], "Old path not torn down")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Adding a PATH_CHALLENGE re-arms the migration timer, which sends whatever is due on every
    // path. With a second path still waiting for its first challenge, that must not start a send
    // on it while the send on the first path is still running.
    func testChallengeWhileAnotherPathWaitsForItsFirstChallenge() {
        let probeCID = QUICConnectionID([0xC1, 0xC2, 0xC3, 0xC4])!
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: MigrationTests.oldCID, sequenceNumber: 1, validated: true)
            let firstPath = self.makePath(dcid: MigrationTests.newCID, sequenceNumber: 2, validated: false)
            let secondPath = self.makePath(dcid: probeCID, sequenceNumber: 3, validated: false)
            self.connection.currentPath = currentPath
            for path in [currentPath, firstPath, secondPath] {
                self.connection.multiplexingPaths[path.pathIdentifier] = path
            }

            self.connection.fromExternal { eventContext in
                firstPath.beginValidation(in: &eventContext)
                secondPath.beginValidation(in: &eventContext)
                self.connection.sendFrames(on: firstPath, in: &eventContext)
            }

            XCTAssertEqual(firstPath.challengesSent, 1)
            XCTAssertEqual(secondPath.challengesSent, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
