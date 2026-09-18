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

// MARK: - One-to-One Protocol Adoption

/// The most basic kind of protocol, with both an upper protocol and a lower protocol.
///
/// Conform to `OneToOneStreamProtocol`, `OneToOneDatagramProtocol`, or `OneToOneStreamToDatagramProtocol`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OneToOneProtocolHandler: ~Copyable, OutboundDataHandler, InboundDataHandler, LoggableProtocol {

    /// The type of upper protocol (toward the app) that you can attach.
    var upper: UpperProtocol { get set }

    /// The type of lower protocol (toward the network) that you can attach.
    var lower: LowerProtocol { get set }

    /// Sets up a protocol instance with parameters and endpoints.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    /// Tears down a protocol when detaching.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func teardown()

    /// Requests that this protocol initiate its handshake, if any.
    ///
    /// If not implemented, the protocol delivers the connected event automatically.
    /// Protocols can implement this function to customize behavior.
    mutating func connect(in eventContext: inout NetworkContext.EventContext)

    /// Requests that this protocol gracefully close.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when the lower protocol disconnects.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when a lower protocol sends an event.
    ///
    /// Returns `.consumed` if the event was handled and shouldn't pass up to
    /// upper protocols, and `.unconsumed` otherwise.
    /// Protocols can implement this function to customize behavior.
    mutating func handleNetworkProtocolEvent(
        _ event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult

    /// A function the framework calls when the app sends an event.
    ///
    /// Returns `.consumed` if the event was handled and shouldn't pass down to
    /// lower protocols, and `.unconsumed` otherwise.
    /// Protocols can implement this function to customize behavior.
    mutating func handleApplicationEvent(
        _ event: ApplicationEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult

    #if !NETWORK_EMBEDDED
    /// The metadata state for this protocol.
    var metadata: AbstractProtocolMetadata? { get }
    #endif

    /// A Boolean value that indicates whether this protocol passes events through without handling them directly.
    ///
    /// Protocols that don't handle events should initialize this to `true`.
    /// The stack may set this to `false` explicitly, after which you shouldn't set it back to `true`.
    var passthroughEvents: Bool { get set }

    /// Update this protocols data transfer snapshot.
    func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot)

    /// Fetch this protocols establishment report entry
    var protocolEstablishmentReport: ProtocolEstablishmentReport? { get }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum HandleNetworkEventResult {
    /// The protocol handled and consumed the event, and the system shouldn't automatically pass it on to the next protocol.
    case consumed

    /// The protocol didn't consume the event, and the system can automatically pass it on to the next protocol.
    case unconsumed
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable {
    /// Indicates to the upper protocol that this protocol is connected.
    ///
    /// Call this only if the protocol customizes `connect()`.
    public func deliverConnectedEvent(in eventContext: inout NetworkContext.EventContext) {
        upper.deliverConnectedEvent(from: self.identifier, in: &eventContext)
    }

    /// Indicates to the upper protocol that this protocol is disconnected, with an error.
    public func deliverDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        upper.deliverDisconnectedEvent(error: error, from: self.identifier, in: &eventContext)
    }

    /// Passes an event to the upper protocol.
    public func deliverNetworkProtocolEvent(_ event: NetworkProtocolEvent, in eventContext: inout NetworkContext.EventContext) {
        upper.deliverNetworkProtocolEvent(
            originalInstance: self.identifier,
            selfInstance: self.identifier,
            event: event,
            in: &eventContext
        )
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OneToOneDatapathProtocol: ~Copyable, OneToOneProtocolHandler
where UpperProtocol: InboundDataLinkage, LowerProtocol: OutboundDataLinkage {

    /// A function the framework calls when the lower protocol has inbound data available to read.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when the lower protocol has outbound room available to send.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func handleOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext)
}

/// One-to-one protocol with an upper stream linkage and a lower stream linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OneToOneStreamProtocol: ~Copyable, OneToOneDatapathProtocol
where UpperProtocol: InboundStreamLinkage, LowerProtocol: OutboundStreamLinkage {

    /// Returns received stream data to the upper protocol.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    /// Returns the number of bytes of stream data that can be written.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int

    /// Sends stream data created by the upper protocol.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func sendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)

    /// A function the framework calls when the lower protocol reports that the inbound direction of data is aborted.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func handleInboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when the lower protocol reports that the outbound direction of data is aborted.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func handleOutboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)
}

/// One-to-one protocol with an upper stream linkage and a lower datagram linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OneToOneStreamToDatagramProtocol: ~Copyable, OneToOneDatapathProtocol
where UpperProtocol: InboundStreamLinkage, LowerProtocol: OutboundDatagramLinkage {

    /// Returns received stream data to the upper protocol.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    /// Returns the number of bytes of stream data that can be written.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int

    /// Sends stream data created by the upper protocol.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func sendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

/// One-to-one protocol with an upper datagram linkage and a lower datagram linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OneToOneDatagramProtocol: ~Copyable, OneToOneDatapathProtocol
where UpperProtocol: InboundDatagramLinkage, LowerProtocol: OutboundDatagramLinkage {

    /// Returns received datagrams to the upper protocol.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    /// Returns datagram frames the upper protocol can use to send.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    /// Sends datagrams created by the upper protocol.
    ///
    /// Protocols can implement this function to customize behavior.
    mutating func sendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

/// One-to-one protocol with an upper datagram linkage and a lower stream linkage.
/// Used by tunnel protocols (e.g. MASQUE CONNECT-UDP) that encapsulate datagrams over a stream.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol OneToOneDatagramToStreamProtocol: ~Copyable, OneToOneDatapathProtocol
where UpperProtocol: InboundDatagramLinkage, LowerProtocol: OutboundStreamLinkage {

    mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    mutating func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    mutating func sendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)

    mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray?

    mutating func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int

    mutating func sendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError)
}

// MARK: - One-to-One Protocol Implementation Details

@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable {
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

    public func invokeConnect(in eventContext: inout NetworkContext.EventContext) {
        lower.invokeConnect(for: effectiveSelfInstance, in: &eventContext)
    }

    public func invokeDisconnect(error: NetworkError? = nil, in eventContext: inout NetworkContext.EventContext) {
        lower.invokeDisconnect(error: error, for: effectiveSelfInstance, in: &eventContext)
    }

    public mutating func attachLowerProtocol(
        _ lowerProtocol: LowerProtocol,
    ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage? {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        lower = lowerProtocol
        // Don't pass through events, linkages are not compatible
        passthroughEvents = false
        return nil
    }

    public mutating func attachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard upper.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        upper = upperProtocol

        #if !NETWORK_EMBEDDED
        if let parameters {
            if let options = getOptions(from: parameters) {
                self.log.logPrefix = options.logIDString ?? ""
            }
        }
        #endif

        do {
            try self.setup(remote: remote, local: local, parameters: parameters, path: path)
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
        let identifier = effectiveSelfInstance
        upper = .init()
        teardown()
        try lower.invokeDetach(for: identifier, in: &eventContext)
        lower = .init()
    }

    public mutating func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        do { try validate(upper: instance, #function) } catch { return }
        if lower.protocolIsConnected(in: &eventContext) {
            if canCallConnect(requested: true, in: &eventContext) {
                connect(in: &eventContext)
            }
        } else {
            connectRequested(in: &eventContext)
            invokeConnect(in: &eventContext)
        }
    }

    public mutating func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(upper: instance, #function) } catch { return }
        if canCallDisconnect(in: &eventContext) {
            disconnect(error: error, in: &eventContext)
        }
    }

    public mutating func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        if canCallConnect(requested: false, in: &eventContext) {
            connect(in: &eventContext)
        }
    }

    public mutating func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleDisconnectedEvent(error: error, in: &eventContext)
    }

    public mutating func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate lower, can pass through
        if self.handleNetworkProtocolEvent(event, in: &eventContext) == .consumed { return }
        upper.deliverNetworkProtocolEvent(
            originalInstance: instance,
            selfInstance: self.identifier,
            event: event,
            in: &eventContext
        )
    }

    public mutating func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate upper, can pass through
        if self.handleApplicationEvent(event, in: &eventContext) == .consumed { return }
        lower.invokeApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        do { try validate(upper: instance, #function) } catch { return nil }
        #if !NETWORK_EMBEDDED
        if let metadata = self.metadata as? ProtocolMetadata<P> {
            return metadata
        }
        return lower.invokeGetMetadata(for: effectiveSelfInstance, in: &eventContext)
        #else
        return nil
        #endif
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        do { try validate(upper: instance, #function) } catch { return nil }
        let lowerMetrics = lower.invokeGetMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: effectiveSelfInstance,
            in: &eventContext
        )
        switch requestedNetworkMetric {
        case .protocolEstablishmentReports:
            var reports = [ProtocolEstablishmentReport]()
            if case .protocolEstablishmentReports(let protocolEstablishmentReports) = lowerMetrics {
                reports = protocolEstablishmentReports
            }
            if let currentProtocolEstablishmentReport = protocolEstablishmentReport {
                reports.append(currentProtocolEstablishmentReport)
            }
            return .protocolEstablishmentReports(reports)
        case .dataTransferSnapshot:
            if case .dataTransferSnapshot(var snapshot) = lowerMetrics {
                updateDataTransferSnapshot(&snapshot)
                return .dataTransferSnapshot(snapshot)
            }
            var snapshot = DataTransferSnapshot()
            updateDataTransferSnapshot(&snapshot)
            return .dataTransferSnapshot(snapshot)
        }
    }

    public func tlsOptions(from parameters: Parameters) -> ProtocolOptions<SwiftTLSProtocol>? {
        parameters.tlsOptions(for: self.identifier)
    }
    public func udpOptions(from parameters: Parameters) -> ProtocolOptions<UDPProtocol>? {
        parameters.udpOptions(for: self.identifier)
    }
    public func ipOptions(from parameters: Parameters) -> ProtocolOptions<IPProtocol>? {
        parameters.ipOptions(for: self.identifier)
    }

    #if !NETWORK_EMBEDDED
    public func getOptions<T>(from parameters: Parameters) -> ProtocolOptions<T>? {
        parameters.protocolOptions(for: self.identifier)
    }
    public func getOptions(from parameters: Parameters) -> AbstractProtocolOptions? {
        parameters.protocolOptions(for: self.identifier)
    }
    #endif
}

@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable, UpperProtocol == LowerProtocol.PairedUpperLinkage {
    public mutating func attachLowerProtocol(
        _ lowerProtocol: LowerProtocol,
    ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage? {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        lower = lowerProtocol
        if upper.isDetached {
            // If the upper is detached at the time of attaching the lower, don't pass through events
            passthroughEvents = false
        }
        if passthroughEvents {
            return upper
        } else {
            return nil
        }
    }
}

// Default implementations, to be overridden as necessary
@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable {
    public mutating func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {}

    public mutating func teardown() {}

    public mutating func connect(in eventContext: inout NetworkContext.EventContext) {
        deliverConnectedEvent(in: &eventContext)
    }

    public mutating func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        invokeDisconnect(error: error, in: &eventContext)
    }

    public mutating func handleDisconnectedEvent(
        error: NetworkError?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        deliverDisconnectedEvent(error: error, in: &eventContext)
    }

    public mutating func handleNetworkProtocolEvent(
        _ event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult {
        .unconsumed
    }

    public mutating func handleApplicationEvent(
        _ event: ApplicationEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> HandleNetworkEventResult {
        .unconsumed
    }

    public func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot) {}

    public var protocolEstablishmentReport: ProtocolEstablishmentReport? { nil }
}

@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable {
    @usableFromInline
    var effectiveSelfInstance: InstanceIdentifier {
        if passthroughEvents {
            return upper.identifier
        } else {
            return self.identifier
        }
    }
}

@available(Network 0.1.0, *)
extension OneToOneDatapathProtocol where Self: ~Copyable {
    public mutating func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleInboundDataAvailableEvent(in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleOutboundRoomAvailableEvent(in: &eventContext)
    }

    public func deliverInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        guard passthroughEvents || isConnected(in: &eventContext) else { return }
        upper.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
    }

    public func deliverOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        guard passthroughEvents || isConnected(in: &eventContext) else { return }
        upper.deliverOutboundRoomAvailableEvent(from: self.identifier, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension OneToOneDatapathProtocol where Self: ~Copyable {
    // Default implementations, to be overridden as necessary
    public mutating func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        deliverInboundDataAvailableEvent(in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        deliverOutboundRoomAvailableEvent(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable, LowerProtocol: OutboundDatagramLinkage {
    public func invokeReceiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try lower.invokeReceiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: effectiveSelfInstance,
            in: &eventContext
        )
    }
    @inline(always)
    public func invokeGetDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try lower.invokeGetDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: effectiveSelfInstance,
            in: &eventContext
        )
    }

    public func invokeSendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try lower.invokeSendDatagrams(datagrams, from: effectiveSelfInstance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension OneToOneDatagramProtocol where Self: ~Copyable {
    public mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, in: &eventContext)
    }
    public mutating func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.getDatagramsToSend(
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
        guard passthroughEvents || isConnected(in: &eventContext) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try self.sendDatagrams(datagrams, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension OneToOneProtocolHandler where Self: ~Copyable, LowerProtocol: OutboundStreamLinkage {
    public mutating func invokeReceiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try lower.invokeReceiveStreamData(
            minimumBytes: minimumBytes,
            maximumBytes: maximumBytes,
            for: effectiveSelfInstance,
            in: &eventContext
        )
    }
    public mutating func invokeGetOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        try lower.invokeGetOutboundStreamDataRoomAvailable(for: effectiveSelfInstance, in: &eventContext)
    }
    public mutating func invokeSendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try lower.invokeSendStreamData(streamData, from: effectiveSelfInstance, in: &eventContext)
    }
    public mutating func invokeSendEarlyStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try lower.invokeSendEarlyStreamData(streamData, from: effectiveSelfInstance, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension OneToOneStreamToDatagramProtocol where Self: ~Copyable {
    public mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
    }
    public mutating func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.getOutboundStreamDataRoomAvailable(in: &eventContext)
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
        guard passthroughEvents || isConnected(in: &eventContext) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try self.sendStreamData(streamData, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension OneToOneStreamProtocol where Self: ~Copyable {
    public mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
    }
    public mutating func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.getOutboundStreamDataRoomAvailable(in: &eventContext)
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
        guard passthroughEvents || isConnected(in: &eventContext) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try self.sendStreamData(streamData, in: &eventContext)
    }

    public mutating func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleInboundAbortedEvent(error: error, in: &eventContext)
    }

    public mutating func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleOutboundAbortedEvent(error: error, in: &eventContext)
    }

    // Default implementations
    public mutating func handleInboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {}
    public mutating func handleOutboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {}
}

@available(Network 0.1.0, *)
extension OneToOneDatagramToStreamProtocol where Self: ~Copyable {
    public mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, in: &eventContext)
    }
    public mutating func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard passthroughEvents || isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.getDatagramsToSend(
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
        guard passthroughEvents || isConnected(in: &eventContext) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try self.sendDatagrams(datagrams, in: &eventContext)
    }
}
