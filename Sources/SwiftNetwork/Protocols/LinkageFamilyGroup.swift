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

/// Bundles the linkage families a whole protocol stack is built from.
///
/// A stack's datagram and stream linkages reference each other -- TCP takes datagrams below and
/// presents a stream above, and a QUIC connection presents both -- so a type generic over one
/// family almost always needs the other. Carrying them as separate generic parameters would make
/// every such type generic over the cross product, and the associated-type expansion does not
/// terminate. Grouping them means the storage and every linkage take exactly one generic parameter.
///
/// A group also has to say how to build a linkage around the protocols the framework creates on its
/// behalf. Those requirements point one way -- from the group out to the linkages -- which is what
/// keeps them resolvable. Expressing them the other way round, as conformances on the linkages
/// pointing back at the group, is what previously made the compiler diverge.
///
/// A client that supplies its own group therefore keeps supporting the framework's protocols; it
/// adds its own rather than replacing them.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol LinkageFamilyGroup: Sendable {
    /// The family used by datagram protocols in this stack -- UDP, IP, demux, the datagram
    /// sockets and bridges, and the paths and datagram flows of a QUIC connection.
    associatedtype DatagramFamily: DatagramLinkageFamily

    /// The family used by stream protocols in this stack -- TCP, the stream sockets and bridges,
    /// and the stream flows a QUIC connection presents.
    associatedtype StreamFamily: StreamLinkageFamily

    /// The multipath linkage a protocol spanning several paths hands out. QUIC is the only such
    /// protocol today.
    associatedtype MultipathLinkageType: DatagramMultipathLinkage
    where MultipathLinkageType.MultipathLowerProtocol == DatagramFamily.Lower

    #if !NETWORK_NO_SWIFT_QUIC
    /// Wraps a QUIC stream in the lower linkage its upper protocol talks to.
    static func linkage(for quicStream: QUICStreamInstance<Self>) -> StreamFamily.Lower

    /// Wraps a QUIC datagram flow in the lower linkage its upper protocol talks to.
    static func linkage(for quicDatagramFlow: QUICDatagramFlow<Self>) -> DatagramFamily.Lower

    /// Wraps a QUIC path in the upper linkage the datagram protocol below it reports to.
    static func linkage(for quicPath: QUICPath<Self>) -> DatagramFamily.Upper
    #endif

    // A framework linkage reporting itself upward has to hand back the family's own type. For the
    // base group those are the same type, but a group that wraps the framework's linkages has to
    // put the wrapper back on. These do that lift; without them the framework would have to force-
    // cast itself to the family type, which traps for any group that wraps.

    /// Lifts a framework datagram upper linkage into this group's family.
    static func family(for linkage: BaseInboundDatagramLinkage<Self>) -> DatagramFamily.Upper

    /// Lifts a framework datagram inbound-flow linkage into this group's family.
    static func family(for linkage: BaseInboundDatagramFlowLinkage<Self>) -> DatagramFamily.InboundFlow

    /// Lifts a framework stream upper linkage into this group's family.
    static func family(for linkage: BaseInboundStreamLinkage<Self>) -> StreamFamily.Upper

    /// Lifts a framework stream inbound-flow linkage into this group's family.
    static func family(for linkage: BaseInboundStreamFlowLinkage<Self>) -> StreamFamily.InboundFlow

    /// Lifts a framework datagram lower linkage into this group's family.
    static func family(for linkage: BaseOutboundDatagramLinkage<Self>) -> DatagramFamily.Lower

    /// Lifts a framework datagram listener linkage into this group's family.
    static func family(for linkage: BaseDatagramListenerLinkage<Self>) -> DatagramFamily.Listener

    /// Lifts a framework datagram multipath linkage into this group's family.
    static func family(for linkage: BaseDatagramMultipathLinkage<Self>) -> MultipathLinkageType

    /// Lifts a framework stream lower linkage into this group's family.
    static func family(for linkage: BaseOutboundStreamLinkage<Self>) -> StreamFamily.Lower

    /// Lifts a framework stream listener linkage into this group's family.
    static func family(for linkage: BaseStreamListenerLinkage<Self>) -> StreamFamily.Listener
}
