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
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
// Linkage families are empty type-level tags that name a set of paired linkages. They carry
// no state, so their metatypes are safe to capture across isolation boundaries.
// A family's two linkages are each other's pair.
public protocol LinkageFamily: Sendable {
    associatedtype Upper: UpperProtocolLinkage where Upper.PairedLowerLinkage == Lower
    associatedtype Lower: LowerProtocolLinkage where Lower.PairedUpperLinkage == Upper
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DataLinkageFamily: LinkageFamily where Upper: InboundDataLinkage, Lower: OutboundDataLinkage {
    associatedtype Listener: ListenerLinkage
    associatedtype InboundFlow: InboundFlowLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DatagramLinkageFamily: DataLinkageFamily
where
    Upper: InboundDatagramLinkage,
    Lower: OutboundDatagramLinkage,
    Listener: DatagramListenerLinkage,
    InboundFlow: InboundDatagramFlowLinkage,
    InboundFlow.DataLinkage == Lower,
    Listener.PairedUpperLinkage == InboundFlow
{}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StreamLinkageFamily: DataLinkageFamily
where
    Upper: InboundStreamLinkage,
    Lower: OutboundStreamLinkage,
    Listener: StreamListenerLinkage,
    InboundFlow: InboundStreamFlowLinkage,
    InboundFlow.DataLinkage == Lower,
    Listener.PairedUpperLinkage == InboundFlow
{}

/// A strongly typed structure that identifies another protocol and dispatches functions to it.
///
/// Each linkage is paired with a matching linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ProtocolLinkage: Hashable {
    init()
    var identifier: InstanceIdentifier { get }
}

@available(Network 0.1.0, *)
extension ProtocolLinkage {
    public var isDetached: Bool {
        self.identifier.isNone
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol UpperProtocolLinkage: ProtocolLinkage {
    /// The lower linkage this upper linkage attaches to.
    associatedtype PairedLowerLinkage: LowerProtocolLinkage

    /// `invokeAttachLowerProtocol` is the general entry point to connecting protocols. It will
    /// call `invokeAttachUpperProtocol` on the lower protocol.
    func invokeAttachLowerProtocol(
        _ lowerProtocol: PairedLowerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext)
    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )

    #if !NETWORK_EMBEDDED
    /// Whether events for this linkage are handed to it on the spot, in the order they are raised,
    /// instead of through the event queues.
    ///
    /// A linkage that answers `true` must have a handler that never calls back into a protocol: it
    /// may be called while the protocol that raised the event is still running.
    var deliversInline: Bool { get }

    /// Hands the event to the linkage's handler right away. Only called when `deliversInline`.
    func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )

    /// `deliverInline(.disconnected(error))` without the event value, for the disconnect every flow
    /// ends with. Only called when `deliversInline`.
    func deliverInlineDisconnected(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )

    /// `deliverInline(.inboundDataAvailable)` without the event value, for the event every flow with
    /// data raises. Only called when `deliversInline`.
    func deliverInlineInboundDataAvailable(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    #endif
}

#if !NETWORK_EMBEDDED
/// The events a linkage can take inline. See `UpperProtocolLinkage.deliversInline`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum InlineUpperEvent {
    case connected
    case disconnected(NetworkError?)
    case network(NetworkProtocolEvent)
    case inboundDataAvailable
    case outboundRoomAvailable
    case inboundAborted(NetworkError?)
    case outboundAborted(NetworkError?)
}

@available(Network 0.1.0, *)
extension UpperProtocolLinkage {
    public var deliversInline: Bool { false }

    public func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}

    public func deliverInlineDisconnected(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        deliverInline(.disconnected(error), from: instance, in: &eventContext)
    }

    public func deliverInlineInboundDataAvailable(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        deliverInline(.inboundDataAvailable, from: instance, in: &eventContext)
    }
}
#endif

@available(Network 0.1.0, *)
extension UpperProtocolLinkage {
    public func deliverConnectedEvent(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineEvent(.connected, from: instance) {
                self.deliverInline(.connected, from: instance, in: &eventContext)
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .connected(
                instance,
                self.identifier,
                { eventContext, instance in
                    self.handleConnectedEvent(for: instance, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
    public func deliverDisconnectedEvent(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineDisconnected(from: instance) {
                self.deliverInlineDisconnected(error: error, from: instance, in: &eventContext)
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .disconnected(
                instance,
                self.identifier,
                error: error,
                { eventContext, instance, error in
                    self.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
    public func deliverNetworkProtocolEvent(
        originalInstance: InstanceIdentifier,
        selfInstance: InstanceIdentifier,
        event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineEvent(.network(event), from: originalInstance) {
                self.deliverInline(.network(event), from: originalInstance, in: &eventContext)
            }
            return
        }
        #endif
        selfInstance.deliverEventToUpperProtocol(
            event: .networkProtocolEvent(
                originalInstance,
                self.identifier,
                event: event,
                { eventContext, from, event in
                    self.handleNetworkProtocolEvent(event: event, for: from, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundDataLinkage: UpperProtocolLinkage where PairedLowerLinkage: OutboundDataLinkage {
    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@available(Network 0.1.0, *)
extension InboundDataLinkage {
    public func deliverInboundDataAvailableEvent(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineData(from: instance) {
                self.deliverInlineInboundDataAvailable(from: instance, in: &eventContext)
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .inboundDataAvailable(
                instance,
                self.identifier,
                { eventContext, instance in
                    self.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
    public func deliverOutboundRoomAvailableEvent(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineEvent(.outboundRoomAvailable, from: instance) {
                self.deliverInline(.outboundRoomAvailable, from: instance, in: &eventContext)
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .outboundRoomAvailable(
                instance,
                self.identifier,
                { eventContext, instance in
                    self.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundFlowLinkage: UpperProtocolLinkage where PairedLowerLinkage: ListenerLinkage {
    associatedtype DataLinkage: OutboundDataLinkage
    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )

    #if !NETWORK_EMBEDDED
    /// Records a new inbound flow for an inline linkage (see `UpperProtocolLinkage.deliversInline`).
    /// Attaching to the flow calls into the protocol, so it is not done on the spot: the linkage
    /// keeps the flow until its owner is outside the protocol.
    func deliverInlineNewInboundFlow(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )

    /// For an inline linkage, makes the application's side of a flow the protocol is creating, reports
    /// the flow, and returns the upper linkage the flow should use, or `nil` if the linkage is not
    /// inline. `lower` is the linkage the application reaches the flow through, and `flowTag` is the
    /// protocol's own number for the flow (for QUIC, the stream ID), which the application is told
    /// with the flow. The flow carries no metadata object: the application asks the protocol for
    /// that if it wants it.
    ///
    /// The protocol calls this while it creates the flow, so the flow has its upper before it can
    /// raise an event, and the application learns of the flow without the attach round trip (a
    /// queued marker, an attach call from the owner, and the events parked in between). Nothing in
    /// the inline linkage calls back into the protocol, which is what makes that safe.
    func makeInlineFlow(
        flowInstance: InstanceIdentifier,
        flowTag: UInt64,
        lower: DataLinkage,
        in eventContext: inout NetworkContext.EventContext
    ) -> DataLinkage.PairedUpperLinkage?
    #endif
}

#if !NETWORK_EMBEDDED
@available(Network 0.1.0, *)
extension InboundFlowLinkage {
    public func deliverInlineNewInboundFlow(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}

    public func makeInlineFlow(
        flowInstance: InstanceIdentifier,
        flowTag: UInt64,
        lower: DataLinkage,
        in eventContext: inout NetworkContext.EventContext
    ) -> DataLinkage.PairedUpperLinkage? { nil }
}
#endif

@available(Network 0.1.0, *)
extension InboundFlowLinkage {
    public func deliverNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if !instance.isNone {
                self.deliverInlineNewInboundFlow(
                    flowInstance: flowInstance,
                    flowMetadata: flowMetadata,
                    from: instance,
                    in: &eventContext
                )
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .newInboundFlow(
                instance,
                self.identifier,
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                { eventContext, instance, flowInstance, flowMetadata in
                    self.handleNewInboundFlowEvent(
                        flowInstance: flowInstance,
                        flowMetadata: flowMetadata,
                        for: instance,
                        in: &eventContext
                    )
                }
            ),
            in: &eventContext
        )
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ListenerLinkage: LowerProtocolLinkage where PairedUpperLinkage: InboundFlowLinkage {
    func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> PairedUpperLinkage.DataLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol LowerProtocolLinkage: ProtocolLinkage {
    /// The upper linkage this lower linkage attaches to.
    associatedtype PairedUpperLinkage: UpperProtocolLinkage

    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool
    func invokeAttachUpperProtocol(
        _ upperProtocol: PairedUpperLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext)
    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
    /// Releases any storage the linkage holds for the protocol instance. This runs after
    /// `detach` has returned, once the call into the protocol stack has fully unwound, so
    /// that the instance is still reachable while it is detaching.
    func teardown(in eventContext: inout NetworkContext.EventContext)
    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>?
    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics?
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundDataLinkage: LowerProtocolLinkage where PairedUpperLinkage: InboundDataLinkage {}

@available(Network 0.1.0, *)
extension LowerProtocolLinkage {
    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    public func invokeConnect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        guard !identifier.isNone else { return }
        identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext in
            self.connect(for: instance, in: &eventContext)
        }
    }

    public func invokeDisconnect(
        error: NetworkError? = nil,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !identifier.isNone else { return }
        identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext in
            self.disconnect(error: error, for: instance, in: &eventContext)
        }
    }

    public func invokeDetach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard !identifier.isNone else { return }
        try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.detach(for: instance, in: &eventContext)
        }
        // Cleanup happens after the call into the protocol stack has unwound, since the
        // instance needs to stay alive for the duration of its own detach.
        self.teardown(in: &eventContext)
    }

    public func invokeApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !identifier.isNone else { return }
        identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext in
            self.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func invokeGetMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        guard !identifier.isNone else { return nil }
        return identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext -> ProtocolMetadata<P>? in
            self.getMetadata(for: instance, in: &eventContext)
        }
    }

    public func invokeGetMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        guard !identifier.isNone else { return nil }
        return identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext -> NetworkMetrics? in
            self.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundDatagramLinkage: InboundDataLinkage where PairedLowerLinkage: OutboundDatagramLinkage {
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundDatagramLinkage: OutboundDataLinkage where PairedUpperLinkage: InboundDatagramLinkage {
    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension OutboundDatagramLinkage {
    public func invokeReceiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard !identifier.isNone else { return nil }
        return try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        }
    }

    public func invokeGetDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard !identifier.isNone else { return nil }
        return try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        }
    }

    public func invokeSendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard !identifier.isNone else {
            datagrams.finalizeAllFramesAsFailed()
            return
        }
        try identifier.handleCallFromUpperProtocol(datagrams, in: &eventContext) {
            eventContext,
            datagrams throws(NetworkError) in
            try self.sendDatagrams(datagrams, from: instance, in: &eventContext)
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundStreamLinkage: InboundDataLinkage where PairedLowerLinkage: OutboundStreamLinkage {
    func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@available(Network 0.1.0, *)
extension InboundStreamLinkage {
    public func deliverInboundAbortedEvent(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineEvent(.inboundAborted(error), from: instance) {
                self.deliverInline(.inboundAborted(error), from: instance, in: &eventContext)
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .inboundAborted(
                instance,
                self.identifier,
                error: error,
                { eventContext, instance, error in
                    self.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
    public func deliverOutboundAbortedEvent(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if !NETWORK_EMBEDDED
        if self.deliversInline {
            if eventContext.admitInlineEvent(.outboundAborted(error), from: instance) {
                self.deliverInline(.outboundAborted(error), from: instance, in: &eventContext)
            }
            return
        }
        #endif
        instance.deliverEventToUpperProtocol(
            event: .outboundAborted(
                instance,
                self.identifier,
                error: error,
                { eventContext, instance, error in
                    self.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
                }
            ),
            in: &eventContext
        )
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundStreamLinkage: OutboundDataLinkage where PairedUpperLinkage: InboundStreamLinkage {
    func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?
    func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int
    func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)

    func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)

    func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
    func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension OutboundStreamLinkage {
    public func invokeReceiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard !identifier.isNone else { return nil }
        return try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        }
    }

    public func invokeGetOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        guard !identifier.isNone else { return 0 }
        return try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        }
    }

    public func invokeSendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard !identifier.isNone else {
            streamData.finalizeAllFramesAsFailed()
            return
        }
        try identifier.handleCallFromUpperProtocol(streamData, in: &eventContext) {
            eventContext,
            streamData throws(NetworkError) in
            try self.sendStreamData(streamData, from: instance, in: &eventContext)
        }
    }

    public func invokeSendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard !identifier.isNone else {
            streamData.finalizeAllFramesAsFailed()
            return
        }
        try identifier.handleCallFromUpperProtocol(streamData, in: &eventContext) {
            eventContext,
            streamData throws(NetworkError) in
            try self.sendEarlyStreamData(streamData, from: instance, in: &eventContext)
        }
    }

    public func invokeAbortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard !identifier.isNone else { return }
        try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.abortInbound(error: error, for: instance, in: &eventContext)
        }
    }

    public func invokeAbortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard !identifier.isNone else { return }
        try identifier.handleCallFromUpperProtocol(in: &eventContext) { eventContext throws(NetworkError) in
            try self.abortOutbound(error: error, for: instance, in: &eventContext)
        }
    }

    // Optional types that may not be supported, default to error

    public func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        streamData.finalizeAllFramesAsFailed()
        throw .posix(ENOTSUP)
    }

    public func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        throw .posix(ENOTSUP)
    }

    public func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        throw .posix(ENOTSUP)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultipathLinkage: ProtocolLinkage {
    associatedtype MultipathLowerProtocol: LowerProtocolLinkage

    mutating func invokeAttachLowerProtocolForNewPath(
        _ lowerProtocol: MultipathLowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundDatagramFlowLinkage: InboundFlowLinkage where PairedLowerLinkage: DatagramListenerLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DatagramListenerLinkage: ListenerLinkage where PairedUpperLinkage: InboundDatagramFlowLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundStreamFlowLinkage: InboundFlowLinkage where PairedLowerLinkage: StreamListenerLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StreamListenerLinkage: ListenerLinkage where PairedUpperLinkage: InboundStreamFlowLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DatagramMultipathLinkage: MultipathLinkage where MultipathLowerProtocol: OutboundDatagramLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension LowerProtocolLinkage where Self: ProtocolInstanceAsLinkage, Self: LowerProtocolHandler {
    public mutating func invokeAttachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try self.attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension UpperProtocolLinkage
where Self: ProtocolInstanceAsLinkage, Self: UpperProtocolHandler, Self == Self.LowerProtocol.PairedUpperLinkage {
    public mutating func invokeAttachLowerProtocol(
        _ lowerProtocol: LowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let overrideUpperLinkage = try self.attachLowerProtocol(lowerProtocol)
        let upperLinkage = overrideUpperLinkage ?? self
        try lowerProtocol.invokeAttachUpperProtocol(
            upperLinkage,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
}
