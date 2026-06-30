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

@available(Network 0.1.0, *)
struct EndpointFlowPrivateStorage {
    func handleStateChange(_ state: EndpointFlow.State) {}
    mutating func initForReuse(_ flow: EndpointFlow) {}
}

@available(Network 0.1.0, *)
extension EndpointFlow {

    internal func startOnQueue() throws(NetworkError) {
        parameters.context.assert()
        self.state = .setup

        if reuse {
            let stack = parameters.defaultStack
            let path = PathProperties(parameters: parameters)
            switch stack.transport {
            case .quic(let options):
                guard let instance = options.protocolInstance else {
                    throw NetworkError.posix(EINVAL)
                }

                let listenerLinkage = StreamListenerLinkage(reference: instance)
                let flow = try StreamEndpointFlowProtocol(
                    identifier: String(self.identifier),
                    local: self.localEndpoint,
                    remote: self.remoteEndpoint,
                    parameters: self.parameters,
                    path: path,
                    context: self.parameters.context,
                    listenerProtocol: listenerLinkage
                )
                self.flowProtocol = .stream(flow)
                options.setLogID(
                    prefix: "C",
                    parent: String(self.identifier),
                    protocolLogIDNumber: Int(self.identifier)
                )
            default:
                Logger.connection.error("Unable to reuse on non-QUIC stack")
                throw NetworkError.posix(ENOENT)
            }
        } else {
            let context = self.context
            let stack = parameters.defaultStack
            let path = PathProperties(parameters: parameters)

            let effectiveLocalEndpoint = localEndpoint
            let effectiveRemoteEndpoint = remoteEndpoint

            if let transport = stack.transport {

                switch transport {
                case .tcp(let options):
                    if case .custom(let linkOptions) = stack.link,
                        linkOptions.identifier == BridgeDatagramProtocol.identifier
                    {
                        guard let reference = TCPProtocol().newProtocolInstance(context: context) else {
                            throw NetworkError.posix(EINVAL)
                        }
                        options.setProtocolInstance(reference)
                        let linkage = OutboundStreamLinkage(reference: reference)
                        let flow = try StreamEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            local: effectiveLocalEndpoint,
                            remote: effectiveRemoteEndpoint,
                            parameters: self.parameters,
                            path: path,
                            context: context,
                            lowerStreamProtocol: linkage
                        )
                        self.flowProtocol = .stream(flow)
                        options.setLogID(
                            prefix: "C",
                            parent: String(self.identifier),
                            protocolLogIDNumber: Int(self.identifier)
                        )
                    } else {
                        let socketReference = SocketStreamProtocol.instance(context: context)
                        options.setProtocolInstance(socketReference)
                        let linkage = OutboundStreamLinkage(reference: socketReference)
                        let flow = try StreamEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            local: effectiveLocalEndpoint,
                            remote: effectiveRemoteEndpoint,
                            parameters: self.parameters,
                            path: path,
                            context: context,
                            lowerStreamProtocol: linkage
                        )
                        self.flowProtocol = .stream(flow)
                        options.setLogID(
                            prefix: "C",
                            parent: String(self.identifier),
                            protocolLogIDNumber: Int(self.identifier)
                        )
                    }
                case .udp(let options):
                    if case .custom(let linkOptions) = stack.link,
                        linkOptions.identifier == BridgeDatagramProtocol.identifier
                    {
                        let udpReference = UDPProtocol.instance(context: context)
                        let ipReference = IPProtocol.instance(context: context)
                        options.setProtocolInstance(udpReference)
                        let linkage = OutboundDatagramLinkage(reference: udpReference)
                        let flow = try DatagramEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            local: effectiveLocalEndpoint,
                            remote: self.remoteEndpoint,
                            parameters: self.parameters,
                            path: path,
                            context: context,
                            lowerDatagramProtocol: linkage
                        )
                        self.flowProtocol = .datagram(flow)
                        options.setLogID(
                            prefix: "C",
                            parent: String(self.identifier),
                            protocolLogIDNumber: Int(self.identifier)
                        )
                        try udpReference.attachLowerDatagramProtocol(
                            ipReference,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        let reference = BridgeDatagramProtocol.instance(context: context)
                        try ipReference.attachLowerDatagramProtocol(
                            reference,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    } else {
                        let socketReference = SocketDatagramProtocol.instance(context: context)
                        let linkage = OutboundDatagramLinkage(reference: socketReference)
                        let flow = try DatagramEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            local: effectiveLocalEndpoint,
                            remote: self.remoteEndpoint,
                            parameters: self.parameters,
                            path: path,
                            context: context,
                            lowerDatagramProtocol: linkage
                        )
                        self.flowProtocol = .datagram(flow)
                        options.setLogID(
                            prefix: "C",
                            parent: String(self.identifier),
                            protocolLogIDNumber: Int(self.identifier)
                        )
                    }
                #if !NETWORK_NO_SWIFT_QUIC
                case .quic(let options):
                    let quicReference = QUICProtocol.instance(context: context)

                    self.quicConnectionReference = quicReference

                    options.setProtocolInstance(quicReference)
                    options.setLogID(
                        prefix: "C",
                        parent: String(self.identifier),
                        protocolLogIDNumber: Int(self.identifier)
                    )
                    let listenerLinkage = StreamListenerLinkage(reference: quicReference)
                    let flow = try StreamEndpointFlowProtocol(
                        identifier: String(self.identifier),
                        local: effectiveLocalEndpoint,
                        remote: self.remoteEndpoint,
                        parameters: self.parameters,
                        path: path,
                        context: context,
                        listenerProtocol: listenerLinkage
                    )
                    self.flowProtocol = .stream(flow)

                    if case .custom(let linkOptions) = stack.link,
                        linkOptions.identifier == BridgeDatagramProtocol.identifier
                    {
                        let udpReference = UDPProtocol.instance(context: context)
                        let ipReference = IPProtocol.instance(context: context)
                        try quicReference.attachLowerDatagramProtocolForNewPath(
                            udpReference,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        try udpReference.attachLowerDatagramProtocol(
                            ipReference,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        let reference = BridgeDatagramProtocol.instance(context: context)
                        try ipReference.attachLowerDatagramProtocol(
                            reference,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    } else {
                        let socketReference = SocketDatagramProtocol.instance(context: context)
                        try quicReference.attachLowerDatagramProtocolForNewPath(
                            socketReference,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    }
                #endif
                default:
                    Logger.connection.error("Unsupported transport protocol")
                    throw NetworkError.posix(EINVAL)
                }
            } else {
                if stack.applicationProtocols.count == 0 {
                    if let link = stack.link {
                        switch link {
                        case .custom(let options):
                            // TODO: It'd be nice if we could do this w/o checking for specific protocols here,
                            // but we're not there quite yet
                            if options.identifier == BridgeStreamProtocol.identifier {
                                let reference = BridgeStreamProtocol.instance(context: context)
                                let linkage = OutboundStreamLinkage(reference: reference)
                                let flow = try StreamEndpointFlowProtocol(
                                    identifier: String(self.identifier),
                                    local: effectiveLocalEndpoint,
                                    remote: self.remoteEndpoint,
                                    parameters: self.parameters,
                                    path: path,
                                    context: context,
                                    lowerStreamProtocol: linkage
                                )
                                self.flowProtocol = .stream(flow)
                            } else {
                                Logger.connection.error("Unknown link protocol")
                                throw NetworkError.posix(EINVAL)
                            }
                        default:
                            Logger.connection.error("Unknown link protocol")
                            throw NetworkError.posix(EINVAL)
                        }
                    } else {
                        Logger.connection.error("No link protocol")
                        throw NetworkError.posix(EINVAL)
                    }
                } else if stack.applicationProtocols.count == 1 {
                    switch stack.applicationProtocols.first {
                    case .swiftTLS(let options):
                        guard let reference = TLSProtocol().newProtocolInstance(context: context) else {
                            throw NetworkError.posix(EINVAL)
                        }
                        options.setProtocolInstance(reference)
                        let linkage = OutboundStreamLinkage(reference: reference)
                        let flow = try StreamEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            local: effectiveLocalEndpoint,
                            remote: effectiveRemoteEndpoint,
                            parameters: parameters,
                            path: path,
                            context: context,
                            lowerStreamProtocol: linkage
                        )
                        self.flowProtocol = .stream(flow)
                        options.setLogID(
                            prefix: "C",
                            parent: String(self.identifier),
                            protocolLogIDNumber: Int(self.identifier)
                        )
                        if let link = stack.link {
                            switch link {
                            case .custom(let options):
                                // TODO: It'd be nice if we could do this w/o checking for specific protocols here,
                                // but we're not there quite yet
                                if options.identifier == BridgeStreamProtocol.identifier {
                                    let bridgeReference = BridgeStreamProtocol.instance(context: context)
                                    try reference.attachLowerStreamProtocol(
                                        bridgeReference,
                                        remote: effectiveRemoteEndpoint,
                                        local: effectiveLocalEndpoint,
                                        parameters: self.parameters,
                                        path: path
                                    )
                                } else {
                                    Logger.connection.error("Unknown link protocol")
                                    throw NetworkError.posix(EINVAL)
                                }
                            default:
                                Logger.connection.error("Unknown link protocol")
                                throw NetworkError.posix(EINVAL)
                            }
                        }
                    default:
                        Logger.connection.error("Unsupported application protocol")
                        throw NetworkError.posix(EINVAL)
                    }
                }
            }
        }

        state = .preparing
        switch self.flowProtocol {
        case .stream(let flow):
            flow.waitForDisconnected { error in self.state = .failed(error) }
            flow.start(self.startCompleted)
        case .datagram(let flow):
            flow.waitForDisconnected { error in self.state = .failed(error) }
            flow.start(self.startCompleted)
        case .none:
            Logger.connection.error("No current flow")
            throw NetworkError.posix(EINVAL)
        }
    }
}
