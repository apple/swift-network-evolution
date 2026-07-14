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
        connection.recovery.recordSentPackets(packets, connection: connection)
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
        XCTAssertGreaterThan(connection.recovery.computedTimeout, .milliseconds(900))

        var expectation = XCTestExpectation()
        self.connection.context.async {
            timeNow = timeNow.advanced(by: .seconds(1))
            self.connection.recovery.timerFired(timeNow: timeNow)
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
        XCTAssertGreaterThan(connection.recovery.computedTimeout, .milliseconds(1900))

        expectation = XCTestExpectation()
        self.connection.context.async {
            timeNow = timeNow.advanced(by: .seconds(2))
            self.connection.recovery.timerFired(timeNow: timeNow)
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
        XCTAssertGreaterThan(connection.recovery.computedTimeout, .milliseconds(3900))

        expectation = XCTestExpectation()
        self.connection.context.async {
            timeNow = timeNow.advanced(by: .seconds(4))
            self.connection.recovery.timerFired(timeNow: timeNow)
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
        XCTAssertGreaterThan(connection.recovery.computedTimeout, .milliseconds(7900))
    }

    // A PTO with ack-eliciting data in flight must emit a probe, even when the only outstanding
    // packet carries STREAM data for a now-closed flow (so it can't be rebuilt) and the connection
    // is validated; otherwise sendPTO sends nothing and the connection spins to idle timeout.
    func testPTOWithClosedFlowStreamPacketStillProbes() {
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

        // The PTO must have sent a probe and advanced the PTO count. On the buggy code no probe is
        // sent and PTOCount stays 0, so the connection would spin until idle timeout.
        XCTAssertEqual(
            path.recoveryState.PTOCount,
            1,
            "PTO produced no probe for a closed-flow tail packet; connection would spin to idle timeout"
        )
    }
}

#endif
