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
                #if NETWORK_NO_SWIFT_QUIC
                _ = options
                Logger.connection.error("Unable to reuse without Swift QUIC")
                throw NetworkError.posix(ENOTSUP)
                #else
                let flow = try StreamEndpointFlowProtocol(
                    identifier: String(self.identifier),
                    local: self.localEndpoint,
                    remote: self.remoteEndpoint,
                    parameters: self.parameters,
                    path: path,
                    context: self.parameters.context
                )
                self.flowProtocol = .stream(flow)

                // Reuse opens another stream on the connection the options already name. The
                // storage is inherited from the flow being reused, so the listener linkage for
                // that existing connection resolves here.
                guard let listener = self.quicStreamListenerLinkage else {
                    Logger.connection.error("Unable to find the connection to reuse")
                    throw NetworkError.posix(ENOENT)
                }
                try listener.invokeAttachUpperProtocolToNewFlow(
                    BaseNetworkProtocolStorage.linkage(for: flow),
                    remote: self.remoteEndpoint,
                    local: self.localEndpoint,
                    parameters: self.parameters,
                    path: path
                )
                options.setLogID(
                    prefix: "C",
                    parent: String(self.identifier),
                    protocolLogIDNumber: Int(self.identifier)
                )
                #endif
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
                    // In bridged (test-harness) mode drive a raw TCP instance over the bridge;
                    // otherwise use a real kernel socket. The flow wiring is identical.
                    let bridged: Bool
                    if case .custom(let linkOptions) = stack.link,
                        linkOptions.identifier == BridgeDatagramProtocol.identifier
                    {
                        bridged = true
                    } else {
                        bridged = false
                    }

                    let transportLower: BaseOutboundStreamLinkage
                    if bridged {
                        let (tcpUpper, tcpLower) = self.storage.createTCPInstance()
                        transportLower = tcpLower
                        let bridge = self.storage.createBridgeDatagramInstance()
                        try tcpUpper.invokeAttachLowerProtocol(
                            bridge,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    } else {
                        transportLower = self.storage.createSocketStreamInstance()
                    }
                    options.setProtocolInstance(transportLower.identifier)
                    let flow = try StreamEndpointFlowProtocol(
                        identifier: String(self.identifier),
                        local: effectiveLocalEndpoint,
                        remote: effectiveRemoteEndpoint,
                        parameters: self.parameters,
                        path: path,
                        context: context
                    )
                    self.flowProtocol = .stream(flow)
                    options.setLogID(
                        prefix: "C",
                        parent: String(self.identifier),
                        protocolLogIDNumber: Int(self.identifier)
                    )
                    // Attach from the upper linkage so both directions are bound.
                    try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                        transportLower,
                        remote: effectiveRemoteEndpoint,
                        local: effectiveLocalEndpoint,
                        parameters: self.parameters,
                        path: path
                    )
                case .udp(let options):
                    let flow = try DatagramEndpointFlowProtocol(
                        identifier: String(self.identifier),
                        local: effectiveLocalEndpoint,
                        remote: self.remoteEndpoint,
                        parameters: self.parameters,
                        path: path,
                        context: context
                    )
                    self.flowProtocol = .datagram(flow)
                    options.setLogID(
                        prefix: "C",
                        parent: String(self.identifier),
                        protocolLogIDNumber: Int(self.identifier)
                    )

                    if case .custom(let linkOptions) = stack.link,
                        linkOptions.identifier == BridgeDatagramProtocol.identifier
                    {
                        // Bridged (test-harness) mode: UDP -> IP -> BridgeProtocol.
                        let (udpUpper, udpLower) = self.storage.createUDPInstance()
                        // Associate the options before attaching: UDP reads them from its own
                        // `setup`, which runs on the attach.
                        options.setProtocolInstance(udpUpper.identifier)
                        // Attach from the upper linkage so both directions are bound.
                        try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                            udpLower,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        let (ipUpper, ipLower) = self.storage.createIPInstance()
                        try udpUpper.invokeAttachLowerProtocol(
                            ipLower,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        let bridge = self.storage.createBridgeDatagramInstance()
                        try ipUpper.invokeAttachLowerProtocol(
                            bridge,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    } else {
                        // Real networking: UDP straight onto a kernel socket.
                        let socket = self.storage.createSocketDatagramInstance()
                        try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                            socket,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    }
                #if !NETWORK_NO_SWIFT_QUIC
                case .quic(let options):
                    let (quicStreamListener, _, quicMultipath) = self.storage.createQUICInstance()

                    self.quicConnectionInstance = quicStreamListener.identifier
                    self.quicStreamListenerLinkage = quicStreamListener

                    options.setProtocolInstance(quicStreamListener.identifier)
                    options.setLogID(
                        prefix: "C",
                        parent: String(self.identifier),
                        protocolLogIDNumber: Int(self.identifier)
                    )
                    let flow = try StreamEndpointFlowProtocol(
                        identifier: String(self.identifier),
                        local: effectiveLocalEndpoint,
                        remote: self.remoteEndpoint,
                        parameters: self.parameters,
                        path: path,
                        context: context,
                    )
                    self.flowProtocol = .stream(flow)

                    // This flow is the client's outbound stream on the connection.
                    try quicStreamListener.invokeAttachUpperProtocolToNewFlow(
                        BaseNetworkProtocolStorage.linkage(for: flow),
                        remote: effectiveRemoteEndpoint,
                        local: effectiveLocalEndpoint,
                        parameters: self.parameters,
                        path: path
                    )

                    if case .custom(let linkOptions) = stack.link,
                        linkOptions.identifier == BridgeDatagramProtocol.identifier
                    {
                        // Bridged (test-harness) mode: QUIC -> UDP -> IP -> BridgeProtocol.
                        let (udpUpper, udpLower) = self.storage.createUDPInstance()
                        let (ipUpper, ipLower) = self.storage.createIPInstance()
                        try quicMultipath.invokeAttachLowerProtocolForNewPath(
                            udpLower,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        try udpUpper.invokeAttachLowerProtocol(
                            ipLower,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        let bridge = self.storage.createBridgeDatagramInstance()
                        try ipUpper.invokeAttachLowerProtocol(
                            bridge,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                    } else {
                        // Real networking: QUIC straight onto a kernel socket.
                        let socket = self.storage.createSocketDatagramInstance()
                        try quicMultipath.invokeAttachLowerProtocolForNewPath(
                            socket,
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
                        case .customLink(let options):
                            let customLink = self.storage.createCustomLinkInstance()
                            options.setProtocolInstance(customLink.identifier)
                            let flow = try StreamEndpointFlowProtocol(
                                identifier: String(self.identifier),
                                local: effectiveLocalEndpoint,
                                remote: self.remoteEndpoint,
                                parameters: self.parameters,
                                path: path,
                                context: context
                            )
                            self.flowProtocol = .stream(flow)
                            // Attach from the upper linkage so both directions are bound.
                            try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                                customLink,
                                remote: effectiveRemoteEndpoint,
                                local: effectiveLocalEndpoint,
                                parameters: self.parameters,
                                path: path
                            )
                        case .custom(let options):
                            // TODO: It'd be nice if we could do this w/o checking for specific protocols here,
                            // but we're not there quite yet
                            if options.identifier == BridgeStreamProtocol.identifier {
                                let bridge = self.storage.createBridgeStreamInstance()
                                let flow = try StreamEndpointFlowProtocol(
                                    identifier: String(self.identifier),
                                    local: effectiveLocalEndpoint,
                                    remote: self.remoteEndpoint,
                                    parameters: self.parameters,
                                    path: path,
                                    context: context,
                                )
                                self.flowProtocol = .stream(flow)
                                // Attach from the upper linkage so both directions are bound.
                                try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                                    bridge,
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
                    } else {
                        Logger.connection.error("No link protocol")
                        throw NetworkError.posix(EINVAL)
                    }
                } else if stack.applicationProtocols.count == 1 {
                    switch stack.applicationProtocols.first {
                    case .swiftTLS(let tlsOptions):
                        #if !HAS_SWIFTTLS_RECORD || !IMPORT_SWIFTTLS || !canImport(SwiftTLS)
                        // Without the record layer there is nothing to put above the link.
                        _ = tlsOptions
                        Logger.connection.error("Record layer TLS is not built for this configuration")
                        throw NetworkError.posix(EINVAL)
                        #else
                        // TLS over a link protocol, so TLS brings its own record layer:
                        // flow -> record-layer TLS -> link.
                        guard let link = stack.link else {
                            Logger.connection.error("No link protocol below record layer TLS")
                            throw NetworkError.posix(EINVAL)
                        }
                        let linkLower: BaseOutboundStreamLinkage
                        switch link {
                        case .customLink(let linkOptions):
                            linkLower = self.storage.createCustomLinkInstance()
                            linkOptions.setProtocolInstance(linkLower.identifier)
                        case .custom(let linkOptions) where linkOptions.identifier == BridgeStreamProtocol.identifier:
                            linkLower = self.storage.createBridgeStreamInstance()
                        default:
                            Logger.connection.error("Unsupported link protocol below record layer TLS")
                            throw NetworkError.posix(EINVAL)
                        }
                        let (tlsUpper, tlsLower) = self.storage.createSwiftTLSRecordInstance()
                        tlsOptions.setProtocolInstance(tlsUpper.identifier)
                        tlsOptions.setLogID(
                            prefix: "C",
                            parent: String(self.identifier),
                            protocolLogIDNumber: Int(self.identifier)
                        )
                        let flow = try StreamEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            local: effectiveLocalEndpoint,
                            remote: self.remoteEndpoint,
                            parameters: self.parameters,
                            path: path,
                            context: context
                        )
                        self.flowProtocol = .stream(flow)
                        // Attach from the upper linkage so both directions are bound.
                        try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                            tlsLower,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        try tlsUpper.invokeAttachLowerProtocol(
                            linkLower,
                            remote: effectiveRemoteEndpoint,
                            local: effectiveLocalEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        #endif
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
            flow.start { state, connectedError in self.startCompleted(connectedError, in: &state) }
        case .datagram(let flow):
            flow.waitForDisconnected { error in self.state = .failed(error) }
            flow.start { state, connectedError in self.startCompleted(connectedError, in: &state) }
        case .none:
            Logger.connection.error("No current flow")
            throw NetworkError.posix(EINVAL)
        }
    }
}
