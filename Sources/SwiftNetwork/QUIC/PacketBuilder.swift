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

enum PacketBuilderError: Int, Error {
    case argumentValidationFailed
    case bufferTooShort
    case frameError
    case tokenLengthTooBig
    case noPayloadsWritten

    func description() -> String {
        switch self {
        case .argumentValidationFailed:
            return "Argument validation failed"
        case .bufferTooShort:
            return "Buffer too short"
        case .frameError:
            return "Frame error"
        case .tokenLengthTooBig:
            return "Token length too big"
        case .noPayloadsWritten:
            return "No payloads written"
        }
    }
}

@available(Network 0.1.0, *)
extension Packet {
    static func build(
        into outboundFrame: inout Frame,
        number: PacketNumber,
        lastAcked: PacketNumber,
        keyState: PacketKeyState,
        path: QUICPath,
        tagSize: UInt8,
        pendingItems: inout PendingItems,
        sentPacketRecord: inout SentPacketRecord,
        connection: QUICConnection,
        availableCongestionWindow: UInt64,
        token: [UInt8]?,
        stats: inout Statistics,
        version: QUICVersion,
        isServer: Bool,
        testSendingShortPackets: Bool
    ) throws(QUICError) -> Packet {
        let longHeader = Packet.requiresLongHeader(keyState: keyState)
        guard let dcid = path.dcid else {
            connection.log.debug("Path is missing DCID")
            throw QUICError.packetBuilder(.argumentValidationFailed)
        }

        let scid: QUICConnectionID
        if longHeader {
            guard let pathSCID = path.scid else {
                connection.log.debug("Path is missing SCID")
                throw QUICError.packetBuilder(.argumentValidationFailed)
            }
            scid = pathSCID
        } else {
            scid = QUICConnectionID(0)
        }

        var packet = Packet(
            number: number,
            lastAcked: lastAcked,
            keyState: keyState,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            version: version
        )

        // payloadLength starts as 0
        packet.tagLength = tagSize

        // Claim tag size from end
        guard outboundFrame.claim(fromStart: 0, fromEnd: Int(tagSize)) else {
            throw QUICError.packetBuilder(PacketBuilderError.frameError)
        }
        defer {
            // Always unclaim the reserved tag size
            _ = outboundFrame.unclaim(fromStart: 0, fromEnd: Int(tagSize))
        }

        if !packet.longHeader {
            packet.update(spinValue: path.spinValue)
        }

        let lengthBeforeWritingHeader = outboundFrame.unclaimedLength

        var headerVersion: UInt32 = version.rawValue
        if !isServer, connection.forceUnsupportedClientVersion, keyState == .initial {
            // For testing support only (should only run once per test connection)
            headerVersion = QUICVersion.unsupportedVersion
            connection.forceUnsupportedClientVersion = false
        }
        // Write header
        var payloadLengthOffset: Int? = nil
        var truncatedPacketNumberLength: Int = 0
        try packet.writeHeader(
            into: &outboundFrame,
            lastAcked: lastAcked,
            token: token,
            payloadLengthOffset: &payloadLengthOffset,
            truncatedPacketNumberLength: &truncatedPacketNumberLength,
            spin: path.spinValue,
            headerVersion: headerVersion
        )

        let lengthAfterWritingHeader = outboundFrame.unclaimedLength

        // Adjust available congestion window down by header + tag
        let reservedHeaderLength = (lengthBeforeWritingHeader - lengthAfterWritingHeader)
        let reservedHeaderAndTagLength = reservedHeaderLength + Int(tagSize)

        let remainingCongestionWindow: UInt64
        if availableCongestionWindow >= reservedHeaderAndTagLength {
            remainingCongestionWindow =
                availableCongestionWindow - UInt64(reservedHeaderAndTagLength)
        } else {
            remainingCongestionWindow = 0
        }

        var isAckEliciting = false
        var isInFlightEligible = false
        var shorthandFrames: [QUICShorthandFrame]?
        if QUICShorthandFrame.shouldGenerateShorthandFrames(hasQLog: (connection.qLog != nil)) {
            shorthandFrames = .init()
        } else {
            shorthandFrames = nil
        }
        do throws(QUICError) {
            try pendingItems.write(
                into: &outboundFrame,
                connection: connection,
                stats: &stats,
                keyState: keyState,
                transmittedItems: &sentPacketRecord.transmittedItems,
                availableCongestionWindow: remainingCongestionWindow,
                isAckEliciting: &isAckEliciting,
                isInFlightEligible: &isInFlightEligible,
                maximumFrameCount: testSendingShortPackets && packet.longHeader ? 1 : nil,
                shorthandFrames: &shorthandFrames
            )
        } catch {
            // Unclaim the header
            let totalUnclaimedLength = lengthBeforeWritingHeader - outboundFrame.unclaimedLength
            _ = outboundFrame.unclaim(fromStart: totalUnclaimedLength)
            throw error
        }
        packet.shorthandFrames = shorthandFrames

        let lengthAfterWritingFrames = outboundFrame.unclaimedLength

        // Unclaim the header and payload
        let totalUnclaimedLength = lengthBeforeWritingHeader - lengthAfterWritingFrames
        guard outboundFrame.unclaim(fromStart: totalUnclaimedLength) else {
            throw QUICError.packetBuilder(PacketBuilderError.frameError)
        }

        // The payload length is everything after the header length
        let totalPayloadLength = totalUnclaimedLength + Int(tagSize) - Int(packet.headerLength)
        guard let payloadLength = UInt16(exactly: totalPayloadLength) else {
            throw QUICError.packetBuilder(PacketBuilderError.frameError)
        }
        packet.payloadLength = payloadLength
        if let payloadLengthOffset {
            try packet.updateLongHeaderPayloadLength(
                frame: &outboundFrame,
                payloadLengthOffset: payloadLengthOffset
            )
        }

        // Inherit length after the payload length is set
        sentPacketRecord.inheritFrom(packet: packet)
        sentPacketRecord.isAckEliciting = isAckEliciting
        sentPacketRecord.isInFlightEligible = isInFlightEligible

        return packet
    }

    // https://www.rfc-editor.org/rfc/rfc9001.html#name-retry-packet-integrity
    static func assemblePseudoRetry(
        firstByte: UInt8,
        originalDCID: QUICConnectionID,
        destinationCID: QUICConnectionID,
        sourceCID: QUICConnectionID,
        token: [UInt8]
    ) -> [UInt8] {
        Serializer.serialize { serializer in
            serializer.connectionID(originalDCID)
            serializer.uint8(firstByte)
            serializer.uint32NetworkByteOrder(QUICVersion.v1.rawValue)
            serializer.connectionID(destinationCID)
            serializer.connectionID(sourceCID)
            serializer.buffer(token)
        }
    }
}

#endif
