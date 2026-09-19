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

// MARK: - Top Protocol Adoption

/// Top protocols sit at the top of a stack and have only a lower protocol.
///
/// Conform to `TopStreamProtocol` or `TopDatagramProtocol`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopProtocolHandler<LinkageType>: ~Copyable, InboundDataHandler {
    /// The upper linkage type that represents this protocol to the protocol below it.
    ///
    /// A top protocol has nothing above it, so what matters is the linkage the lower protocol
    /// holds in order to call back up. Naming that linkage directly, rather than a whole
    /// linkage family, lets a protocol that is itself a linkage serve as its own.
    associatedtype LinkageType: UpperProtocolLinkage

    /// The type of lower protocol (toward the network) that you can attach.
    var lower: LinkageType.PairedLowerLinkage { get set }

    /// A function the framework calls when the lower protocol connects.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleConnectedEvent(in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when the lower protocol disconnects.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when a lower protocol sends an event.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleNetworkProtocolEvent(_ event: NetworkProtocolEvent, in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopDatapathProtocol: ~Copyable, TopProtocolHandler
where LinkageType.PairedLowerLinkage == LowerProtocol {

    /// A function the framework calls when the lower protocol has inbound data available to read.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when the lower protocol has outbound room available to send.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable {
    /// Requests that the lower protocol start connecting.
    ///
    /// This is an external entry point: call it from code outside the protocol stack, such as an
    /// app or a unit test. If you already hold the event context, call the `in:`-taking
    /// variant instead so the state isn't re-derived from the context.
    public func invokeConnect() {
        fromExternal { eventContext in
            invokeConnect(in: &eventContext)
        }
    }

    /// Requests that the lower protocol start connecting, using an already-acquired event context.
    public func invokeConnect(in eventContext: inout NetworkContext.EventContext) {
        lower.invokeConnect(for: self.identifier, in: &eventContext)
    }

    /// Requests that the lower protocol disconnect.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeDisconnect(error: NetworkError?) {
        fromExternal { eventContext in
            invokeDisconnect(error: error, in: &eventContext)
        }
    }

    /// Requests that the lower protocol disconnect, using an already-acquired event context.
    public func invokeDisconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        lower.invokeDisconnect(error: error, for: self.identifier, in: &eventContext)
    }

    /// Detaches the lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public mutating func invokeDetach() throws(NetworkError) {
        try fromExternal { eventContext throws(NetworkError) in
            try lower.invokeDetach(for: self.identifier, in: &eventContext)
        }
        lower = .init()
    }

    /// Detaches the lower protocol, using an already-acquired event context.
    public mutating func invokeDetach(in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        try lower.invokeDetach(for: self.identifier, in: &eventContext)
        lower = .init()
    }

    /// Signals an application-level event to lower protocols.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeApplicationEvent(_ event: ApplicationEvent) {
        fromExternal { eventContext in
            invokeApplicationEvent(event, in: &eventContext)
        }
    }

    /// Signals an application-level event to lower protocols, using an already-acquired event context.
    public func invokeApplicationEvent(_ event: ApplicationEvent, in eventContext: inout NetworkContext.EventContext) {
        lower.invokeApplicationEvent(event: event, for: self.identifier, in: &eventContext)
    }

    /// Accesses protocol metadata from a lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeGetMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        fromExternal { eventContext in
            invokeGetMetadata(in: &eventContext)
        }
    }

    /// Accesses protocol metadata from a lower protocol, using an already-acquired event context.
    public func invokeGetMetadata<P: NetworkProtocol>(
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        lower.invokeGetMetadata(for: self.identifier, in: &eventContext)
    }
}

/// Top protocol with a lower stream linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopStreamProtocol: ~Copyable, TopDatapathProtocol, InboundStreamHandler
where LinkageType: InboundStreamLinkage {
    /// A function the framework calls when the lower protocol reports that inbound stream data is aborted.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleInboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)

    /// A function the framework calls when the lower protocol reports that outbound stream data is aborted.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleOutboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension TopStreamProtocol where Self: ~Copyable {
    /// Receives stream data from the lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeReceiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
        try fromExternal { eventContext throws(NetworkError) in
            try invokeReceiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, in: &eventContext)
        }
    }

    /// Receives stream data from the lower protocol, using an already-acquired event context.
    public func invokeReceiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try lower.invokeReceiveStreamData(
            minimumBytes: minimumBytes,
            maximumBytes: maximumBytes,
            for: self.identifier,
            in: &eventContext
        )
    }

    /// Returns the number of bytes of stream data you can send to the lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeGetOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        try fromExternal { eventContext throws(NetworkError) in
            try invokeGetOutboundStreamDataRoomAvailable(in: &eventContext)
        }
    }

    /// Returns the number of bytes of stream data you can send to the lower protocol, using an
    /// already-acquired event context.
    public func invokeGetOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        try lower.invokeGetOutboundStreamDataRoomAvailable(for: self.identifier, in: &eventContext)
    }

    /// Sends stream data to the lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeSendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        try fromExternal(streamData) { eventContext, streamData throws(NetworkError) in
            try invokeSendStreamData(streamData, in: &eventContext)
        }
    }

    /// Sends stream data to the lower protocol, using an already-acquired event context.
    public func invokeSendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try lower.invokeSendStreamData(streamData, from: self.identifier, in: &eventContext)
    }

    /// Sends early stream data to the lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeSendEarlyStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        try fromExternal(streamData) { eventContext, streamData throws(NetworkError) in
            try invokeSendEarlyStreamData(streamData, in: &eventContext)
        }
    }

    /// Sends early stream data to the lower protocol, using an already-acquired event context.
    public func invokeSendEarlyStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try lower.invokeSendEarlyStreamData(streamData, from: self.identifier, in: &eventContext)
    }
}

/// Top protocol with a lower datagram linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopDatagramProtocol: ~Copyable, TopDatapathProtocol, InboundDatagramHandler
where LinkageType: InboundDatagramLinkage {

}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension TopDatagramProtocol where Self: ~Copyable, Self: ~Copyable {
    /// Receives datagrams from the lower protocol.
    ///
    /// This is an external entry point; see `invokeConnect()`.
    public func invokeReceiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
        try fromExternal { eventContext throws(NetworkError) in
            try invokeReceiveDatagrams(maximumDatagramCount: maximumDatagramCount, in: &eventContext)
        }
    }

    /// Receives datagrams from the lower protocol, using an already-acquired event context.
    public func invokeReceiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try lower.invokeReceiveDatagrams(
            maximumDatagramCount: maximumDatagramCount,
            for: self.identifier,
            in: &eventContext
        )
    }

    /// Returns datagram memory you can write into, from the lower protocol.
    public func invokeGetDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        try fromExternal { eventContext throws(NetworkError) in
            try invokeGetDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                in: &eventContext
            )
        }
    }

    /// Returns datagram memory you can write into, using an already-acquired event context.
    public func invokeGetDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        try lower.invokeGetDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            for: self.identifier,
            in: &eventContext
        )
    }

    /// Sends previously retrieved datagrams to the lower protocol.
    ///
    /// Sends datagrams previously retrieved with `invokeGetDatagramsToSend`.
    public func invokeSendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        try fromExternal(datagrams) { eventContext, datagrams throws(NetworkError) in
            try invokeSendDatagrams(datagrams, in: &eventContext)
        }
    }

    /// Sends previously retrieved datagrams to the lower protocol, using an already-acquired
    /// event context.
    public func invokeSendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try lower.invokeSendDatagrams(datagrams, from: self.identifier, in: &eventContext)
    }
}

// MARK: - Top Protocol Implementation Details

@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable {
    internal func validate(
        lower lowerProtocol: InstanceIdentifier,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard !lowerProtocol.isNone else {
            Logger.proto.error("Received \'\(label)\' from incorrect lower protocol")
            throw ProtocolInstanceError.invalidLowerProtocol
        }
        #endif
    }

    public mutating func attachLowerProtocol(
        _ lowerProtocol: LinkageType.PairedLowerLinkage,
    ) throws(NetworkError) -> LinkageType.PairedLowerLinkage.PairedUpperLinkage? {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        lower = lowerProtocol
        return nil
    }

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleConnectedEvent(in: &eventContext)
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleDisconnectedEvent(error: error, in: &eventContext)
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate lower, can pass through
        self.handleNetworkProtocolEvent(event, in: &eventContext)
    }
}

// Default implementations, to be overridden as necessary
@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable {
    public func handleConnectedEvent(in eventContext: inout NetworkContext.EventContext) {}

    public func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {}

    public func handleNetworkProtocolEvent(
        _ event: NetworkProtocolEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {}
}

@available(Network 0.1.0, *)
extension TopDatapathProtocol where Self: ~Copyable {
    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleInboundDataAvailableEvent(in: &eventContext)
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleOutboundRoomAvailableEvent(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension TopDatapathProtocol where Self: ~Copyable {
    // Default implementations, to be overridden as necessary
    public func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {}

    public func handleOutboundRoomAvailableEvent(in eventContext: inout NetworkContext.EventContext) {}
}

@available(Network 0.1.0, *)
extension TopStreamProtocol where Self: ~Copyable {
    public func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleInboundAbortedEvent(error: error, in: &eventContext)
    }

    public func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        do { try validate(lower: instance, #function) } catch { return }
        self.handleOutboundAbortedEvent(error: error, in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension TopStreamProtocol where Self: ~Copyable {
    // Default implementations, to be overridden as necessary
    public func handleInboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {}

    public func handleOutboundAbortedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {}
}
