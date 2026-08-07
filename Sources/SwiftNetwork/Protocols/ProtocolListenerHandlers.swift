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
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference,
        flowMetadata: AbstractProtocolMetadata?
    )
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {
    func handleNewInboundFlowEvent(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference,
        flowMetadata: AbstractProtocolMetadata?
    ) {
        switch reference {
        case .none: return
        #if !NETWORK_NO_SWIFT_QUIC && !NETWORK_NO_TESTING_HARNESS
        case .newStreamFlowHarness(let instance):
            return instance.handleNewInboundFlowEvent(from, flowReference: flowReference, flowMetadata: flowMetadata)
        case .newDatagramFlowHarness(let instance):
            return instance.handleNewInboundFlowEvent(from, flowReference: flowReference, flowMetadata: flowMetadata)
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            return container.accessInboundFlowHandler(at: index) {
                $0.handleNewInboundFlowEvent(from, flowReference: flowReference, flowMetadata: flowMetadata)
            }
        #endif
        default: fatalError("Protocol cannot accept handleNewInboundFlowEvent")
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ListenerHandler: ~Copyable, LowerProtocolHandler where UpperProtocol: InboundFlowLinkage {
    #if !NETWORK_EMBEDDED
    // Create a new flow
    mutating func attachUpperProtocolToNewFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage

    // Attach to an inbound flow
    mutating func attachUpperProtocolToExistingFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> Linkage
    #endif
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DatagramListenerHandler: ~Copyable, ListenerHandler
where UpperProtocol.DataLinkage == OutboundDatagramLinkage {
    mutating func attachNewDatagramFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> DatagramListenerLinkage

    // Create a new flow
    mutating func attachUpperDatagramProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundDatagramLinkage

    // Attach to an inbound flow
    mutating func attachUpperDatagramProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundDatagramLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StreamListenerHandler: ~Copyable, ListenerHandler
where UpperProtocol.DataLinkage == OutboundStreamLinkage {
    mutating func attachNewStreamFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> StreamListenerLinkage

    // Create a new flow
    mutating func attachUpperStreamProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage

    // Attach to an inbound flow
    mutating func attachUpperStreamProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundStreamLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol HeterogeneousListenerHandler: ~Copyable, ListenerHandler {
    associatedtype SecondaryUpperProtocol: InboundFlowLinkage
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {
    #if !NETWORK_EMBEDDED
    func attachUpperProtocolToNewFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperProtocolToNewFlow(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            case .custom(let container, let index):
                return try container.accessListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperProtocolToNewFlow(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            default: fatalError("Protocol cannot accept attachUpperProtocolToNewFlow call")
            }
        }
    }
    #endif

    func attachNewDatagramFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> DatagramListenerLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachNewDatagramFlowProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessDatagramListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachNewDatagramFlowProtocol(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachNewStreamFlowProtocol call")
            }
        }
    }

    func attachNewStreamFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> StreamListenerLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachNewStreamFlowProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessStreamListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachNewStreamFlowProtocol(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachNewStreamFlowProtocol call")
            }
        }
    }

    func attachUpperDatagramProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperDatagramProtocolToNewFlow(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessDatagramListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperDatagramProtocolToNewFlow(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperDatagramProtocolToNewFlow call")
            }
        }
    }

    func attachUpperStreamProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperStreamProtocolToNewFlow(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessStreamListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperStreamProtocolToNewFlow(
                        from,
                        remote: remote,
                        local: local,
                        parameters: parameters,
                        path: path
                    )
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperStreamProtocolToNewFlow call")
            }
        }
    }

    #if !NETWORK_EMBEDDED
    func attachUpperProtocolToExistingFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> Linkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperProtocolToExistingFlow(from, flowReference: flowReference)
            #endif
            case .custom(let container, let index):
                return try container.accessListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperProtocolToExistingFlow(from, flowReference: flowReference)
                }
            default: fatalError("Protocol cannot accept attachUpperProtocolToExistingFlow call")
            }
        }
    }
    #endif

    func attachUpperDatagramProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperDatagramProtocolToExistingFlow(from, flowReference: flowReference)
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessDatagramListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperDatagramProtocolToExistingFlow(from, flowReference: flowReference)
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperDatagramProtocolToExistingFlow call")
            }
        }
    }

    func attachUpperStreamProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundStreamLinkage {
        try self.handleCallFromUpperProtocol { () throws(NetworkError) in
            switch self.reference {
            case .none: fatalError("Cannot attach to empty protocol")
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(var instance):
                return try instance.attachUpperStreamProtocolToExistingFlow(from, flowReference: flowReference)
            #endif
            #if !NETWORK_EMBEDDED
            case .custom(let container, let index):
                return try container.accessStreamListenerHandler(at: index) { instance throws(NetworkError) in
                    try instance.attachUpperStreamProtocolToExistingFlow(from, flowReference: flowReference)
                }
            #endif
            default: fatalError("Protocol cannot accept attachUpperStreamProtocolToExistingFlow call")
            }
        }
    }

    func deliverEnqueuedInboundStreamData(flowReference: ProtocolInstanceReference) throws(NetworkError) {
        try self.fromExternal { () throws(NetworkError) in
            switch self.reference {
            #if !NETWORK_NO_SWIFT_QUIC
            case .quic(let instance):
                try instance.deliverEnqueuedInboundStreamData(
                    flow: MultiplexedFlowIdentifier(inboundReference: flowReference)
                )
            #endif
            default:
                return
            }
        }
    }
}
