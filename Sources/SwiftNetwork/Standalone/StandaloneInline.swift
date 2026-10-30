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

#if !NETWORK_EMBEDDED

// A standalone protocol's owner is outside the protocol and calls in from one thread, so the
// application above a standalone link can never be running when the protocol raises an event.
// Handing the event to the link on the spot is therefore the same as queueing it, and cheaper: no
// pending-event value, no closure, no queue on either side, no state to hold and drain.
//
// The links below only record the event for the owner, so they never call back into a protocol. The
// one event that would (a new inbound flow attaches to the flow the protocol made) is recorded
// the same way and attached when the owner takes it from the queue, outside any call into the
// protocol: see `NetworkContext.EventContext.standaloneNextEvent()`.

@available(Network 0.1.0, *)
extension BaseInboundStreamLinkage {
    public var deliversInline: Bool {
        if case .standalone = protocolType { return true }
        return false
    }

    public func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneFlowLink(resolving: identifier, in: &eventContext)
        link.deliverInline(event, from: instance, in: &eventContext)
    }

    public func deliverInlineDisconnected(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneFlowLink(resolving: identifier, in: &eventContext)
        link.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    public func deliverInlineInboundDataAvailable(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneFlowLink(resolving: identifier, in: &eventContext)
        link.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension BaseInboundDatagramLinkage {
    public var deliversInline: Bool {
        if case .standalone = protocolType { return true }
        return false
    }

    public func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneFlowLink(resolving: identifier, in: &eventContext)
        link.deliverInline(event, from: instance, in: &eventContext)
    }

    public func deliverInlineDisconnected(
        error: NetworkError?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneFlowLink(resolving: identifier, in: &eventContext)
        link.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    public func deliverInlineInboundDataAvailable(
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneFlowLink(resolving: identifier, in: &eventContext)
        link.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension BaseInboundStreamFlowLinkage {
    public var deliversInline: Bool {
        if case .standalone = protocolType { return true }
        return false
    }

    public func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneConnectionLink(resolving: identifier, in: &eventContext)
        link.deliverInline(event, from: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension BaseInboundDatagramFlowLinkage {
    public var deliversInline: Bool {
        if case .standalone = protocolType { return true }
        return false
    }

    public func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let link = StandaloneConnectionLink(resolving: identifier, in: &eventContext)
        link.deliverInline(event, from: instance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension BaseInboundStreamFlowLinkage {
    public func deliverInlineNewInboundFlow(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        eventContext.standaloneEvents.appendNewInboundFlow(
            connection: identifier,
            flowInstance: flowInstance,
            metadata: flowMetadata
        )
    }
}

@available(Network 0.1.0, *)
extension BaseInboundStreamFlowLinkage {
    public func makeInlineFlow(
        flowInstance: InstanceIdentifier,
        flowTag: UInt64,
        lower: BaseOutboundStreamLinkage,
        in eventContext: inout NetworkContext.EventContext
    ) -> BaseInboundStreamLinkage? {
        guard deliversInline else { return nil }
        let connection = StandaloneConnectionLink(resolving: identifier, in: &eventContext)
        guard !eventContext.standaloneLinks[connection.slot].closed else { return nil }
        let releases = eventContext.standaloneLinks[connection.slot].releasesFlowsOnDisconnect
        let flow = StandaloneFlowLink.make(
            kind: .stream,
            hasFlowID: true,
            reportsConnectionEvents: false,
            lower: lower,
            metadata: nil,
            releasesFlowsOnDisconnect: releases,
            in: &eventContext
        )
        let flowID = StandaloneFlowID(slot: flow.slot)
        eventContext.standaloneLinks[flow.slot].announcedWithFlow = true
        eventContext.standaloneLinks[flow.slot].newFlowPending = true
        eventContext.standaloneEvents.append(.newInboundFlow(flowID, tag: flowTag))
        return flow.inboundStream
    }
}

@available(Network 0.1.0, *)
extension BaseInboundDatagramFlowLinkage {
    public func deliverInlineNewInboundFlow(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        eventContext.standaloneEvents.appendNewInboundFlow(
            connection: identifier,
            flowInstance: flowInstance,
            metadata: flowMetadata
        )
    }
}

@available(Network 0.1.0, *)
extension StandaloneFlowLink {
    func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch event {
        case .connected:
            handleConnectedEvent(for: instance, in: &eventContext)
        case .disconnected(let error):
            handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .network(let networkEvent):
            handleNetworkProtocolEvent(event: networkEvent, for: instance, in: &eventContext)
        case .inboundDataAvailable:
            handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .outboundRoomAvailable:
            handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .inboundAborted(let error):
            handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
        case .outboundAborted(let error):
            handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
        }
    }
}

@available(Network 0.1.0, *)
extension StandaloneConnectionLink {
    func deliverInline(
        _ event: InlineUpperEvent,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch event {
        case .connected:
            handleConnectedEvent(for: instance, in: &eventContext)
        case .disconnected(let error):
            handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .network(let networkEvent):
            handleNetworkProtocolEvent(event: networkEvent, for: instance, in: &eventContext)
        case .inboundDataAvailable, .outboundRoomAvailable, .inboundAborted, .outboundAborted:
            // A connection link has no data.
            break
        }
    }
}

#endif
