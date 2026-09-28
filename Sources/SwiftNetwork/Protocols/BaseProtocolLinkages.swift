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

// The linkages the framework's stack is built from.
//
// These are concrete: each one names every protocol that can appear in a stack in an enum and
// switches on it, so a call from one protocol to the next resolves to a direct call on a known
// type. There is no extension point: a protocol that wants to take part gets a case of its own,
// which is why the test harnesses and the test multiplexing protocol are compiled into this module
// rather than layered on top of it.

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
    public typealias Upper = BaseInboundDatagramLinkage
    public typealias Lower = BaseOutboundDatagramLinkage
    public typealias Listener = BaseDatagramListenerLinkage
    public typealias InboundFlow = BaseInboundDatagramFlowLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamLinkageFamily: StreamLinkageFamily {
    public typealias Upper = BaseInboundStreamLinkage
    public typealias Lower = BaseOutboundStreamLinkage
    public typealias Listener = BaseStreamListenerLinkage
    public typealias InboundFlow = BaseInboundStreamFlowLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseInboundDatagramLinkage: InboundDatagramLinkage {
    enum ProtocolType {
        case unknown
        case udp(NetworkStateIndex)
        case ip(NetworkStateIndex)
        case tcp(NetworkStateIndex)
        case demux(NetworkStateIndex)
        case datagramEndpointFlow(ProtocolInstanceBox<DatagramEndpointFlowProtocol>)
        #if !NETWORK_NO_SWIFT_QUIC
        case quicPath(ProtocolInstanceBox<QUICPath>)
        #endif
        // A protocol from outside the framework, reached through one class call.
        #if !NETWORK_EMBEDDED
        case datagramUpperHarness(DatagramUpperHarness<BaseDatagramLinkageFamily>)
        case multiplexingPath(TestDatagramPath)
        #endif
    }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let overrideUpperLinkage: BaseInboundDatagramLinkage?
        switch protocolType {
        case .udp(let index): overrideUpperLinkage = try storage!.udpInstances[index].attachLowerProtocol(lowerProtocol)
        case .demux(let index):
            overrideUpperLinkage = try storage!.demuxInstances[index].attachLowerProtocol(lowerProtocol)
        case .ip(let index): overrideUpperLinkage = try storage!.ipInstances[index].attachLowerProtocol(lowerProtocol)
        case .tcp(let index): overrideUpperLinkage = try storage!.tcpInstances[index].attachLowerProtocol(lowerProtocol)
        case .datagramEndpointFlow(let box):
            var flow = box.instance
            overrideUpperLinkage = try flow.attachLowerProtocol(lowerProtocol)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let box):
            var path = box.instance
            overrideUpperLinkage = try path.attachLowerProtocol(lowerProtocol)
        #endif
        #if !NETWORK_EMBEDDED
        case .datagramUpperHarness(let harness):
            // The harness owns the pairing: it knows which of its own linkages to hand back, so it
            // completes the attach itself rather than reporting an override here.
            var harness = harness
            let overrideUpper = try harness.attachLowerProtocol(lowerProtocol)
            try lowerProtocol.invokeAttachUpperProtocol(
                overrideUpper ?? self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            return
        case .multiplexingPath:
            // The path's lower is bound when the path is created, so there is nothing more to do.
            return
        #endif
        case .unknown: fatalError("Protocol cannot accept attachLowerProtocol call")
        }
        let upperLinkage = overrideUpperLinkage ?? self
        try lowerProtocol.invokeAttachUpperProtocol(
            upperLinkage,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .demux(let index): storage!.demuxInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .tcp(let index): storage!.tcpInstances[index].handleConnectedEvent(for: instance, in: &eventContext)
        case .datagramEndpointFlow(let box):
            box.instance.handleConnectedEvent(for: instance, in: &eventContext)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let box):
            box.instance.handleConnectedEvent(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .datagramUpperHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        case .multiplexingPath(let path): path.handleConnectedEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleConnectedEvent call")
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let box):
            box.instance.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .datagramUpperHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .multiplexingPath(let path):
            path.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleDisconnectedEvent call")
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let box):
            var protocolInstance = box.instance
            protocolInstance.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .datagramUpperHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .multiplexingPath(let path):
            var path = path
            path.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let box):
            var protocolInstance = box.instance
            protocolInstance.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .datagramUpperHarness(let harness):
            harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .multiplexingPath(let path):
            var path = path
            path.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleInboundDataAvailableEvent call")
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let box):
            var protocolInstance = box.instance
            protocolInstance.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .datagramUpperHarness(let harness):
            harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .multiplexingPath(let path):
            var path = path
            path.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleOutboundRoomAvailableEvent call")
        }
    }

    public typealias PairedLowerLinkage = BaseOutboundDatagramLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches a test harness acting as the application on top of a stack.
    public init(harness: DatagramUpperHarness<BaseDatagramLinkageFamily>) {
        self.identifier = harness.identifier
        self.storage = nil
        self.protocolType = .datagramUpperHarness(harness)
    }

    /// Reaches a path on the test multiplexing protocol, so its lower protocol can deliver events.
    public init(path: TestDatagramPath) {
        self.identifier = path.identifier
        self.storage = nil
        self.protocolType = .multiplexingPath(path)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseOutboundDatagramLinkage: OutboundDatagramLinkage {
    enum ProtocolType {
        case unknown
        case udp(NetworkStateIndex)
        case ip(NetworkStateIndex)
        case demux(NetworkStateIndex)
        case bridgeDatagram(NetworkStateIndex)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case socketDatagram(NetworkStateIndex)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case quicDatagramFlow(ProtocolInstanceBox<QUICDatagramFlow>)
        #endif
        #if !NETWORK_EMBEDDED
        case datagramLowerHarness(DatagramLowerHarness<BaseDatagramLinkageFamily>)
        case multiplexedFlow(TestDatagramFlow)
        #endif
    }

    public func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .udp(let index):
            return try storage!.udpInstances[index].receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        case .demux(let index):
            return try storage!.demuxInstances[index].receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        case .ip(let index):
            return try storage!.ipInstances[index].receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        case .bridgeDatagram(let index):
            return try storage!.bridgeDatagramInstances[index].receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            return try storage!.socketDatagramInstances[index].receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            var protocolInstance = box.instance
            return try protocolInstance.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow):
            var flow = flow
            return try flow.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        case .datagramLowerHarness(let harness):
            var harness = harness
            return try harness.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        #endif
        case .unknown:
            return nil
        }
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .udp(let index):
            return try storage!.udpInstances[index].getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        case .demux(let index):
            return try storage!.demuxInstances[index].getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        case .ip(let index):
            return try storage!.ipInstances[index].getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        case .bridgeDatagram(let index):
            return try storage!.bridgeDatagramInstances[index].getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            return try storage!.socketDatagramInstances[index].getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            return try box.instance.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow):
            return try flow.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        case .datagramLowerHarness(let harness):
            var harness = harness
            return try harness.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        #endif
        case .unknown:
            return nil
        }
    }

    public func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .udp(let index):
            try storage!.udpInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .demux(let index):
            try storage!.demuxInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .ip(let index):
            try storage!.ipInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            try storage!.bridgeDatagramInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            try storage!.socketDatagramInstances[index].sendDatagrams(datagrams, from: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendDatagrams(datagrams, from: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow):
            var flow = flow
            try flow.sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            var harness = harness
            try harness.sendDatagrams(datagrams, from: instance, in: &eventContext)
        #endif
        case .unknown:
            datagrams.finalizeAllFramesAsFailed()
            return
        }
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .datagramLowerHarness, .multiplexedFlow: return identifier.isConnected(in: &eventContext)
        #endif
        default: return identifier.isConnected(in: &eventContext)
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].connect(for: instance, in: &eventContext)
        case .demux(let index): storage!.demuxInstances[index].connect(for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].connect(for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            storage!.bridgeDatagramInstances[index].connect(for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            storage!.socketDatagramInstances[index].connect(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box): box.instance.connect(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow): flow.connect(for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness): harness.connect(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index): storage!.udpInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .demux(let index):
            storage!.demuxInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .ip(let index): storage!.ipInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            storage!.bridgeDatagramInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            storage!.socketDatagramInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box): box.instance.disconnect(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow): flow.disconnect(error: error, for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            harness.disconnect(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .udp(let index):
            try storage!.udpInstances[index].detach(for: instance, in: &eventContext)
        case .demux(let index):
            try storage!.demuxInstances[index].detach(for: instance, in: &eventContext)
        case .ip(let index):
            try storage!.ipInstances[index].detach(for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            try storage!.bridgeDatagramInstances[index].detach(for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            try storage!.socketDatagramInstances[index].detach(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            var protocolInstance = box.instance
            try protocolInstance.detach(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow):
            var flow = flow
            try flow.detach(for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            var harness = harness
            try harness.detach(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept detach call")
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
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            storage!.socketDatagramInstances[index].unregisterEventManager(in: &eventContext)
            storage!.socketDatagramInstances.remove(index: index)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            box.instance.unregisterEventManager(in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow): flow.unregisterEventManager(in: &eventContext)
        case .datagramLowerHarness(let harness): harness.unregisterEventManager(in: &eventContext)
        #endif
        case .unknown: break
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .udp(let index):
            storage!.udpInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .demux(let index):
            storage!.demuxInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .ip(let index):
            storage!.ipInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            storage!.bridgeDatagramInstances[index].handleApplicationEvent(
                event: event,
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            storage!.socketDatagramInstances[index].handleApplicationEvent(
                event: event,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            box.instance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow):
            flow.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            harness.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .udp(let index): return storage!.udpInstances[index].getMetadata(for: instance, in: &eventContext)
        case .demux(let index): return storage!.demuxInstances[index].getMetadata(for: instance, in: &eventContext)
        case .ip(let index): return storage!.ipInstances[index].getMetadata(for: instance, in: &eventContext)
        case .bridgeDatagram(let index):
            return storage!.bridgeDatagramInstances[index].getMetadata(for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            return storage!.socketDatagramInstances[index].getMetadata(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box): return box.instance.getMetadata(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow(let flow): return flow.getMetadata(for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness): return harness.getMetadata(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept getMetadata call")
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .udp(let index):
            return storage!.udpInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        case .demux(let index):
            return storage!.demuxInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        case .ip(let index):
            return storage!.ipInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        case .bridgeDatagram(let index):
            return storage!.bridgeDatagramInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            return storage!.socketDatagramInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            return box.instance.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        // Neither the harness nor a multiplexed flow holds an instance in the storage, so these
        // must not fall through to the storage lookup below.
        case .datagramLowerHarness, .multiplexedFlow: return nil
        #endif
        case .unknown: fatalError("Protocol cannot accept getMetrics call")
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .udp(let index):
            try storage!.udpInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        case .demux(let index):
            try storage!.demuxInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        case .ip(let index):
            try storage!.ipInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        case .bridgeDatagram(let index):
            try storage!.bridgeDatagramInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketDatagram(let index):
            try storage!.socketDatagramInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicDatagramFlow(let box):
            var instance = box.instance
            try instance.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexedFlow:
            // `attachUpperProtocolToNewFlow` binds the upper when it creates the flow, so there
            // is nothing more to do here.
            break
        case .datagramLowerHarness(let harness):
            var harness = harness
            try harness.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        case .unknown: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public typealias PairedUpperLinkage = BaseInboundDatagramLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches a test harness acting as the bottom of a stack.
    public init(harness: DatagramLowerHarness<BaseDatagramLinkageFamily>) {
        self.identifier = harness.identifier
        self.storage = nil
        self.protocolType = .datagramLowerHarness(harness)
    }

    /// Reaches a flow on the test multiplexing protocol, so its upper protocol can talk to it.
    public init(flow: TestDatagramFlow) {
        self.identifier = flow.identifier
        self.storage = nil
        self.protocolType = .multiplexedFlow(flow)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseDatagramListenerLinkage: DatagramListenerLinkage {
    enum ProtocolType {
        case unknown
        #if !NETWORK_NO_SWIFT_QUIC
        case quic(NetworkStateIndex)
        #endif
        #if !NETWORK_EMBEDDED
        case multiplexing(TestMultiplexingProtocol)
        #endif
    }

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches the test multiplexing protocol acting as a listener.
    public init(multiplexing instance: TestMultiplexingProtocol) {
        self.identifier = instance.identifier
        self.storage = nil
        self.protocolType = .multiplexing(instance)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public typealias PairedUpperLinkage = BaseInboundDatagramFlowLinkage

    public func invokeAttachUpperProtocol(
        _ upperProtocol: PairedUpperLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            try storage!.quicInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing):
            var multiplexing = multiplexing
            try multiplexing.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        case .unknown: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        // Only QUIC hands back a flow for the shared pairing below, so without it nothing
        // reaches that tail.
        #if !NETWORK_NO_SWIFT_QUIC
        let lowerProtocol: BaseOutboundDatagramLinkage
        #endif
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            lowerProtocol = try storage!.quicInstances[index].attachUpperProtocolToNewFlow(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing):
            // The multiplexing protocol creates the flow and completes the pairing itself.
            var multiplexing = multiplexing
            let flowLower = try multiplexing.attachUpperProtocolToNewFlow(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            try upperProtocol.invokeAttachLowerProtocol(
                flowLower,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            return
        #endif
        case .unknown: fatalError("Protocol cannot accept invokeAttachUpperProtocolToNewFlow call")
        }
        #if !NETWORK_NO_SWIFT_QUIC
        try upperProtocol.invokeAttachLowerProtocol(
            lowerProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
        #endif
    }

    public func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: BaseInboundDatagramLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> BaseOutboundDatagramLinkage {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            return try storage!.quicInstances[index].attachUpperProtocolToExistingFlow(
                upperProtocol,
                existingFlowInstance: existingFlowInstance
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing):
            var multiplexing = multiplexing
            return try multiplexing.attachUpperProtocolToExistingFlow(
                upperProtocol,
                existingFlowInstance: existingFlowInstance
            )
        #endif
        case .unknown: fatalError("Protocol cannot accept invokeAttachUpperProtocolToExistingFlow call")
        }
    }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing): return multiplexing.isConnected(in: &eventContext)
        #endif
        default: return identifier.isConnected(in: &eventContext)
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): storage!.quicInstances[index].connect(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing): multiplexing.connect(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): storage!.quicInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing):
            multiplexing.disconnect(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): try storage!.quicInstances[index].detach(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing):
            var multiplexing = multiplexing
            try multiplexing.detach(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept detach call")
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            guard storage!.quicInstances[index].isFullyDetached else { return }
            storage!.quicInstances[index].unregisterEventManager(in: &eventContext)
            storage!.quicInstances.remove(index: index)
        #endif
        #if !NETWORK_EMBEDDED
        // The multiplexing protocol outlives its listener linkage; its owner tears it down.
        case .multiplexing: break
        #endif
        case .unknown: break
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            storage!.quicInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing):
            multiplexing.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): return storage!.quicInstances[index].getMetadata(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing(let multiplexing): return multiplexing.getMetadata(for: instance, in: &eventContext)
        #endif
        case .unknown: return nil
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            return storage!.quicInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .multiplexing: return nil
        #endif
        case .unknown: return nil
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseInboundDatagramFlowLinkage: InboundDatagramFlowLinkage {
    enum ProtocolType {
        case unknown
        #if !NETWORK_EMBEDDED
        case newDatagramFlowHarness(NewDatagramFlowHarness<BaseDatagramLinkageFamily>)
        #endif
    }

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches a test harness accepting new inbound datagram flows.
    public init(harness: NewDatagramFlowHarness<BaseDatagramLinkageFamily>) {
        self.identifier = harness.identifier
        self.storage = nil
        self.protocolType = .newDatagramFlowHarness(harness)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public typealias DataLinkage = BaseOutboundDatagramLinkage
    public typealias PairedLowerLinkage = BaseDatagramListenerLinkage

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseDatagramListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newDatagramFlowHarness(let harness):
            _ = try harness.attachLowerProtocol(lowerProtocol)
            // The listener binds the other direction itself, so this is the ordinary pairing call.
            try lowerProtocol.invokeAttachUpperProtocol(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        case .unknown:
            try lowerProtocol.invokeAttachUpperProtocol(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newDatagramFlowHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleConnectedEvent call")
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newDatagramFlowHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleDisconnectedEvent call")
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newDatagramFlowHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newDatagramFlowHarness(let harness):
            harness.handleNewInboundFlowEvent(
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                for: instance,
                in: &eventContext
            )
        #endif
        case .unknown: fatalError("Protocol cannot accept handleNewInboundFlowEvent call")
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseDatagramMultipathLinkage: DatagramMultipathLinkage {
    enum ProtocolType {
        case unknown
        #if !NETWORK_NO_SWIFT_QUIC
        case quic(NetworkStateIndex)
        #endif
        #if !NETWORK_EMBEDDED
        case multiplexing(TestMultiplexingProtocol)
        #endif
    }

    public typealias MultipathLowerProtocol = BaseOutboundDatagramLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches the test multiplexing protocol as the owner of multiple paths.
    public init(multiplexing instance: TestMultiplexingProtocol) {
        self.identifier = instance.identifier
        self.storage = nil
        self.protocolType = .multiplexing(instance)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
        #if !NETWORK_EMBEDDED
        // The multiplexing protocol enters its own stack, so hand the whole call over before
        // acquiring anything here.
        if case .multiplexing(let multiplexing) = protocolType {
            var multiplexing = multiplexing
            // `attachLowerProtocolForNewPath` binds both directions before it announces the path.
            _ = try multiplexing.fromExternal { eventContext throws(NetworkError) in
                try multiplexing.attachLowerProtocolForNewPath(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path,
                    in: &eventContext
                )
            }
            return
        }
        #endif

        // This is an external entry point, so acquire the event context here and thread it
        // into the protocol below.
        // `attachLowerProtocolForNewPath` binds the lower protocol's upper side itself, before it
        // announces the path, so there is nothing left to wire up here.
        try identifier.fromExternal(in: &storage!.context.eventContext) { eventContext throws(NetworkError) in
            switch protocolType {
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let index):
                _ = try storage!.quicInstances[index].attachLowerProtocolForNewPath(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path,
                    in: &eventContext
                )
            #endif
            default: fatalError("Protocol cannot accept attachLowerProtocolForNewPath call")
            }
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseInboundStreamLinkage: InboundStreamLinkage {
    enum ProtocolType {
        case unknown
        case streamEndpointFlow(ProtocolInstanceBox<StreamEndpointFlowProtocol>)
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case swiftTLSRecord(
            ProtocolInstanceBox<
                SwiftTLSProtocol.SwiftTLSRecordInstance<BaseInboundStreamLinkage, BaseOutboundStreamLinkage>
            >
        )
        #endif
        #if !NETWORK_EMBEDDED
        case streamUpperHarness(StreamUpperHarness<BaseStreamLinkageFamily>)
        #endif
    }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let overrideUpperLinkage: BaseInboundStreamLinkage?
        switch protocolType {
        case .streamEndpointFlow(let box):
            var flow = box.instance
            overrideUpperLinkage = try flow.attachLowerProtocol(lowerProtocol)
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            overrideUpperLinkage = try protocolInstance.attachLowerProtocol(lowerProtocol)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            var harness = harness
            let overrideUpper = try harness.attachLowerProtocol(lowerProtocol)
            try lowerProtocol.invokeAttachUpperProtocol(
                overrideUpper ?? self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            return
        #endif
        case .unknown: fatalError("Protocol cannot accept attachLowerProtocol call")
        }
        let upperLinkage = overrideUpperLinkage ?? self
        try lowerProtocol.invokeAttachUpperProtocol(
            upperLinkage,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleConnectedEvent(for: instance, in: &eventContext)
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleConnectedEvent(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleConnectedEvent call")
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
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleDisconnectedEvent call")
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
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleInboundDataAvailableEvent call")
        }
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamEndpointFlow(let box):
            box.instance.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleOutboundRoomAvailableEvent call")
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
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            harness.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleInboundAbortedEvent call")
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
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamUpperHarness(let harness):
            harness.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleOutboundAbortedEvent call")
        }
    }

    public typealias PairedLowerLinkage = BaseOutboundStreamLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches a test harness acting as the application on top of a stream stack.
    public init(harness: StreamUpperHarness<BaseStreamLinkageFamily>) {
        self.identifier = harness.identifier
        self.storage = nil
        self.protocolType = .streamUpperHarness(harness)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseOutboundStreamLinkage: OutboundStreamLinkage {
    enum ProtocolType {
        case unknown
        case tcp(NetworkStateIndex)
        case bridgeStream(NetworkStateIndex)
        case customLink(NetworkStateIndex)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case socketStream(NetworkStateIndex)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case quicStream(ProtocolInstanceBox<QUICStreamInstance>)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case swiftTLSRecord(
            ProtocolInstanceBox<
                SwiftTLSProtocol.SwiftTLSRecordInstance<BaseInboundStreamLinkage, BaseOutboundStreamLinkage>
            >
        )
        #endif
        #if !NETWORK_EMBEDDED
        case streamLowerHarness(StreamLowerHarness<BaseStreamLinkageFamily>)
        #endif
    }

    public func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .tcp(let index):
            return try storage!.tcpInstances[index].receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        case .bridgeStream(let index):
            return try storage!.bridgeStreamInstances[index].receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        case .customLink(let index):
            return try storage!.customLinkInstances[index].receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            return try storage!.socketStreamInstances[index].receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            var protocolInstance = box.instance
            return try protocolInstance.receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            return try protocolInstance.receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            var harness = harness
            return try harness.receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        #endif
        case .unknown:
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
            return try storage!.bridgeStreamInstances[index].getOutboundStreamDataRoomAvailable(
                for: instance,
                in: &eventContext
            )
        case .customLink(let index):
            return try storage!.customLinkInstances[index].getOutboundStreamDataRoomAvailable(
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            return try storage!.socketStreamInstances[index].getOutboundStreamDataRoomAvailable(
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            return try box.instance.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            return try protocolInstance.getOutboundStreamDataRoomAvailable(
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            var harness = harness
            return try harness.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        #endif
        case .unknown:
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
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            try storage!.socketStreamInstances[index].sendStreamData(streamData, from: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendStreamData(streamData, from: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendStreamData(streamData, from: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            var harness = harness
            try harness.sendStreamData(streamData, from: instance, in: &eventContext)
        #endif
        case .unknown:
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            var protocolInstance = box.instance
            try protocolInstance.sendEarlyStreamData(streamData, from: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness:
            // The harness has no early-data path, matching what this linkage reports for every
            // other non-QUIC protocol.
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTSUP)
        #endif
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            box.instance.abortInbound(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness: throw NetworkError.posix(ENOTSUP)
        #endif
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            box.instance.abortOutbound(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness: throw NetworkError.posix(ENOTSUP)
        #endif
        default:
            throw NetworkError.posix(ENOTSUP)
        }
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness: return identifier.isConnected(in: &eventContext)
        #endif
        default: return identifier.isConnected(in: &eventContext)
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .tcp(let index): storage!.tcpInstances[index].connect(for: instance, in: &eventContext)
        case .bridgeStream(let index): storage!.bridgeStreamInstances[index].connect(for: instance, in: &eventContext)
        case .customLink(let index): storage!.customLinkInstances[index].connect(for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index): storage!.socketStreamInstances[index].connect(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box): box.instance.connect(for: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.connect(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness): harness.connect(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .tcp(let index): storage!.tcpInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .bridgeStream(let index):
            storage!.bridgeStreamInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        case .customLink(let index):
            storage!.customLinkInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            storage!.socketStreamInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            box.instance.disconnect(error: error, for: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.disconnect(error: error, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            harness.disconnect(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .tcp(let index):
            try storage!.tcpInstances[index].detach(for: instance, in: &eventContext)
        case .bridgeStream(let index):
            try storage!.bridgeStreamInstances[index].detach(for: instance, in: &eventContext)
        case .customLink(let index):
            try storage!.customLinkInstances[index].detach(for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            try storage!.socketStreamInstances[index].detach(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            var protocolInstance = box.instance
            try protocolInstance.detach(for: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            try protocolInstance.detach(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            var harness = harness
            try harness.detach(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept detach call")
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
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            storage!.socketStreamInstances[index].unregisterEventManager(in: &eventContext)
            storage!.socketStreamInstances.remove(index: index)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            box.instance.unregisterEventManager(in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            box.instance.unregisterEventManager(in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness): harness.unregisterEventManager(in: &eventContext)
        #endif
        case .unknown: break
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .tcp(let index):
            storage!.tcpInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .bridgeStream(let index):
            storage!.bridgeStreamInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .customLink(let index):
            storage!.customLinkInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            storage!.socketStreamInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            box.instance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            protocolInstance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            harness.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .tcp(let index): return storage!.tcpInstances[index].getMetadata(for: instance, in: &eventContext)
        case .bridgeStream(let index):
            return storage!.bridgeStreamInstances[index].getMetadata(for: instance, in: &eventContext)
        case .customLink(let index):
            return storage!.customLinkInstances[index].getMetadata(for: instance, in: &eventContext)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            return storage!.socketStreamInstances[index].getMetadata(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            return box.instance.getMetadata(for: instance, in: &eventContext)
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            return box.instance.getMetadata(for: instance, in: &eventContext)
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness): return harness.getMetadata(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept getMetadata call")
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .tcp(let index):
            return storage!.tcpInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        case .bridgeStream(let index):
            return storage!.bridgeStreamInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        case .customLink(let index):
            return storage!.customLinkInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            return storage!.socketStreamInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            return box.instance.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            return box.instance.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        #if !NETWORK_EMBEDDED
        // The harness holds no instance in the storage, so it must not fall through.
        case .streamLowerHarness: return nil
        #endif
        case .unknown: fatalError("Protocol cannot accept getMetrics call")
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .tcp(let index):
            try storage!.tcpInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        case .bridgeStream(let index):
            try storage!.bridgeStreamInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        case .customLink(let index):
            try storage!.customLinkInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        case .socketStream(let index):
            try storage!.socketStreamInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicStream(let box):
            var instance = box.instance
            try instance.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case .swiftTLSRecord(let box):
            var protocolInstance = box.instance
            try protocolInstance.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        #if !NETWORK_EMBEDDED
        case .streamLowerHarness(let harness):
            var harness = harness
            try harness.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        case .unknown: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public typealias PairedUpperLinkage = BaseInboundStreamLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches a test harness acting as the bottom of a stream stack.
    public init(harness: StreamLowerHarness<BaseStreamLinkageFamily>) {
        self.identifier = harness.identifier
        self.storage = nil
        self.protocolType = .streamLowerHarness(harness)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage?, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseStreamListenerLinkage: StreamListenerLinkage {
    enum ProtocolType {
        case unknown
        #if !NETWORK_NO_SWIFT_QUIC
        case quic(NetworkStateIndex)
        #endif
    }

    public typealias PairedUpperLinkage = BaseInboundStreamFlowLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }


    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage, protocolType: ProtocolType) {
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
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            try storage!.quicInstances[index].attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        default: fatalError("Protocol cannot accept attachUpperProtocol call")
        }
    }

    public func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        // Only QUIC hands back a flow for the shared pairing below, so without it nothing
        // reaches that tail.
        #if !NETWORK_NO_SWIFT_QUIC
        let lowerProtocol: BaseOutboundStreamLinkage
        #endif
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            lowerProtocol = try storage!.quicInstances[index].attachUpperProtocolToNewFlow(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        default: fatalError("Protocol cannot accept invokeAttachUpperProtocolToNewFlow call")
        }
        #if !NETWORK_NO_SWIFT_QUIC
        try upperProtocol.invokeAttachLowerProtocol(
            lowerProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
        #endif
    }

    public func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: BaseInboundStreamLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> BaseOutboundStreamLinkage {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            return try storage!.quicInstances[index].attachUpperProtocolToExistingFlow(
                upperProtocol,
                existingFlowInstance: existingFlowInstance
            )
        #endif
        default: fatalError("Protocol cannot accept invokeAttachUpperProtocolToExistingFlow call")
        }
    }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        default: return identifier.isConnected(in: &eventContext)
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): storage!.quicInstances[index].connect(for: instance, in: &eventContext)
        #endif
        default: fatalError("Protocol cannot accept connect call")
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): storage!.quicInstances[index].disconnect(error: error, for: instance, in: &eventContext)
        #endif
        default: fatalError("Protocol cannot accept disconnect call")
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): try storage!.quicInstances[index].detach(for: instance, in: &eventContext)
        #endif
        default: fatalError("Protocol cannot accept detach call")
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            guard storage!.quicInstances[index].isFullyDetached else { return }
            storage!.quicInstances[index].unregisterEventManager(in: &eventContext)
            storage!.quicInstances.remove(index: index)
        #endif
        case .unknown: break
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            storage!.quicInstances[index].handleApplicationEvent(event: event, for: instance, in: &eventContext)
        #endif
        default: fatalError("Protocol cannot accept handleApplicationEvent call")
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): return storage!.quicInstances[index].getMetadata(for: instance, in: &eventContext)
        #endif
        default: return nil
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            return storage!.quicInstances[index].getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        #endif
        default: return nil
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
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
public struct BaseInboundStreamFlowLinkage: InboundStreamFlowLinkage {
    enum ProtocolType {
        case unknown
        #if !NETWORK_EMBEDDED
        case newStreamFlowHarness(NewStreamFlowHarness<BaseStreamLinkageFamily>)
        #endif
    }

    public typealias DataLinkage = BaseOutboundStreamLinkage
    public typealias PairedLowerLinkage = BaseStreamListenerLinkage

    public init() {
        self.identifier = .init()
        self.storage = nil
        self.protocolType = .unknown
    }

    #if !NETWORK_EMBEDDED
    /// Reaches a test harness accepting new inbound stream flows.
    public init(harness: NewStreamFlowHarness<BaseStreamLinkageFamily>) {
        self.identifier = harness.identifier
        self.storage = nil
        self.protocolType = .newStreamFlowHarness(harness)
    }
    #endif

    init(identifier: InstanceIdentifier, storage: BaseNetworkProtocolStorage, protocolType: ProtocolType) {
        self.identifier = identifier
        self.storage = storage
        self.protocolType = protocolType
    }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newStreamFlowHarness(let harness):
            _ = try harness.attachLowerProtocol(lowerProtocol)
            // The listener binds the other direction itself, so this is the ordinary pairing call.
            try lowerProtocol.invokeAttachUpperProtocol(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        #endif
        case .unknown:
            try lowerProtocol.invokeAttachUpperProtocol(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newStreamFlowHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleConnectedEvent call")
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newStreamFlowHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleDisconnectedEvent call")
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newStreamFlowHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        #endif
        case .unknown: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        #if !NETWORK_EMBEDDED
        case .newStreamFlowHarness(let harness):
            harness.handleNewInboundFlowEvent(
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                for: instance,
                in: &eventContext
            )
        #endif
        case .unknown: fatalError("Protocol cannot accept handleNewInboundFlowEvent call")
        }
    }

    public let identifier: InstanceIdentifier
    public let storage: BaseNetworkProtocolStorage?
    let protocolType: ProtocolType

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

#if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
/// The record-layer TLS instance as a base stack uses it: framework linkages on both faces.
@available(Network 0.1.0, *)
typealias SwiftTLSRecordStreamInstance = SwiftTLSProtocol.SwiftTLSRecordInstance<
    BaseInboundStreamLinkage,
    BaseOutboundStreamLinkage
>

// The record-layer TLS instance sits between two framework protocols, so both of its neighbours
// reach it through an ordinary base linkage. It has its own case in the base stream linkages, and
// these are the accessors that name it.
@available(Network 0.1.0, *)
extension SwiftTLSRecordStreamInstance {
    /// The linkage the protocol below holds in order to reach this one.
    var asUpper: BaseInboundStreamLinkage {
        .init(identifier: identifier, storage: nil, protocolType: .swiftTLSRecord(.init(self)))
    }

    /// The linkage the protocol above holds in order to reach this one.
    var asLower: BaseOutboundStreamLinkage {
        .init(identifier: identifier, storage: nil, protocolType: .swiftTLSRecord(.init(self)))
    }

    /// Pairs this protocol with the lower protocol, in both directions.
    func attachLower(
        _ lowerProtocol: BaseOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var mutableSelf = self
        let overrideUpperLinkage = try mutableSelf.attachLowerProtocol(lowerProtocol)
        try lowerProtocol.invokeAttachUpperProtocol(
            overrideUpperLinkage ?? asUpper,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
}
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
// The storage owns every framework protocol instance and hands out the linkages that reach them.
// It is `open` so a module outside the framework can subclass it and add factories for its own
// protocols alongside the framework's, rather than replacing them.
open class BaseNetworkProtocolStorage {

    /// The context this storage's protocol instances run on.
    ///
    /// Readable by subclasses so a storage defined outside the framework can build its own
    /// protocol instances on the same context.
    public let context: NetworkContext

    public init(context: NetworkContext) {
        self.context = context
    }

    #if !NETWORK_EMBEDDED
    /// The test harnesses this storage is keeping alive; see `HarnessStorage.swift`.
    var heldHarnesses = HeldHarnesses()
    #endif

    // MARK: - Datagram Protocol Instances

    internal var udpInstances = NetworkGappyArray<UDPProtocol.UDPInstance>()

    public func createUDPInstance() -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        createUDPInstance(in: &context.eventContext)
    }

    public func createUDPInstance(
        in eventContext: inout NetworkContext.EventContext
    ) -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        let instance = UDPProtocol.UDPInstance(context: context, in: &eventContext)

        let instanceIndex = udpInstances.insert(instance)

        let identifier = udpInstances[instanceIndex].identifier
        let inbound = BaseInboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .udp(instanceIndex)
        )
        let outbound = BaseOutboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .udp(instanceIndex)
        )

        return (inbound, outbound)
    }

    internal var demuxInstances = NetworkGappyArray<DemuxProtocol.DemuxInstance>()

    public func createDemuxInstance() -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        let instance = DemuxProtocol.DemuxInstance(context: context)

        let instanceIndex = demuxInstances.insert(instance)

        let identifier = demuxInstances[instanceIndex].identifier
        let inbound = BaseInboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .demux(instanceIndex)
        )
        let outbound = BaseOutboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .demux(instanceIndex)
        )

        return (inbound, outbound)
    }

    internal var ipInstances = NetworkGappyArray<IPProtocol.IPInstance>()

    public func createIPInstance() -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        createIPInstance(in: &context.eventContext)
    }

    public func createIPInstance(
        in eventContext: inout NetworkContext.EventContext
    ) -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        let instance = IPProtocol.IPInstance(context: context, in: &eventContext)

        let instanceIndex = ipInstances.insert(instance)

        let identifier = ipInstances[instanceIndex].identifier
        let inbound = BaseInboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .ip(instanceIndex)
        )
        let outbound = BaseOutboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .ip(instanceIndex)
        )

        return (inbound, outbound)
    }

    #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
    internal var socketDatagramInstances = NetworkGappyArray<SocketDatagramProtocol>()

    public func createSocketDatagramInstance() -> BaseOutboundDatagramLinkage {
        let instance = SocketDatagramProtocol(context: context)
        let instanceIndex = socketDatagramInstances.insert(instance)
        return BaseOutboundDatagramLinkage(
            identifier: socketDatagramInstances[instanceIndex].identifier,
            storage: self,
            protocolType: .socketDatagram(instanceIndex)
        )
    }
    #endif

    internal var bridgeDatagramInstances = NetworkGappyArray<BridgeDatagramProtocol.BridgeInstance>()

    public func createBridgeDatagramInstance() -> BaseOutboundDatagramLinkage {
        let instance = BridgeDatagramProtocol.BridgeInstance(context: context)
        let instanceIndex = bridgeDatagramInstances.insert(instance)

        return BaseOutboundDatagramLinkage(
            identifier: instance.identifier,
            storage: self,
            protocolType: .bridgeDatagram(instanceIndex)
        )
    }

    // Endpoint flows are referenced directly by the linkage rather than stored here: the
    // flow owns its own lifetime, so there is nothing for the storage to keep track of.
    internal static func linkage(
        for flow: DatagramEndpointFlowProtocol
    ) -> BaseInboundDatagramLinkage {
        BaseInboundDatagramLinkage(
            identifier: flow.identifier,
            storage: nil,
            protocolType: .datagramEndpointFlow(.init(flow))
        )
    }

    // MARK: - Stream Protocol Instances

    internal var tcpInstances = NetworkGappyArray<TCPProtocol.TCPInstance>()

    // TCP straddles the two families: stream data above, datagrams below. The returned
    // inbound linkage is therefore a *datagram* linkage, for lower protocols to attach
    // below TCP, while the outbound linkage is a *stream* linkage, for upper protocols
    // to attach above it.
    public func createTCPInstance() -> (BaseInboundDatagramLinkage, BaseOutboundStreamLinkage) {
        let instance = TCPProtocol.TCPInstance(context: context)

        let instanceIndex = tcpInstances.insert(instance)

        let identifier = tcpInstances[instanceIndex].identifier
        let inbound = BaseInboundDatagramLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .tcp(instanceIndex)
        )
        let outbound = BaseOutboundStreamLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .tcp(instanceIndex)
        )

        return (inbound, outbound)
    }

    #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
    internal var socketStreamInstances = NetworkGappyArray<SocketStreamProtocol>()

    public func createSocketStreamInstance() -> BaseOutboundStreamLinkage {
        let instance = SocketStreamProtocol(context: context)
        let instanceIndex = socketStreamInstances.insert(instance)
        return BaseOutboundStreamLinkage(
            identifier: socketStreamInstances[instanceIndex].identifier,
            storage: self,
            protocolType: .socketStream(instanceIndex)
        )
    }
    #endif

    internal var bridgeStreamInstances = NetworkGappyArray<BridgeStreamProtocol.BridgeInstance>()

    public func createBridgeStreamInstance() -> BaseOutboundStreamLinkage {
        let instance = BridgeStreamProtocol.BridgeInstance(context: context)
        let instanceIndex = bridgeStreamInstances.insert(instance)

        return BaseOutboundStreamLinkage(
            identifier: instance.identifier,
            storage: self,
            protocolType: .bridgeStream(instanceIndex)
        )
    }

    internal var customLinkInstances = NetworkGappyArray<CustomLinkProtocol.CustomLinkInstance>()

    public func createCustomLinkInstance() -> BaseOutboundStreamLinkage {
        let instance = CustomLinkProtocol.CustomLinkInstance(context: context)
        let instanceIndex = customLinkInstances.insert(instance)

        return BaseOutboundStreamLinkage(
            identifier: instance.identifier,
            storage: self,
            protocolType: .customLink(instanceIndex)
        )
    }

    #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
    /// Creates a record-layer TLS instance, and hands back the linkages its neighbours hold.
    ///
    /// The instance type is internal, so this is how anything outside the module puts record-layer
    /// TLS in a stack. Like the QUIC objects, the instance is owned by the linkages rather than by
    /// the storage, so a caller keeps it alive by keeping one of them.
    public func createSwiftTLSRecordInstance() -> (upper: BaseInboundStreamLinkage, lower: BaseOutboundStreamLinkage) {
        let instance = SwiftTLSRecordStreamInstance(context: context)
        return (instance.asUpper, instance.asLower)
    }
    #endif

    // Endpoint flows are referenced directly by the linkage rather than stored here: the
    // flow owns its own lifetime, so there is nothing for the storage to keep track of.
    internal static func linkage(
        for flow: StreamEndpointFlowProtocol
    ) -> BaseInboundStreamLinkage {
        BaseInboundStreamLinkage(
            identifier: flow.identifier,
            storage: nil,
            protocolType: .streamEndpointFlow(.init(flow))
        )
    }

    #if !NETWORK_NO_SWIFT_QUIC
    internal var quicInstances = NetworkGappyArray<QUICConnection>()

    public func createQUICInstance() -> (
        BaseStreamListenerLinkage, BaseDatagramListenerLinkage, BaseDatagramMultipathLinkage
    ) {
        createQUICInstance(in: &context.eventContext)
    }

    public func createQUICInstance(
        in eventContext: inout NetworkContext.EventContext
    ) -> (
        BaseStreamListenerLinkage, BaseDatagramListenerLinkage, BaseDatagramMultipathLinkage
    ) {
        let instance = QUICConnection(context: context, in: &eventContext)

        let instanceIndex = quicInstances.insert(instance)

        let identifier = instance.identifier
        let stream = BaseStreamListenerLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .quic(instanceIndex)
        )
        let datagram = BaseDatagramListenerLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .quic(instanceIndex)
        )
        let multipath = BaseDatagramMultipathLinkage(
            identifier: identifier,
            storage: self,
            protocolType: .quic(instanceIndex)
        )

        return (stream, datagram, multipath)
    }
    #endif

    public func quicInstance(for linkage: BaseStreamListenerLinkage) -> QUICConnection? {
        switch linkage.protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): return quicInstances[index]
        #endif
        default: return nil
        }
    }

    public func quicInstance(for linkage: BaseDatagramListenerLinkage) -> QUICConnection? {
        switch linkage.protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): return quicInstances[index]
        #endif
        default: return nil
        }
    }

    public func quicInstance(for linkage: BaseDatagramMultipathLinkage) -> QUICConnection? {
        switch linkage.protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index): return quicInstances[index]
        #endif
        default: return nil
        }
    }

    /// The multipath linkage for the connection a stream listener linkage names.
    ///
    /// A QUIC connection hands out three linkages at once, but a caller holding only the stream
    /// listener -- an endpoint flow, say -- still needs the multipath one to add a path.
    public func multipathLinkage(for linkage: BaseStreamListenerLinkage) -> BaseDatagramMultipathLinkage? {
        switch linkage.protocolType {
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let index):
            return BaseDatagramMultipathLinkage(
                identifier: linkage.identifier,
                storage: self,
                protocolType: .quic(index)
            )
        #endif
        default: return nil
        }
    }
}

#if !NETWORK_NO_SWIFT_QUIC
// Builds the linkage that wraps a QUIC object. The QUIC implementation reaches its upper and lower
// protocols through these, and a module outside the framework gets them by wrapping the result.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension BaseOutboundStreamLinkage {
    public init(quicStream: QUICStreamInstance) {
        self.init(identifier: quicStream.identifier, storage: nil, protocolType: .quicStream(.init(quicStream)))
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension BaseOutboundDatagramLinkage {
    public init(quicDatagramFlow: QUICDatagramFlow) {
        self.init(
            identifier: quicDatagramFlow.identifier,
            storage: nil,
            protocolType: .quicDatagramFlow(.init(quicDatagramFlow))
        )
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension BaseInboundDatagramLinkage {
    public init(quicPath: QUICPath) {
        self.init(identifier: quicPath.identifier, storage: nil, protocolType: .quicPath(.init(quicPath)))
    }
}
#endif
