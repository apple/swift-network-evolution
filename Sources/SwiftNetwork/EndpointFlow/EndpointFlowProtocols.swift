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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
protocol AbstractEndpointFlowProtocol: InboundDataHandler, LoggableProtocol {
    func teardown()
}

@available(Network 0.1.0, *)
class EndpointFlowProtocol<LinkageType: InboundDataLinkage>: ProtocolInstanceContainer, AbstractEndpointFlowProtocol {
    typealias LowerProtocol = LinkageType.PairedLinkage

    #if !NETWORK_EMBEDDED
    func accessUpper<R, E: Error>(
        at index: Int?,
        _ body: (inout any UpperProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any UpperProtocolHandler) = self
        return try body(&selfAccess)
    }
    func accessInboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDataHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any InboundDataHandler) = self
        return try body(&selfAccess)
    }
    #endif

    // Completions: called once!
    struct Completions {
        public var connected: ((NetworkError?) -> Void)?
        public var outputRoomAvailable: (() -> Void)?

        // true when inbound data is available, false when disconnected
        public var inboundDataAvailable: ((Bool) -> Void)?

        // invoked when error detected
        public var error: ((NetworkError) -> Void)?

        // invoked when remote peer disconnects
        public var disconnected: ((NetworkError) -> Void)?
        public init() {}
    }
    var completions = Completions()

    var log = NetworkLoggerState()

    fileprivate(set) var context: NetworkContext

    var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    var lower = LowerProtocol(reference: .init())
    var asUpper: LinkageType { .init(reference: reference) }

    var eventManager = ProtocolEventManager()

    var local: Endpoint?
    var remote: Endpoint
    var parameters: Parameters
    var path: PathProperties

    fileprivate init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) {
        log.logPrefix = "[EndpointFlowProtocol:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
    }

    #if !NETWORK_EMBEDDED
    init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        lowerProtocol: LinkageType.PairedLinkage
    ) throws(NetworkError) {
        log.logPrefix = "[EndpointFlowProtocol:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        self.lower = try lowerProtocol.invokeAttachUpperProtocol(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
    #endif

    func attachLowerProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(EINVAL)
    }

    func handleConnectedEvent(_ from: ProtocolInstanceReference) {
        log.debug("Received connected event")
        if let completion = completions.connected {
            completion(nil)
            self.completions.connected = nil
        }
    }

    func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        log.debug("Received disconnected event")
        let disconnectError = error ?? .posix(ENOTCONN)
        if let completion = completions.connected {
            completion(disconnectError)
            self.completions.connected = nil
        }
        if let error, let errorCompletion = self.completions.error {
            errorCompletion(error)
            self.completions.error = nil
        }

        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            inboundDataAvailableCompletion(false)
            self.completions.inboundDataAvailable = nil
        }

        if let disconnectedCompletion = self.completions.disconnected {
            disconnectedCompletion(disconnectError)
            self.completions.disconnected = nil
        }
    }

    func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
        log.debug("Received inbound data available event")
        // Clear the slot before invoking: the completion may synchronously
        // re-arm the waiter (when receiveStreamData returns nil because the
        // requested minimum spans more than one segment). Clearing afterwards
        // would clobber that re-registration and drop later notifications.
        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            self.completions.inboundDataAvailable = nil
            inboundDataAvailableCompletion(true)
        }
    }

    public func handleOutboundRoomAvailableEvent(_ from: ProtocolInstanceReference) {
        log.debug("Received outbound room available event")
        if let completion = self.completions.outputRoomAvailable {
            completion()
            self.completions.outputRoomAvailable = nil
        }
    }

    public func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        log.debug("Received network protocol event: \(event)")
    }

    public func start() {
        log.debug("Starting flow")
        fromExternal {
            lower.invokeConnect(reference)
        }
    }

    public func invokeApplicationEvent(_ event: ApplicationEvent) {
        fromExternal {
            lower.invokeApplicationEvent(reference, event: event)
        }
    }

    public func start(_ completion: @escaping (NetworkError?) -> Void) {
        self.completions.connected = completion
        start()
    }

    public func stop() {
        log.debug("Stopping flow")
        fromExternal {
            lower.invokeDisconnect(reference)
        }
    }

    public func teardown() {
        log.debug("Tearing down flow")
        fromExternal {
            do throws(NetworkError) {
                try lower.invokeDetach(reference)
                lower = .init(reference: .init())
            } catch {
                log.error("Failed to detach lower protocol: \(error)")
            }
        }
    }

    public func abort(error: NetworkError? = nil) {
        log.debug("Aborting flow")
        fromExternal {
            lower.invokeDisconnect(reference, error: error)
        }
    }

    public func waitForOutputRoomAvailable(_ completion: @escaping () -> Void) {
        completions.outputRoomAvailable = completion
    }

    public func waitForInboundDataAvailable(completion: @escaping (Bool) -> Void) {
        completions.inboundDataAvailable = completion
    }

    public func waitForError(completion: @escaping (NetworkError?) -> Void) {
        completions.error = completion
    }

    public func waitForDisconnected(completion: @escaping (NetworkError) -> Void) {
        completions.disconnected = completion
    }

    final public func getMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        fromExternal {
            guard let metadata = lower.invokeGetMetadata(reference) as? ProtocolMetadata<P> else {
                return nil
            }
            return metadata
        }
    }

    public func setApplicationError(_ applicationError: UInt64, applicationErrorReason: String) {
        if let metadata: ProtocolMetadata<QUICProtocol> = self.getMetadata() {
            metadata.perProtocolMetadata?.quicConnectionMetadata?.applicationError = applicationError
            metadata.perProtocolMetadata?.quicConnectionMetadata?.applicationErrorReason = applicationErrorReason
        }
    }
}

@available(Network 0.1.0, *)
final class DatagramEndpointFlowProtocol: EndpointFlowProtocol<InboundDatagramLinkage>, InboundDatagramHandler {

    override var reference: ProtocolInstanceReference { ProtocolInstanceReference(datagramEndpointFlow: self) }

    convenience init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        lowerDatagramProtocol: OutboundDatagramLinkage
    ) throws(NetworkError) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        self.lower = try lowerDatagramProtocol.invokeAttachUpperDatagramProtocol(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func attachLowerDatagramProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(EINVAL)
    }

    convenience init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        listenerProtocol: DatagramListenerLinkage
    ) throws(NetworkError) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        self.lower = try listenerProtocol.invokeAttachUpperDatagramProtocolToNewFlow(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func write(_ datagram: consuming Frame) -> Bool {
        fromExternal {
            do throws(NetworkError) {
                let length = datagram.unclaimedLength
                let frames = try lower.invokeGetDatagramsToSend(
                    reference,
                    maximumDatagramCount: 1,
                    minimumDatagramSize: length
                )
                guard var frames = frames else {
                    datagram.finalize(success: false)
                    log.error("Failed to get datagram to send")
                    return false
                }
                frames.iterateMutableFrames { frame in
                    let copiedLength = datagram.copyInto(&frame, length: length)
                    if copiedLength < length {
                        log.error("Failed to copy \(length) bytes, only copied \(copiedLength)")
                    }
                    let frameLength = frame.unclaimedLength
                    if frameLength > copiedLength {
                        _ = frame.collapse(to: copiedLength)
                    }
                    datagram.finalize(success: true)
                    return false
                }
                try lower.invokeSendDatagrams(reference, datagrams: frames)
                return true
            } catch {
                datagram.finalize(success: false)
                return false
            }
        }
    }

    func read() -> [UInt8]? {
        fromExternal {
            do throws(NetworkError) {
                let frames = try lower.invokeReceiveDatagrams(reference, maximumDatagramCount: 1)
                guard var frames = frames else {
                    log.debug("Failed to receive datagrams")
                    return nil
                }
                var returnBuffer: [UInt8]? = nil
                frames.iterateMutableFrames { frame in
                    var buffer = [UInt8]()
                    let length = frame.unclaimedLength
                    if length > 0 {
                        _ = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                            try read.buffer(&buffer, length: length)
                        }
                    }
                    returnBuffer = buffer
                    frame.finalize(success: true)
                    return true
                }
                return returnBuffer
            } catch {
                return nil
            }
        }
    }
}

@available(Network 0.1.0, *)
final class StreamEndpointFlowProtocol: EndpointFlowProtocol<InboundStreamLinkage>, InboundStreamHandler {

    override var reference: ProtocolInstanceReference { ProtocolInstanceReference(streamEndpointFlow: self) }

    func handleInboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {}
    func handleOutboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {}

    convenience init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        lowerStreamProtocol: OutboundStreamLinkage
    ) throws(NetworkError) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        self.lower = try lowerStreamProtocol.invokeAttachUpperStreamProtocol(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    override public func abort(error: NetworkError? = nil) {
        log.debug("Aborting flow")
        fromExternal {
            do throws(NetworkError) {
                try lower.invokeAbortOutbound(reference, error: error)
                try lower.invokeAbortInbound(reference, error: error)
            } catch {
                log.error("Failed to abort stream: \(error)")
            }
            lower.invokeDisconnect(reference, error: error)
        }
    }

    func attachLowerStreamProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(EINVAL)
    }

    func attachLowerStreamProtocolToExistingFlow(
        listener: StreamListenerLinkage,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) {
        throw NetworkError.posix(EINVAL)
    }

    convenience init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        listenerProtocol: StreamListenerLinkage
    ) throws(NetworkError) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        self.lower = try listenerProtocol.invokeAttachUpperStreamProtocolToNewFlow(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    convenience init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        listenerProtocol: StreamListenerLinkage,
        existingFlowReference: ProtocolInstanceReference
    ) throws(NetworkError) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        self.lower = try listenerProtocol.invokeAttachUpperStreamProtocolToExistingFlow(
            reference,
            flowReference: existingFlowReference
        )
    }

    private func invokeSendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        try fromExternal(streamData) { streamData throws(NetworkError) in
            try lower.invokeSendStreamData(self.reference, streamData: streamData)
        }
    }

    func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        try fromExternal { () throws(NetworkError) in
            try lower.invokeGetOutboundStreamDataRoomAvailable(self.reference)
        }
    }

    func write(_ frame: consuming Frame) -> Bool {
        do throws(NetworkError) {
            try invokeSendStreamData(.init(frame: frame))
            return true
        } catch {
            return false
        }
    }

    func read(minimumBytes: Int, maximumBytes: Int) -> [UInt8]? {
        fromExternal {
            do throws(NetworkError) {
                guard
                    var frames = try lower.invokeReceiveStreamData(
                        reference,
                        minimumBytes: minimumBytes,
                        maximumBytes: maximumBytes
                    )
                else {
                    log.debug("No more stream data available")
                    return nil
                }
                var returnBuffer: [UInt8]? = nil
                frames.iterateMutableFrames { frame in
                    var buffer = [UInt8]()
                    let length = frame.unclaimedLength
                    if length > 0 {
                        _ = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                            try read.buffer(&buffer, length: length)
                        }
                    }
                    if returnBuffer == nil {
                        returnBuffer = buffer
                    } else {
                        returnBuffer?.append(contentsOf: buffer)
                    }
                    frame.finalize(success: true)
                    return true
                }
                return returnBuffer
            } catch {
                return nil
            }
        }
    }
}
