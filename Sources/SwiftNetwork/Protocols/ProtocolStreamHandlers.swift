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
    /// Protocols should implement this function to customize behavior. Thread `eventContext` into any
    /// calls made to other protocols so that the state is never re-derived from the context.
    mutating func serviceLowerReceiveQueue(in eventContext: inout NetworkContext.EventContext)
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

    public mutating func addToLowerSendQueue(_ streamData: consuming Frame) {
        lowerSendQueue.add(frame: streamData)
    }

    /// Enqueues a single outbound frame of stream data to be sent to the lower protocol.
    public mutating func enqueueOutboundFrame(_ frame: consuming Frame) {
        addToLowerSendQueue(frame)
    }

    /// Enqueues a batch of outbound stream data to be sent to the lower protocol.
    public mutating func enqueueOutboundFrameArray(_ frameArray: consuming FrameArray) throws(NetworkError) {
        try addToLowerSendQueue(frameArray)
    }

    /// Indicates to the lower protocol that stream data has been added to the send queue.
    ///
    /// Drains `lowerSendQueue` to the lower protocol.
    public mutating func serviceLowerSendQueue(in eventContext: inout NetworkContext.EventContext) {
        guard !lowerSendQueue.isEmpty else { return }
        try? lower.invokeSendStreamData(lowerSendQueue.drainArray(), from: identifier, in: &eventContext)
    }

    /// Indicates that stream data should be read from the lower protocol.
    public mutating func resumeReadingInboundStreamData(in eventContext: inout NetworkContext.EventContext) {
        _readInboundStreamData(in: &eventContext)
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
    mutating func serviceUpperSendQueue(in eventContext: inout NetworkContext.EventContext)

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
    mutating func upperReceiveQueueDrainedBytes(_ bytes: Int, in eventContext: inout NetworkContext.EventContext)
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

    public mutating func addToUpperReceiveQueue(_ streamData: consuming Frame) {
        upperReceiveQueue.add(frame: streamData)
    }

    /// Enqueues a single inbound frame of stream data to be delivered to the upper protocol.
    public mutating func enqueueOutboundFrame(_ frame: consuming Frame) {
        addToUpperReceiveQueue(frame)
    }

    /// Enqueues a batch of inbound stream data to be delivered to the upper protocol.
    public mutating func enqueueOutboundFrameArray(_ frameArray: consuming FrameArray) throws(NetworkError) {
        try addToUpperReceiveQueue(frameArray)
    }

    /// Indicates to the upper protocol that stream data has been added to the receive queue.
    ///
    /// Notifies the upper protocol that frames are available in `upperReceiveQueue`.
    public func serviceUpperReceiveQueue(in eventContext: inout NetworkContext.EventContext) {
        guard !upperReceiveQueue.isEmpty else { return }
        upper.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
    }
}

// MARK: Manual Stream Processing

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundStreamHandler: ~Copyable, InboundDataHandler where LowerProtocol: OutboundStreamLinkage {
    mutating func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    mutating func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamHandler: ~Copyable, OutboundDataHandler where UpperProtocol: InboundStreamLinkage {
    mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?
    mutating func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int
    mutating func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

// MARK: Unidirectional Stream Aborting

// Conform to this protocol to support unidirectional aborts
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamUnidirectionalAbortHandler: ~Copyable, OutboundStreamHandler {
    mutating func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    mutating func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

// MARK: Sending Early Data

// Conform to this protocol to support sending early data
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamEarlyDataHandler: ~Copyable, OutboundStreamHandler {
    mutating func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

// MARK: Implementations

@available(Network 0.1.0, *)
extension AutomaticLowerStreamProcessing where Self: ~Copyable {
    mutating func _readInboundStreamData(in eventContext: inout NetworkContext.EventContext) {
        var readCount = 0
        repeat {
            do throws(NetworkError) {
                let streamData = try lower.invokeReceiveStreamData(
                    minimumBytes: 1,
                    maximumBytes: Int.max,
                    for: identifier,
                    in: &eventContext
                )
                if let streamData = consume streamData {
                    readCount = streamData.count
                    lowerReceiveQueue.add(frames: streamData)
                } else {
                    readCount = 0
                }
            } catch {
                break
            }
            serviceLowerReceiveQueue(in: &eventContext)
            serviceLowerSendQueue(in: &eventContext)
        } while readCount != 0
    }

    mutating func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        _readInboundStreamData(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension AutomaticUpperStreamProcessing where Self: ~Copyable {
    internal func newOutboundFrame(_ dataSize: Int) -> Frame {
        Frame(count: dataSize)
    }

    public mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard !upperReceiveQueue.isEmpty else {
            return nil
        }
        let remainingBytes = upperReceiveQueue.unclaimedLength
        let complete = upperReceiveQueue.connectionComplete
        guard remainingBytes >= minimumBytes || complete else {
            return nil
        }
        defer {
            upperReceiveQueueDrainedBytes(min(remainingBytes, maximumBytes), in: &eventContext)
        }
        return upperReceiveQueue.drainArray(maximumByteCount: maximumBytes)
    }

    public mutating func upperReceiveQueueDrainedBytes(_ bytes: Int, in eventContext: inout NetworkContext.EventContext) {
        // No-op by default
    }

    public func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        guard !blockUpperSendQueue else { return 0 }
        if upperSendQueue.isEmpty { return maximumStreamDataSize }
        let pendingLength = upperSendQueue.unclaimedLength
        if pendingLength >= maximumStreamDataSize {
            return 0
        } else {
            return maximumStreamDataSize - pendingLength
        }
    }

    public mutating func sendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        upperSendQueue.add(frames: streamData)
        serviceUpperSendQueue(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension AutomaticUpperStreamProcessing where Self: ~Copyable, Self: OutboundStreamEarlyDataHandler {
    mutating func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        upperSendQueue.add(frames: streamData)
        serviceUpperSendQueue(in: &eventContext)
    }
}
