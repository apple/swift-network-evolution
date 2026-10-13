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

@available(Network 0.1.0, *)
private struct PacketFormatConstants {
    static let preambleLength = MemoryLayout<UInt8>.size
}

@available(Network 0.1.0, *)
extension QUICConnectionID {
    // number of bytes required to represent a Connection ID length on the wire
    static let headerCIDLength = 1
}

@available(Network 0.1.0, *)
enum QUICPacketFormatsError: Int, Error {
    case serializationBufferTooSmall
    case unexpectedLength
    case sealingFailure
}

@available(Network 0.1.0, *)
private func validateSerializationResult(_ result: SerializationResult) throws(QUICError) {
    guard result.isValid else {
        throw QUICError.packetFormats(QUICPacketFormatsError.serializationBufferTooSmall)
    }
}

// MARK: - Version Negotiation
@available(Network 0.1.0, *)
struct QUICVersionNegotiation: ~Copyable {
    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+
    // |1|  Unused (7) |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                          Version (32)                         |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // The `type' is a random number and `version' must be 0x00000000.
    let firstByte: UInt8 = 0x80
    let version: [UInt8] = [0, 0, 0, 0]

    // | DCID Len (8)  |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |               Destination Connection ID (0..2040)            ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // | SCID Len (8)  |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                 Source Connection ID (0..2040)               ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                    Supported Version 1 (32)                 ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                   [Supported Version 2 (32)]                ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                   [Supported Version N (32)]                ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //

    var header = [UInt8]()

    init(
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        supportedVersions: [QUICVersion]
    ) throws(QUICError) {

        let dcid = destinationConnectionID.connectionID
        let scid = sourceConnectionID.connectionID

        let expectedLength =
            PacketFormatConstants.preambleLength + version.count + QUICConnectionID.headerCIDLength
            + dcid.count + QUICConnectionID.headerCIDLength + scid.count + supportedVersions.count
            * QUICVersion.versionHeaderSize

        header = Serializer.serialize { write in
            write.uint8(firstByte)
            write.buffer(version)
            write.uint8(UInt8(dcid.count))
            write.buffer(dcid)
            write.uint8(UInt8(scid.count))
            write.buffer(scid)

            for element in supportedVersions {
                write.uint32NetworkByteOrder(element.rawValue)
            }
        }
        if expectedLength != header.count {
            throw QUICError.packetFormats(QUICPacketFormatsError.unexpectedLength)
        }
    }

    func serialize() -> [UInt8] {
        header
    }

    func write(outputFrame: inout Frame, claim: Bool) throws(QUICError) {
        let result = Serializer.serialize(&outputFrame, claim: claim) { write throws(SerializationError) in
            try write.buffer(header)
        }
        try validateSerializationResult(result)
    }
}

// Retry Packet
@available(Network 0.1.0, *)
struct QUICRetryPacket: ~Copyable {
    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+
    // |1|1| 3 | Unused|
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                         Version (32)                          |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // | DCID Len (8)  |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |               Destination Connection ID (0..160)            ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // | SCID Len (8)  |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                 Source Connection ID (0..160)               ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                        Retry Token (*)                      ...
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // +                                                               +
    // |                                                               |
    // +                   Retry Integrity Tag (128)                   +
    // |                                                               |
    // +                                                               +
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // Used for calculating the integrity tag on sent RETRY packets
    static let firstByte: UInt8 = 0xF0
    var header = [UInt8]()

    init(
        version: QUICVersion,
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        originalDCID: QUICConnectionID,
        token: [UInt8]
    ) throws(QUICError) {

        let dcid = destinationConnectionID.connectionID
        let scid = sourceConnectionID.connectionID

        var expectedLength =
            PacketFormatConstants.preambleLength + MemoryLayout<UInt32>.size
            + QUICConnectionID.headerCIDLength
            + dcid.count + QUICConnectionID.headerCIDLength + scid.count + token.count
        // Construct a RETRY pseudo header to calculate the integrity tag.
        let pseudoRetry = QUICPseudoRetry.assemble(
            firstByte: QUICRetryPacket.firstByte,
            version: version,
            destinationCID: destinationConnectionID,
            sourceCID: sourceConnectionID,
            originalDCID: originalDCID,
            token: token
        )
        do throws(QUICError) {
            let retryTag = try Protector.sealRetry(pseudoRetry.span.bytes)
            expectedLength += retryTag.count

            header = Serializer.serialize { write in
                write.uint8(QUICRetryPacket.firstByte)
                write.uint32NetworkByteOrder(version.rawValue)
                write.uint8(UInt8(dcid.count))
                write.buffer(dcid)
                write.uint8(UInt8(scid.count))
                write.buffer(scid)
                write.buffer(token)
                write.buffer(retryTag)
            }
            if expectedLength != header.count {
                throw QUICError.packetFormats(QUICPacketFormatsError.unexpectedLength)
            }
        } catch {
            throw QUICError.packetFormats(.sealingFailure)
        }
    }

    func write(outputFrame: inout Frame, claim: Bool) throws(QUICError) {
        let result = Serializer.serialize(&outputFrame, claim: claim) { write throws(SerializationError) in
            try write.buffer(header)
        }
        try validateSerializationResult(result)
    }
}

// https://www.rfc-editor.org/rfc/rfc9001.html#name-retry-packet-integrity
@available(Network 0.1.0, *)
struct QUICPseudoRetry: ~Copyable {
    static func assemble(
        firstByte: UInt8,
        version: QUICVersion,
        destinationCID: QUICConnectionID,
        sourceCID: QUICConnectionID,
        originalDCID: QUICConnectionID,
        token: [UInt8]
    ) -> [UInt8] {
        Serializer.serialize { serializer in
            serializer.connectionID(originalDCID)
            serializer.uint8(firstByte)
            serializer.uint32NetworkByteOrder(version.rawValue)
            serializer.connectionID(destinationCID)
            serializer.connectionID(sourceCID)
            serializer.buffer(token)
        }
    }
}

@available(Network 0.1.0, *)
struct QUICStatelessResetPacket: ~Copyable {

    // This design ensures that a Stateless Reset is -- to the extent possible -- indistinguishable from a regular packet with a short header
    // 0 1 2 3 4 5 6 7
    // +-+-+-+-+-+-+-+-+
    // |0|1| Unpredictable Bits (>= 38 bits) ...
    // +-+-+-+-+-+-+-+-+...
    // |          Unpredictable Bits           ...
    // +-+-+-+-+-+-+-+-+...
    // |          Stateless Reset Token (128 bits)
    // +-+-+-+-+-+-+-+-+...

    static let shortHeaderFixedBits: UInt8 = 0x40  // 01000000 - proper short header pattern
    static let randomBitsMask: UInt8 = 0x3F  // 00111111 - preserve random bits

    // First two bits are for short header distinction, the rest are random, followed by the token.
    // 22 is the max unpredictable bytes, subject to override depending upon how large the triggering packet was.
    static let unpredictableBytes: Int = 22

    // The resulting minimum size of 21 bytes does not guarantee that a Stateless Reset is difficult to
    // distinguish from other packets if the recipient requires the use of a connection ID.
    // To achieve that end, the endpoint SHOULD ensure that all packets it sends are at least 22 bytes
    // longer than the minimum connection ID length that it requests the peer to include in its packets,
    // adding PADDING frames as necessary. This ensures that any Stateless Reset sent by the peer is
    // indistinguishable from a valid packet sent to the endpoint.

    var bytes = [UInt8]()

    init(resetToken: [UInt8], unpredictableBytes: Int = Self.unpredictableBytes) throws(QUICError) {
        guard resetToken.count == Constants.statelessResetTokenSize else {
            Logger.proto.error("Stateless reset token not the correct size")
            throw QUICError.packetFormats(QUICPacketFormatsError.unexpectedLength)
        }
        guard unpredictableBytes >= 5 else {
            Logger.proto.error("Unpredictable bytes need to be at least 5 bytes in length")
            throw QUICError.packetFormats(QUICPacketFormatsError.unexpectedLength)
        }
        // Ensure we have at least 38 unpredictable bits (~5 bytes minimum)
        var unpredictableByteData: [UInt8] = Array(repeating: 0, count: unpredictableBytes)
        var randomNumberGenerator = SystemRandomNumberGenerator()
        for i in 0..<unpredictableBytes {
            unpredictableByteData[i] = UInt8.random(
                in: 0..<UInt8.max,
                using: &randomNumberGenerator
            )
        }
        // Set proper short header format: first bit = 0, second bit = 1, keep remaining 6 bits random
        unpredictableByteData[0] =
            (unpredictableByteData[0] & Self.randomBitsMask) | Self.shortHeaderFixedBits

        bytes = Serializer.serialize { write in
            write.buffer(unpredictableByteData)
            write.buffer(resetToken)
        }
        if bytes.count != unpredictableBytes + resetToken.count {
            throw QUICError.packetFormats(QUICPacketFormatsError.unexpectedLength)
        }
    }

    func serialize() -> [UInt8] {
        bytes
    }

    func write(outputFrame: inout Frame, claim: Bool) throws(QUICError) {
        let result = Serializer.serialize(&outputFrame, claim: claim) { write throws(SerializationError) in
            try write.buffer(bytes)
        }
        try validateSerializationResult(result)
    }
}
#endif
