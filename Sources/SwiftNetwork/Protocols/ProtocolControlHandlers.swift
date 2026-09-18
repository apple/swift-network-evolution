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

/// A protocol closer to the app, with a linkage to a lower protocol toward the network.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol UpperProtocolHandler<LowerProtocol>: ~Copyable, ProtocolInstance {
    associatedtype LowerProtocol: LowerProtocolLinkage

    /// Attaches the provided protocol linkage as the lower protocol of this
    /// protocol instance. The optional return value provides a paired "upper"
    /// protocol linkage that this protocol instance wants to use for the lower
    /// protocol to refer to its upper.
    mutating func attachLowerProtocol(
        _ lowerProtocol: LowerProtocol,
    ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage?

    mutating func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext)
    mutating func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    mutating func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

/// A protocol closer to the network, with a linkage to an upper protocol toward the app.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol LowerProtocolHandler<UpperProtocol>: ~Copyable, ProtocolInstance {
    associatedtype UpperProtocol: UpperProtocolLinkage

    mutating func attachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    mutating func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError)

    mutating func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext)
    mutating func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )

    mutating func handleApplicationEvent(
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
