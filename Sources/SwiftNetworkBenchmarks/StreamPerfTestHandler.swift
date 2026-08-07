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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)

@_spi(Essentials) @_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class StreamPerfTestHandler: ProtocolInstanceContainer, InboundStreamHandler, LoggableProtocol {

    public typealias LowerProtocol = OutboundStreamLinkage

    // Private Constant state
    private let local: Endpoint
    private let remote: Endpoint
    private let parameters: Parameters
    private let path: PathProperties
    private let logger: LoggingHandle
    private let identifier: String

    // Public mutable state
    public var log = NetworkLoggerState()
    public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    public var eventManager = ProtocolEventManager()
    public var context: NetworkContext
    public var streamID: UInt64
    public var connected: Bool = false
    public var readAvailable: Bool = true
    public var connectedHandler: ((Bool) -> Void)?

    // Internal mutable state
    internal var errorHandler: ((NetworkError) -> Void)?
    internal var lowerProtocol = LowerProtocol(reference: .init())

    public init(
        identifier: String,
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        streamID: UInt64,
        logger: LoggingHandle
    ) {
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        self.streamID = streamID
        self.logger = logger
        self.context = parameters.context
        self.identifier = identifier
        log.logPrefix = "[\(identifier)][S\(streamID)]"
    }

    public init?(
        identifier: String,
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        streamID: UInt64,
        logger: LoggingHandle,
        listenerProtocol: StreamListenerLinkage
    ) {
        self.local = local
        self.remote = remote
        self.parameters = parameters
        self.path = path
        self.streamID = streamID
        self.logger = logger
        self.context = parameters.context
        self.identifier = identifier
        log.logPrefix = "[\(identifier)][S\(streamID)]"
        do throws(NetworkError) {
            self.lowerProtocol = try listenerProtocol.invokeAttachUpperStreamProtocolToNewFlow(
                reference,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            self.log("Error attaching lower protocol: \(error)")
            return nil
        }
    }

    // Set the streamID for new flows received by NewFlowHandler
    func setStreamID(streamID: UInt64) {
        log.logPrefix = "[\(identifier)][S\(streamID)]"
        self.streamID = streamID
    }

    // Set an error callback for the stream handler to notify the connection that an error took place
    func setErrorHandler(errorHandler: @escaping (NetworkError) -> Void) {
        self.errorHandler = errorHandler
    }

    func log(_ logMessage: @autoclosure () -> String) {
        guard self.logger.loggingType != .none else { return }
        let message = logMessage()
        self.logger.log("\(self.log.logPrefix) \(message)")
    }

    // Start the stream handler
    func start() {
        log("start")
        fromExternal {
            lowerProtocol.invokeConnect(reference)
        }
    }

    public func start(_ completion: @escaping (Bool) -> Void) {
        connectedHandler = completion
        start()
    }

    // Stop and disconnect the stream handler
    func stop() {
        log("stop")
        self.connected = false
        self.readAvailable = false
        fromExternal {
            lowerProtocol.invokeDisconnect(reference)
        }
    }

    public func teardown() {
        log("teardown")
        fromExternal {
            do throws(NetworkError) {
                try lowerProtocol.invokeDetach(reference)
                lowerProtocol = .init(reference: .init())
            } catch {
                log("Failed to detach lower protocol: \(error)")
            }
        }
    }

    public func handleInboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {}
    public func handleOutboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {}

    // Called when the stream handler receives an error and is stopping/disconnecting
    public func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        log("handleDisconnectedEvent error: \(String(describing: error))")
        guard let errorHandler = self.errorHandler,
            let networkError = error
        else {
            return
        }
        errorHandler(networkError)
    }

    // Called when data is available to be read on the stream
    // NOTE: New flows with a single read with not get this event and should optimistically read when the flow is started.
    // This event will be called for all future input available after the flow starts.
    public func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
        if !self.connected { return }
        // If input is available, read right away and buffer any available application data until its picked up by the state machine in readDataForStream
        log("received input room available")
        self.readAvailable = true
    }

    public func handleOutboundRoomAvailableEvent(_ from: ProtocolInstanceReference) {
        log("received output available")
    }

    public func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        log("received network protocol event: \(event)")
    }

    // Stream handler is in the connected state
    public func handleConnectedEvent(_ from: ProtocolInstanceReference) {
        log("connected")
        if let completion = connectedHandler {
            completion(true)
            self.connectedHandler = nil
        }
        // Set this flag at the end of the connected function to make sure the client waits long enough until the key state is ready to send data.
        self.connected = true
    }

    // Get metadata about the stream from the internal QUIC stack
    final func getMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        fromExternal {
            guard let metadata = lowerProtocol.invokeGetMetadata(reference) as? ProtocolMetadata<P> else {
                return nil
            }
            return metadata
        }
    }

    // Write to the stream
    public func write(_ bytes: [UInt8]) -> Bool {
        log("write \(bytes.count) bytes")
        return fromExternal {
            do throws(NetworkError) {
                try lowerProtocol.invokeSendStreamData(
                    reference,
                    streamData: FrameArray(frame: Frame(copyBuffer: bytes))
                )
                return true
            } catch {
                log("Failed to write with error: \(error)")
                return false
            }
        }
    }

    // Read from the stream
    public func read() -> [UInt8]? {
        log("read")
        return fromExternal {
            defer { self.readAvailable = false }
            do throws(NetworkError) {
                let frames = try lowerProtocol.invokeReceiveStreamData(
                    reference,
                    minimumBytes: 1,
                    maximumBytes: Int.max
                )
                guard var frames = frames else {
                    log("Failed to receive stream data")
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
                log("Failed to read with error: \(error)")
                return nil
            }
        }
    }
}

@available(Network 0.1.0, *)
extension StreamPerfTestHandler: UpperProtocolHandler {

    // UpperProtocolHandler conformance
    public func attachLowerStreamProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    // InboundStreamHandler conformance
    public func attachLowerStreamProtocolToExistingFlow(
        listener: StreamListenerLinkage,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    // UpperProtocolHandler conformance
    public func attachLowerProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }
}

#endif
