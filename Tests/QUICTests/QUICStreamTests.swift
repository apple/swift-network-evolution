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

/// Keeps a stream, which cannot be copied, where a test case's `setUp` and test methods can both reach it.
@available(Network 0.1.0, *)
final class QUICStreamHolder {
    var stream: QUICStreamInstance
    init(_ stream: consuming QUICStreamInstance) {
        self.stream = stream
    }
}

@available(Network 0.1.0, *)
let quicStreamTestsLogPrefixer = LogPrefixer("[QUICStreamTests]")

@available(Network 0.1.0, *)
final class QUICStreamTests: XCTestCase {
    var holder: QUICStreamHolder!
    var connection = NetworkContext.implicitContext.onQueue {
        QUICConnection(context: NetworkContext.implicitContext)
    }

    override func setUp() {
        connection.context.onQueue {
            holder = QUICStreamHolder(QUICStreamInstance(parent: connection, inbound: false))
        }
        holder.stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: quicStreamTestsLogPrefixer
        )
    }

    override func tearDown() {
        // The stream and the connection were both built outside a protocol stack, so nothing
        // else hands their event states back. The stream's `deinit` is an external entry point
        // that acquires the event context, so release it on the queue too.
        connection.context.onQueue {
            self.holder.stream.destroyFromExternalTest()
            self.holder = nil
            self.connection.destroyFromExternalTest()
        }
    }

    func testProcessIncomingStream() {
        connection.context.onQueue {
            let streamFrame = FrameStreamReceived(id: 0, offset: 0, data: [], isFinal: true)
            let result = connection.fromExternal(streamFrame) { eventContext, frame in
                holder.stream.processIncomingStream(connection: connection, frame: frame, in: &eventContext)
            }
            XCTAssertTrue(result)
        }
    }

    func testProcessIncomingMaxStreamData() {
        self.connection.context.onQueue {
            let newMaxData: UInt64 = 2048
            let maxStreamDataFrame = FrameMaxStreamData(id: 0, max: newMaxData)
            holder.stream.flowControlState.initializeMaxDataValues(remoteMaxData: 1024, localMaxData: 1024)
            XCTAssertTrue(holder.stream.flowControlState.outboundMaxData == 1024)
            connection.fromExternal { eventContext in
                holder.stream.processIncomingMaxStreamData(
                    remoteMaxStreamData: maxStreamDataFrame.max,
                    in: &eventContext
                )
            }
            XCTAssertTrue(holder.stream.flowControlState.outboundMaxData == 2048)
        }
    }

    // MARK: - Sentinel-backed computed properties (finalSize, inboundApplicationError,
    // outboundApplicationError, streamID)

    func testStreamIDDefaultsToNilBeforeSetup() {
        connection.context.onQueue {
            var freshStream = QUICStreamInstance(parent: self.connection, inbound: false)
            XCTAssertNil(freshStream.streamID)
            freshStream.destroyFromExternalTest()
        }
    }

    func testFinalSizeDefaultsToNil() {
        XCTAssertNil(holder.stream.finalSize)
    }

    func testInboundApplicationErrorDefaultsToNil() {
        XCTAssertNil(holder.stream.inboundApplicationError)
    }

    func testOutboundApplicationErrorDefaultsToNil() {
        XCTAssertNil(holder.stream.outboundApplicationError)
    }

    func testFinalSizeRoundTrip() {
        holder.stream.finalSize = 123_456
        XCTAssertEqual(holder.stream.finalSize, 123_456)
        holder.stream.finalSize = nil
        XCTAssertNil(holder.stream.finalSize)
    }

    func testFinalSizeZeroIsNotConfusedWithNil() {
        holder.stream.finalSize = 0
        XCTAssertNotNil(holder.stream.finalSize)
        XCTAssertEqual(holder.stream.finalSize, 0)
    }

    func testInboundApplicationErrorRoundTrip() {
        holder.stream.inboundApplicationError = 42
        XCTAssertEqual(holder.stream.inboundApplicationError, 42)
        holder.stream.inboundApplicationError = nil
        XCTAssertNil(holder.stream.inboundApplicationError)
    }

    func testInboundApplicationErrorZeroIsNotConfusedWithNil() {
        holder.stream.inboundApplicationError = 0
        XCTAssertNotNil(holder.stream.inboundApplicationError)
        XCTAssertEqual(holder.stream.inboundApplicationError, 0)
    }

    func testOutboundApplicationErrorRoundTrip() {
        holder.stream.outboundApplicationError = 99
        XCTAssertEqual(holder.stream.outboundApplicationError, 99)
        holder.stream.outboundApplicationError = nil
        XCTAssertNil(holder.stream.outboundApplicationError)
    }

    func testOutboundApplicationErrorZeroIsNotConfusedWithNil() {
        holder.stream.outboundApplicationError = 0
        XCTAssertNotNil(holder.stream.outboundApplicationError)
        XCTAssertEqual(holder.stream.outboundApplicationError, 0)
    }

    func testResetStreamIDUpdatesStreamID() {
        let newStreamID = QUICStreamID(UInt32(4))
        holder.stream.resetStreamID(streamID: newStreamID)
        let resetStreamID = holder.stream.streamID
        XCTAssertEqual(resetStreamID, newStreamID)
        XCTAssertEqual(resetStreamID?.value, 4)
    }
    func testApplicationErrorMaxIsReservedAsSentinel() {
        holder.stream.inboundApplicationError = UInt64.max
        XCTAssertNil(holder.stream.inboundApplicationError)
    }
}

@available(Network 0.1.0, *)
final class QUICStreamIDStateTests: XCTestCase {
    var streamsState = QUICStreamIDState(.unidirectional)
    var connection = NetworkContext.implicitContext.onQueue {
        QUICConnection(context: NetworkContext.implicitContext)
    }
    var holder: QUICStreamHolder!
    var logPrefix = LogPrefixer("[QUICStreamTests]")

    override func setUp() {
        connection.context.onQueue {
            holder = QUICStreamHolder(QUICStreamInstance(parent: connection, inbound: false))
        }
        holder.stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: quicStreamTestsLogPrefixer
        )
    }

    override func tearDown() {
        _ = streamsState.removeAllPending()
        // The stream and the connection were both built outside a protocol stack, so nothing
        // else hands their event states back. The stream's `deinit` is an external entry point
        // that acquires the event context, so release it on the queue too.
        connection.context.onQueue {
            self.holder.stream.destroyFromExternalTest()
            self.holder = nil
            self.connection.destroyFromExternalTest()
        }
    }

    func testPendingStartStreams() {
        XCTAssertEqual(streamsState.pendingStartStreams.count, 0)
        XCTAssertNil(streamsState.pendingStartStreams.first)

        let flowID = holder.stream.flowIdentifier
        let pendingBefore = holder.stream.pendingStart
        XCTAssertFalse(pendingBefore)
        streamsState.addPending(&holder.stream)
        let pendingAfterAdd = holder.stream.pendingStart
        XCTAssertTrue(pendingAfterAdd)
        XCTAssertEqual(streamsState.pendingStartStreams.count, 1)
        XCTAssertEqual(streamsState.pendingStartStreams.first, flowID)

        streamsState.removePending(&holder.stream)
        let pendingAfterRemove = holder.stream.pendingStart
        XCTAssertFalse(pendingAfterRemove)
        XCTAssertEqual(streamsState.pendingStartStreams.count, 0)
        XCTAssertNil(streamsState.pendingStartStreams.first)
    }
}

@available(Network 0.1.0, *)
final class QUICStreamListTests: XCTestCase {
    var connection = NetworkContext.implicitContext.onQueue {
        QUICConnection(context: NetworkContext.implicitContext)
    }
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
            var stream = QUICStreamInstance(parent: connection, inbound: false)
            defer { stream.destroyFromExternalTest() }
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: quicStreamTestsLogPrefixer
            )
            pendingReassemblyDequeueList.append(&stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            unblockedList.append(&stream)
            XCTAssertEqual(unblockedList.count, 1)
        }
    }

    func testQUICStreamListPreventDuplicate() {
        self.connection.context.onQueue {
            var pendingReassemblyDequeueList = QUICStreamList.pendingReassemblyDequeueList()
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            var stream = QUICStreamInstance(parent: connection, inbound: false)
            defer { stream.destroyFromExternalTest() }
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: quicStreamTestsLogPrefixer
            )
            pendingReassemblyDequeueList.append(&stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            pendingReassemblyDequeueList.append(&stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            pendingReassemblyDequeueList.remove(&stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
        }
    }

    func testQUICRemoveFromStreamList() {
        self.connection.context.onQueue {
            var unblockedList = QUICStreamList.unblockedSendStreamList()
            var pendingReassemblyDequeueList = QUICStreamList.pendingReassemblyDequeueList()
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            var stream = QUICStreamInstance(parent: connection, inbound: false)
            defer { stream.destroyFromExternalTest() }
            stream.setup(
                streamID: QUICStreamID(0),
                logPrefixer: quicStreamTestsLogPrefixer
            )
            pendingReassemblyDequeueList.append(&stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 1)
            unblockedList.append(&stream)
            XCTAssertEqual(unblockedList.count, 1)
            // Removing from pendingReassemblyDequeueList should not remove from sendableList
            pendingReassemblyDequeueList.remove(&stream)
            XCTAssertEqual(pendingReassemblyDequeueList.count, 0)
            XCTAssertEqual(unblockedList.count, 1)
            unblockedList.remove(&stream)
            XCTAssertEqual(unblockedList.count, 0)
        }
    }
}

#endif
