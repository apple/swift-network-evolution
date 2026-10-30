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

@available(Network 0.1.0, *)
final class QUICStreamUpperProtocolBorrowingTests: XCTestCase {

    // An upper protocol's callbacks always run after the borrow ends, not during it.
    // Every callback saw both flow tables unborrowed and no flow marked borrowed.
    // The event manager defers delivery to the upper protocol until the connection's call finishes.

    /// What an upper protocol does from inside one of its callbacks.
    enum UpperProtocolActions: CaseIterable, CustomStringConvertible {
        case write
        case read
        case askForRoom
        case markIdle
        case stop
        case detach

        var description: String {
            switch self {
            case .write: "write"
            case .read: "read"
            case .askForRoom: "askForRoom"
            case .markIdle: "markIdle"
            case .stop: "stop"
            case .detach: "detach"
            }
        }

        func run(
            on harness: StreamUpperHarness<TestStreamLinkageFamily>,
            in eventContext: inout NetworkContext.EventContext
        ) {
            switch self {
            case .write:
                _ = harness.write([1, 2, 3], in: &eventContext)
            case .read:
                _ = harness.readAndDrop(in: &eventContext)
            case .askForRoom:
                _ = try? harness.invokeGetOutboundStreamDataRoomAvailable(in: &eventContext)
            case .markIdle:
                harness.invokeApplicationEvent(.connectionIdle, in: &eventContext)
            case .stop:
                harness.stop(error: nil, in: &eventContext)
            case .detach:
                harness.teardown(in: &eventContext)
            }
        }
    }

    /// Builds the connection with its pending stream and its upper harness for every way an upper
    /// protocol can call back in, and hands each to `body` with the stream's identifier. A new stack is
    /// built for each one, because `stop` and `detach` take the stream away.
    private func forEachUpperAction(
        _ body: (UpperProtocolActions, AsynchronousHandshakeStack, MultiplexedFlowIdentifier) -> Void
    ) {
        for action in UpperProtocolActions.allCases {
            guard let stack = makeAsynchronousHandshakeStack() else { return }
            defer { destroy(stack) }
            let connection = stack.connection
            connection.context.onQueue {
                guard let flowID = connection.someFlowIdentifier else {
                    return XCTFail("The stack has no stream (\(action))")
                }
                body(action, stack, flowID)
                // However the callback went, nothing is left borrowed or held back
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed, "\(action)")
                XCTAssertFalse(connection.stateMachine.isSendActive, "\(action)")
            }
        }
    }

    private func frames(_ bytes: [UInt8]) -> FrameArray {
        var frame = Frame(count: bytes.count)
        _ = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.span(bytes.span.bytes)
        }
        return FrameArray(frame: frame)
    }

    /// What the upper protocol's callback does when it runs: checks that the stream is no longer
    /// borrowed, which is what lets it call back in, and then calls back in.
    private func upperCallback(
        _ action: UpperProtocolActions,
        _ stack: AsynchronousHandshakeStack,
        _ eventContext: inout NetworkContext.EventContext
    ) {
        let stateMachine = stack.connection.stateMachine
        XCTAssertFalse(stateMachine.isFlowBorrowed, "Called while a flow was borrowed (\(action))")
        #if DEBUG
        XCTAssertFalse(stateMachine.isBorrowed(.streams), "Called while the stream table was borrowed (\(action))")
        XCTAssertFalse(stateMachine.isBorrowed(.secondary), "Called while the datagram table was borrowed (\(action))")
        #endif
        action.run(on: stack.harness, in: &eventContext)
    }

    // Inbound data reaches the upper protocol after the stream was borrowed to receive it.
    func testUpperProtocolCanCallBackFromInboundDataAvailable() {
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.inboundDataAvailable = { eventContext, _ in
                called = true
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                try? stack.connection.deliverInboundStreamData(
                    flow: flowID,
                    streamData: frames([1, 2, 3, 4]),
                    in: &eventContext
                )
            }
            XCTAssertTrue(called, "inboundDataAvailable never reached the upper protocol (\(action))")
        }
    }

    // Room to write again is announced to the upper protocol from the connection's send path, for the
    // streams that reopened it, each of which is looked up in the table.
    func testUpperProtocolCanCallBackFromOutboundRoomAvailable() {
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.outboundRoomAvailable = { eventContext in
                called = true
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                // What reopening a stream's room does, then what the next send does with the queue
                _ = stack.connection.performOnStream(flowID, in: &eventContext) {
                    (stream: inout QUICStreamInstance, _: inout NetworkContext.EventContext) in
                    stack.connection.queueOutboundRoomAvailableEvent(for: stream)
                }
                stack.connection.deliverQueuedOutboundRoomAvailableEvents(in: &eventContext)
            }
            XCTAssertTrue(called, "outboundRoomAvailable never reached the upper protocol (\(action))")
        }
    }

    // A RESET_STREAM from the peer aborts the inbound side. The frame is processed with the stream borrowed.
    func testUpperProtocolCanCallBackFromInboundAborted() {
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.inboundAborted = { eventContext, _ in
                called = true
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                _ = stack.connection.performOnStream(flowID, in: &eventContext) {
                    (stream: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    stream.deliverInboundAbortedEvent(error: .posix(ECONNRESET), in: &ctx)
                }
            }
            XCTAssertTrue(called, "inboundAborted never reached the upper protocol (\(action))")
        }
    }

    // A STOP_SENDING from the peer aborts the outbound side, again with the stream borrowed.
    func testUpperProtocolCanCallBackFromOutboundAborted() {
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.outboundAborted = { eventContext, _ in
                called = true
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                _ = stack.connection.performOnStream(flowID, in: &eventContext) {
                    (stream: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    stream.deliverOutboundAbortedEvent(error: .posix(ECONNRESET), in: &ctx)
                }
            }
            XCTAssertTrue(called, "outboundAborted never reached the upper protocol (\(action))")
        }
    }

    // Closing the stream reports it disconnected, which the connection does while the stream is borrowed
    // to close it. The harness hands a disconnect to the `connected` completion as `false`.
    func testUpperProtocolCanCallBackFromDisconnected() {
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.connected = { eventContext, connected in
                called = true
                XCTAssertFalse(connected)
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                _ = stack.connection.performOnStream(flowID, in: &eventContext) {
                    (stream: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    stream.deliverDisconnectedEvent(error: nil, in: &ctx)
                }
            }
            XCTAssertTrue(called, "disconnected never reached the upper protocol (\(action))")
        }
    }

    // The connection reports every flow disconnected when it closes, by walking the whole flow table.
    func testUpperProtocolCanCallBackFromDisconnectedForAllFlows() {
        forEachUpperAction { action, stack, _ in
            var called = false
            stack.harness.completions.connected = { eventContext, connected in
                called = true
                XCTAssertFalse(connected)
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                stack.connection.deliverDisconnectedEvent(flow: .allFlows, error: nil, in: &eventContext)
            }
            XCTAssertTrue(called, "disconnected never reached the upper protocol (\(action))")
        }
    }

    // Reporting one flow connected looks the flow up in the table and delivers to its upper from there.
    func testUpperProtocolCanCallBackFromConnectedForOneFlow() {
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.connected = { eventContext, connected in
                called = true
                XCTAssertTrue(connected)
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                stack.connection.deliverConnectedEvent(flow: flowID, in: &eventContext)
            }
            XCTAssertTrue(called, "connected never reached the upper protocol (\(action))")
        }
    }

    // `connectFlow` ends by handing the flow whatever was queued for it, which it does with the flow looked up
    // in the table. An upper that calls back in from the connect it asked for must still be safe.
    func testUpperProtocolCanCallBackFromConnectFlow() {
        forEachUpperAction { action, stack, flowID in
            stack.harness.completions.connected = { eventContext, _ in
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                stack.connection.connectFlow(flowID, for: stack.harness.identifier, in: &eventContext)
            }
        }
    }

    // Unblocking a stream's sending tells its upper there is room to write again, from the table lookup of
    // that stream. It is public API that nothing in the stack calls itself, so this drives it directly.
    func testUpperProtocolCanCallBackFromUnblockSending() {
        // Through the stream protocol, so the call is not ambiguous with the datagram flow overload
        func unblock<Handler: ManyToManyApplicationStreamProtocol>(
            _ handler: Handler,
            _ flowID: MultiplexedFlowIdentifier,
            _ eventContext: inout NetworkContext.EventContext
        ) where Handler.Flow: AutomaticUpperStreamProcessing {
            handler.blockSending(flow: flowID)
            handler.unblockSending(flow: flowID, in: &eventContext)
        }
        forEachUpperAction { action, stack, flowID in
            var called = false
            stack.harness.completions.outboundRoomAvailable = { eventContext in
                called = true
                self.upperCallback(action, stack, &eventContext)
            }
            stack.connection.fromExternal { eventContext in
                unblock(stack.connection, flowID, &eventContext)
            }
            XCTAssertTrue(called, "outboundRoomAvailable never reached the upper protocol (\(action))")
        }
    }

    // Completing the handshake readies the streams that were opened early. The connection reports each
    // one connected while it holds that stream.
    func testUpperProtocolCanCallBackFromConnected() {
        // Detaching is left out. This turn runs on the TLS instance's own event state, and detaching the last
        // upper protocol tears the connection down, which calls into TLS while it is in the middle of that
        // turn. That is about the handshake's event states, not the borrowed flow tables.
        for action in UpperProtocolActions.allCases where action != .detach {
            guard let stack = makeAsynchronousHandshakeStack() else { return }
            defer { destroy(stack) }
            var called = false
            stack.connection.context.onQueue {
                stack.harness.completions.connected = { eventContext, _ in
                    called = true
                    self.upperCallback(action, stack, &eventContext)
                }
            }
            onAsynchronousHandshakeTurn(stack.connection) { crypto, eventContext in
                crypto.handleConnectedEvent(in: &eventContext)
            }
            XCTAssertTrue(called, "connected never reached the upper protocol (\(action))")
            stack.connection.context.onQueue {
                XCTAssertFalse(stack.connection.stateMachine.isFlowBorrowed, "\(action)")
                XCTAssertFalse(stack.connection.stateMachine.isSendActive, "\(action)")
            }
        }
    }
}

#endif
