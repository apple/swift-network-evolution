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

@available(Network 0.1.0, *)
final class EndpointFlow: CustomDebugStringConvertible {

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
                stateUpdateHandler(_state)
            }
        }
    }

    let connectionID: SystemUUID
    #if !NETWORK_NO_SWIFT_QUIC
    var quicConnectionInstance = InstanceIdentifier()
    var quicStreamListenerLinkage: BaseStreamListenerLinkage? = nil
    #endif

    var privateStorage = EndpointFlowPrivateStorage()

    // Owns the protocol instances backing this flow's stack, and hands back the linkages used to
    // wire them together. Each flow keeps its own storage for now; eventually this should be
    // shared at a higher level so instances can outlive an individual flow.
    //
    // A reused flow inherits the storage of the flow it reuses, since it opens another stream on
    // that flow's existing connection rather than building a new stack.
    lazy var storage = BaseNetworkProtocolStorage(context: self.context)

    enum FlowProtocol {
        case stream(StreamEndpointFlowProtocol)
        case datagram(DatagramEndpointFlowProtocol)
    }
    var flowProtocol: FlowProtocol? = nil

    init(existing flow: EndpointFlow, uuid: SystemUUID) {
        self.localEndpoint = flow.localEndpoint
        self.remoteEndpoint = flow.remoteEndpoint
        self.parameters = flow.parameters
        self.context = flow.parameters.context
        self._state = flow.state
        self.connectionID = uuid
        self.reuse = true
        self.identifier = EndpointFlow.nextInstanceCounter
        self.storage = flow.storage
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicConnectionInstance = flow.quicConnectionInstance
        self.quicStreamListenerLinkage = flow.quicStreamListenerLinkage
        #endif

        self.privateStorage.initForReuse(self)
    }

    init(endpoint: Endpoint, parameters: Parameters, uuid: SystemUUID) {
        self.localEndpoint = parameters.localAddress ?? Endpoint(address: IPv4Address.any, port: 0)
        self.remoteEndpoint = endpoint
        self.parameters = parameters
        self.context = parameters.context
        self._state = .setup
        self.connectionID = uuid
        self.identifier = EndpointFlow.nextInstanceCounter
        self.reuse = false
    }

    init(remoteEndpoint: Endpoint, localEndpoint: Endpoint, parameters: Parameters, uuid: SystemUUID) {
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.parameters = parameters
        self.context = parameters.context
        self._state = .setup
        self.connectionID = uuid
        self.identifier = EndpointFlow.nextInstanceCounter
        self.reuse = false
    }

    public var debugDescription: String {
        "C\(self.identifier) [\(self.state)]"
    }

    func start() {
        self.parameters.context.async {
            self.startIfNeeded()
        }
    }

    private func startIfNeeded() {
        parameters.context.assert()
        if self.state == .setup {
            do throws(NetworkError) {
                try self.startOnQueue()
            } catch {
                self.state = .failed(error)
            }
        }
    }

    // The flow's connected/inbound/outbound completions all run inline while the delivering event
    // holds the event context, so each of these takes the state and threads it back into the
    // stack. The state-free `read()`/`write()` wrappers below are for external entry points.
    internal func startCompleted(_ connectedError: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        if let connectedError {
            self.state = .failed(connectedError)
            return
        }
        self.state = .ready
        self.write(in: &eventContext)
        self.read(in: &eventContext)
    }

    private func inputAvailable(_ additionalDataAvailable: Bool, in eventContext: inout NetworkContext.EventContext) {
        self.read(in: &eventContext)
    }

    private func outputAvailable(in eventContext: inout NetworkContext.EventContext) {
        self.write(in: &eventContext)
    }

    /// Drains pending write requests. This is an external entry point; see `write(in:)`.
    private func write() {
        precondition(self.state == .ready)
        parameters.context.assert()
        fromExternalOnFlow { eventContext in
            self.write(in: &eventContext)
        }
    }

    private func write(in eventContext: inout NetworkContext.EventContext) {
        precondition(self.state == .ready)
        do {
            switch self.flowProtocol {
            case .stream(let flow):
                while !writeRequests.isEmpty {
                    if try flow.getOutboundStreamDataRoomAvailable(in: &eventContext) == 0 {
                        flow.waitForOutputRoomAvailable(self.outputAvailable)
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
            case .none:
                fatalError("No current flow")
            }
        } catch {
            Logger.connection.error("Failed to drain write requests: \(error)")
        }
    }

    /// Drains pending read requests. This is an external entry point; see `read(in:)`.
    private func read() {
        precondition(self.state == .ready)
        parameters.context.assert()
        fromExternalOnFlow { eventContext in
            self.read(in: &eventContext)
        }
    }

    private func read(in eventContext: inout NetworkContext.EventContext) {
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
                        flow.waitForInboundDataAvailable { state, additionalDataAvailable in
                            self.inputAvailable(additionalDataAvailable, in: &state)
                        }
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
                        flow.waitForInboundDataAvailable { state, additionalDataAvailable in
                            self.inputAvailable(additionalDataAvailable, in: &state)
                        }
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
                        flow.waitForInboundDataAvailable { state, additionalDataAvailable in
                            self.inputAvailable(additionalDataAvailable, in: &state)
                        }
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
                        flow.waitForInboundDataAvailable { state, additionalDataAvailable in
                            self.inputAvailable(additionalDataAvailable, in: &state)
                        }
                        break
                    }

                    let readRequest = self.readRequests.removeFirst()
                    deliverToApplication(in: &eventContext) {
                        readRequest.complete(content: content, isComplete: true, isFinal: false)
                    }
                }
            }
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
    private func fromExternalOnFlow(_ body: (inout NetworkContext.EventContext) -> Void) {
        switch self.flowProtocol {
        case .stream(let flow): flow.fromExternal { eventContext in body(&eventContext) }
        case .datagram(let flow): flow.fromExternal { eventContext in body(&eventContext) }
        case .none: fatalError("No current flow")
        }
    }

    func async(_ block: @escaping () -> Void) {
        self.parameters.context.async(block)
    }

    func addWriteRequestOnContext(_ writeRequest: consuming WriteRequest) {
        var writeRequest: WriteRequest? = writeRequest
        startIfNeeded()
        if let takenRequest = writeRequest.take() {
            writeRequests.append(takenRequest)
        }
        if state == .ready {
            write()
        }
    }

    func addReadRequestOnContext(_ readRequest: consuming ReadRequest) {
        var readRequest: ReadRequest? = readRequest
        startIfNeeded()
        if let takenRequest = readRequest.take() {
            readRequests.append(takenRequest)
        }
        // If state is ready and this is the first read request, then try to start reading.
        // Otherwise, wait for inputAvailable to trigger a call to read()
        if state == .ready && readRequests.count == 1 {
            read()
        }
    }

    func invokeApplicationEvent(_ event: ApplicationEvent) {
        parameters.context.assert()
        switch self.flowProtocol {
        case .stream(let flow):
            flow.invokeApplicationEvent(event)
        case .datagram(let flow):
            flow.invokeApplicationEvent(event)
        case .none:
            break
        }
    }

    /// Cancel the flow.
    func cancel(force: Bool = false, error: NetworkError? = nil) {
        self.parameters.context.async {
            guard !self.cancelRequested || force else {
                return
            }
            self.cancelRequested = true
            Logger.connection.debug("EndpointFlow: \(self.debugDescription) cancel called (force=\(force))")

            // Fail anything still queued; it can no longer complete
            self.failPendingRequests()

            // Stop the current flow. Graceful close of a flow defers teardown until
            // the `disconnected` event arrives.
            let teardownDeferred = self.stopFlow(force: force, error: error)

            // Detach and mark cancelled (now, or from the disconnected
            // callback for the deferred graceful path).
            if !teardownDeferred {
                self.completeTeardown()
            }
        }
    }

    /// Stop the current flow. Returns `true` if teardown has been
    /// deferred to the `disconnected` callback (graceful close of a live QUIC
    /// connection), `false` if the caller should tear down immediately.
    /// `error` is only used on the force path.
    private func stopFlow(force: Bool, error: NetworkError?) -> Bool {
        switch self.flowProtocol {
        case .stream(let flow):
            if force {
                flow.abort(error: error)
                return false
            }
            Logger.connection.debug("EndpointFlow: \(self.debugDescription) stopping stream flow protocol")
            if self.shouldDeferTeardown {
                // Wait for the lower layer to confirm `disconnected` before
                // detaching so buffered data drains cleanly.
                flow.waitForDisconnected { [self] state, _ in
                    Logger.connection.debug(
                        "EndpointFlow: \(self.debugDescription) disconnected event received, tearing down"
                    )
                    self.completeTeardown(in: &state)
                }
                flow.stop()
                return true
            }
            flow.stop()
            return false
        case .datagram(let flow):
            Logger.connection.debug("EndpointFlow: \(self.debugDescription) stopping datagram flow protocol")
            if force {
                flow.abort(error: error)
            } else {
                flow.stop()
            }
            return false
        case .none:
            Logger.connection.debug("EndpointFlow: \(self.debugDescription) no flow protocol to stop")
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

    /// Fail and finalize any pending write and read requests.
    private func failPendingRequests() {
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
    private func completeTeardown() {
        guard !self.teardownComplete else { return }
        switch self.flowProtocol {
        case .stream(let flow): flow.fromExternal { eventContext in completeTeardown(in: &eventContext) }
        case .datagram(let flow): flow.fromExternal { eventContext in completeTeardown(in: &eventContext) }
        case .none: finishTeardownBookkeeping()
        }
    }

    private func completeTeardown(in eventContext: inout NetworkContext.EventContext) {
        guard !self.teardownComplete else { return }
        self.teardownComplete = true
        switch self.flowProtocol {
        case .stream(let flow):
            flow.teardown(in: &eventContext)
        case .datagram(let flow):
            flow.teardown(in: &eventContext)
        case .none:
            break
        }
        finishTeardownBookkeeping()
    }

    // Releases the flow's references and moves to `cancelled`. Shared by both `completeTeardown`
    // entry points, and used directly when there is no flow protocol left to tear down.
    private func finishTeardownBookkeeping() {
        self.teardownComplete = true
        self.flowProtocol = nil
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicConnectionInstance = .init()
        self.quicStreamListenerLinkage = nil
        #endif
        self.state = .cancelled
        Logger.connection.debug("EndpointFlow: \(self.debugDescription) state set to cancelled")
        var stateUpdateHandler = self.stateUpdateHandler
        self.stateUpdateHandler = nil
        if stateUpdateHandler != nil {
            stateUpdateHandler = nil
        }
    }
}
