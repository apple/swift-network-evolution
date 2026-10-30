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

internal import DequeModule

/// Names a flow (a stream or a datagram flow) of a standalone many-to-many protocol.
///
/// A one-to-one protocol has exactly one flow, so it never needs one.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandaloneFlowID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public var description: String { "flow#\(rawValue)" }

    /// A dense number for the flow, for a table indexed by flow: the low 32 bits of the ID. It is
    /// reused once the flow is released, so check the ID itself against what the table holds for it.
    public var slotIndex: Int { rawValue & 0xFFFF_FFFF }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The ID of the flow whose link is at `slot`: its position and its generation, so the ID of a
    /// released flow does not name the flow that takes its position. The top bit stays clear, which
    /// keeps IDs clear of the queue's `-1` for "none".
    init(slot: NetworkStateIndex) {
        self.rawValue = Int(truncatingIfNeeded: slot.rawValue & 0x7FFF_FFFF_FFFF_FFFF)
    }
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
    /// The peer opened a flow. The flow is ready to use and connected, and it may already hold data: a
    /// data-available event for it that came before this one is not reported, so read after taking
    /// this event. `tag` is the protocol's own number for it:
    /// for QUIC the stream ID, which is all a QUIC stream's metadata holds that a driver needs. A
    /// protocol with no such number reports 0; ask `getMetadata(flow:)` for the rest.
    case newInboundFlow(StandaloneFlowID, tag: UInt64)
    /// Data can be read from the flow.
    case inboundDataAvailable(StandaloneFlowID?)
    /// The flow can accept more outbound data after having been full.
    case outboundRoomAvailable(StandaloneFlowID?)
    /// The peer stopped sending on the flow.
    case inboundAborted(StandaloneFlowID?, NetworkError?)
    /// The peer asked the flow to stop sending.
    case outboundAborted(StandaloneFlowID?, NetworkError?)
    /// A protocol-specific event, for example a QUIC connection ID or path event.
    indirect case network(NetworkProtocolEvent)
    /// The protocol queued data for the owner to send below. Collect it with `takeOutbound`.
    case outboundDataReady(StandalonePathID?)
}


/// The events a standalone protocol has queued for its owner, oldest first.
///
/// A `StandaloneEvent` is large (166 bytes, for the protocol events it can carry), and most events
/// are one of a few small ones that name a flow. Those queue as a 16-byte entry; the rest wait in a
/// queue of their own and an entry stands for each, so the order is kept. Both are ring buffers:
/// constant time whatever the backlog (about 6 ns an event in a micro-benchmark with batches from 1
/// to 512 events, where removing from the front of an array costs 10 to 90 ns an event).
@available(Network 0.1.0, *)
struct StandaloneEventQueue {
    enum Kind: UInt8 {
        case connected
        case disconnected
        case inboundDataAvailable
        case outboundRoomAvailable
        case outboundDataReady
        /// The event is the next one in `rare`.
        case rare
        /// A new inbound flow the protocol has already made and attached the owner to: the next tag
        /// in `tags`.
        case newInboundFlowTagged
        /// A new inbound flow the protocol made and nothing is attached to yet: the next one in
        /// `newFlows`.
        ///
        /// Attaching to the flow calls into the protocol, which must not happen while the protocol
        /// raises the event, so the attach waits until the owner takes the entry out (see
        /// `NetworkContext.EventContext.standaloneNextEvent()`).
        case newInboundFlow
    }

    struct Entry {
        var kind: Kind
        /// The flow or path the event names, `-1` for none.
        var id: Int
    }

    struct NewFlow {
        var connection: InstanceIdentifier
        var flowInstance: InstanceIdentifier
        var metadata: AbstractProtocolMetadata?
    }

    private var entries = Deque<Entry>()
    private var rare = Deque<StandaloneEvent>()
    private var newFlows = Deque<NewFlow>()
    private var tags = Deque<UInt64>()

    var isEmpty: Bool {
        self.entries.isEmpty
    }

    mutating func append(_ event: StandaloneEvent) {
        switch event {
        case .connected(let flow):
            self.entries.append(Entry(kind: .connected, id: flow?.rawValue ?? -1))
        case .disconnected(let flow, nil):
            self.entries.append(Entry(kind: .disconnected, id: flow?.rawValue ?? -1))
        case .inboundDataAvailable(let flow):
            self.entries.append(Entry(kind: .inboundDataAvailable, id: flow?.rawValue ?? -1))
        case .outboundRoomAvailable(let flow):
            self.entries.append(Entry(kind: .outboundRoomAvailable, id: flow?.rawValue ?? -1))
        case .outboundDataReady(let path):
            self.entries.append(Entry(kind: .outboundDataReady, id: path?.rawValue ?? -1))
        case .newInboundFlow(let flow, let tag):
            self.tags.append(tag)
            self.entries.append(Entry(kind: .newInboundFlowTagged, id: flow.rawValue))
        default:
            self.rare.append(event)
            self.entries.append(Entry(kind: .rare, id: -1))
        }
    }

    mutating func appendNewInboundFlow(
        connection: InstanceIdentifier,
        flowInstance: InstanceIdentifier,
        metadata: AbstractProtocolMetadata?
    ) {
        self.newFlows.append(NewFlow(connection: connection, flowInstance: flowInstance, metadata: metadata))
        self.entries.append(Entry(kind: .newInboundFlow, id: -1))
    }

    @inline(always)
    mutating func popEntry() -> Entry? {
        self.entries.popFirst()
    }

    /// The event a plain entry stands for. Not for `.newInboundFlow`.
    mutating func event(for entry: Entry) -> StandaloneEvent {
        switch entry.kind {
        case .connected:
            return .connected(entry.id < 0 ? nil : StandaloneFlowID(rawValue: entry.id))
        case .disconnected:
            return .disconnected(entry.id < 0 ? nil : StandaloneFlowID(rawValue: entry.id), nil)
        case .inboundDataAvailable:
            return .inboundDataAvailable(entry.id < 0 ? nil : StandaloneFlowID(rawValue: entry.id))
        case .outboundRoomAvailable:
            return .outboundRoomAvailable(entry.id < 0 ? nil : StandaloneFlowID(rawValue: entry.id))
        case .outboundDataReady:
            return .outboundDataReady(entry.id < 0 ? nil : StandalonePathID(rawValue: entry.id))
        case .rare:
            return self.rare.removeFirst()
        case .newInboundFlowTagged:
            return .newInboundFlow(StandaloneFlowID(rawValue: entry.id), tag: self.tags.removeFirst())
        case .newInboundFlow:
            preconditionFailure("A new inbound flow entry has no event until it is attached")
        }
    }

    mutating func takeNewFlow() -> NewFlow {
        self.newFlows.removeFirst()
    }
}

@available(Network 0.1.0, *)
extension NetworkContext.EventContext {
    /// Detaches and frees a flow whose connection asked for that (`releasesFlowsOnDisconnect`), as the
    /// owner takes the flow's disconnect from the queue. The owner is outside the protocol here, as it
    /// is when it tears a flow down itself, but it makes one call less for every flow.
    mutating func standaloneReleaseFlowOnDisconnect(_ id: StandaloneFlowID) {
        guard let flow = standaloneFlowLink(id), standaloneLinks[flow.slot].releasesFlowsOnDisconnect else { return }
        flow.teardown(in: &self)
        flow.free(in: &self)
    }

    /// The oldest event for the owner. A new inbound flow is attached on the way out, which is why
    /// this runs with the owner, outside any call into the protocol.
    mutating func standaloneNextEvent() -> StandaloneEvent? {
        while let entry = standaloneEvents.popEntry() {
            if entry.kind == .newInboundFlow {
                let flow = standaloneEvents.takeNewFlow()
                let link = StandaloneConnectionLink(resolving: flow.connection, in: &self)
                if let event = link.completeNewInboundFlow(
                    flowInstance: flow.flowInstance,
                    flowMetadata: flow.metadata,
                    in: &self
                ) {
                    return event
                }
            } else {
                if entry.kind == .newInboundFlowTagged, let flow = standaloneFlowLink(StandaloneFlowID(rawValue: entry.id)) {
                    standaloneLinks[flow.slot].newFlowPending = false
                }
                if entry.kind == .disconnected, entry.id >= 0 {
                    standaloneReleaseFlowOnDisconnect(StandaloneFlowID(rawValue: entry.id))
                }
                return standaloneEvents.event(for: entry)
            }
        }
        return nil
    }
}

#endif
