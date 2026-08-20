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
public protocol InboundDataHandler: ~Copyable, UpperProtocolHandler {
    mutating func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference)
    mutating func handleOutboundRoomAvailableEvent(_ from: ProtocolInstanceReference)
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {
    func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
        switch reference {
        case .none: return
        case .tcp(var instance): instance.handleInboundDataAvailableEvent(from)
        case .udp(let index): context.udpInstances[index].handleInboundDataAvailableEvent(from)
        case .ip(let index): context.ipInstances[index].handleInboundDataAvailableEvent(from)
        case .tls(let instance): instance.handleInboundDataAvailableEvent(from)
        case .tlsEncryptionLevel(let instance): instance.handleInboundDataAvailableEvent(from)
        case .streamEndpointFlow(let instance): instance.handleInboundDataAvailableEvent(from)
        case .datagramEndpointFlow(let instance): instance.handleInboundDataAvailableEvent(from)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(var instance): instance.handleInboundDataAvailableEvent(from)
        case .quicCrypto(let instance): instance.handleInboundDataAvailableEvent(from)
        #endif
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleInboundDataAvailableEvent(from)
        case .datagramUpperHarness(let instance): instance.handleInboundDataAvailableEvent(from)
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            return container.accessInboundDataHandler(at: index) { $0.handleInboundDataAvailableEvent(from) }
        #endif
        default: fatalError("Protocol cannot accept handleInboundDataAvailableEvent event")
        }
    }
    func handleOutboundRoomAvailableEvent(_ from: ProtocolInstanceReference) {
        switch reference {
        case .none: return
        case .tcp(var instance): instance.handleOutboundRoomAvailableEvent(from)
        case .udp(let index): context.udpInstances[index].handleOutboundRoomAvailableEvent(from)
        case .ip(let index): context.ipInstances[index].handleOutboundRoomAvailableEvent(from)
        case .tls(var instance): instance.handleOutboundRoomAvailableEvent(from)
        case .tlsEncryptionLevel(let instance): instance.handleOutboundRoomAvailableEvent(from)
        case .streamEndpointFlow(let instance): instance.handleOutboundRoomAvailableEvent(from)
        case .datagramEndpointFlow(let instance): instance.handleOutboundRoomAvailableEvent(from)
        #if !NETWORK_NO_SWIFT_QUIC
        case .quicPath(var instance): instance.handleOutboundRoomAvailableEvent(from)
        case .quicCrypto(let instance): instance.handleOutboundRoomAvailableEvent(from)
        #endif
        #if !NETWORK_NO_TESTING_HARNESS
        case .streamUpperHarness(let instance): instance.handleOutboundRoomAvailableEvent(from)
        case .datagramUpperHarness(let instance): instance.handleOutboundRoomAvailableEvent(from)
        #endif

        #if !NETWORK_EMBEDDED
        case .custom(let container, let index):
            return container.accessInboundDataHandler(at: index) { $0.handleOutboundRoomAvailableEvent(from) }
        #endif
        default: fatalError("Protocol cannot accept handleOutboundRoomAvailableEvent event")
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OutboundDataHandler: ~Copyable, LowerProtocolHandler {}
