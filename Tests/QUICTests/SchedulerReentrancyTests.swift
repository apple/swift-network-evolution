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
let schedulerReentrancyTestsLogPrefixer: LogPrefixer = LogPrefixer("[SchedulerReentrancyTests]")

@available(Network 0.1.0, *)
final class SchedulerReentrancyTests: XCTestCase {
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
            self.connection.recovery = Recovery(logPrefixer: schedulerReentrancyTestsLogPrefixer)
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
                self.connection.pendingItemsState.applicationPendingItems.triggerAllStreamsUnblocked = true
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
                self.connection.withSendPathBorrow(in: &eventContext) { eventContext in
                    self.connection.recovery.timerFired(at: NetworkClock.Instant.systemNow, in: &eventContext)
                }
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

    // Scenario: QUICPath.handlePathChallengeResponse -> Migration.migrate -> sendFramesFromMigration ->
    // Migration.tearDownMigratedPath -> sendFramesFromMigration
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
                    stats: &self.connection.stats,
                    ecn: &self.connection.ecn,
                    ack: &self.connection.ack,
                    in: &eventContext
                )
            }

            XCTAssertEqual(self.connection.currentPath?.identifier, migratingPath.identifier)
            XCTAssertNil(self.connection.multiplexingPaths[oldPath.pathIdentifier], "Old path not torn down")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Scenario: PMTUDState.timerFired -> sendProbe -> sendFramesFromRecovery -> addPendingItems ->
    // addPathChallenge -> Migration.resetTimer -> sendPendingChallenges ->
    // sendFrames(on: waitingPath)
    func testPMTUDTimerTriggersChallengeOnWaitingPath() {
        let storage = TestNetworkProtocolStorage(context: .implicitContext)
        let connection = QUICConnection(context: .implicitContext)

        let quicOptions = QUICProtocol.options()
        quicOptions.connectionOptions.pmtud = true
        quicOptions.connectionOptions.pmtudIgnoreCost = true
        // `setup(parameters:)` only picks up these options if they're registered under the
        // connection's own identifier -- `ProtocolOptions.matches(protocolInstance:)` compares by
        // equality, so stamping the connection's own (still-default) identifier here is enough.
        quicOptions.setProtocolInstance(connection.identifier)
        var parameters = Parameters()
        parameters.defaultStack.prepend(applicationProtocol: .quic(quicOptions))
        // A server doesn't validate the peer's `initialSCID` against an original DCID it chose
        // itself, which this lightweight setup (no real Initial packet ever sent) can't provide.
        parameters.isServer = true

        func makeLocalPath(dcid: QUICConnectionID, sequenceNumber: UInt64, validated: Bool) -> QUICPath {
            let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
                identifier: "\(sequenceNumber)",
                context: .implicitContext
            )
            lower.fromExternal { eventContext in
                lower.connect(in: &eventContext)
            }
            var path = QUICPath.makeFromExternalTest(parent: connection)
            path.set(interface: nil, priority: 1, isInitial: true)
            connection.fromExternal { eventContext in
                path.assignDCID(dcid, in: &eventContext)
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

        let expectation = XCTestExpectation()
        connection.context.async {
            try? connection.setup(remote: nil, local: nil, parameters: parameters, path: nil)
            connection.recovery = Recovery(logPrefixer: schedulerReentrancyTestsLogPrefixer)
            connection.recovery.connection = connection

            let currentPath = makeLocalPath(dcid: Self.pathACID, sequenceNumber: 1, validated: false)
            connection.currentPath = currentPath
            connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            // As a server, every packet build is anti-amplification-limited to 3x the bytes
            // received until a real Handshake-space packet has been decrypted -- which this
            // lightweight setup never does. Credit enough received bytes to lift that limit so
            // HANDSHAKE_DONE/NEW_TOKEN (queued by `confirmHandshake` below) and the PMTUD probe can
            // actually build a packet instead of being stuck pending forever.
            connection.stats.increment(.rxBytes, by: 1 << 16)

            // Reach "handshake confirmed, 1-RTT keys installed" without a real TLS handshake, the
            // same way `QUICConnectionTests.makeAsynchronousHandshakeStack` does. Keys must be
            // installed BEFORE `scheduleReportReady` runs: as a server, `confirmHandshake` queues
            // HANDSHAKE_DONE/NEW_TOKEN, and `scheduleReportReady`'s trailing `sendFrames(in:)` only
            // flushes (and clears) that queue if 1-RTT keys are already ready -- otherwise it's
            // stuck pending forever, which would block PMTUD's own `!hasPendingItems` guard.
            let secret = SymmetricKey(data: Array(repeating: UInt8(0x42), count: 48))
            connection.protector.keyUpdate(
                for: .application,
                cipherSuite: .aesGCM256SHA384,
                secret: secret,
                isWrite: true
            )
            connection.protector.keyUpdate(
                for: .application,
                cipherSuite: .aesGCM256SHA384,
                secret: secret,
                isWrite: false
            )
            var peerTransportParameters = TransportParameters(logPrefixer: schedulerReentrancyTestsLogPrefixer)
            peerTransportParameters.append(.initialSCID(connectionID: Self.pathACID))
            peerTransportParameters.append(.initialMaxStreamsBidirectional(value: 4))
            peerTransportParameters.append(.initialMaxStreamsUnidirectional(value: 4))
            peerTransportParameters.append(.initialMaxData(value: 1 << 20))
            peerTransportParameters.append(.initialMaxStreamDataBidirectionalLocal(value: 1 << 16))
            peerTransportParameters.append(.initialMaxStreamDataBidirectionalRemote(value: 1 << 16))
            peerTransportParameters.append(.initialMaxStreamDataUnidirectional(value: 1 << 16))
            connection.fromExternal { eventContext in
                connection.setRemoteTransportParameters(
                    peerTransportParameters,
                    earlyData: false,
                    in: &eventContext
                )
                connection.scheduleReportReady(in: &eventContext)
                connection.confirmHandshake(ack: &connection.ack)
            }

            let waitingPath = makeLocalPath(dcid: Self.pathBCID, sequenceNumber: 2, validated: false)
            connection.multiplexingPaths[waitingPath.pathIdentifier] = waitingPath
            connection.fromExternal { eventContext in
                currentPath.beginValidation(in: &eventContext)
                waitingPath.beginValidation(in: &eventContext)
            }

            connection.fromExternal { eventContext in
                connection.sendPMTUDProbe(
                    on: currentPath,
                    firedAt: NetworkClock.Instant.systemNow,
                    in: &eventContext
                )
            }

            XCTAssertEqual(currentPath.challengesSent, 1)
            XCTAssertEqual(waitingPath.challengesSent, 1)

            connection.currentPath = nil
            for path in connection.multiplexingPaths.values {
                path.destroyFromExternalTest()
            }
            connection.multiplexingPaths.removeAll()

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
