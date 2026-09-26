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
class EndpointFlowProtocol<LinkageFamily: DataLinkageFamily>: TopDatapathProtocol {
    typealias LinkageType = LinkageFamily.Upper
    typealias LowerProtocol = LinkageFamily.Lower

    // Completions: called once!
    //
    // These run inline while the delivering event holds the event context, so each one takes the
    // state and must thread it into any call back into the stack. Calling a state-free entry
    // point from inside one of these would re-derive the state and trip exclusivity.
    struct Completions {
        public var connected: ((inout NetworkContext.EventContext, NetworkError?) -> Void)?
        public var outputRoomAvailable: ((inout NetworkContext.EventContext) -> Void)?

        // true when inbound data is available, false when disconnected
        public var inboundDataAvailable: ((inout NetworkContext.EventContext, Bool) -> Void)?

        // invoked when error detected
        public var error: ((inout NetworkContext.EventContext, NetworkError) -> Void)?

        // invoked when remote peer disconnects
        public var disconnected: ((inout NetworkContext.EventContext, NetworkError) -> Void)?
        public init() {}
    }
    var completions = Completions()

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
        if let completion = completions.connected {
            self.completions.connected = nil
            completion(&eventContext, nil)
        }
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received disconnected event")
        let disconnectError = error ?? .posix(ENOTCONN)
        if let completion = completions.connected {
            self.completions.connected = nil
            completion(&eventContext, disconnectError)
        }
        if let error, let errorCompletion = self.completions.error {
            self.completions.error = nil
            errorCompletion(&eventContext, error)
        }

        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            self.completions.inboundDataAvailable = nil
            inboundDataAvailableCompletion(&eventContext, false)
        }

        if let disconnectedCompletion = self.completions.disconnected {
            self.completions.disconnected = nil
            disconnectedCompletion(&eventContext, disconnectError)
        }
    }

    func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        log.debug("Received inbound data available event")
        // Clear the slot before invoking: the completion may synchronously
        // re-arm the waiter (when receiveStreamData returns nil because the
        // requested minimum spans more than one segment). Clearing afterwards
        // would clobber that re-registration and drop later notifications.
        if let inboundDataAvailableCompletion = self.completions.inboundDataAvailable {
            self.completions.inboundDataAvailable = nil
            inboundDataAvailableCompletion(&eventContext, true)
        }
    }

    public func handleOutboundRoomAvailableEvent(
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Received outbound room available event")
        if let completion = self.completions.outputRoomAvailable {
            self.completions.outputRoomAvailable = nil
            completion(&eventContext)
        }
    }

    public func start() {
        log.debug("Starting flow")
        invokeConnect()
    }

    public func start(_ completion: @escaping (inout NetworkContext.EventContext, NetworkError?) -> Void) {
        self.completions.connected = completion
        start()
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

    public func waitForOutputRoomAvailable(
        _ completion: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        completions.outputRoomAvailable = completion
    }

    public func waitForInboundDataAvailable(
        completion: @escaping (inout NetworkContext.EventContext, Bool) -> Void
    ) {
        completions.inboundDataAvailable = completion
    }

    public func waitForError(
        completion: @escaping (inout NetworkContext.EventContext, NetworkError) -> Void
    ) {
        completions.error = completion
    }

    public func waitForDisconnected(
        completion: @escaping (inout NetworkContext.EventContext, NetworkError) -> Void
    ) {
        completions.disconnected = completion
    }

    /// Registers a completion that does not need the event context.
    public func waitForDisconnected(completion: @escaping (NetworkError) -> Void) {
        completions.disconnected = { _, error in completion(error) }
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
