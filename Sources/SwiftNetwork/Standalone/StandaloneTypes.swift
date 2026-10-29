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

/// Names a flow (a stream or a datagram flow) of a standalone many-to-many protocol.
///
/// A one-to-one protocol has exactly one flow, so it never needs one.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandaloneFlowID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public var description: String { "flow#\(rawValue)" }
}

/// Names a path of a standalone many-to-many protocol.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandalonePathID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public var description: String { "path#\(rawValue)" }
}

/// What a standalone protocol wants the owner to know about.
///
/// Events are queued while a call into the protocol unwinds, and the owner collects them with
/// `StandaloneEnvironment.drainEvents(_:)` or `nextEvent()`. A `nil` flow means the event concerns
/// the whole connection (or, for a one-to-one protocol, the one flow).
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum StandaloneEvent {
    /// The protocol (or flow) is connected.
    case connected(StandaloneFlowID?)
    /// The protocol (or flow) is disconnected.
    case disconnected(StandaloneFlowID?, NetworkError?)
    /// The peer opened a flow. The flow is ready to use, and its metadata is the protocol's own
    /// (for QUIC, `QUICStreamMetadata`).
    case newInboundFlow(StandaloneFlowID, AbstractProtocolMetadata?)
    /// Data can be read from the flow.
    case inboundDataAvailable(StandaloneFlowID?)
    /// The flow can accept more outbound data after having been full.
    case outboundRoomAvailable(StandaloneFlowID?)
    /// The peer stopped sending on the flow.
    case inboundAborted(StandaloneFlowID?, NetworkError?)
    /// The peer asked the flow to stop sending.
    case outboundAborted(StandaloneFlowID?, NetworkError?)
    /// A protocol-specific event, for example a QUIC connection ID or path event.
    case network(NetworkProtocolEvent)
    /// The protocol queued data for the owner to send below. Collect it with `takeOutbound`.
    case outboundDataReady(StandalonePathID?)
}

#endif
