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
public struct QUICPathInfo: Sendable, Equatable {
    public let isValidated: Bool
    public let remote: AddressEndpoint
    public let local: AddressEndpoint
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum QUICEvent: DomainSpecificNetworkProtocolEvent {
    public var domain: NetworkEventDomain { .init(domain: "QUIC") }

    #if !NETWORK_NO_SWIFT_QUIC
    case newInboundConnectionID(_ connectionID: QUICConnectionID)
    case retiredInboundConnectionID(_ connectionID: QUICConnectionID)
    case newOutboundConnectionID(_ connectionID: QUICConnectionID, statelessResetToken: QUICStatelessResetToken)
    case retiredOutboundConnectionID(_ connectionID: QUICConnectionID, statelessResetToken: QUICStatelessResetToken)
    #endif
    case remoteBidirectionalStreamsBlocked(maximumStreams: Int)
    case remoteUnidirectionalStreamsBlocked(maximumStreams: Int)
    case maxStreamsLimitBidirectionalUpdated(maximumStreams: Int)
    case maxStreamsLimitUnidirectionalUpdated(maximumStreams: Int)
    case earlyDataRejected
    case receivedRemoteTransportParameters(transportParameters: [UInt8])
    case pathChanged(_ info: QUICPathInfo)
    case pathValidated(_ info: QUICPathInfo)
    case pathUnreachable(_ info: QUICPathInfo)

    public var description: String {
        switch self {
        #if !NETWORK_NO_SWIFT_QUIC
        case .newInboundConnectionID(let connectionID):
            return "QUIC: New inbound connection ID: \(connectionID)"
        case .retiredInboundConnectionID(let connectionID):
            return "QUIC: Retired inbound connection ID: \(connectionID)"
        case .newOutboundConnectionID(let connectionID, _):
            return
                "QUIC: New outbound connection ID: \(connectionID)"
        case .retiredOutboundConnectionID(let connectionID, _):
            return
                "QUIC: Retired outbound connection ID: \(connectionID)"
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
        case .pathChanged(let pathInfo):
            return
                "QUIC: Path changed local: \(pathInfo.local.description) remote: \(pathInfo.remote.description) validated: \(pathInfo.isValidated)"
        case .pathValidated(let pathInfo):
            return
                "QUIC: Path validated local: \(pathInfo.local.description) remote: \(pathInfo.remote.description)"
        case .pathUnreachable(let pathInfo):
            return
                "QUIC: Path unreachable local: \(pathInfo.local.description) remote: \(pathInfo.remote.description)"
        }
    }
}
