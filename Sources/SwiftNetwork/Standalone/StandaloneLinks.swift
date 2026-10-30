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

/// What the lower and connection links remember beyond what every link does.
///
/// Flow links are made and freed for every stream, and the rest of a link's state is only used by
/// the few lower and connection links of a connection, so it lives behind a reference: a flow's
/// link state is a fraction of the size, and creating or freeing one moves less.
@available(Network 0.1.0, *)
final class StandaloneLinkExtra {
    // A lower link: the protocol above it, and the frames in flight.
    var streamUpper = BaseInboundStreamLinkage()
    var datagramUpper = BaseInboundDatagramLinkage()
    var pendingInbound = FrameArray()
    var pendingOutbound = FrameArray()

    // A connection link: the listeners new flows attach to.
    var streamListener = BaseStreamListenerLinkage()
    var datagramListener = BaseDatagramListenerLinkage()

    // A flow link: what the protocol said about the flow.
    var flowMetadata: AbstractProtocolMetadata?
}

/// What a link remembers. Lives in `EventContext.standaloneLinks`, keyed by the link's slot.
@available(Network 0.1.0, *)
struct StandaloneLinkState: ~Copyable {
    /// The one protocol below a flow link: a flow carries a stream or datagrams, not both.
    private enum Lower {
        case stream(BaseOutboundStreamLinkage)
        case datagram(BaseOutboundDatagramLinkage)
    }

    /// The link's yes-or-no facts, in one byte.
    struct Flags: OptionSet {
        var rawValue: UInt8

        /// Set when the protocol tore the link down. A closed link ignores everything.
        static let closed = Flags(rawValue: 1 << 0)
        /// Whether a connection-wide event (a network event, or connected and disconnected for a
        /// connection link) is reported through this link. A many-to-many protocol reports those
        /// through its connection link only, so a flow does not repeat them.
        static let reportsConnectionEvents = Flags(rawValue: 1 << 1)
        /// A connection link: whether the flows made through it are released when their disconnect is
        /// reported (see `StandaloneQUICConnection.init(releasesFlowsOnDisconnect:)`). A flow link:
        /// whether this flow is.
        static let releasesFlowsOnDisconnect = Flags(rawValue: 1 << 2)
        /// A flow link for a flow the peer opened through an inline linkage: the new-flow event
        /// announces the flow as connected, so no connected event of its own is queued.
        static let announcedWithFlow = Flags(rawValue: 1 << 3)
        /// A flow link whose new-flow event the owner has not taken yet: that event stands for the
        /// data the flow already holds, so data-available events wait out until it is taken.
        static let newFlowPending = Flags(rawValue: 1 << 4)
        /// The link is a flow of a many-to-many protocol, named by an ID made from its slot. A
        /// one-to-one protocol's only flow, and links that are not flows, have none.
        static let hasFlowID = Flags(rawValue: 1 << 5)
    }

    // The fields come in the order they are read: the flags and the identity first, which is all
    // an event needs, and the protocol below last.
    private var flags: Flags
    let kind: StandaloneDataKind
    /// The event state the link was registered with, and the slot it is at, so the link can be found
    /// from its flow ID.
    private var eventStateIndex = NetworkStateIndex.none
    private(set) var selfIndex = NetworkStateIndex.none
    /// `0` for a one-to-one protocol's only lower, and for links that are not lowers. Path IDs count
    /// up from one.
    private var pathRaw: Int
    // Lower and connection links, and the metadata of a flow that has some. See `StandaloneLinkExtra`.
    private var extra: StandaloneLinkExtra?
    /// A flow link: the protocol below it.
    private var lower: Lower

    @inline(always) var closed: Bool {
        get { flags.contains(.closed) }
        set { flags.set(.closed, to: newValue) }
    }

    @inline(always) var reportsConnectionEvents: Bool {
        get { flags.contains(.reportsConnectionEvents) }
        set { flags.set(.reportsConnectionEvents, to: newValue) }
    }

    @inline(always) var releasesFlowsOnDisconnect: Bool {
        get { flags.contains(.releasesFlowsOnDisconnect) }
        set { flags.set(.releasesFlowsOnDisconnect, to: newValue) }
    }

    @inline(always) var announcedWithFlow: Bool {
        get { flags.contains(.announcedWithFlow) }
        set { flags.set(.announcedWithFlow, to: newValue) }
    }

    @inline(always) var newFlowPending: Bool {
        get { flags.contains(.newFlowPending) }
        set { flags.set(.newFlowPending, to: newValue) }
    }

    /// The identifier the link's linkages use.
    var identifier: InstanceIdentifier {
        InstanceIdentifier(eventStateIndex: eventStateIndex)
    }

    /// `nil` for a one-to-one protocol's only flow, and for links that are not flows.
    var flowID: StandaloneFlowID? {
        flags.contains(.hasFlowID) ? StandaloneFlowID(slot: selfIndex) : nil
    }

    /// `nil` for a one-to-one protocol's only lower, and for links that are not lowers.
    var pathID: StandalonePathID? {
        pathRaw == 0 ? nil : StandalonePathID(rawValue: pathRaw)
    }

    /// Records where the link is registered.
    mutating func registered(identifier: InstanceIdentifier, slot: NetworkStateIndex, isFlow: Bool) {
        eventStateIndex = identifier.eventStateIndex
        selfIndex = slot
        if isFlow { flags.insert(.hasFlowID) }
    }

    /// A flow link: what the protocol said about the flow, if it said anything.
    var flowMetadata: AbstractProtocolMetadata? {
        get { extra?.flowMetadata }
        set {
            if newValue == nil && extra == nil { return }
            ensureExtra().flowMetadata = newValue
        }
    }

    var streamLower: BaseOutboundStreamLinkage {
        get {
            if case .stream(let lower) = self.lower { return lower }
            return BaseOutboundStreamLinkage()
        }
        set { self.lower = .stream(newValue) }
    }

    var datagramLower: BaseOutboundDatagramLinkage {
        get {
            if case .datagram(let lower) = self.lower { return lower }
            return BaseOutboundDatagramLinkage()
        }
        set { self.lower = .datagram(newValue) }
    }

    /// What the link announces for its flow.
    var flowAnnouncement: (flowID: StandaloneFlowID?, metadata: AbstractProtocolMetadata?) {
        (self.flowID, self.flowMetadata)
    }

    /// The protocol below a stream flow, or `nil` if the link is closed or carries datagrams.
    mutating func openStreamLower() -> BaseOutboundStreamLinkage? {
        if !self.closed, case .stream(let lower) = self.lower { return lower }
        return nil
    }

    /// The protocol below a datagram flow, or `nil` if the link is closed or carries a stream.
    mutating func openDatagramLower() -> BaseOutboundDatagramLinkage? {
        if !self.closed, case .datagram(let lower) = self.lower { return lower }
        return nil
    }

    private mutating func ensureExtra() -> StandaloneLinkExtra {
        if let extra = self.extra { return extra }
        let extra = StandaloneLinkExtra()
        self.extra = extra
        return extra
    }

    var streamUpper: BaseInboundStreamLinkage {
        get { self.extra?.streamUpper ?? BaseInboundStreamLinkage() }
        set { self.ensureExtra().streamUpper = newValue }
    }

    var datagramUpper: BaseInboundDatagramLinkage {
        get { self.extra?.datagramUpper ?? BaseInboundDatagramLinkage() }
        set { self.ensureExtra().datagramUpper = newValue }
    }

    var streamListener: BaseStreamListenerLinkage {
        get { self.extra?.streamListener ?? BaseStreamListenerLinkage() }
        set { self.ensureExtra().streamListener = newValue }
    }

    var datagramListener: BaseDatagramListenerLinkage {
        get { self.extra?.datagramListener ?? BaseDatagramListenerLinkage() }
        set { self.ensureExtra().datagramListener = newValue }
    }

    /// Finalizes the frames the link holds, without making the storage for them when there are none:
    /// most flows never hold any.
    mutating func finalizePendingFrames() {
        guard let extra = self.extra else { return }
        extra.pendingInbound.finalizeAllFramesAsFailed()
        extra.pendingOutbound.finalizeAllFramesAsFailed()
    }

    var pendingInbound: FrameArray {
        _read {
            if let extra = self.extra {
                yield extra.pendingInbound
            } else {
                yield FrameArray()
            }
        }
        _modify { yield &self.ensureExtra().pendingInbound }
    }

    var pendingOutbound: FrameArray {
        _read {
            if let extra = self.extra {
                yield extra.pendingOutbound
            } else {
                yield FrameArray()
            }
        }
        _modify { yield &self.ensureExtra().pendingOutbound }
    }

    init(
        kind: StandaloneDataKind,
        pathID: StandalonePathID? = nil,
        reportsConnectionEvents: Bool = false
    ) {
        self.kind = kind
        self.pathRaw = pathID?.rawValue ?? 0
        self.flags = reportsConnectionEvents ? [.reportsConnectionEvents] : []
        switch kind {
        case .stream: self.lower = .stream(BaseOutboundStreamLinkage())
        case .datagram: self.lower = .datagram(BaseOutboundDatagramLinkage())
        }
    }
}

extension OptionSet {
    /// Inserts or removes `member`.
    @inline(always)
    mutating func set(_ member: Element, to isOn: Bool) {
        if isOn { insert(member) } else { remove(member) }
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
        _ state: consuming StandaloneLinkState,
        assignsFlowID: Bool = false
    ) -> (identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        let identifier = InstanceIdentifier.registerWithoutOwner(in: &self)
        let slot = standaloneLinks.insert(state)
        protocolEventStates[identifier.eventStateIndex].standaloneSlot = slot
        // A flow's ID is made from its slot, so finding the flow from its ID is one lookup.
        standaloneLinks[slot].registered(identifier: identifier, slot: slot, isFlow: assignsFlowID)
        return (identifier, slot)
    }

    /// The link of the flow named by `id`, or `nil` if there is none (the flow was released).
    mutating func standaloneFlowLink(_ id: StandaloneFlowID) -> StandaloneFlowLink? {
        let position = id.slotIndex
        guard standaloneLinks.isPresent(slot: position) else { return nil }
        let index = NetworkStateIndex.atSlot(position)
        guard standaloneLinks[index].flowID == id else { return nil }
        return StandaloneFlowLink(identifier: standaloneLinks[index].identifier, slot: standaloneLinks[index].selfIndex)
    }

    /// Every flow link, in slot order.
    mutating func standaloneAllFlowLinks() -> [StandaloneFlowLink] {
        var links: [StandaloneFlowLink] = []
        standaloneLinks.forEachElement { state in
            if state.flowID != nil {
                links.append(StandaloneFlowLink(identifier: state.identifier, slot: state.selfIndex))
            }
        }
        return links
    }

    /// Frees a link's state. The link must not be used afterwards.
    mutating func standaloneUnregisterLink(identifier: InstanceIdentifier, slot: NetworkStateIndex) {
        identifier.retireWithoutOwner(in: &self)
        standaloneLinks[slot].finalizePendingFrames()
        standaloneLinks.remove(index: slot)
    }

    /// Where the state of the standalone link named by `identifier` is.
    mutating func standaloneSlot(of identifier: InstanceIdentifier) -> NetworkStateIndex {
        protocolEventStates[identifier.eventStateIndex].standaloneSlot
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
    /// Makes a stream flow link whose lower and metadata are known, with one registration.
    static func make(
        kind: StandaloneDataKind,
        hasFlowID: Bool,
        reportsConnectionEvents: Bool,
        lower: BaseOutboundStreamLinkage,
        metadata: AbstractProtocolMetadata?,
        releasesFlowsOnDisconnect: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) -> StandaloneFlowLink {
        var state = StandaloneLinkState(kind: kind, reportsConnectionEvents: reportsConnectionEvents)
        state.streamLower = lower
        state.flowMetadata = metadata
        state.releasesFlowsOnDisconnect = releasesFlowsOnDisconnect
        let (identifier, slot) = eventContext.standaloneRegisterLink(state, assignsFlowID: hasFlowID)
        return StandaloneFlowLink(identifier: identifier, slot: slot)
    }

    static func make(
        kind: StandaloneDataKind,
        hasFlowID: Bool,
        reportsConnectionEvents: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) -> StandaloneFlowLink {
        let (identifier, slot) = eventContext.standaloneRegisterLink(
            StandaloneLinkState(kind: kind, reportsConnectionEvents: reportsConnectionEvents),
            assignsFlowID: hasFlowID
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
        guard !eventContext.standaloneLinks[slot].closed, !eventContext.standaloneLinks[slot].announcedWithFlow else {
            return
        }
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
        guard !eventContext.standaloneLinks[slot].closed, !eventContext.standaloneLinks[slot].newFlowPending else {
            return
        }
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

    // The owner is outside the protocol, so a call needs no event state of the flow's own: the
    // protocol's events for the flow go to the link inline (see `StandaloneInline.swift`), and the
    // state the protocol keeps for its side of the flow is entered by the lower linkage. Each call
    // reads the link once, for whether it is open and the protocol below, and calls that.

    func connect(context: NetworkContext) {
        if let lower = context.eventContext.standaloneLinks[slot].openStreamLower() {
            lower.invokeConnect(for: identifier, in: &context.eventContext)
        } else if let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() {
            lower.invokeConnect(for: identifier, in: &context.eventContext)
        }
    }

    func disconnect(error: NetworkError?, context: NetworkContext) {
        if let lower = context.eventContext.standaloneLinks[slot].openStreamLower() {
            lower.invokeDisconnect(error: error, for: identifier, in: &context.eventContext)
        } else if let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() {
            lower.invokeDisconnect(error: error, for: identifier, in: &context.eventContext)
        }
    }

    func applicationEvent(_ event: ApplicationEvent, context: NetworkContext) {
        if let lower = context.eventContext.standaloneLinks[slot].openStreamLower() {
            lower.invokeApplicationEvent(event: event, for: identifier, in: &context.eventContext)
        } else if let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() {
            lower.invokeApplicationEvent(event: event, for: identifier, in: &context.eventContext)
        }
    }

    func sendStream(
        _ frames: consuming FrameArray,
        early: Bool,
        context: NetworkContext
    ) throws(NetworkError) {
        guard let lower = context.eventContext.standaloneLinks[slot].openStreamLower() else {
            var failed = consume frames
            failed.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        if early {
            try lower.invokeSendEarlyStreamData(frames, from: identifier, in: &context.eventContext)
        } else {
            try lower.invokeSendStreamData(frames, from: identifier, in: &context.eventContext)
        }
    }

    func receiveStream(
        minimumBytes: Int,
        maximumBytes: Int,
        context: NetworkContext
    ) throws(NetworkError) -> FrameArray? {
        guard let lower = context.eventContext.standaloneLinks[slot].openStreamLower() else {
            throw NetworkError.posix(ENOTCONN)
        }
        return try lower.invokeReceiveStreamData(
            minimumBytes: minimumBytes,
            maximumBytes: maximumBytes,
            for: identifier,
            in: &context.eventContext
        )
    }

    func outboundRoomAvailable(context: NetworkContext) throws(NetworkError) -> Int {
        guard let lower = context.eventContext.standaloneLinks[slot].openStreamLower() else {
            throw NetworkError.posix(ENOTCONN)
        }
        return try lower.invokeGetOutboundStreamDataRoomAvailable(for: identifier, in: &context.eventContext)
    }

    func abortInbound(error: NetworkError?, context: NetworkContext) throws(NetworkError) {
        guard let lower = context.eventContext.standaloneLinks[slot].openStreamLower() else {
            throw NetworkError.posix(ENOTCONN)
        }
        try lower.invokeAbortInbound(error: error, for: identifier, in: &context.eventContext)
    }

    func abortOutbound(error: NetworkError?, context: NetworkContext) throws(NetworkError) {
        guard let lower = context.eventContext.standaloneLinks[slot].openStreamLower() else {
            throw NetworkError.posix(ENOTCONN)
        }
        try lower.invokeAbortOutbound(error: error, for: identifier, in: &context.eventContext)
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        context: NetworkContext
    ) throws(NetworkError) -> FrameArray? {
        guard let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() else {
            throw NetworkError.posix(ENOTCONN)
        }
        return try lower.invokeGetDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: identifier,
            in: &context.eventContext
        )
    }

    func sendDatagrams(_ frames: consuming FrameArray, context: NetworkContext) throws(NetworkError) {
        guard let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() else {
            var failed = consume frames
            failed.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try lower.invokeSendDatagrams(frames, from: identifier, in: &context.eventContext)
    }

    func receiveDatagrams(maximumDatagramCount: Int, context: NetworkContext) throws(NetworkError) -> FrameArray? {
        guard let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() else {
            throw NetworkError.posix(ENOTCONN)
        }
        return try lower.invokeReceiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: identifier,
            in: &context.eventContext
        )
    }

    func getMetadata<P: NetworkProtocol>(context: NetworkContext) -> ProtocolMetadata<P>? {
        guard !context.eventContext.standaloneLinks[slot].closed else { return nil }
        if let metadata = context.eventContext.standaloneLinks[slot].flowMetadata as? ProtocolMetadata<P> {
            return metadata
        }
        if let lower = context.eventContext.standaloneLinks[slot].openStreamLower() {
            return lower.invokeGetMetadata(for: identifier, in: &context.eventContext)
        } else if let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() {
            return lower.invokeGetMetadata(for: identifier, in: &context.eventContext)
        }
        return nil
    }

    func getMetrics(_ requested: RequestedNetworkMetrics, context: NetworkContext) -> NetworkMetrics? {
        if let lower = context.eventContext.standaloneLinks[slot].openStreamLower() {
            return lower.invokeGetMetrics(requestedNetworkMetric: requested, for: identifier, in: &context.eventContext)
        } else if let lower = context.eventContext.standaloneLinks[slot].openDatagramLower() {
            return lower.invokeGetMetrics(requestedNetworkMetric: requested, for: identifier, in: &context.eventContext)
        }
        return nil
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
        eventContext.standaloneLinks[slot].finalizePendingFrames()
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
        eventContext.standaloneLinks[slot].finalizePendingFrames()
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        guard !eventContext.standaloneLinks[slot].closed else { return }
        eventContext.standaloneLinks[slot].closed = true
        eventContext.standaloneLinks[slot].finalizePendingFrames()
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
        let frameSize = min(minimumDatagramSize, eventContext.standaloneMaximumOutputSize)
        var frames = FrameArray(capacity: maximumDatagramCount)
        if let provider = eventContext.standaloneOutputFrame {
            for _ in 0..<maximumDatagramCount {
                frames.add(frame: provider(frameSize))
            }
        } else {
            for _ in 0..<maximumDatagramCount {
                frames.add(frame: Frame(count: frameSize))
            }
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
        eventContext.standaloneLinks[slot].finalizePendingFrames()
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
        if let event = completeNewInboundFlow(flowInstance: flowInstance, flowMetadata: flowMetadata, in: &eventContext)
        {
            eventContext.standaloneEvents.append(event)
        }
    }

    /// Attaches to the flow the protocol made, connects it, and returns the event that announces it.
    ///
    /// What connecting makes the protocol raise is queued behind it: the caller reports the returned
    /// event first.
    func completeNewInboundFlow(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        in eventContext: inout NetworkContext.EventContext
    ) -> StandaloneEvent? {
        guard !eventContext.standaloneLinks[slot].closed else { return nil }
        let kind = eventContext.standaloneLinks[slot].kind
        let flow = StandaloneFlowLink.make(
            kind: kind,
            hasFlowID: true,
            reportsConnectionEvents: false,
            in: &eventContext
        )
        let flowID = StandaloneFlowID(slot: flow.slot)
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
            return nil
        }
        eventContext.standaloneLinks[flow.slot].flowMetadata = flowMetadata
        eventContext.standaloneLinks[flow.slot].releasesFlowsOnDisconnect =
            eventContext.standaloneLinks[slot].releasesFlowsOnDisconnect
        // Connecting hands over anything the flow buffered before it had an upper.
        switch kind {
        case .stream:
            let lower = eventContext.standaloneLinks[flow.slot].streamLower
            lower.invokeConnect(for: flow.identifier, in: &eventContext)
        case .datagram:
            let lower = eventContext.standaloneLinks[flow.slot].datagramLower
            lower.invokeConnect(for: flow.identifier, in: &eventContext)
        }
        return .newInboundFlow(flowID, tag: 0)
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
