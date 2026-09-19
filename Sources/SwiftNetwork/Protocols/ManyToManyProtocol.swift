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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// MARK: - Many-to-Many Protocol Adoption

/// A protocol that handles multiple flows over multiple paths.
///
/// Many-to-many protocols have associated types for flows that connect to upper protocols
/// and paths that connect to lower protocols.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyProtocolHandler: ListenerHandler, LoggableProtocol where Flow: MultiplexedFlow {
    associatedtype Path: MultiplexingPath

    var inboundFlowLinkage: UpperProtocol { get set }

    var multiplexedFlows: [MultiplexedFlowIdentifier: Flow] { get set }
    var multiplexingPaths: [MultiplexingPathIdentifier: Path] { get set }

    // MARK: Connection-wide calls to implement
    func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    /// Requests that this protocol initiate its handshake, if any.
    ///
    /// Thread `eventContext` into any calls made to other protocols so that the state is never
    /// re-derived from the context.
    func connect(in eventContext: inout NetworkContext.EventContext)
    func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)
    func teardown(in eventContext: inout NetworkContext.EventContext)
    mutating func teardownIfPossible(in eventContext: inout NetworkContext.EventContext)
    /// Whether every upper linkage has detached, so the instance's storage can be released.
    ///
    /// A single instance can be shared by more than one upper linkage, such as a QUIC connection
    /// serving both a stream listener and a datagram listener. Each of those detaches separately,
    /// so storage may only be released once the last one has gone.
    var isFullyDetached: Bool { get }
    func handleApplicationEvent(
        _ event: ApplicationEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult

    // MARK: Per-flow calls to implement
    func setup(
        flow: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
    func connect(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext)
    func disconnect(
        flow: MultiplexedFlowIdentifier,
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    )
    func teardown(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext)
    func handleApplicationEvent(
        flow: MultiplexedFlowIdentifier,
        event: ApplicationEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult
    func getMetadata<P>(flow: MultiplexedFlowIdentifier) -> ProtocolMetadata<P>? where P: NetworkProtocol
    func updateDataTransferSnapshot(flow: MultiplexedFlowIdentifier, _ snapshot: inout DataTransferSnapshot)
    var protocolEstablishmentReport: ProtocolEstablishmentReport? { get }

    // MARK: Per-path events to implement
    func handleConnectedEvent(path: MultiplexingPathIdentifier, in eventContext: inout NetworkContext.EventContext)
    func handleDisconnectedEvent(
        path: MultiplexingPathIdentifier,
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    )
    func handlePathChanged(
        path pathID: MultiplexingPathIdentifier,
        event: MultiplexingPathEvent,
        isPrimary: Bool,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleNetworkProtocolEvent(
        path: MultiplexingPathIdentifier,
        event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult

    mutating func attachLowerProtocolForNewPath(
        _ lowerProtocol: Path.LowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Path.LowerProtocol.PairedUpperLinkage

    // MARK: Helper functions implemented by inheriting either HomogeneousManyToManyProtocolHandler or HeterogeneousManyToManyProtocolHandler
    mutating func performInitialSetupIfNeeded(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
    func validate(
        inbound inboundProtocol: InstanceIdentifier,
        _ label: String
    ) throws(ProtocolInstanceError)
}

/// Declares that a many-to-many protocol supports only a single type of flow.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol HomogeneousManyToManyProtocolHandler: ManyToManyProtocolHandler {
}

/// Allows a many-to-many protocol to support a secondary type of flow, for example, both stream flows and datagram flows.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol HeterogeneousManyToManyProtocolHandler: HeterogeneousListenerHandler, ManyToManyProtocolHandler
where SecondaryFlow: MultiplexedFlow {
    var multiplexedSecondaryFlows: [MultiplexedFlowIdentifier: SecondaryFlow] { get set }
    var secondaryInboundFlowLinkage: SecondaryUpperProtocol { get set }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyDatapathProtocol: ManyToManyProtocolHandler
where Flow.UpperProtocol: InboundDataLinkage, Path.LowerProtocol: OutboundDataLinkage {
    func handleInboundDataAvailableEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
    func handleOutboundRoomAvailableEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    )
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyApplicationStreamProtocol: ManyToManyDatapathProtocol {
    func serviceStreamDataToSend(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyApplicationDatagramProtocol: ManyToManyDatapathProtocol {
    func serviceDatagramsToSend(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyOutboundDatagramProtocol: ManyToManyDatapathProtocol
where Path.LowerProtocol: OutboundDatagramLinkage {
    func serviceReceivedDatagrams(path: MultiplexingPathIdentifier, in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct MultiplexedFlowIdentifier: Hashable, Sendable, CustomDebugStringConvertible {

    fileprivate var identifier: UInt64

    public static let allFlows = MultiplexedFlowIdentifier(0)

    private init(_ identifier: UInt64) {
        self.identifier = identifier
    }

    public init(testValue identifier: UInt64) {
        self.identifier = identifier
    }

    // Identify the flow by its own event state, not its parent's: every flow on a connection
    // shares that parent, so allowing the parent index here would collapse them all onto one
    // identifier.
    fileprivate init(_ identifier: InstanceIdentifier) {
        let index = identifier.protocolEventStateIndex(allowParent: false)
        guard !index.isNone else {
            self = .allFlows
            return
        }
        // The whole state index, slot and generation together, so a reused slot never collides
        // with the flow that previously held it. `.none` is all-zeros, which is why `.allFlows`
        // can use zero as its own value.
        self.identifier = index.rawValue
    }

    // Inbound and outbound flows are identified the same way; the spelling is kept so call sites
    // still say which side they are on.
    fileprivate init(inboundInstance: InstanceIdentifier) {
        self.init(inboundInstance)
    }

    public func _rawHashValue(seed: Int) -> Int {
        self.identifier._rawHashValue(seed: seed)
    }

    public var debugDescription: String {
        guard identifier != 0 else { return "All Flows" }
        #if !NETWORK_EMBEDDED
        return "\(identifier)"
        #else
        return "Some Flow"
        #endif
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexedFlow: LowerProtocolHandler, LoggableProtocol {
    associatedtype ParentProtocol: ManyToManyProtocolHandler
    var upper: UpperProtocol { get set }
    var parentProtocol: ParentProtocol { get set }
    var flowIdentifier: MultiplexedFlowIdentifier { get }
    init(parent: ParentProtocol, inbound: Bool)
    /// Hands over events that were buffered before this flow had an upper protocol.
    ///
    /// A requirement rather than just an extension member so that refinements which can deliver
    /// more event kinds — unidirectional aborts, say — are dispatched to.
    func drainQueuedEventsForUpperProtocol(in eventContext: inout NetworkContext.EventContext)
    /// Releases whatever this flow holds, as its upper protocol detaches.
    ///
    /// Empty by default.
    func teardown(in eventContext: inout NetworkContext.EventContext)
    /// Creates a flow using an event context the caller already holds.
    ///
    /// Prefer this over `init(parent:inbound:)` anywhere the state is already in scope, so
    /// registering the flow's identifier doesn't re-derive it from the context.
    init(parent: ParentProtocol, inbound: Bool, in eventContext: inout NetworkContext.EventContext)
    var upperReceiveQueue: FrameArray { get set }
    var upperSendQueue: FrameArray { get set }
    func asLowerLinkage() -> UpperProtocol.PairedLowerLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexedDatapathFlow<UpperProtocol>: MultiplexedFlow
where UpperProtocol: InboundDataLinkage, ParentProtocol: ManyToManyDatapathProtocol {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias MultiplexingPathIdentifier = Int
@available(Network 0.1.0, *)
extension MultiplexingPathIdentifier {
    static var none: Self {
        0
    }

    init() {
        self = Int.random(in: 1...Int.max)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
@frozen public enum MultiplexingPathEvent: CustomStringConvertible {
    // During bringup of the path it is possible that the endpoints may have changed
    case available(local: Endpoint?, remote: Endpoint?, path: PathProperties?, parameters: Parameters?)
    case unavailable
    case established

    public var description: String {
        switch self {
        case .available: return "available"
        case .unavailable: return "unavailable"
        case .established: return "established"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexingPath: UpperProtocolHandler {
    associatedtype ParentProtocol: ManyToManyProtocolHandler
    var lower: LowerProtocol { get set }
    var parentProtocol: ParentProtocol { get }
    var pathIdentifier: MultiplexingPathIdentifier { get }
    init(parent: ParentProtocol, in eventContext: inout NetworkContext.EventContext)
    var pathIsPrimary: Bool { get set }
    var pathHasMigrationInfo: Bool { get set }
    func asUpperLinkage() -> LowerProtocol.PairedUpperLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexingDatapathPath<LowerProtocol>: MultiplexingPath
where LowerProtocol: OutboundDataLinkage, ParentProtocol: ManyToManyDatapathProtocol {}

// MARK: Implementations

@available(Network 0.1.0, *)
extension ManyToManyProtocolHandler {
    // Default implementations, to be overridden as necessary
    public func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {}

    public func teardown(in eventContext: inout NetworkContext.EventContext) {}

    public func connect(in eventContext: inout NetworkContext.EventContext) {}

    public func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {}

    public func handleApplicationEvent(
        _ event: ApplicationEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult { .unconsumed }

    public func setup(
        flow: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {}

    public func connect(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext) {
        deliverConnectedEvent(flow: flow, in: &eventContext)
    }

    public func disconnect(
        flow: MultiplexedFlowIdentifier,
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    public func teardown(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext) {}
    public func handleApplicationEvent(
        flow: MultiplexedFlowIdentifier,
        event: ApplicationEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult { .unconsumed }

    public func getMetadata<P>(flow: MultiplexedFlowIdentifier) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        nil
    }

    public func getMetadata<P>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        getMetadata(flow: .allFlows)
    }

    public func updateDataTransferSnapshot(flow: MultiplexedFlowIdentifier, _ snapshot: inout DataTransferSnapshot) {}
    public var protocolEstablishmentReport: ProtocolEstablishmentReport? { nil }

    public func getMetrics(
        flow: MultiplexedFlowIdentifier,
        requestedNetworkMetric: RequestedNetworkMetrics
    ) -> NetworkMetrics? {
        switch requestedNetworkMetric {
        case .protocolEstablishmentReports:
            guard let report = protocolEstablishmentReport else { return nil }
            return .protocolEstablishmentReports([report])
        case .dataTransferSnapshot:
            var snapshot = DataTransferSnapshot()
            updateDataTransferSnapshot(flow: flow, &snapshot)
            return .dataTransferSnapshot(snapshot)
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        getMetrics(flow: .allFlows, requestedNetworkMetric: requestedNetworkMetric)
    }

    public func handleInboundDataAvailableEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    public func handleOutboundRoomAvailableEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}

    public func handleConnectedEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    public func handleDisconnectedEvent(
        path: MultiplexingPathIdentifier,
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    public func handlePathChanged(
        path pathID: MultiplexingPathIdentifier,
        event: MultiplexingPathEvent,
        isPrimary: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    public func handleNetworkProtocolEvent(
        path: MultiplexingPathIdentifier,
        event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult { .unconsumed }
}

@available(Network 0.1.0, *)
extension ManyToManyProtocolHandler {
    /// Hands this instance's event state back once every upper linkage has detached.
    fileprivate func releaseEventStateOnceDetached(in eventContext: inout NetworkContext.EventContext) {
        var mutableSelf = self
        mutableSelf.unregisterEventManager(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension ManyToManyProtocolHandler {
    public mutating func attachLowerProtocolForNewPath(
        _ lowerProtocol: Path.LowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Path.LowerProtocol.PairedUpperLinkage
    where Path.ParentProtocol == Self {
        var newPath = Path(parent: self, in: &eventContext)
        _ = try newPath.attachLowerProtocol(lowerProtocol)
        let isFirstPath = multiplexingPaths.isEmpty
        if isFirstPath { newPath.pathIsPrimary = true }
        if path?.hasMigrationInfo == true { newPath.pathHasMigrationInfo = true }
        multiplexingPaths[newPath.pathIdentifier] = newPath
        let upperLinkage = newPath.asUpperLinkage()
        // Bind the lower protocol's upper side before announcing the path. Announcing it can take
        // the protocol straight into `invokeEstablish`, and a lower protocol that connects
        // synchronously delivers its connected event back up the moment it is asked to connect. If
        // the binding happened afterwards, that event would arrive at a detached upper linkage and
        // be dropped, leaving the path stuck in `routeAvailable`.
        try lowerProtocol.invokeAttachUpperProtocol(
            upperLinkage,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
        if !isFirstPath {
            handlePathChanged(
                path: newPath.pathIdentifier,
                event: .available(local: local, remote: remote, path: path, parameters: parameters),
                isPrimary: newPath.pathIsPrimary,
                in: &eventContext
            )
        }
        return upperLinkage
    }

    fileprivate func connectInternal(in eventContext: inout NetworkContext.EventContext) {
        if somePathIsConnected(in: &eventContext) {
            if canCallConnect(requested: true, in: &eventContext) {
                connect(in: &eventContext)
            }
        } else {
            connectRequested(in: &eventContext)
            for path in multiplexingPaths.values {
                path.invokeConnect(in: &eventContext)
            }
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        do { try validate(inbound: instance, #function) } catch { return }
        connectInternal(in: &eventContext)
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(inbound: instance, #function) } catch { return }
        if canCallDisconnect(in: &eventContext) {
            disconnect(error: error, in: &eventContext)
        }
    }

    public func flow(for flowID: MultiplexedFlowIdentifier) -> Flow? {
        multiplexedFlows[flowID]
    }

    public var someFlow: Flow? {
        multiplexedFlows.first?.value
    }

    public var someFlowIdentifier: MultiplexedFlowIdentifier? {
        multiplexedFlows.first?.value.flowIdentifier
    }

    public func findFlow(where closure: (_ flow: Flow) -> Bool) -> MultiplexedFlowIdentifier? {
        var returnFlowID: MultiplexedFlowIdentifier?
        for (flowID, flow) in multiplexedFlows {
            if closure(flow) {
                returnFlowID = flowID
                break
            }
        }
        return returnFlowID
    }

    public func allFlowIdentifiers(_ closure: (MultiplexedFlowIdentifier) -> Void) {
        multiplexedFlows.keys.forEach(closure)
    }

    public func applyToAllFlows(_ closure: (Flow) -> Void) {
        multiplexedFlows.values.forEach(closure)
    }

    public func path(for pathID: MultiplexingPathIdentifier) -> Path? {
        multiplexingPaths[pathID]
    }

    public var somePath: Path? {
        multiplexingPaths.first?.value
    }

    public var somePathIdentifier: MultiplexingPathIdentifier? {
        multiplexingPaths.first?.value.pathIdentifier
    }

    public func allPathIdentifiers(_ closure: (MultiplexingPathIdentifier) -> Void) {
        multiplexingPaths.keys.forEach(closure)
    }

    public func applyToAllPaths(_ closure: (Path) -> Void) {
        multiplexingPaths.values.forEach(closure)
    }

    public func somePathIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        for path in multiplexingPaths.values {
            if path.lower.protocolIsConnected(in: &eventContext) {
                return true
            }
        }
        return false
    }

    fileprivate mutating func resetPrimaryPath(newPrimary: MultiplexingPathIdentifier) {
        allPathIdentifiers { pathIdentifier in
            if pathIdentifier == newPrimary {
                multiplexingPaths[pathIdentifier]?.pathIsPrimary = true
            } else {
                multiplexingPaths[pathIdentifier]?.pathIsPrimary = false
            }
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate upper, can pass through
        if self.handleApplicationEvent(event, in: &eventContext) == .consumed { return }
        applyToAllPaths { path in
            path.lower.invokeApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }
}

@available(Network 0.1.0, *)
extension HomogeneousManyToManyProtocolHandler {

    public mutating func performInitialSetupIfNeeded(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard hasNoUpperLinkages else {
            // Already set up
            return
        }

        #if !NETWORK_EMBEDDED
        if let parameters, let options = getOptions(from: parameters, for: .allFlows) {
            self.log.logPrefix = options.logIDString ?? ""
        }
        #endif

        try self.setup(remote: remote, local: local, parameters: parameters, path: path)
    }

    public mutating func attachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard inboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.inboundFlowLinkage = upperProtocol
    }

    public mutating func attachUpperProtocolToNewFlow(
        _ upperProtocol: Flow.UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Flow.UpperProtocol.PairedLowerLinkage where Flow.ParentProtocol == Self {
        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = Flow(parent: self, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        newFlow.upper = upperProtocol
        multiplexedFlows[newFlow.flowIdentifier] = newFlow

        return newFlow.asLowerLinkage()
    }

    public mutating func attachUpperProtocolToExistingFlow(
        _ upperProtocol: Flow.UpperProtocol,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> Flow.UpperProtocol.PairedLowerLinkage {
        let flowID = MultiplexedFlowIdentifier(inboundInstance: existingFlowInstance)
        guard var existingFlow = flow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = upperProtocol
        return existingFlow.asLowerLinkage()
    }

    public func validate(
        inbound inboundProtocol: InstanceIdentifier,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard inboundProtocol == inboundFlowLinkage.identifier else {
            Logger.proto.fault("Received \'\(label)\' from incorrect inbound flow protocol")
            throw ProtocolInstanceError.invalidNewFlowLinkage
        }
        #endif
    }

    fileprivate var hasNoUpperLinkages: Bool {
        multiplexedFlows.isEmpty && inboundFlowLinkage.isDetached
    }

    public var isFullyDetached: Bool { hasNoUpperLinkages }

    public mutating func teardownIfPossible(in eventContext: inout NetworkContext.EventContext) {
        guard hasNoUpperLinkages else {
            // Still has some flow
            return
        }
        teardown(in: &eventContext)
        allPathIdentifiers { pathIdentifier in
            multiplexingPaths[pathIdentifier]?.destroy(in: &eventContext)
        }
        multiplexingPaths.removeAll()
        releaseEventStateOnceDetached(in: &eventContext)
    }

    public mutating func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(inbound: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        inboundFlowLinkage = .init()
        teardownIfPossible(in: &eventContext)
    }

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters, for flowID: MultiplexedFlowIdentifier) -> ProtocolOptions<T>?
    {
        if case .allFlows = flowID {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: identifier) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.identifier)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: flow.identifier) {
                return options
            }
        }
        return parameters.protocolOptions(for: identifier)
    }
    public func getOptions(
        from parameters: Parameters,
        for flowID: MultiplexedFlowIdentifier
    ) -> AbstractProtocolOptions? {
        if case .allFlows = flowID {
            if let options = parameters.protocolOptions(for: identifier) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.identifier)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options = parameters.protocolOptions(for: flow.identifier) {
                return options
            }
        }
        return parameters.protocolOptions(for: identifier)
    }
    #endif
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler {
    fileprivate var hasNoUpperLinkages: Bool {
        multiplexedFlows.isEmpty && multiplexedSecondaryFlows.isEmpty && inboundFlowLinkage.isDetached
            && secondaryInboundFlowLinkage.isDetached
    }

    public var isFullyDetached: Bool { hasNoUpperLinkages }

    public mutating func teardownIfPossible(in eventContext: inout NetworkContext.EventContext) {
        guard hasNoUpperLinkages else {
            // Still has some flow
            return
        }
        teardown(in: &eventContext)
        allPathIdentifiers { pathIdentifier in
            multiplexingPaths[pathIdentifier]?.destroy(in: &eventContext)
        }
        multiplexingPaths.removeAll()
        releaseEventStateOnceDetached(in: &eventContext)
    }

    public mutating func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(inbound: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        if instance == secondaryInboundFlowLinkage.identifier {
            secondaryInboundFlowLinkage = .init()
        } else {
            inboundFlowLinkage = .init()
        }
        teardownIfPossible(in: &eventContext)
    }

    public func validate(
        inbound inboundProtocol: InstanceIdentifier,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard
            inboundProtocol == inboundFlowLinkage.identifier
                || inboundProtocol == secondaryInboundFlowLinkage.identifier
        else {
            Logger.proto.fault("Received \'\(label)\' from incorrect inbound flow protocol")
            throw ProtocolInstanceError.invalidNewFlowLinkage
        }
        #endif
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler {
    public mutating func performInitialSetupIfNeeded(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard hasNoUpperLinkages else {
            // Already set up
            return
        }

        #if !NETWORK_EMBEDDED
        if let parameters, let options = getOptions(from: parameters, for: .allFlows) {
            self.log.logPrefix = options.logIDString ?? ""
        }
        #endif

        try self.setup(remote: remote, local: local, parameters: parameters, path: path)
    }

    public mutating func attachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard inboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.inboundFlowLinkage = upperProtocol
    }

    public mutating func attachUpperProtocol(
        _ upperProtocol: SecondaryUpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard secondaryInboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.secondaryInboundFlowLinkage = upperProtocol
    }

    public mutating func attachUpperProtocolToNewFlow(
        _ upperProtocol: Flow.UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Flow.UpperProtocol.PairedLowerLinkage where Flow.ParentProtocol == Self {
        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = Flow(parent: self, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        newFlow.upper = upperProtocol
        multiplexedFlows[newFlow.flowIdentifier] = newFlow

        return newFlow.asLowerLinkage()
    }

    public mutating func attachUpperProtocolToNewFlow(
        _ upperProtocol: SecondaryFlow.UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> SecondaryFlow.UpperProtocol.PairedLowerLinkage
    where SecondaryFlow.ParentProtocol == Self {
        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = SecondaryFlow(parent: self, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        newFlow.upper = upperProtocol
        multiplexedSecondaryFlows[newFlow.flowIdentifier] = newFlow

        return newFlow.asLowerLinkage()
    }

    public mutating func attachUpperProtocolToExistingFlow(
        _ upperProtocol: Flow.UpperProtocol,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> Flow.UpperProtocol.PairedLowerLinkage {
        let flowID = MultiplexedFlowIdentifier(inboundInstance: existingFlowInstance)
        guard var existingFlow = flow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = upperProtocol
        return existingFlow.asLowerLinkage()
    }

    public mutating func attachUpperProtocolToExistingFlow(
        _ upperProtocol: SecondaryFlow.UpperProtocol,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> SecondaryFlow.UpperProtocol.PairedLowerLinkage {
        let flowID = MultiplexedFlowIdentifier(inboundInstance: existingFlowInstance)
        guard var existingFlow = secondaryFlow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = upperProtocol
        return existingFlow.asLowerLinkage()
    }

    public mutating func addInboundSecondaryFlow(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> MultiplexedFlowIdentifier
    where
        SecondaryFlow.ParentProtocol == Self,
        SecondaryUpperProtocol.DataLinkage.PairedUpperLinkage == SecondaryFlow.UpperProtocol,
        SecondaryUpperProtocol.DataLinkage == SecondaryFlow.UpperProtocol.PairedLowerLinkage
    {

        let newFlow = SecondaryFlow(parent: self, inbound: true, in: &eventContext)
        multiplexedSecondaryFlows[newFlow.flowIdentifier] = newFlow
        deliverNewInboundFlowEvent(newFlow.identifier, flowMetadata: nil, in: &eventContext)

        return newFlow.flowIdentifier
    }

    public func deliverNewInboundSecondaryFlowEvent(
        _ flowInstance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        secondaryInboundFlowLinkage.deliverNewInboundFlowEvent(
            flowInstance: flowInstance,
            flowMetadata: nil,
            from: identifier,
            in: &eventContext
        )
    }

    public func secondaryFlow(for flowID: MultiplexedFlowIdentifier) -> SecondaryFlow? {
        multiplexedSecondaryFlows[flowID]
    }

    public var someSecondaryFlow: SecondaryFlow? {
        multiplexedSecondaryFlows.first?.value
    }

    public var someSecondaryFlowIdentifier: MultiplexedFlowIdentifier? {
        multiplexedSecondaryFlows.first?.value.flowIdentifier
    }

    public func findSecondaryFlow(where closure: (_ flow: SecondaryFlow) -> Bool) -> MultiplexedFlowIdentifier? {
        var returnFlowID: MultiplexedFlowIdentifier?
        for (flowID, flow) in multiplexedSecondaryFlows {
            if closure(flow) {
                returnFlowID = flowID
                break
            }
        }
        return returnFlowID
    }

    public func allSecondaryFlowIdentifiers(_ closure: (MultiplexedFlowIdentifier) -> Void) {
        multiplexedSecondaryFlows.keys.forEach(closure)
    }

    public func applyToAllSecondaryFlows(_ closure: (SecondaryFlow) -> Void) {
        multiplexedSecondaryFlows.values.forEach(closure)
    }

    #if !NETWORK_NO_SWIFT_QUIC
    public func quicOptions(
        from parameters: Parameters,
        for flowID: MultiplexedFlowIdentifier
    ) -> ProtocolOptions<QUICProtocol>? {
        if case .allFlows = flowID {
            if let options = parameters.quicOptions(for: identifier) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.quicOptions(for: someFlow.identifier)
            }
            if let someFlow = someSecondaryFlow {
                return parameters.quicOptions(for: someFlow.identifier)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options = parameters.quicOptions(for: flow.identifier) {
                return options
            }
        }
        if let flow = secondaryFlow(for: flowID) {
            if let options = parameters.quicOptions(for: flow.identifier) {
                return options
            }
        }
        return parameters.quicOptions(for: identifier)
    }
    #endif

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters, for flowID: MultiplexedFlowIdentifier) -> ProtocolOptions<T>?
    {
        if case .allFlows = flowID {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: identifier) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.identifier)
            }
            if let someFlow = someSecondaryFlow {
                return parameters.protocolOptions(for: someFlow.identifier)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: flow.identifier) {
                return options
            }
        }
        if let flow = secondaryFlow(for: flowID) {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: flow.identifier) {
                return options
            }
        }
        return parameters.protocolOptions(for: identifier)
    }
    public func getOptions(
        from parameters: Parameters,
        for flowID: MultiplexedFlowIdentifier
    ) -> AbstractProtocolOptions? {
        if case .allFlows = flowID {
            if let options = parameters.protocolOptions(for: identifier) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.identifier)
            }
            if let someFlow = someSecondaryFlow {
                return parameters.protocolOptions(for: someFlow.identifier)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options = parameters.protocolOptions(for: flow.identifier) {
                return options
            }
        }
        if let flow = secondaryFlow(for: flowID) {
            if let options = parameters.protocolOptions(for: flow.identifier) {
                return options
            }
        }
        return parameters.protocolOptions(for: identifier)
    }
    #endif
}

@available(Network 0.1.0, *)
extension MultiplexedFlow {
    internal func validate(
        upper upperProtocol: InstanceIdentifier,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard upperProtocol == upper.identifier else {
            Logger.proto.fault("Received \'\(label)\' from incorrect upper protocol")
            throw ProtocolInstanceError.invalidUpperProtocol
        }
        #endif
    }

    public var context: NetworkContext { parentProtocol.context }

    /// Empty by default; a flow with per-flow cleanup overrides this.
    public func teardown(in eventContext: inout NetworkContext.EventContext) {}

    public mutating func attachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        // `attachUpperProtocolToNewFlow` already bound this upper when it created the flow, so
        // seeing the same one again is the expected second leg of the attach, not a conflict.
        // A *different* upper is still rejected.
        guard upper.isDetached || upper == upperProtocol else {
            throw NetworkError.posix(EALREADY)
        }
        upper = upperProtocol

        do {
            try parentProtocol.setup(
                flow: flowIdentifier,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch let error {
            upper = .init()
            throw error
        }
    }

    public mutating func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        teardown(in: &eventContext)
        parentProtocol.teardown(flow: flowIdentifier, in: &eventContext)
        parentProtocol.multiplexedFlows.removeValue(forKey: flowIdentifier)
        upper = UpperProtocol()
        self.identifier.discardPendingEventsForUpperProtocol(in: &eventContext)
        upperReceiveQueue.finalizeAllFramesAsFailed()
        upperSendQueue.finalizeAllFramesAsFailed()
        parentProtocol.teardownIfPossible(in: &eventContext)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        do { try validate(upper: instance, #function) } catch { return }
        if parentProtocol.isConnected(in: &eventContext) {
            if canCallConnect(requested: true, in: &eventContext) {
                parentProtocol.connect(flow: flowIdentifier, in: &eventContext)
            }
        } else {
            connectRequested(in: &eventContext)
            parentProtocol.connectInternal(in: &eventContext)
        }
        // Hand over anything buffered while this flow had no upper protocol. This runs after
        // connecting so the connected event is delivered first, matching the ordering the
        // non-detached path in `deliverConnectedEvent` produces.
        drainQueuedEventsForUpperProtocol(in: &eventContext)
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(upper: instance, #function) } catch { return }
        if canCallDisconnect(in: &eventContext) {
            parentProtocol.disconnect(flow: flowIdentifier, error: error, in: &eventContext)
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate upper, can pass through
        if parentProtocol.handleApplicationEvent(flow: flowIdentifier, event: event, in: &eventContext) == .consumed {
            return
        }
        parentProtocol.applyToAllPaths { path in
            path.lower.invokeApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func getMetadata<P>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        do { try validate(upper: instance, #function) } catch { return nil }
        return parentProtocol.getMetadata(flow: flowIdentifier)
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        do { try validate(upper: instance, #function) } catch { return nil }
        return parentProtocol.getMetrics(flow: flowIdentifier, requestedNetworkMetric: requestedNetworkMetric)
    }

    fileprivate func deliverConnectedEvent() {
        fromExternal { eventContext in
            deliverConnectedEvent(in: &eventContext)
        }
    }

    /// Hands over events that were buffered before this flow had an upper protocol.
    ///
    /// A buffered event carries its payload but no delivery block, because the upper was unknown
    /// when it was queued. Supply blocks that route to the now-attached upper linkage.
    ///
    /// Flows whose upper linkage can deliver more event kinds (unidirectional aborts, say)
    /// override this to route those too.
    public func drainQueuedEventsForUpperProtocol(in eventContext: inout NetworkContext.EventContext) {
        let upperProtocol = upper
        self.identifier.reassignQueuedPendingEventsForUpperProtocol(
            to: upperProtocol.identifier,
            in: &eventContext,
            block: { eventContext, from in
                upperProtocol.handleConnectedEvent(for: from, in: &eventContext)
            },
            errorBlock: { eventContext, from, error in
                upperProtocol.handleDisconnectedEvent(error: error, for: from, in: &eventContext)
            },
            newInboundFlowBlock: { _, _, _, _ in },
            networkProtocolEventBlock: { eventContext, from, event in
                upperProtocol.handleNetworkProtocolEvent(event: event, for: from, in: &eventContext)
            },
            // A plain data linkage has no unidirectional aborts to deliver.
            inboundAbortedBlock: { _, _, _ in },
            outboundAbortedBlock: { _, _, _ in }
        )
    }

    fileprivate func deliverConnectedEvent(in eventContext: inout NetworkContext.EventContext) {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfInstance = self.identifier
            selfInstance.enqueuePendingEventForUpperProtocol(
                event: .connected(
                    selfInstance,
                    upper.identifier,
                    { _, _ in

                    }
                ),
                in: &eventContext
            )
        } else {
            // Deliver connected event *followed by* any events which were buffered while detached
            upper.deliverConnectedEvent(from: self.identifier, in: &eventContext)
            drainQueuedEventsForUpperProtocol(in: &eventContext)
        }
    }

    fileprivate func deliverDisconnectedEvent(error: NetworkError?) {
        fromExternal { eventContext in
            deliverDisconnectedEvent(error: error, in: &eventContext)
        }
    }

    fileprivate func deliverDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)
    {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfInstance = self.identifier
            selfInstance.enqueuePendingEventForUpperProtocol(
                event: .disconnected(
                    selfInstance,
                    upper.identifier,
                    error: error,
                    { _, _, _ in

                    }
                ),
                in: &eventContext
            )
        } else {
            upper.deliverDisconnectedEvent(error: error, from: self.identifier, in: &eventContext)
        }
    }

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters) -> ProtocolOptions<T>? {
        parameters.protocolOptions(for: identifier)
    }
    public func getOptions(from parameters: Parameters) -> AbstractProtocolOptions? {
        parameters.protocolOptions(for: identifier)
    }
    #endif
}

@available(Network 0.1.0, *)
extension MultiplexedFlow where ParentProtocol: HeterogeneousManyToManyProtocolHandler {
    public mutating func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        teardown(in: &eventContext)
        parentProtocol.teardown(flow: flowIdentifier, in: &eventContext)
        parentProtocol.multiplexedFlows.removeValue(forKey: flowIdentifier)
        parentProtocol.multiplexedSecondaryFlows.removeValue(forKey: flowIdentifier)
        upper = UpperProtocol()
        self.identifier.discardPendingEventsForUpperProtocol(in: &eventContext)
        upperReceiveQueue.finalizeAllFramesAsFailed()
        upperSendQueue.finalizeAllFramesAsFailed()
        parentProtocol.teardownIfPossible(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension MultiplexedDatapathFlow where Self: AutomaticUpperStreamProcessing {
    public mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        return try receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
    }

    public func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try getOutboundStreamDataRoomAvailable(in: &eventContext)
    }

    public mutating func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(upper: instance, #function) } catch {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        guard isConnected(in: &eventContext) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try sendStreamData(streamData, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension MultiplexedDatapathFlow where Self: AutomaticUpperStreamProcessing, Self: OutboundStreamEarlyDataHandler {
    public mutating func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(upper: instance, #function) } catch {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        try sendEarlyStreamData(streamData, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension ManyToManyApplicationStreamProtocol where Flow: AutomaticUpperStreamProcessing {
    public func accessStreamDataToSend(flow flowID: MultiplexedFlowIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var flow = self.flow(for: flowID) else { return }
        body(&flow.upperSendQueue)
    }

    // Access the upperSendQueue directly from the flow
    public func accessStreamDataToSend(stream: Flow, _ body: (inout FrameArray) -> Void) {
        var flow = stream
        body(&flow.upperSendQueue)
    }

    public func blockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = true
    }

    public func unblockSending(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = false
        flow.upper.deliverOutboundRoomAvailableEvent(from: flow.identifier, in: &eventContext)
    }

    public func enqueueInboundStreamData(
        flow flowID: MultiplexedFlowIdentifier,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        return try flow.addToUpperReceiveQueue(streamData)
    }

    public func deliverEnqueuedInboundStreamData(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard let flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        flow.serviceUpperReceiveQueue(in: &eventContext)
    }
    // Enqueue and delivery the stream data all in one shot
    public func deliverInboundStreamData(
        flow flowID: MultiplexedFlowIdentifier,
        streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        try deliverInboundStreamData(flow: &flow, streamData: streamData, in: &eventContext)
    }

    // Enqueue and deliver the stream data directly to the flow
    public func deliverInboundStreamData(
        flow existingFlow: inout Flow,
        streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try existingFlow.addToUpperReceiveQueue(streamData)
        existingFlow.serviceUpperReceiveQueue(in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
open class MultiplexedStreamFlow<
    ParentProtocol: ManyToManyApplicationStreamProtocol,
    LinkageType: InboundStreamLinkage
>: MultiplexedDatapathFlow,
    AutomaticUpperStreamProcessing
{
    public typealias ParentProtocol = ParentProtocol
    public typealias UpperProtocol = LinkageType

    public var parentProtocol: ParentProtocol
    public var upper = UpperProtocol()
    public var eventManager = ProtocolEventManager()

    public var upperSendQueue = FrameArray()
    public var upperReceiveQueue = FrameArray()
    public var maximumStreamDataSize: Int = Int.max
    public var blockUpperSendQueue: Bool = false

    public var log = NetworkLoggerState()

    public var flowIdentifier: MultiplexedFlowIdentifier

    public var identifier: InstanceIdentifier

    public func serviceUpperSendQueue(in eventContext: inout NetworkContext.EventContext) {
        parentProtocol.serviceStreamDataToSend(flow: flowIdentifier, in: &eventContext)
    }

    public required init(parent: ParentProtocol, inbound: Bool) {
        self.parentProtocol = parent
        identifier = .init(context: parent.context, eventManager: &self.eventManager)
        identifier.setParentInstance(parent.identifier)

        if inbound {
            flowIdentifier = .init(inboundInstance: identifier)
        } else {
            flowIdentifier = .init(identifier)
        }
    }

    public required init(parent: ParentProtocol, inbound: Bool, in eventContext: inout NetworkContext.EventContext) {
        self.parentProtocol = parent
        identifier = .init(eventManager: &self.eventManager, context: parent.context, in: &eventContext)
        identifier.setParentInstance(parent.identifier)

        if inbound {
            flowIdentifier = .init(inboundInstance: identifier)
        } else {
            flowIdentifier = .init(identifier)
        }
    }

    public func upperReceiveQueueDrainedBytes(_ bytes: Int, in eventContext: inout NetworkContext.EventContext) {
        // No-op by default
    }

    /// Also routes the unidirectional abort events, which only a stream linkage can handle.
    public func drainQueuedEventsForUpperProtocol(in eventContext: inout NetworkContext.EventContext) {
        let upperProtocol = upper
        self.identifier.reassignQueuedPendingEventsForUpperProtocol(
            to: upperProtocol.identifier,
            in: &eventContext,
            block: { eventContext, from in
                upperProtocol.handleConnectedEvent(for: from, in: &eventContext)
            },
            errorBlock: { eventContext, from, error in
                upperProtocol.handleDisconnectedEvent(error: error, for: from, in: &eventContext)
            },
            newInboundFlowBlock: { _, _, _, _ in },
            networkProtocolEventBlock: { eventContext, from, event in
                upperProtocol.handleNetworkProtocolEvent(event: event, for: from, in: &eventContext)
            },
            inboundAbortedBlock: { eventContext, from, error in
                upperProtocol.handleInboundAbortedEvent(error: error, for: from, in: &eventContext)
            },
            outboundAbortedBlock: { eventContext, from, error in
                upperProtocol.handleOutboundAbortedEvent(error: error, for: from, in: &eventContext)
            }
        )
    }

    /// To be overridden by subclasses
    open func asLowerLinkage() -> UpperProtocol.PairedLowerLinkage {
        .init()
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol UnidirectionalAbortingStreamFlow: MultiplexedDatapathFlow, OutboundStreamUnidirectionalAbortHandler {
    func abortInbound(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)
    func abortOutbound(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)
}

@available(Network 0.1.0, *)
extension UnidirectionalAbortingStreamFlow {
    public func deliverInboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfInstance = self.identifier
            selfInstance.enqueuePendingEventForUpperProtocol(
                event: .inboundAborted(
                    selfInstance,
                    upper.identifier,
                    error: error,
                    { _, _, _ in

                    }
                ),
                in: &eventContext
            )
        } else {
            upper.deliverInboundAbortedEvent(error: error, from: self.identifier, in: &eventContext)
        }
    }

    public func deliverOutboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfInstance = self.identifier
            selfInstance.enqueuePendingEventForUpperProtocol(
                event: .outboundAborted(
                    selfInstance,
                    upper.identifier,
                    error: error,
                    { _, _, _ in

                    }
                ),
                in: &eventContext
            )
        } else {
            upper.deliverOutboundAbortedEvent(error: error, from: self.identifier, in: &eventContext)
        }
    }

    public func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(upper: instance, #function) } catch { return }
        guard isConnected(in: &eventContext) else { return }
        abortInbound(error: error, in: &eventContext)
    }

    public func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(upper: instance, #function) } catch { return }
        guard isConnected(in: &eventContext) else { return }
        abortOutbound(error: error, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol EarlyDataStreamFlow: MultiplexedDatapathFlow, OutboundStreamEarlyDataHandler {}

@available(Network 0.1.0, *)
extension MultiplexedDatapathFlow where Self: AutomaticUpperDatagramProcessing {
    public mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try receiveDatagrams(maximumDatagramCount: maximumDatagramCount, in: &eventContext)
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            in: &eventContext
        )
    }

    public mutating func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        do { try validate(upper: instance, #function) } catch {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        guard isConnected(in: &eventContext) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try sendDatagrams(datagrams, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension ManyToManyApplicationDatagramProtocol where Flow: AutomaticUpperDatagramProcessing {
    public func accessDatagramsToSend(flow flowID: MultiplexedFlowIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var flow = self.flow(for: flowID) else { return }
        body(&flow.upperSendQueue)
    }

    // Access the upperSendQueue directly from the flow
    public func accessDatagramsToSend(flow: Flow, _ body: (inout FrameArray) -> Void) {
        var flow = flow
        body(&flow.upperSendQueue)
    }

    public func blockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = true
    }

    public func unblockSending(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = false
        flow.upper.deliverOutboundRoomAvailableEvent(from: flow.identifier, in: &eventContext)
    }

    public func enqueueInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        return try flow.addToUpperReceiveQueue(datagrams)
    }

    public func deliverEnqueuedInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard let flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        flow.serviceUpperReceiveQueue(in: &eventContext)
    }

    // Enqueue and delivery the datagrams all in one shot
    public func deliverInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        try flow.addToUpperReceiveQueue(datagrams)
        flow.serviceUpperReceiveQueue(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler where SecondaryFlow: AutomaticUpperDatagramProcessing {
    public func accessDatagramsToSend(flow flowID: MultiplexedFlowIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var flow = self.secondaryFlow(for: flowID) else { return }
        body(&flow.upperSendQueue)
    }

    // Access the upperSendQueue directly from the flow
    public func accessDatagramsToSend(flow: SecondaryFlow, _ body: (inout FrameArray) -> Void) {
        var flow = flow
        body(&flow.upperSendQueue)
    }

    public func blockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.secondaryFlow(for: flowID) else { return }
        flow.blockUpperSendQueue = true
    }

    public func unblockSending(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard var flow = self.secondaryFlow(for: flowID) else { return }
        flow.blockUpperSendQueue = false
        flow.upper.deliverOutboundRoomAvailableEvent(from: flow.identifier, in: &eventContext)
    }

    public func enqueueInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.secondaryFlow(for: flowID) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        return try flow.addToUpperReceiveQueue(datagrams)
    }

    public func deliverEnqueuedInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard let flow = self.secondaryFlow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        flow.serviceUpperReceiveQueue(in: &eventContext)
    }

    // Enqueue and delivery the datagrams all in one shot
    public func deliverInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard var flow = self.secondaryFlow(for: flowID) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        try deliverInboundDatagrams(flow: &flow, datagrams: datagrams, in: &eventContext)
    }

    // Enqueue and deliver the datagrams directly to the flow
    public func deliverInboundDatagrams(
        flow existingFlow: inout SecondaryFlow,
        datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try existingFlow.addToUpperReceiveQueue(datagrams)
        existingFlow.serviceUpperReceiveQueue(in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
open class MultiplexedDatagramFlow<
    ParentProtocol: ManyToManyApplicationDatagramProtocol,
    LinkageType: InboundDatagramLinkage
>: MultiplexedDatapathFlow,
    AutomaticUpperDatagramProcessing
{
    public typealias ParentProtocol = ParentProtocol
    public typealias UpperProtocol = LinkageType

    public var parentProtocol: ParentProtocol
    public var upper = UpperProtocol()
    public var eventManager = ProtocolEventManager()

    public var upperSendQueue = FrameArray()
    public var upperReceiveQueue = FrameArray()
    public var maximumUpperDatagramSize: Int = 0
    public var blockUpperSendQueue: Bool = false

    public var log = NetworkLoggerState()

    public var flowIdentifier: MultiplexedFlowIdentifier

    public var identifier: InstanceIdentifier

    public func serviceUpperSendQueue(in eventContext: inout NetworkContext.EventContext) {
        parentProtocol.serviceDatagramsToSend(flow: flowIdentifier, in: &eventContext)
    }

    public required init(parent: ParentProtocol, inbound: Bool) {
        self.parentProtocol = parent
        identifier = .init(context: parent.context, eventManager: &self.eventManager)
        identifier.setParentInstance(parent.identifier)
        if inbound {
            flowIdentifier = .init(inboundInstance: identifier)
        } else {
            flowIdentifier = .init(identifier)
        }
    }

    public required init(parent: ParentProtocol, inbound: Bool, in eventContext: inout NetworkContext.EventContext) {
        self.parentProtocol = parent
        identifier = .init(eventManager: &self.eventManager, context: parent.context, in: &eventContext)
        identifier.setParentInstance(parent.identifier)
        if inbound {
            flowIdentifier = .init(inboundInstance: identifier)
        } else {
            flowIdentifier = .init(identifier)
        }
    }

    /// To be overridden by subclasses
    open func asLowerLinkage() -> UpperProtocol.PairedLowerLinkage {
        .init()
    }
}

@available(Network 0.1.0, *)
extension MultiplexingPath {
    internal func validate(
        lower lowerProtocol: InstanceIdentifier,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard !lowerProtocol.isNone else {
            Logger.proto.fault("Received \'\(label)\' from incorrect lower protocol")
            throw ProtocolInstanceError.invalidLowerProtocol
        }
        #endif
    }

    public var context: NetworkContext { parentProtocol.context }

    public mutating func attachLowerProtocol(
        _ lowerProtocol: LowerProtocol,
    ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage? {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        lower = lowerProtocol
        return nil
    }

    fileprivate func invokeConnect() {
        lower.invokeConnect(for: self.identifier, in: &context.eventContext)
    }

    fileprivate func invokeConnect(in eventContext: inout NetworkContext.EventContext) {
        lower.invokeConnect(for: self.identifier, in: &eventContext)
    }

    fileprivate func invokeDisconnect(error: NetworkError?) {
        lower.invokeDisconnect(error: error, for: self.identifier, in: &context.eventContext)
    }

    fileprivate func invokeDetach() {
        try? lower.invokeDetach(for: self.identifier, in: &context.eventContext)
    }

    fileprivate func invokeDetach(in eventContext: inout NetworkContext.EventContext) {
        try? lower.invokeDetach(for: self.identifier, in: &eventContext)
    }

    /// Detaches the lower protocol and releases this path's own event state.
    public mutating func destroy(in eventContext: inout NetworkContext.EventContext) {
        invokeDetach(in: &eventContext)
        unregisterEventManager(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension MultiplexingPath {
    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        if parentProtocol.canCallConnect(requested: false, in: &eventContext) {
            parentProtocol.connect(in: &eventContext)
        }
        parentProtocol.handleConnectedEvent(path: pathIdentifier, in: &eventContext)
        parentProtocol.handlePathChanged(
            path: pathIdentifier,
            event: .established,
            isPrimary: pathIsPrimary,
            in: &eventContext
        )
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        parentProtocol.handlePathChanged(path: pathIdentifier, event: .unavailable, isPrimary: false, in: &eventContext)
        parentProtocol.handleDisconnectedEvent(path: pathIdentifier, error: error, in: &eventContext)
    }

    public mutating func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate lower, can pass through
        if case .pathPrimaryChanged(let primary) = event.internalEvent {
            if primary && !pathIsPrimary {
                var parent = parentProtocol
                parent.resetPrimaryPath(newPrimary: pathIdentifier)
            } else if !primary {
                pathIsPrimary = false
            }
            let pathEvent: MultiplexingPathEvent =
                isConnected(in: &eventContext)
                ? .established : .available(local: nil, remote: nil, path: nil, parameters: nil)
            parentProtocol.handlePathChanged(
                path: pathIdentifier,
                event: pathEvent,
                isPrimary: pathIsPrimary,
                in: &eventContext
            )
            return
        }

        if parentProtocol.handleNetworkProtocolEvent(path: pathIdentifier, event: event, in: &eventContext) == .consumed
        {
            return
        }
        parentProtocol.applyToAllFlows { flow in
            flow.upper.deliverNetworkProtocolEvent(
                originalInstance: instance,
                selfInstance: flow.identifier,
                event: event,
                in: &eventContext
            )
        }
    }
}

@available(Network 0.1.0, *)
extension ManyToManyProtocolHandler {
    public func deliverNewInboundFlowEvent(
        _ flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        inboundFlowLinkage.deliverNewInboundFlowEvent(
            flowInstance: flowInstance,
            flowMetadata: flowMetadata,
            from: identifier,
            in: &eventContext
        )
    }

    public func invokeConnect(
        path pathID: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard let path = self.path(for: pathID) else { return }
        path.lower.invokeConnect(for: path.identifier, in: &eventContext)
    }

    public func invokeDisconnect(path pathID: MultiplexingPathIdentifier, error: NetworkError? = nil) {
        guard let path = self.path(for: pathID) else { return }
        path.lower.invokeDisconnect(error: error, for: path.identifier, in: &context.eventContext)
    }

    public func invokeEstablish(
        path pathID: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        invokeConnect(path: pathID, in: &eventContext)
    }

    public func deliverConnectedEvent(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverConnectedEvent(from: identifier, in: &eventContext)
            applyToAllFlows { flow in
                if flow.canCallConnect(requested: false, in: &eventContext) {
                    connect(flow: flow.flowIdentifier, in: &eventContext)
                }
            }
        default:
            guard let flow = self.flow(for: flowID) else { return }
            flow.deliverConnectedEvent(in: &eventContext)
        }
    }

    public func deliverDisconnectedEvent(
        flow flowID: MultiplexedFlowIdentifier,
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverDisconnectedEvent(error: error, from: identifier, in: &eventContext)
            applyToAllFlows { flow in
                flow.deliverDisconnectedEvent(error: error, in: &eventContext)
            }
        default:
            guard let flow = self.flow(for: flowID) else { return }
            flow.deliverDisconnectedEvent(error: error, in: &eventContext)
        }
    }

    public func deliverNetworkProtocolEvent(
        flow flowID: MultiplexedFlowIdentifier,
        event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverNetworkProtocolEvent(
                originalInstance: self.identifier,
                selfInstance: self.identifier,
                event: event,
                in: &eventContext
            )
            applyToAllFlows { flow in
                flow.upper.deliverNetworkProtocolEvent(
                    originalInstance: self.identifier,
                    selfInstance: flow.identifier,
                    event: event,
                    in: &eventContext
                )
            }
        default:
            guard let flow = self.flow(for: flowID) else { return }
            flow.upper.deliverNetworkProtocolEvent(
                originalInstance: flow.identifier,
                selfInstance: flow.identifier,
                event: event,
                in: &eventContext
            )
        }
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler {
    public func deliverConnectedEvent(
        flow flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverConnectedEvent(from: identifier, in: &eventContext)
            applyToAllFlows { flow in
                if flow.canCallConnect(requested: false, in: &eventContext) {
                    connect(flow: flow.flowIdentifier, in: &eventContext)
                }
            }
            applyToAllSecondaryFlows { flow in
                if flow.canCallConnect(requested: false, in: &eventContext) {
                    connect(flow: flow.flowIdentifier, in: &eventContext)
                }
            }
        default:
            if let flow = self.flow(for: flowID) {
                flow.deliverConnectedEvent(in: &eventContext)
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.deliverConnectedEvent(in: &eventContext)
            }
        }
    }

    public func deliverDisconnectedEvent(flow flowID: MultiplexedFlowIdentifier, error: NetworkError?) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverDisconnectedEvent(error: error, from: identifier, in: &context.eventContext)
            applyToAllFlows { flow in
                flow.deliverDisconnectedEvent(error: error)
            }
            applyToAllSecondaryFlows { flow in
                flow.deliverDisconnectedEvent(error: error)
            }
        default:
            if let flow = self.flow(for: flowID) {
                flow.deliverDisconnectedEvent(error: error)
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.deliverDisconnectedEvent(error: error)
            }
        }
    }

    public func deliverDisconnectedEvent(
        flow flowID: MultiplexedFlowIdentifier,
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverDisconnectedEvent(error: error, from: identifier, in: &eventContext)
            applyToAllFlows { flow in
                flow.deliverDisconnectedEvent(error: error, in: &eventContext)
            }
            applyToAllSecondaryFlows { flow in
                flow.deliverDisconnectedEvent(error: error, in: &eventContext)
            }
        default:
            if let flow = self.flow(for: flowID) {
                flow.deliverDisconnectedEvent(error: error, in: &eventContext)
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.deliverDisconnectedEvent(error: error, in: &eventContext)
            }
        }
    }

    /// Delivers a protocol event using an event context the caller already holds.
    public func deliverNetworkProtocolEvent(
        flow flowID: MultiplexedFlowIdentifier,
        event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverNetworkProtocolEvent(
                originalInstance: self.identifier,
                selfInstance: self.identifier,
                event: event,
                in: &eventContext
            )
            applyToAllFlows { flow in
                flow.upper.deliverNetworkProtocolEvent(
                    originalInstance: self.identifier,
                    selfInstance: flow.identifier,
                    event: event,
                    in: &eventContext
                )
            }
            applyToAllSecondaryFlows { flow in
                flow.upper.deliverNetworkProtocolEvent(
                    originalInstance: self.identifier,
                    selfInstance: flow.identifier,
                    event: event,
                    in: &eventContext
                )
            }
        default:
            if let flow = self.flow(for: flowID) {
                flow.upper.deliverNetworkProtocolEvent(
                    originalInstance: flow.identifier,
                    selfInstance: flow.identifier,
                    event: event,
                    in: &eventContext
                )
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.upper.deliverNetworkProtocolEvent(
                    originalInstance: flow.identifier,
                    selfInstance: flow.identifier,
                    event: event,
                    in: &eventContext
                )
            }
        }
    }
}

@available(Network 0.1.0, *)
extension ManyToManyOutboundDatagramProtocol where Path: AutomaticLowerDatagramProcessing {
    public mutating func resumeReadingInboundDatagrams(path pathID: MultiplexingPathIdentifier) {
        guard var path = self.path(for: pathID) else { return }
        path.resumeReadingInboundDatagrams(in: &context.eventContext)
    }

    public func getDatagramsToSend(
        path pathID: MultiplexingPathIdentifier,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        try fromExternal { eventContext throws(NetworkError) in
            try getDatagramsToSend(
                path: pathID,
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                in: &eventContext
            )
        }
    }

    /// Fetches datagrams to send using an event context the caller already holds.
    public func getDatagramsToSend(
        path pathID: MultiplexingPathIdentifier,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard let path = self.path(for: pathID) else { throw NetworkError.posix(EINVAL) }
        return try path.lower.invokeGetDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: path.identifier,
            in: &eventContext
        )
    }

    public func enqueueOutboundDatagrams(
        path pathID: MultiplexingPathIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var path = self.path(for: pathID) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        return try path.addToLowerSendQueue(datagrams)
    }

    public func sendEnqueuedOutboundDatagrams(path pathID: MultiplexingPathIdentifier) throws(NetworkError) {
        guard var path = self.path(for: pathID) else { throw NetworkError.posix(EINVAL) }
        path.serviceLowerSendQueue(in: &context.eventContext)
    }

    /// Services a path's send queue using an event context the caller already holds.
    public func sendEnqueuedOutboundDatagrams(
        path pathID: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard var path = self.path(for: pathID) else { throw NetworkError.posix(EINVAL) }
        path.serviceLowerSendQueue(in: &eventContext)
    }

    public func accessReceivedDatagrams(path pathID: MultiplexingPathIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var path = self.path(for: pathID) else {
            log.error("Unknown path for id: \(pathID)")
            return
        }
        body(&path.lowerReceiveQueue)
    }

    public func accessReceivedDatagrams(
        path pathID: MultiplexingPathIdentifier,
        _ body: (inout FrameArray, Path) -> Void
    ) {
        guard var path = self.path(for: pathID) else {
            log.error("Unknown path for id: \(pathID)")
            return
        }
        body(&path.lowerReceiveQueue, path)
    }

    public func sendAllEnqueuedOutboundDatagrams(in eventContext: inout NetworkContext.EventContext) {
        allPathIdentifiers { pathID in
            try? sendEnqueuedOutboundDatagrams(path: pathID, in: &eventContext)
        }
    }
}

@available(Network 0.1.0, *)
extension MultiplexingDatapathPath where Self: AutomaticLowerDatagramProcessing {
    public mutating func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        handleInboundDataAvailableEvent(in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        handleOutboundRoomAvailableEvent(in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
open class MultiplexingDatagramPath<
    ParentProtocol: ManyToManyOutboundDatagramProtocol,
    LinkageType: OutboundDatagramLinkage
>: MultiplexingDatapathPath,
    AutomaticLowerDatagramProcessing
{
    public typealias ParentProtocol = ParentProtocol
    public typealias LowerProtocol = LinkageType

    public var parentProtocol: ParentProtocol
    public var lower = LowerProtocol()
    public var eventManager = ProtocolEventManager()

    public let pathIdentifier = MultiplexingPathIdentifier()

    public var lowerSendQueue = FrameArray(capacity: 10)
    public var lowerReceiveQueue = FrameArray()

    public var pathIsPrimary: Bool = false
    public var pathHasMigrationInfo: Bool = false

    public var identifier: InstanceIdentifier

    public func serviceLowerReceiveQueue(in eventContext: inout NetworkContext.EventContext) {
        guard !lowerReceiveQueue.isEmpty else { return }
        parentProtocol.serviceReceivedDatagrams(path: pathIdentifier, in: &eventContext)
    }

    public func handleOutboundRoomAvailable(in eventContext: inout NetworkContext.EventContext) {
        parentProtocol.handleOutboundRoomAvailableEvent(path: pathIdentifier, in: &eventContext)
    }

    public required init(parent: ParentProtocol, in eventContext: inout NetworkContext.EventContext) {
        self.parentProtocol = parent
        identifier = .init(eventManager: &self.eventManager, context: parent.context, in: &eventContext)
        identifier.setParentInstance(parent.identifier)
    }

    /// To be overridden by subclasses
    open func asUpperLinkage() -> LowerProtocol.PairedUpperLinkage {
        .init()
    }
}
