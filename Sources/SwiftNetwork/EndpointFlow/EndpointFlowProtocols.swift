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

/// Events the stack has delivered to a flow but the flow has not yet consumed.
@available(Network 0.1.0, *)
struct EndpointFlowPendingEvents {
    /// `.some(nil)` when the connect succeeded, `.some(error)` when it failed.
    var connected: NetworkError?? = nil

    /// `true` when inbound data is available, `false` when the peer disconnected.
    var inboundDataAvailable: Bool? = nil

    /// Set when the lower layer has room for more outbound data.
    var outputRoomAvailable = false

    /// Set when the remote peer disconnects.
    var disconnected: NetworkError? = nil

    /// Flows the peer opened on a multiplexing connection, oldest first.
    ///
    /// Only inbound flow handlers record these; see `InboundEndpointFlowProtocol`.
    var inboundFlows: [PendingInboundFlow] = []

    var isEmpty: Bool {
        self.connected == nil && self.inboundDataAvailable == nil && !self.outputRoomAvailable
            && self.disconnected == nil && self.inboundFlows.isEmpty
    }
}

/// A flow the peer opened, waiting for the connection to hand it to the application.
@available(Network 0.1.0, *)
struct PendingInboundFlow {
    /// The lower-layer instance to attach to, rather than creating a new flow.
    let instance: InstanceIdentifier
    let metadata: AbstractProtocolMetadata?
}

@available(Network 0.1.0, *)
class EndpointFlowProtocol<LinkageFamily: DataLinkageFamily>: TopDatapathProtocol {
    typealias LinkageType = LinkageFamily.Upper
    typealias LowerProtocol = LinkageFamily.Lower

    // Events recorded for the owning flow, and the hook that nudges it to consume them.
    var pending = EndpointFlowPendingEvents()

    /// Asks the owning flow to drain `pending`, threading in the event context the delivering
    /// event already holds.
    ///
    /// This is a no-op when a flow call is already in progress; that call drains on its way out.
    var wakeFlow: ((inout NetworkContext.EventContext) -> Void)? = nil

    /// Records an event and asks the flow to consume it.
    private func recordEvent(
        in eventContext: inout NetworkContext.EventContext,
        _ record: (inout EndpointFlowPendingEvents) -> Void
    ) {
        record(&self.pending)
        self.wakeFlow?(&eventContext)
    }

    var log = NetworkLoggerState()

    fileprivate(set) var context: NetworkContext

    var identifier: InstanceIdentifier
    var lower = LowerProtocol()

    var eventManager = ProtocolEventManager()

    var local: Endpoint?
    var remote: Endpoint
    var parameters: Parameters
    var path: PathProperties

    init(
        identifier: String = "",
        local: Endpoint?,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) throws(NetworkError) {
        log.logPrefix = "[EndpointFlowProtocol:\(identifier)]"
        self.context = context
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        self.identifier = .init(context: context, eventManager: &self.eventManager)
    }

    func handleConnectedEvent(in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received connected event")
        recordEvent(in: &eventContext) { $0.connected = .some(nil) }
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received disconnected event")
        let disconnectError = error ?? .posix(ENOTCONN)
        recordEvent(in: &eventContext) {
            // A disconnect before the connect completed is reported as a failed connect, and it
            // also wakes any outstanding read.
            $0.connected = .some(disconnectError)
            $0.inboundDataAvailable = false
            $0.disconnected = disconnectError
        }
    }

    func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received inbound data available event")
        recordEvent(in: &eventContext) { $0.inboundDataAvailable = true }
    }

    public func handleOutboundRoomAvailableEvent(
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received outbound room available event")
        recordEvent(in: &eventContext) { $0.outputRoomAvailable = true }
    }

    public func start() {
        log.debug("Starting flow")
        invokeConnect()
    }

    public func stop() {
        log.debug("Stopping flow")
        invokeDisconnect(error: nil)
    }

    public func teardown() {
        log.debug("Tearing down flow")
        fromExternal { eventContext in
            teardown(in: &eventContext)
        }
    }

    /// Tears down using an event context the caller already holds.
    ///
    /// Completions run inline while the delivering event holds the state, so they have to use
    /// this rather than `teardown()`.
    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        self.wakeFlow = nil
        do throws(NetworkError) {
            var mutatingSelf = self
            try mutatingSelf.invokeDetach(in: &eventContext)
        } catch {
            log.error("Failed to detach lower protocol: \(error)")
        }
        // Nothing sits above a top protocol, so no lower linkage hands this instance's event
        // state back. Release it here; the retirement is deferred to whichever call still holds
        // the state, so this is safe even when reached from inside this instance's own call.
        unregisterEventManager(in: &eventContext)
    }

    public func abort(error: NetworkError? = nil) {
        log.debug("Aborting flow")
        invokeDisconnect(error: error)
    }
}

@available(Network 0.1.0, *)
final class DatagramEndpointFlowProtocol: EndpointFlowProtocol<BaseDatagramLinkageFamily>,
    TopDatagramProtocol
{
    func write(_ datagram: consuming Frame) -> Bool {
        fromExternal(datagram) { eventContext, datagram in
            write(datagram, in: &eventContext)
        }
    }

    /// Writes using an event context the caller already holds.
    ///
    /// Completions run inline while the delivering event holds the state, so they have to use
    /// this rather than `write(_:)`.
    func write(_ datagram: consuming Frame, in eventContext: inout NetworkContext.EventContext) -> Bool {
        do throws(NetworkError) {
            let length = datagram.unclaimedLength
            let frames = try lower.invokeGetDatagramsToSend(
                maximumDatagramCount: 1,
                minimumDatagramSize: length,
                for: identifier,
                in: &eventContext
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
            try lower.invokeSendDatagrams(frames, from: identifier, in: &eventContext)
            return true
        } catch {
            datagram.finalize(success: false)
            return false
        }
    }

    func readFrames(maximumFrames: Int) -> FrameArray? {
        fromExternal { eventContext in
            readFrames(maximumFrames: maximumFrames, in: &eventContext)
        }
    }

    /// Reads frames using an event context the caller already holds.
    func readFrames(maximumFrames: Int, in eventContext: inout NetworkContext.EventContext) -> FrameArray? {
        do throws(NetworkError) {
            return try lower.invokeReceiveDatagrams(
                maximumDatagramCount: maximumFrames,
                for: identifier,
                in: &eventContext
            )
        } catch {
            return nil
        }
    }

    func read() -> [UInt8]? {
        fromExternal { eventContext in
            read(in: &eventContext)
        }
    }

    /// Reads using an event context the caller already holds.
    func read(in eventContext: inout NetworkContext.EventContext) -> [UInt8]? {
        do throws(NetworkError) {
            let frames = try lower.invokeReceiveDatagrams(
                maximumDatagramCount: 1,
                for: identifier,
                in: &eventContext
            )
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

@available(Network 0.1.0, *)
final class StreamEndpointFlowProtocol: EndpointFlowProtocol<BaseStreamLinkageFamily>,
    TopStreamProtocol
{

    override public func abort(error: NetworkError? = nil) {
        log.debug("Aborting flow")
        fromExternal { eventContext in
            abort(error: error, in: &eventContext)
        }
    }

    /// Aborts using an event context the caller already holds.
    func abort(error: NetworkError? = nil, in eventContext: inout NetworkContext.EventContext) {
        do throws(NetworkError) {
            try lower.invokeAbortOutbound(error: error, for: identifier, in: &eventContext)
            try lower.invokeAbortInbound(error: error, for: identifier, in: &eventContext)
        } catch {
            log.error("Failed to abort stream: \(error)")
        }
        lower.invokeDisconnect(error: error, for: identifier, in: &eventContext)
    }

    func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        try fromExternal { eventContext throws(NetworkError) in
            try getOutboundStreamDataRoomAvailable(in: &eventContext)
        }
    }

    /// Queries outbound room using an event context the caller already holds.
    func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        try lower.invokeGetOutboundStreamDataRoomAvailable(for: self.identifier, in: &eventContext)
    }

    func write(_ frame: consuming Frame) -> Bool {
        fromExternal(frame) { eventContext, frame in
            write(frame, in: &eventContext)
        }
    }

    /// Writes using an event context the caller already holds.
    ///
    /// Completions run inline while the delivering event holds the state, so they have to use
    /// this rather than `write(_:)`.
    func write(_ frame: consuming Frame, in eventContext: inout NetworkContext.EventContext) -> Bool {
        do throws(NetworkError) {
            try lower.invokeSendStreamData(.init(frame: frame), from: self.identifier, in: &eventContext)
            return true
        } catch {
            return false
        }
    }

    func readFrames(minimumBytes: Int, maximumBytes: Int) -> FrameArray? {
        fromExternal { eventContext in
            readFrames(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
        }
    }

    /// Reads frames using an event context the caller already holds.
    func readFrames(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) -> FrameArray? {
        do throws(NetworkError) {
            return try lower.invokeReceiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: identifier,
                in: &eventContext
            )
        } catch {
            return nil
        }
    }

    func read(minimumBytes: Int, maximumBytes: Int) -> [UInt8]? {
        fromExternal { eventContext in
            read(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
        }
    }

    /// Reads using an event context the caller already holds.
    func read(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) -> [UInt8]? {
        do throws(NetworkError) {
            guard
                var frames = try lower.invokeReceiveStreamData(
                    minimumBytes: minimumBytes,
                    maximumBytes: maximumBytes,
                    for: identifier,
                    in: &eventContext
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

// MARK: - Inbound flow handlers

/// The top of a multiplexing connection's own stack, as opposed to one of its flows.
@available(Network 0.1.0, *)
class InboundEndpointFlowProtocol<LinkageFamily: DataLinkageFamily>: InboundFlowHandler, LoggableProtocol
where LinkageFamily.Listener.PairedUpperLinkage == LinkageFamily.InboundFlow {
    typealias LowerProtocol = LinkageFamily.Listener

    // Recorded for the owning flow and consumed by its drain; see `EndpointFlowPendingEvents`.
    var pending = EndpointFlowPendingEvents()
    var wakeFlow: ((inout NetworkContext.EventContext) -> Void)? = nil

    var log = NetworkLoggerState()
    private(set) var context: NetworkContext
    var identifier: InstanceIdentifier
    var eventManager = ProtocolEventManager()
    var lower = LowerProtocol()

    init(identifier: String = "", context: NetworkContext) {
        log.logPrefix = "[InboundEndpointFlowProtocol:\(identifier)]"
        self.context = context
        self.identifier = .init(context: context, eventManager: &self.eventManager)
    }

    /// Records an event and asks the flow to consume it.
    private func recordEvent(
        in eventContext: inout NetworkContext.EventContext,
        _ record: (inout EndpointFlowPendingEvents) -> Void
    ) {
        record(&self.pending)
        self.wakeFlow?(&eventContext)
    }

    func attachLowerProtocol(
        _ lowerProtocol: LowerProtocol
    ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage? {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        lower = lowerProtocol
        return nil
    }

    func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received connected event")
        recordEvent(in: &eventContext) { $0.connected = .some(nil) }
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received disconnected event")
        let disconnectError = error ?? .posix(ENOTCONN)
        recordEvent(in: &eventContext) {
            // A disconnect before the handshake completed is reported as a failed connect.
            $0.connected = .some(disconnectError)
            $0.disconnected = disconnectError
        }
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received network protocol event: \(event)")
    }

    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received new inbound flow event for instance \(flowInstance)")
        // The flow is only recorded here. Building something for the application to use means
        // creating another channel, which borrows this one's flow, so it has to happen once the
        // drain has let go of it.
        recordEvent(in: &eventContext) {
            $0.inboundFlows.append(PendingInboundFlow(instance: flowInstance, metadata: flowMetadata))
        }
    }

    /// Brings the connection up.
    public func start() {
        log.debug("Starting connection flow")
        fromExternal { eventContext in
            lower.invokeConnect(for: identifier, in: &eventContext)
        }
    }

    /// Closes the connection gracefully.
    public func stop() {
        log.debug("Stopping connection flow")
        fromExternal { eventContext in
            lower.invokeDisconnect(error: nil, for: identifier, in: &eventContext)
        }
    }

    /// Closes the connection without waiting for it to drain.
    public func abort(error: NetworkError? = nil) {
        log.debug("Aborting connection flow")
        fromExternal { eventContext in
            lower.invokeDisconnect(error: error, for: identifier, in: &eventContext)
        }
    }

    public func invokeApplicationEvent(_ event: ApplicationEvent, in eventContext: inout NetworkContext.EventContext) {
        lower.invokeApplicationEvent(event: event, for: identifier, in: &eventContext)
    }

    /// Detaches from the connection and hands this instance's event state back.
    ///
    /// Nothing sits above this, so no lower linkage releases the state on its behalf; see
    /// `TopProtocolHandler.teardown(in:)`, which this mirrors for a listener-backed instance.
    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        guard !identifier.isNone else { return }
        self.wakeFlow = nil
        do throws(NetworkError) {
            try lower.invokeDetach(for: identifier, in: &eventContext)
            lower = .init()
        } catch {
            log.error("Failed to detach lower protocol: \(error)")
        }
        unregisterEventManager(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
final class InboundStreamEndpointFlowProtocol: InboundEndpointFlowProtocol<BaseStreamLinkageFamily> {}

@available(Network 0.1.0, *)
final class InboundDatagramEndpointFlowProtocol: InboundEndpointFlowProtocol<BaseDatagramLinkageFamily> {}
