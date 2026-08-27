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
final class FlowControlTests: XCTestCase {
    func testOutboundFlowControl() {
        let logPrefixer = LogPrefixer("[FlowControlTests]")
        let connection = QUICConnection(
            context: NetworkContext(identifier: "test context")
        )
        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: logPrefixer
        )

        let unsetMaxStreamDataSize = stream.maximumStreamDataSize
        XCTAssertEqual(unsetMaxStreamDataSize, Int.max)

        stream.updateOutboundFlowControlCredit(connection: connection)

        // Initial size is initial MSS * 10
        let initialMaxStreamDataSize = stream.maximumStreamDataSize
        XCTAssertEqual(initialMaxStreamDataSize, 1200 * 10)

        var updated = stream.updateOutboundMaxData(to: 40000)
        XCTAssertTrue(updated)

        updated = connection.updateOutboundMaxData(to: 100000)
        XCTAssertTrue(updated)

        stream.updateFlowControlWithEnqueuedBytesToSend(8000, connection: connection)
        stream.updateFlowControlWithSentBytes(3000, connection: connection)

        stream.updateOutboundFlowControlCredit(connection: connection)

        // Check that pending outbound data is accounted for
        let updatedMaxStreamDataSize = stream.maximumStreamDataSize
        XCTAssertEqual(updatedMaxStreamDataSize, 1200 * 10 - (8000 - 3000))
    }

    func testInboundFlowControl() {
        let logPrefixer = LogPrefixer("[FlowControlTests]")
        let connection = QUICConnection(
            context: NetworkContext(identifier: "test context")
        )
        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: logPrefixer
        )
        let newPath = QUICPath(parent: connection)

        newPath.mss = 1200
        connection.currentPath = newPath

        stream.receiveState.change(logIDString: "FlowControlTests", to: .receive)

        stream.sendInboundFlowControlCreditIfNeeded(connection: connection)
        let initialReceiveSpace: UInt64 = 2 * 1024 * 1024

        var inboundMaxData = stream.flowControlState.inboundMaxData
        var maxUnreadInbound = stream.flowControlState.maximumUnreadInboundBytesAllowed
        XCTAssertEqual(maxUnreadInbound, initialReceiveSpace)

        stream.updateFlowControlWithTotalInOrderInboundBytesRead(1_500_000, connection: connection)
        stream.updateFlowControlWithInboundBytesDelivered(1_500_000, connection: connection)

        stream.sendInboundFlowControlCreditIfNeeded(connection: connection)

        inboundMaxData = stream.flowControlState.inboundMaxData
        maxUnreadInbound = stream.flowControlState.maximumUnreadInboundBytesAllowed
        XCTAssertEqual(inboundMaxData, initialReceiveSpace + 1_500_000)
        XCTAssertEqual(maxUnreadInbound, initialReceiveSpace)

        connection.currentPath = nil
    }

    func testSendPermitReopensAfterDrainWithoutMaxStreamData() {
        let logPrefixer = LogPrefixer("[FlowControlTests]")
        let context = NetworkContext(identifier: "test context")
        context.activate()

        // Run on the context queue: reopening the permit delivers an upper-layer
        // event, which asserts it is running in-context.
        let done = XCTestExpectation(description: "permit reopen check complete")
        context.async {
            let connection = QUICConnection(context: context)
            let stream = QUICStreamInstance(parent: connection, inbound: false)
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: logPrefixer
            )

            // Ample peer credit at both levels, so this is not peer flow control
            _ = stream.updateOutboundMaxData(to: 8_000_000)
            _ = connection.updateOutboundMaxData(to: 8_000_000)

            // One 16 KB buffer exceeds the 10 * MSS (12,000 B) watermark, so the
            // permit latches to 0
            stream.updateFlowControlWithEnqueuedBytesToSend(16_384, connection: connection)
            stream.updateOutboundFlowControlCredit(connection: connection)
            XCTAssertEqual(stream.maximumStreamDataSize, 0)
            XCTAssertEqual(try? stream.getOutboundStreamDataRoomAvailable(), 0)

            // Send the bytes to drain the backlog, with no MAX_STREAM_DATA
            // arriving. Run inside an external cycle so the reopen event has a
            // valid event state, as a real send does.
            stream.fromExternal {
                stream.updateFlowControlWithSentBytes(16_384, connection: connection)
            }

            // Draining reopens the permit without an inbound MAX_STREAM_DATA
            XCTAssertGreaterThan(stream.maximumStreamDataSize, 0)
            XCTAssertGreaterThan((try? stream.getOutboundStreamDataRoomAvailable()) ?? 0, 0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
    }

    func testDuplicateResetStreamOverflow() {
        let logPrefixer = LogPrefixer("[FlowControlTests]")
        let connection = QUICConnection(
            context: NetworkContext(identifier: "test context")
        )
        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: logPrefixer
        )

        // Baseline: both counters start at 0.
        XCTAssertEqual(stream.flowControlState.totalInOrderInboundBytesRead, 0)
        XCTAssertEqual(
            connection.flowControlState.totalInOrderInboundBytesRead,
            0
        )

        let finalSize = UInt64(4_611_686_018_427_387_903)

        // Loop 5 times to add a very large size to the flow control, without
        // updating the stream. The parsing of reset stream guards against this
        // but we also check here to ensure that the connection value doesn't overflow.
        for _ in 1...5 {
            stream.updateFlowControlWithTotalInOrderInboundBytesRead(
                finalSize,
                connection: connection,
                updateStream: false,
                updateConnection: true
            )
        }

        XCTAssertEqual(connection.flowControlState.totalInOrderInboundBytesRead, finalSize * 4)
    }
}

#endif
