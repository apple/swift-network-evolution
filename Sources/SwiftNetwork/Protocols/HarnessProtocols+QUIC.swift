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
#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if !NETWORK_NO_TESTING_HARNESS

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension NewFlowHarness {
    public struct Completions {
        public var connected: ((Bool) -> Void)?
        public var disconnected: (() -> Void)?
        var newFlow = Deque<(() -> Void)>()
        public var error: ((NetworkError) -> Void)?  // invoked when error detected
        public var pathChanged: ((QUICPathInfo) -> Void)?
        public var pathValidated: ((QUICPathInfo) -> Void)?
        public var pathUnreachable: ((QUICPathInfo) -> Void)?
        public init() {}
    }

    public func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        log.debug("Received network protocol event: \(event)")
        #if !NETWORK_NO_SWIFT_QUIC
        if let quicEvent = event.quicEvent {
            switch quicEvent {
            case .newInboundConnectionID: newInboundCIDEventCount += 1
            case .newOutboundConnectionID(let connectionID, let statelessResetToken):
                newOutboundCIDEventCount += 1
                lastNewOutboundConnectionID = connectionID
                lastNewOutboundStatelessResetToken = statelessResetToken
            case .retiredOutboundConnectionID(let connectionID, let statelessResetToken):
                retiredOutboundCIDEventCount += 1
                lastRetiredOutboundConnectionID = connectionID
                lastRetiredOutboundStatelessResetToken = statelessResetToken
            case .pathChanged(let info):
                if let completion = completions.pathChanged {
                    completion(info)
                }
            case .pathValidated(let info):
                if let completion = completions.pathValidated {
                    completion(info)
                }
            case .pathUnreachable(let info):
                if let completion = completions.pathUnreachable {
                    completion(info)
                }
            default: break
            }
        }
        #endif
    }
}
#endif
