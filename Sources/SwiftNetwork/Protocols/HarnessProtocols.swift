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

#if !NETWORK_NO_SWIFT_QUIC && !NETWORK_NO_TESTING_HARNESS

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol UpperHarnessProtocol: TopDatapathProtocol, LoggableProtocol {
    func teardown()
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class UpperHarness<LinkageType: InboundDataLinkage>: UpperHarnessProtocol {
    public typealias LowerProtocol = LinkageType.PairedLinkage

    // Completions: called once!
    public struct Completions {
        public var connected: ((Bool) -> Void)?
        public var disconnected: (() -> Void)?

        // true when inbound data is available, false when disconnected
        public var inboundDataAvailable: ((Bool) -> Void)?

        public var inboundAborted: ((NetworkError?) -> Void)?
        public var outboundAborted: ((NetworkError?) -> Void)?
        public var error: ((NetworkError) -> Void)?  // invoked when error detected
        public var earlyDataRejected: (() -> Void)?
        public var receivedRemoteTransportParameters: (([UInt8]) -> Void)?
        public init() {}
    }
    public var completions = Completions()

    var inboundDataAvailableReceived = false

    public var receivedConnected = false
    public var receivedDisconnected = false

    public var log = NetworkLoggerState()

    public fileprivate(set) var context: NetworkContext

    public var reference: ProtocolInstanceReference { .init() }
    public var lower = LowerProtocol(reference: .init())

    public var eventManager = ProtocolEventManager()
    // Metadata passed in by the new inbound flow event when a new flow is created.
    public var flowMetadata: AbstractProtocolMetadata?

    var local: Endpoint
    var remote: Endpoint
    var parameters: Parameters
    var path: PathProperties

    fileprivate init(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) {
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        log.logPrefix = "[UpperHarness:\(identifier)]"
    }

    #if !NETWORK_EMBEDDED
    public init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        lowerProtocol: LinkageType.PairedLinkage
    ) {
        log.logPrefix = "[UpperHarness:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        do throws(NetworkError) {
            self.lower = try lowerProtocol.invokeAttachUpperProtocol(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }
    #endif

    public func handleConnectedEvent() {
        log.debug("Received connected event")
        self.receivedConnected = true
        if let completion = completions.connected {
            completion(true)
            self.completions.connected = nil
        }
    }

    public func handleDisconnectedEvent(error: NetworkError?) {
        log.debug("Received disconnected event, error \(error.debugDescription)")
        receivedDisconnected = true
        if let completion = completions.connected {
            completion(false)
            self.completions.connected = nil
        }
        if let completion = completions.disconnected {
            completion()
            self.completions.disconnected = nil
        }
        if let error, let errorCompletion = self.completions.error {
            errorCompletion(error)
            self.completions.error = nil
        }

        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            inboundDataAvailableCompletion(false)
            self.completions.inboundDataAvailable = nil
        }
    }

    public func handleInboundDataAvailableEvent() {
        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            self.completions.inboundDataAvailable = nil
            inboundDataAvailableCompletion(true)
        } else {
            self.inboundDataAvailableReceived = true
        }
    }

    public func handleOutboundRoomAvailableEvent() {
    }

    public func handleNetworkProtocolEvent(_ event: NetworkProtocolEvent) {
        log.debug("Received network protocol event: \(event)")
        if let quicEvent = event.quicEvent {
            switch quicEvent {
            case .earlyDataRejected:
                if let earlyDataRejectedCompletion = self.completions.earlyDataRejected {
                    self.completions.earlyDataRejected = nil
                    earlyDataRejectedCompletion()
                }
            case .receivedRemoteTransportParameters(let state):
                if let transportParametersCompletion = self.completions.receivedRemoteTransportParameters {
                    self.completions.receivedRemoteTransportParameters = nil
                    transportParametersCompletion(state)
                }
            default: break
            }
        }
    }

    public func start() {
        invokeConnect()
    }

    public func start(_ completion: @escaping (Bool) -> Void) {
        self.completions.connected = completion
        start()
    }

    public func stop(error: NetworkError? = nil) {
        invokeDisconnect(error: error)
    }

    public func teardown() {
        do throws(NetworkError) {
            var mutatingSelf = self
            try mutatingSelf.invokeDetach()
        } catch {
            log.error("Failed to detach lower protocol: \(error)")
        }
    }

    public func waitForInboundDataAvailable(completion: @escaping (Bool) -> Void) {
        if self.inboundDataAvailableReceived {
            // Received inbound data available, but didn't deliver. Fire now.
            self.inboundDataAvailableReceived = false
            completion(true)
            return
        }
        completions.inboundDataAvailable = completion
    }

    public func waitForDisconnected(completion: @escaping () -> Void) {
        if receivedDisconnected {
            completion()
            return
        }
        completions.disconnected = completion
    }

    public func waitForError(completion: @escaping (NetworkError?) -> Void) {
        completions.error = completion
    }

    final public func getMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        if let flowMetadata = flowMetadata as? ProtocolMetadata<P> {
            return flowMetadata
        }
        return invokeGetMetadata() as? ProtocolMetadata<P>
    }

    final public func getMetrics(requestedNetworkMetric: RequestedNetworkMetrics) -> NetworkMetrics? {
        lower.invokeGetMetrics(reference, requestedNetworkMetric: requestedNetworkMetric)
    }

    public func setApplicationError(_ applicationError: UInt64, applicationErrorReason: String) {
        if let metadata: ProtocolMetadata<QUICProtocol> = self.getMetadata() {
            metadata.perProtocolMetadata?.quicConnectionMetadata?.applicationError = applicationError
            metadata.perProtocolMetadata?.quicConnectionMetadata?.applicationErrorReason = applicationErrorReason
        }
    }

    public func invokeDataStallEvent() {
        invokeApplicationEvent(.dataStall)
    }

    public func invokeConnectionIdleEvent() {
        invokeApplicationEvent(.connectionIdle)
    }

    public func invokeConnectionReusedEvent() {
        invokeApplicationEvent(.connectionReused)
    }

    public func invokeApplicationEvent(_ event: ApplicationEvent) {
        fromExternal {
            lower.invokeApplicationEvent(reference, event: event)
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class DatagramUpperHarness: UpperHarness<InboundDatagramLinkage>, TopDatagramProtocol {

    override public var reference: ProtocolInstanceReference { ProtocolInstanceReference(datagramUpperHarness: self) }

    public convenience init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        lowerDatagramProtocol: OutboundDatagramLinkage
    ) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        do throws(NetworkError) {
            self.lower = try lowerDatagramProtocol.invokeAttachUpperDatagramProtocol(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    public convenience init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        listenerProtocol: DatagramListenerLinkage
    ) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        do throws(NetworkError) {
            self.lower = try listenerProtocol.invokeAttachUpperDatagramProtocolToNewFlow(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    public func write(_ datagram: [UInt8]) -> Bool {
        do throws(NetworkError) {
            let frames = try invokeGetDatagramsToSend(maximumDatagramCount: 1, minimumDatagramSize: datagram.count)
            guard var frames = frames else {
                log.error("Failed to get datagram to send")
                return false
            }
            frames.iterateMutableFrames { frame in
                let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.buffer(datagram)
                }
                log.debug("Write result: \(result)")
                frame.collapse()
                if !frame.unclaim(fromStart: datagram.count) {
                    log.error("Failed to unclaim")
                }
                return false
            }
            try invokeSendDatagrams(frames)
            return true
        } catch {
            return false
        }
    }

    public func read() -> [UInt8]? {
        do throws(NetworkError) {
            let frames = try invokeReceiveDatagrams(maximumDatagramCount: 1)
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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class StreamUpperHarness: UpperHarness<InboundStreamLinkage>, TopStreamProtocol {

    override public var reference: ProtocolInstanceReference { ProtocolInstanceReference(streamUpperHarness: self) }

    public func handleInboundAbortedEvent(error: NetworkError?) {
        log.debug("Received inbound aborted event: \(error?.description ?? "no error")")
        self.inboundAborted = true
        self.inboundAbortError = error
        if let inboundAbortedCompletion = self.completions.inboundAborted {
            self.completions.inboundAborted = nil
            inboundAbortedCompletion(self.inboundAbortError)
        }
    }
    public func handleOutboundAbortedEvent(error: NetworkError?) {
        log.debug("Received outbound aborted event: \(error?.description ?? "no error")")
        self.outboundAborted = true
        self.outboundAbortError = error
        if let inboundAbortedCompletion = self.completions.outboundAborted {
            self.completions.inboundAborted = nil
            inboundAbortedCompletion(self.outboundAbortError)
        }
    }

    var inboundAborted = false
    var outboundAborted = false
    var inboundAbortError: NetworkError?
    var outboundAbortError: NetworkError?

    public func waitForInboundAborted(completion: @escaping (NetworkError?) -> Void) {
        if self.inboundAborted {
            completion(self.inboundAbortError)
            return
        }
        completions.inboundAborted = completion
    }

    public func waitForOutboundAborted(completion: @escaping (NetworkError?) -> Void) {
        if self.outboundAborted {
            completion(self.outboundAbortError)
            return
        }
        completions.outboundAborted = completion
    }

    public convenience init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        lowerStreamProtocol: OutboundStreamLinkage
    ) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        do throws(NetworkError) {
            self.lower = try lowerStreamProtocol.invokeAttachUpperStreamProtocol(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    public convenience init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        listenerProtocol: StreamListenerLinkage
    ) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        do throws(NetworkError) {
            self.lower = try listenerProtocol.invokeAttachUpperStreamProtocolToNewFlow(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    public func write(_ bytes: [UInt8], sendFIN: Bool = false, earlyData: Bool = false) -> Bool {
        do throws(NetworkError) {
            var frame = Frame(count: bytes.count)
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.span(bytes.span.bytes)
            }
            guard result.isValid else {
                Logger.proto.error("Serializing to frame failed")
                return false
            }
            if sendFIN {
                frame.metadataComplete = true
                frame.connectionComplete = true
            }
            if earlyData {
                try invokeSendEarlyStreamData(.init(frame: frame))
            } else {
                try invokeSendStreamData(.init(frame: frame))
            }
            return true
        } catch {
            return false
        }
    }

    public var receivedFIN: Bool = false

    public func readAndDrop(upTo maximumBytes: Int = Int.max) -> Int {
        do throws(NetworkError) {
            guard var frames = try invokeReceiveStreamData(minimumBytes: 1, maximumBytes: maximumBytes) else {
                return 0
            }
            var bytesRead = 0
            frames.iterateMutableFrames { frame in
                let length = frame.unclaimedLength
                let fin = frame.connectionComplete
                bytesRead += length
                if fin {
                    self.receivedFIN = true
                }
                frame.finalize(success: true)
                return true
            }
            return bytesRead
        } catch {
            return 0
        }
    }

    public func read(upTo maximumBytes: Int = Int.max) -> [UInt8]? {
        do throws(NetworkError) {
            guard var frames = try invokeReceiveStreamData(minimumBytes: 1, maximumBytes: maximumBytes) else {
                return nil
            }
            var returnBuffer: [UInt8]? = nil
            frames.iterateMutableFrames { frame in
                var buffer = [UInt8]()
                let length = frame.unclaimedLength
                let fin = frame.connectionComplete
                if length > 0 {
                    _ = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                        try read.buffer(&buffer, length: length)
                    }
                }
                if fin {
                    self.receivedFIN = true
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

    public func abortInbound(error: NetworkError?) {
        fromExternal {
            do throws(NetworkError) {
                try lower.invokeAbortInbound(reference, error: error)
            } catch {
                log.error("Failed to abort inbound: \(error)")
            }
        }
    }

    public func abortOutbound(error: NetworkError?) {
        fromExternal {
            do throws(NetworkError) {
                try lower.invokeAbortOutbound(reference, error: error)
            } catch {
                log.error("Failed to abort outbound: \(error)")
            }
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class LowerHarness<LinkageType: OutboundDataLinkage>: BottomProtocolHandler, LoggableProtocol
where LinkageType == LinkageType.PairedLinkage.PairedLinkage {
    public typealias UpperProtocol = LinkageType.PairedLinkage

    public var log = NetworkLoggerState()
    public private(set) var context: NetworkContext

    public var reference: ProtocolInstanceReference { .init() }
    public var upper = UpperProtocol(reference: .init())

    public var eventManager = ProtocolEventManager()

    var pendingOutboundPackets = FrameArray()
    var pendingInboundPackets = FrameArray()

    public init(
        identifier: String = "",
        context: NetworkContext
    ) {
        log.logPrefix = "[LowerHarness:\(identifier)]"
        self.context = context
    }

    public func flushPackets() {
        pendingOutboundPackets.finalizeAllFramesAsFailed()
    }

    public func teardown() {
        log.debug("Received teardown")
        flushPackets()
    }

    func extractLastOutboundBytes() -> UniqueArray<UInt8>? {
        guard var frame = pendingOutboundPackets.popFirst() else {
            return nil
        }
        return frame.extractBytes()
    }

    public func extractLastOutboundPacket() -> [UInt8]? {
        guard let bytes = extractLastOutboundBytes() else {
            return nil
        }
        return [UInt8](copying: bytes.span, maxCount: bytes.count)
    }

    public var hasOutboundPackets: Bool {
        !pendingOutboundPackets.isEmpty
    }

    func setNextInboundPacketBytes(_ bytes: consuming UniqueArray<UInt8>, sendAvailableEvent: Bool = true) {
        pendingInboundPackets.add(frame: .init(bytes: bytes))
        if sendAvailableEvent {
            deliverInboundDataAvailableEvent()
        }
    }

    public func setNextInboundPacket(_ packet: [UInt8], sendAvailableEvent: Bool = true) {
        pendingInboundPackets.add(frame: .init(copyBuffer: packet))
        if sendAvailableEvent {
            deliverInboundDataAvailableEvent()
        }
    }

    public func setNextInboundPacket(from: LowerHarness, sendAvailableEvent: Bool = true) -> Bool {
        guard let bytes = from.extractLastOutboundBytes() else {
            return false
        }
        setNextInboundPacketBytes(bytes, sendAvailableEvent: sendAvailableEvent)
        return true
    }

    public func deliverViableEvent() {
        deliverNetworkProtocolEvent(.viabilityChanged(isViable: true))
    }

    public func deliverPathIsPrimary() {
        deliverNetworkProtocolEvent(.pathIsPrimary)
    }

    public func deliverPathIsNotPrimary() {
        deliverNetworkProtocolEvent(.pathIsNotPrimary)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class DatagramLowerHarness: LowerHarness<OutboundDatagramLinkage>, BottomDatagramProtocol {
    public var maximumOutputSize = 1500

    override public var reference: ProtocolInstanceReference { ProtocolInstanceReference(datagramLowerHarness: self) }

    public func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
        let array = pendingInboundPackets.drainArray(maximumFrameCount: maximumDatagramCount)
        log.debug("Deliver inbound datagram count: \(array.count)")
        return array
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        let frameSize = min(minimumDatagramSize, self.maximumOutputSize)
        var frameArray = FrameArray(capacity: maximumDatagramCount)
        for _ in 0..<maximumDatagramCount {
            let frame = Frame(count: frameSize)
            frameArray.add(frame: frame)
        }
        return frameArray
    }

    public func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        pendingOutboundPackets.add(frames: datagrams)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class StreamLowerHarness: LowerHarness<OutboundStreamLinkage>, BottomStreamProtocol {

    override public var reference: ProtocolInstanceReference { ProtocolInstanceReference(streamLowerHarness: self) }

    public func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
        pendingInboundPackets.drainArray(maximumByteCount: maximumBytes)
    }

    public func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        Int.max
    }

    public func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        pendingOutboundPackets.add(frames: streamData)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class NewFlowHarness<LinkageType: InboundFlowLinkage, HarnessType: UpperHarnessProtocol>: InboundFlowHandler,
    LoggableProtocol
{
    public typealias LowerProtocol = LinkageType.PairedLinkage
    typealias HarnessType = HarnessType

    public var eventManager = ProtocolEventManager()

    public var log = NetworkLoggerState()
    public private(set) var context: NetworkContext

    public var reference: ProtocolInstanceReference { .init() }
    var lower = LowerProtocol(reference: .init())
    var asUpper: LinkageType { .init(reference: reference) }

    public var upperHarnesses: [HarnessType] = []

    var local: Endpoint
    var remote: Endpoint
    var parameters: Parameters
    var path: PathProperties

    public struct Completions {
        public var connected: ((Bool) -> Void)?
        public var disconnected: (() -> Void)?
        var newFlow = Deque<(() -> Void)>()
        public var error: ((NetworkError) -> Void)?  // invoked when error detected
        public init() {}
    }
    public var completions: Completions = .init()

    public var receivedConnected = false
    public var receivedDisconnected = false

    public func attachLowerProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(EINVAL)
    }

    public func handleConnectedEvent(_ from: ProtocolInstanceReference) {
        log.debug("Received connected event")
        self.receivedConnected = true
        if let completion = completions.connected {
            completion(true)
            self.completions.connected = nil
        }
    }

    public func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        log.debug("Received disconnected event, \(error?.description ?? "<no error>")")
        receivedDisconnected = true
        if let completion = completions.connected {
            completion(false)
            self.completions.connected = nil
        }
        if let completion = completions.disconnected {
            completion()
            self.completions.disconnected = nil
        }
        if let error, let errorCompletion = self.completions.error {
            errorCompletion(error)
            self.completions.error = nil
        }
    }

    open func handleNewInboundFlowEvent(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference,
        flowMetadata: AbstractProtocolMetadata?
    ) {
        log.debug("Received new inbound flow event with reference \(flowReference)")
    }

    public var newInboundCIDEventCount = 0
    public var newOutboundCIDEventCount = 0
    public func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        log.debug("Received network protocol event: \(event)")
        if let quicEvent = event.quicEvent {
            switch quicEvent {
            case .newInboundConnectionID: newInboundCIDEventCount += 1
            case .newOutboundConnectionID: newOutboundCIDEventCount += 1
            default: break
            }
        }
    }

    public func teardown() {
        for upperHarness in upperHarnesses {
            upperHarness.teardown()
        }
        upperHarnesses.removeAll()
        fromExternal {
            do throws(NetworkError) {
                try lower.invokeDetach(reference)
                lower = .init(reference: .init())
            } catch {
                log.error("Failed to detach lower protocol: \(error)")
            }
        }
    }

    fileprivate init(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) {
        log.logPrefix = "[NewFlowHarness:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
    }

    #if !NETWORK_EMBEDDED
    public init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        listenerProtocol: LinkageType.PairedLinkage
    ) {
        log.logPrefix = "[NewFlowHarness:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        do throws(NetworkError) {
            self.lower = try listenerProtocol.invokeAttachUpperProtocol(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }
    #endif

    public func waitForDisconnected(completion: @escaping () -> Void) {
        if receivedDisconnected {
            completion()
            return
        }
        completions.disconnected = completion
    }

    public func waitForError(completion: @escaping (NetworkError?) -> Void) {
        completions.error = completion
    }

    public func start() {
        fromExternal {
            lower.invokeConnect(reference)
        }
    }

    public func start(_ completion: @escaping (Bool) -> Void) {
        completions.connected = completion
        start()
    }

    public func stop(error: NetworkError? = nil) {
        fromExternal {
            lower.invokeDisconnect(reference, error: error)
        }
    }

    public func waitForNewFlow(completion: @escaping () -> Void) {
        completions.newFlow.append(completion)
    }

    public func invokeApplicationEvent(_ event: ApplicationEvent) {
        fromExternal {
            lower.invokeApplicationEvent(reference, event: event)
        }
    }

    final public func getMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        fromExternal {
            guard let metadata = lower.invokeGetMetadata(reference) as? ProtocolMetadata<P> else {
                return nil
            }
            return metadata
        }
    }

    final public func getMetrics(requestedNetworkMetric: RequestedNetworkMetrics) -> NetworkMetrics? {
        fromExternal {
            lower.invokeGetMetrics(reference, requestedNetworkMetric: requestedNetworkMetric)
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class NewDatagramFlowHarness: NewFlowHarness<InboundDatagramFlowLinkage, DatagramUpperHarness> {

    override public var reference: ProtocolInstanceReference { ProtocolInstanceReference(newDatagramFlowHarness: self) }

    public convenience init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        datagramListenerProtocol: DatagramListenerLinkage
    ) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        do throws(NetworkError) {
            self.lower = try datagramListenerProtocol.invokeAttachNewDatagramFlowProtocol(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    public override func handleNewInboundFlowEvent(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference,
        flowMetadata: AbstractProtocolMetadata?
    ) {
        log.debug(
            "Received new inbound flow event with reference \(flowReference) with flowMetadata: \(flowMetadata.debugDescription)"
        )
        do throws(NetworkError) {
            let newUpperHarness = HarnessType(
                identifier: "Inbound",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                context: context
            )
            newUpperHarness.lower = try lower.invokeAttachUpperDatagramProtocolToExistingFlow(
                newUpperHarness.reference,
                flowReference: flowReference
            )
            upperHarnesses.append(newUpperHarness)
            newUpperHarness.flowMetadata = flowMetadata
            newUpperHarness.start()
            if let newFlowCompletion = completions.newFlow.popFirst() {
                newFlowCompletion()
            }
        } catch {
            log.error("Failed to attach new inbound flow")
            return
        }
    }
}
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class NewStreamFlowHarness: NewFlowHarness<InboundStreamFlowLinkage, StreamUpperHarness> {

    override public var reference: ProtocolInstanceReference { ProtocolInstanceReference(newStreamFlowHarness: self) }

    public convenience init?(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        streamListenerProtocol: StreamListenerLinkage
    ) {
        self.init(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        do throws(NetworkError) {
            self.lower = try streamListenerProtocol.invokeAttachNewStreamFlowProtocol(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            return nil
        }
    }

    public override func handleNewInboundFlowEvent(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference,
        flowMetadata: AbstractProtocolMetadata?
    ) {
        log.debug(
            "Received new inbound flow event with reference \(flowReference) with flowMetadata: \(flowMetadata.debugDescription)"
        )
        do throws(NetworkError) {
            let newUpperHarness = HarnessType(
                identifier: "Inbound",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                context: context
            )
            newUpperHarness.lower = try lower.invokeAttachUpperStreamProtocolToExistingFlow(
                newUpperHarness.reference,
                flowReference: flowReference
            )
            upperHarnesses.append(newUpperHarness)
            newUpperHarness.flowMetadata = flowMetadata
            newUpperHarness.start()
            if let newFlowCompletion = completions.newFlow.popFirst() {
                newFlowCompletion()
            }
        } catch {
            log.error("Failed to attach new inbound flow")
            return
        }
    }
}

#endif
