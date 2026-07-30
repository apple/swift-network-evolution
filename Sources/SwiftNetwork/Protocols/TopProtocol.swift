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
public protocol TopProtocolHandler: ~Copyable, InboundDataHandler {

    /// The type of lower protocol (toward the network) that you can attach.
    var lower: LowerProtocol { get set }

    /// A function the framework calls when the lower protocol connects.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleConnectedEvent()

    /// A function the framework calls when the lower protocol disconnects.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleDisconnectedEvent(error: NetworkError?)

    /// A function the framework calls when a lower protocol sends an event.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleNetworkProtocolEvent(_ event: NetworkProtocolEvent)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopDatapathProtocol: ~Copyable, TopProtocolHandler where LowerProtocol: OutboundDataLinkage {

    /// A function the framework calls when the lower protocol has inbound data available to read.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleInboundDataAvailableEvent()

    /// A function the framework calls when the lower protocol has outbound room available to send.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleOutboundRoomAvailableEvent()
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable {
    /// Requests that the lower protocol start connecting.
    public func invokeConnect() {
        fromExternal {
            lower.invokeConnect(self.reference)
        }
    }

    /// Requests that the lower protocol disconnect.
    public func invokeDisconnect(error: NetworkError?) {
        fromExternal {
            lower.invokeDisconnect(self.reference, error: error)
        }
    }

    /// Detaches the lower protocol.
    public mutating func invokeDetach() throws(NetworkError) {
        try fromExternal { () throws(NetworkError) in
            try lower.invokeDetach(self.reference)
        }
        lower = .init(reference: .init())
    }

    /// Signals an application-level event to lower protocols.
    public func invokeApplicationEvent(_ event: ApplicationEvent) {
        fromExternal {
            lower.invokeApplicationEvent(self.reference, event: event)
        }
    }

    /// Accesses protocol metadata from a lower protocol.
    public func invokeGetMetadata<P: NetworkProtocol>() -> ProtocolMetadata<P>? {
        fromExternal {
            lower.invokeGetMetadata(self.reference)
        }

    }
}

/// Top protocol with a lower stream linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopStreamProtocol: ~Copyable, TopDatapathProtocol, InboundStreamHandler
where LowerProtocol == OutboundStreamLinkage {
    /// A function the framework calls when the lower protocol reports that inbound stream data is aborted.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleInboundAbortedEvent(error: NetworkError?)

    /// A function the framework calls when the lower protocol reports that outbound stream data is aborted.
    ///
    /// Protocols can implement this function to customize behavior.
    func handleOutboundAbortedEvent(error: NetworkError?)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension TopStreamProtocol where Self: ~Copyable {
    /// Receives stream data from the lower protocol.
    public func invokeReceiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
        try fromExternal { () throws(NetworkError) in
            try lower.invokeReceiveStreamData(self.reference, minimumBytes: minimumBytes, maximumBytes: maximumBytes)
        }
    }

    /// Returns the number of bytes of stream data you can send to the lower protocol.
    public func invokeGetOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        try fromExternal { () throws(NetworkError) in
            try lower.invokeGetOutboundStreamDataRoomAvailable(self.reference)
        }
    }

    /// Sends stream data to the lower protocol.
    public func invokeSendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        try fromExternal(streamData) { streamData throws(NetworkError) in
            try lower.invokeSendStreamData(self.reference, streamData: streamData)
        }
    }

    /// Sends early stream data to the lower protocol.
    public func invokeSendEarlyStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        try fromExternal(streamData) { streamData throws(NetworkError) in
            try lower.invokeSendEarlyStreamData(self.reference, streamData: streamData)
        }
    }
}

/// Top protocol with a lower datagram linkage.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TopDatagramProtocol: ~Copyable, TopDatapathProtocol, InboundDatagramHandler
where LowerProtocol == OutboundDatagramLinkage {

}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension TopDatagramProtocol where Self: ~Copyable, Self: ~Copyable {
    /// Receives datagrams from the lower protocol.
    public func invokeReceiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
        try fromExternal { () throws(NetworkError) in
            try lower.invokeReceiveDatagrams(self.reference, maximumDatagramCount: maximumDatagramCount)
        }
    }

    /// Returns datagram memory you can write into, from the lower protocol.
    public func invokeGetDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        try fromExternal { () throws(NetworkError) in
            try lower.invokeGetDatagramsToSend(
                self.reference,
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize
            )
        }
    }

    /// Sends previously retrieved datagrams to the lower protocol.
    ///
    /// Sends datagrams previously retrieved with `invokeGetDatagramsToSend`.
    public func invokeSendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        try fromExternal(datagrams) { datagrams throws(NetworkError) in
            try lower.invokeSendDatagrams(self.reference, datagrams: datagrams)
        }
    }
}

// MARK: - Top Protocol Implementation Details

@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable {
    var asUpper: LowerProtocol.PairedLinkage { .init(reference: reference) }

    internal func validate(
        lower lowerProtocol: ProtocolInstanceReference,
        _ label: String
    ) throws(ProtocolInstanceError) {
        #if DEBUG
        guard !lowerProtocol.isNone else {
            Logger.proto.error("Received \'\(label)\' from incorrect lower protocol")
            throw ProtocolInstanceError.invalidLowerProtocol
        }
        #endif
    }

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

    public func handleConnectedEvent(_ from: ProtocolInstanceReference) {
        do { try validate(lower: from, #function) } catch { return }
        self.handleConnectedEvent()
    }

    public func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(lower: from, #function) } catch { return }
        self.handleDisconnectedEvent(error: error)
    }

    public func handleNetworkProtocolEvent(_ from: ProtocolInstanceReference, event: NetworkProtocolEvent) {
        // Don't validate lower, can pass through
        self.handleNetworkProtocolEvent(event)
    }
}

// Default implementations, to be overridden as necessary
@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable {
    public func handleConnectedEvent() {}

    public func handleDisconnectedEvent(error: NetworkError?) {}

    public func handleNetworkProtocolEvent(_ event: NetworkProtocolEvent) {}
}

@available(Network 0.1.0, *)
extension TopDatapathProtocol where Self: ~Copyable {
    public func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
        do { try validate(lower: from, #function) } catch { return }
        self.handleInboundDataAvailableEvent()
    }

    public func handleOutboundRoomAvailableEvent(_ from: ProtocolInstanceReference) {
        do { try validate(lower: from, #function) } catch { return }
        self.handleOutboundRoomAvailableEvent()
    }
}

@available(Network 0.1.0, *)
extension TopDatapathProtocol where Self: ~Copyable {
    // Default implementations, to be overridden as necessary
    public func handleInboundDataAvailableEvent() {}

    public func handleOutboundRoomAvailableEvent() {}
}

@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable, LowerProtocol == OutboundDatagramLinkage {
    public mutating func attachLowerDatagramProtocol(
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

@available(Network 0.1.0, *)
extension TopProtocolHandler where Self: ~Copyable, LowerProtocol == OutboundStreamLinkage {
    public mutating func attachLowerStreamProtocol(
        _ lowerProtocol: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        self.lower = try lowerProtocol.attachUpperStreamProtocol(
            reference,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    public mutating func attachLowerStreamProtocolToExistingFlow(
        listener: StreamListenerLinkage,
        flowReference: ProtocolInstanceReference
    ) throws(NetworkError) {
        guard lower.isDetached else {
            throw NetworkError.posix(EALREADY)
        }
        self.lower = try listener.invokeAttachUpperStreamProtocolToExistingFlow(
            reference,
            flowReference: flowReference
        )
    }
}

@available(Network 0.1.0, *)
extension TopStreamProtocol where Self: ~Copyable {
    public func handleInboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(lower: from, #function) } catch { return }
        self.handleInboundAbortedEvent(error: error)
    }

    public func handleOutboundAbortedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
        do { try validate(lower: from, #function) } catch { return }
        self.handleOutboundAbortedEvent(error: error)
    }
}

@available(Network 0.1.0, *)
extension TopStreamProtocol where Self: ~Copyable {
    // Default implementations, to be overridden as necessary
    public func handleInboundAbortedEvent(error: NetworkError?) {}

    public func handleOutboundAbortedEvent(error: NetworkError?) {}
}
