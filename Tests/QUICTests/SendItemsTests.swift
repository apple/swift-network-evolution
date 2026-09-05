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

@available(Network 0.1.0, *)
final class SendItemsTests: XCTestCase {

    func testHasFrames() {
        var pendingItems = PendingItems(packetNumberSpace: .initial)
        XCTAssertFalse(pendingItems.hasPendingItems)

        pendingItems.ping = true
        XCTAssertTrue(pendingItems.hasPendingItems)
    }

    func testHasAckElicitingFrame() {
        var pendingItems = PendingItems(packetNumberSpace: .initial)
        XCTAssertFalse(pendingItems.hasAckElicitingPendingItems)

        // all ack, padding, app close and connection close packets are not ack eliciting
        let ackFrame = FrameAck(packetNumberSpace: .initial, largest: 128, delay: 10)
        pendingItems.setAckFrame(.ack(frame: ackFrame), ping: false)
        XCTAssertFalse(pendingItems.hasAckElicitingPendingItems)

        pendingItems.paddingApproach = .fixedSize(1)
        XCTAssertFalse(pendingItems.hasAckElicitingPendingItems)

        // ping is ack eliciting
        pendingItems.ping = true
        XCTAssertTrue(pendingItems.hasAckElicitingPendingItems)
    }

    func runPendingItemsTest(
        _ pendingItems: consuming PendingItems,
        transmittedItems: inout TransmittedItems,
        isAckEliciting: inout Bool,
        isInFlightEligible: inout Bool
    ) {
        var frame = Frame(count: 1200)
        defer { frame.finalize(success: true) }
        let context = NetworkContext(identifier: "SendItemsTests")
        let connection = QUICConnection(context: context)
        var shorthandFrames: [QUICShorthandFrame]? = nil
        XCTAssertNoThrow(
            try pendingItems.write(
                into: &frame,
                connection: connection,
                stats: &connection.stats,
                keyState: .phase0,
                transmittedItems: &transmittedItems,
                availableCongestionWindow: 10000,
                isAckEliciting: &isAckEliciting,
                isInFlightEligible: &isInFlightEligible,
                shorthandFrames: &shorthandFrames
            )
        )

    }

    func testPendingItems_ACK() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ack = true
        pendingItems.ackFrame = FrameAck(
            packetNumberSpace: .applicationData,
            largest: 2000,
            delay: 42
        )
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false

        runPendingItemsTest(
            pendingItems,
            transmittedItems: &transmittedItems,
            isAckEliciting: &isAckEliciting,
            isInFlightEligible: &isInFlightEligible
        )

        XCTAssertFalse(isAckEliciting)
        XCTAssertFalse(isInFlightEligible)

        XCTAssertTrue(transmittedItems.ackFrame != nil)
        let largest = transmittedItems.ackFrame?.largest
        let delay = transmittedItems.ackFrame?.delay
        XCTAssertEqual(largest, 2000)
        XCTAssertEqual(delay, 42)
    }

    func testPendingItems_PADDING() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.paddingApproach = .fixedSize(100)
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false

        runPendingItemsTest(
            pendingItems,
            transmittedItems: &transmittedItems,
            isAckEliciting: &isAckEliciting,
            isInFlightEligible: &isInFlightEligible
        )

        XCTAssertFalse(isAckEliciting)
        XCTAssertTrue(isInFlightEligible)
    }

    func testPendingItems_PING() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ping = true
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false

        runPendingItemsTest(
            pendingItems,
            transmittedItems: &transmittedItems,
            isAckEliciting: &isAckEliciting,
            isInFlightEligible: &isInFlightEligible
        )

        XCTAssertTrue(isAckEliciting)
        XCTAssertTrue(isInFlightEligible)

        XCTAssertTrue(transmittedItems.ping)
    }

    func testRetireConnectionID_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addRetireConnectionID(FrameRetireConnectionID(sequence: 0))
        pendingItems.addRetireConnectionID(FrameRetireConnectionID(sequence: 1))

        var transmittedItems = TransmittedItems()
        FrameRetireConnectionID.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.retireConnectionIDs.count, 1)
        XCTAssertEqual(transmittedItems.retireConnectionIDs.count, 1)
        XCTAssertEqual(
            pendingItems.retireConnectionID,
            !pendingItems.retireConnectionIDs.isEmpty,
            "PendingItems.retireConnectionID flag must mirror retireConnectionIDs deque emptiness"
        )
    }

    func testPathChallenge_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addPathChallenge(FramePathChallenge(data: 1))
        pendingItems.addPathChallenge(FramePathChallenge(data: 2))

        var transmittedItems = TransmittedItems()
        FramePathChallenge.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.pathChallenges.count, 1)
        XCTAssertEqual(
            pendingItems.pathChallenge,
            !pendingItems.pathChallenges.isEmpty,
            "PendingItems.pathChallenge flag must mirror pathChallenges deque emptiness"
        )
    }

    func testPathResponse_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addPathResponse(FramePathResponse(data: 1))
        pendingItems.addPathResponse(FramePathResponse(data: 2))

        var transmittedItems = TransmittedItems()
        FramePathResponse.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.pathResponses.count, 1)
        XCTAssertEqual(
            pendingItems.pathResponse,
            !pendingItems.pathResponses.isEmpty,
            "PendingItems.pathResponse flag must mirror pathResponses deque emptiness"
        )
    }

    func testStreamReset_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addStreamReset(streamID: 0, code: 0, finalSize: 1000)
        pendingItems.addStreamReset(streamID: 4, code: 0, finalSize: 1000)

        var transmittedItems = TransmittedItems()
        FrameResetStream.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.streamResets.count, 1)
        XCTAssertEqual(transmittedItems.streamResets.count, 1)
        XCTAssertEqual(
            pendingItems.resetStream,
            !pendingItems.streamResets.isEmpty,
            "PendingItems.resetStream flag must mirror streamResets deque emptiness"
        )
    }

    func testStopSending_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addStreamStopSending(streamID: 0, code: 0)
        pendingItems.addStreamStopSending(streamID: 4, code: 0)

        var transmittedItems = TransmittedItems()
        FrameStopSending.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.streamStopSendings.count, 1)
        XCTAssertEqual(transmittedItems.streamStopSendings.count, 1)
        XCTAssertEqual(
            pendingItems.stopSendingFlag,
            !pendingItems.streamStopSendings.isEmpty,
            "PendingItems.stopSendingFlag must mirror streamStopSendings deque emptiness"
        )
    }

    func testStreamDataBlocked_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.appendStreamDataBlockedFlow(.outboundFlow(index: 1))
        pendingItems.appendStreamDataBlockedFlow(.outboundFlow(index: 2))

        var transmittedItems = TransmittedItems()
        FrameStreamDataBlocked.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.streamDataBlockedFlows.count, 1)
        XCTAssertEqual(transmittedItems.streamDataBlockedFlows.count, 1)
        XCTAssertEqual(
            pendingItems.streamDataBlocked,
            !pendingItems.streamDataBlockedFlows.isEmpty,
            "PendingItems.streamDataBlocked flag must mirror streamDataBlockedFlows deque emptiness"
        )
    }

}

#endif
