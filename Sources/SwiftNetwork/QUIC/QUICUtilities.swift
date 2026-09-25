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

@available(Network 0.1.0, *)
extension System {
    static func isHighMemory() -> Bool {
        #if NETWORK_EMBEDDED
        return false
        #else
        /*
		 * The hw.memsize sysctl will usually return < 4GB on a 4GB system, so we consider
		 * a high memory system a device that holds more than 3GB of usable memory.
		 */
        var memsize: UInt64 = 0
        #if os(Linux)
        memsize = 0xffff_ffff + 1
        #elseif !NETWORK_STANDALONE
        var len = Int.bitWidth
        if sysctlbyname("hw.memsize", &memsize, &len, nil, 0) < 0 {
            Logger.proto.error("sysctlbyname(hw.memsize) failed, assuming 4GB")
            memsize = 0xffff_ffff + 1
        }
        #endif
        return memsize > Constants.highMemorySystem
        #endif
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICRoutingHeader: ~Copyable {
    public var type: UInt8?
    public var version: UInt32?
    public var destinationConnectionID: QUICConnectionID?
    public var sourceConnectionID: QUICConnectionID?
    public var token: [UInt8]
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICConnectionUtilities {
    public static func parseInboundPacket(
        _ buffer: UnsafeRawBufferPointer,
        shortHeaderDestinationCIDLength: Int?
    ) -> QUICRoutingHeader? {
        guard buffer.count >= Constants.minimumPacketSize else {
            Logger.proto.error("Buffer length < minimum packet size, len=\(buffer.count)")
            return nil
        }

        var dcidLength: Int = 0
        var scidLength: Int = 0
        var firstOctet: UInt8 = 0
        var rawVersion: UInt32 = 0
        var returnVersion: UInt32?
        var parsedDcidLength: UInt8 = 0
        var parsedScidLength: UInt8 = 0
        var retryToken: [UInt8] = []
        var retryPacket = false
        let result = Deserializer.deserialize(buffer.bytes) { read throws(DeserializationError) in
            try read.uint8(&firstOctet)
        }

        guard result.isValid else {
            Logger.proto.error("Unable to parse first octect")
            return nil
        }

        let longHeader = (firstOctet & 0x80) != 0
        var dcidStorage = QUICConnectionIDStorage.empty
        var scidStorage = QUICConnectionIDStorage.empty
        var destinationConnectionID: QUICConnectionID?
        var sourceConnectionID: QUICConnectionID?
        let packetType = PacketParser.PacketTypes(rawValue: (firstOctet & 0x30) >> 4)
        if longHeader {
            // Retry packet present
            switch packetType {
            case .Retry:
                retryPacket = true
            default:
                break
            }
            let result = Deserializer.deserialize(buffer.bytes) { read throws(DeserializationError) in
                try read.uint8(&firstOctet)
                try read.uint32NetworkByteOrder(&rawVersion)
                try read.uint8(&parsedDcidLength)
                try read.connectionID(&dcidStorage, length: Int(parsedDcidLength))
                try read.uint8(&parsedScidLength)
                try read.connectionID(&scidStorage, length: Int(parsedScidLength))
                if retryPacket {
                    // Calculate the length of the retry token
                    // For firstOctet, version, and DCID length and SCID length for retry packet
                    let staticHeaderBytes =
                        MemoryLayout<UInt8>.size + MemoryLayout<UInt32>.size
                        + (2 * MemoryLayout<UInt8>.size)
                    // Header bytes plus the size of the DCID and SCID
                    let expectedLongHeaderLength =
                        UInt8(staticHeaderBytes) + parsedDcidLength + parsedScidLength
                    // Compute the length minus the header, padding, and integrity tag
                    let retryTokenLength =
                        Int(buffer.count) - Int(expectedLongHeaderLength)
                        - Int(Constants.retryTokenIntegrityTagLength)
                    if retryTokenLength > 0 {
                        try read.buffer(&retryToken, length: retryTokenLength)
                    }
                }
            }
            guard result.isValid else {
                Logger.proto.error("Unable to parse long header")
                return nil
            }
            returnVersion = rawVersion
            dcidLength = Int(parsedDcidLength)

            scidLength = Int(parsedScidLength)
            destinationConnectionID = QUICConnectionID(storage: dcidStorage, size: Int(dcidLength))
            sourceConnectionID = QUICConnectionID(storage: scidStorage, size: Int(scidLength))

        } else {  // shortheader
            // incoming destination cid must be the currently active source cid for this path
            guard let shortHeaderDestinationCIDLength = shortHeaderDestinationCIDLength else {
                Logger.proto.error("Bad short header: unknown incoming cid length")
                return nil
            }
            let fixed = (firstOctet & 0x40) != 0
            dcidLength = shortHeaderDestinationCIDLength

            if _slowPath(!fixed) {
                Logger.proto.error("Bad short header: fixed bit is zero")
                return nil
            }

            let result = Deserializer.deserialize(buffer.bytes) { read throws(DeserializationError) in
                try read.uint8(&firstOctet)
                try read.connectionID(&dcidStorage, length: Int(dcidLength))
            }
            guard result.isValid else {
                Logger.proto.error("Unable to deserialize destination CID")
                return nil
            }
            destinationConnectionID = QUICConnectionID(storage: dcidStorage, size: Int(dcidLength))
        }

        return QUICRoutingHeader(
            type: packetType?.rawValue,
            version: returnVersion,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            token: retryToken
        )
    }

    /// Creates a stateless reset packet from the given token and length.
    ///
    /// - Parameters:
    ///     - token: The stateless reset token to send.
    ///     - triggeringPacketLength: The size of the packet that caused this stateless reset token to be sent.
    public static func createStatelessResetPacket(
        token: QUICStatelessResetToken,
        triggeringPacketLength: Int
    ) throws(NetworkError) -> [UInt8] {

        guard token.token.count > 0, triggeringPacketLength > 0 else {
            throw NetworkError(
                category: .init(
                    identifier: "QUICUtilities",
                    description: "Failed to provide valid input: \(token), \(triggeringPacketLength)"
                )
            )
        }
        // An endpoint MUST ensure that every Stateless Reset that it sends is smaller than the packet that triggered it
        let totalLength = triggeringPacketLength
        var unpredictableBytesOverride: Int = 22  // Default unpredictable Bytes (Total size 38 bytes)
        if QUICStatelessResetPacket.unpredictableBytes + token.token.count > totalLength {
            // Make sure the new Stateless Reset packet is smaller by adjusting unpredictableBytes stored after the short header.
            // For example, if the received packet was of size 36, the Stateless Reset packet needs to be size 35 (or smaller).
            let overLength =
                (QUICStatelessResetPacket.unpredictableBytes + token.token.count) - totalLength + 1
            unpredictableBytesOverride = QUICStatelessResetPacket.unpredictableBytes - overLength
        }
        guard
            let statelessReset = try? QUICStatelessResetPacket(
                resetToken: token.token,
                unpredictableBytes: unpredictableBytesOverride
            )
        else {
            throw NetworkError(
                category: .init(
                    identifier: "QUICUtilities",
                    description: "Failed to create QUICStatelessResetPacket"
                )
            )
        }
        guard statelessReset.bytes.count >= Constants.minimumPacketSize else {
            throw NetworkError(
                category: .init(
                    identifier: "QUICUtilities",
                    description: "Failed to create QUICStatelessResetPacket greater than the minimum packet size"
                )
            )
        }
        return statelessReset.bytes
    }

    /// Creates a version negotiation packet from the given SCID, DCID.
    /// NOTE: Includes the negotiation pattern already and the supported versions of the QUIC stack.
    /// NOTE: The DCID and SCID are swapped when building the packet.
    ///
    /// - Parameters:
    ///     - destinationConnectionID: The cid to include on the packet scid
    ///     - sourceConnectionID: The cid to include on the packet dcid
    public static func createVersionNegotiationPacket(
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID
    ) throws(NetworkError) -> [UInt8]? {
        let versions: [QUICVersion] = [.v1, .negotiationPattern]

        // Version Negotiation packets are special, they are not a specific frame type and they do not sealed so they can be sent as a one-off.
        // N.B.: The packet scid/dcid are swapped when constructing QUICVersionNegotiation
        guard
            let versionNegotiationPacket = try? QUICVersionNegotiation(
                destinationConnectionID: sourceConnectionID,
                sourceConnectionID: destinationConnectionID,
                supportedVersions: versions
            )
        else {
            throw NetworkError(
                category: .init(
                    identifier: "QUICUtilities",
                    description: "Failed to build a valid version negotiation packet"
                )
            )
        }
        guard versionNegotiationPacket.header.count >= Constants.minimumPacketSize else {
            throw NetworkError(
                category: .init(
                    identifier: "QUICUtilities",
                    description: "Failed to create QUICVersionNegotiation packet greater than the minimum packet size"
                )
            )

        }
        return versionNegotiationPacket.header
    }
}
#endif
