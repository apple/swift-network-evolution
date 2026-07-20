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

    #if !NETWORK_EMBEDDED
    mutating func attachLowerProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
    #endif

    mutating func handleConnectedEvent(_ from: ProtocolInstanceReference)
    mutating func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?)
    mutating func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent)
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {
    func handleConnectedEvent(_ from: ProtocolInstanceReference) {
        switch reference {
        case .none: return
        case .tcp(var instance): instance.handleConnectedEvent(from)
        case .udp(let index): context.udpInstances[index].handleConnectedEvent(from)
        case .ip(let index): context.ipInstances[index].handleConnectedEvent(from)
        case .tls(var instance): instance.handleConnectedEvent(from)
        case .tlsEncryptionLevel(let instance): instance.handleConnectedEvent(from)
        case .streamEndpointFlow(let instance): instance.handleConnectedEvent(from)
        case .datagramEndpointFlow(let instance): instance.handleConnectedEvent(from)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let instance): instance.handleConnectedEvent(from)
        case .quicCrypto(let instance): instance.handleConnectedEvent(from)
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleConnectedEvent(from)
        case .datagramUpperHarness(let instance): instance.handleConnectedEvent(from)
        case .newStreamFlowHarness(let instance): instance.handleConnectedEvent(from)
        case .newDatagramFlowHarness(let instance): instance.handleConnectedEvent(from)
        #endif
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            return container.accessUpper(at: index) { $0.handleConnectedEvent(from) }
        #endif
        default: fatalError("Protocol cannot accept handleConnectedEvent event")
        }
    }
    func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        switch reference {
        case .none: return
        case .tcp(var instance): instance.handleDisconnectedEvent(from, error: error)
        case .udp(let index): context.udpInstances[index].handleDisconnectedEvent(from, error: error)
        case .ip(let index): context.ipInstances[index].handleDisconnectedEvent(from, error: error)
        case .tls(var instance): instance.handleDisconnectedEvent(from, error: error)
        case .tlsEncryptionLevel(let instance): instance.handleDisconnectedEvent(from, error: error)
        case .streamEndpointFlow(let instance): instance.handleDisconnectedEvent(from, error: error)
        case .datagramEndpointFlow(let instance): instance.handleDisconnectedEvent(from, error: error)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(let instance): instance.handleDisconnectedEvent(from, error: error)
        case .quicCrypto(let instance): instance.handleDisconnectedEvent(from, error: error)
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleDisconnectedEvent(from, error: error)
        case .datagramUpperHarness(let instance): instance.handleDisconnectedEvent(from, error: error)
        case .newStreamFlowHarness(let instance): instance.handleDisconnectedEvent(from, error: error)
        case .newDatagramFlowHarness(let instance): instance.handleDisconnectedEvent(from, error: error)
        #endif
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            return container.accessUpper(at: index) { $0.handleDisconnectedEvent(from, error: error) }
        #endif
        default: fatalError("Protocol cannot accept handleDisconnectedEvent event")
        }
    }

    func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        switch self.reference {
        case .none: return
        case .udp(let index): context.udpInstances[index].handleNetworkProtocolEvent(from, event: event)
        case .ip(let index): context.ipInstances[index].handleNetworkProtocolEvent(from, event: event)
        case .tcp(var instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .tls(var instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .tlsEncryptionLevel(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .streamEndpointFlow(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .datagramEndpointFlow(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(var instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .quicCrypto(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .datagramUpperHarness(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .newStreamFlowHarness(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        case .newDatagramFlowHarness(let instance): instance.handleNetworkProtocolEvent(from, event: event)
        #endif
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            return container.accessUpper(at: index) { $0.handleNetworkProtocolEvent(from, event: event) }
        #endif
        default: fatalError("Protocol cannot accept handleNetworkProtocolEvent call")
        }
    }

}

/// A protocol closer to the network, with a linkage to an upper protocol toward the app.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol LowerProtocolHandler<UpperProtocol>: ~Copyable, ProtocolInstance {
    associatedtype UpperProtocol: UpperProtocolLinkage

    #if !NETWORK_EMBEDDED
    mutating func attachUpperProtocol<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage
    #endif
    mutating func detach(_ from: ProtocolInstanceReference) throws(NetworkError)

    mutating func connect(_ from: ProtocolInstanceReference)
    mutating func disconnect(_ from: ProtocolInstanceReference, error: NetworkError?)

    mutating func handleApplicationEvent(_ from: ProtocolInstanceReference, event: ApplicationEvent)

    func getMetadata<P: NetworkProtocol>(_ from: ProtocolInstanceReference) -> ProtocolMetadata<P>?
    func getMetrics(
        _ from: ProtocolInstanceReference,
        requestedNetworkMetric: RequestedNetworkMetrics
    ) -> NetworkMetrics?
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {
    func connect(_ from: ProtocolInstanceReference) {
        guard !isNone else { return }
        self.handleCallFromUpperProtocol {
            switch self.reference {
            case .none: return
            case .udp(let index): context.udpInstances[index].connect(from)
            case .ip(let index): context.ipInstances[index].connect(from)
            case .tcp(var instance): instance.connect(from)
            case .tls(var instance): instance.connect(from)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let instance): instance.connect(from)
            case .quicStream(let instance): instance.connect(from)
            case .quicDatagram(let instance): instance.connect(from)
            case .quicCrypto(let instance): instance.connect(from)
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(let instance): instance.connect(from)
            case .streamLowerHarness(let instance): instance.connect(from)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index): return container.accessLower(at: index) { $0.connect(from) }
            #endif
            default: fatalError("Protocol cannot accept connect call")
            }
        }
    }

    func disconnect(_ from: ProtocolInstanceReference, error: NetworkError?) {
        guard !isNone else { return }
        self.handleCallFromUpperProtocol {
            switch self.reference {
            case .none: return
            case .udp(let index): context.udpInstances[index].disconnect(from, error: error)
            case .ip(let index): context.ipInstances[index].disconnect(from, error: error)
            case .tcp(var instance): instance.disconnect(from, error: error)
            case .tls(var instance): instance.disconnect(from, error: error)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let instance): instance.disconnect(from, error: error)
            case .quicStream(let instance): instance.disconnect(from, error: error)
            case .quicDatagram(let instance): instance.disconnect(from, error: error)
            case .quicCrypto(let instance): instance.disconnect(from, error: error)
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(let instance): instance.disconnect(from, error: error)
            case .streamLowerHarness(let instance): instance.disconnect(from, error: error)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return container.accessLower(at: index) { $0.disconnect(from, error: error) }
            #endif
            default: fatalError("Protocol cannot accept disconnect call")
            }
        }
    }

    func handleApplicationEvent(_ from: ProtocolInstanceReference, event: ApplicationEvent) {
        self.handleCallFromUpperProtocol {
            switch self.reference {
            case .none: return
            case .udp(let index): context.udpInstances[index].handleApplicationEvent(from, event: event)
            case .ip(let index): context.ipInstances[index].handleApplicationEvent(from, event: event)
            case .tcp(var instance): instance.handleApplicationEvent(from, event: event)
            case .tls(var instance): instance.handleApplicationEvent(from, event: event)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let instance): instance.handleApplicationEvent(from, event: event)
            case .quicStream(let instance): instance.handleApplicationEvent(from, event: event)
            case .quicDatagram(let instance): instance.handleApplicationEvent(from, event: event)
            case .quicCrypto(let instance): instance.handleApplicationEvent(from, event: event)
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(let instance): instance.handleApplicationEvent(from, event: event)
            case .streamLowerHarness(let instance): instance.handleApplicationEvent(from, event: event)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return container.accessLower(at: index) { $0.handleApplicationEvent(from, event: event) }
            #endif
            default: fatalError("Protocol cannot accept handleApplicationEvent call")
            }
        }
    }

    #if !NETWORK_EMBEDDED
    func attachUpperProtocol<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            case .udp(let index):
                return try context.udpInstances[index].attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .ip(let index):
                return try context.ipInstances[index].attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tcp(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tls(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .quicStream(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .quicDatagram(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .quicCrypto(let instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .datagramLowerHarness(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .streamLowerHarness(var instance):
                return try instance.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessLower(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperProtocol(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperProtocol call")
            }
        }
    }
    #endif

    func attachUpperStreamProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            case .tcp(var instance):
                return try instance.attachUpperStreamProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tls(var instance):
                return try instance.attachUpperStreamProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicStream(let instance):
                return try instance.attachUpperStreamProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .quicCrypto(let instance):
                return try instance.attachUpperStreamProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_TESTING_HARNESS
            case .streamLowerHarness(var instance):
                return try instance.attachUpperStreamProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessOutboundStreamHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperStreamProtocol(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperStreamProtocol call")
            }
        }
    }

    func attachUpperDatagramProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            case .udp(let index):
                return try context.udpInstances[index].attachUpperDatagramProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .ip(let index):
                return try context.ipInstances[index].attachUpperDatagramProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicDatagram(let instance):
                return try instance.attachUpperDatagramProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(var instance):
                return try instance.attachUpperDatagramProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessOutboundDatagramHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperDatagramProtocol(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperDatagramProtocol call")
            }
        }
    }

    #if !NETWORK_EMBEDDED
    public func attachLowerProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try self.fromExternal { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            case .udp(let index):
                try context.udpInstances[index].attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .ip(let index):
                try context.ipInstances[index].attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tcp(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tls(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tlsEncryptionLevel(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .streamEndpointFlow(let instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .datagramEndpointFlow(let instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicPath(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .quicCrypto(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .streamUpperHarness(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .datagramUpperHarness(var instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .newStreamFlowHarness(let instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .newDatagramFlowHarness(let instance):
                try instance.attachLowerProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            case .custom(let container, let index):
                try container.accessUpper(at: index) { instance throws(NetworkError) in
                    try instance.attachLowerProtocol(
                        lowerProtocol,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            default: fatalError("Protocol cannot accept attachLowerProtocol call")
            }
        }
    }
    #endif

    public func attachLowerDatagramProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try self.fromExternal { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            case .udp(let index):
                try context.udpInstances[index].attachLowerDatagramProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .ip(let index):
                try context.ipInstances[index].attachLowerDatagramProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tcp(var instance):
                try instance.attachLowerDatagramProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .datagramEndpointFlow(let instance):
                try instance.attachLowerDatagramProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicPath(let instance):
                try instance.attachLowerDatagramProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramUpperHarness(var instance):
                try instance.attachLowerDatagramProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                try container.accessInboundDatagramHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachLowerDatagramProtocol(
                        lowerProtocol,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachLowerDatagramProtocol call")
            }
        }
    }

    public func attachLowerStreamProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try self.fromExternal { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            case .tls(var instance):
                try instance.attachLowerStreamProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .tlsEncryptionLevel(var instance):
                try instance.attachLowerStreamProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            case .streamEndpointFlow(let instance):
                try instance.attachLowerStreamProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_SWIFT_QUIC
            case .quicCrypto(var instance):
                try instance.attachLowerStreamProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #if !NETWORK_NO_TESTING_HARNESS
            case .streamUpperHarness(var instance):
                try instance.attachLowerStreamProtocol(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                try container.accessInboundStreamHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachLowerStreamProtocol(
                        lowerProtocol,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachLowerStreamProtocol call")
            }
        }
    }

    #if !NETWORK_EMBEDDED
    public func attachLowerProtocolForNewPath(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try self.fromExternal { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                try instance.attachLowerProtocolForNewPath(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            case .custom(let container, let index):
                return try container.accessManyToMany(at: index) { instance throws(NetworkError) in
                    try instance.attachLowerProtocolForNewPath(
                        lowerProtocol,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            default: fatalError("Protocol cannot accept attachLowerProtocolForNewPath call")
            }
        }
    }
    #endif

    public func attachLowerDatagramProtocolForNewPath(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try self.fromExternal { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                try instance.attachLowerDatagramProtocolForNewPath(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessManyToMany(at: index) { instance throws(NetworkError) in
                    try instance.attachLowerProtocolForNewPath(
                        lowerProtocol,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachLowerDatagramProtocolForNewPath call")
            }
        }
    }

    public func detach(_ from: ProtocolInstanceReference) throws(NetworkError) {
        guard !isNone else { return }
        return try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: return
            case .udp(let index):
                try context.udpInstances[index].detach(from)
                context.unregisterUDPInstance(index)
            case .ip(let index):
                try context.ipInstances[index].detach(from)
                context.unregisterIPInstance(index)
            case .tcp(var instance): try instance.detach(from)
            case .tls(var instance): try instance.detach(from)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance): try instance.detach(from)
            case .quicStream(var instance): try instance.detach(from)
            case .quicDatagram(var instance): try instance.detach(from)
            case .quicCrypto(let instance): try instance.detach(from)
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(var instance): try instance.detach(from)
            case .streamLowerHarness(var instance): try instance.detach(from)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                try container.accessLower(at: index) { instance throws(NetworkError) in
                    try instance.detach(from)
                }
            #endif
            default: fatalError("Protocol cannot accept detach call")
            }
        }
    }

    public func getMetadata<P: NetworkProtocol>(_ from: ProtocolInstanceReference) -> ProtocolMetadata<P>? {
        self.handleCallFromUpperProtocol {
            switch self.reference {
            case .none: return nil
            case .udp(let index): return context.udpInstances[index].getMetadata(from)
            case .ip(let index): return context.ipInstances[index].getMetadata(from)
            case .tcp(let instance): return instance.getMetadata(from)
            case .tls(let instance): return instance.getMetadata(from)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let instance): return instance.getMetadata(from)
            case .quicStream(let instance): return instance.getMetadata(from)
            case .quicDatagram(let instance): return instance.getMetadata(from)
            case .quicCrypto(let instance): return instance.getMetadata(from)
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(let instance): return instance.getMetadata(from)
            case .streamLowerHarness(let instance): return instance.getMetadata(from)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index): return container.accessLower(at: index) { $0.getMetadata(from) }
            #endif
            default: fatalError("Protocol cannot accept getMetadata call")
            }
        }
    }

    public func getPathEndpoints(
        _ from: ProtocolInstanceReference
    ) -> DatagramPathEndpoints? {
        guard !isNone else { return nil }
        return self.handleCallFromUpperProtocol {
            switch self.reference {
            case .udp(let index): return context.udpInstances[index].pathEndpoints()
            default: return nil
            }
        }
    }

    public func getMetrics(
        _ from: ProtocolInstanceReference,
        requestedNetworkMetric: RequestedNetworkMetrics
    ) -> NetworkMetrics? {
        self.handleCallFromUpperProtocol {
            switch self.reference {
            case .none: return nil
            case .udp(let index):
                return context.udpInstances[index].getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .ip(let index):
                return context.ipInstances[index].getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .tcp(let instance): return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .tls(let instance): return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let instance): return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .quicStream(let instance):
                return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .quicDatagram(let instance):
                return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .quicCrypto(let instance):
                return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            #if !NETWORK_NO_TESTING_HARNESS
            case .datagramLowerHarness(let instance):
                return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            case .streamLowerHarness(let instance):
                return instance.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
            #endif
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return container.accessLower(at: index) {
                    $0.getMetrics(from, requestedNetworkMetric: requestedNetworkMetric)
                }
            #endif
            default: fatalError("Protocol cannot accept getMetrics call")
            }
        }
    }
}
