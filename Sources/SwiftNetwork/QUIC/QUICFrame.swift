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

// MARK: - QUIC Frames

@available(Network 0.1.0, *)
enum QUICFrame: ~Copyable {
    case padding(frame: FramePadding)
    case ping(frame: FramePing)
    case ack(frame: FrameAck)
    case resetStream(frame: FrameResetStream)
    case stopSending(frame: FrameStopSending)
    case crypto(frame: FrameCrypto)
    case newToken(frame: FrameNewToken)
    case stream(frame: FrameStreamReceived)
    case streamSend(frame: FrameStreamSendMetadata)
    // stream with flags 0x09-0x0f
    case maxData(frame: FrameMaxData)
    case maxStreamData(frame: FrameMaxStreamData)
    case maxStreamsBidirectional(frame: FrameMaxStreamsBidirectional)
    case maxStreamsUnidirectional(frame: FrameMaxStreamsUnidirectional)
    case dataBlocked(frame: FrameDataBlocked)
    case streamDataBlocked(frame: FrameStreamDataBlocked)
    case streamsBlockedBidirectional(frame: FrameStreamsBlockedBidirectional)
    case streamsBlockedUnidirectional(frame: FrameStreamsBlockedUnidirectional)
    case newConnectionID(frame: FrameNewConnectionID)
    case retireConnectionID(frame: FrameRetireConnectionID)
    case pathChallenge(frame: FramePathChallenge)
    case pathResponse(frame: FramePathResponse)
    case connectionClose(frame: FrameConnectionClose)
    case applicationClose(frame: FrameApplicationClose)
    case handshakeDone(frame: FrameHandshakeDone)

    /* RFC 9221 */
    case datagram(frame: FrameDatagram)

    @inline(always)
    static func isAckEliciting(frame: borrowing QUICFrame) -> Bool {
        switch frame {
        case .padding:
            return false
        case .ack:
            return false
        case .connectionClose:
            return false
        case .applicationClose:
            return false
        default:
            return true
        }
    }

    // Packets are considered in flight when they are ack-eliciting or contain a PADDING frame.
    // So isInFlightEligible is basically the same as isAckEliciting(), but also returns true for PADDING frames.
    static func isInFlightEligible(frame: borrowing QUICFrame) -> Bool {
        switch frame {
        case .ack:
            return false
        case .connectionClose:
            return false
        case .applicationClose:
            return false
        default:
            return true
        }
    }

    @inline(always)
    static func isProbing(frame: borrowing QUICFrame) -> Bool {
        switch frame {
        case .padding:
            return true
        case .pathChallenge:
            return true
        case .pathResponse:
            return true
        case .newConnectionID:
            return true
        default:
            return false
        }
    }

    @inline(always)
    static func isAllowedDuringHandshake(frame: borrowing QUICFrame) -> Bool {
        // N.B.: APPLICATION_CLOSE is NOT allowed during the handshake.
        switch frame {
        case .ack:
            return true
        case .crypto:
            return true
        case .ping:
            return true
        case .padding:
            return true
        case .connectionClose:
            return true
        default:
            return false
        }
    }

    @inline(always)
    static func isValidInInitial(frame: borrowing QUICFrame) -> Bool {
        // Returns true if the frame is valid in an INITIAL packet.
        switch frame {
        case .ack:
            return true
        case .crypto:
            return true
        case .ping:
            return true
        case .padding:
            return true
        case .connectionClose:
            return true
        default:
            return false
        }
    }

    static func parse(
        type: FrameType,
        frame: inout Frame,
        packet: inout Packet,
        connection: QUICConnection,
        isLastPacketInFrame: Bool = true
    ) throws(QUICError) -> QUICFrame {
        switch type {
        case .padding:
            return try FramePadding.parse(
                frame: &frame,
                packetNumberSpace: packet.numberSpace,
                shorthandFrames: &packet.shorthandFrames
            )
        case .ping:
            return try FramePing.parse(
                frame: &frame,
                packetNumberSpace: packet.numberSpace,
                shorthandFrames: &packet.shorthandFrames
            )
        case .ack:
            return try FrameAck.parse(
                frame: &frame,
                packetNumberSpace: packet.numberSpace,
                shorthandFrames: &packet.shorthandFrames
            )
        case .ackECN:
            return try FrameAck.parse(
                frame: &frame,
                packetNumberSpace: packet.numberSpace,
                shorthandFrames: &packet.shorthandFrames
            )
        case .resetStream:
            return try FrameResetStream.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .stopSending:
            return try FrameStopSending.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .crypto:
            return try FrameCrypto.parse(
                frame: &frame,
                packetNumberSpace: packet.numberSpace,
                isLastPacketInFrame: isLastPacketInFrame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .newToken:
            return try FrameNewToken.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .stream:
            return try FrameStreamReceived.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .maxData:
            return try FrameMaxData.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .maxStreamData:
            return try FrameMaxStreamData.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .maxStreamsBidirectional:
            return try FrameMaxStreamsBidirectional.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .maxStreamsUnidirectional:
            return try FrameMaxStreamsUnidirectional.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .dataBlocked:
            return try FrameDataBlocked.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .streamDataBlocked:
            return try FrameStreamDataBlocked.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .streamsBlockedBidirectional:
            return try FrameStreamsBlockedBidirectional.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .streamsBlockedUnidirectional:
            return try FrameStreamsBlockedUnidirectional.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .newConnectionID:
            return try FrameNewConnectionID.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .retireConnectionID:
            return try FrameRetireConnectionID.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .pathChallenge:
            return try FramePathChallenge.parse(
                frame: &frame,
                destinationConnectionID: packet.destinationConnectionID!,
                shorthandFrames: &packet.shorthandFrames
            )
        case .pathResponse:
            return try FramePathResponse.parse(
                frame: &frame,
                destinationConnectionID: packet.destinationConnectionID!,
                shorthandFrames: &packet.shorthandFrames
            )
        case .connectionClose:
            return try FrameConnectionClose.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .applicationClose:
            return try FrameApplicationClose.parse(
                frame: &frame,
                stats: &connection.stats,
                shorthandFrames: &packet.shorthandFrames
            )
        case .handshakeDone:
            return try FrameHandshakeDone.parse(
                frame: &frame,
                shorthandFrames: &packet.shorthandFrames
            )
        case .datagram:
            return try FrameDatagram.parse(
                frame: &frame,
                useFlowID: connection.datagramEnableFlowID,
                useContextID: connection.datagramUseContextID,
                connection: connection,
                shorthandFrames: &packet.shorthandFrames
            )
        }
    }

    var frameType: FrameType {
        switch self {
        case .padding: return FrameType.padding
        case .ping: return FrameType.ping
        case .ack: return FrameType.ack
        case .resetStream: return FrameType.resetStream
        case .stopSending: return FrameType.stopSending
        case .crypto: return FrameType.crypto
        case .newToken: return FrameType.newToken
        case .stream: return FrameType.stream()
        case .streamSend: return FrameType.stream()
        case .maxData: return FrameType.maxData
        case .maxStreamData: return FrameType.maxStreamData
        case .maxStreamsBidirectional: return FrameType.maxStreamsBidirectional
        case .maxStreamsUnidirectional: return FrameType.maxStreamsUnidirectional
        case .dataBlocked: return FrameType.dataBlocked
        case .streamDataBlocked: return FrameType.streamDataBlocked
        case .streamsBlockedBidirectional: return FrameType.streamsBlockedBidirectional
        case .streamsBlockedUnidirectional: return FrameType.streamsBlockedUnidirectional
        case .newConnectionID: return FrameType.newConnectionID
        case .retireConnectionID: return FrameType.retireConnectionID
        case .pathChallenge: return FrameType.pathChallenge
        case .pathResponse: return FrameType.pathResponse
        case .connectionClose: return FrameType.connectionClose
        case .applicationClose: return FrameType.applicationClose
        case .handshakeDone: return FrameType.handshakeDone
        case .datagram: return FrameType.datagram()
        }
    }
}
// MARK: - QUIC Frame Types

@available(Network 0.1.0, *)
enum FrameType: RawRepresentable, CaseIterable, Equatable {
    static let paddingCode: UInt64 = 0x00
    static let pingCode: UInt64 = 0x01
    static let ackCode: UInt64 = 0x02
    static let ackECNCode: UInt64 = 0x03
    static let resetStreamCode: UInt64 = 0x04
    static let stopSendingCode: UInt64 = 0x05
    static let cryptoCode: UInt64 = 0x06
    static let newTokenCode: UInt64 = 0x07
    static let streamCodes: ClosedRange<UInt64> = 0x08...0x0f
    static let maxDataCode: UInt64 = 0x10
    static let maxStreamDataCode: UInt64 = 0x11
    static let maxStreamsBidirectionalCode: UInt64 = 0x12
    static let maxStreamsUnidirectionalCode: UInt64 = 0x13
    static let dataBlockedCode: UInt64 = 0x14
    static let streamDataBlockedCode: UInt64 = 0x15
    static let streamsBlockedBidirectionalCode: UInt64 = 0x16
    static let streamsBlockedUnidirectionalCode: UInt64 = 0x17
    static let newConnectionIDCode: UInt64 = 0x18
    static let retireConnectionIDCode: UInt64 = 0x19
    static let pathChallengeCode: UInt64 = 0x1a
    static let pathResponseCode: UInt64 = 0x1b
    static let connectionCloseCode: UInt64 = 0x1c
    static let applicationCloseCode: UInt64 = 0x1d
    static let handshakeDoneCode: UInt64 = 0x1e

    static let datagramCode: UInt64 = 0x30
    static let datagramWithLengthCode: UInt64 = 0x31

    /* RFC 9000 */
    case padding
    case ping
    case ack
    case ackECN
    case resetStream
    case stopSending
    case crypto
    case newToken
    case stream(flag: FrameStreamFlag = 0)
    case maxData
    case maxStreamData
    case maxStreamsBidirectional
    case maxStreamsUnidirectional
    case dataBlocked
    case streamDataBlocked
    case streamsBlockedBidirectional
    case streamsBlockedUnidirectional
    case newConnectionID
    case retireConnectionID
    case pathChallenge
    case pathResponse
    case connectionClose
    case applicationClose
    case handshakeDone

    /* RFC 9221 */
    case datagram(hasLength: Bool = false)

    init?(rawValue: UInt64) {
        switch rawValue {
        case FrameType.paddingCode:
            self = .padding
        case FrameType.pingCode:
            self = .ping
        case FrameType.ackCode:
            self = .ack
        case FrameType.ackECNCode:
            self = .ackECN
        case FrameType.resetStreamCode:
            self = .resetStream
        case FrameType.stopSendingCode:
            self = .stopSending
        case FrameType.cryptoCode:
            self = .crypto
        case FrameType.newTokenCode:
            self = .newToken
        case FrameType.streamCodes:
            self = .stream(flag: FrameStreamFlag(rawValue - FrameType.streamCodes.lowerBound))
        case FrameType.maxDataCode:
            self = .maxData
        case FrameType.maxStreamDataCode:
            self = .maxStreamData
        case FrameType.maxStreamsBidirectionalCode:
            self = .maxStreamsBidirectional
        case FrameType.maxStreamsUnidirectionalCode:
            self = .maxStreamsUnidirectional
        case FrameType.dataBlockedCode:
            self = .dataBlocked
        case FrameType.streamDataBlockedCode:
            self = .streamDataBlocked
        case FrameType.streamsBlockedBidirectionalCode:
            self = .streamsBlockedBidirectional
        case FrameType.streamsBlockedUnidirectionalCode:
            self = .streamsBlockedUnidirectional
        case FrameType.newConnectionIDCode:
            self = .newConnectionID
        case FrameType.retireConnectionIDCode:
            self = .retireConnectionID
        case FrameType.pathChallengeCode:
            self = .pathChallenge
        case FrameType.pathResponseCode:
            self = .pathResponse
        case FrameType.connectionCloseCode:
            self = .connectionClose
        case FrameType.applicationCloseCode:
            self = .applicationClose
        case FrameType.handshakeDoneCode:
            self = .handshakeDone
        case FrameType.datagramCode:
            self = .datagram(hasLength: false)
        case FrameType.datagramWithLengthCode:
            self = .datagram(hasLength: true)
        default:
            return nil
        }
    }

    var rawValue: UInt64 {
        switch self {
        case .padding:
            return FrameType.paddingCode
        case .ping:
            return FrameType.pingCode
        case .ack:
            return FrameType.ackCode
        case .ackECN:
            return FrameType.ackECNCode
        case .resetStream:
            return FrameType.resetStreamCode
        case .stopSending:
            return FrameType.stopSendingCode
        case .crypto:
            return FrameType.cryptoCode
        case .newToken:
            return FrameType.newTokenCode
        case .stream(let flag):
            return FrameType.streamCodes.lowerBound + flag.rawValue
        case .maxData:
            return FrameType.maxDataCode
        case .maxStreamData:
            return FrameType.maxStreamDataCode
        case .maxStreamsBidirectional:
            return FrameType.maxStreamsBidirectionalCode
        case .maxStreamsUnidirectional:
            return FrameType.maxStreamsUnidirectionalCode
        case .dataBlocked:
            return FrameType.dataBlockedCode
        case .streamDataBlocked:
            return FrameType.streamDataBlockedCode
        case .streamsBlockedBidirectional:
            return FrameType.streamsBlockedBidirectionalCode
        case .streamsBlockedUnidirectional:
            return FrameType.streamsBlockedUnidirectionalCode
        case .newConnectionID:
            return FrameType.newConnectionIDCode
        case .retireConnectionID:
            return FrameType.retireConnectionIDCode
        case .pathChallenge:
            return FrameType.pathChallengeCode
        case .pathResponse:
            return FrameType.pathResponseCode
        case .connectionClose:
            return FrameType.connectionCloseCode
        case .applicationClose:
            return FrameType.applicationCloseCode
        case .handshakeDone:
            return FrameType.handshakeDoneCode
        case .datagram(let hasLength):
            return hasLength ? FrameType.datagramWithLengthCode : FrameType.datagramCode
        }
    }

    static let allCases: [FrameType] = [
        .padding, .ping, .ack, .ackECN, .resetStream, .stopSending, .crypto, .newToken, .stream(),
        .maxData, .maxStreamData, .maxStreamsBidirectional, .maxStreamsUnidirectional, .dataBlocked,
        .streamDataBlocked, .streamsBlockedBidirectional, .streamsBlockedUnidirectional,
        .newConnectionID, .retireConnectionID, .pathChallenge, .pathResponse, .connectionClose,
        .applicationClose, .handshakeDone, .datagram(),
    ]

    var isOneByte: Bool {
        true
    }
}

@available(Network 0.1.0, *)
extension FrameType {
    func description() -> String {
        switch self {
        case .padding:
            return "PADDING"
        case .ping:
            return "PING"
        case .ack, .ackECN:
            return "ACK"
        case .resetStream:
            return "RESET_STREAM"
        case .stopSending:
            return "STOP_SENDING"
        case .crypto:
            return "CRYPTO"
        case .newToken:
            return "NEW_TOKEN"
        case .stream:
            return "STREAM"
        case .maxData:
            return "MAX_DATA"
        case .maxStreamData:
            return "MAX_STREAM_DATA"
        case .maxStreamsBidirectional:
            return "MAX_STREAMS_BIDI"
        case .maxStreamsUnidirectional:
            return "MAX_STREAMS_UNI"
        case .dataBlocked:
            return "DATA_BLOCKED"
        case .streamDataBlocked:
            return "STREAM_DATA_BLOCKED"
        case .streamsBlockedBidirectional:
            return "STREAMS_BLOCKED_BIDI"
        case .streamsBlockedUnidirectional:
            return "STREAMS_BLOCKED_UNI"
        case .newConnectionID:
            return "NEW_CONNECTION_ID"
        case .retireConnectionID:
            return "RETIRE_CONNECTION_ID"
        case .pathChallenge:
            return "PATH_CHALLENGE"
        case .pathResponse:
            return "PATH_RESPONSE"
        case .connectionClose:
            return "CONNECTION_CLOSE"
        case .applicationClose:
            return "APPLICATION_CLOSE"
        case .handshakeDone:
            return "HANDSHAKE_DONE"
        case .datagram(let hasLength):
            return hasLength ? "DATAGRAM_LEN" : "DATAGRAM"
        }
    }
}

@available(Network 0.1.0, *)
enum FrameParseError: Error {
    case parsingError
    case invalidType(UInt64)
    case invalidValue(String)

    func description() -> String {
        switch self {
        case .parsingError:
            return "Frame Parse: parsing error"
        case .invalidType(let type):
            return "Frame Parse: invalid type: \(type)"
        case .invalidValue(let value):
            return "Frame Parse: invalid value: \(value)"
        }
    }
}

@available(Network 0.1.0, *)
enum FrameWriteError: Int, Error {
    case smallBuffer
    case invalidTypeForSend
}

// MARK: - QUIC Frame Protocols
@available(Network 0.1.0, *)
protocol QUICFrameProtocol: ~Copyable {
    var type: FrameType { get }

    // All QUIC frames should have an init resembling the following:
    // init(frame: inout Frame, ...) throws(QUICError)

    // All QUIC frames should have an write function resembling one of the following:
    // func write(frame: inout Frame) throws(QUICError)
    // func write(frame: inout Frame, stats: inout Statistics?) throws(QUICError)
}

@available(Network 0.1.0, *)
extension QUICFrameProtocol {
    // Most frames don't do anything when they are acknowledged.
    func acknowledged() {}
}

@available(Network 0.1.0, *)
extension QUICFrameProtocol {
    // Common frame deserialization validation
    func validateDeserializationResult(_ result: DeserializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.frameParse(FrameParseError.parsingError)
        }
    }

    // Common frame serialization validation
    func validateSerializationResult(_ result: SerializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.frameWrite(.smallBuffer)
        }
    }

    static func validateSerializationResult(_ result: SerializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.frameWrite(.smallBuffer)
        }
    }

    // Common frame type validation
    func validateType(_ rawType: UInt64) throws(QUICError) {
        if rawType != type.rawValue {
            throw QUICError.frameParse(FrameParseError.invalidType(rawType))
        }
    }
}

@available(Network 0.1.0, *)
extension QUICFrameProtocol where Self: ~Copyable {
    // Common frame deserialization validation
    func validateDeserializationResult(_ result: DeserializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.frameParse(FrameParseError.parsingError)
        }
    }

    // Common frame serialization validation
    func validateSerializationResult(_ result: SerializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.frameWrite(.smallBuffer)
        }
    }

    static func validateSerializationResult(_ result: SerializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.frameWrite(.smallBuffer)
        }
    }

    // Common frame type validation
    func validateType(_ rawType: UInt64) throws(QUICError) {
        if rawType != type.rawValue {
            throw QUICError.frameParse(FrameParseError.invalidType(rawType))
        }
    }
}

// MARK: - Padding (0x00)

@available(Network 0.1.0, *)
struct FramePadding: ~Copyable, QUICFrameProtocol {
    let type = FrameType.padding

    private(set) var packetNumberSpace: PacketNumberSpace
    private(set) var extraPadding: Int?
    let isVariableLength: Bool

    static func parse(
        frame: inout Frame,
        packetNumberSpace: PacketNumberSpace,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FramePadding(frame: &frame, packetNumberSpace: packetNumberSpace)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.padding(frame: frame)
    }

    init(
        packetNumberSpace: PacketNumberSpace,
        padding: Int? = nil
    ) {
        if let padding {
            extraPadding = padding
            if padding > 0 {
                extraPadding! -= 1  // ! is ok, extraPadding was just set!
            }
            isVariableLength = false
        } else {
            isVariableLength = true
        }

        self.packetNumberSpace = packetNumberSpace
    }

    init(frame: inout Frame, packetNumberSpace: PacketNumberSpace) throws(QUICError) {
        self.packetNumberSpace = packetNumberSpace
        isVariableLength = false  // incoming padding frames are a fixed size

        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
        }

        guard result.isValid else {
            throw QUICError.frameParse(FrameParseError.parsingError)
        }

        try validateType(rawType)
        try countZeros(frame: &frame)
    }

    private mutating func countZeros(frame: inout Frame) throws(QUICError) {
        var extraPadding = 0

        if let bytes = frame.bytes {
            extraPadding = Self.countLeadingZeroBytes(bytes)
        }

        guard frame.claim(fromStart: extraPadding) else {
            throw QUICError.frameParse(FrameParseError.parsingError)
        }
        self.extraPadding = extraPadding
    }

    private static func countLeadingZeroBytes(_ bytes: RawSpan) -> Int {
        let count = bytes.byteCount
        let wordSize = MemoryLayout<UInt64>.size
        var offset = 0

        while offset &+ wordSize <= count {
            let word = bytes.unsafeLoadUnaligned(fromByteOffset: offset, as: UInt64.self)

            if word == 0 {
                offset &+= wordSize
            } else {
                return offset &+ (UInt64(littleEndian: word).trailingZeroBitCount / 8)
            }
        }

        while offset < count, bytes[offset] == 0x00 {
            offset &+= 1
        }

        return offset
    }

    static func write(frame: inout Frame, length: Int) throws(QUICError) {
        guard length >= 1 else {
            throw QUICError.frameWrite(FrameWriteError.smallBuffer)
        }
        let paddingBuffer = [UInt8](repeating: 0, count: length)
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            // Note: Padding type (0x00) is part of the pad
            try write.buffer(paddingBuffer)
        }
        try validateSerializationResult(result)
    }

    func process() -> Bool {
        // Nothing to process
        true
    }
}

// MARK: Ping (0x01)
@available(Network 0.1.0, *)
struct FramePing: ~Copyable, QUICFrameProtocol {
    let type = FrameType.ping

    private(set) var packetNumberSpace: PacketNumberSpace

    static func parse(
        frame: inout Frame,
        packetNumberSpace: PacketNumberSpace,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FramePing(frame: &frame, packetNumberSpace: packetNumberSpace)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.ping(frame: frame)
    }

    init(packetNumberSpace: PacketNumberSpace) {
        self.packetNumberSpace = packetNumberSpace
    }

    init(frame: inout Frame, packetNumberSpace: PacketNumberSpace) throws(QUICError) {
        self.packetNumberSpace = packetNumberSpace

        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    static func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.ping.rawValue)
        }

        try validateSerializationResult(result)
    }

    func process() -> Bool {
        // Nothing to process
        true
    }
}

// MARK: Ack (0x02-0x03)

@available(Network 0.1.0, *)
struct FrameAckRange {
    var gap: PacketNumber
    var range: PacketNumber
}

@available(Network 0.1.0, *)
struct FrameAck: QUICFrameProtocol {
    var type = FrameType.ack

    var packetNumberSpace: PacketNumberSpace

    var largest = PacketNumber.none

    // Cap ack delay value, which is in microseconds.
    // The cap avoids handling values of microseconds that
    // would cause overflows when turned into nanoseconds, etc.
    // Capping at UInt32.max microseconds makes this limited
    // to around 1.2 hours.
    private var _delay: UInt64 = 0
    static let maximumAllowedAckDelay = UInt64(UInt32.max)
    var delay: UInt64 {
        get { _delay }
        set {
            guard newValue <= FrameAck.maximumAllowedAckDelay else {
                _delay = FrameAck.maximumAllowedAckDelay
                return
            }
            _delay = newValue
        }
    }
    var ranges: [FrameAckRange]
    var pendingGap: PacketNumber?
    private var _ecnCounter: ECNCounter?
    var ecnCounter: ECNCounter? {
        get { _ecnCounter }
        set {
            if let newValue, !newValue.isEmpty {
                type = .ackECN
                _ecnCounter = newValue
            } else {
                type = .ack
                _ecnCounter = nil
            }
        }
    }

    static func parse(
        frame: inout Frame,
        packetNumberSpace: PacketNumberSpace,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameAck(frame: &frame, packetNumberSpace: packetNumberSpace)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.ack(frame: frame)
    }

    init(packetNumberSpace: PacketNumberSpace, largest: PacketNumber, delay: UInt64) {
        self.packetNumberSpace = packetNumberSpace
        self.ranges = .init()
        self.ranges.reserveCapacity(4)
        self.largest = largest
        self.delay = delay
    }

    init(
        packetNumberSpace: PacketNumberSpace,
        largest: PacketNumber,
        delay: UInt64,
        ranges: [FrameAckRange]
    ) {
        self.init(packetNumberSpace: packetNumberSpace, largest: largest, delay: delay)
        self.ranges = ranges
    }

    private mutating func validateAckType(_ rawType: UInt64) throws(QUICError) {
        if rawType == FrameType.ack.rawValue {
            type = FrameType.ack
        } else if rawType == FrameType.ackECN.rawValue {
            type = FrameType.ackECN
        } else {
            throw QUICError.frameParse(FrameParseError.invalidType(rawType))
        }
    }

    init(frame: inout Frame, packetNumberSpace: PacketNumberSpace) throws(QUICError) {
        self.packetNumberSpace = packetNumberSpace
        self.ranges = .init()
        var rawType: UInt64 = 0
        var rangeCount: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&largest.value)
            try read.vle(&delay)
            try read.vle(&rangeCount)
        }
        try validateDeserializationResult(result)

        try validateAckType(rawType)

        guard rangeCount <= 1024 else {
            throw QUICError.frameParse(
                FrameParseError.invalidValue("excessive ACK range: \(rangeCount)")
            )
        }

        ranges = [FrameAckRange](
            repeating: FrameAckRange(gap: 0, range: 0),
            count: Int(rangeCount + 1)
        )

        let rangeResult = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&ranges[0].range.value)
            if ranges.count > 1 {
                for i in 1..<ranges.count {
                    try read.vle(&ranges[i].gap.value)
                    try read.vle(&ranges[i].range.value)
                }
            }
        }
        try validateDeserializationResult(rangeResult)

        if type == .ackECN {
            // Parse ECN-specific fields
            var ecnCounter = ECNCounter(ect0: 0, ect1: 0, ce: 0)
            let ecnResult = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                try read.vle(&ecnCounter.ect0)
                try read.vle(&ecnCounter.ect1)
                try read.vle(&ecnCounter.ce)
            }
            try validateDeserializationResult(ecnResult)
            self.ecnCounter = ecnCounter
        }
    }

    var writeLength: Int {
        Serializer.length { write in
            write.vle(type.rawValue)
            write.vle(largest.value)
            write.vle(delay)
            if ranges.count == 0 {
                write.vle(0)
                write.vle(0)
            } else {
                write.vle(ranges.count - 1)
                write.vle(ranges[0].range.value)
                for i in 1..<ranges.count {
                    write.vle(ranges[i].gap.value)
                    write.vle(ranges[i].range.value)
                }
            }
            if let ecnCounter {
                write.vle(ecnCounter.ect0)
                write.vle(ecnCounter.ect1)
                write.vle(ecnCounter.ce)
            }
        }
    }

    func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(type.rawValue)
            try write.vle(largest.value)
            try write.vle(delay)
            if ranges.count == 0 {
                try write.vle(0)
                try write.vle(0)
            } else {
                try write.vle(ranges.count - 1)
                try write.vle(ranges[0].range.value)
                for i in 1..<ranges.count {
                    try write.vle(ranges[i].gap.value)
                    try write.vle(ranges[i].range.value)
                }
            }
            if let ecnCounter {
                try write.vle(ecnCounter.ect0)
                try write.vle(ecnCounter.ect1)
                try write.vle(ecnCounter.ce)
            }
        }
        try validateSerializationResult(result)
    }

    mutating func addRange(gap: PacketNumber = .initial, range: PacketNumber) {
        if let pendingGap = pendingGap {
            ranges.append(FrameAckRange(gap: pendingGap, range: range))
            self.pendingGap = nil
        } else {
            ranges.append(FrameAckRange(gap: .initial, range: range))
        }
        if gap != 0 {
            pendingGap = gap
        } else {
            pendingGap = nil
        }
    }

    mutating func setDelay(_ delay: UInt64) {
        self.delay = delay
    }
}

// MARK: Reset Stream (0x04)

@available(Network 0.1.0, *)
struct FrameResetStream: ~Copyable, QUICFrameProtocol {
    let type = FrameType.resetStream

    private(set) var id: UInt64 = 0
    private(set) var code: UInt64 = 0
    private(set) var finalSize: UInt64 = 0

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameResetStream(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.resetStream(frame: frame)
    }

    init(id: UInt64, code: UInt64, finalSize: UInt64) {
        self.id = id
        self.code = code
        self.finalSize = finalSize
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&id)
            try read.vle(&code)
            try read.vle(&finalSize)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        stats.increment(.rxStreamResetFrames)
    }

    static func write(
        frame: inout Frame,
        id: UInt64,
        code: UInt64,
        finalSize: UInt64,
        stats: inout Statistics
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.resetStream.rawValue)
            try write.vle(id)
            try write.vle(code)
            try write.vle(finalSize)
        }

        try validateSerializationResult(result)

        stats.increment(.txStreamResetFrames)
    }

    func process(connection: QUICConnection) -> Bool {
        guard let streamID = QUICStreamID(self.id) else {
            let idValue = self.id
            Logger.proto.error("Stream frame with invalid stream ID \(idValue)")
            return false
        }
        // An endpoint that receives a RESET_STREAM frame for a
        // send-only stream MUST terminate the connection with error
        // STREAM_STATE_ERROR.
        if streamID.isSendOnly(server: connection.isServer) {
            Logger.proto.error(
                "RESET_STREAM received for send-only stream \(streamID.value)"
            )
            connection.close(with: .streamStateError, "RESET_STREAM for send-only stream")
            return false
        }

        let stream: QUICStreamInstance
        if let flowID = connection.knownFlows[streamID] {
            // The stream id is known. The flow object may still be missing
            // if the stream was torn down without clearing `knownFlows`; in
            // that case there is no one to deliver the reset to, so drop it.
            guard let existing = connection.flow(for: flowID) else {
                Logger.proto.error(
                    "stream \(streamID.value) has known flow but no QUICStreamInstance; dropping RESET_STREAM"
                )
                return true
            }
            stream = existing

        } else {
            // RESET_STREAM may be the first frame the peer sends on a stream
            // createInboundStreams will register it.
            let inboundStreamResult = connection.createInboundStreams(streamID: streamID)
            if inboundStreamResult.checkZombie {
                connection.zombieStreamListFinalSizeReceived(
                    streamID: streamID,
                    finalSize: self.finalSize
                )
                return true
            }
            if !inboundStreamResult.created {
                // The stream is being ignored. createInboundStreams already
                // drove any required peer notification or close, so treat the
                // frame as handled.
                return true
            }
            guard let flowID = connection.knownFlows[streamID],
                let created = connection.flow(for: flowID)
            else {
                Logger.proto.error(
                    "Stream \(streamID.value) is not a QUICStreamInstance after createInboundStreams"
                )
                return true
            }
            stream = created
        }
        // Set the application error code
        stream.streamMetadata.applicationError = self.code
        stream.inboundApplicationError = self.code
        connection.deliverInboundAbortedEvent(stream: stream, error: NetworkError(quicApplicationError: self.code))
        connection.log.info(
            "[S\(streamID.value)] received RESET_STREAM; offsets conn (inorder \(stream.receiveState), last \(connection.flowControlState.totalInOrderInboundBytesRead)), stream (inorder \(stream.flowControlState.totalInOrderInboundBytesRead), last \(stream.lastReceivedOffset)), final \(self.finalSize)"
        )

        // If the final size of the stream being reset is beyond the total in-order
        // stream size, update the flow control counters to account for the final lengths.
        // This does not need to consult the reassembly queue or ensure that bytes are in
        // fact available.
        if !stream.resetReceived, stream.flowControlState.totalInOrderInboundBytesRead < self.finalSize {

            // Don't increase the stream in-order value, so that
            // if the gaps in the stream will be filled by
            // out-of-order STREAM frames, the application will
            // be able to read as much of the stream as possible.
            stream.updateFlowControlWithTotalInOrderInboundBytesRead(
                self.finalSize,
                connection: connection,
                updateStream: false
            )
        }

        stream.resetReceived = true

        let lastOffset: UInt64 = self.finalSize == 0 ? 0 : self.finalSize - 1
        if let lastOffsetDelta = stream.updateLastOffset(
            connection: connection,
            newLastOffset: lastOffset,
            newFinalSize: self.finalSize
        ) {
            // Even though the stream is getting reset, it may
            // affect the connection max data
            if lastOffsetDelta > 0 {
                stream.updateInboundFlowControlCredit(
                    dataLengthAdded: UInt64(lastOffsetDelta),
                    connection: connection,
                    connectionOnly: true
                )
            }
        }
        if lastOffset == UInt64.max {
            let finalSize = self.finalSize
            Logger.proto.debug(
                "[S\(streamID.value)] final size invariants violated (final \(finalSize))"
            )
            return false
        }

        if stream.receiveState == .receive || stream.receiveState == .sizeKnown {
            stream.receiveState = .resetReceived
            stream.readClosed = true
            // A receiver of RESET_STREAM can discard any data
            // that it already received on that stream.
            if streamID.isReceiveOnly(server: connection.isServer) || stream.receivedStopSending
                || stream.sendState == .dataSent || stream.sendState == .dataReceived
            {
                let error = NetworkError.posix(ECONNRESET)
                stream.close(errorCode: error)
            }
        }
        return true
    }
}

// MARK: Stop Sending (0x05)

@available(Network 0.1.0, *)
struct FrameStopSending: ~Copyable, QUICFrameProtocol {
    let type = FrameType.stopSending

    private(set) var id: UInt64 = 0
    private(set) var code: UInt64 = 0

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameStopSending(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.stopSending(frame: frame)
    }

    init(id: UInt64, code: UInt64) {
        self.code = code
        self.id = id
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&id)
            try read.vle(&code)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        stats.increment(.rxStreamStopSendingFrames)
    }

    static func write(
        frame: inout Frame,
        id: UInt64,
        code: UInt64,
        stats: inout Statistics
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.stopSending.rawValue)
            try write.vle(id)
            try write.vle(code)
        }

        try validateSerializationResult(result)

        stats.increment(.txStreamStopSendingFrames)
    }

    func process(connection: QUICConnection) -> Bool {
        guard let streamID = QUICStreamID(self.id) else {
            let idValue = self.id
            Logger.proto.error("Stream frame with invalid stream ID \(idValue)")
            return false
        }
        // An endpoint that receives a STOP_SENDING frame for a receive-only
        // stream MUST terminate the connection with error STREAM_STATE_ERROR.
        if streamID.isReceiveOnly(server: connection.isServer) {
            Logger.proto.error(
                "Received STOP_SENDING for receive only stream"
            )
            connection.close(with: .streamStateError, "STREAM frame on send-only stream")
            return false
        }

        guard let flowID = connection.knownFlows[streamID] else {
            return true
        }
        guard let stream = connection.flow(for: flowID) else {
            if connection.streamClosedAlready(streamID: streamID) {
                return true
            }
            if streamID.isLocalBidirectional(server: connection.isServer)
                || streamID.isSendOnly(server: connection.isServer)
            {
                // Receiving a STOP_SENDING frame for a
                // locally-initiated stream that has not yet been
                // created MUST be treated as a connection error of type
                // STREAM_STATE_ERROR.
                Logger.proto.error(
                    "STOP_SENDING frame received on send stream that does not exist"
                )
                connection.close(with: .streamStateError, "STOP_SENDING: non-existent stream")
                return false
            }
            let inboundStreamResult = connection.createInboundStreams(streamID: streamID)
            // If we are ignoring the stream
            if !inboundStreamResult.created {
                return true
            }
            return false
        }
        Logger.proto.info("[S\(streamID.value)] received STOP_SENDING")
        stream.receivedStopSending = true
        stream.updateOutboundFlowControlCredit(connection: connection)

        var streamError = NetworkError.posix(ENOTCONN)
        if stream.receiveState == .resetReceived {
            streamError = NetworkError.posix(ECONNRESET)
        }
        stream.streamMetadata.applicationError = self.code
        stream.outboundApplicationError = self.code
        stream.deliverOutboundAbortedEvent(error: NetworkError(quicApplicationError: self.code))
        // If STOP_SENDING was received the outbound write should be closed
        // An endpoint that receives a STOP_SENDING frame MUST send a
        // RESET_STREAM frame if the stream is in the "Ready" or "Send" state.
        if stream.sendState == .ready || stream.sendState == .send {
            let _ = connection.disconnect(flow: stream.identifier, direction: .outbound)
        }
        //
        // Immediately close the stream if we have received
        // a RESET_STREAM frame or a STREAM+FIN frame
        // and the app has read the FIN.
        //
        if streamID.isSendOnly(server: connection.isServer) || stream.receiveState == .resetReceived
            || stream.receiveState == .dataRead
        {
            stream.close(errorCode: streamError)
        }
        return true
    }
}

// MARK: Crypto (0x06)

@available(Network 0.1.0, *)
struct FrameCrypto: ~Copyable, QUICFrameProtocol {
    let type = FrameType.crypto

    private(set) var packetNumberSpace: PacketNumberSpace
    private(set) var offset: UInt64 = 0
    private(set) var length = 0

    var frame = Frame()

    static func parse(
        frame: inout Frame,
        packetNumberSpace: PacketNumberSpace,
        isLastPacketInFrame: Bool = true,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameCrypto(
            frame: &frame,
            packetNumberSpace: packetNumberSpace,
            isLastPacketInFrame: isLastPacketInFrame,
            stats: &stats
        )
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.crypto(frame: frame)
    }

    // For testing only, as this incurs extra copies
    init(packetNumberSpace: PacketNumberSpace, offset: UInt64, data: [UInt8]) {
        self.packetNumberSpace = packetNumberSpace
        self.offset = offset
        self.length = data.count
        if self.length > 0 {
            self.frame = Frame(copyBuffer: data)
        }
    }

    init(
        frame: inout Frame,
        packetNumberSpace: PacketNumberSpace,
        isLastPacketInFrame: Bool = true,
        stats: inout Statistics
    ) throws(QUICError) {
        self.packetNumberSpace = packetNumberSpace

        var rawType: UInt64 = 0
        var length: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&offset)
            try read.vle(&length)
        }

        // Get the remaining bytes in the frame
        let remainingBytes: Int
        if case .success(_, let remaining) = result {
            remainingBytes = remaining
        } else {
            remainingBytes = 0
        }

        let cryptoLength = Int(length)

        // The crypto length must be able to fit in the remaining bytes
        if cryptoLength > remainingBytes {
            throw QUICError.frameParse(FrameParseError.parsingError)
        }

        // Only copy bytes if the crypto frame doesn't extend to the end of the packet
        let shouldCopyBytes = (cryptoLength < remainingBytes) || !isLastPacketInFrame

        try validateDeserializationResult(result)
        try validateType(rawType)

        self.length = cryptoLength

        if shouldCopyBytes {
            self.frame = Frame(count: cryptoLength)
            let bytesCopied = frame.copyInto(&self.frame, length: cryptoLength)

            // Claim from the start of the original frame
            guard frame.claim(fromStart: cryptoLength), bytesCopied == cryptoLength else {

                // If this fails, discard our local copy
                self.frame.finalize(success: false)

                throw QUICError.frameParse(FrameParseError.parsingError)
            }
        } else {
            // Consume the frame, and clear the passed-in frame
            self.frame = frame
            frame = .init()
        }
        self.frame.takeOwnershipOfBytes()

        FrameCrypto.updateStats(
            isRx: true,
            stats: &stats,
            packetNumberSpace: packetNumberSpace,
            size: cryptoLength
        )
    }

    // For testing only, as this incurs extra copies
    static func write(
        frame: inout Frame,
        stats: inout Statistics,
        packetNumberSpace: PacketNumberSpace,
        offset: UInt64,
        data: [UInt8]
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.crypto.rawValue)
            try write.vle(offset)
            try write.vle(data.count)
            try write.buffer(data)
        }
        try validateSerializationResult(result)

        updateStats(
            isRx: false,
            stats: &stats,
            packetNumberSpace: packetNumberSpace,
            size: data.count
        )

        if frame.isRetransmit {
            stats.increment(.txRetransmittedCryptoFrames)
            stats.increment(.txRetransmittedCryptoBytes, by: data.count)
        }
    }

    static func write(
        frame: inout Frame,
        stats: inout Statistics,
        packetNumberSpace: PacketNumberSpace,
        crypto: QUICCrypto,
        offset: UInt64,
        length: UInt64
    ) throws(QUICError) -> Int {
        let roomBeforeAddingHeader = frame.unclaimedLength

        let mockHeaderLength = Serializer.length { write in
            write.vle(FrameType.crypto.rawValue)
            write.vle(offset)
            write.vle(roomBeforeAddingHeader)  // Fake length to represent the longest length that can fit
        }

        guard roomBeforeAddingHeader > mockHeaderLength else {
            throw QUICError.frameWrite(.smallBuffer)
        }

        let availablePayloadLength = roomBeforeAddingHeader - mockHeaderLength
        let lengthToWrite = min(length, UInt64(availablePayloadLength))

        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.crypto.rawValue)
            try write.vle(offset)
            try write.vle(lengthToWrite)
        }
        try validateSerializationResult(result)

        let dataSizeWritten = crypto.copyOutSendData(
            for: packetNumberSpace,
            offset: offset,
            length: lengthToWrite,
            into: &frame
        )
        if dataSizeWritten != lengthToWrite {
            // Unclaim header bytes
            let roomAfterAddingHeader = frame.unclaimedLength
            if roomBeforeAddingHeader > roomAfterAddingHeader {
                let success = frame.unclaim(
                    fromStart: (roomBeforeAddingHeader - roomAfterAddingHeader)
                )
                precondition(success)
            }
            throw QUICError.frameWrite(FrameWriteError.smallBuffer)
        }
        let success = frame.claim(fromStart: Int(lengthToWrite))
        precondition(success)

        updateStats(
            isRx: false,
            stats: &stats,
            packetNumberSpace: packetNumberSpace,
            size: Int(lengthToWrite)
        )

        if frame.isRetransmit {
            stats.increment(.txRetransmittedCryptoFrames)
            stats.increment(.txRetransmittedCryptoBytes, by: Int(lengthToWrite))
        }

        return Int(lengthToWrite)
    }

    private static func updateStats(
        isRx: Bool,
        stats: inout Statistics,
        packetNumberSpace: PacketNumberSpace,
        size: Int
    ) {
        var framesStatistic: QUICStatistic
        var bytesStatistic: QUICStatistic

        switch packetNumberSpace {
        case .initial:
            if isRx {
                framesStatistic = .rxInitialCryptoFrames
                bytesStatistic = .rxInitialCryptoBytes
            } else {
                framesStatistic = .txInitialCryptoFrames
                bytesStatistic = .txInitialCryptoBytes
            }
        case .handshake:
            if isRx {
                framesStatistic = .rxHandshakeCryptoFrames
                bytesStatistic = .rxHandshakeCryptoBytes
            } else {
                framesStatistic = .txHandshakeCryptoFrames
                bytesStatistic = .txHandshakeCryptoBytes
            }
        case .applicationData:
            if isRx {
                framesStatistic = .rx1RTTCryptoFrames
                bytesStatistic = .rx1RTTCryptoBytes
            } else {
                framesStatistic = .tx1RTTCryptoFrames
                bytesStatistic = .tx1RTTCryptoBytes
            }
        }

        stats.increment(framesStatistic)
        stats.increment(bytesStatistic, by: size)
    }
}

// MARK: New Token (0x07)

@available(Network 0.1.0, *)
struct FrameNewToken: ~Copyable, QUICFrameProtocol {
    let type = FrameType.newToken

    private(set) var token: [UInt8] = []

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameNewToken(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.newToken(frame: frame)
    }

    init(token: [UInt8]) {
        self.token = token
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        var length: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&length)
            try read.buffer(&token, length: Int(length))
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
        stats.increment(.rxNewToken)
    }

    static func write(frame: inout Frame, token: [UInt8], stats: inout Statistics) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.newTokenCode)
            try write.vle(token.count)
            try write.buffer(token)
        }

        try validateSerializationResult(result)
        stats.increment(.txNewToken)
    }
}

// MARK: Stream (0x08...0x0f)

@available(Network 0.1.0, *)
struct FrameStreamFlag: ExpressibleByIntegerLiteral {
    // The FIN bit (0x01) indicates that the frame marks the end of the stream
    static let final: UInt64 = 0x01
    // The LEN bit (0x02) is set to indicate that there is a Length field present
    static let length: UInt64 = 0x02
    // The OFF bit (0x04) is set to indicate that there is an Offset field present
    static let offset: UInt64 = 0x04

    private(set) var rawValue: UInt64

    init(_ rawValue: UInt64) {
        precondition((0x0...0x7).contains(rawValue), "Invalid stream flag code")
        self.rawValue = rawValue
    }

    init(integerLiteral rawValue: IntegerLiteralType) {
        self.init(UInt64(rawValue))
    }
}

@available(Network 0.1.0, *)
extension FrameStreamFlag {
    static func fromCode(_ code: UInt64) -> FrameStreamFlag {
        let flag = code - FrameType.streamCodes.lowerBound
        return FrameStreamFlag(flag)
    }

    static func fromFields(hasOffset: Bool, hasLength: Bool, hasFinal: Bool) -> FrameStreamFlag {
        var flag: UInt64 = 0x0
        if hasOffset {
            flag |= FrameStreamFlag.offset
        }
        if hasLength {
            flag |= FrameStreamFlag.length
        }
        if hasFinal {
            flag |= FrameStreamFlag.final
        }
        return FrameStreamFlag(flag)
    }
}

// Only used for sending (or re-sending) STREAM frames
@available(Network 0.1.0, *)
struct FrameStreamSendMetadata: QUICFrameProtocol {
    let type: FrameType

    // Write STREAM frame into outbound `frame` from the stream's sendBuffer
    // starting from the `offset` and *up to* the requested `length`. The written
    // STREAM frame is claimed from the outbound `frame`.
    // Throws `QUICError.frameWrite(.smallBuffer)` if a STREAM frame cannot
    // fit in the outbound `frame`.
    // Caller MUST ensure the `offset` and `length` is still in the sendBuffer
    // (i.e. has not been ACKed yet) otherwise the error thrown due to this is
    // indistinguishable from the outbound `frame` not being big enough to hold
    // the STREAM frame.
    // Returns the stream data length actually written
    // Only marks FIN if the entire length is written
    static func write(
        into frame: inout Frame,
        stats: inout Statistics,
        stream: QUICStreamInstance,
        offset: UInt64,
        length: UInt64,
        isFinal: Bool
    ) throws(QUICError) -> Int {

        let streamID = stream.streamID!.value
        let roomBeforeAddingHeader = frame.unclaimedLength

        // Calculate the mockHeaderLength by defining:
        // (0 - variableLengthSize = 1) + streamID.variableLengthSize + (offset if present)
        let mockHeaderLength = 1 + streamID.variableLengthSize + (offset > 0 ? offset.variableLengthSize : 0)

        guard roomBeforeAddingHeader >= mockHeaderLength else {
            // Not even room for the header
            throw QUICError.frameWrite(.smallBuffer)
        }

        // Handle empty FIN
        if length == 0, isFinal {
            let addLength: Bool
            if roomBeforeAddingHeader == mockHeaderLength {
                // We fill to end of room, so no need for length field
                addLength = false
            } else {
                // Add length (of 0)
                addLength = true
            }
            let flag = FrameStreamFlag.fromFields(
                hasOffset: offset > 0,
                hasLength: addLength,
                hasFinal: isFinal
            )
            let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                try write.vle(FrameType.stream(flag: flag).rawValue)
                try write.vle(streamID)
                if offset > 0 {
                    try write.vle(offset)
                }
                if addLength {
                    try write.vle(0)
                }
            }
            try validateSerializationResult(result)
            stats.increment(.txStreamFrames)
            return 0
        }

        // Ensure there is room for at least some real data
        guard roomBeforeAddingHeader > mockHeaderLength else {
            // Not enough room for even one byte
            throw QUICError.frameWrite(.smallBuffer)
        }

        // At this point, we will be writing some payload bytes.

        // Determine if we should be adding the length field.
        // If the data will extend to the end of the frame, we don't need to.
        var shouldIncludeLength: Bool
        var lengthToWrite: UInt64
        if roomBeforeAddingHeader <= (mockHeaderLength + Int(length)) {
            // Trivial case, enough stream data to consume the whole frame
            shouldIncludeLength = false
            lengthToWrite = UInt64(roomBeforeAddingHeader - mockHeaderLength)
        } else {
            // The stream data cannot consume the whole frame, so add a Length field
            shouldIncludeLength = true
            lengthToWrite = length

            // The Length field is VLE encoded and its size depends on the final
            // stream length that is written.
            if roomBeforeAddingHeader < (mockHeaderLength + length.variableLengthSize + Int(length)) {
                // The requested length's VLE encoding pushes beyond the end of available room
                // But the length isn't much bigger because that's the trivial case above
                // Note: The VLE encoding size of the requested length is going to be the
                // biggest size Length field. The actual Length field is lengthToWrite's
                // VLE encoding size
                lengthToWrite = UInt64(
                    roomBeforeAddingHeader - (mockHeaderLength + length.variableLengthSize)
                )
            }
        }

        // The length to write cannot be longer than the requested length
        precondition(lengthToWrite <= length)

        let shouldWriteIsFinal = isFinal && (lengthToWrite == length)

        let flag = FrameStreamFlag.fromFields(
            hasOffset: offset > 0,
            hasLength: shouldIncludeLength,
            hasFinal: shouldWriteIsFinal
        )
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.stream(flag: flag).rawValue)
            try write.vle(streamID)
            if offset > 0 {
                try write.vle(offset)
            }
            if shouldIncludeLength {
                try write.vle(lengthToWrite)
            }
        }
        try validateSerializationResult(result)

        if lengthToWrite > 0 {
            let dataSizeWritten = stream.sendBuffer.copyOutSendData(
                offset: offset,
                length: lengthToWrite,
                into: &frame,
                log: stream.log
            )
            // It is caller's responsibility to check that the sendBuffer has
            // the requested offset+length. This throw therefore is indistinguishable
            // from indications that there isn't enough space in the outbound frame.
            if dataSizeWritten != lengthToWrite {
                // Unclaim header bytes
                let roomAfterAddingHeader = frame.unclaimedLength
                if roomBeforeAddingHeader > roomAfterAddingHeader {
                    let success = frame.unclaim(
                        fromStart: (roomBeforeAddingHeader - roomAfterAddingHeader)
                    )
                    precondition(success)
                }
                throw QUICError.frameWrite(FrameWriteError.smallBuffer)
            }
            let success = frame.claim(fromStart: Int(lengthToWrite))
            precondition(success)
        }

        stats.increment(.txStreamFrames)
        // Int() conversion is safe as no STREAM frame can be too big, though it
        // would be nice to change Statistics to use UInt64 here.
        stats.increment(.txStreamBytes, by: Int(lengthToWrite))

        return Int(lengthToWrite)
    }

    static func headerSizeForAvailableSize(
        streamID: QUICStreamID,
        offset: UInt64,
        availableSize: Int
    ) -> Int {
        // We always encode the length since we don't know if we're
        // adding an ACK or a PING frame after the STREAM frame.
        let flag = FrameStreamFlag.fromFields(
            hasOffset: offset > 0,
            hasLength: true,
            hasFinal: false
        )
        let type = FrameType.stream(flag: flag)
        let rawType = type.rawValue | FrameStreamFlag.length

        // Note well: Keep this in sync with write(), except the length
        let headerSizeExceptLengthField = Serializer.length { write in
            write.vle(rawType)
            write.vle(streamID.value)
            if offset > 0 {
                write.vle(offset)
            }
            // skip length
        }
        guard availableSize > headerSizeExceptLengthField + 1 else {
            // Cannot fit a header with a minimal (1 byte) VLE encoded length
            return Int.max
        }
        // This is how much is left for VLE-encoded length and the data
        let maxLengthDataSize = availableSize - headerSizeExceptLengthField
        // Which results this VLE-encoded length field. There is no more optimal
        // way to fill availableSpace, since to use the entire length we would need
        // at least this size Length field - thanks Greg!
        let lengthFieldSize = maxLengthDataSize.variableLengthSize

        return headerSizeExceptLengthField + lengthFieldSize
    }
}

// Only used for receiving STREAM frames
@available(Network 0.1.0, *)
struct FrameStreamReceived: ~Copyable, QUICFrameProtocol {
    var type = FrameType.stream()

    private(set) var id: UInt64 = 0
    private(set) var offset: UInt64 = 0
    private(set) var length: Int = 0

    var frame = Frame()

    private(set) var isFinal: Bool = false

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameStreamReceived(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.stream(frame: frame)
    }

    // For testing only, as this incurs extra copies
    init(id: UInt64, offset: UInt64, data: [UInt8], isFinal: Bool = false) {
        self.id = id
        self.offset = offset
        self.length = data.count
        if self.length > 0 {
            self.frame = Frame(copyBuffer: data)
        }
        self.isFinal = isFinal

        let flag = FrameStreamFlag.fromFields(
            hasOffset: offset > 0,
            hasLength: !data.isEmpty,
            hasFinal: isFinal
        )
        type = .stream(flag: flag)
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        var length: UInt64 = 0

        var streamID: UInt64 = 0
        var offset: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&streamID)
            if FrameStreamReceived.hasOffset(rawType) {
                try read.vle(&offset)
            }
            if FrameStreamReceived.hasLength(rawType) {
                try read.vle(&length)
            }
        }

        try validateDeserializationResult(result)
        try validateStreamType(rawType)

        // Get the remaining bytes in the frame
        let remainingBytes: Int
        if case .success(_, let remaining) = result {
            remainingBytes = remaining
        } else {
            remainingBytes = 0
        }

        let shouldCopyBytes: Bool
        let streamLength: Int
        if FrameStreamReceived.hasLength(rawType) {
            // If there is a stream length in the frame, it must be able to fit in the remaining bytes
            if length > remainingBytes {
                throw QUICError.frameParse(FrameParseError.parsingError)
            }

            // At this point, the value in `length` is correct for the stream
            streamLength = Int(length)

            // Only copy bytes if the stream frame doesn't extend to the end of the packet
            shouldCopyBytes = (streamLength < remainingBytes)
        } else {
            // If there is no stream length in the frame, the frame extends to the end of the packet
            // Don't copy bytes since the rest of the bytes are for this stream anyway
            streamLength = remainingBytes
            shouldCopyBytes = false
        }

        isFinal = FrameStreamReceived.hasFinal(rawType)

        stats.increment(.rxStreamFrames)
        stats.increment(.rxStreamBytes, by: streamLength)

        self.id = streamID
        self.offset = offset
        self.length = streamLength
        if shouldCopyBytes {
            self.frame = Frame(count: streamLength)
            let bytesCopied = frame.copyInto(&self.frame, length: streamLength)

            // Claim from the start of the original frame
            guard frame.claim(fromStart: streamLength), bytesCopied == streamLength else {

                // If this fails, discard our local copy
                self.frame.finalize(success: false)

                throw QUICError.frameParse(FrameParseError.parsingError)
            }
        } else {
            // Consume the frame, and clear the passed-in frame
            self.frame = frame
            frame = .init()
        }
        self.frame.takeOwnershipOfBytes()
    }

    static private func hasOffset(_ rawType: UInt64) -> Bool {
        (rawType & FrameStreamFlag.offset) != 0
    }

    static private func hasLength(_ rawType: UInt64) -> Bool {
        (rawType & FrameStreamFlag.length) != 0
    }

    static private func hasFinal(_ rawType: UInt64) -> Bool {
        (rawType & FrameStreamFlag.final) != 0
    }

    private mutating func validateStreamType(_ rawType: UInt64) throws(QUICError) {
        // The type field in a STREAM frame takes the form 0b00001XXX
        // (or the set of values from 0x08 to 0x0f)
        guard rawType >= 0x08, rawType <= 0x0f else {
            throw QUICError.frameParse(FrameParseError.invalidType(rawType))
        }
        type = .stream(flag: FrameStreamFlag.fromCode(rawType))
    }
}

// MARK: Max Data (0x10)

@available(Network 0.1.0, *)
struct FrameMaxData: ~Copyable, QUICFrameProtocol {
    let type = FrameType.maxData

    private(set) var max: UInt64 = 0

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameMaxData(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.maxData(frame: frame)
    }

    init(max: UInt64) {
        self.max = max
    }

    init(frame: inout Frame) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&max)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    static func write(frame: inout Frame, max: UInt64) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.maxData.rawValue)
            try write.vle(max)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Max Stream Data (0x11)

@available(Network 0.1.0, *)
struct FrameMaxStreamData: ~Copyable, QUICFrameProtocol {
    let type = FrameType.maxStreamData

    private(set) var id: UInt64 = 0
    private(set) var max: UInt64 = 0

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameMaxStreamData(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.maxStreamData(frame: frame)
    }

    init(id: UInt64, max: UInt64) {
        self.id = id
        self.max = max
    }

    init(frame: inout Frame) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&id)
            try read.vle(&max)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    static func write(frame: inout Frame, id: UInt64, max: UInt64) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.maxStreamData.rawValue)
            try write.vle(id)
            try write.vle(max)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Max Streams Bidirectional (0x12)

@available(Network 0.1.0, *)
struct FrameMaxStreamsBidirectional: ~Copyable, QUICFrameProtocol {
    let type = FrameType.maxStreamsBidirectional

    public let max: UInt64

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameMaxStreamsBidirectional(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.maxStreamsBidirectional(frame: frame)
    }

    init(max: UInt64) {
        self.max = max
    }

    init(frame: inout Frame) throws(QUICError) {
        var rawType: UInt64 = 0
        var _max: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&_max)
        }
        self.max = _max

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    static func write(frame: inout Frame, max: UInt64) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.maxStreamsBidirectional.rawValue)
            try write.vle(max)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Max Streams Unidirectional (0x13)

@available(Network 0.1.0, *)
struct FrameMaxStreamsUnidirectional: ~Copyable, QUICFrameProtocol {
    let type = FrameType.maxStreamsUnidirectional

    public let max: UInt64

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameMaxStreamsUnidirectional(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.maxStreamsUnidirectional(frame: frame)
    }

    init(max: UInt64) {
        self.max = max
    }

    init(frame: inout Frame) throws(QUICError) {
        var rawType: UInt64 = 0
        var _max: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&_max)
        }
        self.max = _max

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    static func write(frame: inout Frame, max: UInt64) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.maxStreamsUnidirectional.rawValue)
            try write.vle(max)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Data Blocked (0x14)

@available(Network 0.1.0, *)
struct FrameDataBlocked: ~Copyable, QUICFrameProtocol {
    let type = FrameType.dataBlocked

    private(set) var limit: UInt64 = 0

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameDataBlocked(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.dataBlocked(frame: frame)
    }

    init(limit: UInt64) {
        self.limit = limit
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&limit)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        stats.increment(.rxDataBlockedFrames)
    }

    static func write(frame: inout Frame, limit: UInt64, stats: inout Statistics) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.dataBlocked.rawValue)
            try write.vle(limit)
        }

        try validateSerializationResult(result)

        stats.increment(.txDataBlockedFrames)
    }
}

// MARK: Stream Data Blocked (0x15)

@available(Network 0.1.0, *)
struct FrameStreamDataBlocked: ~Copyable, QUICFrameProtocol {
    let type = FrameType.streamDataBlocked

    private(set) var id: UInt64 = 0
    private(set) var limit: UInt64 = 0

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameStreamDataBlocked(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.streamDataBlocked(frame: frame)
    }

    init(id: UInt64, limit: UInt64) {
        self.id = id
        self.limit = limit
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&id)
            try read.vle(&limit)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        stats.increment(.rxStreamDataBlockedFrames)
    }

    static func write(
        frame: inout Frame,
        id: UInt64,
        limit: UInt64,
        stats: inout Statistics
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.streamDataBlocked.rawValue)
            try write.vle(id)
            try write.vle(limit)
        }

        try validateSerializationResult(result)

        stats.increment(.txStreamDataBlockedFrames)
    }
}

// MARK: Streams Blocked Bidirectional (0x16)

@available(Network 0.1.0, *)
struct FrameStreamsBlockedBidirectional: ~Copyable, QUICFrameProtocol {
    let type = FrameType.streamsBlockedBidirectional

    public let limit: UInt64

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameStreamsBlockedBidirectional(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.streamsBlockedBidirectional(frame: frame)
    }

    init(limit: UInt64) {
        self.limit = limit
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        var _limit: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&_limit)
        }
        self.limit = _limit

        try validateDeserializationResult(result)
        try validateType(rawType)

        stats.increment(.rxStreamDataBlockedFrames)
    }

    static func write(frame: inout Frame, limit: UInt64, stats: inout Statistics) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.streamsBlockedBidirectional.rawValue)
            try write.vle(limit)
        }

        try validateSerializationResult(result)

        stats.increment(.txStreamDataBlockedFrames)
    }
}

// MARK: Streams Blocked Unidirectional (0x17)

@available(Network 0.1.0, *)
struct FrameStreamsBlockedUnidirectional: ~Copyable, QUICFrameProtocol {
    let type = FrameType.streamsBlockedUnidirectional

    public let limit: UInt64

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameStreamsBlockedUnidirectional(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.streamsBlockedUnidirectional(frame: frame)
    }

    init(limit: UInt64) {
        self.limit = limit
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        var _limit: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&_limit)
        }
        self.limit = _limit

        try validateDeserializationResult(result)
        try validateType(rawType)

        stats.increment(.rxStreamDataBlockedFrames)
    }

    static func write(frame: inout Frame, limit: UInt64, stats: inout Statistics) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.streamsBlockedUnidirectional.rawValue)
            try write.vle(limit)
        }

        try validateSerializationResult(result)

        stats.increment(.txStreamDataBlockedFrames)
    }
}

// MARK: New Connection ID (0x18)

@available(Network 0.1.0, *)
struct FrameNewConnectionID: QUICFrameProtocol {
    let type = FrameType.newConnectionID
    private(set) var sequence: UInt64 = 0
    private(set) var retirePriorToSequence: UInt64 = 0
    private(set) var connectionID: QUICConnectionID
    private(set) var statelessResetToken: QUICStatelessResetToken

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameNewConnectionID(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.newConnectionID(frame: frame)
    }

    init(
        sequence: UInt64,
        retirePriorToSequence: UInt64,
        connectionID: QUICConnectionID,
        statelessResetToken: QUICStatelessResetToken
    ) {
        self.sequence = sequence
        self.retirePriorToSequence = retirePriorToSequence
        self.connectionID = connectionID
        self.statelessResetToken = statelessResetToken
    }

    init(frame: inout Frame, pnSpace: PacketNumberSpace? = nil) throws(QUICError) {
        var rawType: UInt64 = 0
        var cidLength: UInt8 = 0
        var tokenBuffer: [UInt8] = []

        self.connectionID = QUICConnectionID(0)
        self.statelessResetToken = QUICStatelessResetToken()
        var connectionIDStorage = QUICConnectionIDStorage.empty
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&sequence)
            try read.vle(&retirePriorToSequence)
            try read.uint8(&cidLength)
            try read.connectionID(&connectionIDStorage, length: Int(cidLength))
            try read.buffer(&tokenBuffer, length: QUICStatelessResetToken.size)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        guard cidLength >= 1, cidLength <= QUICConnectionID.maximumSize
        else {
            throw QUICError.frameParse(
                FrameParseError.invalidValue(
                    "cid length \(cidLength) not within 1...\(QUICConnectionID.maximumSize)"
                )
            )
        }
        guard let statelessResetToken = QUICStatelessResetToken(tokenBuffer) else {
            throw QUICError.frameParse(
                FrameParseError.invalidValue(
                    "Invalid stateless reset token"
                )
            )
        }

        // N.B.: size of tokenBuffer is guaranteed to be correct.
        self.connectionID = QUICConnectionID(storage: connectionIDStorage, size: Int(cidLength))
        self.statelessResetToken = statelessResetToken
    }

    func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(type.rawValue)
            try write.vle(sequence)
            try write.vle(retirePriorToSequence)
            try write.connectionID(connectionID)
            try write.buffer(statelessResetToken.token)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Retire Connection ID (0x19)

@available(Network 0.1.0, *)
struct FrameRetireConnectionID: QUICFrameProtocol {
    let type = FrameType.retireConnectionID

    private(set) var sequence: UInt64 = 0

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameRetireConnectionID(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.retireConnectionID(frame: frame)
    }

    init(sequence: UInt64) {
        self.sequence = sequence
    }

    init(frame: inout Frame) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&sequence)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(type.rawValue)
            try write.vle(sequence)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Path Challenge (0x1a)

@available(Network 0.1.0, *)
struct FramePathChallenge: QUICFrameProtocol {
    let type = FrameType.pathChallenge

    private(set) var data: UInt64 = 0
    private(set) var destinationConnectionID: QUICConnectionID?

    static func parse(
        frame: inout Frame,
        destinationConnectionID: QUICConnectionID,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FramePathChallenge(
            frame: &frame,
            destinationConnectionID: destinationConnectionID
        )
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.pathChallenge(frame: frame)
    }

    init(data: UInt64) {
        self.data = data
    }

    init(frame: inout Frame, destinationConnectionID: QUICConnectionID) throws(QUICError) {
        self.destinationConnectionID = destinationConnectionID

        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.uint64(&data)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(type.rawValue)
            try write.uint64(data)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Path Response (0x1b)

@available(Network 0.1.0, *)
struct FramePathResponse: QUICFrameProtocol {
    let type = FrameType.pathResponse

    private(set) var data: UInt64 = 0
    private(set) var destinationConnectionID: QUICConnectionID?

    static func parse(
        frame: inout Frame,
        destinationConnectionID: QUICConnectionID,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FramePathResponse(
            frame: &frame,
            destinationConnectionID: destinationConnectionID
        )
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.pathResponse(frame: frame)
    }

    init(data: UInt64) {
        self.data = data
    }

    init(frame: inout Frame, destinationConnectionID: QUICConnectionID) throws(QUICError) {
        self.destinationConnectionID = destinationConnectionID

        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.uint64(&data)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(type.rawValue)
            try write.uint64(data)
        }

        try validateSerializationResult(result)
    }
}

// MARK: Connection Close (0x1c)

@available(Network 0.1.0, *)
private func updateConnectionCloseStats(
    errorCode: UInt64,
    isRx: Bool,
    stats: inout Statistics
) {
    var stat: QUICStatistic?

    if let error = QUICTransportError(errorCode) {
        switch error.errorCode {
        case .transport(let transport):
            switch transport {
            case .internalError:
                if isRx {
                    stat = .rxConnectionCloseReasonInternalError
                } else {
                    stat = .txConnectionCloseReasonInternalError
                }
            case .serverBusy:
                if isRx {
                    stat = .rxConnectionCloseReasonServerBusy
                } else {
                    stat = .txConnectionCloseReasonServerBusy
                }
            case .flowControlError:
                if isRx {
                    stat = .rxConnectionCloseReasonFlowControlError
                } else {
                    stat = .txConnectionCloseReasonFlowControlError
                }
            case .streamLimitError:
                if isRx {
                    stat = .rxConnectionCloseReasonStreamLimitError
                } else {
                    stat = .txConnectionCloseReasonStreamLimitError
                }
            case .streamStateError:
                if isRx {
                    stat = .rxConnectionCloseReasonStreamStateError
                } else {
                    stat = .txConnectionCloseReasonStreamStateError
                }
            case .finalSizeError:
                if isRx {
                    stat = .rxConnectionCloseReasonFinalSizeError
                } else {
                    stat = .txConnectionCloseReasonFinalSizeError
                }
            case .frameEncodingError:
                if isRx {
                    stat = .rxConnectionCloseReasonFrameEncodingError
                } else {
                    stat = .txConnectionCloseReasonFrameEncodingError
                }
            case .transportParameterError:
                if isRx {
                    stat = .rxConnectionCloseReasonTransportParameterError
                } else {
                    stat = .txConnectionCloseReasonTransportParameterError
                }
            case .protocolViolation:
                if isRx {
                    stat = .rxConnectionCloseReasonProtocolViolation
                } else {
                    stat = .txConnectionCloseReasonProtocolViolation
                }
            default:
                break
            }
        case .crypto:
            if isRx {
                stat = .rxConnectionCloseReasonCryptoError
            } else {
                stat = .txConnectionCloseReasonCryptoError
            }
        }
    }

    if let stat {
        stats.increment(stat)
    }
}

@available(Network 0.1.0, *)
struct FrameConnectionClose: ~Copyable, QUICFrameProtocol {

    let type = FrameType.connectionClose

    private(set) var errorCode: UInt64 = 0
    private(set) var frameType: FrameType

    private(set) var reason: String = ""

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameConnectionClose(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.connectionClose(frame: frame)
    }

    init(errorCode: UInt64, frameType: FrameType, reason: String = "") {
        self.errorCode = errorCode
        self.frameType = frameType
        self.reason = reason
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {
        var rawType: UInt64 = 0
        var rawFrameType: UInt64 = 0
        var rawCode: UInt64 = 0
        var reasonLength: UInt64 = 0

        frameType = .connectionClose
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&rawCode)
            try read.vle(&rawFrameType)
            try read.vle(&reasonLength)
            try read.fixedLengthUTF8(&reason, byteCount: Int(reasonLength))
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        self.errorCode = rawCode

        guard let frameType = FrameType(rawValue: rawFrameType) else {
            throw QUICError.frameParse(
                FrameParseError.invalidValue("invalid frame type: \(rawFrameType)")
            )
        }
        self.frameType = frameType

        updateConnectionCloseStats(errorCode: self.errorCode, isRx: true, stats: &stats)
    }

    static func write(
        frame: inout Frame,
        stats: inout Statistics,
        errorCode: UInt64,
        frameType: FrameType?,
        reason: String? = ""
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.connectionClose.rawValue)
            try write.vle(errorCode)
            try write.vle(frameType?.rawValue ?? 0)
            if let reason {
                try write.vle(reason.utf8.count)
                try write.fixedLengthUTF8(reason, byteCount: reason.utf8.count)
            } else {
                try write.vle(0)
            }
        }

        try validateSerializationResult(result)

        updateConnectionCloseStats(errorCode: errorCode, isRx: false, stats: &stats)
    }
}

// MARK: Application Close (0x1d)

@available(Network 0.1.0, *)
struct FrameApplicationClose: ~Copyable, QUICFrameProtocol {
    let type = FrameType.applicationClose

    private(set) var errorCode: UInt64 = 0

    private(set) var reason: String = ""

    static func parse(
        frame: inout Frame,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameApplicationClose(frame: &frame, stats: &stats)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.applicationClose(frame: frame)
    }

    init(errorCode: UInt64, reason: String = "") {
        self.errorCode = errorCode
        self.reason = reason
    }

    init(frame: inout Frame, stats: inout Statistics) throws(QUICError) {

        var rawType: UInt64 = 0
        var rawCode: UInt64 = 0
        var reasonLength: UInt64 = 0

        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
            try read.vle(&rawCode)
            try read.vle(&reasonLength)
            try read.fixedLengthUTF8(&reason, byteCount: Int(reasonLength))
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
        self.errorCode = rawCode
        stats.increment(.rxApplicationCloseError)
    }

    static func write(
        frame: inout Frame,
        stats: inout Statistics,
        errorCode: UInt64,
        reason: String?
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.applicationClose.rawValue)
            try write.vle(errorCode)
            if let reason {
                try write.vle(reason.utf8.count)
                try write.fixedLengthUTF8(reason, byteCount: reason.utf8.count)
            } else {
                try write.vle(0)
            }
        }

        try validateSerializationResult(result)

        stats.increment(.txApplicationCloseError)
    }

    func write(frame: inout Frame, stats: inout Statistics, claim: Bool = false) throws(QUICError) {
        try FrameApplicationClose.write(
            frame: &frame,
            stats: &stats,
            errorCode: errorCode,
            reason: reason
        )
    }
}

// MARK: Handshake Done (0x1e)

@available(Network 0.1.0, *)
struct FrameHandshakeDone: ~Copyable, QUICFrameProtocol {
    let type = FrameType.handshakeDone

    static func parse(
        frame: inout Frame,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameHandshakeDone(frame: &frame)
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.handshakeDone(frame: frame)
    }

    init() {}

    init(frame: inout Frame) throws(QUICError) {
        var rawType: UInt64 = 0
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
        }

        try validateDeserializationResult(result)
        try validateType(rawType)
    }

    static func write(frame: inout Frame) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.handshakeDone.rawValue)
        }

        try validateSerializationResult(result)
    }

    func process(connection: QUICConnection) -> Bool {
        if connection.isServer {
            connection.close(with: .protocolViolation, "Received HANDSHAKE_DONE from a client")
            return false
        }

        connection.confirmHandshake()
        return true
    }
}

// MARK: Datagram (0x30...0x31)

// The Type field in the DATAGRAM frame takes the form 0b0011000X (or the values 0x30 and 0x31).
// The least significant bit of the Type field in the DATAGRAM frame is the LEN bit (0x01),
// which indicates whether there is a Length field present: if this bit is set to 0,
// the Length field is absent and the Datagram Data field extends to the end of the packet
@available(Network 0.1.0, *)
struct FrameDatagram: ~Copyable, QUICFrameProtocol {
    var type = FrameType.datagram()

    private(set) var flowID: UInt64?
    private(set) var contextID: UInt64?
    private(set) var length: Int = 0

    var frame = Frame()

    static func length(dataLength: UInt64, flowID: UInt64?, contextID: UInt64?) -> UInt64 {
        var length = dataLength
        if let flowID {
            length += UInt64(flowID.variableLengthSize)
        }
        if let contextID {
            length += UInt64(contextID.variableLengthSize)
        }
        return length
    }

    private var hasLength: Bool {
        type == .datagram(hasLength: true)
    }

    static func parse(
        frame: inout Frame,
        useFlowID: Bool,
        useContextID: Bool,
        connection: QUICConnection,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> QUICFrame {
        let frame = try FrameDatagram(
            frame: &frame,
            useFlowID: useFlowID,
            useContextID: useContextID,
            connection: connection
        )
        if shorthandFrames != nil {
            shorthandFrames!.append(frame.toShorthandLogEntry(outgoing: false))
        }
        return QUICFrame.datagram(frame: frame)
    }

    // For testing only, as this incurs extra copies
    init(
        flowID: UInt64? = nil,
        contextID: UInt64? = nil,
        data: [UInt8],
        hasLength: Bool
    ) {
        type = .datagram(hasLength: hasLength)

        self.contextID = contextID
        self.length = data.count
        if self.length > 0 {
            self.frame = Frame(copyBuffer: data)
        }
        if let flowID {
            self.flowID = flowID & ~Constants.streamIDDatagramMask
        }
    }

    init(
        frame: inout Frame,
        useFlowID: Bool,
        useContextID: Bool,
        connection: QUICConnection
    ) throws(QUICError) {
        var rawType: UInt64 = 0
        var contextID: UInt64 = 0
        var flowID: UInt64 = 0
        var result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.vle(&rawType)
        }

        try validateDeserializationResult(result)
        try validateDatagramType(rawType)

        var rawLength: UInt64 = 0
        if hasLength {
            result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                try read.vle(&rawLength)
            }
            try validateDeserializationResult(result)
        }

        var headerOverhead = 0
        let unclaimedLengthBeforeHeader = frame.unclaimedLength
        if useFlowID || useContextID {
            result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                if useFlowID {
                    try read.vle(&flowID)
                }
                if useContextID {
                    try read.vle(&contextID)
                }
            }
            try validateDeserializationResult(result)
            let unclaimedLengthAfterHeader = frame.unclaimedLength
            if unclaimedLengthBeforeHeader > unclaimedLengthAfterHeader {
                headerOverhead = unclaimedLengthBeforeHeader - unclaimedLengthAfterHeader
            }

            if useFlowID {
                self.flowID = flowID
            }

            if useContextID {
                self.contextID = contextID
            }
        }

        let shouldCopyBytes: Bool
        let datagramLength: Int

        let remainingBytes = unclaimedLengthBeforeHeader - headerOverhead

        if hasLength {
            // If there is a datagram length in the frame, it must be able to fit in the remaining bytes
            if rawLength > headerOverhead + remainingBytes {
                throw QUICError.frameParse(FrameParseError.parsingError)
            }

            // At this point, the value in `length` is correct for the datagram
            datagramLength = Int(rawLength) - headerOverhead

            // Only copy bytes if the datagram frame doesn't extend to the end of the packet
            shouldCopyBytes = (datagramLength < remainingBytes)
        } else {
            // If there is no datagram length in the frame, the frame extends to the end of the packet
            // Don't copy bytes since the rest of the bytes are for this datagram anyway
            datagramLength = remainingBytes
            shouldCopyBytes = false
        }

        try validateDeserializationResult(result)
        try validateType(rawType)

        // In testing scenarios localTransportParameters maxDatagramFrameSize can be 0
        let tpLocalMaxDatagramFrameSize = connection.localTransportParameters.intValue(
            .maxDatagramFrameSize
        )
        let localMaxDatagramFrameSize =
            tpLocalMaxDatagramFrameSize == 0
            ? Constants.maxDatagramFrameSize : tpLocalMaxDatagramFrameSize
        guard datagramLength <= localMaxDatagramFrameSize else {
            connection.close(with: .protocolViolation, "DATAGRAM frame size too big")
            throw QUICError.frameParse(FrameParseError.parsingError)
        }

        self.length = datagramLength

        if shouldCopyBytes {
            self.frame = Frame(count: datagramLength)
            let bytesCopied = frame.copyInto(&self.frame, length: datagramLength)

            // Claim from the start of the original frame
            guard frame.claim(fromStart: datagramLength), bytesCopied == datagramLength else {

                // If this fails, discard our local copy
                self.frame.finalize(success: false)

                throw QUICError.frameParse(FrameParseError.parsingError)
            }
        } else {
            // Consume the frame, and clear the passed-in frame
            self.frame = frame
            frame = .init()
        }
        self.frame.takeOwnershipOfBytes()

        if hasLength {
            connection.stats.increment(.rxDatagramFrameWithLength)
        } else {
            connection.stats.increment(.rxDatagramFrameWithOutLength)
        }
    }

    static func write(
        frame: inout Frame,
        hasLength: Bool,
        flowID: UInt64?,
        contextID: UInt64?,
        data: borrowing Frame,
        stats: inout Statistics
    ) throws(QUICError) {
        let roomBeforeAddingHeader = frame.unclaimedLength
        let dataLength = data.unclaimedLength
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.vle(FrameType.datagram(hasLength: hasLength).rawValue)
            if hasLength {
                try write.vle(
                    FrameDatagram.length(
                        dataLength: UInt64(dataLength),
                        flowID: flowID,
                        contextID: contextID
                    )
                )
            }
            if let flowID {
                try write.vle(flowID)
            }
            if let contextID {
                try write.vle(contextID)
            }
        }
        try validateSerializationResult(result)

        // Just go ahead, copyInto() will check and return what length it could copy
        let lengthCopied = data.copyInto(&frame, length: dataLength)
        guard lengthCopied == dataLength, frame.claim(fromStart: lengthCopied) else {
            // Unclaim header bytes in case of failure
            let roomAfterAddingHeader = frame.unclaimedLength
            if roomBeforeAddingHeader > roomAfterAddingHeader {
                let success = frame.unclaim(
                    fromStart: (roomBeforeAddingHeader - roomAfterAddingHeader)
                )
                precondition(success)
            }

            throw QUICError.frameWrite(FrameWriteError.smallBuffer)
        }

        if hasLength {
            stats.increment(.txDatagramFrameWithLength)
        } else {
            stats.increment(.txDatagramFrameWithOutLength)
        }
    }

    private mutating func validateDatagramType(_ rawType: UInt64) throws(QUICError) {
        // The type field in a DATAGRAM frame can be 0x30 or 0x31, the latter
        // indicating a DATAGRAM_LEN frame which has a VLE encoded length field.
        if rawType == FrameType.datagramCode {
            self.type = .datagram(hasLength: false)
        } else if rawType == FrameType.datagramWithLengthCode {
            self.type = .datagram(hasLength: true)
        } else {
            throw QUICError.frameParse(FrameParseError.invalidType(rawType))
        }
    }
}

#endif
