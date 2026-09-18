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

// The extension point for protocols the framework does not know about.
//
// The framework's own linkages are concrete: `BaseOutboundDatagramLinkage` names the framework's
// datagram protocols in an enum and switches on it, so every call from one framework protocol to
// the next is a direct call on a known type. That is what makes the stack fast, and it is why the
// linkages are not generic over the set of protocols that can appear in them.
//
// A module outside the framework still has to be able to put its own protocols in a stack. It does
// that by handing the framework a class that speaks the framework's concrete linkage types: the
// `External*Linkage` protocols below. Each base linkage has an `external` case holding one, so a
// framework protocol reaching a foreign protocol above or below it makes a single class-witness
// call instead of paying for an unspecialized generic.
//
// The direction matters. A foreign module wraps the base linkages in its own linkage type and calls
// straight into them, so its calls *into* the framework are direct too. Only the framework's calls
// back *out* go through one of these, and only for the protocols that module added.

// Embedded Swift has no `any` existentials, so this whole extension point is unavailable there: an
// embedded stack is limited to the protocols the framework itself provides. Everything below, and
// every `external` case in `BaseProtocolLinkages.swift`, is compiled out for that configuration.
#if !NETWORK_EMBEDDED

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalProtocolLinkage: AnyObject {
    var identifier: InstanceIdentifier { get }
}

// MARK: - Upper linkages

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalUpperProtocolLinkage: ExternalProtocolLinkage {
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
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalInboundDataLinkage: ExternalUpperProtocolLinkage {
    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalInboundDatagramLinkage: ExternalInboundDataLinkage {
    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalInboundStreamLinkage: ExternalInboundDataLinkage {
    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

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

// MARK: - Inbound flow linkages

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalInboundFlowLinkage: ExternalUpperProtocolLinkage {
    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalInboundDatagramFlowLinkage: ExternalInboundFlowLinkage {
    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseDatagramListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalInboundStreamFlowLinkage: ExternalInboundFlowLinkage {
    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
}

// MARK: - Lower linkages

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalLowerProtocolLinkage: ExternalProtocolLinkage {
    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool
    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext)
    func disconnect(error: NetworkError?, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext)
    func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError)
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
public protocol ExternalOutboundDatagramLinkage: ExternalLowerProtocolLinkage {
    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

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
public protocol ExternalOutboundStreamLinkage: ExternalLowerProtocolLinkage {
    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

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

// MARK: - Listener linkages

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalDatagramListenerLinkage: ExternalLowerProtocolLinkage {
    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: BaseInboundDatagramLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> BaseOutboundDatagramLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalStreamListenerLinkage: ExternalLowerProtocolLinkage {
    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundStreamFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: BaseInboundStreamLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> BaseOutboundStreamLinkage
}

// MARK: - Multipath linkages

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ExternalDatagramMultipathLinkage: ExternalProtocolLinkage {
    func invokeAttachLowerProtocolForNewPath(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
}

#endif  // !NETWORK_EMBEDDED
