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

// MARK: Automatic Stream Processing

/// A protocol for automatically sending and receiving stream data with lower protocols.
///
/// Add conformance to `AutomaticLowerStreamProcessing` to automatically send and receive
/// stream data from lower protocols.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol AutomaticLowerStreamProcessing: ~Copyable, InboundStreamHandler {
    var lower: LowerProtocol { get set }

    /// A queue of stream data the framework sends to the lower protocol.
    ///
    /// Protocols generally don't need to access this directly.
    /// Instead, call `addToLowerSendQueue`.
    var lowerSendQueue: FrameArray { get set }

    /// A queue of datagrams that have been received from the lower protocol.
    ///
    /// Protocols should access frames from this queue in response
    /// to the `serviceLowerReceiveQueue` call.
    var lowerReceiveQueue: FrameArray { get set }

    /// A function the framework calls when the lower protocol has added stream data to
    /// `lowerReceiveQueue`.
    ///
    /// Protocols should implement this function to customize behavior.
    func serviceLowerReceiveQueue()
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension AutomaticLowerStreamProcessing where Self: ~Copyable {
    /// Adds stream data to the lower send queue.
    ///
    /// Appends frames to `lowerSendQueue`.
    public mutating func addToLowerSendQueue(_ streamData: consuming FrameArray) throws(NetworkError) {
        lowerSendQueue.add(frames: streamData)
    }

    /// Indicates to the lower protocol that stream data has been added to the send queue.
    ///
    /// Drains `lowerSendQueue` to the lower protocol.
    public mutating func serviceLowerSendQueue() {
        guard !lowerSendQueue.isEmpty else { return }
        try? lower.invokeSendStreamData(reference, streamData: lowerSendQueue.drainArray())
    }

    /// Indicates that stream data should be read from the lower protocol.
    public mutating func resumeReadingInboundStreamData() {
        _readInboundStreamData()
    }
}

/// A protocol for automatically processing stream data from upper protocols.
///
/// Add conformance to `AutomaticUpperStreamProcessing` to automatically process stream data
/// from upper protocols.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol AutomaticUpperStreamProcessing: ~Copyable, OutboundStreamHandler {
    var upper: UpperProtocol { get set }

    /// A queue of stream data that has been sent by the upper protocol.
    ///
    /// Protocols should access frames from this queue in response
    /// to the `serviceUpperSendQueue` call.
    var upperSendQueue: FrameArray { get set }

    /// A function the framework calls when the upper protocol has added stream data to
    /// `upperSendQueue`.
    ///
    /// Protocols should implement this function to customize behavior.
    func serviceUpperSendQueue()

    /// The maximum amount of stream data allowed to be pending in the upper send queue.
    ///
    /// Caps the total bytes pending in `upperSendQueue`.
    var maximumStreamDataSize: Int { get set }

    /// A Boolean value that indicates whether the upper protocol is blocked from sending stream data.
    var blockUpperSendQueue: Bool { get set }

    /// A queue of stream data the framework delivers to the upper protocol.
    ///
    /// Protocols generally don't need to access this directly.
    /// Instead, call `addToUpperReceiveQueue`.
    var upperReceiveQueue: FrameArray { get set }

    /// A function the framework calls when the upper protocol has read stream data out of
    /// `upperReceiveQueue`.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func upperReceiveQueueDrainedBytes(_ bytes: Int)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension AutomaticUpperStreamProcessing where Self: ~Copyable {
    /// Adds stream data to the upper receive queue.
    ///
    /// Appends frames to `upperReceiveQueue`.
    public mutating func addToUpperReceiveQueue(_ streamData: consuming FrameArray) throws(NetworkError) {
        upperReceiveQueue.add(frames: streamData)
    }

    /// Indicates to the upper protocol that stream data has been added to the receive queue.
    ///
    /// Notifies the upper protocol that frames are available in `upperReceiveQueue`.
    public func serviceUpperReceiveQueue() {
        guard !upperReceiveQueue.isEmpty else { return }
        if upper.isDetached {
            // Enqueue pending event until the stream is completely attached.
            // This will ensure that the inboundDataAvailable event is sent for all new streams carrying data
            let selfReference = self.reference
            selfReference.enqueuePendingEventForUpperProtocol(
                event: .inboundDataAvailable(selfReference, upper.reference)
            )
        } else {
            upper.deliverInboundDataAvailableEvent(reference)
        }
    }
}

// MARK: Manual Stream Processing

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundStreamHandler: ~Copyable, InboundDataHandler where LowerProtocol == OutboundStreamLinkage {
    mutating func attachLowerStreamProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    mutating func attachLowerStreamProtocolToExistingFlow(
        listener: StreamListenerLinkage,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError)

    mutating func handleInboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?)
    mutating func handleOutboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamHandler: ~Copyable, OutboundDataHandler where UpperProtocol == InboundStreamLinkage {

    mutating func attachUpperStreamProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage

    mutating func receiveStreamData(
        _ from: ProtocolInstanceReference,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws(NetworkError) -> FrameArray?
    mutating func getOutboundStreamDataRoomAvailable(_ from: ProtocolInstanceReference) throws(NetworkError) -> Int
    mutating func sendStreamData(
        _ from: ProtocolInstanceReference,
        streamData: consuming FrameArray
    ) throws(NetworkError)
}

// MARK: Unidirectional Stream Aborting

// Conform to this protocol to support unidirectional aborts
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamUnidirectionalAbortHandler: ~Copyable, OutboundStreamHandler {
    mutating func abortInbound(_ from: ProtocolInstanceReference, error: NetworkError?)
    mutating func abortOutbound(_ from: ProtocolInstanceReference, error: NetworkError?)
}

// MARK: Sending Early Data

// Conform to this protocol to support sending early data
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamEarlyDataHandler: ~Copyable, OutboundStreamHandler {
    mutating func sendEarlyStreamData(
        _ from: ProtocolInstanceReference,
        streamData: consuming FrameArray
    ) throws(NetworkError)
}

// MARK: Implementations

@available(Network 0.1.0, *)
extension AutomaticLowerStreamProcessing where Self: ~Copyable {
    mutating func _readInboundStreamData() {
        var readCount = 0
        repeat {
            do throws(NetworkError) {
                let streamData = try lower.invokeReceiveStreamData(reference, minimumBytes: 1, maximumBytes: Int.max)
                if let streamData = consume streamData {
                    readCount = streamData.count
                    lowerReceiveQueue.add(frames: streamData)
                } else {
                    readCount = 0
                }
            } catch {
                break
            }
            serviceLowerReceiveQueue()
            serviceLowerSendQueue()
        } while readCount != 0
    }

    mutating func handleInboundDataAvailableEvent() {
        _readInboundStreamData()
    }
}

@available(Network 0.1.0, *)
extension AutomaticUpperStreamProcessing where Self: ~Copyable {
    internal func newOutboundFrame(_ dataSize: Int) -> Frame {
        Frame(count: dataSize)
    }

    public mutating func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
        guard !upperReceiveQueue.isEmpty else {
            return nil
        }
        let remainingBytes = upperReceiveQueue.unclaimedLength
        let complete = upperReceiveQueue.connectionComplete
        guard remainingBytes >= minimumBytes || complete else {
            return nil
        }
        defer {
            upperReceiveQueueDrainedBytes(min(remainingBytes, maximumBytes))
        }
        return upperReceiveQueue.drainArray(maximumByteCount: maximumBytes)
    }

    public mutating func upperReceiveQueueDrainedBytes(_ bytes: Int) {
        // No-op by default
    }

    public func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        guard !blockUpperSendQueue else { return 0 }
        if upperSendQueue.isEmpty { return maximumStreamDataSize }
        let pendingLength = upperSendQueue.unclaimedLength
        if pendingLength >= maximumStreamDataSize {
            return 0
        } else {
            return maximumStreamDataSize - pendingLength
        }
    }

    public mutating func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        upperSendQueue.add(frames: streamData)
        serviceUpperSendQueue()
    }
}

@available(Network 0.1.0, *)
extension AutomaticUpperStreamProcessing where Self: ~Copyable, Self: OutboundStreamEarlyDataHandler {
    mutating func sendEarlyStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        upperSendQueue.add(frames: streamData)
        serviceUpperSendQueue()
    }
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {
    func receiveStreamData(
        _ from: ProtocolInstanceReference,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws(NetworkError) -> FrameArray? {
        guard !isNone else { return nil }
        return try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: return nil
            case .tcp(var instance):
                return try instance.receiveStreamData(from, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            case .tls(var instance):
                return try instance.receiveStreamData(from, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(var instance):
                return try instance.receiveStreamData(from, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            case .quicCrypto(let instance):
                return try instance.receiveStreamData(from, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            #if !NETWORK_NO_TESTING_HARNESS
            case .streamLowerHarness(var instance):
                return try instance.receiveStreamData(from, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessOutboundStreamHandler(at: index) { instance throws(NetworkError) in
                    try instance.receiveStreamData(from, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
                }
            #endif
            default: fatalError("Protocol cannot accept receiveStreamData call")
            }
        }
    }

    func getOutboundStreamDataRoomAvailable(_ from: ProtocolInstanceReference) throws(NetworkError) -> Int {
        guard !isNone else { return 0 }
        return try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: return 0
            case .tcp(var instance): return try instance.getOutboundStreamDataRoomAvailable(from)
            case .tls(var instance): return try instance.getOutboundStreamDataRoomAvailable(from)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(let instance): return try instance.getOutboundStreamDataRoomAvailable(from)
            case .quicCrypto(let instance): return try instance.getOutboundStreamDataRoomAvailable(from)
            #if !NETWORK_NO_TESTING_HARNESS
            case .streamLowerHarness(var instance): return try instance.getOutboundStreamDataRoomAvailable(from)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessOutboundStreamHandler(at: index) { instance throws(NetworkError) in
                    try instance.getOutboundStreamDataRoomAvailable(from)
                }
            #endif
            default: fatalError("Protocol cannot accept getOutboundStreamDataRoomAvailable call")
            }
        }
    }

    func sendStreamData(_ from: ProtocolInstanceReference, streamData: consuming FrameArray) throws(NetworkError) {
        guard !isNone else {
            streamData.finalizeAllFramesAsFailed()
            return
        }
        try self.handleCallFromUpperProtocol(streamData) { streamData throws(NetworkError) in
            switch self.reference {
            case .none:
                var streamData = streamData
                streamData.finalizeAllFramesAsFailed()
                return
            case .tcp(var instance): try instance.sendStreamData(from, streamData: streamData)
            case .tls(var instance): try instance.sendStreamData(from, streamData: streamData)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(var instance): try instance.sendStreamData(from, streamData: streamData)
            case .quicCrypto(let instance): try instance.sendStreamData(from, streamData: streamData)
            #if !NETWORK_NO_TESTING_HARNESS
            case .streamLowerHarness(var instance): try instance.sendStreamData(from, streamData: streamData)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                try container.accessOutboundStreamHandler(at: index, streamData) {
                    instance,
                    streamData throws(NetworkError) in
                    try instance.sendStreamData(from, streamData: streamData)
                }
            #endif
            default: fatalError("Protocol cannot accept sendStreamData call")
            }
        }
    }

    func sendEarlyStreamData(_ from: ProtocolInstanceReference, streamData: consuming FrameArray) throws(NetworkError) {
        guard !isNone else {
            streamData.finalizeAllFramesAsFailed()
            return
        }
        try self.handleCallFromUpperProtocol(streamData) { streamData throws(NetworkError) in
            switch self.reference {
            case .none:
                var streamData = streamData
                streamData.finalizeAllFramesAsFailed()
                return
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(var instance): try instance.sendEarlyStreamData(from, streamData: streamData)
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                try container.accessOutboundStreamEarlyDataHandler(at: index, streamData) {
                    instance,
                    streamData throws(NetworkError) in
                    try instance.sendEarlyStreamData(from, streamData: streamData)
                }
            #endif
            // Sending early stream data not supported on the protocol
            default: throw NetworkError.posix(ENOTSUP)
            }
        }
    }

    func abortInbound(_ from: ProtocolInstanceReference, error: NetworkError?) throws(NetworkError) {
        guard !isNone else { return }
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: return
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(let instance): instance.abortInbound(from, error: error)
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                container.accessOutboundStreamUnidirectionalAbortHandler(at: index) {
                    $0.abortInbound(from, error: error)
                }
            #endif
            // Unidirectional aborting not supported on the protocol
            default: throw NetworkError.posix(ENOTSUP)
            }
        }
    }

    func abortOutbound(_ from: ProtocolInstanceReference, error: NetworkError?) throws(NetworkError) {
        guard !isNone else { return }
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: return
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(let instance): instance.abortOutbound(from, error: error)
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                container.accessOutboundStreamUnidirectionalAbortHandler(at: index) {
                    $0.abortOutbound(from, error: error)
                }
            #endif
            // Unidirectional aborting not supported on the protocol
            default: throw NetworkError.posix(ENOTSUP)
            }
        }
    }

    func handleInboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        switch reference {
        case .none: return
        case .tls(var instance): instance.handleInboundAbortedEvent(from, error: error)
        case .tlsEncryptionLevel(let instance): instance.handleInboundAbortedEvent(from, error: error)
        case .streamEndpointFlow(let instance): instance.handleInboundAbortedEvent(from, error: error)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicCrypto(let instance): instance.handleInboundAbortedEvent(from, error: error)
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleInboundAbortedEvent(from, error: error)
        #endif
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            container.accessInboundStreamHandler(at: index) {
                $0.handleInboundAbortedEvent(from, error: error)
            }
        #endif
        default: fatalError("Protocol cannot accept handleInboundAbortedEvent event")
        }
    }

    func handleOutboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        switch reference {
        case .none: return
        case .tls(var instance): instance.handleOutboundAbortedEvent(from, error: error)
        case .tlsEncryptionLevel(let instance): instance.handleOutboundAbortedEvent(from, error: error)
        case .streamEndpointFlow(let instance): instance.handleOutboundAbortedEvent(from, error: error)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicCrypto(let instance): instance.handleOutboundAbortedEvent(from, error: error)
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleOutboundAbortedEvent(from, error: error)
        #endif
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            container.accessInboundStreamHandler(at: index) {
                $0.handleOutboundAbortedEvent(from, error: error)
            }
        #endif
        default: fatalError("Protocol cannot accept handleOutboundAbortedEvent event")
        }
    }
}
