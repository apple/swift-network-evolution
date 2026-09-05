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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

@available(Network 0.1.0, *)
let recoveryTestsLogPrefixer: LogPrefixer = LogPrefixer("[RecoveryTests]")

@available(Network 0.1.0, *)
final class RecoveryTests: XCTestCase {
    var connection = QUICConnection(context: .implicitContext)
    var path: QUICPath! = nil

    override func setUp() {
        let expectation = XCTestExpectation()
        self.connection.context.async {
            try? self.connection.setup(remote: nil, local: nil, parameters: nil, path: nil)
            self.connection.recovery = Recovery(logPrefixer: recoveryTestsLogPrefixer)
            self.connection.recovery.connection = self.connection
            let lowerHarness = DatagramLowerHarness(
                identifier: "Client",
                context: .implicitContext
            )
            lowerHarness.connect()
            var newPath = QUICPath(parent: self.connection)
            newPath.set(interface: nil, priority: 1, isInitial: true)
            newPath.assignDCID(QUICConnectionID(0))
            newPath.setSCID(QUICConnectionID(0))
            try? newPath.attachLowerProtocol(
                lowerHarness.reference,
                remote: nil,
                local: nil,
                parameters: nil,
                path: nil
            )
            self.path = newPath
            self.connection.currentPath = newPath
            self.connection.multiplexingPaths[newPath.identifier] = newPath
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    override func tearDown() {
        self.connection.currentPath = nil
    }

    func sentPacket(_ sentPacket: consuming SentPacketRecord, connection: QUICConnection) {
        var packets = NetworkUniqueDeque<SentPacketRecord>()
        packets.append(sentPacket)
        connection.recovery.recordSentPackets(&packets, connection: connection)
    }

    func testInitialValues() {
        connection.withCurrentPath { path in
            XCTAssertEqual(path.recoveryState.PTOPeriod, .zero)
        }
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: .initial),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: .handshake),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: .applicationData),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: .initial),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: .handshake),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: .applicationData),
            PacketNumber.none
        )
        for space in PacketNumberSpace.allCases {
            connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
                innerState in
                XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
            }
        }
    }

    func testSentPacket() {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .initial, number: 1)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 20 + 96
        let sentPath = connection.currentPath?.identifier ?? .none
        packet.sentPath = sentPath
        let space = packet.identifier.space
        sentPacket(packet, connection: connection)
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: space),
            1
        )
        //path.withCongestionControl { XCTAssertEqual($0.bytesInFlight, 116) }
        XCTAssertEqual(path.congestionControlBytesInFlight, 116)
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }
    }

    func testResetInitialSpace() throws {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .initial, number: 10)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 500 + 500
        packet.sentPath = connection.currentPath?.identifier ?? .none
        let space = packet.identifier.space

        sentPacket(packet, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            10
        )

        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }

        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )

        connection.recovery.resetPNSpace(packetNumberSpace: space, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            .none
        )
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )
    }

    func testResetHandshakeSpace() throws {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .handshake, number: 1)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 500 + 500
        packet.sentPath = connection.currentPath?.identifier ?? .none
        let space = packet.identifier.space

        sentPacket(packet, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            1
        )

        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }

        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )

        connection.recovery.resetPNSpace(packetNumberSpace: space, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            .none
        )
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )
    }

    func testResetApplicationDataSpace() throws {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .applicationData, number: 4)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 500 + 500
        packet.sentPath = connection.currentPath?.identifier ?? .none
        let space = packet.identifier.space

        sentPacket(packet, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            4
        )

        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }

        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )

        connection.recovery.resetPNSpace(packetNumberSpace: space, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            .none
        )
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )
    }

    func testResetApplicationSpaceNonAckEliciting() throws {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .applicationData, number: 10)
        packet.isInFlightEligible = true
        packet.isAckEliciting = false
        packet.totalLength = 500 + 516
        let sentPath = connection.currentPath?.identifier ?? .none
        packet.sentPath = sentPath
        let space = packet.identifier.space

        sentPacket(packet, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            10
        )
        XCTAssertEqual(path.congestionControlBytesInFlight, 1016)
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )

        connection.recovery.resetPNSpace(packetNumberSpace: space, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )

        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
    }

    func testPacketAcked() {
        let ackFrame = FrameAck(
            packetNumberSpace: .applicationData,
            largest: 3,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 3)]
        )
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .applicationData, number: 3)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 500 + 540
        let sentPath = connection.currentPath?.identifier ?? .none
        packet.sentPath = sentPath
        let space = packet.identifier.space
        sentPacket(packet, connection: connection)
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            3
        )
        XCTAssertEqual(path.congestionControlBytesInFlight, 1040)
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(
                packetNumberSpace: space
            ),
            PacketNumber.none
        )

        // Validate that the congestion window starts at the default
        XCTAssertEqual(path.congestionControlWindow, 12000)

        connection.recovery.receivedAck(
            ack: ackFrame,
            ackedPath: connection.currentPath!,
            connection: connection
        )

        // Validate that the congestion window has grown after the packet is acked
        XCTAssertGreaterThan(path.congestionControlWindow, 12000)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(
                packetNumberSpace: space
            ),
            3
        )
        XCTAssertEqual(path.congestionControlBytesInFlight, 0)
        connection.recovery.withImmutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(connection.recovery.getLargestAckedPN(packetNumberSpace: space), 3)
    }

    func testPacketAckedNonAckEliciting() throws {
        let ackFrame = FrameAck(
            packetNumberSpace: .applicationData,
            largest: 3,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 3)]
        )
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .applicationData, number: 3)
        packet.isInFlightEligible = true
        packet.isAckEliciting = false
        packet.totalLength = 500 + 524
        packet.sentPath = connection.currentPath?.identifier ?? .none
        packet.transmittedItems = TransmittedItems()
        packet.transmittedItems.ackFrame = .init(ackFrame)
        let space = packet.identifier.space

        sentPacket(packet, connection: connection)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: space),
            PacketNumber(3)
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: space),
            PacketNumber.none
        )
        connection.recovery.withMutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }

        connection.recovery
            .receivedAck(
                ack: ackFrame,
                ackedPath: connection.currentPath!,
                connection: connection
            )

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: space),
            PacketNumber(3)
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: space),
            PacketNumber(3)
        )
        connection.recovery.withMutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }

    }

    func testResetPNSpaceAndDiscard() {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .applicationData, number: 3)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 540 + 500
        packet.sentPath = connection.currentPath?.identifier ?? .none
        let space = packet.identifier.space
        sentPacket(packet, connection: connection)
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: space),
            PacketNumber(3)
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: space),
            PacketNumber.none
        )
        connection.recovery.withMutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }

        connection.recovery.withMutableInnerState(packetNumberSpace: space) {
            innerState in
            innerState.ackElicitingPacketsInFlight -= 1
        }

        connection.recovery.withMutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        let expectation = XCTestExpectation()
        self.connection.context.async {
            self.connection.recovery.resetAll()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: space),
            PacketNumber.none
        )
        XCTAssertEqual(
            connection.recovery.getLargestAckedPN(packetNumberSpace: space),
            PacketNumber.none
        )
        connection.recovery.withMutableInnerState(packetNumberSpace: space) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }

    }

    func testWithImmutableInnerState() {
        // This test validates the assumption that the closure will ALWAYS be invoked. If that assumption
        // changes and the closure MAY NOT be run under certain conditions, the above tests will need checks to
        // ensure the test asserts are run in order to assure correct operation.

        for space in PacketNumberSpace.allCases {
            var wasCalled = false
            connection.recovery.withImmutableInnerState(packetNumberSpace: space) { _ in
                wasCalled = true
            }
            XCTAssertTrue(wasCalled)
        }
    }

    func testWithMutableInnerState() {
        // This test validates the assumption that the closure will ALWAYS be invoked. If that assumption
        // changes and the closure MAY NOT be run under certain conditions, the above tests will need checks to
        // ensure the test asserts are run in order to assure correct operation.

        for space in PacketNumberSpace.allCases {
            var wasCalled = false
            connection.recovery.withMutableInnerState(packetNumberSpace: space) { _ in
                wasCalled = true
            }
            XCTAssertTrue(wasCalled)
        }
    }

    func testApplyToAllInnerStatesImmutable() {
        // This test validates the assumption that the closure will ALWAYS be invoked. If that assumption
        // changes and the closure MAY NOT be run under certain conditions, the above tests will need checks to
        // ensure the test asserts are run in order to assure correct operation.

        for space in PacketNumberSpace.allCases {
            var wasCalled = false
            connection.recovery.applyToAllInnerStatesImmutable { innerState, packetNumberSpace in
                if packetNumberSpace == space {
                    wasCalled = true
                }
            }
            XCTAssertTrue(wasCalled)
        }
    }

    func testApplyToAllInnerStatesMutable() {
        // This test validates the assumption that the closure will ALWAYS be invoked. If that assumption
        // changes and the closure MAY NOT be run under certain conditions, the above tests will need checks to
        // ensure the test asserts are run in order to assure correct operation.

        for space in PacketNumberSpace.allCases {
            var wasCalled = false
            connection.recovery.applyToAllInnerStatesMutable { innerState, packetNumberSpace in
                if packetNumberSpace == space {
                    wasCalled = true
                }
            }
            XCTAssertTrue(wasCalled)
        }
    }

    func testPTO() {
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .initial, number: 0)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 20 + 96
        // Pretend there was an ACK eliciting frame inside the packet.
        packet.transmittedItems.ping = true
        let sentPath = connection.currentPath?.identifier ?? .none
        packet.sentPath = sentPath
        var timeNow = NetworkClock.Instant.now
        sentPacket(packet, connection: connection)
        XCTAssertEqual(
            connection.recovery.getLargestSentPN(packetNumberSpace: .initial),
            0
        )
        connection.recovery.withImmutableInnerState(packetNumberSpace: .initial) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .handshake) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(path.recoveryState.PTOCount, 0)
        // `PTOPeriod` is the backed-off period; `computedTimeout` is what remains of it once the
        // fired instant is taken into account, and this test advances its own clock by whole
        // seconds between fires, so only the former doubles.
        XCTAssertGreaterThan(path.recoveryState.PTOPeriod, .milliseconds(900))

        var expectation = XCTestExpectation()
        self.connection.context.async {
            timeNow = timeNow.advanced(by: .seconds(1))
            self.connection.recovery.timerFired(at: timeNow)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        connection.recovery.withImmutableInnerState(packetNumberSpace: .initial) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 2)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .handshake) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(path.recoveryState.PTOCount, 1)
        XCTAssertGreaterThan(path.recoveryState.PTOPeriod, .milliseconds(1900))

        expectation = XCTestExpectation()
        self.connection.context.async {
            timeNow = timeNow.advanced(by: .seconds(2))
            self.connection.recovery.timerFired(at: timeNow)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        connection.recovery.withImmutableInnerState(packetNumberSpace: .initial) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 4)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .handshake) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(path.recoveryState.PTOCount, 2)
        XCTAssertGreaterThan(path.recoveryState.PTOPeriod, .milliseconds(3900))

        expectation = XCTestExpectation()
        self.connection.context.async {
            timeNow = timeNow.advanced(by: .seconds(4))
            self.connection.recovery.timerFired(at: timeNow)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        connection.recovery.withImmutableInnerState(packetNumberSpace: .initial) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 6)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .handshake) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 0)
        }
        XCTAssertEqual(path.recoveryState.PTOCount, 3)
        XCTAssertGreaterThan(path.recoveryState.PTOPeriod, .milliseconds(7900))
    }

    // A PTO with ack-eliciting data in flight must emit a probe, even when the only outstanding
    // packet carries STREAM data for a now-closed flow (so it can't be rebuilt) and the connection
    // is validated; otherwise `sendPTO` sends nothing and the connection makes no progress until the
    // idle timeout closes it.
    func testValidatedPTOProbesWhenTailRetransmitProducesNothing() {
        // Register a flow and close it, so its STREAM data can never be rebuilt for retransmission.
        let stream = QUICStreamInstance(parent: connection, inbound: true)
        stream.setup(streamID: QUICStreamID(0), logPrefixer: recoveryTestsLogPrefixer)
        connection.multiplexedFlows[stream.identifier] = stream
        stream.closed = true
        XCTAssertFalse(stream.isOpen)

        // A single ack-eliciting application-data packet is outstanding, carrying only that flow's
        // STREAM data. This keeps ackElicitingPacketsInFlight > 0 (so the PTO stays armed) while
        // being unrebuildable once the flow is closed.
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .applicationData, number: 0)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 20 + 96
        packet.sentPath = connection.currentPath?.identifier ?? .none
        packet.transmittedItems.sentStreams.append(
            TransmittedItems.SentStream(
                flowID: stream.identifier,
                streamID: QUICStreamID(0),
                offset: 0,
                length: 32,
                isFinal: true
            )
        )
        XCTAssertTrue(packet.transmittedItems.hasRetransmissibleItems)
        sentPacket(packet, connection: connection)

        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }

        // Establish (address-validated) connection: peerCompletedValidation must be true. This is
        // the condition under which the anti-deadlock PING is incorrectly skipped.
        connection.recovery.received1RTTAck = true
        XCTAssertTrue(connection.recovery.peerCompletedValidation(connection: connection))
        XCTAssertEqual(path.recoveryState.PTOCount, 0)

        // Fire the PTO with no new ack-eliciting data pending.
        let expectation = XCTestExpectation()
        self.connection.context.async {
            self.connection.withCurrentPath { path in
                self.connection.recovery.sendPTO(connection: self.connection, path: path)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // A probe must have been recorded, taking the packets in flight to two, and the PTO counted.
        XCTAssertEqual(
            connection.recovery.totalAckElicitingPacketsInFlight,
            2,
            "PTO produced no probe for a closed-flow tail packet"
        )
        XCTAssertEqual(path.recoveryState.PTOCount, 1)
    }

    // `sendPTO` must emit a probe; otherwise the PTO makes no progress. A pending item whose flow was
    // torn down writes no payload, so ensure the probe only counts once the packet is recorded.
    func testPTOProbesWhenNewDataProducesNothing() {
        // A stream queued for service whose flow has since been torn down: it is absent from
        // `multiplexedFlows`, so writing it produces no payload.
        let unregisteredStream = QUICStreamInstance(parent: connection, inbound: true)
        unregisteredStream.setup(streamID: QUICStreamID(0), logPrefixer: recoveryTestsLogPrefixer)
        XCTAssertNil(connection.flow(for: unregisteredStream.identifier))
        connection.withPendingItems(for: .initial) { pendingItems in
            pendingItems.streamsToService.append(unregisteredStream.identifier)
            pendingItems.stream = true
        }

        // Recovery still sees new ack-eliciting data, so the PTO sends that rather than retransmitting.
        let hasPendingAckEliciting = connection.withPendingItems(for: .initial) {
            $0.hasAckElicitingPendingItems
        }
        XCTAssertTrue(hasPendingAckEliciting)

        // One ack-eliciting packet outstanding, so the PTO is armed and the per-space loop runs.
        var packet = SentPacketRecord()
        packet.identifier = .init(space: .initial, number: 0)
        packet.isInFlightEligible = true
        packet.isAckEliciting = true
        packet.totalLength = 20 + 96
        packet.sentPath = connection.currentPath?.identifier ?? .none

        sentPacket(packet, connection: connection)

        connection.recovery.withImmutableInnerState(packetNumberSpace: .initial) { innerState in
            XCTAssertEqual(innerState.ackElicitingPacketsInFlight, 1)
        }

        let expectation = XCTestExpectation()
        self.connection.context.async {
            self.connection.withCurrentPath { path in
                self.connection.recovery.sendPTO(connection: self.connection, path: path)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // Ensure a probe has been recorded, taking the packets in flight to two.
        connection.recovery.withImmutableInnerState(packetNumberSpace: .initial) { innerState in
            XCTAssertEqual(
                innerState.ackElicitingPacketsInFlight,
                2,
                "PTO reported a probe but no packet was sent"
            )
        }
    }

    // MARK: - Packet index hints

    /// Records a sparse ascending run of packets in the application data space.
    private func recordSparsePackets(_ packetNumbers: [Int64]) {
        for number in packetNumbers {
            var packet = SentPacketRecord()
            packet.identifier = .init(space: .applicationData, number: PacketNumber(number))
            packet.isInFlightEligible = true
            packet.isAckEliciting = true
            packet.totalLength = 100
            packet.sentPath = connection.currentPath?.identifier ?? .none
            sentPacket(packet, connection: connection)
        }
    }

    /// Removes an outstanding packet, asserting it was present. `removeSentPacket`
    /// returns a non-copyable entry, so the result is reduced to a `Bool` here.
    private func removeOutstanding(
        _ innerState: inout Recovery.InnerState,
        _ number: Int64,
        _ message: String
    ) {
        let removed = innerState.removeSentPacket(PacketNumber(number)) != nil
        XCTAssertTrue(removed, message)
    }

    /// Every recorded packet must be findable, and absent numbers must not be
    /// reported as present, regardless of the hints accumulated along the way.
    func testIndexOfPacketNumberFindsSparseEntries() {
        let numbers: [Int64] = [4, 5, 9, 10, 11, 20, 21, 40, 41, 42, 100]
        recordSparsePackets(numbers)

        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            for (expectedIndex, number) in numbers.enumerated() {
                XCTAssertEqual(
                    innerState.indexOfPacketNumber(PacketNumber(number)),
                    expectedIndex,
                    "Packet \(number) should be at index \(expectedIndex)"
                )
            }
            // Numbers in the gaps, and outside the range entirely, are absent.
            for absent: Int64 in [0, 3, 6, 8, 12, 19, 30, 43, 99, 101, 1000] {
                XCTAssertNil(
                    innerState.indexOfPacketNumber(PacketNumber(absent)),
                    "Packet \(absent) was never recorded"
                )
            }
        }
    }

    /// Removing from the front — the common in-order acknowledgement case — must
    /// keep the remaining lookups correct as cached indices shift down.
    func testIndexOfPacketNumberAfterFrontRemovals() {
        var remaining: [Int64] = [4, 5, 9, 10, 11, 20, 21, 40, 41, 42, 100]
        recordSparsePackets(remaining)

        while !remaining.isEmpty {
            let removed = remaining.removeFirst()
            connection.recovery.withMutableInnerState(packetNumberSpace: .applicationData) {
                innerState in
                removeOutstanding(
                    &innerState,
                    removed,
                    "Packet \(removed) should still be outstanding"
                )
                XCTAssertNil(
                    innerState.indexOfPacketNumber(PacketNumber(removed)),
                    "Packet \(removed) was just removed"
                )
                for (expectedIndex, number) in remaining.enumerated() {
                    XCTAssertEqual(
                        innerState.indexOfPacketNumber(PacketNumber(number)),
                        expectedIndex,
                        "After removing \(removed), packet \(number) should be at \(expectedIndex)"
                    )
                }
            }
        }
    }

    /// Removing from the middle exercises hint invalidation: pairs above the
    /// removed index shift down, and the pair naming it must be dropped.
    func testIndexOfPacketNumberAfterInteriorRemovals() {
        var remaining: [Int64] = [1, 2, 3, 7, 8, 15, 16, 17, 30, 31, 60, 61, 62]
        recordSparsePackets(remaining)

        // Prime the hints with lookups spread across the deque, then remove from
        // the middle so the cached indices must be adjusted.
        for removed: Int64 in [15, 8, 31, 60, 2, 17] {
            connection.recovery.withMutableInnerState(packetNumberSpace: .applicationData) {
                innerState in
                for number in remaining {
                    _ = innerState.indexOfPacketNumber(PacketNumber(number))
                }
                removeOutstanding(
                    &innerState,
                    removed,
                    "Packet \(removed) should still be outstanding"
                )
                remaining.removeAll { $0 == removed }
                for (expectedIndex, number) in remaining.enumerated() {
                    XCTAssertEqual(
                        innerState.indexOfPacketNumber(PacketNumber(number)),
                        expectedIndex,
                        "After removing \(removed), packet \(number) should be at \(expectedIndex)"
                    )
                }
                XCTAssertNil(innerState.indexOfPacketNumber(PacketNumber(removed)))
            }
        }
    }

    /// Appending after removals must not leave stale hints behind: the deque can
    /// drain to empty and refill with much larger packet numbers.
    func testIndexOfPacketNumberAcrossDrainAndRefill() {
        recordSparsePackets([1, 2, 3])
        connection.recovery.withMutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            for number: Int64 in [1, 2, 3] {
                removeOutstanding(&innerState, number, "Packet \(number) should be outstanding")
            }
            XCTAssertTrue(innerState.outstandingPackets.isEmpty)
        }

        let refilled: [Int64] = [500, 501, 700]
        recordSparsePackets(refilled)
        connection.recovery.withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            for (expectedIndex, number) in refilled.enumerated() {
                XCTAssertEqual(
                    innerState.indexOfPacketNumber(PacketNumber(number)),
                    expectedIndex
                )
            }
            // The drained packet numbers must not resolve to the refilled entries.
            for absent: Int64 in [1, 2, 3] {
                XCTAssertNil(innerState.indexOfPacketNumber(PacketNumber(absent)))
            }
        }
    }

}

#endif
