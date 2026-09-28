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

// The datagram linkages dispatch through an existential rather than a switch.
//
// `BaseInboundDatagramLinkage` and `BaseOutboundDatagramLinkage` used to hold a `ProtocolType` enum
// with one case per framework protocol, and every method switched over it. Adding a protocol meant
// adding a case to every method of both types. Here the two linkages instead hold
// `any InboundDatagramLinkageImplementation` / `any OutboundDatagramLinkageImplementation`, and each
// protocol gets one small implementation type below that calls straight into its own instance.
//
// The linkages keep their names, their `init()`, and their `Hashable` conformance, so the linkage
// protocol hierarchy in `ProtocolLinkage.swift` is unchanged and everything holding a
// `Base*DatagramLinkage` still compiles. The existential lives *inside* the linkage rather than
// replacing it, which matters because Swift has no self-conformance: `any InboundDatagramLinkage`
// does not conform to `InboundDatagramLinkage`, so it could not satisfy `LinkageFamily`'s
// `Upper: UpperProtocolLinkage` requirement on its own.
//
// Every implementation type below must fit in an existential's inline value buffer, which is three
// words (24 bytes). Past that, each linkage copy heap-allocates a box and the change loses the
// performance it was made for. The storage-backed implementations are exactly 24 bytes: a storage
// reference, the instance's event state index, and its slot in the storage array. That is why they
// store a bare `NetworkStateIndex` instead of a whole `InstanceIdentifier` -- see
// `InstanceIdentifier.init(eventStateIndex:)` for the constraint that buys.
// `DatagramLinkageImplementationTests` asserts the sizes.

// MARK: - Implementation protocols

/// What `BaseInboundDatagramLinkage` needs from the protocol it points at.
///
/// These are deliberately the same requirements as `ExternalInboundDatagramLinkage`, so a protocol
/// from outside the framework is an implementation like any other rather than a special case.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol InboundDatagramLinkageImplementation {
    var identifier: InstanceIdentifier { get }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
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
    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

/// An inbound implementation that attaches by handing its instance the lower linkage and then
/// letting the linkage complete the pairing.
///
/// Framework protocols work this way; a foreign protocol owns its own pairing and implements
/// `invokeAttachLowerProtocol` itself, which is why this is a refinement rather than the base.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol PairingInboundDatagramLinkageImplementation: InboundDatagramLinkageImplementation {
    /// Attaches `lowerProtocol` to this protocol's instance, returning a replacement upper linkage
    /// if the instance wants the lower protocol to point somewhere other than at this linkage.
    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage?
}

@available(Network 0.1.0, *)
extension PairingInboundDatagramLinkageImplementation {
    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let overrideUpperLinkage = try attachLowerProtocol(lowerProtocol)
        let upperLinkage = overrideUpperLinkage ?? BaseInboundDatagramLinkage(implementation: self)
        try lowerProtocol.invokeAttachUpperProtocol(
            upperLinkage,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
}

/// What `BaseOutboundDatagramLinkage` needs from the protocol it points at. As with the inbound
/// side, these match `ExternalOutboundDatagramLinkage`'s requirements.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundDatagramLinkageImplementation {
    var identifier: InstanceIdentifier { get }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool
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

@available(Network 0.1.0, *)
extension OutboundDatagramLinkageImplementation {
    /// Connectedness is tracked by the event state, so only a foreign protocol needs to answer
    /// this differently.
    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }
}

// MARK: - Storage-backed implementations

// Each of these holds a storage reference, the instance's event state index, and the instance's
// slot in its storage array: three words, so the whole thing sits inline in the existential.
//
// `identifier` is rebuilt from `eventStateIndex` rather than stored, because storing a whole
// `InstanceIdentifier` would take the implementation to 32 bytes and force it onto the heap. That
// loses the parent index, so these are only usable by protocols that never call
// `setParentInstance`. `BaseNetworkProtocolStorage`'s factories check that.
//
// The identifier is a stored index rather than a lookup into the instance so that it stays
// readable after the instance has been unregistered and removed, which is what teardown relies on.

@available(Network 0.1.0, *)
struct UDPInboundLinkage: PairingInboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage? {
        try storage.udpInstances[index].attachLowerProtocol(lowerProtocol)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.udpInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.udpInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.udpInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.udpInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.udpInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct UDPOutboundLinkage: OutboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try storage.udpInstances[index].attachUpperProtocol(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.udpInstances[index].connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.udpInstances[index].disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.udpInstances[index].detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        storage.udpInstances[index].unregisterEventManager(in: &eventContext)
        storage.udpInstances.remove(index: index)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.udpInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        storage.udpInstances[index].getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        storage.udpInstances[index].getMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: instance,
            in: &eventContext
        )
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.udpInstances[index].receiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: instance,
            in: &eventContext
        )
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.udpInstances[index].getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: instance,
            in: &eventContext
        )
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.udpInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct IPInboundLinkage: PairingInboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage? {
        try storage.ipInstances[index].attachLowerProtocol(lowerProtocol)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.ipInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.ipInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.ipInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.ipInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.ipInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct IPOutboundLinkage: OutboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try storage.ipInstances[index].attachUpperProtocol(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.ipInstances[index].connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.ipInstances[index].disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.ipInstances[index].detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        storage.ipInstances[index].unregisterEventManager(in: &eventContext)
        storage.ipInstances.remove(index: index)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.ipInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        storage.ipInstances[index].getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        storage.ipInstances[index].getMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: instance,
            in: &eventContext
        )
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.ipInstances[index].receiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: instance,
            in: &eventContext
        )
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.ipInstances[index].getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: instance,
            in: &eventContext
        )
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.ipInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct DemuxInboundLinkage: PairingInboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage? {
        try storage.demuxInstances[index].attachLowerProtocol(lowerProtocol)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.demuxInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.demuxInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.demuxInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.demuxInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.demuxInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct DemuxOutboundLinkage: OutboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try storage.demuxInstances[index].attachUpperProtocol(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.demuxInstances[index].connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.demuxInstances[index].disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.demuxInstances[index].detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        // A demux instance is shared by its default upper and one upper per pattern set,
        // which detach separately. Only release the storage once the last one has gone.
        guard storage.demuxInstances[index].isFullyDetached else { return }
        storage.demuxInstances[index].unregisterEventManager(in: &eventContext)
        storage.demuxInstances.remove(index: index)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.demuxInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        storage.demuxInstances[index].getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        storage.demuxInstances[index].getMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: instance,
            in: &eventContext
        )
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.demuxInstances[index].receiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: instance,
            in: &eventContext
        )
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.demuxInstances[index].getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: instance,
            in: &eventContext
        )
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.demuxInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
    }
}

// TCP's upper linkage is a stream linkage, but IP reaches *down* to nothing and TCP sits above IP,
// so TCP appears here as the inbound datagram linkage that IP calls up through.
@available(Network 0.1.0, *)
struct TCPInboundDatagramLinkage: PairingInboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage? {
        try storage.tcpInstances[index].attachLowerProtocol(lowerProtocol)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.tcpInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.tcpInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.tcpInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.tcpInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.tcpInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct BridgeDatagramOutboundLinkage: OutboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try storage.bridgeDatagramInstances[index].attachUpperProtocol(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.bridgeDatagramInstances[index].connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.bridgeDatagramInstances[index].disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.bridgeDatagramInstances[index].detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        storage.bridgeDatagramInstances[index].unregisterEventManager(in: &eventContext)
        storage.bridgeDatagramInstances.remove(index: index)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.bridgeDatagramInstances[index].handleApplicationEvent(
            event: event,
            for: instance,
            in: &eventContext
        )
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        storage.bridgeDatagramInstances[index].getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        storage.bridgeDatagramInstances[index].getMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: instance,
            in: &eventContext
        )
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.bridgeDatagramInstances[index].receiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: instance,
            in: &eventContext
        )
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.bridgeDatagramInstances[index].getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: instance,
            in: &eventContext
        )
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.bridgeDatagramInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
    }
}

#if !NETWORK_PRIVATE && !NETWORK_STANDALONE
@available(Network 0.1.0, *)
struct SocketDatagramOutboundLinkage: OutboundDatagramLinkageImplementation {
    let storage: BaseNetworkProtocolStorage
    let eventStateIndex: NetworkStateIndex
    let index: NetworkStateIndex

    var identifier: InstanceIdentifier { InstanceIdentifier(eventStateIndex: eventStateIndex) }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try storage.socketDatagramInstances[index].attachUpperProtocol(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        storage.socketDatagramInstances[index].connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.socketDatagramInstances[index].disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.socketDatagramInstances[index].detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        storage.socketDatagramInstances[index].unregisterEventManager(in: &eventContext)
        storage.socketDatagramInstances.remove(index: index)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        storage.socketDatagramInstances[index].handleApplicationEvent(
            event: event,
            for: instance,
            in: &eventContext
        )
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        storage.socketDatagramInstances[index].getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        storage.socketDatagramInstances[index].getMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: instance,
            in: &eventContext
        )
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.socketDatagramInstances[index].receiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: instance,
            in: &eventContext
        )
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try storage.socketDatagramInstances[index].getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: instance,
            in: &eventContext
        )
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try storage.socketDatagramInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
    }
}
#endif

// MARK: - Class-backed implementations

// These protocols own their own lifetime rather than living in a storage array, so the
// implementation is just the class reference: one word, well inside the inline buffer. The
// identifier is read from the instance, so unlike the storage-backed implementations above these
// keep a parent index and are safe for multiplexed protocols.
//
// Each one is a wrapper rather than a conformance on the class itself, because the calls it forwards
// come from `mutating` protocol extensions that a class cannot satisfy directly. Assigning the
// reference to a `var` first is what the old switch arms did for the same reason; it mutates the
// local reference, not the shared instance.

@available(Network 0.1.0, *)
struct DatagramEndpointFlowInboundLinkage: PairingInboundDatagramLinkageImplementation {
    let flow: DatagramEndpointFlowProtocol

    var identifier: InstanceIdentifier { flow.identifier }

    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage? {
        var flow = flow
        return try flow.attachLowerProtocol(lowerProtocol)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        flow.handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        flow.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        flow.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        flow.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        flow.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

#if !NETWORK_NO_SWIFT_QUIC
@available(Network 0.1.0, *)
struct QUICPathInboundLinkage: PairingInboundDatagramLinkageImplementation {
    let path: QUICPath

    var identifier: InstanceIdentifier { path.identifier }

    func attachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage
    ) throws(NetworkError) -> BaseInboundDatagramLinkage? {
        var path = path
        return try path.attachLowerProtocol(lowerProtocol)
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        path.handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        path.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        var path = path
        path.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        var path = path
        path.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        var path = path
        path.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
struct QUICDatagramFlowOutboundLinkage: OutboundDatagramLinkageImplementation {
    let flow: QUICDatagramFlow

    var identifier: InstanceIdentifier { flow.identifier }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var flow = flow
        try flow.attachUpperProtocol(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        flow.connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        flow.disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        var flow = flow
        try flow.detach(for: instance, in: &eventContext)
    }

    // The flow's own lifetime is not managed here, so tearing down only unregisters its events.
    func teardown(in eventContext: inout NetworkContext.EventContext) {
        flow.unregisterEventManager(in: &eventContext)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        flow.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        flow.getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        flow.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        var flow = flow
        return try flow.receiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: instance,
            in: &eventContext
        )
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try flow.getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: instance,
            in: &eventContext
        )
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        var flow = flow
        try flow.sendDatagrams(datagrams, from: instance, in: &eventContext)
    }
}
#endif
