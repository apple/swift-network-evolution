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

// MARK: Automatic Datagram Processing

/// A protocol for automatically sending and receiving datagrams with lower protocols.
///
/// Add conformance to `AutomaticLowerDatagramProcessing` to automatically send and receive
/// datagrams from lower protocols.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol AutomaticLowerDatagramProcessing: ~Copyable, InboundDatagramHandler {
    var lower: LowerProtocol { get set }

    /// A queue of datagrams the framework sends to the lower protocol.
    ///
    /// Protocols generally don't need to access this directly.
    /// Instead, call `addToLowerSendQueue`.
    var lowerSendQueue: FrameArray { get set }

    /// A queue of datagrams that have been received from the lower protocol.
    ///
    /// Protocols should access frames from this queue in response
    /// to the `serviceLowerReceiveQueue` call.
    var lowerReceiveQueue: FrameArray { get set }

    /// A function the framework calls when the lower protocol has added datagrams to
    /// `lowerReceiveQueue`.
    ///
    /// Protocols should implement this function to customize behavior. Thread `eventContext` into any
    /// calls made to other protocols so that the state is never re-derived from the context.
    mutating func serviceLowerReceiveQueue(in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when outbound room becomes available.
    ///
    /// Protocols should implement this function to customize behavior.
    mutating func handleOutboundRoomAvailable(in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension AutomaticLowerDatagramProcessing where Self: ~Copyable {
    /// Adds datagrams to the lower send queue.
    ///
    /// Appends frames to `lowerSendQueue`.
    public mutating func addToLowerSendQueue(_ datagrams: consuming FrameArray) throws(NetworkError) {
        lowerSendQueue.add(frames: datagrams)
    }

    public mutating func addToLowerSendQueue(_ datagram: consuming Frame) {
        lowerSendQueue.add(frame: datagram)
    }

    /// Enqueues a single outbound datagram to be sent to the lower protocol.
    public mutating func enqueueOutboundDatagram(_ datagram: consuming Frame) {
        addToLowerSendQueue(datagram)
    }

    /// Enqueues a batch of outbound datagrams to be sent to the lower protocol.
    public mutating func enqueueOutboundDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        try addToLowerSendQueue(datagrams)
    }

    /// Indicates to the lower protocol that datagrams have been added to the send queue.
    ///
    /// Drains `lowerSendQueue` to the lower protocol.
    public mutating func serviceLowerSendQueue(in eventContext: inout NetworkContext.EventContext) {
        guard !lowerSendQueue.isEmpty else { return }
        try? lower.invokeSendDatagrams(
            lowerSendQueue.drainArrayKeepingCapacity(),
            from: identifier,
            in: &eventContext
        )
    }

    /// Indicates that datagrams should be read from the lower protocol.
    public mutating func resumeReadingInboundDatagrams(in eventContext: inout NetworkContext.EventContext) {
        _readInboundDatagrams(in: &eventContext)
    }
}

/// A protocol for automatically processing datagrams from upper protocols.
///
/// Add conformance to `AutomaticUpperDatagramProcessing` to automatically process datagrams
/// from upper protocols.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol AutomaticUpperDatagramProcessing: ~Copyable, OutboundDatagramHandler {
    var upper: UpperProtocol { get set }

    /// A queue of datagrams that have been sent by the upper protocol.
    ///
    /// Protocols should access frames from this queue in response
    /// to the `serviceUpperSendQueue` call.
    var upperSendQueue: FrameArray { get set }

    /// A function the framework calls when the upper protocol has added datagrams to
    /// `upperSendQueue`.
    ///
    /// Protocols should implement this function to customize behavior.
    mutating func serviceUpperSendQueue(in eventContext: inout NetworkContext.EventContext)

    /// The maximum datagram size the upper protocol can send.
    var maximumUpperDatagramSize: Int { get set }

    /// A Boolean value that indicates whether the upper protocol is blocked from sending datagrams.
    var blockUpperSendQueue: Bool { get set }

    /// A queue of datagrams the framework delivers to the upper protocol.
    ///
    /// Protocols generally don't need to access this directly.
    /// Instead, call `addToUpperReceiveQueue`.
    var upperReceiveQueue: FrameArray { get set }

}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension AutomaticUpperDatagramProcessing where Self: ~Copyable {
    /// Adds datagrams to the upper receive queue.
    ///
    /// Appends frames to `upperReceiveQueue`.
    public mutating func addToUpperReceiveQueue(_ datagrams: consuming FrameArray) throws(NetworkError) {
        upperReceiveQueue.add(frames: datagrams)
    }

    public mutating func addToUpperReceiveQueue(_ datagram: consuming Frame) {
        upperReceiveQueue.add(frame: datagram)
    }

    /// Enqueues a single inbound datagram to be delivered to the upper protocol.
    public mutating func enqueueOutboundDatagram(_ datagram: consuming Frame) {
        addToUpperReceiveQueue(datagram)
    }

    /// Enqueues a batch of inbound datagrams to be delivered to the upper protocol.
    public mutating func enqueueOutboundDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        try addToUpperReceiveQueue(datagrams)
    }

    /// Indicates to the upper protocol that datagrams have been added to the receive queue.
    ///
    /// Notifies the upper protocol that frames are available in `upperReceiveQueue`.
    public func serviceUpperReceiveQueue(in eventContext: inout NetworkContext.EventContext) {
        guard !upperReceiveQueue.isEmpty else { return }
        upper.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
    }
}

// MARK: Manual Datagram Processing

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundDatagramHandler: ~Copyable, InboundDataHandler where LowerProtocol: OutboundDatagramLinkage { }

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundDatagramHandler: ~Copyable, OutboundDataHandler where UpperProtocol: InboundDatagramLinkage {
    mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?
    mutating func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?
    mutating func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

// MARK: Implementation Details

@available(Network 0.1.0, *)
extension AutomaticLowerDatagramProcessing where Self: ~Copyable {
    mutating func _readInboundDatagrams(in eventContext: inout NetworkContext.EventContext) {
        var readCount = 0
        repeat {
            do throws(NetworkError) {
                let datagrams = try lower.invokeReceiveDatagrams(
                    maximumDatagramCount: Int.max,
                    for: identifier,
                    in: &eventContext
                )
                if let datagrams = consume datagrams {
                    readCount = datagrams.count
                    lowerReceiveQueue.add(frames: datagrams)
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
        _readInboundDatagrams(in: &eventContext)
    }

    mutating func handleOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        serviceLowerSendQueue(in: &eventContext)
        handleOutboundRoomAvailable(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension AutomaticUpperDatagramProcessing where Self: ~Copyable {
    internal func newOutboundFrame(_ dataSize: Int) -> Frame {
        Frame(count: dataSize)
    }

    public mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard !upperReceiveQueue.isEmpty else { return nil }
        return upperReceiveQueue.drainArray(maximumFrameCount: maximumDatagramCount)
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard !blockUpperSendQueue else { return nil }
        let datagramSize: Int
        if maximumUpperDatagramSize == 0 {
            datagramSize = minimumDatagramSize
        } else {
            datagramSize = min(minimumDatagramSize, maximumUpperDatagramSize)
        }
        var returnArray = FrameArray(capacity: maximumDatagramCount)
        for _ in 0..<maximumDatagramCount {
            returnArray.add(frame: newOutboundFrame(datagramSize))
        }
        return returnArray
    }

    public mutating func sendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        upperSendQueue.add(frames: datagrams)
        serviceUpperSendQueue(in: &eventContext)
    }
}
