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

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// The links of a standalone protocol: what stands where a neighbour would be.
//
// A protocol reaches what is above and below it through linkages, and a linkage that points at
// nothing silently drops every event. A standalone driver puts a linkage with the `standalone`
// protocol type in each place a neighbour would be, so the protocol's events and data land where
// the driver's owner can collect them.
//
// Such a linkage holds nothing but its identifier. What the link remembers (the linkages it was
// attached to, the frames in flight) lives in `StandaloneLinkState`, in a table on the event
// context, and the identifier's event state says where. No class stands behind it, so copying the
// linkage costs nothing, and the linkage adds no size to the protocols that hold it. Everything
// runs on the event context's single execution context, so none of it needs a lock.
//
// The `StandaloneFlowLink`, `StandaloneLowerLink` and `StandaloneConnectionLink` types below are
// what a `standalone` linkage resolves to when the protocol calls it, and what the drivers use to
// make and operate links.
//
// The one exception is the moment a protocol attaches to a lower link. `attachUpperProtocol`
// carries no event context, and some protocols make it from inside a call that already holds the
// context exclusively, where touching the context again would trap. A link attached that way (the
// `standaloneSuppliedUpper` protocol type) records nothing at attach, and the driver supplies what
// it needs afterwards.

/// What a link carries.
@available(Network 0.1.0, *)
enum StandaloneDataKind {
    case stream
    case datagram
}

/// What a link remembers. Lives in `EventContext.standaloneLinks`, keyed by the link's slot.
@available(Network 0.1.0, *)
struct StandaloneLinkState: ~Copyable {
    let kind: StandaloneDataKind
    /// `nil` for a one-to-one protocol's only flow, and for links that are not flows.
    var flowID: StandaloneFlowID?
    /// `nil` for a one-to-one protocol's only lower, and for links that are not lowers.
    var pathID: StandalonePathID?
    /// Whether a connection-wide event (a network event, or connected and disconnected for a
    /// connection link) is reported through this link. A many-to-many protocol reports those
    /// through its connection link only, so a flow does not repeat them.
    var reportsConnectionEvents: Bool
    /// Set when the protocol tore the link down. A closed link ignores everything.
    var closed = false

    // A flow link: the protocol below it.
    var streamLower = BaseOutboundStreamLinkage()
    var datagramLower = BaseOutboundDatagramLinkage()
    var flowMetadata: AbstractProtocolMetadata?

    // A lower link: the protocol above it, and the frames in flight.
    var streamUpper = BaseInboundStreamLinkage()
    var datagramUpper = BaseInboundDatagramLinkage()
    var pendingInbound = FrameArray()
    var pendingOutbound = FrameArray()
    var maximumOutputSize = 1500

    // A connection link: the listeners new flows attach to, and the flows that came through it.
    var flowIDs: [StandaloneFlowID] = []
    var streamListener = BaseStreamListenerLinkage()
    var datagramListener = BaseDatagramListenerLinkage()

    init(
        kind: StandaloneDataKind,
        flowID: StandaloneFlowID? = nil,
        pathID: StandalonePathID? = nil,
        reportsConnectionEvents: Bool = false
    ) {
        self.kind = kind
        self.flowID = flowID
        self.pathID = pathID
        self.reportsConnectionEvents = reportsConnectionEvents
    }
}

// MARK: - Event context

@available(Network 0.1.0, *)
extension InstanceIdentifier {
    /// Registers an event state that no protocol instance object owns.
    ///
    /// A link has no object to own a `ProtocolEventManager`, so the registration is made and the
    /// manager defused. The caller hands the state back with `retireWithoutOwner(in:)`.
    static func registerWithoutOwner(in eventContext: inout NetworkContext.EventContext) -> InstanceIdentifier {
        var manager = ProtocolEventManager()
        let identifier = InstanceIdentifier(eventManager: &manager, in: &eventContext)
        manager.contextIndex = .none
        return identifier
    }

    func retireWithoutOwner(in eventContext: inout NetworkContext.EventContext) {
        guard !isNone else { return }
        eventContext.retireProtocolEventState(eventStateIndex)
    }
}

@available(Network 0.1.0, *)
extension NetworkContext.EventContext {
    /// Creates the state for a link and the identifier its linkages use.
    mutating func standaloneRegisterLink(
        _ state: consuming StandaloneLinkState
    ) -> (identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        let identifier = InstanceIdentifier.registerWithoutOwner(in: &self)
        let slot = standaloneLinks.insert(state)
        protocolEventStates[identifier.eventStateIndex].standaloneSlot = slot
        return (identifier, slot)
    }

    /// Frees a link's state. The link must not be used afterwards.
    mutating func standaloneUnregisterLink(identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        identifier.retireWithoutOwner(in: &self)
        standaloneLinks[slot].pendingInbound.finalizeAllFramesAsFailed()
        standaloneLinks[slot].pendingOutbound.finalizeAllFramesAsFailed()
        standaloneLinks.remove(index: slot)
    }

    /// Where the state of the standalone link named by `identifier` is.
    mutating func standaloneSlot(of identifier: InstanceIdentifier) -> NetworkStateIndex {
        protocolEventStates[identifier.eventStateIndex].standaloneSlot
    }

    mutating func standaloneMakeFlowID() -> StandaloneFlowID {
        defer { standaloneNextID += 1 }
        return StandaloneFlowID(rawValue: standaloneNextID)
    }

    mutating func standaloneMakePathID() -> StandalonePathID {
        defer { standaloneNextID += 1 }
        return StandalonePathID(rawValue: standaloneNextID)
    }
}

// MARK: - Flow link (the application above one flow)

/// Stands in for the application above one flow.
///
/// For a one-to-one protocol it is the only upper. For a many-to-many protocol there is one per
/// stream or datagram flow.
@available(Network 0.1.0, *)
struct StandaloneFlowLink: Hashable {
    let identifier: InstanceIdentifier
    let slot: NetworkStateIndex

    /// Finds the link a `standalone` linkage names, from inside a call that holds the event context.
    init(resolving identifier: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        self.identifier = identifier
        self.slot = eventContext.standaloneSlot(of: identifier)
    }

    /// Finds the link a `standalone` linkage names, from a call that does not carry the context.
    init(resolving identifier: InstanceIdentifier, context: NetworkContext) {
        self.identifier = identifier
        self.slot = context.eventContext.standaloneSlot(of: identifier)
    }

    init(identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        self.identifier = identifier
        self.slot = slot
    }

    var inboundStream: BaseInboundStreamLinkage {
        BaseInboundStreamLinkage(identifier: identifier, storage: nil, protocolType: .standalone)
    }

    var inboundDatagram: BaseInboundDatagramLinkage {
        BaseInboundDatagramLinkage(identifier: identifier, storage: nil, protocolType: .standalone)
    }

    /// Creates a flow link from inside a call that holds the event context, or from outside one.
    static func make(
        kind: StandaloneDataKind,
        flowID: StandaloneFlowID?,
        reportsConnectionEvents: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) -> StandaloneFlowLink {
        let (identifier, slot) = eventContext.standaloneRegisterLink(
            StandaloneLinkState(kind: kind, flowID: flowID, reportsConnectionEvents: reportsConnectionEvents)
        )
        return StandaloneFlowLink(identifier: identifier, slot: slot)
    }

    // MARK: Attach

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let context = parameters?.context else { throw NetworkError.posix(EINVAL) }
        guard context.eventContext.standaloneLinks[slot].streamLower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        context.eventContext.standaloneLinks[slot].streamLower = lowerProtocol
        try lowerProtocol.invokeAttachUpperProtocol(
            inboundStream,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let context = parameters?.context else { throw NetworkError.posix(EINVAL) }
        guard context.eventContext.standaloneLinks[slot].datagramLower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        context.eventContext.standaloneLinks[slot].datagramLower = lowerProtocol
        try lowerProtocol.invokeAttachUpperProtocol(
            inboundDatagram,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    // MARK: Events from the protocol

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneEvents.append(.connected(eventContext.standaloneLinks[slot].flowID))
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneEvents.append(.disconnected(eventContext.standaloneLinks[slot].flowID, error))
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed,
            eventContext.standaloneLinks[slot].reportsConnectionEvents
        else { return }
        eventContext.standaloneEvents.append(.network(event))
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneEvents.append(.inboundDataAvailable(eventContext.standaloneLinks[slot].flowID))
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneEvents.append(.outboundRoomAvailable(eventContext.standaloneLinks[slot].flowID))
    }

    func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneEvents.append(.inboundAborted(eventContext.standaloneLinks[slot].flowID, error))
    }

    func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneEvents.append(.outboundAborted(eventContext.standaloneLinks[slot].flowID, error))
    }

    // MARK: Calls from the owner

    // Each of these enters the protocol the way an application would, through the flow's own event
    // state, and calls down through the lower linkage the attach recorded.

    func connect(context: NetworkContext) {
        identifier.fromExternal(in: &context.eventContext) { eventContext in
            guard !eventContext.standaloneLinks[slot].closed else { return }
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let lower = eventContext.standaloneLinks[slot].streamLower
                lower.invokeConnect(for: identifier, in: &eventContext)
            case .datagram:
                let lower = eventContext.standaloneLinks[slot].datagramLower
                lower.invokeConnect(for: identifier, in: &eventContext)
            }
        }
    }

    func disconnect(error: NetworkError?, context: NetworkContext) {
        identifier.fromExternal(in: &context.eventContext) { eventContext in
            guard !eventContext.standaloneLinks[slot].closed else { return }
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let lower = eventContext.standaloneLinks[slot].streamLower
                lower.invokeDisconnect(error: error, for: identifier, in: &eventContext)
            case .datagram:
                let lower = eventContext.standaloneLinks[slot].datagramLower
                lower.invokeDisconnect(error: error, for: identifier, in: &eventContext)
            }
        }
    }

    func applicationEvent(_ event: ApplicationEvent, context: NetworkContext) {
        identifier.fromExternal(in: &context.eventContext) { eventContext in
            guard !eventContext.standaloneLinks[slot].closed else { return }
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let lower = eventContext.standaloneLinks[slot].streamLower
                lower.invokeApplicationEvent(event: event, for: identifier, in: &eventContext)
            case .datagram:
                let lower = eventContext.standaloneLinks[slot].datagramLower
                lower.invokeApplicationEvent(event: event, for: identifier, in: &eventContext)
            }
        }
    }

    func sendStream(
        _ frames: consuming FrameArray,
        early: Bool,
        context: NetworkContext
    ) throws(NetworkError) {
        try identifier.fromExternal(frames, in: &context.eventContext) { eventContext, frames throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else {
                var failed = consume frames
                failed.finalizeAllFramesAsFailed()
                throw NetworkError.posix(ENOTCONN)
            }
            let lower = eventContext.standaloneLinks[slot].streamLower
            if early {
                try lower.invokeSendEarlyStreamData(frames, from: identifier, in: &eventContext)
            } else {
                try lower.invokeSendStreamData(frames, from: identifier, in: &eventContext)
            }
        }
    }

    func receiveStream(
        minimumBytes: Int,
        maximumBytes: Int,
        context: NetworkContext
    ) throws(NetworkError) -> FrameArray? {
        try identifier.fromExternal(in: &context.eventContext) { eventContext throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else { throw NetworkError.posix(ENOTCONN) }
            let lower = eventContext.standaloneLinks[slot].streamLower
            return try lower.invokeReceiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: identifier,
                in: &eventContext
            )
        }
    }

    func outboundRoomAvailable(context: NetworkContext) throws(NetworkError) -> Int {
        try identifier.fromExternal(in: &context.eventContext) { eventContext throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else { throw NetworkError.posix(ENOTCONN) }
            let lower = eventContext.standaloneLinks[slot].streamLower
            return try lower.invokeGetOutboundStreamDataRoomAvailable(for: identifier, in: &eventContext)
        }
    }

    func abortInbound(error: NetworkError?, context: NetworkContext) throws(NetworkError) {
        try identifier.fromExternal(in: &context.eventContext) { eventContext throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else { throw NetworkError.posix(ENOTCONN) }
            let lower = eventContext.standaloneLinks[slot].streamLower
            try lower.invokeAbortInbound(error: error, for: identifier, in: &eventContext)
        }
    }

    func abortOutbound(error: NetworkError?, context: NetworkContext) throws(NetworkError) {
        try identifier.fromExternal(in: &context.eventContext) { eventContext throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else { throw NetworkError.posix(ENOTCONN) }
            let lower = eventContext.standaloneLinks[slot].streamLower
            try lower.invokeAbortOutbound(error: error, for: identifier, in: &eventContext)
        }
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        context: NetworkContext
    ) throws(NetworkError) -> FrameArray? {
        try identifier.fromExternal(in: &context.eventContext) { eventContext throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else { throw NetworkError.posix(ENOTCONN) }
            let lower = eventContext.standaloneLinks[slot].datagramLower
            return try lower.invokeGetDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: identifier,
                in: &eventContext
            )
        }
    }

    func sendDatagrams(_ frames: consuming FrameArray, context: NetworkContext) throws(NetworkError) {
        try identifier.fromExternal(frames, in: &context.eventContext) { eventContext, frames throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else {
                var failed = consume frames
                failed.finalizeAllFramesAsFailed()
                throw NetworkError.posix(ENOTCONN)
            }
            let lower = eventContext.standaloneLinks[slot].datagramLower
            try lower.invokeSendDatagrams(frames, from: identifier, in: &eventContext)
        }
    }

    func receiveDatagrams(maximumDatagramCount: Int, context: NetworkContext) throws(NetworkError) -> FrameArray? {
        try identifier.fromExternal(in: &context.eventContext) { eventContext throws(NetworkError) in
            guard !eventContext.standaloneLinks[slot].closed else { throw NetworkError.posix(ENOTCONN) }
            let lower = eventContext.standaloneLinks[slot].datagramLower
            return try lower.invokeReceiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: identifier,
                in: &eventContext
            )
        }
    }

    func getMetadata<P: NetworkProtocol>(context: NetworkContext) -> ProtocolMetadata<P>? {
        identifier.fromExternal(in: &context.eventContext) { eventContext -> ProtocolMetadata<P>? in
            guard !eventContext.standaloneLinks[slot].closed else { return nil }
            if let metadata = eventContext.standaloneLinks[slot].flowMetadata as? ProtocolMetadata<P> {
                return metadata
            }
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let lower = eventContext.standaloneLinks[slot].streamLower
                return lower.invokeGetMetadata(for: identifier, in: &eventContext)
            case .datagram:
                let lower = eventContext.standaloneLinks[slot].datagramLower
                return lower.invokeGetMetadata(for: identifier, in: &eventContext)
            }
        }
    }

    func getMetrics(_ requested: RequestedNetworkMetrics, context: NetworkContext) -> NetworkMetrics? {
        identifier.fromExternal(in: &context.eventContext) { eventContext -> NetworkMetrics? in
            guard !eventContext.standaloneLinks[slot].closed else { return nil }
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let lower = eventContext.standaloneLinks[slot].streamLower
                return lower.invokeGetMetrics(requestedNetworkMetric: requested, for: identifier, in: &eventContext)
            case .datagram:
                let lower = eventContext.standaloneLinks[slot].datagramLower
                return lower.invokeGetMetrics(requestedNetworkMetric: requested, for: identifier, in: &eventContext)
            }
        }
    }

    /// Detaches from the protocol below and frees the link. Safe to call twice.
    func teardown(in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneLinks[slot].closed = true
        do throws(NetworkError) {
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let lower = eventContext.standaloneLinks[slot].streamLower
                eventContext.standaloneLinks[slot].streamLower = .init()
                try lower.invokeDetach(for: identifier, in: &eventContext)
            case .datagram:
                let lower = eventContext.standaloneLinks[slot].datagramLower
                eventContext.standaloneLinks[slot].datagramLower = .init()
                try lower.invokeDetach(for: identifier, in: &eventContext)
            }
        } catch {
            // The protocol is going away either way.
        }
        identifier.retireWithoutOwner(in: &eventContext)
    }

    /// Frees the link's state once nothing will use it again.
    func free(in eventContext: inout NetworkContext.EventContext) {
        eventContext.standaloneLinks[slot].pendingInbound.finalizeAllFramesAsFailed()
        eventContext.standaloneLinks.remove(index: slot)
    }
}

// MARK: - Lower link (the network below)

/// Stands in for the network below a protocol.
///
/// What the protocol sends is held until the owner collects it, and what the owner injects is held
/// until the protocol reads it.
@available(Network 0.1.0, *)
struct StandaloneLowerLink: Hashable {
    let identifier: InstanceIdentifier
    let slot: NetworkStateIndex

    static func make(
        kind: StandaloneDataKind,
        pathID: StandalonePathID?,
        in eventContext: inout NetworkContext.EventContext
    ) -> StandaloneLowerLink {
        let (identifier, slot) = eventContext.standaloneRegisterLink(StandaloneLinkState(kind: kind, pathID: pathID))
        return StandaloneLowerLink(identifier: identifier, slot: slot)
    }

    init(identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        self.identifier = identifier
        self.slot = slot
    }

    /// Finds the link a `standalone` linkage names, from inside a call that holds the event context.
    init(resolving identifier: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        self.identifier = identifier
        self.slot = eventContext.standaloneSlot(of: identifier)
    }

    /// Finds the link a `standalone` linkage names, from a call that does not carry the context.
    init(resolving identifier: InstanceIdentifier, context: NetworkContext) {
        self.identifier = identifier
        self.slot = context.eventContext.standaloneSlot(of: identifier)
    }

    var outboundStream: BaseOutboundStreamLinkage {
        BaseOutboundStreamLinkage(identifier: identifier, storage: nil, protocolType: .standalone)
    }

    var outboundDatagram: BaseOutboundDatagramLinkage {
        BaseOutboundDatagramLinkage(identifier: identifier, storage: nil, protocolType: .standalone)
    }

    /// A linkage for a protocol that attaches from inside a call that holds the event context. See
    /// the note at the top of this file.
    var outboundDatagramSuppliedUpper: BaseOutboundDatagramLinkage {
        BaseOutboundDatagramLinkage(identifier: identifier, storage: nil, protocolType: .standaloneSuppliedUpper)
    }

    // MARK: Attach

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let context = parameters?.context else { throw NetworkError.posix(EINVAL) }
        guard context.eventContext.standaloneLinks[slot].datagramUpper.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        context.eventContext.standaloneLinks[slot].datagramUpper = upperProtocol
    }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let context = parameters?.context else { throw NetworkError.posix(EINVAL) }
        guard context.eventContext.standaloneLinks[slot].streamUpper.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        context.eventContext.standaloneLinks[slot].streamUpper = upperProtocol
    }

    /// Records the protocol above, for a link whose protocol attached without the chance to.
    func supplyUpper(_ upper: BaseInboundDatagramLinkage, context: NetworkContext) {
        context.eventContext.standaloneLinks[slot].datagramUpper = upper
    }

    // MARK: Calls from the protocol

    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        guard !eventContext.standaloneLinks[slot].closed else { return false }
        return identifier.isConnected(in: &eventContext)
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed,
            identifier.canCallConnect(requested: true, in: &eventContext)
        else { return }
        switch eventContext.standaloneLinks[slot].kind {
        case .stream:
            let upper = eventContext.standaloneLinks[slot].streamUpper
            upper.deliverConnectedEvent(from: identifier, in: &eventContext)
        case .datagram:
            let upper = eventContext.standaloneLinks[slot].datagramUpper
            upper.deliverConnectedEvent(from: identifier, in: &eventContext)
        }
        // Data injected before the lower was connected could not be announced.
        if !eventContext.standaloneLinks[slot].pendingInbound.isEmpty {
            deliverInboundDataAvailable(in: &eventContext)
        }
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed,
            identifier.canCallDisconnect(in: &eventContext)
        else { return }
        switch eventContext.standaloneLinks[slot].kind {
        case .stream:
            let upper = eventContext.standaloneLinks[slot].streamUpper
            upper.deliverDisconnectedEvent(error: nil, from: identifier, in: &eventContext)
        case .datagram:
            let upper = eventContext.standaloneLinks[slot].datagramUpper
            upper.deliverDisconnectedEvent(error: nil, from: identifier, in: &eventContext)
        }
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        eventContext.standaloneLinks[slot].datagramUpper = .init()
        eventContext.standaloneLinks[slot].streamUpper = .init()
        eventContext.standaloneLinks[slot].pendingInbound.finalizeAllFramesAsFailed()
        eventContext.standaloneLinks[slot].pendingOutbound.finalizeAllFramesAsFailed()
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneLinks[slot].closed = true
        eventContext.standaloneLinks[slot].pendingInbound.finalizeAllFramesAsFailed()
        eventContext.standaloneLinks[slot].pendingOutbound.finalizeAllFramesAsFailed()
        identifier.retireWithoutOwner(in: &eventContext)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? { nil }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? { nil }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        eventContext.standaloneLinks[slot].pendingInbound.drainArray(maximumFrameCount: maximumDatagramCount)
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        let frameSize = min(minimumDatagramSize, eventContext.standaloneLinks[slot].maximumOutputSize)
        var frames = FrameArray(capacity: maximumDatagramCount)
        for _ in 0..<maximumDatagramCount {
            frames.add(frame: Frame(count: frameSize))
        }
        return frames
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        eventContext.standaloneLinks[slot].pendingOutbound.add(frames: datagrams)
        eventContext.standaloneEvents.append(.outboundDataReady(eventContext.standaloneLinks[slot].pathID))
    }

    func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        eventContext.standaloneLinks[slot].pendingInbound.drainArray(maximumByteCount: maximumBytes)
    }

    func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        Int.max
    }

    func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        eventContext.standaloneLinks[slot].pendingOutbound.add(frames: streamData)
        eventContext.standaloneEvents.append(.outboundDataReady(eventContext.standaloneLinks[slot].pathID))
    }

    func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        streamData.finalizeAllFramesAsFailed()
        throw NetworkError.posix(ENOTSUP)
    }

    func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    // MARK: Calls from the owner

    func deliverInboundDataAvailable(in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed,
            identifier.isConnected(in: &eventContext)
        else { return }
        switch eventContext.standaloneLinks[slot].kind {
        case .stream:
            let upper = eventContext.standaloneLinks[slot].streamUpper
            upper.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
        case .datagram:
            let upper = eventContext.standaloneLinks[slot].datagramUpper
            upper.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
        }
    }

    /// Queues data from the network and tells the protocol it is there.
    func receive(_ frames: consuming FrameArray, context: NetworkContext) {
        identifier.fromExternal(frames, in: &context.eventContext) { eventContext, frames in
            guard !eventContext.standaloneLinks[slot].closed else {
                var failed = consume frames
                failed.finalizeAllFramesAsFailed()
                return
            }
            eventContext.standaloneLinks[slot].pendingInbound.add(frames: frames)
            deliverInboundDataAvailable(in: &eventContext)
        }
    }

    /// Hands the owner everything the protocol queued to send below.
    func takeOutbound(context: NetworkContext) -> FrameArray {
        guard !context.eventContext.standaloneLinks[slot].closed else { return FrameArray() }
        return context.eventContext.standaloneLinks[slot].pendingOutbound.drainArrayKeepingCapacity()
    }

    /// Tells the protocol about something that happened to the network, such as viability.
    func deliverNetworkProtocolEvent(_ event: NetworkProtocolEvent, context: NetworkContext) {
        identifier.fromExternal(in: &context.eventContext) { eventContext in
            guard !eventContext.standaloneLinks[slot].closed else { return }
            switch eventContext.standaloneLinks[slot].kind {
            case .stream:
                let upper = eventContext.standaloneLinks[slot].streamUpper
                upper.deliverNetworkProtocolEvent(
                    originalInstance: identifier,
                    selfInstance: identifier,
                    event: event,
                    in: &eventContext
                )
            case .datagram:
                let upper = eventContext.standaloneLinks[slot].datagramUpper
                upper.deliverNetworkProtocolEvent(
                    originalInstance: identifier,
                    selfInstance: identifier,
                    event: event,
                    in: &eventContext
                )
            }
        }
    }

    /// Frees the link's state once the protocol has torn it down, or at close.
    func free(in eventContext: inout NetworkContext.EventContext) {
        if !eventContext.standaloneLinks[slot].closed {
            eventContext.standaloneLinks[slot].closed = true
            identifier.retireWithoutOwner(in: &eventContext)
        }
        eventContext.standaloneLinks[slot].pendingInbound.finalizeAllFramesAsFailed()
        eventContext.standaloneLinks[slot].pendingOutbound.finalizeAllFramesAsFailed()
        eventContext.standaloneLinks.remove(index: slot)
    }
}

// MARK: - Connection link (the application above a many-to-many protocol's listener)

/// Stands in for the application above a many-to-many protocol's listener.
///
/// It reports connection-wide events (connected, disconnected, QUIC connection ID and path events)
/// and is told when the peer opens a flow. Opening a flow from this side does not involve it.
@available(Network 0.1.0, *)
struct StandaloneConnectionLink: Hashable {
    let identifier: InstanceIdentifier
    let slot: NetworkStateIndex

    init(identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        self.identifier = identifier
        self.slot = slot
    }

    /// Finds the link a `standalone` linkage names, from inside a call that holds the event context.
    init(resolving identifier: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        self.identifier = identifier
        self.slot = eventContext.standaloneSlot(of: identifier)
    }

    /// Finds the link a `standalone` linkage names, from a call that does not carry the context.
    init(resolving identifier: InstanceIdentifier, context: NetworkContext) {
        self.identifier = identifier
        self.slot = context.eventContext.standaloneSlot(of: identifier)
    }

    var inboundStreamFlow: BaseInboundStreamFlowLinkage {
        BaseInboundStreamFlowLinkage(identifier: identifier, storage: nil, protocolType: .standalone)
    }

    var inboundDatagramFlow: BaseInboundDatagramFlowLinkage {
        BaseInboundDatagramFlowLinkage(identifier: identifier, storage: nil, protocolType: .standalone)
    }

    /// - Parameter reportsConnectionEvents: Only one of a connection's listener links reports
    ///   connection-wide events, or each would be reported twice.
    static func make(
        kind: StandaloneDataKind,
        reportsConnectionEvents: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) -> StandaloneConnectionLink {
        let (identifier, slot) = eventContext.standaloneRegisterLink(
            StandaloneLinkState(kind: kind, reportsConnectionEvents: reportsConnectionEvents)
        )
        return StandaloneConnectionLink(identifier: identifier, slot: slot)
    }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let context = parameters?.context else { throw NetworkError.posix(EINVAL) }
        guard context.eventContext.standaloneLinks[slot].streamListener.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        context.eventContext.standaloneLinks[slot].streamListener = lowerProtocol
        try lowerProtocol.invokeAttachUpperProtocol(
            inboundStreamFlow,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseDatagramListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let context = parameters?.context else { throw NetworkError.posix(EINVAL) }
        guard context.eventContext.standaloneLinks[slot].datagramListener.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        context.eventContext.standaloneLinks[slot].datagramListener = lowerProtocol
        try lowerProtocol.invokeAttachUpperProtocol(
            inboundDatagramFlow,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed,
            eventContext.standaloneLinks[slot].reportsConnectionEvents
        else { return }
        eventContext.standaloneEvents.append(.connected(nil))
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed,
            eventContext.standaloneLinks[slot].reportsConnectionEvents
        else { return }
        eventContext.standaloneEvents.append(.disconnected(nil, error))
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed,
            eventContext.standaloneLinks[slot].reportsConnectionEvents
        else { return }
        eventContext.standaloneEvents.append(.network(event))
    }

    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        let kind = eventContext.standaloneLinks[slot].kind
        let flowID = eventContext.standaloneMakeFlowID()
        let flow = StandaloneFlowLink.make(
            kind: kind,
            flowID: flowID,
            reportsConnectionEvents: false,
            in: &eventContext
        )
        do throws(NetworkError) {
            switch kind {
            case .stream:
                let listener = eventContext.standaloneLinks[slot].streamListener
                let lower = try listener.invokeAttachUpperProtocolToExistingFlow(
                    flow.inboundStream,
                    existingFlowInstance: flowInstance
                )
                eventContext.standaloneLinks[flow.slot].streamLower = lower
            case .datagram:
                let listener = eventContext.standaloneLinks[slot].datagramListener
                let lower = try listener.invokeAttachUpperProtocolToExistingFlow(
                    flow.inboundDatagram,
                    existingFlowInstance: flowInstance
                )
                eventContext.standaloneLinks[flow.slot].datagramLower = lower
            }
        } catch {
            flow.teardown(in: &eventContext)
            flow.free(in: &eventContext)
            return
        }
        eventContext.standaloneLinks[flow.slot].flowMetadata = flowMetadata
        eventContext.standaloneFlows[flowID] = flow
        eventContext.standaloneLinks[slot].flowIDs.append(flowID)
        eventContext.standaloneEvents.append(.newInboundFlow(flowID, flowMetadata))
        // Connecting hands over anything the flow buffered before it had an upper.
        switch kind {
        case .stream:
            let lower = eventContext.standaloneLinks[flow.slot].streamLower
            lower.invokeConnect(for: flow.identifier, in: &eventContext)
        case .datagram:
            let lower = eventContext.standaloneLinks[flow.slot].datagramLower
            lower.invokeConnect(for: flow.identifier, in: &eventContext)
        }
    }

    /// Detaches from the listeners and frees the link.
    func teardown(in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneLinks[slot].closed = true
        let streamListener = eventContext.standaloneLinks[slot].streamListener
        let datagramListener = eventContext.standaloneLinks[slot].datagramListener
        eventContext.standaloneLinks[slot].streamListener = .init()
        eventContext.standaloneLinks[slot].datagramListener = .init()
        do throws(NetworkError) {
            if !streamListener.isDetached {
                try streamListener.invokeDetach(for: identifier, in: &eventContext)
            }
            if !datagramListener.isDetached {
                try datagramListener.invokeDetach(for: identifier, in: &eventContext)
            }
        } catch {
            // The connection is going away either way.
        }
        identifier.retireWithoutOwner(in: &eventContext)
    }

    func free(in eventContext: inout NetworkContext.EventContext) {
        eventContext.standaloneLinks.remove(index: slot)
    }
}

#endif
