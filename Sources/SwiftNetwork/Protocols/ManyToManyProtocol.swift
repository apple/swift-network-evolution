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
public protocol ManyToManyProtocolHandler: ListenerHandler, LoggableProtocol {
    associatedtype Flow: MultiplexedFlow
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
    func connect()
    func disconnect(error: NetworkError?)
    func teardown()
    func handleApplicationEvent(_ event: ApplicationEvent) -> HandleNetworkEventResult

    // MARK: Per-flow calls to implement
    func setup(
        flow: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
    func connect(flow: MultiplexedFlowIdentifier)
    func disconnect(flow: MultiplexedFlowIdentifier, error: NetworkError?)
    func teardown(flow: MultiplexedFlowIdentifier)
    func handleApplicationEvent(flow: MultiplexedFlowIdentifier, event: ApplicationEvent) -> HandleNetworkEventResult
    func getMetadata<P>(flow: MultiplexedFlowIdentifier) -> ProtocolMetadata<P>? where P: NetworkProtocol
    func updateDataTransferSnapshot(flow: MultiplexedFlowIdentifier, _ snapshot: inout DataTransferSnapshot)
    var protocolEstablishmentReport: ProtocolEstablishmentReport? { get }

    // MARK: Per-path events to implement
    func handleConnectedEvent(path: MultiplexingPathIdentifier)
    func handleDisconnectedEvent(path: MultiplexingPathIdentifier, error: NetworkError?)
    func handlePathChanged(path pathID: MultiplexingPathIdentifier, event: MultiplexingPathEvent, isPrimary: Bool)
    func handleNetworkProtocolEvent(
        path: MultiplexingPathIdentifier,
        event: NetworkProtocolEvent
    ) -> HandleNetworkEventResult

    #if !NETWORK_EMBEDDED
    mutating func attachLowerProtocolForNewPath(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
    #endif

    // MARK: Helper functions implemented by inheriting either HomogeneousManyToManyProtocolHandler or HeterogeneousManyToManyProtocolHandler
    mutating func performInitialSetupIfNeeded(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)
    func validate(
        inbound inboundProtocol: ProtocolInstanceReference,
        _ label: String
    ) throws(ProtocolInstanceError)
    mutating func teardownIfPossible()
}

/// Declares that a many-to-many protocol supports only a single type of flow.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol HomogeneousManyToManyProtocolHandler: ManyToManyProtocolHandler {
}

/// Allows a many-to-many protocol to support a secondary type of flow, for example, both stream flows and datagram flows.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol HeterogeneousManyToManyProtocolHandler: HeterogeneousListenerHandler, ManyToManyProtocolHandler {
    associatedtype SecondaryFlow: MultiplexedFlow
    var multiplexedSecondaryFlows: [MultiplexedFlowIdentifier: SecondaryFlow] { get set }
    var secondaryInboundFlowLinkage: SecondaryUpperProtocol { get set }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyDatapathProtocol: ManyToManyProtocolHandler
where Flow.UpperProtocol: InboundDataLinkage, Path.LowerProtocol: OutboundDataLinkage {
    func handleInboundDataAvailableEvent(path: MultiplexingPathIdentifier)
    func handleOutboundRoomAvailableEvent(path: MultiplexingPathIdentifier)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyApplicationStreamProtocol: ManyToManyDatapathProtocol {
    func serviceStreamDataToSend(flow: MultiplexedFlowIdentifier)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyApplicationDatagramProtocol: ManyToManyDatapathProtocol {
    func serviceDatagramsToSend(flow: MultiplexedFlowIdentifier)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ManyToManyOutboundDatagramProtocol: ManyToManyDatapathProtocol
where Path.LowerProtocol == OutboundDatagramLinkage {
    func serviceReceivedDatagrams(path: MultiplexingPathIdentifier)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
@frozen public enum MultiplexedFlowIdentifier: Hashable, CustomDebugStringConvertible {
    case allFlows
    case outboundFlow(index: Int)
    case inboundFlow(index: Int)

    init(_ reference: ProtocolInstanceReference) {
        guard let index = reference._protocolEventStateIndex else {
            self = .allFlows
            return
        }
        self = .outboundFlow(index: index.rawValue)
    }

    init(inboundReference: ProtocolInstanceReference) {
        guard let index = inboundReference._protocolEventStateIndex else {
            self = .allFlows
            return
        }
        self = .inboundFlow(index: index.rawValue)
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .allFlows:
            hasher.combine(0)
        case .outboundFlow(let index):
            hasher.combine(index)
        case .inboundFlow(let index):
            hasher.combine(index)
        }
    }

    public var debugDescription: String {
        switch self {
        case .allFlows: return "All Flows"
        #if !NETWORK_EMBEDDED
        case .outboundFlow(let index): return index.description
        case .inboundFlow(let index): return index.description
        #else
        case .outboundFlow: return "Outbound Flow"
        case .inboundFlow: return "Inbound Flow"
        #endif
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexedFlow: LowerProtocolHandler, LoggableProtocol {
    associatedtype ParentProtocol: ManyToManyProtocolHandler
    var upper: UpperProtocol { get set }
    var parentProtocol: ParentProtocol { get set }
    var identifier: MultiplexedFlowIdentifier { get }
    init(parent: ParentProtocol, inbound: Bool)
    var upperReceiveQueue: FrameArray { get set }
    var upperSendQueue: FrameArray { get set }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexedDatapathFlow: MultiplexedFlow
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
    case available
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
    var identifier: MultiplexingPathIdentifier { get }
    init(parent: ParentProtocol)
    var pathIsPrimary: Bool { get set }
    var pathHasMigrationInfo: Bool { get set }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol MultiplexingDatapathPath: MultiplexingPath
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

    public func teardown() {}

    public func connect() {}

    public func disconnect(error: NetworkError?) {}

    public func handleApplicationEvent(_ event: ApplicationEvent) -> HandleNetworkEventResult { .unconsumed }

    public func setup(
        flow: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {}

    public func connect(flow: MultiplexedFlowIdentifier) { deliverConnectedEvent(flow: flow) }

    public func disconnect(flow: MultiplexedFlowIdentifier, error: NetworkError?) {}
    public func teardown(flow: MultiplexedFlowIdentifier) {}
    public func handleApplicationEvent(
        flow: MultiplexedFlowIdentifier,
        event: ApplicationEvent
    ) -> HandleNetworkEventResult { .unconsumed }

    public func getMetadata<P>(flow: MultiplexedFlowIdentifier) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        nil
    }

    public func getMetadata<P>(_ from: ProtocolInstanceReference) -> ProtocolMetadata<P>? where P: NetworkProtocol {
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
        _ from: ProtocolInstanceReference,
        requestedNetworkMetric: RequestedNetworkMetrics
    ) -> NetworkMetrics? {
        getMetrics(flow: .allFlows, requestedNetworkMetric: requestedNetworkMetric)
    }

    public func handleInboundDataAvailableEvent(path: MultiplexingPathIdentifier) {}
    public func handleOutboundRoomAvailableEvent(path: MultiplexingPathIdentifier) {}

    public func handleConnectedEvent(path: MultiplexingPathIdentifier) {}
    public func handleDisconnectedEvent(path: MultiplexingPathIdentifier, error: NetworkError?) {}
    public func handlePathChanged(
        path pathID: MultiplexingPathIdentifier,
        event: MultiplexingPathEvent,
        isPrimary: Bool
    ) {}
    public func handleNetworkProtocolEvent(
        path: MultiplexingPathIdentifier,
        event: NetworkProtocolEvent
    ) -> HandleNetworkEventResult { .unconsumed }
}

@available(Network 0.1.0, *)
extension ManyToManyProtocolHandler {
    var asListener: UpperProtocol.PairedLinkage { .init(reference: reference) }

    #if !NETWORK_EMBEDDED
    public mutating func attachLowerProtocolForNewPath(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var newPath = Path(parent: self as! Self.Path.ParentProtocol)
        try newPath.attachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
        if multiplexingPaths.isEmpty { newPath.pathIsPrimary = true }
        multiplexingPaths[newPath.identifier] = newPath
        handlePathChanged(path: newPath.identifier, event: .available, isPrimary: newPath.pathIsPrimary)
    }
    #endif

    fileprivate func connectInternal() {
        if somePathIsConnected {
            if canCallConnect(requested: true) {
                connect()
            }
        } else {
            connectRequested()
            applyToAllPaths { $0.invokeConnect() }
        }
    }

    public func connect(_ from: ProtocolInstanceReference) {
        do { try validate(inbound: from, #function) } catch { return }
        connectInternal()
    }

    public func disconnect(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(inbound: from, #function) } catch { return }
        if canCallDisconnect {
            disconnect(error: error)
        }
    }

    public func flow(for flowID: MultiplexedFlowIdentifier) -> Flow? {
        multiplexedFlows[flowID]
    }

    public var someFlow: Flow? {
        multiplexedFlows.first?.value
    }

    public var someFlowIdentifier: MultiplexedFlowIdentifier? {
        multiplexedFlows.first?.value.identifier
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
        multiplexingPaths.first?.value.identifier
    }

    public func allPathIdentifiers(_ closure: (MultiplexingPathIdentifier) -> Void) {
        multiplexingPaths.keys.forEach(closure)
    }

    public func applyToAllPaths(_ closure: (Path) -> Void) {
        multiplexingPaths.values.forEach(closure)
    }

    public var somePathIsConnected: Bool {
        for path in multiplexingPaths.values {
            if path.lower.isConnected {
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

    public func handleApplicationEvent(_ from: ProtocolInstanceReference, event: ApplicationEvent) {
        // Don't validate upper, can pass through
        if self.handleApplicationEvent(event) == .consumed { return }
        applyToAllPaths { path in
            path.lower.invokeApplicationEvent(from, event: event)
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

    #if !NETWORK_EMBEDDED
    public mutating func attachUpperProtocol<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        guard Linkage.self == UpperProtocol.PairedLinkage.self else {
            throw NetworkError.posix(ENOTSUP)
        }
        guard inboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.inboundFlowLinkage = UpperProtocol(reference: from)

        return asListener as! Linkage
    }

    public mutating func attachUpperProtocolToNewFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        guard Linkage.self == UpperProtocol.DataLinkage.self else {
            throw NetworkError.posix(ENOTSUP)
        }
        let flowID = MultiplexedFlowIdentifier(from)
        let existingFlow = flow(for: flowID)
        guard existingFlow == nil else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = Flow(parent: self as! Flow.ParentProtocol, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        multiplexedFlows[flowID] = newFlow
        do {
            return try newFlow.attachUpperProtocol(
                from,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            multiplexedFlows[flowID] = nil
            throw error
        }
    }

    public mutating func attachUpperProtocolToExistingFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> Linkage {
        guard Linkage.self == UpperProtocol.DataLinkage.self else {
            throw NetworkError.posix(ENOTSUP)
        }

        let flowID = MultiplexedFlowIdentifier(inboundReference: flowReference)
        guard var existingFlow = flow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = .init(reference: from)
        return existingFlow.asLower as! Linkage
    }
    #endif

    public func validate(
        inbound inboundProtocol: ProtocolInstanceReference,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard inboundProtocol == inboundFlowLinkage.reference else {
            Logger.proto.fault("Received \'\(label)\' from incorrect inbound flow protocol")
            throw ProtocolInstanceError.invalidNewFlowLinkage
        }
        #endif
    }

    fileprivate var hasNoUpperLinkages: Bool {
        multiplexedFlows.isEmpty && inboundFlowLinkage.isDetached
    }

    public mutating func teardownIfPossible() {
        guard hasNoUpperLinkages else {
            // Still has some flow
            return
        }
        teardown()
        applyToAllPaths { $0.invokeDetach() }
        multiplexingPaths.removeAll()
    }

    public mutating func detach(_ from: ProtocolInstanceReference) throws(NetworkError) {
        do { try validate(inbound: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        inboundFlowLinkage = .init(reference: .init())
        teardownIfPossible()
    }

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters, for flowID: MultiplexedFlowIdentifier) -> ProtocolOptions<T>?
    {
        if case .allFlows = flowID {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: reference) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.reference)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: flow.reference) {
                return options
            }
        }
        return parameters.protocolOptions(for: reference)
    }
    public func getOptions(
        from parameters: Parameters,
        for flowID: MultiplexedFlowIdentifier
    ) -> AbstractProtocolOptions? {
        if case .allFlows = flowID {
            if let options = parameters.protocolOptions(for: reference) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.reference)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options = parameters.protocolOptions(for: flow.reference) {
                return options
            }
        }
        return parameters.protocolOptions(for: reference)
    }
    #endif
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler {
    fileprivate var hasNoUpperLinkages: Bool {
        multiplexedFlows.isEmpty && multiplexedSecondaryFlows.isEmpty && inboundFlowLinkage.isDetached
    }

    public mutating func teardownIfPossible() {
        guard hasNoUpperLinkages else {
            // Still has some flow
            return
        }
        teardown()
        applyToAllPaths { $0.invokeDetach() }
        multiplexingPaths.removeAll()
    }

    public mutating func detach(_ from: ProtocolInstanceReference) throws(NetworkError) {
        do { try validate(inbound: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        inboundFlowLinkage = .init(reference: .init())
        teardownIfPossible()
    }

    public func validate(
        inbound inboundProtocol: ProtocolInstanceReference,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard
            inboundProtocol == inboundFlowLinkage.reference || inboundProtocol == secondaryInboundFlowLinkage.reference
        else {
            Logger.proto.fault("Received \'\(label)\' from incorrect inbound flow protocol")
            throw ProtocolInstanceError.invalidNewFlowLinkage
        }
        #endif
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler {
    var asSecondaryListener: SecondaryUpperProtocol.PairedLinkage { .init(reference: reference) }

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

    #if !NETWORK_EMBEDDED
    public mutating func attachUpperProtocol<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        if Linkage.self == UpperProtocol.PairedLinkage.self {
            guard inboundFlowLinkage.isDetached else {
                throw NetworkError.posix(EALREADY)
            }

            try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

            self.inboundFlowLinkage = UpperProtocol(reference: from)
            return asListener as! Linkage
        } else if Linkage.self == SecondaryUpperProtocol.PairedLinkage.self {
            guard secondaryInboundFlowLinkage.isDetached else {
                throw NetworkError.posix(EALREADY)
            }

            try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

            self.secondaryInboundFlowLinkage = SecondaryUpperProtocol(reference: from)
            return asSecondaryListener as! Linkage
        } else {
            throw NetworkError.posix(ENOTSUP)
        }
    }

    public mutating func attachUpperProtocolToNewFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage where Flow.ParentProtocol == Self, SecondaryFlow.ParentProtocol == Self {
        if Linkage.self == UpperProtocol.DataLinkage.self {
            let flowID = MultiplexedFlowIdentifier(from)
            let existingFlow = flow(for: flowID)
            guard existingFlow == nil else {
                throw NetworkError.posix(EALREADY)
            }

            try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

            var newFlow = Flow(parent: self, inbound: false)
            newFlow.log.logPrefix = self.log.logPrefix
            multiplexedFlows[flowID] = newFlow
            do {
                return try newFlow.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            } catch {
                multiplexedFlows[flowID] = nil
                throw error
            }
        } else if Linkage.self == SecondaryUpperProtocol.DataLinkage.self {
            let flowID = MultiplexedFlowIdentifier(from)
            let existingFlow = secondaryFlow(for: flowID)
            guard existingFlow == nil else {
                throw NetworkError.posix(EALREADY)
            }

            try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

            var newFlow = SecondaryFlow(parent: self, inbound: false)
            newFlow.log.logPrefix = self.log.logPrefix
            multiplexedSecondaryFlows[flowID] = newFlow
            do {
                return try newFlow.attachUpperProtocol(
                    from,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            } catch {
                multiplexedSecondaryFlows[flowID] = nil
                throw error
            }
        } else {
            throw NetworkError.posix(ENOTSUP)
        }
    }
    #endif

    public mutating func addInboundSecondaryFlow() throws(NetworkError) -> MultiplexedFlowIdentifier
    where
        SecondaryFlow.ParentProtocol == Self,
        SecondaryUpperProtocol.DataLinkage.PairedLinkage == SecondaryFlow.UpperProtocol,
        SecondaryUpperProtocol.DataLinkage == SecondaryFlow.UpperProtocol.PairedLinkage
    {

        let newFlow = SecondaryFlow(parent: self, inbound: true)
        multiplexedSecondaryFlows[newFlow.identifier] = newFlow
        deliverNewInboundFlowEvent(newFlow.reference, flowMetadata: nil)

        return newFlow.identifier
    }

    public func deliverNewInboundSecondaryFlowEvent(_ flowReference: ProtocolInstanceReference) {
        secondaryInboundFlowLinkage.deliverNewInboundFlowEvent(
            reference,
            flowReference: flowReference,
            flowMetadata: nil
        )
    }

    #if !NETWORK_EMBEDDED
    public mutating func attachUpperProtocolToExistingFlow<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> Linkage {
        if Linkage.self == UpperProtocol.DataLinkage.self {
            let flowID = MultiplexedFlowIdentifier(inboundReference: flowReference)
            guard var existingFlow = flow(for: flowID) else {
                throw NetworkError.posix(ENOENT)
            }
            existingFlow.upper = .init(reference: from)
            return existingFlow.asLower as! Linkage
        } else if Linkage.self == SecondaryUpperProtocol.DataLinkage.self {
            let flowID = MultiplexedFlowIdentifier(inboundReference: flowReference)
            guard var existingFlow = secondaryFlow(for: flowID) else {
                throw NetworkError.posix(ENOENT)
            }
            existingFlow.upper = .init(reference: from)
            return existingFlow.asLower as! Linkage
        } else {
            throw NetworkError.posix(ENOTSUP)
        }
    }
    #endif

    public func secondaryFlow(for flowID: MultiplexedFlowIdentifier) -> SecondaryFlow? {
        multiplexedSecondaryFlows[flowID]
    }

    public var someSecondaryFlow: SecondaryFlow? {
        multiplexedSecondaryFlows.first?.value
    }

    public var someSecondaryFlowIdentifier: MultiplexedFlowIdentifier? {
        multiplexedSecondaryFlows.first?.value.identifier
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
            if let options = parameters.quicOptions(for: reference) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.quicOptions(for: someFlow.reference)
            }
            if let someFlow = someSecondaryFlow {
                return parameters.quicOptions(for: someFlow.reference)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options = parameters.quicOptions(for: flow.reference) {
                return options
            }
        }
        if let flow = secondaryFlow(for: flowID) {
            if let options = parameters.quicOptions(for: flow.reference) {
                return options
            }
        }
        return parameters.quicOptions(for: reference)
    }
    #endif

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters, for flowID: MultiplexedFlowIdentifier) -> ProtocolOptions<T>?
    {
        if case .allFlows = flowID {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: reference) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.reference)
            }
            if let someFlow = someSecondaryFlow {
                return parameters.protocolOptions(for: someFlow.reference)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: flow.reference) {
                return options
            }
        }
        if let flow = secondaryFlow(for: flowID) {
            if let options: ProtocolOptions<T> = parameters.protocolOptions(for: flow.reference) {
                return options
            }
        }
        return parameters.protocolOptions(for: reference)
    }
    public func getOptions(
        from parameters: Parameters,
        for flowID: MultiplexedFlowIdentifier
    ) -> AbstractProtocolOptions? {
        if case .allFlows = flowID {
            if let options = parameters.protocolOptions(for: reference) {
                return options
            }
            if let someFlow = someFlow {
                return parameters.protocolOptions(for: someFlow.reference)
            }
            if let someFlow = someSecondaryFlow {
                return parameters.protocolOptions(for: someFlow.reference)
            }
            return nil
        }
        if let flow = flow(for: flowID) {
            if let options = parameters.protocolOptions(for: flow.reference) {
                return options
            }
        }
        if let flow = secondaryFlow(for: flowID) {
            if let options = parameters.protocolOptions(for: flow.reference) {
                return options
            }
        }
        return parameters.protocolOptions(for: reference)
    }
    #endif
}

@available(Network 0.1.0, *)
extension ManyToManyDatapathProtocol where Path.ParentProtocol == Self, Path: InboundDatagramHandler {
    public mutating func attachLowerDatagramProtocolForNewPath(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var newPath = Path(parent: self)
        try newPath.attachLowerDatagramProtocol(
            lowerProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
        let isFirstPath = multiplexingPaths.isEmpty
        if isFirstPath { newPath.pathIsPrimary = true }
        if path?.hasMigrationInfo == true { newPath.pathHasMigrationInfo = true }
        multiplexingPaths[newPath.identifier] = newPath
        if !isFirstPath {
            handlePathChanged(path: newPath.identifier, event: .available, isPrimary: newPath.pathIsPrimary)
        }
    }
}

@available(Network 0.1.0, *)
extension ManyToManyDatapathProtocol where Flow.ParentProtocol == Self, Flow: OutboundStreamHandler {
    public mutating func attachNewStreamFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> UpperProtocol.PairedLinkage {
        guard inboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.inboundFlowLinkage = UpperProtocol(reference: from)
        return asListener
    }

    public mutating func attachUpperStreamProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage {
        let flowID = MultiplexedFlowIdentifier(from)
        let existingFlow = flow(for: flowID)
        guard existingFlow == nil else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = Flow(parent: self, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        multiplexedFlows[flowID] = newFlow
        do {
            return try newFlow.attachUpperStreamProtocol(
                from,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            multiplexedFlows[flowID] = nil
            throw error
        }
    }

    public mutating func attachUpperStreamProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundStreamLinkage {
        let flowID = MultiplexedFlowIdentifier(inboundReference: flowReference)
        guard var existingFlow = flow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = .init(reference: from)
        return existingFlow.asLower
    }
}

@available(Network 0.1.0, *)
extension ManyToManyDatapathProtocol where Flow.ParentProtocol == Self, Flow: OutboundDatagramHandler {
    public mutating func attachNewDatagramFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> UpperProtocol.PairedLinkage {
        guard inboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.inboundFlowLinkage = UpperProtocol(reference: from)
        return asListener
    }

    public mutating func attachUpperDatagramProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        let flowID = MultiplexedFlowIdentifier(from)
        let existingFlow = flow(for: flowID)
        guard existingFlow == nil else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = Flow(parent: self, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        multiplexedFlows[flowID] = newFlow
        do {
            return try newFlow.attachUpperDatagramProtocol(
                from,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            multiplexedFlows[flowID] = nil
            throw error
        }
    }

    public mutating func attachUpperDatagramProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        let flowID = MultiplexedFlowIdentifier(inboundReference: flowReference)
        guard var existingFlow = flow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = .init(reference: from)
        return existingFlow.asLower
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler
where SecondaryFlow.ParentProtocol == Self, SecondaryFlow: OutboundDatagramHandler {
    public mutating func attachNewDatagramFlowProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> SecondaryUpperProtocol.PairedLinkage {
        guard secondaryInboundFlowLinkage.isDetached else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        self.secondaryInboundFlowLinkage = SecondaryUpperProtocol(reference: from)
        return asSecondaryListener
    }

    public mutating func attachUpperDatagramProtocolToNewFlow(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        let flowID = MultiplexedFlowIdentifier(from)
        let existingFlow = secondaryFlow(for: flowID)
        guard existingFlow == nil else {
            throw NetworkError.posix(EALREADY)
        }

        try performInitialSetupIfNeeded(remote: remote, local: local, parameters: parameters, path: path)

        var newFlow = SecondaryFlow(parent: self, inbound: false)
        newFlow.log.logPrefix = self.log.logPrefix
        multiplexedSecondaryFlows[flowID] = newFlow
        do {
            return try newFlow.attachUpperDatagramProtocol(
                from,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            multiplexedSecondaryFlows[flowID] = nil
            throw error
        }
    }

    public mutating func attachUpperDatagramProtocolToExistingFlow(
        _ from: ProtocolInstanceReference,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        let flowID = MultiplexedFlowIdentifier(inboundReference: flowReference)
        guard var existingFlow = secondaryFlow(for: flowID) else {
            throw NetworkError.posix(ENOENT)
        }
        existingFlow.upper = .init(reference: from)
        return existingFlow.asLower
    }
}

@available(Network 0.1.0, *)
extension MultiplexedFlow {
    var asLower: UpperProtocol.PairedLinkage { .init(reference: reference) }

    internal func validate(
        upper upperProtocol: ProtocolInstanceReference,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard upperProtocol == upper.reference else {
            Logger.proto.fault("Received \'\(label)\' from incorrect upper protocol")
            throw ProtocolInstanceError.invalidUpperProtocol
        }
        #endif
    }

    public var context: NetworkContext { parentProtocol.context }

    #if !NETWORK_EMBEDDED
    public mutating func attachUpperProtocol<Linkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        guard Linkage.self == UpperProtocol.PairedLinkage.self else {
            throw NetworkError.posix(ENOTSUP)
        }
        upper = UpperProtocol(reference: from)

        do {
            try parentProtocol.setup(flow: identifier, remote: remote, local: local, parameters: parameters, path: path)
        } catch let error {
            upper = .init(reference: .init())
            throw error
        }

        return asLower as! Linkage
    }
    #endif

    public mutating func detach(_ from: ProtocolInstanceReference) throws(NetworkError) {
        do { try validate(upper: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        parentProtocol.teardown(flow: identifier)
        parentProtocol.multiplexedFlows.removeValue(forKey: identifier)
        upper = UpperProtocol(reference: .init())
        self.reference.discardPendingEventsForUpperProtocol()
        upperReceiveQueue.finalizeAllFramesAsFailed()
        upperSendQueue.finalizeAllFramesAsFailed()
        parentProtocol.teardownIfPossible()
    }

    public func connect(_ from: ProtocolInstanceReference) {
        do { try validate(upper: from, #function) } catch { return }
        if parentProtocol.isConnected {
            if canCallConnect(requested: true) {
                parentProtocol.connect(flow: identifier)
            }
        } else {
            connectRequested()
            parentProtocol.connectInternal()
        }
    }

    public func disconnect(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(upper: from, #function) } catch { return }
        if canCallDisconnect {
            parentProtocol.disconnect(flow: identifier, error: error)
        }
    }

    public func handleApplicationEvent(_ from: ProtocolInstanceReference, event: ApplicationEvent) {
        // Don't validate upper, can pass through
        if parentProtocol.handleApplicationEvent(flow: identifier, event: event) == .consumed { return }
        parentProtocol.applyToAllPaths { path in
            path.lower.invokeApplicationEvent(from, event: event)
        }
    }

    public func getMetadata<P>(_ from: ProtocolInstanceReference) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        do { try validate(upper: from, #function) } catch { return nil }
        return parentProtocol.getMetadata(flow: identifier)
    }

    public func getMetrics(
        _ from: ProtocolInstanceReference,
        requestedNetworkMetric: RequestedNetworkMetrics
    ) -> NetworkMetrics? {
        do { try validate(upper: from, #function) } catch { return nil }
        return parentProtocol.getMetrics(flow: identifier, requestedNetworkMetric: requestedNetworkMetric)
    }

    fileprivate func deliverConnectedEvent() {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfReference = self.reference
            selfReference.enqueuePendingEventForUpperProtocol(event: .connected(selfReference, upper.reference))
        } else {
            // Deliver connected event *followed by* any events which were buffered while detached
            upper.deliverConnectedEvent(self.reference)
            self.reference.reassignQueuedPendingEventsForUpperProtocol(to: upper.reference)
        }
    }

    fileprivate func deliverDisconnectedEvent(error: NetworkError?) {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfReference = self.reference
            selfReference.enqueuePendingEventForUpperProtocol(
                event: .disconnected(selfReference, upper.reference, error: error)
            )
        } else {
            upper.deliverDisconnectedEvent(self.reference, error: error)
        }
    }

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters) -> ProtocolOptions<T>? {
        parameters.protocolOptions(for: reference)
    }
    public func getOptions(from parameters: Parameters) -> AbstractProtocolOptions? {
        parameters.protocolOptions(for: reference)
    }
    #endif
}

@available(Network 0.1.0, *)
extension MultiplexedFlow where ParentProtocol: HeterogeneousManyToManyProtocolHandler {
    public mutating func detach(_ from: ProtocolInstanceReference) throws(NetworkError) {
        do { try validate(upper: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        parentProtocol.teardown(flow: identifier)
        parentProtocol.multiplexedFlows.removeValue(forKey: identifier)
        parentProtocol.multiplexedSecondaryFlows.removeValue(forKey: identifier)
        upper = UpperProtocol(reference: .init())
        self.reference.discardPendingEventsForUpperProtocol()
        upperReceiveQueue.finalizeAllFramesAsFailed()
        upperSendQueue.finalizeAllFramesAsFailed()
        parentProtocol.teardownIfPossible()
    }
}

@available(Network 0.1.0, *)
extension MultiplexedDatapathFlow where Self: AutomaticUpperStreamProcessing {
    public mutating func receiveStreamData(
        _ from: ProtocolInstanceReference,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        return try receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes)
    }

    public func getOutboundStreamDataRoomAvailable(_ from: ProtocolInstanceReference) throws(NetworkError) -> Int {
        do { try validate(upper: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected else { throw NetworkError.posix(ENOTCONN) }
        return try getOutboundStreamDataRoomAvailable()
    }

    public mutating func sendStreamData(
        _ from: ProtocolInstanceReference,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        do { try validate(upper: from, #function) } catch {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        guard isConnected else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try sendStreamData(streamData)
    }
}

@available(Network 0.1.0, *)
extension MultiplexedDatapathFlow where Self: AutomaticUpperStreamProcessing, Self: OutboundStreamEarlyDataHandler {
    public mutating func sendEarlyStreamData(
        _ from: ProtocolInstanceReference,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        do { try validate(upper: from, #function) } catch {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        try sendEarlyStreamData(streamData)
    }
}

@available(Network 0.1.0, *)
extension ManyToManyApplicationStreamProtocol where Flow: AutomaticUpperStreamProcessing {
    public func accessStreamDataToSend(flow flowID: MultiplexedFlowIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var flow = self.flow(for: flowID) else { return }
        body(&flow.upperSendQueue)
    }

    public func blockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = true
    }

    public func unblockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = false
        flow.upper.deliverOutboundRoomAvailableEvent(flow.reference)
    }

    public func enqueueInboundStreamData(
        flow flowID: MultiplexedFlowIdentifier,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        return try flow.addToUpperReceiveQueue(streamData)
    }

    public func deliverEnqueuedInboundStreamData(flow flowID: MultiplexedFlowIdentifier) throws(NetworkError) {
        guard let flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        flow.serviceUpperReceiveQueue()
    }
    // Enqueue and delivery the stream data all in one shot
    public func deliverInboundStreamData(
        flow flowID: MultiplexedFlowIdentifier,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        try deliverInboundStreamData(flow: &flow, streamData: streamData)
    }

    // Enqueue and deliver the stream data directly to the flow
    public func deliverInboundStreamData(
        flow existingFlow: inout Flow,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        try existingFlow.addToUpperReceiveQueue(streamData)
        existingFlow.serviceUpperReceiveQueue()
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
open class MultiplexedStreamFlow<ParentProtocol: ManyToManyApplicationStreamProtocol>: MultiplexedDatapathFlow,
    AutomaticUpperStreamProcessing, ProtocolInstanceContainer
{
    public typealias ParentProtocol = ParentProtocol
    public typealias UpperProtocol = InboundStreamLinkage

    public var parentProtocol: ParentProtocol
    public var upper = UpperProtocol()
    public var eventManager = ProtocolEventManager()

    public var upperSendQueue = FrameArray()
    public var upperReceiveQueue = FrameArray()
    public var maximumStreamDataSize: Int = Int.max
    public var blockUpperSendQueue: Bool = false

    public var log = NetworkLoggerState()

    fileprivate var _identifier: MultiplexedFlowIdentifier?
    public var identifier: MultiplexedFlowIdentifier {
        if let _identifier { return _identifier }
        return .init(upper.reference)
    }

    @_optimize(speed)
    public var reference: ProtocolInstanceReference {
        var reference = ProtocolInstanceReference(custom: self)
        reference.parentReference = parentProtocol.reference
        return reference
    }

    public func serviceUpperSendQueue() {
        parentProtocol.serviceStreamDataToSend(flow: identifier)
    }

    public required init(parent: ParentProtocol, inbound: Bool) {
        self.parentProtocol = parent
        self._identifier = nil

        if inbound {
            self._identifier = .init(inboundReference: reference)
        }
    }

    public func attachUpperStreamProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage {
        upper = UpperProtocol(reference: from)

        do {
            try parentProtocol.setup(flow: identifier, remote: remote, local: local, parameters: parameters, path: path)
        } catch let error {
            upper = .init(reference: .init())
            throw error
        }

        return asLower
    }

    public func upperReceiveQueueDrainedBytes(_ bytes: Int) {
        // No-op by default
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol UnidirectionalAbortingStreamFlow: MultiplexedDatapathFlow, OutboundStreamUnidirectionalAbortHandler {
    func abortInbound(error: NetworkError?)
    func abortOutbound(error: NetworkError?)
}

@available(Network 0.1.0, *)
extension UnidirectionalAbortingStreamFlow {
    public func deliverInboundAbortedEvent(error: NetworkError?) {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfReference = self.reference
            selfReference.enqueuePendingEventForUpperProtocol(
                event: .inboundAborted(selfReference, upper.reference, error: error)
            )
        } else {
            upper.deliverInboundAbortedEvent(self.reference, error: error)
        }
    }

    public func deliverOutboundAbortedEvent(error: NetworkError?) {
        if upper.isDetached {
            // Enqueue pending event instead of delivering immediately.
            // Inbound multiplexed flows may get attached after creation.
            let selfReference = self.reference
            selfReference.enqueuePendingEventForUpperProtocol(
                event: .outboundAborted(selfReference, upper.reference, error: error)
            )
        } else {
            upper.deliverOutboundAbortedEvent(self.reference, error: error)
        }
    }

    public func abortInbound(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(upper: from, #function) } catch { return }
        guard isConnected else { return }
        abortInbound(error: error)
    }

    public func abortOutbound(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(upper: from, #function) } catch { return }
        guard isConnected else { return }
        abortOutbound(error: error)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol EarlyDataStreamFlow: MultiplexedDatapathFlow, OutboundStreamEarlyDataHandler {}

@available(Network 0.1.0, *)
extension MultiplexedDatapathFlow where Self: AutomaticUpperDatagramProcessing {
    public mutating func receiveDatagrams(
        _ from: ProtocolInstanceReference,
        maximumDatagramCount: Int
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected else { throw NetworkError.posix(ENOTCONN) }
        return try receiveDatagrams(maximumDatagramCount: maximumDatagramCount)
    }

    public func getDatagramsToSend(
        _ from: ProtocolInstanceReference,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: from, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected else { throw NetworkError.posix(ENOTCONN) }
        return try getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize
        )
    }

    public mutating func sendDatagrams(
        _ from: ProtocolInstanceReference,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        do { try validate(upper: from, #function) } catch {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        guard isConnected else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try sendDatagrams(datagrams)
    }
}

@available(Network 0.1.0, *)
extension ManyToManyApplicationDatagramProtocol where Flow: AutomaticUpperDatagramProcessing {
    public func accessDatagramsToSend(flow flowID: MultiplexedFlowIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var flow = self.flow(for: flowID) else { return }
        body(&flow.upperSendQueue)
    }

    public func blockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = true
    }

    public func unblockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.flow(for: flowID) else { return }
        flow.blockUpperSendQueue = false
        flow.upper.deliverOutboundRoomAvailableEvent(flow.reference)
    }

    public func enqueueInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        return try flow.addToUpperReceiveQueue(datagrams)
    }

    public func deliverEnqueuedInboundDatagrams(flow flowID: MultiplexedFlowIdentifier) throws(NetworkError) {
        guard let flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        flow.serviceUpperReceiveQueue()
    }

    // Enqueue and delivery the datagrams all in one shot
    public func deliverInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.flow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        try flow.addToUpperReceiveQueue(datagrams)
        flow.serviceUpperReceiveQueue()
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler where SecondaryFlow: AutomaticUpperDatagramProcessing {
    public func accessDatagramsToSend(flow flowID: MultiplexedFlowIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var flow = self.secondaryFlow(for: flowID) else { return }
        body(&flow.upperSendQueue)
    }

    public func blockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.secondaryFlow(for: flowID) else { return }
        flow.blockUpperSendQueue = true
    }

    public func unblockSending(flow flowID: MultiplexedFlowIdentifier) {
        guard var flow = self.secondaryFlow(for: flowID) else { return }
        flow.blockUpperSendQueue = false
        flow.upper.deliverOutboundRoomAvailableEvent(flow.reference)
    }

    public func enqueueInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.secondaryFlow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        return try flow.addToUpperReceiveQueue(datagrams)
    }

    public func deliverEnqueuedInboundDatagrams(flow flowID: MultiplexedFlowIdentifier) throws(NetworkError) {
        guard let flow = self.secondaryFlow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        flow.serviceUpperReceiveQueue()
    }

    // Enqueue and delivery the datagrams all in one shot
    public func deliverInboundDatagrams(
        flow flowID: MultiplexedFlowIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var flow = self.secondaryFlow(for: flowID) else { throw NetworkError.posix(EINVAL) }
        try deliverInboundDatagrams(flow: &flow, datagrams: datagrams)
    }

    // Enqueue and deliver the datagrams directly to the flow
    public func deliverInboundDatagrams(
        flow existingFlow: inout SecondaryFlow,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        try existingFlow.addToUpperReceiveQueue(datagrams)
        existingFlow.serviceUpperReceiveQueue()
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
open class MultiplexedDatagramFlow<ParentProtocol: ManyToManyApplicationDatagramProtocol>: MultiplexedDatapathFlow,
    AutomaticUpperDatagramProcessing, ProtocolInstanceContainer
{
    public typealias ParentProtocol = ParentProtocol
    public typealias UpperProtocol = InboundDatagramLinkage

    public var parentProtocol: ParentProtocol
    public var upper = UpperProtocol()
    public var eventManager = ProtocolEventManager()

    public var upperSendQueue = FrameArray()
    public var upperReceiveQueue = FrameArray()
    public var maximumUpperDatagramSize: Int = 0
    public var blockUpperSendQueue: Bool = false

    public var log = NetworkLoggerState()

    var _identifier: MultiplexedFlowIdentifier?
    public var identifier: MultiplexedFlowIdentifier {
        if let _identifier { return _identifier }
        return .init(upper.reference)
    }

    public var reference: ProtocolInstanceReference {
        var reference = ProtocolInstanceReference(custom: self)
        reference.parentReference = parentProtocol.reference
        return reference
    }

    public func serviceUpperSendQueue() {
        parentProtocol.serviceDatagramsToSend(flow: identifier)
    }

    public required init(parent: ParentProtocol, inbound: Bool) {
        self.parentProtocol = parent
        self._identifier = nil
        if inbound {
            self._identifier = .init(inboundReference: reference)
        }
    }

    public func attachUpperDatagramProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundDatagramLinkage {
        upper = UpperProtocol(reference: from)

        do {
            try parentProtocol.setup(flow: identifier, remote: remote, local: local, parameters: parameters, path: path)
        } catch let error {
            upper = .init(reference: .init())
            throw error
        }

        return asLower
    }
}

@available(Network 0.1.0, *)
extension MultiplexingPath {
    var asUpper: LowerProtocol.PairedLinkage { .init(reference: reference) }

    internal func validate(
        lower lowerProtocol: ProtocolInstanceReference,
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

    #if !NETWORK_EMBEDDED
    public mutating func attachLowerProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        self.lower = try lowerProtocol.attachUpperProtocol(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
    #endif

    fileprivate func invokeConnect() {
        lower.invokeConnect(self.reference)
    }

    fileprivate func invokeDisconnect(error: NetworkError?) {
        lower.invokeDisconnect(self.reference, error: error)
    }

    fileprivate func invokeDetach() {
        try? lower.invokeDetach(self.reference)
    }
}

@available(Network 0.1.0, *)
extension MultiplexingPath {
    public func handleConnectedEvent(_ from: ProtocolInstanceReference) {
        do { try validate(lower: from, #function) } catch { return }
        if parentProtocol.canCallConnect(requested: false) {
            parentProtocol.connect()
        }
        parentProtocol.handleConnectedEvent(path: identifier)
        parentProtocol.handlePathChanged(path: identifier, event: .established, isPrimary: pathIsPrimary)
    }

    public func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(lower: from, #function) } catch { return }
        parentProtocol.handlePathChanged(path: identifier, event: .unavailable, isPrimary: false)
        parentProtocol.handleDisconnectedEvent(path: identifier, error: error)
    }

    public mutating func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        // Don't validate lower, can pass through
        if case .pathPrimaryChanged(let primary) = event.internalEvent {
            if primary && !pathIsPrimary {
                var parent = parentProtocol
                parent.resetPrimaryPath(newPrimary: identifier)
            } else if !primary {
                pathIsPrimary = false
            }
            parentProtocol.handlePathChanged(
                path: identifier,
                event: isConnected ? .established : .available,
                isPrimary: pathIsPrimary
            )
            return
        }

        if parentProtocol.handleNetworkProtocolEvent(path: identifier, event: event) == .consumed { return }
        parentProtocol.applyToAllFlows { flow in
            flow.upper.deliverNetworkProtocolEvent(originalReference: from, selfReference: flow.reference, event: event)
        }
    }
}

@available(Network 0.1.0, *)
extension ManyToManyProtocolHandler {
    public func deliverNewInboundFlowEvent(
        _ flowReference: ProtocolInstanceReference,
        flowMetadata: AbstractProtocolMetadata?
    ) {
        inboundFlowLinkage.deliverNewInboundFlowEvent(
            reference,
            flowReference: flowReference,
            flowMetadata: flowMetadata
        )
    }

    public func invokeConnect(path pathID: MultiplexingPathIdentifier) {
        guard let path = self.path(for: pathID) else { return }
        path.lower.invokeConnect(path.reference)
    }

    public func invokeDisconnect(path pathID: MultiplexingPathIdentifier, error: NetworkError? = nil) {
        guard let path = self.path(for: pathID) else { return }
        path.lower.invokeDisconnect(path.reference, error: error)
    }

    public func invokeEstablish(path pathID: MultiplexingPathIdentifier) {
        invokeConnect(path: pathID)
    }

    public func deliverConnectedEvent(flow flowID: MultiplexedFlowIdentifier) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverConnectedEvent(reference)
            applyToAllFlows { flow in
                if flow.canCallConnect(requested: false) {
                    connect(flow: flow.identifier)
                }
            }
        case .outboundFlow, .inboundFlow:
            guard let flow = self.flow(for: flowID) else { return }
            flow.deliverConnectedEvent()
        }
    }

    public func deliverDisconnectedEvent(flow flowID: MultiplexedFlowIdentifier, error: NetworkError?) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverDisconnectedEvent(reference, error: error)
            applyToAllFlows { flow in
                flow.deliverDisconnectedEvent(error: error)
            }
        case .outboundFlow, .inboundFlow:
            guard let flow = self.flow(for: flowID) else { return }
            flow.deliverDisconnectedEvent(error: error)
        }
    }

    public func deliverNetworkProtocolEvent(flow flowID: MultiplexedFlowIdentifier, event: NetworkProtocolEvent) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverNetworkProtocolEvent(
                originalReference: self.reference,
                selfReference: self.reference,
                event: event
            )
            applyToAllFlows { flow in
                flow.upper.deliverNetworkProtocolEvent(
                    originalReference: self.reference,
                    selfReference: flow.reference,
                    event: event
                )
            }
        case .outboundFlow, .inboundFlow:
            guard let flow = self.flow(for: flowID) else { return }
            flow.upper.deliverNetworkProtocolEvent(
                originalReference: flow.reference,
                selfReference: flow.reference,
                event: event
            )
        }
    }
}

@available(Network 0.1.0, *)
extension HeterogeneousManyToManyProtocolHandler {
    public func deliverConnectedEvent(flow flowID: MultiplexedFlowIdentifier) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverConnectedEvent(reference)
            applyToAllFlows { flow in
                if flow.canCallConnect(requested: false) {
                    connect(flow: flow.identifier)
                }
            }
            applyToAllSecondaryFlows { flow in
                if flow.canCallConnect(requested: false) {
                    connect(flow: flow.identifier)
                }
            }
        case .outboundFlow, .inboundFlow:
            if let flow = self.flow(for: flowID) {
                flow.deliverConnectedEvent()
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.deliverConnectedEvent()
            }
        }
    }

    public func deliverDisconnectedEvent(flow flowID: MultiplexedFlowIdentifier, error: NetworkError?) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverDisconnectedEvent(reference, error: error)
            applyToAllFlows { flow in
                flow.deliverDisconnectedEvent(error: error)
            }
            applyToAllSecondaryFlows { flow in
                flow.deliverDisconnectedEvent(error: error)
            }
        case .outboundFlow, .inboundFlow:
            if let flow = self.flow(for: flowID) {
                flow.deliverDisconnectedEvent(error: error)
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.deliverDisconnectedEvent(error: error)
            }
        }
    }

    public func deliverNetworkProtocolEvent(flow flowID: MultiplexedFlowIdentifier, event: NetworkProtocolEvent) {
        switch flowID {
        case .allFlows:
            inboundFlowLinkage.deliverNetworkProtocolEvent(
                originalReference: self.reference,
                selfReference: self.reference,
                event: event
            )
            applyToAllFlows { flow in
                flow.upper.deliverNetworkProtocolEvent(
                    originalReference: self.reference,
                    selfReference: flow.reference,
                    event: event
                )
            }
            applyToAllSecondaryFlows { flow in
                flow.upper.deliverNetworkProtocolEvent(
                    originalReference: self.reference,
                    selfReference: flow.reference,
                    event: event
                )
            }
        case .outboundFlow, .inboundFlow:
            if let flow = self.flow(for: flowID) {
                flow.upper.deliverNetworkProtocolEvent(
                    originalReference: flow.reference,
                    selfReference: flow.reference,
                    event: event
                )
            }
            if let flow = self.secondaryFlow(for: flowID) {
                flow.upper.deliverNetworkProtocolEvent(
                    originalReference: flow.reference,
                    selfReference: flow.reference,
                    event: event
                )
            }
        }
    }
}

@available(Network 0.1.0, *)
extension ManyToManyOutboundDatagramProtocol where Path: AutomaticLowerDatagramProcessing {
    public mutating func resumeReadingInboundDatagrams(path pathID: MultiplexingPathIdentifier) {
        guard var path = self.path(for: pathID) else { return }
        path.resumeReadingInboundDatagrams()
    }

    @inline(__always)
    public func getDatagramsToSend(
        path pathID: MultiplexingPathIdentifier,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        guard let path = self.path(for: pathID) else { throw NetworkError.posix(EINVAL) }
        return try path.lower.invokeGetDatagramsToSend(
            path.reference,
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize
        )
    }

    public func enqueueOutboundDatagrams(
        path pathID: MultiplexingPathIdentifier,
        datagrams: consuming FrameArray
    ) throws(NetworkError) {
        guard var path = self.path(for: pathID) else { throw NetworkError.posix(EINVAL) }
        return try path.addToLowerSendQueue(datagrams)
    }

    public func sendEnqueuedOutboundDatagrams(path pathID: MultiplexingPathIdentifier) throws(NetworkError) {
        guard var path = self.path(for: pathID) else { throw NetworkError.posix(EINVAL) }
        path.serviceLowerSendQueue()
    }

    public func accessReceivedDatagrams(path pathID: MultiplexingPathIdentifier, _ body: (inout FrameArray) -> Void) {
        guard var path = self.path(for: pathID) else { return }
        body(&path.lowerReceiveQueue)
    }

    public func accessReceivedDatagrams(
        path pathID: MultiplexingPathIdentifier,
        _ body: (inout FrameArray, Path) -> Void
    ) {
        guard var path = self.path(for: pathID) else { return }
        body(&path.lowerReceiveQueue, path)
    }

    public func sendAllEnqueuedOutboundDatagrams() {
        allPathIdentifiers { pathID in
            try? sendEnqueuedOutboundDatagrams(path: pathID)
        }
    }
}

@available(Network 0.1.0, *)
extension MultiplexingDatapathPath where Self: AutomaticLowerDatagramProcessing {
    public mutating func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
        do { try validate(lower: from, #function) } catch { return }
        handleInboundDataAvailableEvent()
    }

    public mutating func handleOutboundRoomAvailableEvent(_ from: ProtocolInstanceReference) {
        do { try validate(lower: from, #function) } catch { return }
        handleOutboundRoomAvailableEvent()
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
open class MultiplexingDatagramPath<ParentProtocol: ManyToManyOutboundDatagramProtocol>: MultiplexingDatapathPath,
    AutomaticLowerDatagramProcessing, ProtocolInstanceContainer
{
    public typealias ParentProtocol = ParentProtocol
    public typealias LowerProtocol = OutboundDatagramLinkage

    public var parentProtocol: ParentProtocol
    public var lower = LowerProtocol()
    public var eventManager = ProtocolEventManager()

    public let identifier = MultiplexingPathIdentifier()

    public var lowerSendQueue = FrameArray()
    public var lowerReceiveQueue = FrameArray()

    public var pathIsPrimary: Bool = false
    public var pathHasMigrationInfo: Bool = false

    @_optimize(speed)
    public var reference: ProtocolInstanceReference {
        var reference = ProtocolInstanceReference(custom: self)
        reference.parentReference = parentProtocol.reference
        return reference
    }

    public func serviceLowerReceiveQueue() {
        guard !lowerReceiveQueue.isEmpty else { return }
        parentProtocol.serviceReceivedDatagrams(path: identifier)
    }

    public func handleOutboundRoomAvailable() {
        parentProtocol.handleOutboundRoomAvailableEvent(path: identifier)
    }

    public required init(parent: ParentProtocol) { self.parentProtocol = parent }

    public func attachLowerDatagramProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        self.lower = try lowerProtocol.attachUpperDatagramProtocol(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
}
