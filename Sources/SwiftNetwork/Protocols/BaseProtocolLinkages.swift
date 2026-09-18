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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramLinkageFamily: DatagramLinkageFamily {
    public typealias Upper = BaseDatagramUpper
    public typealias Lower = BaseDatagramLower
    public typealias Listener = BaseDatagramListener
    public typealias InboundFlow = BaseDatagramInboundFlow
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamLinkageFamily: StreamLinkageFamily {
    public typealias Upper = BaseStreamUpper
    public typealias Lower = BaseStreamLower
    public typealias Listener = BaseStreamListener
    public typealias InboundFlow = BaseStreamInboundFlow
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseInboundDatagramLinkage<Group: LinkageFamilyGroup>: InboundDatagramLinkage, @unchecked Sendable{
    enum ProtocolType: Hashable {
        case unknown
        case udp(NetworkStateIndex)
        case ip(NetworkStateIndex)
        case tcp(NetworkStateIndex)
        case demux(NetworkStateIndex)
        case datagramEndpointFlow(ProtocolInstanceBox<DatagramEndpointFlowProtocol<Group.DatagramFamily>>)
        case quicPath(ProtocolInstanceBox<QUICPath<Group>>)
    }

    public func invokeAttachLowerProtocol(_ lowerProtocol: Group.DatagramFamily.Lower, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        let overrideUpperLinkage: Group.DatagramFamily.Upper?
        switch protocolType {
        case .udp(let index): overrideUpperLinkage = try storage!.udpInstances[index].attachLowerProtocol(lowerProtocol)
        case .demux(let index): overrideUpperLinkage = try storage!.demuxInstances[index].attachLowerProtocol(lowerProtocol)
        case .ip(let index): overrideUpperLinkage = try storage!.ipInstances[index].attachLowerProtocol(lowerProtocol)
        case .tcp(let index): overrideUpperLinkage = try storage!.tcpInstances[index].attachLowerProtocol(lowerProtocol)
        case .datagramEndpointFlow(let box):
            var flow = box.instance
            overrideUpperLinkage = try flow.attachLowerProtocol(lowerProtocol)
        case .quicPath(let box):
            var path = box.instance
            overrideUpperLinkage = try path.attachLowerProtocol(lowerProtocol)
        default: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
        let upperLinkage = overrideUpperLinkage ?? Group.family(for: self)
        try lowerProtocol.invokeAttachUpperProtocol(upperLinkage, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .demux(let index): storage!.demuxInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .tcp(let index): storage!.tcpInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .datagramEndpointFlow(let box):
            box.instance.handleConnectedEvent(for: instance, in: &eventContext)
        case .quicPath(let box):
            box.instance.handleConnectedEvent(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleConnectedEvent call")
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index):
            storage!.udpInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .demux(let index):
            storage!.demuxInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .ip(let index):
            storage!.ipInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .tcp(let index):
            storage!.tcpInstances[index].handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .datagramEndpointFlow(let box):
            box.instance.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .quicPath(let box):
            box.instance.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleDisconnectedEvent call")
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index):
            storage!.udpInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .demux(let index):
            storage!.demuxInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .ip(let index):
            storage!.ipInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .tcp(let index):
            storage!.tcpInstances[index].handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .datagramEndpointFlow(let box):
            box.instance.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .quicPath(let box):
            var protocolInstance = box.instance
            protocolInstance.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index):
            storage!.udpInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .demux(let index):
            storage!.demuxInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .ip(let index):
            storage!.ipInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .tcp(let index):
            storage!.tcpInstances[index].handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .datagramEndpointFlow(let box):
            box.instance.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .quicPath(let box):
            var protocolInstance = box.instance
            protocolInstance.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleInboundDataAvailableEvent call")
        }
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index):
            storage!.udpInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .demux(let index):
            storage!.demuxInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .ip(let index):
            storage!.ipInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .tcp(let index):
            storage!.tcpInstances[index].handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .datagramEndpointFlow(let box):
            box.instance.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .quicPath(let box):
            var protocolInstance = box.instance
            protocolInstance.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleOutboundRoomAvailableEvent call")
        }
    }

    public typealias PairedLowerLinkage = Group.DatagramFamily.Lower

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseOutboundDatagramLinkage<Group: LinkageFamilyGroup>: OutboundDatagramLinkage, @unchecked Sendable{
    enum ProtocolType: Hashable {
        case unknown
        case udp(NetworkStateIndex)
        case ip(NetworkStateIndex)
        case demux(NetworkStateIndex)
        case bridgeDatagram(NetworkStateIndex)
        case socketDatagram(NetworkStateIndex)
        case quicDatagramFlow(ProtocolInstanceBox<QUICDatagramFlow<Group>>)
    }

    public func receiveDatagrams(maximumDatagramCount: Int, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .udp(let index):
            return try storage!.udpInstances[index].receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        case .demux(let index):
            return try storage!.demuxInstances[index].receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        case .ip(let index):
            return try storage!.ipInstances[index].receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            return try storage!.bridgeDatagramInstances[index].receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        case .socketDatagram(let index):
            return try storage!.socketDatagramInstances[index].receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        case .quicDatagramFlow(let box):
            var protocolInstance = box.instance
            return try protocolInstance.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
        default:
            return nil
        }
    }
    
    public func getDatagramsToSend(maximumDatagramCount: Int, minimumDatagramSize: Int, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .udp(let index):
            return try storage!.udpInstances[index].getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
        case .demux(let index):
            return try storage!.demuxInstances[index].getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
        case .ip(let index):
            return try storage!.ipInstances[index].getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            return try storage!.bridgeDatagramInstances[index].getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
        case .socketDatagram(let index):
            return try storage!.socketDatagramInstances[index].getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
        case .quicDatagramFlow(let box):
            return try box.instance.getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
        default:
            return nil
        }
    }
    
    public func sendDatagrams(_ datagrams: consuming FrameArray, from instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        switch protocolType {
        case .udp(let index):
            try storage!.udpInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .demux(let index):
            try storage!.demuxInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .ip(let index):
            try storage!.ipInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            try storage!.bridgeDatagramInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .socketDatagram(let index):
            try storage!.socketDatagramInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .quicDatagramFlow(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendDatagrams(datagrams, from: instance, in: &eventContext)
        default:
            return
        }
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].connect(for: instance, in: &eventContext)
        case .demux(let index): storage!.demuxInstances[index].connect(for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].connect(for: instance, in: &eventContext)
        case .bridgeDatagram(let index): storage!.bridgeDatagramInstances[index].connect(for: instance, in: &eventContext)
        case .socketDatagram(let index): storage!.socketDatagramInstances[index].connect(for: instance, in: &eventContext)
        case .quicDatagramFlow(let box): box.instance.connect(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(error: NetworkError?, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .demux(let index): storage!.demuxInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .bridgeDatagram(let index): storage!.bridgeDatagramInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .socketDatagram(let index): storage!.socketDatagramInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .quicDatagramFlow(let box): box.instance.disconnect(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        switch protocolType {
        case .udp(let index):
            try storage!.udpInstances[index].detach(for: instance, in: &eventContext)
        case .demux(let index):
            try storage!.demuxInstances[index].detach(for: instance, in: &eventContext)
        case .ip(let index):
            try storage!.ipInstances[index].detach(for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            try storage!.bridgeDatagramInstances[index].detach(for: instance, in: &eventContext)
        case .socketDatagram(let index):
            try storage!.socketDatagramInstances[index].detach(for: instance, in: &eventContext)
        case .quicDatagramFlow(let box):
            var protocolInstance = box.instance
            try protocolInstance.detach(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept detach call")
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .udp(let index):
            storage!.udpInstances[index].unregisterEventManager(in: &eventContext)
            storage!.udpInstances.remove(index: index)
        case .demux(let index):
            // A demux instance is shared by its default upper and one upper per pattern set,
            // which detach separately. Only release the storage once the last one has gone.
            guard storage!.demuxInstances[index].isFullyDetached else { return }
            storage!.demuxInstances[index].unregisterEventManager(in: &eventContext)
            storage!.demuxInstances.remove(index: index)
        case .ip(let index):
            storage!.ipInstances[index].unregisterEventManager(in: &eventContext)
            storage!.ipInstances.remove(index: index)
        case .bridgeDatagram(let index):
            storage!.bridgeDatagramInstances[index].unregisterEventManager(in: &eventContext)
            storage!.bridgeDatagramInstances.remove(index: index)
        case .socketDatagram(let index):
            storage!.socketDatagramInstances[index].unregisterEventManager(in: &eventContext)
            storage!.socketDatagramInstances.remove(index: index)
        case .quicDatagramFlow(let box):
            box.instance.unregisterEventManager(in: &eventContext)
        default: break
        }
    }

    public func handleApplicationEvent(event: ApplicationEvent, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .demux(let index): storage!.demuxInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .bridgeDatagram(let index): storage!.bridgeDatagramInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .socketDatagram(let index): storage!.socketDatagramInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .quicDatagramFlow(let box): box.instance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .udp(let index): return storage!.udpInstances[index].getMetadata(for: instance, in: &eventContext)
        case .demux(let index): return storage!.demuxInstances[index].getMetadata(for: instance, in: &eventContext)
        case .ip(let index): return storage!.ipInstances[index].getMetadata(for: instance, in: &eventContext)
        case .bridgeDatagram(let index): return storage!.bridgeDatagramInstances[index].getMetadata(for: instance, in: &eventContext)
        case .socketDatagram(let index): return storage!.socketDatagramInstances[index].getMetadata(for: instance, in: &eventContext)
        case .quicDatagramFlow(let box): return box.instance.getMetadata(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept getMetadata call")
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .udp(let index): return storage!.udpInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .demux(let index): return storage!.demuxInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .ip(let index): return storage!.ipInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .bridgeDatagram(let index): return storage!.bridgeDatagramInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .socketDatagram(let index): return storage!.socketDatagramInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .quicDatagramFlow(let box): return box.instance.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept getMetrics call")
        }
    }

    public func invokeAttachUpperProtocol(_ upperProtocol: Group.DatagramFamily.Upper, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        switch protocolType {
        case .udp(let index): try storage!.udpInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .demux(let index): try storage!.demuxInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .ip(let index): try storage!.ipInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .bridgeDatagram(let index): try storage!.bridgeDatagramInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .socketDatagram(let index): try storage!.socketDatagramInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .quicDatagramFlow(let box):
            var instance = box.instance
            try instance.attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        default: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }
    
    public typealias PairedUpperLinkage = Group.DatagramFamily.Upper

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramListenerLinkage<Group: LinkageFamilyGroup>: DatagramListenerLinkage{
    enum ProtocolType: Hashable {
        case unknown
        case quic(NetworkStateIndex)
    }

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public typealias PairedUpperLinkage = Group.DatagramFamily.InboundFlow

    public func invokeAttachUpperProtocol(_ upperProtocol: PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        switch protocolType {
        case .quic(let index): try storage!.quicInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        default: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public func invokeAttachUpperProtocolToNewFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        let lowerProtocol: PairedUpperLinkage.DataLinkage
        switch protocolType {
        case .quic(let index): lowerProtocol = try storage!.quicInstances[index].attachUpperProtocolToNewFlow(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        default: fatalError("Protocol cannot accept invokeAttachUpperProtocolToNewFlow call")
        }
        try upperProtocol.invokeAttachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func invokeAttachUpperProtocolToExistingFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, existingFlowInstance: InstanceIdentifier) throws(NetworkError) -> PairedUpperLinkage.DataLinkage {
        switch protocolType {
        case .quic(let index): return try storage!.quicInstances[index].attachUpperProtocolToExistingFlow(upperProtocol, existingFlowInstance: existingFlowInstance)
        default: fatalError("Protocol cannot accept invokeAttachUpperProtocolToExistingFlow call")
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .quic(let index): storage!.quicInstances[index].connect(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .quic(let index): storage!.quicInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .quic(let index): try storage!.quicInstances[index].detach(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept detach call")
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .quic(let index):
            guard storage!.quicInstances[index].isFullyDetached else { return }
            storage!.quicInstances[index].unregisterEventManager(in: &eventContext)
            storage!.quicInstances.remove(index: index)
        default: break
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .quic(let index): storage!.quicInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .quic(let index): return storage!.quicInstances[index].getMetadata(for: instance, in: &eventContext)
        default: return nil
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .quic(let index):
            return storage!.quicInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        default: return nil
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseInboundDatagramFlowLinkage<Group: LinkageFamilyGroup>: InboundDatagramFlowLinkage{
    enum ProtocolType: Hashable {
        case unknown
    }

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public typealias DataLinkage = Group.DatagramFamily.Lower
    public typealias PairedLowerLinkage = Group.DatagramFamily.Listener

    public func invokeAttachLowerProtocol(_ lowerProtocol: Group.DatagramFamily.Listener, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        let overrideUpperLinkage: Group.DatagramFamily.InboundFlow?
        switch protocolType {
        default: fatalError("Protocol cannot accept invokeAttachLowerProtocol call")
        }
        let upperLinkage = overrideUpperLinkage ?? Group.family(for: self)
        try lowerProtocol.invokeAttachUpperProtocol(upperLinkage, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleConnectedEvent call")
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleDisconnectedEvent call")
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleNewInboundFlowEvent call")
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramMultipathLinkage<Group: LinkageFamilyGroup>: DatagramMultipathLinkage, @unchecked Sendable{
    enum ProtocolType: Hashable {
        case unknown
        case quic(NetworkStateIndex)
    }

    public typealias MultipathLowerProtocol = Group.DatagramFamily.Lower

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }

    public func invokeAttachLowerProtocolForNewPath(
        _ lowerProtocol: MultipathLowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        // This is an external entry point, so acquire the event context here and thread it
        // into the protocol below.
        try identifier.fromExternal(in: &storage!.context.eventContext) { eventContext throws(NetworkError) in
            let upperLinkage: MultipathLowerProtocol.PairedUpperLinkage

            switch protocolType {
            case .quic(let index):
                upperLinkage = try storage!.quicInstances[index].attachLowerProtocolForNewPath(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path,
                    in: &eventContext
                )
            default: fatalError("Protocol cannot accept attachLowerProtocolForNewPath call")
            }
            try lowerProtocol.invokeAttachUpperProtocol(upperLinkage, remote: remote, local: local, parameters: parameters, path: path)
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseInboundStreamLinkage<Group: LinkageFamilyGroup>: InboundStreamLinkage{
    enum ProtocolType: Hashable {
        case unknown
        case streamEndpointFlow(ProtocolInstanceBox<StreamEndpointFlowProtocol<Group.StreamFamily>>)
    }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: Group.StreamFamily.Lower,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let overrideUpperLinkage: Group.StreamFamily.Upper?
        switch protocolType {
        case .streamEndpointFlow(let box):
            var flow = box.instance
            overrideUpperLinkage = try flow.attachLowerProtocol(lowerProtocol)
        default: fatalError("Protocol cannot accept attachLowerProtocol call")
        }
        let upperLinkage = overrideUpperLinkage ?? Group.family(for: self)
        try lowerProtocol.invokeAttachUpperProtocol(upperLinkage, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleConnectedEvent(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleConnectedEvent call")
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleDisconnectedEvent call")
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleInboundDataAvailableEvent call")
        }
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleOutboundRoomAvailableEvent call")
        }
    }

    public func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleInboundAbortedEvent call")
        }
    }

    public func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleOutboundAbortedEvent call")
        }
    }

    public typealias PairedLowerLinkage = Group.StreamFamily.Lower

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseOutboundStreamLinkage<Group: LinkageFamilyGroup>: OutboundStreamLinkage, @unchecked Sendable{
    enum ProtocolType: Hashable {
        case unknown
        case tcp(NetworkStateIndex)
        case bridgeStream(NetworkStateIndex)
        case customLink(NetworkStateIndex)
        case socketStream(NetworkStateIndex)
        case quicStream(ProtocolInstanceBox<QUICStreamInstance<Group>>)
    }

    public func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .tcp(let index):
            return try storage!.tcpInstances[index].receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, for: instance, in: &eventContext)
        case .bridgeStream(let index):
            return try storage!.bridgeStreamInstances[index].receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, for: instance, in: &eventContext)
        case .customLink(let index):
            return try storage!.customLinkInstances[index].receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, for: instance, in: &eventContext)
        case .socketStream(let index):
            return try storage!.socketStreamInstances[index].receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, for: instance, in: &eventContext)
        case .quicStream(let box):
            var protocolInstance = box.instance
            return try protocolInstance.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, for: instance, in: &eventContext)
        default:
            return nil
        }
    }

    public func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        switch protocolType {
        case .tcp(let index):
            return try storage!.tcpInstances[index].getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        case .bridgeStream(let index):
            return try storage!.bridgeStreamInstances[index].getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        case .customLink(let index):
            return try storage!.customLinkInstances[index].getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        case .socketStream(let index):
            return try storage!.socketStreamInstances[index].getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        case .quicStream(let box):
            return try box.instance.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        default:
            return 0
        }
    }

    public func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .tcp(let index):
            try storage!.tcpInstances[index].sendStreamData(streamData, from: instance, in: &eventContext)
        case .bridgeStream(let index):
            try storage!.bridgeStreamInstances[index].sendStreamData(streamData, from: instance, in: &eventContext)
        case .customLink(let index):
            try storage!.customLinkInstances[index].sendStreamData(streamData, from: instance, in: &eventContext)
        case .socketStream(let index):
            try storage!.socketStreamInstances[index].sendStreamData(streamData, from: instance, in: &eventContext)
        case .quicStream(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendStreamData(streamData, from: instance, in: &eventContext)
        default:
            var streamData = streamData
            streamData.finalizeAllFramesAsFailed()
            return
        }
    }

    public func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .quicStream(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendEarlyStreamData(streamData, from: instance, in: &eventContext)
        default:
            // Only QUIC supports sending data before the handshake completes.
            var streamData = streamData
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTSUP)
        }
    }

    public func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .quicStream(let box):
            box.instance.abortInbound(error: error, for: instance, in: &eventContext)
        default:
            throw NetworkError.posix(ENOTSUP)
        }
    }

    public func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .quicStream(let box):
            box.instance.abortOutbound(error: error, for: instance, in: &eventContext)
        default:
            throw NetworkError.posix(ENOTSUP)
        }
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .tcp(let index): storage!.tcpInstances[index].connect(for: instance, in: &eventContext)
        case .bridgeStream(let index): storage!.bridgeStreamInstances[index].connect(for: instance, in: &eventContext)
        case .customLink(let index): storage!.customLinkInstances[index].connect(for: instance, in: &eventContext)
        case .socketStream(let index): storage!.socketStreamInstances[index].connect(for: instance, in: &eventContext)
        case .quicStream(let box): box.instance.connect(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(error: NetworkError?, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .tcp(let index): storage!.tcpInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .bridgeStream(let index):
            storage!.bridgeStreamInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .customLink(let index):
            storage!.customLinkInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .socketStream(let index):
            storage!.socketStreamInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .quicStream(let box):
            box.instance.disconnect(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        switch protocolType {
        case .tcp(let index):
            try storage!.tcpInstances[index].detach(for: instance, in: &eventContext)
        case .bridgeStream(let index):
            try storage!.bridgeStreamInstances[index].detach(for: instance, in: &eventContext)
        case .customLink(let index):
            try storage!.customLinkInstances[index].detach(for: instance, in: &eventContext)
        case .socketStream(let index):
            try storage!.socketStreamInstances[index].detach(for: instance, in: &eventContext)
        case .quicStream(let box):
            var protocolInstance = box.instance
            try protocolInstance.detach(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept detach call")
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .tcp(let index):
            storage!.tcpInstances[index].unregisterEventManager(in: &eventContext)
            storage!.tcpInstances.remove(index: index)
        case .bridgeStream(let index):
            storage!.bridgeStreamInstances[index].unregisterEventManager(in: &eventContext)
            storage!.bridgeStreamInstances.remove(index: index)
        case .customLink(let index):
            storage!.customLinkInstances[index].unregisterEventManager(in: &eventContext)
            storage!.customLinkInstances.remove(index: index)
        case .socketStream(let index):
            storage!.socketStreamInstances[index].unregisterEventManager(in: &eventContext)
            storage!.socketStreamInstances.remove(index: index)
        case .quicStream(let box):
            box.instance.unregisterEventManager(in: &eventContext)
        default: break
        }
    }

    public func handleApplicationEvent(event: ApplicationEvent, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .tcp(let index): storage!.tcpInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .bridgeStream(let index):
            storage!.bridgeStreamInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .customLink(let index):
            storage!.customLinkInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .socketStream(let index):
            storage!.socketStreamInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .quicStream(let box):
            box.instance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .tcp(let index): return storage!.tcpInstances[index].getMetadata(for: instance, in: &eventContext)
        case .bridgeStream(let index):
            return storage!.bridgeStreamInstances[index].getMetadata(for: instance, in: &eventContext)
        case .customLink(let index):
            return storage!.customLinkInstances[index].getMetadata(for: instance, in: &eventContext)
        case .socketStream(let index):
            return storage!.socketStreamInstances[index].getMetadata(for: instance, in: &eventContext)
        case .quicStream(let box):
            return box.instance.getMetadata(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept getMetadata call")
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .tcp(let index):
            return storage!.tcpInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .bridgeStream(let index):
            return storage!.bridgeStreamInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .customLink(let index):
            return storage!.customLinkInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .socketStream(let index):
            return storage!.socketStreamInstances[index].getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        case .quicStream(let box):
            return box.instance.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept getMetrics call")
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: Group.StreamFamily.Upper,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .tcp(let index): try storage!.tcpInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .bridgeStream(let index): try storage!.bridgeStreamInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .customLink(let index): try storage!.customLinkInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .socketStream(let index): try storage!.socketStreamInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        case .quicStream(let box):
            var instance = box.instance
            try instance.attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        default: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public typealias PairedUpperLinkage = Group.StreamFamily.Upper

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamListenerLinkage<Group: LinkageFamilyGroup>: StreamListenerLinkage{
    enum ProtocolType: Hashable {
        case unknown
        case quic(NetworkStateIndex)
    }

    public typealias PairedUpperLinkage = Group.StreamFamily.InboundFlow

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: PairedUpperLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .quic(let index): try storage!.quicInstances[index].attachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        default: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public func invokeAttachUpperProtocolToNewFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        let lowerProtocol: PairedUpperLinkage.DataLinkage
        switch protocolType {
        case .quic(let index): lowerProtocol = try storage!.quicInstances[index].attachUpperProtocolToNewFlow(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
        default: fatalError("Protocol cannot accept invokeAttachUpperProtocolToNewFlow call")
        }
        try upperProtocol.invokeAttachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func invokeAttachUpperProtocolToExistingFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, existingFlowInstance: InstanceIdentifier) throws(NetworkError) -> PairedUpperLinkage.DataLinkage {
        switch protocolType {
        case .quic(let index): return try storage!.quicInstances[index].attachUpperProtocolToExistingFlow(upperProtocol, existingFlowInstance: existingFlowInstance)
        default: fatalError("Protocol cannot accept invokeAttachUpperProtocolToExistingFlow call")
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .quic(let index): storage!.quicInstances[index].connect(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .quic(let index): storage!.quicInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .quic(let index): try storage!.quicInstances[index].detach(for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept detach call")
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .quic(let index):
            guard storage!.quicInstances[index].isFullyDetached else { return }
            storage!.quicInstances[index].unregisterEventManager(in: &eventContext)
            storage!.quicInstances.remove(index: index)
        default: break
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .quic(let index): storage!.quicInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .quic(let index): return storage!.quicInstances[index].getMetadata(for: instance, in: &eventContext)
        default: return nil
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .quic(let index):
            return storage!.quicInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        default: return nil
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseInboundStreamFlowLinkage<Group: LinkageFamilyGroup>: InboundStreamFlowLinkage{
    enum ProtocolType: Hashable {
        case unknown
    }

    public typealias DataLinkage = Group.StreamFamily.Lower
    public typealias PairedLowerLinkage = Group.StreamFamily.Listener

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorageParent<Group>, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: Group.StreamFamily.Listener,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let overrideUpperLinkage: Group.StreamFamily.InboundFlow?
        switch protocolType {
        default: fatalError("Protocol cannot accept invokeAttachLowerProtocol call")
        }
        let upperLinkage = overrideUpperLinkage ?? Group.family(for: self)
        try lowerProtocol.invokeAttachUpperProtocol(upperLinkage, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleConnectedEvent call")
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleDisconnectedEvent call")
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: fatalError("Protocol cannot accept handleNewInboundFlowEvent call")
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorageParent<Group>?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias BaseNetworkProtocolStorage = BaseNetworkProtocolStorageParent<BaseLinkageFamilyGroup>

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
// The storage builds the framework's own linkages, so it is constrained to groups whose families
// are exactly those linkages. That lets it hand back `Group.DatagramFamily.Upper` and friends while
// constructing `BaseInboundDatagramLinkage<Group>` directly. Stating this on the storage rather than
// on `LinkageFamilyGroup` keeps the protocol free of a circular requirement.
open class BaseNetworkProtocolStorageParent<Group: LinkageFamilyGroup> {

    /// The context this storage's protocol instances run on.
    ///
    /// Readable by subclasses so a storage defined outside the framework can build its own
    /// protocol instances on the same context.
    public let context: NetworkContext

    public init(context: NetworkContext) {
        self.context = context
    }

    // A multipath linkage lets a protocol that spans several paths accept a new lower
    // protocol for each one. QUIC is currently the only such protocol.

    // MARK: - Stream Linkages

    internal var udpInstances = NetworkGappyArray<UDPProtocol.UDPInstance<Group.DatagramFamily>>()

    public func createUDPInstance() -> (Group.DatagramFamily.Upper, Group.DatagramFamily.Lower) {
        let instance = UDPProtocol.UDPInstance<Group.DatagramFamily>(context: context)

        let instanceIndex = udpInstances.insert(instance)

        let identifier = udpInstances[instanceIndex].identifier
        let inbound = Group.family(for: BaseInboundDatagramLinkage<Group>(identifier: identifier, storage: self, protocolType: .udp(instanceIndex)))
        let outbound = Group.family(for: BaseOutboundDatagramLinkage<Group>(identifier: identifier, storage: self, protocolType: .udp(instanceIndex)))

        return (inbound, outbound)
    }

    internal var demuxInstances = NetworkGappyArray<DemuxProtocol.DemuxInstance<Group.DatagramFamily>>()

    public func createDemuxInstance() -> (Group.DatagramFamily.Upper, Group.DatagramFamily.Lower) {
        let instance = DemuxProtocol.DemuxInstance<Group.DatagramFamily>(context: context)

        let instanceIndex = demuxInstances.insert(instance)

        let identifier = demuxInstances[instanceIndex].identifier
        let inbound = Group.family(for: BaseInboundDatagramLinkage<Group>(identifier: identifier, storage: self, protocolType: .demux(instanceIndex)))
        let outbound = Group.family(for: BaseOutboundDatagramLinkage<Group>(identifier: identifier, storage: self, protocolType: .demux(instanceIndex)))

        return (inbound, outbound)
    }

    internal var ipInstances = NetworkGappyArray<IPProtocol.IPInstance<Group.DatagramFamily>>()

    public func createIPInstance() -> (Group.DatagramFamily.Upper, Group.DatagramFamily.Lower) {
        let instance = IPProtocol.IPInstance<Group.DatagramFamily>(context: context)

        let instanceIndex = ipInstances.insert(instance)

        let identifier = ipInstances[instanceIndex].identifier
        let inbound = Group.family(for: BaseInboundDatagramLinkage<Group>(identifier: identifier, storage: self, protocolType: .ip(instanceIndex)))
        let outbound = Group.family(for: BaseOutboundDatagramLinkage<Group>(identifier: identifier, storage: self, protocolType: .ip(instanceIndex)))

        return (inbound, outbound)
    }


    internal var socketDatagramInstances = NetworkGappyArray<SocketDatagramProtocol<Group.DatagramFamily>>()

    public func createSocketDatagramInstance() -> Group.DatagramFamily.Lower {
        let instance = SocketDatagramProtocol<Group.DatagramFamily>(context: context)
        let instanceIndex = socketDatagramInstances.insert(instance)
        return Group.family(for: BaseOutboundDatagramLinkage<Group>(
            identifier: socketDatagramInstances[instanceIndex].identifier,
            storage: self,
            protocolType: .socketDatagram(instanceIndex)
        ))
    }

    internal var bridgeDatagramInstances = NetworkGappyArray< BridgeDatagramProtocol.BridgeInstance<Group.DatagramFamily>>()

    public func createBridgeDatagramInstance() -> Group.DatagramFamily.Lower {
        let instance = BridgeDatagramProtocol.BridgeInstance<Group.DatagramFamily>(context: context)
        let instanceIndex = bridgeDatagramInstances.insert(instance)

        return Group.family(for: BaseOutboundDatagramLinkage<Group>(
            identifier: instance.identifier,
            storage: self,
            protocolType: .bridgeDatagram(instanceIndex)
        ))
    }



    // Endpoint flows are referenced directly by the linkage rather than stored here: the
    // flow owns its own lifetime, so there is nothing for the storage to keep track of.
    internal static func linkage(
        for flow: DatagramEndpointFlowProtocol<Group.DatagramFamily>
    ) -> Group.DatagramFamily.Upper {
        Group.family(for: BaseInboundDatagramLinkage<Group>(
            identifier: flow.identifier,
            storage: nil,
            protocolType: .datagramEndpointFlow(.init(flow))
        ))
    }

    // MARK: - Stream Protocol Instances

    internal var tcpInstances = NetworkGappyArray<
        TCPProtocol.TCPInstance<Group.StreamFamily, Group.DatagramFamily>
    >()

    // TCP straddles the two families: stream data above, datagrams below. The returned
    // inbound linkage is therefore a *datagram* linkage, for lower protocols to attach
    // below TCP, while the outbound linkage is a *stream* linkage, for upper protocols
    // to attach above it.
    public func createTCPInstance() -> (Group.DatagramFamily.Upper, Group.StreamFamily.Lower) {
        let instance = TCPProtocol.TCPInstance<Group.StreamFamily, Group.DatagramFamily>(
            context: context
        )

        let instanceIndex = tcpInstances.insert(instance)

        let identifier = tcpInstances[instanceIndex].identifier
        let inbound = Group.family(for: BaseInboundDatagramLinkage<Group>(
            identifier: identifier,
            storage: self,
            protocolType: .tcp(instanceIndex)
        ))
        let outbound = Group.family(for: BaseOutboundStreamLinkage<Group>(identifier: identifier, storage: self, protocolType: .tcp(instanceIndex)))

        return (inbound, outbound)
    }


    internal var socketStreamInstances = NetworkGappyArray<SocketStreamProtocol<Group.StreamFamily>>()

    public func createSocketStreamInstance() -> Group.StreamFamily.Lower {
        let instance = SocketStreamProtocol<Group.StreamFamily>(context: context)
        let instanceIndex = socketStreamInstances.insert(instance)
        return Group.family(for: BaseOutboundStreamLinkage<Group>(
            identifier: socketStreamInstances[instanceIndex].identifier,
            storage: self,
            protocolType: .socketStream(instanceIndex)
        ))
    }

    internal var bridgeStreamInstances = NetworkGappyArray<BridgeStreamProtocol.BridgeInstance<Group.StreamFamily>>()

    public func createBridgeStreamInstance() -> Group.StreamFamily.Lower {
        let instance = BridgeStreamProtocol.BridgeInstance<Group.StreamFamily>(context: context)
        let instanceIndex = bridgeStreamInstances.insert(instance)

        return Group.family(for: BaseOutboundStreamLinkage<Group>(
            identifier: instance.identifier,
            storage: self,
            protocolType: .bridgeStream(instanceIndex)
        ))
    }

    internal var customLinkInstances = NetworkGappyArray<CustomLinkProtocol.CustomLinkInstance<Group.StreamFamily>>()

    public func createCustomLinkInstance() -> Group.StreamFamily.Lower {
        let instance = CustomLinkProtocol.CustomLinkInstance<Group.StreamFamily>(context: context)
        let instanceIndex = customLinkInstances.insert(instance)

        return Group.family(for: BaseOutboundStreamLinkage<Group>(
            identifier: instance.identifier,
            storage: self,
            protocolType: .customLink(instanceIndex)
        ))
    }




    // Endpoint flows are referenced directly by the linkage rather than stored here: the
    // flow owns its own lifetime, so there is nothing for the storage to keep track of.
    internal static func linkage(
        for flow: StreamEndpointFlowProtocol<Group.StreamFamily>
    ) -> Group.StreamFamily.Upper {
        Group.family(for: BaseInboundStreamLinkage<Group>(
            identifier: flow.identifier,
            storage: nil,
            protocolType: .streamEndpointFlow(.init(flow))
        ))
    }

    internal var quicInstances = NetworkGappyArray<QUICConnection<Group>>()

    public func createQUICInstance() -> (Group.StreamFamily.Listener, Group.DatagramFamily.Listener, Group.MultipathLinkageType) {
        let instance = QUICConnection<Group>(context: context)

        let instanceIndex = quicInstances.insert(instance)

        let identifier = instance.identifier
        let stream = Group.family(for: BaseStreamListenerLinkage<Group>(identifier: identifier, storage: self, protocolType: .quic(instanceIndex)))
        let datagram = Group.family(for: BaseDatagramListenerLinkage<Group>(identifier: identifier, storage: self, protocolType: .quic(instanceIndex)))
        let multipath = Group.family(for: BaseDatagramMultipathLinkage<Group>(identifier: identifier, storage: self, protocolType: .quic(instanceIndex)))

        return (stream, datagram, multipath)
    }

    public func quicInstance(for linkage: BaseStreamListenerLinkage<Group>) -> QUICConnection<Group>? {
        switch linkage.protocolType {
        case .quic(let index): return quicInstances[index]
        default: return nil
        }
    }

    public func quicInstance(for linkage: BaseDatagramListenerLinkage<Group>) -> QUICConnection<Group>? {
        switch linkage.protocolType {
        case .quic(let index): return quicInstances[index]
        default: return nil
        }
    }

    public func quicInstance(for linkage: BaseDatagramMultipathLinkage<Group>) -> QUICConnection<Group>? {
        switch linkage.protocolType {
        case .quic(let index): return quicInstances[index]
        default: return nil
        }
    }
}

// Builds the linkage that wraps a QUIC object, for any group that uses the framework's linkages.
// A group defined outside this module cannot call the linkages' internal initializer, so these
// free functions give it the same three constructions its `LinkageFamilyGroup` conformance owes.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func baseLinkage<Group: LinkageFamilyGroup>(
    forQUICStream quicStream: QUICStreamInstance<Group>
) -> BaseOutboundStreamLinkage<Group> {
    .init(identifier: quicStream.identifier, storage: nil, protocolType: .quicStream(.init(quicStream)))
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func baseLinkage<Group: LinkageFamilyGroup>(
    forQUICDatagramFlow quicDatagramFlow: QUICDatagramFlow<Group>
) -> BaseOutboundDatagramLinkage<Group> {
    .init(
        identifier: quicDatagramFlow.identifier,
        storage: nil,
        protocolType: .quicDatagramFlow(.init(quicDatagramFlow))
    )
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func baseLinkage<Group: LinkageFamilyGroup>(
    forQUICPath quicPath: QUICPath<Group>
) -> BaseInboundDatagramLinkage<Group> {
    .init(identifier: quicPath.identifier, storage: nil, protocolType: .quicPath(.init(quicPath)))
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseLinkageFamilyGroup: LinkageFamilyGroup {
    public typealias StreamFamily = BaseStreamLinkageFamily
    public typealias DatagramFamily = BaseDatagramLinkageFamily
    public typealias MultipathLinkageType = BaseDatagramMultipath


    public static func linkage(
        for quicStream: QUICStreamInstance<BaseLinkageFamilyGroup>
    ) -> BaseStreamLower {
        .init(base: baseLinkage(forQUICStream: quicStream))
    }

    public static func linkage(
        for quicDatagramFlow: QUICDatagramFlow<BaseLinkageFamilyGroup>
    ) -> BaseDatagramLower {
        .init(base: baseLinkage(forQUICDatagramFlow: quicDatagramFlow))
    }

    public static func linkage(
        for quicPath: QUICPath<BaseLinkageFamilyGroup>
    ) -> BaseDatagramUpper {
        .init(base: baseLinkage(forQUICPath: quicPath))
    }

    public static func family(
        for linkage: BaseInboundDatagramLinkage<BaseLinkageFamilyGroup>
    ) -> BaseDatagramUpper { .init(base: linkage) }

    public static func family(
        for linkage: BaseInboundDatagramFlowLinkage<BaseLinkageFamilyGroup>
    ) -> BaseDatagramInboundFlow { .init(base: linkage) }

    public static func family(
        for linkage: BaseInboundStreamLinkage<BaseLinkageFamilyGroup>
    ) -> BaseStreamUpper { .init(base: linkage) }

    public static func family(
        for linkage: BaseInboundStreamFlowLinkage<BaseLinkageFamilyGroup>
    ) -> BaseStreamInboundFlow { .init(base: linkage) }

    public static func family(
        for linkage: BaseOutboundDatagramLinkage<BaseLinkageFamilyGroup>
    ) -> BaseDatagramLower { .init(base: linkage) }

    public static func family(
        for linkage: BaseDatagramListenerLinkage<BaseLinkageFamilyGroup>
    ) -> BaseDatagramListener { .init(base: linkage) }

    public static func family(
        for linkage: BaseDatagramMultipathLinkage<BaseLinkageFamilyGroup>
    ) -> BaseDatagramMultipath { .init(base: linkage) }

    public static func family(
        for linkage: BaseOutboundStreamLinkage<BaseLinkageFamilyGroup>
    ) -> BaseStreamLower { .init(base: linkage) }

    public static func family(
        for linkage: BaseStreamListenerLinkage<BaseLinkageFamilyGroup>
    ) -> BaseStreamListener { .init(base: linkage) }
}
