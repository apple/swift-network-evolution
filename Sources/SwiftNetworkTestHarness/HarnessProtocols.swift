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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

#if !NETWORK_NO_TESTING_HARNESS

// A local copy of the framework's internal convenience. This is deliberately not made public on
// the framework side: it extends the standard library's `Array`, so widening it would add an
// initializer to the namespace of every SwiftNetwork client, unlike the other API this target
// needs, which is all on SwiftNetwork's own types.
@available(anyAppleOS 26, *)
extension Array {
    fileprivate init(copyingSpan span: Span<Element>, maxCount: Int) {
        let copyCount = Swift.min(span.count, maxCount)
        self.init(unsafeUninitializedCapacity: copyCount) { (buffer, count) in
            for i in 0..<copyCount {
                buffer.initializeElement(at: i, to: span[i])
            }
            count = copyCount
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol UpperHarnessProtocol: TopDatapathProtocol, LoggableProtocol {
    /// Metadata handed over by the new inbound flow event that created this harness.
    var flowMetadata: AbstractProtocolMetadata? { get set }
    func teardown()
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class UpperHarness<LinkageFamily: DataLinkageFamily>: UpperHarnessProtocol {
    public typealias LinkageType = LinkageFamily.Upper
    public typealias LowerProtocol = LinkageFamily.Lower

    // Completions: called once!
    public struct Completions {
        public var connected: ((inout NetworkContext.EventContext, Bool) -> Void)?
        public var disconnected: (() -> Void)?

        // true when inbound data is available, false when disconnected. The completion runs
        // inline while the event's event context is held, so it receives that state and must
        // thread it into any reads rather than re-deriving it.
        public var inboundDataAvailable: ((inout NetworkContext.EventContext, Bool) -> Void)?

        public var inboundAborted: ((inout NetworkContext.EventContext, NetworkError?) -> Void)?
        public var outboundAborted: ((inout NetworkContext.EventContext, NetworkError?) -> Void)?
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

    public var identifier: InstanceIdentifier

    public var lower = LowerProtocol()

    public var eventManager = ProtocolEventManager()
    // Metadata passed in by the new inbound flow event when a new flow is created.
    public var flowMetadata: AbstractProtocolMetadata?

    var local: Endpoint
    var remote: Endpoint
    var parameters: Parameters
    var path: PathProperties

    public init(
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
        self.identifier = .init(context: context, eventManager: &self.eventManager)
    }

    /// Creates a harness using an event context the caller already holds.
    ///
    /// Use this when building a harness from inside a call that carries the state, such as
    /// handling a new inbound flow, so registering the identifier doesn't re-derive it.
    public required init(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        log.logPrefix = "[UpperHarness:\(identifier)]"
        self.identifier = .init(eventManager: &self.eventManager, context: context, in: &eventContext)
    }

    public func handleConnectedEvent(in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received connected event")
        self.receivedConnected = true
        if let completion = completions.connected {
            self.completions.connected = nil
            completion(&eventContext, true)
        }
    }

    public func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received disconnected event, error \(error.debugDescription)")
        receivedDisconnected = true
        if let completion = completions.connected {
            self.completions.connected = nil
            completion(&eventContext, false)
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
            inboundDataAvailableCompletion(&eventContext, false)
            self.completions.inboundDataAvailable = nil
        }
    }

    public func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            self.completions.inboundDataAvailable = nil
            inboundDataAvailableCompletion(&eventContext, true)
        } else {
            self.inboundDataAvailableReceived = true
        }
    }

    public func handleOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
    }

    public func handleNetworkProtocolEvent(_ event: NetworkProtocolEvent, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received network protocol event: \(event)")
        if let quicEvent = event.quicEvent {
            switch quicEvent {
            case .earlyDataRejected:
                if let earlyDataRejectedCompletion = self.completions.earlyDataRejected {
                    self.completions.earlyDataRejected = nil
                    earlyDataRejectedCompletion()
                }
            case .receivedRemoteTransportParameters(let transportParameters):
                if let transportParametersCompletion = self.completions.receivedRemoteTransportParameters {
                    self.completions.receivedRemoteTransportParameters = nil
                    transportParametersCompletion(transportParameters)
                }
            default: break
            }
        }
    }

    public func start() {
        invokeConnect()
    }

    public func start(_ completion: @escaping (inout NetworkContext.EventContext, Bool) -> Void) {
        self.completions.connected = completion
        start()
    }

    /// Starts with a completion that does not need the event context.
    public func start(_ completion: @escaping (Bool) -> Void) {
        self.completions.connected = { _, connected in completion(connected) }
        start()
    }

    public func stop(error: NetworkError? = nil) {
        invokeDisconnect(error: error)
    }

    /// Stops using an event context the caller already holds.
    public func stop(error: NetworkError? = nil, in eventContext: inout NetworkContext.EventContext) {
        invokeDisconnect(error: error, in: &eventContext)
    }

    public func teardown() {
        fromExternal { eventContext in
            teardown(in: &eventContext)
        }
    }

    /// Tears down using an event context the caller already holds.
    ///
    /// Completions that run inline while a delivering event holds the state have to use this
    /// rather than `teardown()`.
    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        do throws(NetworkError) {
            var mutatingSelf = self
            try mutatingSelf.invokeDetach(in: &eventContext)
        } catch {
            log.error("Failed to detach lower protocol: \(error)")
        }
        unregisterEventManager(in: &eventContext)
    }

    public func waitForInboundDataAvailable(
        completion: @escaping (inout NetworkContext.EventContext, Bool) -> Void
    ) {
        if self.inboundDataAvailableReceived {
            // Received inbound data available, but didn't deliver. Fire now. This is an
            // external entry point, so acquire the state for the completion.
            self.inboundDataAvailableReceived = false
            fromExternal { eventContext in
                completion(&eventContext, true)
            }
            return
        }
        completions.inboundDataAvailable = completion
    }

    /// Registers an inbound-data completion using an event context the caller already holds.
    ///
    /// Re-registering from inside a completion has to use this: the state is already held there,
    /// so `waitForInboundDataAvailable(completion:)` would re-enter it via `fromExternal` when
    /// data had already arrived, and the pending read would be lost.
    public func waitForInboundDataAvailable(
        in eventContext: inout NetworkContext.EventContext,
        completion: @escaping (inout NetworkContext.EventContext, Bool) -> Void
    ) {
        if self.inboundDataAvailableReceived {
            self.inboundDataAvailableReceived = false
            completion(&eventContext, true)
            return
        }
        completions.inboundDataAvailable = completion
    }

    /// Registers a completion that does not need the event context.
    public func waitForInboundDataAvailable(completion: @escaping (Bool) -> Void) {
        waitForInboundDataAvailable { _, available in completion(available) }
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
        fromExternal { eventContext in
            getMetadata(in: &eventContext)
        }
    }

    /// Reads metadata using an event context the caller already holds.
    final public func getMetadata<P: NetworkProtocol>(
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        guard let metadata = lower.invokeGetMetadata(for: identifier, in: &eventContext) as? ProtocolMetadata<P> else {
            return nil
        }
        return metadata
    }

    final public func getMetrics(requestedNetworkMetric: RequestedNetworkMetrics) -> NetworkMetrics? {
        fromExternal { eventContext in
            lower.invokeGetMetrics(requestedNetworkMetric: requestedNetworkMetric, for: identifier, in: &eventContext)
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
        fromExternal { eventContext in
            invokeApplicationEvent(event, in: &eventContext)
        }
    }

    /// Sends an application event using an event context the caller already holds.
    ///
    /// Completions such as `connected` run inline while the delivering event holds the state, so
    /// they have to use this rather than `invokeApplicationEvent(_:)`.
    public func invokeApplicationEvent(_ event: ApplicationEvent, in eventContext: inout NetworkContext.EventContext) {
        lower.invokeApplicationEvent(event: event, for: identifier, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class DatagramUpperHarness<LinkageFamily: DatagramLinkageFamily>: UpperHarness<LinkageFamily>, TopDatagramProtocol {
    public func write(_ datagram: [UInt8]) -> Bool {
        fromExternal { eventContext in
            write(datagram, in: &eventContext)
        }
    }

    /// Writes using an event context the caller already holds.
    public func write(_ datagram: [UInt8], in eventContext: inout NetworkContext.EventContext) -> Bool {
        do throws(NetworkError) {
            let frames = try invokeGetDatagramsToSend(
                maximumDatagramCount: 1,
                minimumDatagramSize: datagram.count,
                in: &eventContext
            )
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
            try invokeSendDatagrams(frames, in: &eventContext)
            return true
        } catch {
            return false
        }
    }

    public func read() -> [UInt8]? {
        fromExternal { eventContext in
            read(in: &eventContext)
        }
    }

    /// Reads using an event context the caller already holds.
    ///
    /// Inbound-data completions run inline while the delivering event holds the state, so they
    /// have to use this rather than `read()`.
    public func read(in eventContext: inout NetworkContext.EventContext) -> [UInt8]? {
        do throws(NetworkError) {
            let frames = try invokeReceiveDatagrams(maximumDatagramCount: 1, in: &eventContext)
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
public class StreamUpperHarness<LinkageFamily: StreamLinkageFamily>: UpperHarness<LinkageFamily>, TopStreamProtocol {

    public func handleInboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received inbound aborted event: \(error?.description ?? "no error")")
        self.inboundAborted = true
        self.inboundAbortError = error
        if let inboundAbortedCompletion = self.completions.inboundAborted {
            self.completions.inboundAborted = nil
            inboundAbortedCompletion(&eventContext, self.inboundAbortError)
        }
    }
    public func handleOutboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received outbound aborted event: \(error?.description ?? "no error")")
        self.outboundAborted = true
        self.outboundAbortError = error
        if let outboundAbortedCompletion = self.completions.outboundAborted {
            self.completions.outboundAborted = nil
            outboundAbortedCompletion(&eventContext, self.outboundAbortError)
        }
    }

    var inboundAborted = false
    var outboundAborted = false
    var inboundAbortError: NetworkError?
    var outboundAbortError: NetworkError?

    public func waitForInboundAborted(
        completion: @escaping (inout NetworkContext.EventContext, NetworkError?) -> Void
    ) {
        if self.inboundAborted {
            // Already aborted, so this is an external entry point: acquire the state.
            fromExternal { eventContext in
                completion(&eventContext, self.inboundAbortError)
            }
            return
        }
        completions.inboundAborted = completion
    }

    /// Registers a completion that does not need the event context.
    public func waitForInboundAborted(completion: @escaping (NetworkError?) -> Void) {
        waitForInboundAborted { _, error in completion(error) }
    }

    public func waitForOutboundAborted(
        completion: @escaping (inout NetworkContext.EventContext, NetworkError?) -> Void
    ) {
        if self.outboundAborted {
            fromExternal { eventContext in
                completion(&eventContext, self.outboundAbortError)
            }
            return
        }
        completions.outboundAborted = completion
    }

    /// Registers a completion that does not need the event context.
    public func waitForOutboundAborted(completion: @escaping (NetworkError?) -> Void) {
        waitForOutboundAborted { _, error in completion(error) }
    }

    public func write(_ bytes: [UInt8], sendFIN: Bool = false, earlyData: Bool = false) -> Bool {
        fromExternal { eventContext in
            write(bytes, sendFIN: sendFIN, earlyData: earlyData, in: &eventContext)
        }
    }

    /// Writes using an event context the caller already holds.
    public func write(
        _ bytes: [UInt8],
        sendFIN: Bool = false,
        earlyData: Bool = false,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        do throws(NetworkError) {
            var frame = Frame(count: bytes.count)
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.span(bytes.span.bytes)
            }
            guard result.isValid else {
                log.error("Serializing to frame failed")
                return false
            }
            if sendFIN {
                frame.metadataComplete = true
                frame.connectionComplete = true
            }
            if earlyData {
                try invokeSendEarlyStreamData(.init(frame: frame), in: &eventContext)
            } else {
                try invokeSendStreamData(.init(frame: frame), in: &eventContext)
            }
            return true
        } catch {
            return false
        }
    }

    public var receivedFIN: Bool = false

    public func readAndDrop(upTo maximumBytes: Int = Int.max) -> Int {
        fromExternal { eventContext in
            readAndDrop(upTo: maximumBytes, in: &eventContext)
        }
    }

    /// Reads and discards inbound data, using an event context the caller already holds.
    ///
    /// Inbound-data and new-flow completions run inline while the delivering event holds the
    /// state, so they have to use this rather than `readAndDrop(upTo:)`.
    public func readAndDrop(upTo maximumBytes: Int = Int.max, in eventContext: inout NetworkContext.EventContext) -> Int {
        do throws(NetworkError) {
            guard
                var frames = try invokeReceiveStreamData(
                    minimumBytes: 1,
                    maximumBytes: maximumBytes,
                    in: &eventContext
                )
            else {
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
        fromExternal { eventContext in
            read(upTo: maximumBytes, in: &eventContext)
        }
    }

    /// Reads using an event context the caller already holds.
    ///
    /// Inbound-data completions run inline while the delivering event holds the state, so they
    /// have to use this rather than `read(upTo:)`.
    public func read(upTo maximumBytes: Int = Int.max, in eventContext: inout NetworkContext.EventContext) -> [UInt8]? {
        do throws(NetworkError) {
            guard
                var frames = try invokeReceiveStreamData(
                    minimumBytes: 1,
                    maximumBytes: maximumBytes,
                    in: &eventContext
                )
            else {
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
        fromExternal { eventContext in
            do throws(NetworkError) {
                try lower.invokeAbortInbound(error: error, for: identifier, in: &eventContext)
            } catch {
                log.error("Failed to abort inbound: \(error)")
            }
        }
    }

    public func abortOutbound(error: NetworkError?) {
        fromExternal { eventContext in
            do throws(NetworkError) {
                try lower.invokeAbortOutbound(error: error, for: identifier, in: &eventContext)
            } catch {
                log.error("Failed to abort outbound: \(error)")
            }
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class LowerHarness<LinkageFamily: DataLinkageFamily>: BottomProtocolHandler, LoggableProtocol {
    public typealias UpperProtocol = LinkageFamily.Upper
    public typealias LinkageType = LinkageFamily.Lower

    public var log = NetworkLoggerState()
    public private(set) var context: NetworkContext

    public var identifier: InstanceIdentifier
    public var upper = UpperProtocol()

    public var eventManager = ProtocolEventManager()

    // Tests inspect the queued outbound frames directly, so this is part of the harness's surface.
    public var pendingOutboundPackets = FrameArray()
    var pendingInboundPackets = FrameArray()

    public init(
        identifier: String = "",
        context: NetworkContext
    ) {
        log.logPrefix = "[LowerHarness:\(identifier)]"
        self.context = context
        self.identifier = .init(context: context, eventManager: &self.eventManager)
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
        return [UInt8](copyingSpan: bytes.span, maxCount: bytes.count)
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
public class DatagramLowerHarness<LinkageFamily: DatagramLinkageFamily>: LowerHarness<LinkageFamily>, BottomDatagramProtocol {
    
    public var maximumOutputSize = 1500

    public func receiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        let array = pendingInboundPackets.drainArray(maximumFrameCount: maximumDatagramCount)
        log.debug("Deliver inbound datagram count: \(array.count)")
        return array
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        let frameSize = min(minimumDatagramSize, self.maximumOutputSize)
        var frameArray = FrameArray(capacity: maximumDatagramCount)
        for _ in 0..<maximumDatagramCount {
            let frame = Frame(count: frameSize)
            frameArray.add(frame: frame)
        }
        return frameArray
    }

    public func sendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        pendingOutboundPackets.add(frames: datagrams)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class StreamLowerHarness<LinkageFamily: StreamLinkageFamily>: LowerHarness<LinkageFamily>, BottomStreamProtocol {

    public func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        pendingInboundPackets.drainArray(maximumByteCount: maximumBytes)
    }

    public func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        Int.max
    }

    public func sendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        pendingOutboundPackets.add(frames: streamData)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class NewFlowHarness<LinkageFamily: DataLinkageFamily, HarnessType: UpperHarnessProtocol>: InboundFlowHandler,
    LoggableProtocol
where
    // The harness this one creates per inbound flow sits on the flow linkage that the listener
    // hands back, so its lower protocol has to be the family's own data linkage. Stating it
    // here is what lets `attachUpperProtocolToExistingFlow`'s result be assigned to the new
    // harness's `lower`.
    LinkageFamily.Listener.PairedUpperLinkage.DataLinkage == LinkageFamily.Lower,
    HarnessType.LowerProtocol == LinkageFamily.Lower,
    HarnessType.LinkageType == LinkageFamily.Upper
{
    public typealias LowerProtocol = LinkageFamily.Listener
    typealias HarnessType = HarnessType

    public var eventManager = ProtocolEventManager()

    public var log = NetworkLoggerState()
    public private(set) var context: NetworkContext

    public var identifier: InstanceIdentifier
    var lower = LowerProtocol()

    public var upperHarnesses: [HarnessType] = []

    var local: Endpoint
    var remote: Endpoint
    var parameters: Parameters
    var path: PathProperties

    public struct Completions {
        var createNewFlowHandler: ((inout NetworkContext.EventContext) -> (HarnessType, HarnessType.LinkageType))?
        // Runs inline while the delivering event holds the event context, so it takes the
        // state and must thread it into any call back into the stack.
        public var connected: ((inout NetworkContext.EventContext, Bool) -> Void)?
        public var disconnected: (() -> Void)?
        // Runs inline while the new-inbound-flow event holds the event context, so the
        // completion receives it and must thread it into any calls on the new flow.
        var newFlow = Deque<((inout NetworkContext.EventContext) -> Void)>()
        public var error: ((NetworkError) -> Void)?  // invoked when error detected
        public var pathChanged: ((QUICPathInfo) -> Void)?
        public var pathValidated: ((QUICPathInfo) -> Void)?
        public var pathUnreachable: ((QUICPathInfo) -> Void)?
        public init() {}
    }
    public var completions: Completions = .init()

    public var receivedConnected = false
    public var receivedDisconnected = false

    public func attachLowerProtocol(
        _ lowerProtocol: LowerProtocol,
    ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage? {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        lower = lowerProtocol
        return nil
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received connected event")
        self.receivedConnected = true
        if let completion = completions.connected {
            self.completions.connected = nil
            completion(&eventContext, true)
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received disconnected event, \(error?.description ?? "<no error>")")
        receivedDisconnected = true
        if let completion = completions.connected {
            self.completions.connected = nil
            completion(&eventContext, false)
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

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug(
            "Received new inbound flow event with instance \(flowInstance) with flowMetadata: \(flowMetadata.debugDescription)"
        )
        guard let createNewFlowHandler = completions.createNewFlowHandler else {
            log.error("Received new inbound flow event but no handler was set")
            return
        }
        do throws(NetworkError) {
            var (newUpperHarness, upperLinkage) = createNewFlowHandler(&eventContext)
            newUpperHarness.lower = try lower.invokeAttachUpperProtocolToExistingFlow(upperLinkage, existingFlowInstance: flowInstance)
            upperHarnesses.append(newUpperHarness)
            newUpperHarness.flowMetadata = flowMetadata
            newUpperHarness.invokeConnect(in: &eventContext)
            if let newFlowCompletion = completions.newFlow.popFirst() {
                newFlowCompletion(&eventContext)
            }
        } catch {
            log.error("Failed to attach new inbound flow")
            return
        }
    }


    public var newInboundCIDEventCount = 0
    public var newOutboundCIDEventCount = 0
    public var retiredOutboundCIDEventCount = 0
    #if !NETWORK_NO_SWIFT_QUIC
    public var lastNewOutboundConnectionID: QUICConnectionID?
    public var lastNewOutboundStatelessResetToken: QUICStatelessResetToken?
    public var lastRetiredOutboundConnectionID: QUICConnectionID?
    public var lastRetiredOutboundStatelessResetToken: QUICStatelessResetToken?
    #endif
    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received network protocol event: \(event)")
        #if !NETWORK_NO_SWIFT_QUIC
        if let quicEvent = event.quicEvent {
            switch quicEvent {
            case .newInboundConnectionID: newInboundCIDEventCount += 1
            case .newOutboundConnectionID(let connectionID, let statelessResetToken):
                newOutboundCIDEventCount += 1
                lastNewOutboundConnectionID = connectionID
                lastNewOutboundStatelessResetToken = statelessResetToken
            case .retiredOutboundConnectionID(let connectionID, let statelessResetToken):
                retiredOutboundCIDEventCount += 1
                lastRetiredOutboundConnectionID = connectionID
                lastRetiredOutboundStatelessResetToken = statelessResetToken
            case .pathChanged(let info):
                if let completion = completions.pathChanged {
                    completion(info)
                }
            case .pathValidated(let info):
                if let completion = completions.pathValidated {
                    completion(info)
                }
            case .pathUnreachable(let info):
                if let completion = completions.pathUnreachable {
                    completion(info)
                }
            default: break
            }
        }
        #endif
    }

    public func teardown() {
        for upperHarness in upperHarnesses {
            upperHarness.teardown()
        }
        upperHarnesses.removeAll()
        fromExternal { eventContext in
            do throws(NetworkError) {
                try lower.invokeDetach(for: identifier, in: &eventContext)
                lower = .init()
            } catch {
                log.error("Failed to detach lower protocol: \(error)")
            }
        }
    }

    public init(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        createNewFlowHandler: @escaping ((inout NetworkContext.EventContext) -> (HarnessType, HarnessType.LinkageType))
    ) {
        log.logPrefix = "[NewFlowHarness:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        self.identifier = .init(context: context, eventManager: &self.eventManager)
        completions.createNewFlowHandler = createNewFlowHandler
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

    public func start() {
        fromExternal { eventContext in
            lower.invokeConnect(for: identifier, in: &eventContext)
        }
    }

    public func start(_ completion: @escaping (inout NetworkContext.EventContext, Bool) -> Void) {
        completions.connected = completion
        start()
    }

    /// Starts with a completion that does not need the event context.
    public func start(_ completion: @escaping (Bool) -> Void) {
        completions.connected = { _, connected in completion(connected) }
        start()
    }

    public func stop(error: NetworkError? = nil) {
        fromExternal { eventContext in
            lower.invokeDisconnect(error: error, for: identifier, in: &eventContext)
        }
    }

    public func waitForNewFlow(
        completion: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        completions.newFlow.append(completion)
    }

    /// Registers a completion that does not need the event context.
    public func waitForNewFlow(completion: @escaping () -> Void) {
        completions.newFlow.append { _ in completion() }
    }

    public func invokeApplicationEvent(_ event: ApplicationEvent) {
        fromExternal { eventContext in
            lower.invokeApplicationEvent(event: event, for: identifier, in: &eventContext)
        }
    }

    final public func getMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        fromExternal { eventContext in
            getMetadata(in: &eventContext)
        }
    }

    /// Reads metadata using an event context the caller already holds.
    final public func getMetadata<P: NetworkProtocol>(
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        guard let metadata = lower.invokeGetMetadata(for: identifier, in: &eventContext) as? ProtocolMetadata<P> else {
            return nil
        }
        return metadata
    }

    final public func getMetrics(requestedNetworkMetric: RequestedNetworkMetrics) -> NetworkMetrics? {
        fromExternal { eventContext in
            lower.invokeGetMetrics(requestedNetworkMetric: requestedNetworkMetric, for: identifier, in: &eventContext)
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class NewDatagramFlowHarness<LinkageFamily: DatagramLinkageFamily>: NewFlowHarness<LinkageFamily, DatagramUpperHarness<LinkageFamily>> { }

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class NewStreamFlowHarness<LinkageFamily: StreamLinkageFamily>: NewFlowHarness<LinkageFamily, StreamUpperHarness<LinkageFamily>> { }

#endif
