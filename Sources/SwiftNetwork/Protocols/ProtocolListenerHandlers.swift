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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundFlowHandler: ~Copyable, UpperProtocolHandler {
    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ListenerHandler: ~Copyable, LowerProtocolHandler where UpperProtocol: InboundFlowLinkage {
    associatedtype Flow: LowerProtocolHandler

    // Create a new flow
    mutating func attachUpperProtocolToNewFlow(
        _ upperProtocol: Flow.UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Flow.UpperProtocol.PairedLowerLinkage

    // Attach to an inbound flow
    mutating func attachUpperProtocolToExistingFlow(
        _ upperProtocol: Flow.UpperProtocol,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> Flow.UpperProtocol.PairedLowerLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DatagramListenerHandler: ~Copyable, ListenerHandler
where UpperProtocol.DataLinkage: OutboundDatagramLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StreamListenerHandler: ~Copyable, ListenerHandler
where UpperProtocol: InboundStreamFlowLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol HeterogeneousListenerHandler: ~Copyable, ListenerHandler {
    associatedtype SecondaryUpperProtocol: InboundFlowLinkage

    associatedtype SecondaryFlow: LowerProtocolHandler

    // Create a new flow
    mutating func attachUpperProtocolToNewFlow(
        _ upperProtocol: SecondaryFlow.UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> SecondaryFlow.UpperProtocol.PairedLowerLinkage

    // Attach to an inbound flow
    mutating func attachUpperProtocolToExistingFlow(
        _ upperProtocol: SecondaryFlow.UpperProtocol,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> SecondaryFlow.UpperProtocol.PairedLowerLinkage
}
