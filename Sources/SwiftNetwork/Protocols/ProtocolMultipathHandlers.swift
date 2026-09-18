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
public protocol MultipathProtocolHandler<MultipathLowerProtocol>: ~Copyable, ProtocolInstance {
    associatedtype MultipathLowerProtocol: LowerProtocolLinkage

    mutating func attachLowerProtocolForNewPath(
        _ lowerProtocol: MultipathLowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> MultipathLowerProtocol.PairedUpperLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DatagramMultipathProtocolHandler: ~Copyable, MultipathProtocolHandler where MultipathLowerProtocol: OutboundDatagramLinkage { }
