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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if canImport(Synchronization)
internal import Synchronization
#endif

/// The owner of an `EndpointFlow`.
///
/// A flow is a non-copyable struct, so the stack cannot capture it in the escaping callbacks it
/// used to store. Instead the stack records events as facts and reaches the flow back through its
/// owner, which is a class and can be captured freely.
@available(Network 0.1.0, *)
protocol EndpointFlowParent: AnyObject {
    /// Runs `body` with exclusive access to the owned flow.
    ///
    /// Returns `nil` without running `body` when a flow call is already in progress. That is not
    /// a failure: the events the caller wanted the flow to see are recorded on the flow protocol,
    /// and the call already running drains them on its way out.
    func withFlow<R>(_ body: (inout EndpointFlow) -> R) -> R?

    /// Asks the owned flow to consume the events the stack has recorded for it.
    func drainFlowEvents(in eventContext: inout NetworkContext.EventContext)

    /// Hands the owner a flow the peer opened on a multiplexing connection.
    ///
    /// Called from the drain, so the flow is still held: an implementation that needs to build
    /// another channel has to defer, because doing so borrows this owner's flow.
    func receiveInboundFlow(_ inboundFlow: PendingInboundFlow)
}

@available(Network 0.1.0, *)
extension EndpointFlowParent {
    /// Only a multiplexing connection receives inbound flows; everything else ignores them.
    func receiveInboundFlow(_ inboundFlow: PendingInboundFlow) {}
}

@available(Network 0.1.0, *)
struct EndpointFlow: ~Copyable {

    /// State used to emit logs on the data path.
    public var log = NetworkLoggerState()

    enum State: Equatable, Sendable {
        /// The initial state prior to start.
        case setup
        /// Waiting connections haven't yet been started, or don't have a viable network.
        case waiting(NetworkError)
        /// Preparing connections are actively establishing the connection.
        case preparing
        /// Ready connections can send and receive data.
        case ready
        /// Failed connections are disconnected and can no longer send or receive data.
        case failed(NetworkError)
        /// Cancelled connections have been invalidated by the client and send no more events.
        case cancelled

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.setup, .setup):
                return true
            case (.waiting, .waiting):
                return true
            case (.preparing, .preparing):
                return true
            case (.ready, .ready):
                return true
            case (.failed, .failed):
                return true
            case (.cancelled, .cancelled):
                return true
            default:
                return false
            }
        }
    }
    static internal let globalInstanceCounter = NetworkMutex<UInt64>(1)
    static var nextInstanceCounter: UInt64 {
        var identifier: UInt64 = 0
        globalInstanceCounter.withLock {
            identifier = $0
            $0 += 1
        }
        return identifier
    }

    let localEndpoint: Endpoint
    let remoteEndpoint: Endpoint
    let parameters: Parameters
    let context: NetworkContext
    let identifier: UInt64
    var writeRequests = NetworkUniqueDeque<WriteRequest>()
    var readRequests = NetworkUniqueDeque<ReadRequest>()
    var stateUpdateHandler: ((State) -> Void)? = nil
    var cancelRequested = false
    var teardownComplete = false
    let reuse: Bool
    var _state: State
    var state: State {
        get {
            _state
        }
        set {
            _state = newValue
            privateStorage.handleStateChange(_state)
            if let stateUpdateHandler {
                self.parameters.context.async {
                    stateUpdateHandler(newValue)
                }
            }
        }
    }

    let connectionID: SystemUUID
    #if !NETWORK_NO_SWIFT_QUIC
    var quicConnectionInstance = InstanceIdentifier()
    var quicStreamListenerLinkage: BaseStreamListenerLinkage? = nil

    /// The connection-level flow for QUIC datagrams, when the stack negotiated them.
    ///
    /// `flowProtocol` already holds the stream side, and a QUIC connection can carry both, so the
    /// datagram side is held here rather than displacing it.
    var quicDatagramConnectionFlow: InboundDatagramEndpointFlowProtocol? = nil
    #endif

    var privateStorage = EndpointFlowPrivateStorage()

    /// The hooks that build an application protocol for one stream of a QUIC connection, for a
    /// stack that names a protocol the framework cannot build itself.
    ///
    /// Held in a box because the connection and every flow that joins it share one: setting a hook
    /// is a queue hop, and a stream can be opened before that hop runs, so a stream built in the
    /// meantime still has to see it.
    ///
    /// The two directions are not symmetric. A stream the peer opened already exists, so whoever
    /// owns the protocol attaches it: only the owner holds the instance whose lower linkage has to
    /// be set, and setting it directly is what keeps the stream from being paired a second time. A
    /// stream opened locally does not exist yet, so the owner only builds the instance and the
    /// framework opens the stream and wires both ends.
    final class StreamApplicationProtocols {
        /// Builds the protocol for a stream the peer opened, binds it onto that stream, and
        /// returns the linkage the stream's flow attaches to.
        typealias InboundProvider = (
            _ streamListener: BaseStreamListenerLinkage,
            _ flowInstance: InstanceIdentifier,
            _ context: NetworkContext
        ) throws(NetworkError) -> BaseOutboundStreamLinkage

        /// Builds the protocol for a stream being opened on the connection.
        typealias Factory = (
            _ context: NetworkContext
        ) throws(NetworkError) -> (upper: BaseInboundStreamLinkage, lower: BaseOutboundStreamLinkage)

        var inboundProvider: InboundProvider?
        var factory: Factory?
    }

    /// The application-protocol hooks shared by this connection and its streams.
    let streamApplicationProtocols: StreamApplicationProtocols

    // Owns the protocol instances backing this flow's stack, and hands back the linkages used to
    // wire them together. Each flow keeps its own storage for now; eventually this should be
    // shared at a higher level so instances can outlive an individual flow.
    //
    // A reused flow inherits the storage of the flow it reuses, since it opens another stream on
    // that flow's existing connection rather than building a new stack.
    var storage: BaseNetworkProtocolStorage

    enum FlowProtocol {
        case stream(StreamEndpointFlowProtocol)
        case datagram(DatagramEndpointFlowProtocol)
        case inboundStream(InboundStreamEndpointFlowProtocol)
        case inboundDatagram(InboundDatagramEndpointFlowProtocol)
    }

    var isInboundFlowHandler: Bool {
        switch self.flowProtocol {
        case .inboundStream, .inboundDatagram: return true
        case .stream, .datagram, .none: return false
        }
    }
    var flowProtocol: FlowProtocol? = nil

    /// The lower-layer flow instance this flow adopts instead of opening a new one.
    ///
    /// Set when joining a flow the peer opened: the stack already has an instance for it, so the
    /// flow protocol attaches to that rather than asking the connection for a fresh one.
    let adoptedInboundFlowInstance: InstanceIdentifier?

    init(
        existing flow: borrowing EndpointFlow,
        uuid: SystemUUID,
        adopting adoptedInboundFlowInstance: InstanceIdentifier? = nil
    ) {
        self.adoptedInboundFlowInstance = adoptedInboundFlowInstance
        self.localEndpoint = flow.localEndpoint
        self.remoteEndpoint = flow.remoteEndpoint
        self.parameters = flow.parameters
        self.context = flow.parameters.context
        self._state = .setup
        self.connectionID = uuid
        self.reuse = true
        self.identifier = EndpointFlow.nextInstanceCounter
        self.storage = flow.storage
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicConnectionInstance = flow.quicConnectionInstance
        self.quicStreamListenerLinkage = flow.quicStreamListenerLinkage
        // The connection, not the joining flow, owns the datagram side.
        self.quicDatagramConnectionFlow = nil
        #endif
        // A joining flow builds a stream on this connection, so it uses the connection's hooks.
        self.streamApplicationProtocols = flow.streamApplicationProtocols
        self.privateStorage.initForReuse(flow)
    }

    init(endpoint: Endpoint, parameters: Parameters, uuid: SystemUUID) {
        self.streamApplicationProtocols = StreamApplicationProtocols()
        self.localEndpoint = parameters.localAddress ?? Endpoint(address: IPv4Address.any, port: 0)
        self.remoteEndpoint = endpoint
        self.parameters = parameters
        self.context = parameters.context
        self._state = .setup
        self.connectionID = uuid
        self.identifier = EndpointFlow.nextInstanceCounter
        self.reuse = false
        self.adoptedInboundFlowInstance = nil
        self.storage = BaseNetworkProtocolStorage(context: self.context)
    }

    init(remoteEndpoint: Endpoint, localEndpoint: Endpoint, parameters: Parameters, uuid: SystemUUID) {
        self.streamApplicationProtocols = StreamApplicationProtocols()
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.parameters = parameters
        self.context = parameters.context
        self._state = .setup
        self.connectionID = uuid
        self.identifier = EndpointFlow.nextInstanceCounter
        self.reuse = false
        self.adoptedInboundFlowInstance = nil
        self.storage = BaseNetworkProtocolStorage(context: self.context)
    }

    public var debugDescription: String {
        "C\(self.identifier) [\(self.state)]"
    }

    mutating func start<P: EndpointFlowParent>(_ parent: P) {
        parameters.context.assert()
        if self.state == .setup {
            do throws(NetworkError) {
                try self.startOnQueue(parent)
            } catch {
                self.state = .failed(error)
            }
            // Bringing up the stack can complete the connect synchronously: `invokeConnect` drains
            // the event queue before returning, so the connected event is usually already recorded
            // by the time we get here.
            self.drainPendingEvents(parent)
        }
    }

    // MARK: Pending event draining

    /// Consumes the events the stack has recorded on the active flow protocol.
    ///
    /// This is an external entry point, used when nothing else is holding the event context; see
    /// `drainPendingEvents(in:_:)`.
    mutating func drainPendingEvents<P: EndpointFlowParent>(_ parent: P) {
        guard self.hasPendingEvents else { return }
        fromExternalOnFlow { eventContext, flow in
            flow.drainPendingEvents(in: &eventContext, parent)
        }
    }

    /// Consumes the recorded events using an event context the caller already holds.
    ///
    /// Consuming an event calls back into the stack, which can record further events before
    /// returning, so this loops until the flow protocol has nothing left to report.
    mutating func drainPendingEvents<P: EndpointFlowParent>(
        in eventContext: inout NetworkContext.EventContext,
        _ parent: P
    ) {
        while let events = self.takePendingEvents() {
            // Ordering matches the order the stack used to invoke the equivalent completions in:
            // connect result first, then a wakeup for any outstanding read, then outbound room,
            // then the disconnect itself. `disconnected` is last because it is what moves the flow
            // out of `.ready`, and the earlier steps need to run while it still is.
            if let connectedError = events.connected, self.state == .preparing {
                self.startCompleted(connectedError, in: &eventContext)
            }
            if let additionalDataAvailable = events.inboundDataAvailable, self.state == .ready,
                !self.isInboundFlowHandler
            {
                self.inputAvailable(additionalDataAvailable, in: &eventContext)
            }
            if events.outputRoomAvailable, self.state == .ready, !self.isInboundFlowHandler {
                self.outputAvailable(in: &eventContext)
            }
            for inboundFlow in events.inboundFlows {
                parent.receiveInboundFlow(inboundFlow)
            }
            if let disconnectError = events.disconnected {
                self.handleDisconnected(disconnectError, in: &eventContext)
            }
        }
    }

    private var hasPendingEvents: Bool {
        switch self.flowProtocol {
        case .stream(let flow): return !flow.pending.isEmpty
        case .datagram(let flow): return !flow.pending.isEmpty
        case .inboundStream(let flow): return !flow.pending.isEmpty
        case .inboundDatagram(let flow): return !flow.pending.isEmpty
        case .none: return false
        }
    }

    /// Removes and returns the recorded events, or `nil` when there are none.
    private func takePendingEvents() -> EndpointFlowPendingEvents? {
        func take(_ pending: inout EndpointFlowPendingEvents) -> EndpointFlowPendingEvents? {
            guard !pending.isEmpty else { return nil }
            defer { pending = EndpointFlowPendingEvents() }
            return pending
        }
        switch self.flowProtocol {
        case .stream(let flow): return take(&flow.pending)
        case .datagram(let flow): return take(&flow.pending)
        case .inboundStream(let flow): return take(&flow.pending)
        case .inboundDatagram(let flow): return take(&flow.pending)
        case .none: return nil
        }
    }

    /// Handles the peer disconnecting.
    ///
    /// A graceful `cancel()` defers teardown until the lower layer confirms the disconnect, so
    /// after cancel this finishes that teardown; before cancel it fails the flow.
    private mutating func handleDisconnected(
        _ error: NetworkError,
        in eventContext: inout NetworkContext.EventContext
    ) {
        if self.cancelRequested {
            let description = self.debugDescription
            Logger.connection.debug(
                "EndpointFlow: \(description) disconnected event received, tearing down"
            )
            self.completeTeardown(in: &eventContext)
        } else {
            self.state = .failed(error)
        }
    }

    // The connect result and the inbound/outbound wakeups all arrive through
    // `drainPendingEvents(in:_:)` while the delivering event holds the event context, so each of
    // these takes the context and threads it back into the stack. The context-free `read()` and
    // `write()` wrappers below are for external entry points.
    //
    // Only `startOnQueue` needs the owner, to install the hook the stack calls back through;
    // everything below simply threads the event context.
    internal mutating func startCompleted(
        _ connectedError: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        if let connectedError {
            self.state = .failed(connectedError)
            return
        }
        self.state = .ready
        // A multiplexing connection has no data path of its own; coming up means its flows can
        // now be opened, not that there is anything to send or receive here.
        guard !self.isInboundFlowHandler else { return }
        self.write(in: &eventContext)
        self.read(in: &eventContext)
    }

    private mutating func inputAvailable(
        _ additionalDataAvailable: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.read(in: &eventContext)
    }

    private mutating func outputAvailable(in eventContext: inout NetworkContext.EventContext) {
        self.write(in: &eventContext)
    }

    /// Drains pending write requests. This is an external entry point; see `write(in:)`.
    private mutating func write() {
        precondition(self.state == .ready)
        parameters.context.assert()
        fromExternalOnFlow { eventContext, flow in
            flow.write(in: &eventContext)
        }
    }

    private mutating func write(in eventContext: inout NetworkContext.EventContext) {
        precondition(self.state == .ready)
        do {
            switch self.flowProtocol {
            case .stream(let flow):
                while !writeRequests.isEmpty {
                    if try flow.getOutboundStreamDataRoomAvailable(in: &eventContext) == 0 {
                        // The lower layer will record `outputRoomAvailable` when there is room
                        // again, which brings us back through the drain loop.
                        break
                    }
                    guard let writeRequest = writeRequests.popFirst() else {
                        break
                    }
                    let completion = writeRequest.completion
                    let success = flow.write(writeRequest.frame, in: &eventContext)
                    deliverToApplication(in: &eventContext) {
                        WriteRequest.runCompletion(completion, success: success)
                    }
                }
            case .datagram(let flow):
                while let writeRequest = writeRequests.popFirst() {
                    let completion = writeRequest.completion
                    let success = flow.write(writeRequest.frame, in: &eventContext)
                    deliverToApplication(in: &eventContext) {
                        WriteRequest.runCompletion(completion, success: success)
                    }
                }
            case .inboundStream, .inboundDatagram:
                // A multiplexing connection has no data path of its own; the application sends
                // and receives on its individual flows. Requests never reach here because
                // `addWriteRequestOnContext` fails them up front.
                fatalError("Connection-level flow has no data path")
            case .none:
                fatalError("No current flow")
            }
        } catch {
            Logger.connection.error("Failed to drain write requests: \(error)")
        }
    }

    /// Drains pending read requests. This is an external entry point; see `read(in:)`.
    private mutating func read() {
        precondition(self.state == .ready)
        parameters.context.assert()
        fromExternalOnFlow { eventContext, flow in
            flow.read(in: &eventContext)
        }
    }

    private mutating func read(in eventContext: inout NetworkContext.EventContext) {
        precondition(self.state == .ready)

        switch self.flowProtocol {
        case .stream(let flow):
            while !self.readRequests.isEmpty {
                if self.readRequests[0].expectsSpan {
                    guard
                        var frames = flow.readFrames(
                            minimumBytes: self.readRequests[0].minimumBytes,
                            maximumBytes: self.readRequests[0].maximumBytes,
                            in: &eventContext
                        )
                    else {
                        // The lower layer will record `inboundDataAvailable` when more data
                        // arrives, which brings us back through the drain loop.
                        break
                    }
                    let readRequest = self.readRequests.removeFirst()
                    var offset = 0
                    while var frame = frames.popFirst() {
                        let isLastFrame = frames.isEmpty
                        if let bytes = frame.bytes {
                            readRequest.complete(
                                bytes: bytes,
                                offset: offset,
                                isComplete: frame.metadataComplete,
                                isFinal: true,
                                lastChunkOfBatch: isLastFrame
                            )
                            offset += bytes.byteCount
                        }
                        frame.finalize(success: true)
                    }
                } else {
                    guard
                        let content = flow.read(
                            minimumBytes: self.readRequests[0].minimumBytes,
                            maximumBytes: self.readRequests[0].maximumBytes,
                            in: &eventContext
                        )
                    else {
                        // The lower layer will record `inboundDataAvailable` when more data
                        // arrives, which brings us back through the drain loop.
                        break
                    }
                    let readRequest = self.readRequests.removeFirst()
                    // TODO: Get the actual metadata
                    deliverToApplication(in: &eventContext) {
                        readRequest.complete(content: content, isComplete: false, isFinal: true)
                    }
                }
            }
        case .datagram(let flow):
            while !self.readRequests.isEmpty {
                if self.readRequests[0].expectsSpan {
                    guard
                        var frames = flow.readFrames(
                            maximumFrames: self.readRequests[0].maximumFrames,
                            in: &eventContext
                        )
                    else {
                        // The lower layer will record `inboundDataAvailable` when more data
                        // arrives, which brings us back through the drain loop.
                        break
                    }

                    let readRequest = self.readRequests.removeFirst()
                    var offset = 0
                    while var frame = frames.popFirst() {
                        let isLastFrame = frames.isEmpty
                        if let bytes = frame.bytes {
                            readRequest.complete(
                                bytes: bytes,
                                offset: offset,
                                isComplete: frame.metadataComplete,
                                isFinal: false,
                                lastChunkOfBatch: isLastFrame
                            )
                            offset += bytes.byteCount
                        }
                        frame.finalize(success: true)
                    }
                } else {
                    guard let content = flow.read(in: &eventContext) else {
                        // The lower layer will record `inboundDataAvailable` when more data
                        // arrives, which brings us back through the drain loop.
                        break
                    }

                    let readRequest = self.readRequests.removeFirst()
                    deliverToApplication(in: &eventContext) {
                        readRequest.complete(content: content, isComplete: true, isFinal: false)
                    }
                }
            }
        case .inboundStream, .inboundDatagram:
            // See the note in `write(in:)`: a connection-level flow has no data path.
            fatalError("Connection-level flow has no data path")
        case .none:
            fatalError("No current flow")
        }
    }

    // Runs an application completion after the event context has been released.
    //
    // Application callbacks are the boundary into user code and may call straight back into any
    // public API, which acquires the state itself. Invoking them while a delivering event still
    // holds the state would trip exclusivity, so they are scheduled onto the context queue
    // instead. `EventContext.async` is used rather than `NetworkContext.async` because the latter
    // reads the context's state to reach the scheduler.
    private func deliverToApplication(
        in eventContext: inout NetworkContext.EventContext,
        _ completion: @escaping () -> Void
    ) {
        eventContext.async(completion)
    }

    // Acquires the event context through whichever flow protocol is active, so the state-free
    // entry points above can reach the state-taking implementations.
    private mutating func fromExternalOnFlow(_ body: (inout NetworkContext.EventContext, inout EndpointFlow) -> Void) {
        switch self.flowProtocol {
        case .stream(let flow): flow.fromExternal { eventContext in body(&eventContext, &self) }
        case .datagram(let flow): flow.fromExternal { eventContext in body(&eventContext, &self) }
        case .inboundStream(let flow): flow.fromExternal { eventContext in body(&eventContext, &self) }
        case .inboundDatagram(let flow): flow.fromExternal { eventContext in body(&eventContext, &self) }
        case .none: fatalError("No current flow")
        }
    }

    func async(_ block: @escaping () -> Void) {
        self.parameters.context.async(block)
    }

    mutating func addWriteRequestOnContext<P: EndpointFlowParent>(_ writeRequest: consuming WriteRequest, _ parent: P) {
        var writeRequest: WriteRequest? = writeRequest
        start(parent)
        guard !self.isInboundFlowHandler else {
            // The application sends on a multiplexing connection's individual flows, not on the
            // connection itself. Fail rather than enqueue, so the frame is finalized.
            Logger.connection.error("Cannot send on a multiplexing connection; open a flow first")
            if var takenRequest = writeRequest.take() {
                let completion = takenRequest.completion
                takenRequest.frame.finalize(success: false)
                WriteRequest.runCompletion(completion, success: false)
            }
            return
        }
        if let takenRequest = writeRequest.take() {
            writeRequests.append(takenRequest)
        }
        if state == .ready {
            write()
        }
        self.drainPendingEvents(parent)
    }

    mutating func addReadRequestOnContext<P: EndpointFlowParent>(_ readRequest: consuming ReadRequest, _ parent: P) {
        var readRequest: ReadRequest? = readRequest
        start(parent)
        guard !self.isInboundFlowHandler else {
            // See `addWriteRequestOnContext`: a multiplexing connection has no data path.
            Logger.connection.error("Cannot receive on a multiplexing connection; open a flow first")
            if let takenRequest = readRequest.take() {
                if takenRequest.expectsSpan {
                    takenRequest.complete(
                        bytes: nil,
                        offset: 0,
                        isComplete: false,
                        isFinal: true,
                        lastChunkOfBatch: true,
                        error: .posix(ENOTSUP)
                    )
                } else {
                    takenRequest.complete(content: nil, isComplete: false, isFinal: true, error: .posix(ENOTSUP))
                }
            }
            return
        }
        if let takenRequest = readRequest.take() {
            readRequests.append(takenRequest)
        }
        // If state is ready and this is the first read request, then try to start reading.
        // Otherwise, wait for an `inboundDataAvailable` event to bring us back through the drain.
        if state == .ready && readRequests.count == 1 {
            read()
        }
        self.drainPendingEvents(parent)
    }

    mutating func invokeApplicationEvent<P: EndpointFlowParent>(_ event: ApplicationEvent, _ parent: P) {
        parameters.context.assert()
        switch self.flowProtocol {
        case .stream(let flow):
            flow.invokeApplicationEvent(event)
        case .datagram(let flow):
            flow.invokeApplicationEvent(event)
        case .inboundStream(let flow):
            flow.fromExternal { eventContext in
                flow.invokeApplicationEvent(event, in: &eventContext)
            }
        case .inboundDatagram(let flow):
            flow.fromExternal { eventContext in
                flow.invokeApplicationEvent(event, in: &eventContext)
            }
        case .none:
            break
        }
        self.drainPendingEvents(parent)
    }

    /// Cancel the flow.
    mutating func cancel<P: EndpointFlowParent>(force: Bool = false, error: NetworkError? = nil, _ parent: P) {
        guard !self.cancelRequested || force else {
            return
        }
        self.cancelRequested = true
        let description = self.debugDescription
        Logger.connection.debug("EndpointFlow: \(description) cancel called (force=\(force))")

        // Fail anything still queued; it can no longer complete
        self.failPendingRequests()

        // Stop the current flow. Graceful close of a flow defers teardown until
        // the `disconnected` event arrives.
        let teardownDeferred = self.stopFlow(force: force, error: error)

        // Detach and mark cancelled (now, or from the recorded disconnect event
        // for the deferred graceful path).
        if !teardownDeferred {
            self.completeTeardown()
        }
        self.drainPendingEvents(parent)
    }

    /// Stop the current flow. Returns `true` if teardown has been
    /// deferred to the recorded `disconnected` event (graceful close of a live QUIC
    /// connection), `false` if the caller should tear down immediately.
    /// `error` is only used on the force path.
    private mutating func stopFlow(force: Bool, error: NetworkError?) -> Bool {
        let description = self.debugDescription
        switch self.flowProtocol {
        case .stream(let flow):
            if force {
                flow.abort(error: error)
                return false
            }
            Logger.connection.debug("EndpointFlow: \(description) stopping stream flow protocol")
            if self.shouldDeferTeardown {
                // Wait for the lower layer to confirm `disconnected` before detaching so buffered
                // data drains cleanly. `handleDisconnected` finishes the teardown once the event
                // is recorded; it recognises this path by `cancelRequested`.
                flow.stop()
                return true
            }
            flow.stop()
            return false
        case .datagram(let flow):
            Logger.connection.debug("EndpointFlow: \(description) stopping datagram flow protocol")
            if force {
                flow.abort(error: error)
            } else {
                flow.stop()
            }
            return false
        case .inboundStream(let flow):
            Logger.connection.debug("EndpointFlow: \(description) stopping connection flow protocol")
            if force {
                flow.abort(error: error)
                return false
            }
            if self.shouldDeferTeardown {
                flow.stop()
                return true
            }
            flow.stop()
            return false
        case .inboundDatagram(let flow):
            Logger.connection.debug("EndpointFlow: \(description) stopping connection datagram flow protocol")
            if force {
                flow.abort(error: error)
            } else {
                flow.stop()
            }
            return false
        case .none:
            Logger.connection.debug("EndpointFlow: \(description) no flow protocol to stop")
            return false
        }
    }

    /// Whether graceful teardown should wait for the QUIC `disconnected` event.
    /// Only true when there is still a live QUIC connection to drain and the
    /// lower layer has not already delivered `disconnected`.
    private var shouldDeferTeardown: Bool {
        #if !NETWORK_NO_SWIFT_QUIC
        guard !self.quicConnectionInstance.isNone else { return false }
        if case .failed = self.state { return false }
        return true
        #else
        return false
        #endif
    }

    /// Detaches the flow protocol so its teardown can be completed elsewhere, and fails anything
    /// still queued.
    mutating func detachFlowProtocolForTeardown() -> DetachedFlowProtocols? {
        guard !self.teardownComplete else { return nil }
        self.teardownComplete = true
        self.cancelRequested = true
        self.failPendingRequests()
        var detached = DetachedFlowProtocols(flowProtocol: self.flowProtocol)
        self.flowProtocol = nil
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicConnectionInstance = .init()
        self.quicStreamListenerLinkage = nil
        detached.datagramConnectionFlow = self.quicDatagramConnectionFlow
        self.quicDatagramConnectionFlow = nil
        #endif
        detached.clearWakeFlow()
        self.stateUpdateHandler = nil
        return detached
    }

    /// The protocol instances a flow hands over so its owner can finish tearing them down.
    struct DetachedFlowProtocols {
        var flowProtocol: FlowProtocol?
        #if !NETWORK_NO_SWIFT_QUIC
        var datagramConnectionFlow: InboundDatagramEndpointFlowProtocol?
        #endif

        /// Drops the hook each instance uses to reach the flow's owner.
        func clearWakeFlow() {
            switch flowProtocol {
            case .stream(let flowProtocol): flowProtocol.wakeFlow = nil
            case .datagram(let flowProtocol): flowProtocol.wakeFlow = nil
            case .inboundStream(let flowProtocol): flowProtocol.wakeFlow = nil
            case .inboundDatagram(let flowProtocol): flowProtocol.wakeFlow = nil
            case .none: break
            }
            #if !NETWORK_NO_SWIFT_QUIC
            datagramConnectionFlow?.wakeFlow = nil
            #endif
        }

        /// Tears each instance down, using an event context the caller already holds.
        func teardown(in eventContext: inout NetworkContext.EventContext) {
            switch flowProtocol {
            case .stream(let flowProtocol): flowProtocol.teardown(in: &eventContext)
            case .datagram(let flowProtocol): flowProtocol.teardown(in: &eventContext)
            case .inboundStream(let flowProtocol): flowProtocol.teardown(in: &eventContext)
            case .inboundDatagram(let flowProtocol): flowProtocol.teardown(in: &eventContext)
            case .none: break
            }
            #if !NETWORK_NO_SWIFT_QUIC
            datagramConnectionFlow?.teardown(in: &eventContext)
            #endif
        }

        /// Tears each instance down. This is an external entry point; see `teardown(in:)`.
        func teardown() {
            // Any one of the instances can acquire the event context; they share a context.
            switch flowProtocol {
            case .stream(let flowProtocol):
                flowProtocol.fromExternal { eventContext in self.teardown(in: &eventContext) }
            case .datagram(let flowProtocol):
                flowProtocol.fromExternal { eventContext in self.teardown(in: &eventContext) }
            case .inboundStream(let flowProtocol):
                flowProtocol.fromExternal { eventContext in self.teardown(in: &eventContext) }
            case .inboundDatagram(let flowProtocol):
                flowProtocol.fromExternal { eventContext in self.teardown(in: &eventContext) }
            case .none:
                #if !NETWORK_NO_SWIFT_QUIC
                datagramConnectionFlow?.fromExternal { eventContext in self.teardown(in: &eventContext) }
                #endif
            }
        }
    }

    /// Fail and finalize any pending write and read requests.
    private mutating func failPendingRequests() {
        while var writeRequest = self.writeRequests.popFirst() {
            let completion = writeRequest.completion
            writeRequest.frame.finalize(success: false)
            WriteRequest.runCompletion(completion, success: false)
        }
        while !self.readRequests.isEmpty {
            let readRequest = self.readRequests.removeFirst()
            if readRequest.expectsSpan {
                readRequest.complete(
                    bytes: nil,
                    offset: 0,
                    isComplete: false,
                    isFinal: true,
                    lastChunkOfBatch: true,
                    error: .posix(ECANCELED)
                )
            } else {
                readRequest.complete(content: nil, isComplete: false, isFinal: true, error: .posix(ECANCELED))
            }
        }
    }

    /// Detach the flow, release references, transition to `.cancelled`, and drop the state-update handler.
    /// Completes teardown. This is an external entry point; see `completeTeardown(in:)`.
    private mutating func completeTeardown() {
        guard !self.teardownComplete else { return }
        switch self.flowProtocol {
        case .stream(let flow): flow.fromExternal { eventContext in completeTeardown(in: &eventContext) }
        case .datagram(let flow): flow.fromExternal { eventContext in completeTeardown(in: &eventContext) }
        case .inboundStream(let flow): flow.fromExternal { eventContext in completeTeardown(in: &eventContext) }
        case .inboundDatagram(let flow): flow.fromExternal { eventContext in completeTeardown(in: &eventContext) }
        case .none: finishTeardownBookkeeping()
        }
    }

    private mutating func completeTeardown(in eventContext: inout NetworkContext.EventContext) {
        guard !self.teardownComplete else { return }
        self.teardownComplete = true
        switch self.flowProtocol {
        case .stream(let flow):
            flow.teardown(in: &eventContext)
        case .datagram(let flow):
            flow.teardown(in: &eventContext)
        case .inboundStream(let flow):
            flow.teardown(in: &eventContext)
        case .inboundDatagram(let flow):
            flow.teardown(in: &eventContext)
        case .none:
            break
        }
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicDatagramConnectionFlow?.teardown(in: &eventContext)
        self.quicDatagramConnectionFlow = nil
        #endif
        finishTeardownBookkeeping()
    }

    // Releases the flow's references and moves to `cancelled`. Shared by both `completeTeardown`
    // entry points, and used directly when there is no flow protocol left to tear down.
    private mutating func finishTeardownBookkeeping() {
        self.teardownComplete = true
        self.flowProtocol = nil
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicConnectionInstance = .init()
        self.quicStreamListenerLinkage = nil
        self.quicDatagramConnectionFlow = nil
        #endif
        self.state = .cancelled
        let description = self.debugDescription
        Logger.connection.debug("EndpointFlow: \(description) state set to cancelled")
        var stateUpdateHandler = self.stateUpdateHandler
        self.stateUpdateHandler = nil
        if stateUpdateHandler != nil {
            stateUpdateHandler = nil
        }
    }
}
