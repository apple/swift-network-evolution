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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICDatagramFlow: ~Copyable, AutomaticUpperDatagramProcessing, MultiplexedDatapathFlow {
    public typealias ParentProtocol = QUICConnection
    public typealias UpperProtocol = BaseInboundDatagramLinkage

    // The generic datagram flow: identity, upper linkage and the queues shared with the application.
    // A QUIC datagram flow lives inline in its connection's secondary flow table, so nothing here is
    // reference counted.
    @usableFromInline
    var base: MultiplexedDatagramFlow<QUICConnection, BaseInboundDatagramLinkage>

    private(set) var flowID: UInt64?
    private(set) var contextID: UInt64?
    var applicationMarkedIdle: Bool = false

    public init(parent: QUICConnection, inbound: Bool) {
        base = MultiplexedDatagramFlow(parent: parent, inbound: inbound)
    }

    public init(parent: QUICConnection, inbound: Bool, in eventContext: inout NetworkContext.EventContext) {
        base = MultiplexedDatagramFlow(parent: parent, inbound: inbound, in: &eventContext)
    }

    // MARK: Forwarded flow state

    public var parentProtocol: QUICConnection {
        @inline(always) get { base.parentProtocol }
        @inline(always) set { base.parentProtocol = newValue }
    }
    public var upper: BaseInboundDatagramLinkage {
        @inline(always) get { base.upper }
        @inline(always) set { base.upper = newValue }
    }
    public var eventManager: ProtocolEventManager {
        @inline(always) _read { yield base.eventManager }
        @inline(always) _modify { yield &base.eventManager }
    }
    public var log: NetworkLoggerState {
        @inline(always) _read { yield base.log }
        @inline(always) _modify { yield &base.log }
    }
    public var upperSendQueue: FrameArray {
        @inline(always) _read { yield base.upperSendQueue }
        @inline(always) _modify { yield &base.upperSendQueue }
    }
    public var upperReceiveQueue: FrameArray {
        @inline(always) _read { yield base.upperReceiveQueue }
        @inline(always) _modify { yield &base.upperReceiveQueue }
    }
    public var maximumUpperDatagramSize: Int {
        @inline(always) get { base.maximumUpperDatagramSize }
        @inline(always) set { base.maximumUpperDatagramSize = newValue }
    }
    public var blockUpperSendQueue: Bool {
        @inline(always) get { base.blockUpperSendQueue }
        @inline(always) set { base.blockUpperSendQueue = newValue }
    }
    public var flowIdentifier: MultiplexedFlowIdentifier {
        @inline(always) get { base.flowIdentifier }
    }
    public var identifier: InstanceIdentifier {
        @inline(always) get { base.identifier }
        @inline(always) set { base.identifier = newValue }
    }

    public func drainQueuedEventsForUpperProtocol(in eventContext: inout NetworkContext.EventContext) {
        base.drainQueuedEventsForUpperProtocol(in: &eventContext)
    }

    // The flow is borrowed from the connection's secondary flow table while this runs, so the
    // connection cannot look the flow up again. Sending frames is held back until the borrow ends.
    public mutating func serviceUpperSendQueue(in eventContext: inout NetworkContext.EventContext) {
        parentProtocol.serviceDatagramsToSend(borrowedFlow: flowIdentifier, in: &eventContext)
    }

    public func asLowerLinkage() -> UpperProtocol.PairedLowerLinkage {
        BaseOutboundDatagramLinkage(
            quicConnection: parentProtocol,
            datagramFlow: flowIdentifier,
            identifier: identifier
        )
    }

    var usableDatagramSize: Int {
        get { maximumUpperDatagramSize }
        set { maximumUpperDatagramSize = newValue }
    }

    mutating func setup(
        datagramFlowID: UInt64? = nil,
        contextID: UInt64? = nil,
        logPrefixer: LogPrefixer
    ) {
        self.flowID = datagramFlowID
        self.contextID = contextID
    }

    static func generateFlowID(from associatedStreamID: UInt64) -> UInt64? {
        guard associatedStreamID % 4 == 0 else {
            Logger.proto.error(
                "Cannot create DATAGRAM flow ID with associated stream ID \(associatedStreamID)"
            )
            return nil
        }
        return (associatedStreamID / 4)
    }

    mutating func updateUsableDatagramFrameSize(
        connection: QUICConnection,
        path: QUICPath
    ) {
        guard let dcid = path.dcid else { return }
        let shortHeaderUnusablePayloadSize =
            (Int(connection.protector.getTagSize(for: connection.keyState)) + Packet.shortHeaderBaseSize
                + dcid.length + 4)
        var usableUDPPayloadSize = min(connection.remoteMaximumUDPPayloadSize, path.mss)
        guard usableUDPPayloadSize > shortHeaderUnusablePayloadSize else { return }
        usableUDPPayloadSize -= shortHeaderUnusablePayloadSize

        let maximumDatagramFrameHeaderSize =
            FrameType.datagram().rawValue.variableLengthSize
            + usableUDPPayloadSize.variableLengthSize
        var usableDatagramFrameSize = min(
            connection.remoteMaxDatagramFrameSize,
            usableUDPPayloadSize
        )
        guard usableDatagramFrameSize > maximumDatagramFrameHeaderSize else { return }
        usableDatagramFrameSize -= maximumDatagramFrameHeaderSize

        if let flowID {
            let encodedFlowIDLength = flowID.variableLengthSize
            guard usableDatagramFrameSize > encodedFlowIDLength else { return }
            usableDatagramFrameSize -= encodedFlowIDLength
        }

        self.usableDatagramSize = usableDatagramFrameSize
        log.debug("Usable datagram frame size set to \(usableDatagramFrameSize)")
    }
}
#endif
