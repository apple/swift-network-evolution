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
struct QUICVersionNegotiationPacket: ~Copyable {
    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+
    // |1|  Unused (7) |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                          Version (32)                         |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
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
    // The `type' is a random number and `version' must be 0x00000000.
    let firstByte: UInt8
    let version: [UInt8] = [0, 0, 0, 0]
    let destinationConnectionID: QUICConnectionID
    let sourceConnectionID: QUICConnectionID
    let supportedVersions: [QUICVersion]

    var length: Int {
        PacketFormatConstants.preambleLength + version.count
            + QUICConnectionID.headerCIDLength + destinationConnectionID.length
            + QUICConnectionID.headerCIDLength + sourceConnectionID.length
            + supportedVersions.count * QUICVersion.versionHeaderSize
    }
    // For outgoing packets.
    init(
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        supportedVersions: [QUICVersion]
    ) {
        // Only the long header bit is required, but RFC 9000 Section 17.2.1
        // says servers SHOULD also set 0x40 so VN packets appear to have the
        // Fixed Bit when QUIC is multiplexed with other protocols.
        self.init(
            firstByte: 0xC0 | (UInt8.random(in: .min ... .max) & 0x3F),
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            supportedVersions: supportedVersions
        )
    }

    // For incoming packets. Keeps the first byte as received on the wire.
    init(
        firstByte: UInt8,
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        supportedVersions: [QUICVersion]
    ) {
        self.firstByte = firstByte
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.supportedVersions = supportedVersions
    }

    private func write<F: SerializerSpanFactory & ~Copyable & ~Escapable>(
        into write: inout InPlaceSerializer<F>
    ) throws(SerializationError) {
        try write.uint8(firstByte)
        try write.buffer(version)
        try write.connectionID(destinationConnectionID)
        try write.connectionID(sourceConnectionID)
        for element in supportedVersions {
            try write.uint32NetworkByteOrder(element.rawValue)
        }
    }

    func write(outputFrame: inout Frame, claim: Bool) throws(QUICError) {
        let result = Serializer.serialize(&outputFrame, claim: claim) { w throws(SerializationError) in
            try self.write(into: &w)
        }
        try validateSerializationResult(result)
    }

    func serialize() throws(QUICError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let result = Serializer.serialize(bytes.mutableSpan) { w throws(SerializationError) in
            try self.write(into: &w)
        }
        try validateSerializationResult(result)
        return bytes
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
    // Long header, fixed bit and the Retry packet type. The low 4 bits are unused.
    static let firstByteBase: UInt8 = 0xF0
    static let unusedBitsMask: UInt8 = 0x0F

    let firstByte: UInt8
    let version: QUICVersion
    let destinationConnectionID: QUICConnectionID
    let sourceConnectionID: QUICConnectionID
    let token: [UInt8]
    let retryTag: [UInt8]

    var length: Int {
        PacketFormatConstants.preambleLength + QUICVersion.versionHeaderSize
            + QUICConnectionID.headerCIDLength + destinationConnectionID.length
            + QUICConnectionID.headerCIDLength + sourceConnectionID.length
            + token.count + retryTag.count
    }

    // For outgoing packets. Computes the integrity tag over the pseudo-packet
    // that includes the DCID of the client's first Initial packet.
    init(
        version: QUICVersion = .v1,
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        originalDCID: QUICConnectionID,
        token: [UInt8]
    ) throws(QUICError) {
        let firstByte = Self.firstByteBase | (UInt8.random(in: .min ... .max) & Self.unusedBitsMask)
        let pseudoRetry = QUICPseudoRetry.assemble(
            firstByte: firstByte,
            version: version,
            destinationCID: destinationConnectionID,
            sourceCID: sourceConnectionID,
            originalDCID: originalDCID,
            token: token
        )
        do throws(QUICError) {
            self.retryTag = try Protector.sealRetry(pseudoRetry.span.bytes)
        } catch {
            throw QUICError.packetFormats(.sealingFailure)
        }
        self.firstByte = firstByte
        self.version = version
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.token = token
    }

    // For incoming packets. The first byte must be the one received on the
    // wire because the unused bits are covered by the integrity tag.
    init(
        firstByte: UInt8,
        version: QUICVersion,
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        token: [UInt8],
        retryTag: [UInt8]
    ) {
        self.firstByte = firstByte
        self.version = version
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.token = token
        self.retryTag = retryTag
    }

    private func write<F: SerializerSpanFactory & ~Copyable & ~Escapable>(
        into write: inout InPlaceSerializer<F>
    ) throws(SerializationError) {
        try write.uint8(firstByte)
        try write.uint32NetworkByteOrder(version.rawValue)
        try write.connectionID(destinationConnectionID)
        try write.connectionID(sourceConnectionID)
        try write.buffer(token)
        try write.buffer(retryTag)
    }

    func write(outputFrame: inout Frame, claim: Bool) throws(QUICError) {
        let result = Serializer.serialize(&outputFrame, claim: claim) { w throws(SerializationError) in
            try self.write(into: &w)
        }
        try validateSerializationResult(result)
    }

    func serialize() throws(QUICError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let result = Serializer.serialize(bytes.mutableSpan) { w throws(SerializationError) in
            try self.write(into: &w)
        }
        try validateSerializationResult(result)
        return bytes
    }

    // Verifies the integrity tag. `originalDCID` is the DCID the client used
    // in its first Initial packet.
    func open(originalDCID: QUICConnectionID) -> Bool {
        guard retryTag.count == Int(Constants.retryTokenIntegrityTagLength) else {
            return false
        }
        let pseudoRetry = QUICPseudoRetry.assemble(
            firstByte: firstByte,
            version: version,
            destinationCID: destinationConnectionID,
            sourceCID: sourceConnectionID,
            originalDCID: originalDCID,
            token: token
        )
        do throws(QUICError) {
            try Protector.openRetry(retryPseudo: pseudoRetry.span.bytes, retryTag: retryTag.span.bytes)
            return true
        } catch {
            return false
        }
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
