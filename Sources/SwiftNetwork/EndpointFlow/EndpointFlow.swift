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
final class EndpointFlow: CustomDebugStringConvertible, @unchecked Sendable {

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
    var readRequests = [ReadRequest]()
    var stateUpdateHandler: ((State) -> Void)? = nil
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
            while true {
                if let readRequest = self.readRequests.first {
                    if let content = flow.read(
                        minimumBytes: readRequest.minimumBytes,
                        maximumBytes: readRequest.maximumBytes
                    ) {
                        // TODO: Get the actual metadata
                        readRequest.complete(content: content, isComplete: false, isFinal: true)
                        // TODO: This is not efficient. Probably better to use an ArraySlice here
                        self.readRequests.removeFirst()
                    } else {
                        flow.waitForInboundDataAvailable(completion: self.inputAvailable)
                        break
                    }
                } else {
                    break
                }
            }
        case .datagram(let flow):
            while true {
                if let readRequest = self.readRequests.first {
                    if let content = flow.read() {
                        readRequest.complete(content: content, isComplete: true, isFinal: false)
                        // TODO: This is not efficient. Probably better to use an ArraySlice here
                        self.readRequests.removeFirst()
                    } else {
                        flow.waitForInboundDataAvailable(completion: self.inputAvailable)
                        break
                    }
                } else {
                    break
                }
            }
        case .none:
            fatalError("No current flow")
        }
    }

    func async(_ block: @Sendable @escaping () -> Void) {
        self.parameters.context.async(block)
    }

    func addWriteRequestOnContext(_ writeRequest: consuming WriteRequest) {
        var writeRequest: WriteRequest? = writeRequest
        self.startIfNeeded()
        if let takenRequest = writeRequest.take() {
            self.writeRequests.append(takenRequest)
        }
        if self.state == .ready {
            self.write()
        }
    }

    func addReadRequest(_ readRequest: ReadRequest) {
        self.parameters.context.async {
            self.startIfNeeded()
            self.readRequests.append(readRequest)
            // If state is ready and this is the first read request, then try to start reading.
            // Otherwise, wait for inputAvailable to trigger a call to read()
            if self.state == .ready && self.readRequests.count == 1 {
                self.read()
            }
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

    func cancel() {
        self.parameters.context.async {
            switch self.flowProtocol {
            case .stream(let flow):
                flow.stop()
                flow.teardown()
            case .datagram(let flow):
                flow.stop()
                flow.teardown()
            case .none:
                break
            }

            // Fail pending write requests
            while var writeRequest = self.writeRequests.popFirst() {
                let completion = writeRequest.completion
                writeRequest.frame.finalize(success: false)
                WriteRequest.runCompletion(completion, success: false)
            }

            // Fail pending read requests
            while !self.readRequests.isEmpty {
                let readRequest = self.readRequests.removeFirst()
                readRequest.complete(content: nil, isComplete: false, isFinal: true, error: .posix(ECANCELED))
            }

            self.state = .cancelled

            var stateUpdateHandler = self.stateUpdateHandler
            self.stateUpdateHandler = nil
            if stateUpdateHandler != nil {
                stateUpdateHandler = nil
            }
        }
    }
}
