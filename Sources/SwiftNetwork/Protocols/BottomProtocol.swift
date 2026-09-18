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

// MARK: - Bottom Protocol Adoption

/// Bottom protocols sit at the bottom of a stack and have only an upper protocol.
///
/// Conform to `BottomStreamProtocol` or `BottomDatagramProtocol`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol BottomProtocolHandler<LinkageType>: ~Copyable, OutboundDataHandler {
    /// The lower linkage type that represents this protocol to the protocol above it.
    ///
    /// A bottom protocol has nothing below it, so what matters is the linkage the upper
    /// protocol holds in order to call back down. Naming that linkage directly, rather than a
    /// whole linkage family, lets a protocol that is itself a linkage serve as its own.
    associatedtype LinkageType: LowerProtocolLinkage

    /// The type of upper protocol (toward the app) that you can attach.
    var upper: LinkageType.PairedUpperLinkage { get set }

    /// Sets up a protocol instance with parameters and endpoints.
    ///
    /// Protocols can implement this function to customize behavior.
    func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError)

    /// Tears down a protocol when detaching.
    ///
    /// Protocols can implement this function to customize behavior.
    func teardown()

    /// Requests that this protocol initiate its handshake, if any.
    ///
    /// If not implemented, the protocol delivers the connected event automatically.
    /// Protocols can implement this function to customize behavior. Thread `eventContext` into any
    /// calls made to other protocols so that the state is never re-derived from the context.
    func connect(in eventContext: inout NetworkContext.EventContext)

    /// Requests that this protocol gracefully close.
    ///
    /// Protocols can implement this function to customize behavior. See `connect(state:)`.
    func disconnect(in eventContext: inout NetworkContext.EventContext)

    /// Handles an event the app sent.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleApplicationEvent(_ event: ApplicationEvent, in eventContext: inout NetworkContext.EventContext)

    #if !NETWORK_EMBEDDED
    /// The metadata state for this protocol.
    var metadata: AbstractProtocolMetadata? { get }
    #endif

    /// Update this protocols contribution to a data transfer snapshot.
    func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot)

    /// Fetch this protocols establishment report entry
    var protocolEstablishmentReport: ProtocolEstablishmentReport? { get }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension BottomProtocolHandler where Self: ~Copyable {
    /// Indicates to the upper protocol that this protocol is connected.
    ///
    /// Call this only if the protocol customizes `connect()`.
    ///
    /// This is an external entry point: call it from code outside the protocol stack, such as
    /// a socket readiness callback. If you already hold the event context, call the
    /// `in:`-taking variant instead so the state isn't re-derived from the context.
    public func deliverConnectedEvent() {
        fromExternal { eventContext in
            deliverConnectedEvent(in: &eventContext)
        }
    }

    /// Indicates to the upper protocol that this protocol is connected, using an
    /// already-acquired event context.
    public func deliverConnectedEvent(in eventContext: inout NetworkContext.EventContext) {
        upper.deliverConnectedEvent(from: self.identifier, in: &eventContext)
    }

    /// Indicates to the upper protocol that this protocol is disconnected, with an error.
    ///
    /// This is an external entry point; see `deliverConnectedEvent()`.
    public func deliverDisconnectedEvent(error: NetworkError?) {
        fromExternal { eventContext in
            deliverDisconnectedEvent(error: error, in: &eventContext)
        }
    }

    /// Indicates to the upper protocol that this protocol is disconnected, using an
    /// already-acquired event context.
    public func deliverDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        upper.deliverDisconnectedEvent(error: error, from: self.identifier, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension BottomProtocolHandler where Self: ~Copyable, LinkageType.PairedUpperLinkage: InboundDataLinkage {
    /// Indicates to the upper protocol that this protocol has data available to read.
    ///
    /// This is an external entry point; see `deliverConnectedEvent()`.
    public func deliverInboundDataAvailableEvent() {
        fromExternal { eventContext in
            deliverInboundDataAvailableEvent(in: &eventContext)
        }
    }

    /// Indicates to the upper protocol that this protocol has data available to read, using an
    /// already-acquired event context.
    public func deliverInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        guard isConnected(in: &eventContext) else { return }
        upper.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
    }

    /// Indicates to the upper protocol that this protocol has room available to send.
    ///
    /// This is an external entry point; see `deliverConnectedEvent()`.
    public func deliverOutboundRoomAvailableEvent() {
        fromExternal { eventContext in
            deliverOutboundRoomAvailableEvent(in: &eventContext)
        }
    }

    /// Indicates to the upper protocol that this protocol has room available to send, using an
    /// already-acquired event context.
    public func deliverOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
        guard isConnected(in: &eventContext) else { return }
        upper.deliverOutboundRoomAvailableEvent(from: self.identifier, in: &eventContext)
    }

    /// Passes an event to the upper protocol.
    ///
    /// This is an external entry point; see `deliverConnectedEvent()`.
    public func deliverNetworkProtocolEvent(_ event: NetworkProtocolEvent) {
        fromExternal { eventContext in
            deliverNetworkProtocolEvent(event, in: &eventContext)
        }
    }

    /// Passes an event to the upper protocol, using an already-acquired event context.
    public func deliverNetworkProtocolEvent(
        _ event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        upper.deliverNetworkProtocolEvent(
            originalInstance: self.identifier,
            selfInstance: self.identifier,
            event: event,
            in: &eventContext
        )
    }
}

/// Bottom protocol with an upper stream linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol BottomStreamProtocol: ~Copyable, BottomProtocolHandler, OutboundStreamHandler
where LinkageType: OutboundStreamLinkage, LinkageType.PairedUpperLinkage == UpperProtocol {

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

/// Bottom protocol with an upper datagram linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol BottomDatagramProtocol: ~Copyable, BottomProtocolHandler, OutboundDatagramHandler
where LinkageType: OutboundDatagramLinkage, LinkageType.PairedUpperLinkage == UpperProtocol {

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

// MARK: - Bottom Protocol Implementation Details

@available(Network 0.1.0, *)
extension BottomProtocolHandler where Self: ~Copyable {
    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate upper, can pass through
        self.handleApplicationEvent(event, in: &eventContext)
    }

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

    public mutating func attachUpperProtocol(
        _ upperProtocol: LinkageType.PairedUpperLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard upper.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        upper = upperProtocol

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
        upper = .init()
        teardown()
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        do { try validate(upper: instance, #function) } catch { return }
        if canCallConnect(requested: true, in: &eventContext) {
            connect(in: &eventContext)
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(upper: instance, #function) } catch { return }
        if canCallDisconnect(in: &eventContext) {
            disconnect(in: &eventContext)
        }
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
        #endif
        return nil
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        do { try validate(upper: instance, #function) } catch { return nil }
        switch requestedNetworkMetric {
        case .protocolEstablishmentReports:
            guard let report = protocolEstablishmentReport else { return nil }
            return .protocolEstablishmentReports([report])
        case .dataTransferSnapshot:
            var snapshot = DataTransferSnapshot()
            updateDataTransferSnapshot(&snapshot)
            return .dataTransferSnapshot(snapshot)
        }
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

// Default implementations, to be overridden as necessary
@available(Network 0.1.0, *)
extension BottomProtocolHandler where Self: ~Copyable {
    public func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {}

    public func teardown() {}

    public func connect(in eventContext: inout NetworkContext.EventContext) {
        deliverConnectedEvent(in: &eventContext)
    }

    public func disconnect(in eventContext: inout NetworkContext.EventContext) {
        deliverDisconnectedEvent(error: nil, in: &eventContext)
    }

    public func handleApplicationEvent(_ event: ApplicationEvent, in eventContext: inout NetworkContext.EventContext) {}

    #if !NETWORK_EMBEDDED
    public var metadata: AbstractProtocolMetadata? { nil }
    #endif

    public func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot) {}

    public var protocolEstablishmentReport: ProtocolEstablishmentReport? { nil }
}

@available(Network 0.1.0, *)
extension BottomDatagramProtocol where Self: ~Copyable {
    public mutating func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, in: &eventContext)
    }
    public mutating func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
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
        guard isConnected(in: &eventContext) else {
            datagrams.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try self.sendDatagrams(datagrams, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension BottomStreamProtocol where Self: ~Copyable {
    public mutating func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
        return try self.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
    }
    public mutating func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
        guard isConnected(in: &eventContext) else { throw NetworkError.posix(ENOTCONN) }
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
        guard isConnected(in: &eventContext) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTCONN)
        }
        try self.sendStreamData(streamData, in: &eventContext)
    }
}
