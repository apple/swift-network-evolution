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

@available(Network 0.1.0, *)
final class QUICStreamIDTests: XCTestCase {
    func testMinMaxValues() {
        XCTAssertNotNil(QUICStreamID(0))
        XCTAssertNotNil(QUICStreamID(QUICStreamID.maxValid))
        XCTAssertTrue(QUICStreamID.maxLocal < QUICStreamID.maxValid)
        XCTAssertNil(QUICStreamID(QUICStreamID.maxValid + 1))
        XCTAssertNil(QUICStreamID(UInt64.max))
    }

    func testInitiator() {
        let clientInitiatedStreamID: QUICStreamID = QUICStreamID(0)
        XCTAssertTrue(clientInitiatedStreamID.isClientInitiated)
        XCTAssertFalse(clientInitiatedStreamID.isServerInitiated)
        let serverInitiatedStreamID: QUICStreamID = QUICStreamID(1)
        XCTAssertTrue(serverInitiatedStreamID.isServerInitiated)
        XCTAssertFalse(serverInitiatedStreamID.isClientInitiated)
    }

    func testType() {
        let unidirectionalStreamID: QUICStreamID = QUICStreamID(2)
        XCTAssertTrue(unidirectionalStreamID.isUnidirectional)
        XCTAssertFalse(unidirectionalStreamID.isBidirectional)
        let bidirectionalStreamID: QUICStreamID = QUICStreamID(0)
        XCTAssertTrue(bidirectionalStreamID.isBidirectional)
        XCTAssertFalse(bidirectionalStreamID.isUnidirectional)

        XCTAssertEqual(unidirectionalStreamID.quicStreamType, QUICStreamType.unidirectional)
        XCTAssertEqual(bidirectionalStreamID.quicStreamType, QUICStreamType.bidirectional)
    }

    func testStreamIDFromValue() {
        let serverInitiatedStreamID = QUICStreamID(
            2,
            serverInitiated: true,
            isUnidirectional: false
        )!
        XCTAssertTrue(serverInitiatedStreamID.isServerInitiated)
        // The type bit should have been zeroed out!
        XCTAssertTrue(serverInitiatedStreamID.isBidirectional)
        let clientInitiatedStreamID = QUICStreamID(
            2,
            serverInitiated: false,
            isUnidirectional: false
        )!
        XCTAssertTrue(clientInitiatedStreamID.isClientInitiated)
        // The type bit should have been zeroed out!
        XCTAssertTrue(clientInitiatedStreamID.isBidirectional)
    }

    func testMaxStreamID() {
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 1),
            QUICStreamID(0)
        )

        // XX test Int truncation!

        // TODO: continue implementing these tests

        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 1),
            QUICStreamID(0)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 2),
            QUICStreamID(4)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 3),
            QUICStreamID(8)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 4),
            QUICStreamID(12)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: false, streams: 5),
            QUICStreamID(16)
        )

        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: false, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: false, streams: 1),
            QUICStreamID(2)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: false, streams: 2),
            QUICStreamID(6)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: false, streams: 3),
            QUICStreamID(10)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: false, streams: 4),
            QUICStreamID(14)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: false, streams: 5),
            QUICStreamID(18)
        )

        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: true, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: true, streams: 1),
            QUICStreamID(1)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: true, streams: 2),
            QUICStreamID(5)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: true, streams: 3),
            QUICStreamID(9)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: true, streams: 4),
            QUICStreamID(13)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDBidirectional(server: true, streams: 5),
            QUICStreamID(17)
        )

        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: true, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: true, streams: 1),
            QUICStreamID(3)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: true, streams: 2),
            QUICStreamID(7)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: true, streams: 3),
            QUICStreamID(11)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: true, streams: 4),
            QUICStreamID(15)
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamIDUnidirectional(server: true, streams: 5),
            QUICStreamID(19)
        )

        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: true, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: true, streams: 1),
            QUICStreamID(0)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: true, streams: 2),
            QUICStreamID(4)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: true, streams: 3),
            QUICStreamID(8)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: true, streams: 4),
            QUICStreamID(12)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: true, streams: 5),
            QUICStreamID(16)
        )

        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: true, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: true, streams: 1),
            QUICStreamID(2)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: true, streams: 2),
            QUICStreamID(6)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: true, streams: 3),
            QUICStreamID(10)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: true, streams: 4),
            QUICStreamID(14)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: true, streams: 5),
            QUICStreamID(18)
        )

        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: false, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: false, streams: 1),
            QUICStreamID(1)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: false, streams: 2),
            QUICStreamID(5)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: false, streams: 3),
            QUICStreamID(9)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: false, streams: 4),
            QUICStreamID(13)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDBidirectional(server: false, streams: 5),
            QUICStreamID(17)
        )

        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: false, streams: 0),
            nil
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: false, streams: 1),
            QUICStreamID(3)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: false, streams: 2),
            QUICStreamID(7)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: false, streams: 3),
            QUICStreamID(11)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: false, streams: 4),
            QUICStreamID(15)
        )
        XCTAssertEqual(
            QUICStreamID.computeLocalMaxStreamIDUnidirectional(server: false, streams: 5),
            QUICStreamID(19)
        )
    }

    func testComputeRemoteMaxStreamData() {
        let mockTransportParameters = createMockTransportParameters()
        // As client with nil transport parameters
        let clientBidirectionalStreamID: QUICStreamID = QUICStreamID(0)
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: false,
                remoteTransportParameters: nil,
                streamID: QUICStreamID(0)  // client initiated bidirectional
            ),
            0
        )
        // Test as client / server with real streamIDs and transport parameters
        let clientUnidirectionalStreamID: QUICStreamID = QUICStreamID(2)  // Client initiated unidirectional
        let serverUnidirectionalStreamID: QUICStreamID = QUICStreamID(3)  // Server initiated unidirectional
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: false,
                remoteTransportParameters: mockTransportParameters,
                streamID: clientUnidirectionalStreamID
            ),
            1000
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: true,
                remoteTransportParameters: mockTransportParameters,
                streamID: serverUnidirectionalStreamID
            ),
            1000
        )
        // Test bidirectional streams as client
        let serverBidirectionalStreamID: QUICStreamID = QUICStreamID(1)  // Server-initiated bidirectional
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: false,
                remoteTransportParameters: mockTransportParameters,
                streamID: serverBidirectionalStreamID
            ),
            2000
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: false,
                remoteTransportParameters: mockTransportParameters,
                streamID: clientBidirectionalStreamID
            ),
            3000
        )
        // Test bidirectional streams as server
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: true,
                remoteTransportParameters: mockTransportParameters,
                streamID: serverBidirectionalStreamID
            ),
            3000
        )
        XCTAssertEqual(
            QUICStreamID.computeRemoteMaxStreamData(
                isServer: true,
                remoteTransportParameters: mockTransportParameters,
                streamID: clientBidirectionalStreamID
            ),
            2000
        )
    }
    private func createMockTransportParameters() -> TransportParameters {
        var params = TransportParameters(logPrefixer: LogPrefixer())
        // Use a value distinct from the per-stream uni data window below, so a
        // regression that reads the uni stream COUNT (0x09) instead of the per-stream
        // DATA limit (0x07) returns 17 and fails the assertions.
        let initialMaxStreamsUnidirectional = TransportParameter.initialMaxStreamsUnidirectional(
            value: 17
        )
        params.append(initialMaxStreamsUnidirectional)
        let initialMaxStreamDataUnidirectional =
            TransportParameter.initialMaxStreamDataUnidirectional(value: 1000)
        params.append(initialMaxStreamDataUnidirectional)
        let initialMaxStreamDataBidirectionalLocal =
            TransportParameter.initialMaxStreamDataBidirectionalLocal(value: 2000)
        params.append(initialMaxStreamDataBidirectionalLocal)
        let initialMaxStreamDataBidirectionalRemote =
            TransportParameter.initialMaxStreamDataBidirectionalRemote(value: 3000)
        params.append(initialMaxStreamDataBidirectionalRemote)
        return params
    }

    func testQUICStreamIDPendingBidirectionalStreams() {
        var streamsState = QUICTestStreamIDState(.bidirectional)
        let connection = QUICConnection(context: NetworkContext.implicitContext)
        defer { connection.context.onQueue { connection.destroyFromExternalTest() } }
        let logPrefixer = LogPrefixer("[testQUICStreamIDPendingStreams]")
        connection.context.onQueue {

            // Create 3 inbound pending streams
            let stream1 = QUICTestStream(parent: connection, inbound: true)
            defer { stream1.destroyFromExternalTest() }
            stream1.setup(streamID: nil, logPrefixer: logPrefixer)
            let stream2 = QUICTestStream(parent: connection, inbound: true)
            defer { stream2.destroyFromExternalTest() }
            stream2.setup(streamID: nil, logPrefixer: logPrefixer)
            let stream3 = QUICTestStream(parent: connection, inbound: true)
            defer { stream3.destroyFromExternalTest() }
            stream3.setup(streamID: nil, logPrefixer: logPrefixer)

            streamsState.addPending(stream1)
            streamsState.addPending(stream2)
            streamsState.addPending(stream3)
            XCTAssertEqual(streamsState.pendingStartStreams.count, 3)

            XCTAssertTrue(stream1.flowIdentifier != MultiplexedFlowIdentifier.allFlows)
            XCTAssertTrue(stream2.flowIdentifier != MultiplexedFlowIdentifier.allFlows)
            XCTAssertTrue(stream3.flowIdentifier != MultiplexedFlowIdentifier.allFlows)

            // Remove the last added pending stream
            streamsState.removePending(stream3)

            // stream3 should not be in the pending list
            XCTAssertFalse(
                streamsState.pendingStartStreams.contains(where: { $0 === stream3 }),
                "stream3 should not be in the pending list after removal"
            )
            // stream1 still should be in the pending list
            XCTAssertTrue(
                streamsState.pendingStartStreams.contains(where: { $0 === stream1 }),
                "stream1 should still be in the pending list"
            )
            // stream2 still should be in the pending list
            XCTAssertTrue(stream2.pendingStart, "stream2 should still be pending")
            streamsState.removeAllPending()
        }
    }
}

#endif
