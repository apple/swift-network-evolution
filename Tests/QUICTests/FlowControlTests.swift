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

    // MARK: Credit for inbound bytes the application never reads

    // Builds a connection with a single inbound stream that has already
    // received `byteCount` bytes, sitting unread in the upper receive queue.
    // The stream and connection each advertise `window` bytes of credit.
    private func makeStreamWithUnreadInboundBytes(
        byteCount: Int,
        window: UInt64,
        connection: QUICConnection
    ) -> QUICStreamInstance {
        let logPrefixer = LogPrefixer("[FlowControlTests]")
        let path = QUICPath(parent: connection)
        path.mss = 1200
        connection.currentPath = path
        connection.flowControlState.initializeMaxDataValues(
            remoteMaxData: window,
            localMaxData: window
        )

        var stream = QUICStreamInstance(parent: connection, inbound: true)
        stream.setup(streamID: QUICStreamID(0), logPrefixer: logPrefixer)
        stream.flowControlState.initializeMaxDataValues(
            remoteMaxData: window,
            localMaxData: window
        )
        stream.receiveState.change(logIDString: "FlowControlTests", to: .receive)

        _ = stream.processIncomingStream(
            connection: connection,
            frame: FrameStreamReceived(
                id: 0,
                offset: 0,
                data: [UInt8](repeating: 0x41, count: byteCount),
                isFinal: false
            )
        )

        // Move the bytes out of the reassembly queue and into the upper receive
        // queue, which is what the datapath does before the application reads.
        if let frames = stream.dequeueReassembledData(connection: connection) {
            try? stream.addToUpperReceiveQueue(frames)
        }
        return stream
    }

    // When the application reads the bytes, MAX_DATA advances past them: the
    // credit consumed by those bytes is returned to the peer. This is the
    // baseline that the "dropped" cases below are compared against.
    func testInboundCreditReturnedWhenApplicationReadsBytes() {
        let byteCount = 4000
        let window: UInt64 = 100_000
        let context = NetworkContext(identifier: "test context")
        context.activate()

        let done = XCTestExpectation(description: "read-all accounting complete")
        context.async {
            let connection = QUICConnection(context: context)
            let stream = self.makeStreamWithUnreadInboundBytes(
                byteCount: byteCount,
                window: window,
                connection: connection
            )

            // The application reads every byte.
            stream.deliveredInboundBytes(consumedLength: byteCount, connection: connection)
            stream.upperReceiveQueue.finalizeAllFramesAsFailed()

            XCTAssertEqual(
                connection.flowControlState.totalInOrderInboundBytesRead,
                UInt64(byteCount),
                "Connection should account for all in-order bytes that were read"
            )
            // MAX_DATA is anchored on the bytes delivered to the application, so
            // reading the data must push the advertised limit beyond them.
            XCTAssertGreaterThan(
                connection.flowControlState.inboundMaxData,
                UInt64(byteCount),
                "MAX_DATA should move past bytes the application has consumed"
            )
            connection.currentPath = nil
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
    }

    // The application closes the read side while inbound bytes are still buffered
    // and unread. Those bytes consumed receive window when they arrived, so
    // closing must return their credit; otherwise QUIC never gets it back and the
    // usable window shrinks for the rest of the connection.
    func testInboundCreditReturnedWhenUnreadBytesDroppedOnClose() {
        let byteCount = 4000
        let window: UInt64 = 100_000
        let context = NetworkContext(identifier: "test context")
        context.activate()

        let done = XCTestExpectation(description: "drop accounting complete")
        context.async {
            let connection = QUICConnection(context: context)
            let stream = self.makeStreamWithUnreadInboundBytes(
                byteCount: byteCount,
                window: window,
                connection: connection
            )
            XCTAssertEqual(
                stream.upperReceiveQueue.unclaimedLength,
                byteCount,
                "Bytes should be pending in the upper receive queue, unread"
            )
            let maxDataBeforeClose = connection.flowControlState.inboundMaxData

            // The application closes the read side without reading anything.
            connection.fromExternal {
                connection.handleStopRead(for: stream)
            }
            stream.readClosed = true

            // Closing the read side discards those buffered bytes, so their
            // credit must be returned immediately rather than waiting for the
            // peer's RESET_STREAM: the application is never going to read them.
            XCTAssertEqual(
                connection.flowControlState.totalInOrderInboundBytesRead,
                UInt64(byteCount),
                "Connection must account for inbound bytes dropped without being read"
            )
            XCTAssertEqual(
                stream.upperReceiveQueue.unclaimedLength,
                0,
                "Discarded frames should be released from the upper receive queue"
            )
            // MAX_DATA is anchored on consumed bytes, so it must now advance past
            // the discarded ones, handing the credit back to the peer.
            XCTAssertGreaterThan(
                connection.flowControlState.inboundMaxData,
                maxDataBeforeClose,
                "MAX_DATA must advance so the discarded bytes' credit is returned"
            )
            XCTAssertGreaterThan(
                connection.flowControlState.inboundMaxData,
                UInt64(byteCount),
                "MAX_DATA must move past the bytes that were dropped"
            )
            connection.currentPath = nil
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
    }

    // A stream torn down before its final size is known becomes a zombie. When
    // the final size finally arrives, the bytes that were in flight but never
    // read must be credited at the connection level.
    func testInboundCreditReturnedForZombieStreamFinalSize() {
        let context = NetworkContext(identifier: "test context")
        context.activate()

        let done = XCTestExpectation(description: "zombie accounting complete")
        context.async {
            let connection = QUICConnection(context: context)
            connection.flowControlState.initializeMaxDataValues(
                remoteMaxData: 100_000,
                localMaxData: 100_000
            )
            var zombies = QUICStreamZombieList()
            let streamID: QUICStreamID = QUICStreamID(0)

            // 4000 bytes had arrived when the application tore the stream down
            // unread; the peer later reports the stream really ended at 6000,
            // so 2000 further bytes were in flight and will never be read.
            let lastSize: UInt64 = 4000
            let finalSize: UInt64 = 6000

            connection.fromExternal {
                zombies.append(
                    logIDString: "[FlowControlTests]",
                    streamID: streamID,
                    lastSize: lastSize,
                    localMaxStreamData: 100_000
                )
            }
            XCTAssertNotNil(zombies.find(streamID: streamID))
            XCTAssertEqual(connection.flowControlState.totalInOrderInboundBytesRead, 0)

            connection.fromExternal {
                zombies.finalSizeReceived(
                    logIDString: "[FlowControlTests]",
                    streamID: streamID,
                    finalSize: finalSize,
                    connection: connection
                )
            }

            // The gap between the last size we saw and the final size is the
            // set of bytes that were dropped, and must be credited back.
            XCTAssertEqual(
                connection.flowControlState.totalInOrderInboundBytesRead,
                finalSize - lastSize - 1,
                "Connection must credit the in-flight bytes a zombie stream never delivered"
            )
            XCTAssertNil(
                zombies.find(streamID: streamID),
                "Zombie should be retired once its final size is known"
            )
            connection.currentPath = nil
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
    }
}

#endif
