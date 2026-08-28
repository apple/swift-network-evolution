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
    var quicConnectionReference: ProtocolInstanceReference? = nil
    #endif

    var privateStorage = EndpointFlowPrivateStorage()

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

    internal func startCompleted(_ connectedError: NetworkError?) {
        parameters.context.assert()
        if let connectedError {
            self.state = .failed(connectedError)
            return
        }
        self.state = .ready
        self.write()
        self.read()
    }

    private func inputAvailable(_ additionalDataAvailable: Bool) {
        parameters.context.assert()
        self.read()
    }

    private func outputAvailable() {
        parameters.context.assert()
        self.write()
    }

    private func write() {
        precondition(self.state == .ready)
        parameters.context.assert()
        do {
            switch self.flowProtocol {
            case .stream(let flow):
                while !writeRequests.isEmpty {
                    if try flow.getOutboundStreamDataRoomAvailable() == 0 {
                        flow.waitForOutputRoomAvailable(self.outputAvailable)
                        break
                    }
                    guard let writeRequest = writeRequests.popFirst() else {
                        break
                    }
                    let completion = writeRequest.completion
                    let success = flow.write(writeRequest.frame)
                    WriteRequest.runCompletion(completion, success: success)
                }
            case .datagram(let flow):
                while let writeRequest = writeRequests.popFirst() {
                    let completion = writeRequest.completion
                    let success = flow.write(writeRequest.frame)
                    WriteRequest.runCompletion(completion, success: success)
                }
            case .none:
                fatalError("No current flow")
            }
        } catch {
            Logger.connection.error("Failed to drain write requests: \(error)")
        }
    }

    private func read() {
        precondition(self.state == .ready)
        parameters.context.assert()

        switch self.flowProtocol {
        case .stream(let flow):
            while !self.readRequests.isEmpty {
                if self.readRequests[0].expectsSpan {
                    guard
                        var frames = flow.readFrames(
                            minimumBytes: self.readRequests[0].minimumBytes,
                            maximumBytes: self.readRequests[0].maximumBytes
                        )
                    else {
                        flow.waitForInboundDataAvailable(completion: self.inputAvailable)
                        break
                    }
                    let readRequest = self.readRequests.removeFirst()
                    frames.iterateMutableFrames { frame in
                        if let bytes = frame.bytes {
                            readRequest.complete(bytes: bytes, isComplete: frame.metadataComplete, isFinal: true)
                        }
                        frame.finalize(success: true)
                        return .removeFrameAndContinue
                    }
                } else {
                    guard
                        let content = flow.read(
                            minimumBytes: self.readRequests[0].minimumBytes,
                            maximumBytes: self.readRequests[0].maximumBytes
                        )
                    else {
                        flow.waitForInboundDataAvailable(completion: self.inputAvailable)
                        break
                    }
                    // TODO: Get the actual metadata
                    let readRequest = self.readRequests.removeFirst()
                    readRequest.complete(content: content, isComplete: false, isFinal: true)
                }
            }
        case .datagram(let flow):
            while !self.readRequests.isEmpty {
                if self.readRequests[0].expectsSpan {
                    guard var frames = flow.readFrames(maximumFrames: self.readRequests[0].maximumFrames) else {
                        flow.waitForInboundDataAvailable(completion: self.inputAvailable)
                        break
                    }

                    let readRequest = self.readRequests.removeFirst()
                    frames.iterateMutableFrames { frame in
                        if let bytes = frame.bytes {
                            readRequest.complete(bytes: bytes, isComplete: frame.metadataComplete, isFinal: false)
                        }
                        frame.finalize(success: true)
                        return .removeFrameAndContinue
                    }
                } else {
                    guard let content = flow.read() else {
                        flow.waitForInboundDataAvailable(completion: self.inputAvailable)
                        break
                    }

                    let readRequest = self.readRequests.removeFirst()
                    readRequest.complete(content: content, isComplete: true, isFinal: false)
                }
            }
        case .none:
            fatalError("No current flow")
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
                flow.waitForDisconnected { [self] _ in
                    Logger.connection.debug(
                        "EndpointFlow: \(self.debugDescription) disconnected event received, tearing down"
                    )
                    self.completeTeardown()
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
        guard self.quicConnectionReference != nil else { return false }
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
            readRequest.complete(content: nil, isComplete: false, isFinal: true, error: .posix(ECANCELED))
        }
    }

    /// Detach the flow, release references, transition to `.cancelled`, and drop the state-update handler.
    private func completeTeardown() {
        guard !self.teardownComplete else { return }
        self.teardownComplete = true
        switch self.flowProtocol {
        case .stream(let flow):
            flow.teardown()
        case .datagram(let flow):
            flow.teardown()
        case .none:
            break
        }
        self.flowProtocol = nil
        #if !NETWORK_NO_SWIFT_QUIC
        self.quicConnectionReference = nil
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
