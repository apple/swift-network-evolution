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
        var streamsState = QUICStreamIDState(.bidirectional)
        let connection = NetworkContext.implicitContext.onQueue {
            QUICConnection(context: NetworkContext.implicitContext)
        }
        defer { connection.context.onQueue { connection.destroyFromExternalTest() } }
        let logPrefixer = LogPrefixer("[testQUICStreamIDPendingStreams]")
        connection.context.onQueue {

            // Create 3 inbound pending streams
            var stream1 = QUICStreamInstance(parent: connection, inbound: true)
            defer { stream1.destroyFromExternalTest() }
            stream1.setup(streamID: nil, logPrefixer: logPrefixer)
            var stream2 = QUICStreamInstance(parent: connection, inbound: true)
            defer { stream2.destroyFromExternalTest() }
            stream2.setup(streamID: nil, logPrefixer: logPrefixer)
            var stream3 = QUICStreamInstance(parent: connection, inbound: true)
            defer { stream3.destroyFromExternalTest() }
            stream3.setup(streamID: nil, logPrefixer: logPrefixer)

            streamsState.addPending(&stream1)
            streamsState.addPending(&stream2)
            streamsState.addPending(&stream3)
            XCTAssertEqual(streamsState.pendingStartStreams.count, 3)

            XCTAssertTrue(stream1.flowIdentifier != MultiplexedFlowIdentifier.allFlows)
            XCTAssertTrue(stream2.flowIdentifier != MultiplexedFlowIdentifier.allFlows)
            XCTAssertTrue(stream3.flowIdentifier != MultiplexedFlowIdentifier.allFlows)

            // Remove the last added pending stream
            streamsState.removePending(&stream3)

            // stream3 should not be in the pending list
            XCTAssertFalse(
                streamsState.pendingStartStreams.contains(stream3.flowIdentifier),
                "stream3 should not be in the pending list after removal"
            )
            // stream1 still should be in the pending list
            XCTAssertTrue(
                streamsState.pendingStartStreams.contains(stream1.flowIdentifier),
                "stream1 should still be in the pending list"
            )
            // stream2 still should be in the pending list
            XCTAssertTrue(stream2.pendingStart, "stream2 should still be pending")
            _ = streamsState.removeAllPending()
        }
    }

    /// The first stream ID of each kind the peer opens, for either role we play.
    private static let peerFirstStreamIDs: [(description: String, streamType: QUICStreamType, firstStreamID: UInt64)] =
        [
            ("server, client bidirectional", .bidirectional, 0),
            ("client, server bidirectional", .bidirectional, 1),
            ("server, client unidirectional", .unidirectional, 2),
            ("client, server unidirectional", .unidirectional, 3),
        ]

    /// A peer allowed N streams may open exactly its first N streams of the type, whichever
    /// role it plays. Comparing against a stream ID numbered by our own role instead let a
    /// client's peer open only N - 1.
    func testNewStreamIDsAreBlockedAtTheAdvertisedLimit() {
        for (description, streamType, firstStreamID) in Self.peerFirstStreamIDs {
            for maxStreams in [1, 2, 3, 50] {
                var state = QUICStreamIDState(streamType)
                state.updateLocalMaxStreams(newMaxStreams: maxStreams, logIDString: "")
                let lastAllowed = QUICStreamID(UInt64(maxStreams - 1) << 2 + firstStreamID)!
                let firstBlocked = QUICStreamID(UInt64(maxStreams) << 2 + firstStreamID)!
                XCTAssertFalse(
                    state.newStreamIDsAreBlocked(QUICStreamID(firstStreamID)!),
                    "\(description), limit \(maxStreams): first stream"
                )
                XCTAssertFalse(
                    state.newStreamIDsAreBlocked(lastAllowed),
                    "\(description), limit \(maxStreams): stream \(lastAllowed) is the last allowed"
                )
                XCTAssertTrue(
                    state.newStreamIDsAreBlocked(firstBlocked),
                    "\(description), limit \(maxStreams): stream \(firstBlocked) is over the limit"
                )
                // Within `window` of being blocked means fewer than `window` streams are left.
                let window = maxStreams / 2
                if window > 0 {
                    let lastOutsideWindow = QUICStreamID(UInt64(maxStreams - window - 1) << 2 + firstStreamID)!
                    let firstInsideWindow = QUICStreamID(UInt64(maxStreams - window) << 2 + firstStreamID)!
                    XCTAssertFalse(state.newStreamIDsAreBlocked(lastOutsideWindow, window: window), description)
                    XCTAssertTrue(state.newStreamIDsAreBlocked(firstInsideWindow, window: window), description)
                }
            }

            var state = QUICStreamIDState(streamType)
            state.updateLocalMaxStreams(newMaxStreams: 0, logIDString: "")
            XCTAssertTrue(
                state.newStreamIDsAreBlocked(QUICStreamID(firstStreamID)!),
                "\(description): a limit of zero blocks every stream"
            )
        }
    }

    /// The peer opens every stream the limit allows, then closes some, over and over. After each
    /// close the advertised limit must never let it hold more than the concurrency cap open, and
    /// must keep rising so the peer is not starved. Adding the room left under the cap to the old
    /// limit instead of to the streams opened so far lets the peer go over the cap by the second
    /// close.
    func testLocalMaxStreamsToAdvertiseBoundsConcurrency() {
        for (description, streamType, firstStreamID) in Self.peerFirstStreamIDs {
            for maximumConcurrentStreams in [1, 2, 5, 8, 100] {
                let context = "\(description), cap \(maximumConcurrentStreams)"
                var state = QUICStreamIDState(streamType)
                state.nextInboundStreamID = QUICStreamID(firstStreamID)
                state.updateLocalMaxStreams(newMaxStreams: maximumConcurrentStreams, logIDString: "")

                var openedStreams = 0
                for round in 0..<200 {
                    // Open everything the limit allows, as stream frames for the highest allowed
                    // ID would.
                    while openedStreams < state.localMaxStreams {
                        openedStreams += 1
                        state.incrementActiveStreams()
                    }
                    state.nextInboundStreamID = QUICStreamID(UInt64(openedStreams) << 2 + firstStreamID)
                    XCTAssertLessThanOrEqual(
                        state.activeStreamsRemaining(),
                        maximumConcurrentStreams,
                        "\(context), round \(round)"
                    )

                    // Close one or two streams, letting the limit move after each.
                    for _ in 0..<min(1 + round % 2, state.activeStreamsRemaining()) {
                        state.decrementActiveStreams()
                        if let newMaxStreams = state.localMaxStreamsToAdvertise(
                            maximumConcurrentStreams: maximumConcurrentStreams
                        ) {
                            XCTAssertGreaterThan(newMaxStreams, state.localMaxStreams)
                            state.updateLocalMaxStreams(newMaxStreams: newMaxStreams, logIDString: "")
                        }
                        XCTAssertLessThanOrEqual(
                            state.activeStreamsRemaining() + state.localMaxStreams - openedStreams,
                            maximumConcurrentStreams,
                            "\(context), round \(round): limit \(state.localMaxStreams) lets the peer go over the cap"
                        )
                    }
                }
                XCTAssertGreaterThanOrEqual(openedStreams, 200, "\(context): the peer was starved of stream credit")
            }
        }
    }
}

#endif
