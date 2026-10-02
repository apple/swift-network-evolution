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
    mutating func initForReuse(_ flow: borrowing EndpointFlow) {}
}

@available(Network 0.1.0, *)
extension EndpointFlow {

    internal mutating func startOnQueue<P: EndpointFlowParent>(_ parent: P) throws(NetworkError) {
        parameters.context.assert()
        self.state = .setup

        #if !NETWORK_NO_SWIFT_QUIC
        // An application protocol above a stream the peer opened only starts reading once it is
        // wired up, so whatever the stack buffered in the meantime is replayed after start.
        var replayInboundStreamData: InstanceIdentifier? = nil
        #endif

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

                // Reuse opens a flow on the connection the options already name. The storage is
                // inherited from the flow being reused, so the listener linkage for that existing
                // connection resolves here.
                guard let listener = self.quicStreamListenerLinkage else {
                    Logger.connection.error("Unable to find the connection to reuse")
                    throw NetworkError.posix(ENOENT)
                }
                if let adoptedInboundFlowInstance {
                    // Joining a stream the peer opened. The connection already built an instance
                    // for it, so attach to that one and keep the linkage it hands back as this
                    // flow's lower; there is no second attach for the other direction.
                    //
                    // A stack can also name an application protocol above the stream. When it
                    // does, that protocol takes the stream as its lower and the flow attaches
                    // above it instead.
                    if let applicationLower = try self.bindInboundApplicationProtocol(
                        listener: listener,
                        flowInstance: adoptedInboundFlowInstance
                    ) {
                        try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                            applicationLower,
                            remote: self.remoteEndpoint,
                            local: self.localEndpoint,
                            parameters: self.parameters,
                            path: path
                        )
                        replayInboundStreamData = adoptedInboundFlowInstance
                    } else {
                        flow.lower = try listener.invokeAttachUpperProtocolToExistingFlow(
                            BaseNetworkProtocolStorage.linkage(for: flow),
                            existingFlowInstance: adoptedInboundFlowInstance
                        )
                    }
                } else if let application = try self.buildStreamApplicationProtocol() {
                    // Opening a stream on a stack that names an application protocol: the protocol
                    // goes between the flow and the new QUIC stream, so the flow takes it as its
                    // lower and it takes the stream as its own.
                    try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                        application.lower,
                        remote: self.remoteEndpoint,
                        local: self.localEndpoint,
                        parameters: self.parameters,
                        path: path
                    )
                    try listener.invokeAttachUpperProtocolToNewFlow(
                        application.upper,
                        remote: self.remoteEndpoint,
                        local: self.localEndpoint,
                        parameters: self.parameters,
                        path: path
                    )
                } else {
                    try listener.invokeAttachUpperProtocolToNewFlow(
                        BaseNetworkProtocolStorage.linkage(for: flow),
                        remote: self.remoteEndpoint,
                        local: self.localEndpoint,
                        parameters: self.parameters,
                        path: path
                    )
                }
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
                    let (quicStreamListener, quicDatagramListener, quicMultipath) =
                        self.storage.createQUICInstance()

                    self.quicConnectionInstance = quicStreamListener.identifier
                    self.quicStreamListenerLinkage = quicStreamListener

                    options.setProtocolInstance(quicStreamListener.identifier)
                    options.setLogID(
                        prefix: "C",
                        parent: String(self.identifier),
                        protocolLogIDNumber: Int(self.identifier)
                    )

                    // This flow is the connection itself, not a stream on it. It attaches to the
                    // listener rather than to a flow, so it has no data path: the application
                    // opens streams, each of which gets its own channel and its own flow. The
                    // connection reports whether it came up and which streams the peer opened.
                    let flow = InboundStreamEndpointFlowProtocol(
                        identifier: String(self.identifier),
                        context: context
                    )
                    self.flowProtocol = .inboundStream(flow)

                    try BaseNetworkProtocolStorage.linkage(for: flow).invokeAttachLowerProtocol(
                        quicStreamListener,
                        remote: effectiveRemoteEndpoint,
                        local: effectiveLocalEndpoint,
                        parameters: self.parameters,
                        path: path
                    )

                    // Datagram flows are only negotiated when the stack asked for them, so only
                    // then is there anything for a connection-level datagram flow to observe.
                    if let maxDatagramFrameSize = options.perProtocolOptions?.quicConnectionOptions
                        .maxDatagramFrameSize, maxDatagramFrameSize > 0
                    {
                        let datagramFlow = InboundDatagramEndpointFlowProtocol(
                            identifier: String(self.identifier),
                            context: context
                        )
                        self.quicDatagramConnectionFlow = datagramFlow
                        try BaseNetworkProtocolStorage.linkage(for: datagramFlow)
                            .invokeAttachLowerProtocol(
                                quicDatagramListener,
                                remote: effectiveRemoteEndpoint,
                                local: effectiveLocalEndpoint,
                                parameters: self.parameters,
                                path: path
                            )
                    }

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
        // Record the hook the stack uses to hand events back, then start. `invokeConnect` drains
        // the event queue inline, so the connect can complete before `start()` returns; that is
        // why nothing is consumed here. The caller drains once this returns and it is safe to
        // take the flow again.
        let wakeFlow: (inout NetworkContext.EventContext) -> Void = { [parent] eventContext in
            parent.drainFlowEvents(in: &eventContext)
        }
        #if !NETWORK_NO_SWIFT_QUIC
        // The datagram side shares the connection's flow, so it reports through the same hook.
        // It needs no `start()` of its own: the stream side brings the connection up.
        self.quicDatagramConnectionFlow?.wakeFlow = wakeFlow
        #endif
        switch self.flowProtocol {
        case .stream(let flow):
            flow.wakeFlow = wakeFlow
            flow.start()
        case .datagram(let flow):
            flow.wakeFlow = wakeFlow
            flow.start()
        case .inboundStream(let flow):
            flow.wakeFlow = wakeFlow
            flow.start()
        case .inboundDatagram(let flow):
            flow.wakeFlow = wakeFlow
            flow.start()
        case .none:
            Logger.connection.error("No current flow")
            throw NetworkError.posix(EINVAL)
        }

        #if !NETWORK_NO_SWIFT_QUIC
        if let replayInboundStreamData, let listener = self.quicStreamListenerLinkage,
            let quic = listener.storage?.quicInstance(for: listener)
        {
            // Events on a stream flow are queued against the connection the flow belongs to, so
            // the connection's event state is the one that has to be in a call here -- entering
            // this flow's own state would leave the connection idle and the delivery would have
            // nowhere to go. The events this records are consumed by the drain that follows
            // `start()`.
            quic.fromExternal { eventContext in
                do {
                    try quic.deliverEnqueuedInboundStreamData(
                        flow: .init(flowInstance: replayInboundStreamData),
                        in: &eventContext
                    )
                } catch {
                    Logger.connection.error(
                        "Failed to replay buffered inbound stream data: \(error)"
                    )
                }
            }
        }
        #endif
    }

    #if !NETWORK_NO_SWIFT_QUIC
    /// Builds the application protocol for a stream the peer opened and binds it onto that stream.
    ///
    /// Returns the linkage this flow attaches to, or nil when the stack carries no application
    /// protocol and the flow binds straight onto the stream.
    private func bindInboundApplicationProtocol(
        listener: BaseStreamListenerLinkage,
        flowInstance: InstanceIdentifier
    ) throws(NetworkError) -> BaseOutboundStreamLinkage? {
        let applicationProtocols = self.parameters.defaultStack.applicationProtocols
        guard !applicationProtocols.isEmpty else {
            return nil
        }
        guard applicationProtocols.count == 1 else {
            Logger.connection.error(
                "Cannot attach \(applicationProtocols.count) application protocols to a stream"
            )
            return nil
        }
        switch applicationProtocols.first {
        case .swiftTLS(let options):
            #if !HAS_SWIFTTLS_RECORD || !IMPORT_SWIFTTLS || !canImport(SwiftTLS)
            // Without the record layer there is nothing to put above the stream.
            _ = options
            Logger.connection.error("Record layer TLS is not built for this configuration")
            throw NetworkError.posix(ENOTSUP)
            #else
            let tlsInstance = SwiftTLSRecordStreamInstance(context: self.context)
            options.setProtocolInstance(tlsInstance.identifier)
            options.setLogID(
                prefix: "C",
                parent: String(self.identifier),
                protocolLogIDNumber: Int(self.identifier)
            )
            // The stream exists, so only this direction is attached: pairing it again through the
            // linkage would bind the stream's upper a second time.
            tlsInstance.lower = try listener.invokeAttachUpperProtocolToExistingFlow(
                tlsInstance.asUpper,
                existingFlowInstance: flowInstance
            )
            return tlsInstance.asLower
            #endif
        #if !NETWORK_EMBEDDED
        case .custom(let options):
            // A protocol from outside the framework supplies its own instance rather than being
            // built generically, and a stream needs one instance per stream, so its owner is asked
            // for one here.
            guard let provider = self.streamApplicationProtocols.inboundProvider else {
                Logger.connection.error(
                    "Application protocol \(options.identifier.name) must supply its own instance for inbound streams"
                )
                throw NetworkError.posix(ENOTSUP)
            }
            return try provider(listener, flowInstance, self.context)
        #endif
        default:
            Logger.connection.error("Unsupported application protocol on inbound stream")
            throw NetworkError.posix(ENOTSUP)
        }
    }

    /// Builds the application protocol for a stream being opened on this connection.
    ///
    /// Returns the pair of linkages to splice between the flow and the new QUIC stream, or nil
    /// when the stack carries no application protocol and the flow binds straight onto the stream.
    private func buildStreamApplicationProtocol() throws(NetworkError) -> (
        upper: BaseInboundStreamLinkage, lower: BaseOutboundStreamLinkage
    )? {
        let applicationProtocols = self.parameters.defaultStack.applicationProtocols
        guard !applicationProtocols.isEmpty else {
            return nil
        }
        guard applicationProtocols.count == 1 else {
            Logger.connection.error(
                "Cannot attach \(applicationProtocols.count) application protocols to a stream"
            )
            return nil
        }
        switch applicationProtocols.first {
        case .swiftTLS(let options):
            #if !HAS_SWIFTTLS_RECORD || !IMPORT_SWIFTTLS || !canImport(SwiftTLS)
            // Without the record layer there is nothing to put above the stream.
            _ = options
            Logger.connection.error("Record layer TLS is not built for this configuration")
            throw NetworkError.posix(ENOTSUP)
            #else
            let tlsInstance = SwiftTLSRecordStreamInstance(context: self.context)
            options.setProtocolInstance(tlsInstance.identifier)
            options.setLogID(
                prefix: "C",
                parent: String(self.identifier),
                protocolLogIDNumber: Int(self.identifier)
            )
            return (tlsInstance.asUpper, tlsInstance.asLower)
            #endif
        #if !NETWORK_EMBEDDED
        case .custom(let options):
            // As on the inbound side, a protocol from outside the framework is built by its owner,
            // one instance per stream.
            guard let factory = self.streamApplicationProtocols.factory else {
                Logger.connection.error(
                    "Application protocol \(options.identifier.name) must supply its own instance for streams"
                )
                throw NetworkError.posix(ENOTSUP)
            }
            return try factory(self.context)
        #endif
        default:
            Logger.connection.error("Unsupported application protocol on stream")
            throw NetworkError.posix(ENOTSUP)
        }
    }
    #endif
}
