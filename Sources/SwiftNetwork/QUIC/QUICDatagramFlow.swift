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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICDatagramFlow: MultiplexedDatagramFlow<QUICConnection, BaseInboundDatagramLinkage> {
    private(set) var flowID: UInt64?
    private(set) var contextID: UInt64?
    var applicationMarkedIdle: Bool = false

    override public func asLowerLinkage() -> UpperProtocol.PairedLowerLinkage {
        BaseOutboundDatagramLinkage(quicDatagramFlow: self)
    }

    var usableDatagramSize: Int {
        get { maximumUpperDatagramSize }
        set { maximumUpperDatagramSize = newValue }
    }

    func setup(
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

    func updateUsableDatagramFrameSize(
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
