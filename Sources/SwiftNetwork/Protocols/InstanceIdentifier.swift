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

/// A unique identifier of a particular protocol instance that has been instantiated and registered
/// with a NetworkContext.EventContext. Each protocol in the stack will have one of these, and
/// this type can be used for comparison and hashing.
@_spi(Essentials)
@available(Network 0.1.0, *)
public struct InstanceIdentifier: Hashable {

    let eventStateIndex: NetworkStateIndex

    var parentEventStateIndex: NetworkStateIndex = .none

    func protocolEventStateIndex(allowParent: Bool = true) -> NetworkStateIndex {
        if allowParent, !parentEventStateIndex.isNone { return parentEventStateIndex }
        return eventStateIndex
    }

    var protocolEventStateIndex: NetworkStateIndex {
        protocolEventStateIndex()
    }

    public mutating func setParentInstance(_ parentInstance: InstanceIdentifier) {
        parentEventStateIndex = parentInstance.eventStateIndex
    }

    public init() {
        eventStateIndex = .none
    }

    public init(context: NetworkContext, eventManager: inout ProtocolEventManager) {
        self.eventStateIndex = eventManager.register(with: context, in: &context.eventContext)
    }

    /// Registers using an event context the caller already holds.
    ///
    /// Use this instead of `init(context:eventManager:)` when constructing an identifier from
    /// inside a call that already has the state, so the state isn't re-derived from the context.
    public init(
        eventManager: inout ProtocolEventManager,
        context: NetworkContext,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.eventStateIndex = eventManager.register(with: context, in: &eventContext)
    }

    public var isNone: Bool {
        eventStateIndex.isNone
    }
}
