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
public struct NetworkEventDomain: Sendable, Hashable, CustomStringConvertible {
    let domain: String
    public var description: String { domain }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
/// An extensible event that a lower protocol reports to upper protocols.
public struct NetworkProtocolEvent: Sendable, Equatable, CustomStringConvertible {
    enum InternalEvent: Equatable {
        case viabilityChanged(viable: Bool)
        case pathPrimaryChanged(primary: Bool)
        case quic(event: QUICEvent)
        #if !NETWORK_EMBEDDED
        case custom(event: any DomainSpecificNetworkProtocolEvent)
        #endif

        static func == (lhs: NetworkProtocolEvent.InternalEvent, rhs: NetworkProtocolEvent.InternalEvent) -> Bool {
            switch (lhs, rhs) {
            case (.viabilityChanged(let lEvent), .viabilityChanged(let rEvent)):
                return lEvent == rEvent
            case (.quic(let lEvent), .quic(let rEvent)):
                return lEvent == rEvent
            case (.pathPrimaryChanged(let lEvent), .pathPrimaryChanged(let rEvent)):
                return lEvent == rEvent
            default:
                return false
            }
        }
    }
    let internalEvent: InternalEvent

    var domain: NetworkEventDomain? {
        switch internalEvent {
        case .quic(let event): return event.domain
        #if !NETWORK_EMBEDDED
        case .custom(let event): return event.domain
        #endif
        default: return nil
        }
    }

    internal init(internalEvent: InternalEvent) {
        self.internalEvent = internalEvent
    }

    public init(quicEvent: QUICEvent) {
        self.internalEvent = .quic(event: quicEvent)
    }

    static public func viabilityChanged(isViable: Bool) -> NetworkProtocolEvent {
        .init(internalEvent: .viabilityChanged(viable: isViable))
    }

    static public var pathIsPrimary: NetworkProtocolEvent {
        .init(internalEvent: .pathPrimaryChanged(primary: true))
    }

    static public var pathIsNotPrimary: NetworkProtocolEvent {
        .init(internalEvent: .pathPrimaryChanged(primary: false))
    }

    #if !NETWORK_EMBEDDED
    public init(custom: (any DomainSpecificNetworkProtocolEvent)) {
        self.internalEvent = .custom(event: custom)
    }
    #endif

    public var description: String {
        switch internalEvent {
        case .quic(let event): return event.description
        case .viabilityChanged(let viable):
            if viable {
                return "Viable"
            } else {
                return "Not Viable"
            }
        case .pathPrimaryChanged(let primary):
            if primary {
                return "Primary Path"
            } else {
                return "Not Primary Path"
            }
        #if !NETWORK_EMBEDDED
        case .custom(let event): return event.description
        #endif
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
/// An extensible event from the app, sent from upper protocols to lower protocols.
public struct ApplicationEvent: Sendable, Equatable, CustomStringConvertible {
    enum InternalEvent: Equatable {
        case dataStall
        case connectionIdle(idle: Bool)
        case outboundDataPending(pending: Bool)
        case quic(event: QUICApplicationEvent)
        #if !NETWORK_EMBEDDED
        case custom(event: any DomainSpecificApplicationEvent)
        #endif

        static func == (lhs: ApplicationEvent.InternalEvent, rhs: ApplicationEvent.InternalEvent) -> Bool {
            switch (lhs, rhs) {
            case (.dataStall, .dataStall): return true
            case (.connectionIdle(let lState), .connectionIdle(let rState)): return lState == rState
            case (.outboundDataPending(let lState), .outboundDataPending(let rState)): return lState == rState
            default:
                return false
            }
        }
    }
    let internalEvent: InternalEvent

    var domain: NetworkEventDomain? {
        switch internalEvent {
        case .dataStall: return nil
        case .connectionIdle: return nil
        case .outboundDataPending: return nil
        case .quic(let event): return event.domain
        #if !NETWORK_EMBEDDED
        case .custom(let event): return event.domain
        #endif
        }
    }

    internal init(internalEvent: InternalEvent) {
        self.internalEvent = internalEvent
    }

    static public var dataStall: ApplicationEvent {
        .init(internalEvent: .dataStall)
    }

    static public var connectionIdle: ApplicationEvent {
        .init(internalEvent: .connectionIdle(idle: true))
    }

    static public var connectionReused: ApplicationEvent {
        .init(internalEvent: .connectionIdle(idle: false))
    }

    static public var outboundDataBatchStart: ApplicationEvent {
        .init(internalEvent: .outboundDataPending(pending: true))
    }

    static public var outboundDataBatchEnd: ApplicationEvent {
        .init(internalEvent: .outboundDataPending(pending: false))
    }

    public init(quicEvent: QUICApplicationEvent) {
        self.internalEvent = .quic(event: quicEvent)
    }

    #if !NETWORK_EMBEDDED
    public init(custom: (any DomainSpecificApplicationEvent)) {
        self.internalEvent = .custom(event: custom)
    }
    #endif

    public var description: String {
        switch internalEvent {
        case .dataStall: return "Data Stall"
        case .connectionIdle(let idle):
            if idle {
                return "Connection Idle"
            } else {
                return "Connection Reused"
            }
        case .outboundDataPending(let pending):
            if pending {
                return "Outbound Data Pending"
            } else {
                return "Outbound Data No Longer Pending"
            }
        case .quic(let event): return event.description
        #if !NETWORK_EMBEDDED
        case .custom(let event): return event.description
        #endif
        }
    }
}

#if !NETWORK_EMBEDDED
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DomainSpecificNetworkProtocolEvent: Sendable, Equatable, CustomStringConvertible {
    var domain: NetworkEventDomain { get }
}
#else
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DomainSpecificNetworkProtocolEvent: Sendable, Equatable {
    var domain: NetworkEventDomain { get }
}
#endif

#if !NETWORK_EMBEDDED
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DomainSpecificApplicationEvent: Sendable, Equatable, CustomStringConvertible {
    var domain: NetworkEventDomain { get }
}
#else
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DomainSpecificApplicationEvent: Sendable, Equatable {
    var domain: NetworkEventDomain { get }
}
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum QUICEvent: DomainSpecificNetworkProtocolEvent {
    public var domain: NetworkEventDomain { .init(domain: "QUIC") }

    #if !NETWORK_NO_SWIFT_QUIC
    case newInboundConnectionID(_ connectionID: QUICConnectionID)
    case retiredInboundConnectionID(_ connectionID: QUICConnectionID)
    case newOutboundConnectionID(_ connectionID: QUICConnectionID)
    case retiredOutboundConnectionID(_ connectionID: QUICConnectionID)
    #endif
    case remoteBidirectionalStreamsBlocked(maximumStreams: Int)
    case remoteUnidirectionalStreamsBlocked(maximumStreams: Int)
    case maxStreamsLimitBidirectionalUpdated(maximumStreams: Int)
    case maxStreamsLimitUnidirectionalUpdated(maximumStreams: Int)
    case earlyDataRejected
    case receivedRemoteTransportParameters(transportParameters: [UInt8])

    public var description: String {
        switch self {
        #if !NETWORK_NO_SWIFT_QUIC
        case .newInboundConnectionID(let connectionID):
            return "QUIC: New inbound connection ID: \(connectionID)"
        case .retiredInboundConnectionID(let connectionID):
            return "QUIC: Retired inbound connection ID: \(connectionID)"
        case .newOutboundConnectionID(let connectionID):
            return "QUIC: New outbound connection ID: \(connectionID)"
        case .retiredOutboundConnectionID(let connectionID):
            return "QUIC: Retired outbound connection ID: \(connectionID)"
        #endif
        case .remoteBidirectionalStreamsBlocked(let maximumStreams):
            return "QUIC: Remote bidirectional streams blocked: \(maximumStreams)"
        case .remoteUnidirectionalStreamsBlocked(let maximumStreams):
            return "QUIC: Remote unidirectional streams blocked: \(maximumStreams)"
        case .maxStreamsLimitBidirectionalUpdated(let maximumStreams):
            return "QUIC: Remote bidirectional stream limit updated to: \(maximumStreams)"
        case .maxStreamsLimitUnidirectionalUpdated(let maximumStreams):
            return "QUIC: Remote unidirectional stream limit updated to: \(maximumStreams)"
        case .earlyDataRejected:
            return "QUIC: Early data rejected"
        case .receivedRemoteTransportParameters:
            return "QUIC: Received remote transport parameters"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension NetworkProtocolEvent {
    public var quicEvent: QUICEvent? {
        guard case .quic(let quicEvent) = internalEvent else {
            return nil
        }
        return quicEvent
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum QUICApplicationEvent: DomainSpecificApplicationEvent {
    public var domain: NetworkEventDomain { .init(domain: "QUICApplication") }

    #if !NETWORK_NO_SWIFT_QUIC
    case announceNewInboundConnectionID(_ connectionID: QUICConnectionID, statelessResetToken: QUICStatelessResetToken)
    case retireOutboundConnectionID(_ connectionID: QUICConnectionID)
    #endif
    case updateMaximumBidirectionalStreams(_ maximumStreams: Int)
    case updateMaximumUnidirectionalStreams(_ maximumStreams: Int)

    public var description: String {
        switch self {
        #if !NETWORK_NO_SWIFT_QUIC
        case .announceNewInboundConnectionID(let connectionID, _):
            return "QUIC: Announce new inbound connection ID: \(connectionID)"
        case .retireOutboundConnectionID(let connectionID):
            return "QUIC: Retire outbound connection ID: \(connectionID)"
        #endif
        case .updateMaximumBidirectionalStreams(let maximumStreams):
            return "QUIC: Update maximum bidirectional streams: \(maximumStreams)"
        case .updateMaximumUnidirectionalStreams(let maximumStreams):
            return "QUIC: Update maximum unidirectional streams: \(maximumStreams)"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension ApplicationEvent {
    public var quicEvent: QUICApplicationEvent? {
        guard case .quic(let quicEvent) = internalEvent else {
            return nil
        }
        return quicEvent
    }
}
