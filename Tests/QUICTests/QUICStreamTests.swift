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
let quicStreamTestsLogPrefixer = LogPrefixer("[QUICStreamTests]")

@available(Network 0.1.0, *)
final class QUICStreamTests: XCTestCase {
    var stream: QUICTestStream!
    var connection = QUICConnection(context: NetworkContext.implicitContext)

    override func setUp() {
        stream = QUICTestStream(parent: connection, inbound: false)
        stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: quicStreamTestsLogPrefixer
        )
    }

    override func tearDown() {
        // The stream and the connection were both built outside a protocol stack, so nothing
        // else hands their event states back. The stream's `deinit` is an external entry point
        // that acquires the event context, so release it on the queue too.
        connection.context.onQueue {
            self.stream.destroyFromExternalTest()
            self.stream = nil
            self.connection.destroyFromExternalTest()
        }
    }

    func testProcessIncomingStream() {
        connection.context.onQueue {
            let streamFrame = FrameStreamReceived(id: 0, offset: 0, data: [], isFinal: true)
            let result = connection.fromExternal(streamFrame) { eventContext, frame in
                stream.processIncomingStream(connection: connection, frame: frame, in: &eventContext)
            }
            XCTAssertTrue(result)
        }
    }

    func testProcessIncomingMaxStreamData() {
        self.connection.context.onQueue {
            let newMaxData: UInt64 = 2048
            let maxStreamDataFrame = FrameMaxStreamData(id: 0, max: newMaxData)
            stream.flowControlState.initializeMaxDataValues(remoteMaxData: 1024, localMaxData: 1024)
            XCTAssertTrue(stream.flowControlState.outboundMaxData == 1024)
            connection.fromExternal { eventContext in
                stream.processIncomingMaxStreamData(
                    remoteMaxStreamData: maxStreamDataFrame.max,
                    in: &eventContext
                )
            }
            XCTAssertTrue(stream.flowControlState.outboundMaxData == 2048)
        }
    }
}

@available(Network 0.1.0, *)
final class QUICStreamIDStateTests: XCTestCase {
    var streamsState = QUICTestStreamIDState(.unidirectional)
    var connection = QUICConnection(context: NetworkContext.implicitContext)
    var stream: QUICTestStream!
    var logPrefix = LogPrefixer("[QUICStreamTests]")

    override func setUp() {
        stream = QUICTestStream(parent: connection, inbound: false)
        stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: quicStreamTestsLogPrefixer
        )
    }

    override func tearDown() {
        streamsState.removeAllPending()
        // The stream and the connection were both built outside a protocol stack, so nothing
        // else hands their event states back. The stream's `deinit` is an external entry point
        // that acquires the event context, so release it on the queue too.
        connection.context.onQueue {
            self.stream.destroyFromExternalTest()
            self.stream = nil
            self.connection.destroyFromExternalTest()
        }
    }

    func testPendingStartStreams() {
        XCTAssertEqual(streamsState.pendingStartStreams.count, 0)
        XCTAssertNil(streamsState.pendingStartStreams.first)

        XCTAssertFalse(stream.pendingStart)
        streamsState.addPending(stream)
        XCTAssertTrue(stream.pendingStart)
        XCTAssertEqual(streamsState.pendingStartStreams.count, 1)
        XCTAssertEqual(streamsState.pendingStartStreams.first?.streamID, stream.streamID)

        streamsState.removePending(stream)
        XCTAssertFalse(stream.pendingStart)
        XCTAssertEqual(streamsState.pendingStartStreams.count, 0)
        XCTAssertNil(streamsState.pendingStartStreams.first)
    }
}

@available(Network 0.1.0, *)
final class QUICStreamListTests: XCTestCase {
    var connection = QUICConnection(context: NetworkContext.implicitContext)
    var logPrefix = LogPrefixer("[QUICStreamListTests]")

    override func tearDown() {
        // The connection was built directly rather than attached to a stack, so nothing else
        // hands its event state back.
        connection.context.onQueue { self.connection.destroyFromExternalTest() }
    }

    func testQUICStreamList() {
        self.connection.context.onQueue {
            var unblockedList = QUICStreamList.unblockedSendStreamList()
            var pendingReassemblyDequeueList = QUICStreamList.pendingReassemblyDequeueList()
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            let stream = QUICTestStream(parent: connection, inbound: false)
            defer { stream.destroyFromExternalTest() }
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: quicStreamTestsLogPrefixer
            )
            pendingReassemblyDequeueList.append(stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            unblockedList.append(stream)
            XCTAssertEqual(unblockedList.count, 1)
        }
    }

    func testQUICStreamListPreventDuplicate() {
        self.connection.context.onQueue {
            var pendingReassemblyDequeueList = QUICStreamList.pendingReassemblyDequeueList()
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            let stream = QUICTestStream(parent: connection, inbound: false)
            defer { stream.destroyFromExternalTest() }
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: quicStreamTestsLogPrefixer
            )
            pendingReassemblyDequeueList.append(stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            pendingReassemblyDequeueList.append(stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            pendingReassemblyDequeueList.remove(stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
        }
    }

    func testQUICRemoveFromStreamList() {
        self.connection.context.onQueue {
            var unblockedList = QUICStreamList.unblockedSendStreamList()
            var pendingReassemblyDequeueList = QUICStreamList.pendingReassemblyDequeueList()
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            let stream = QUICTestStream(parent: connection, inbound: false)
            defer { stream.destroyFromExternalTest() }
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: quicStreamTestsLogPrefixer
            )
            pendingReassemblyDequeueList.append(stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            unblockedList.append(stream)
            XCTAssertEqual(unblockedList.count, 1)
            // Removing from pendingReassemblyDequeueList should not remove from sendableList
            pendingReassemblyDequeueList.remove(stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            XCTAssertEqual(unblockedList.count, 1)
            unblockedList.remove(stream)
            XCTAssertEqual(unblockedList.count, 0)
        }
    }
}

#endif
