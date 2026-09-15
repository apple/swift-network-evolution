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

#if canImport(BasicContainers)
import BasicContainers
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

enum QUICPacketError: Int, Error {
    case invalidDestinationConnectionID
    case invalidSourceConnectionID
    case invalidVersionNumber
    case serializationBufferTooSmall
    case serializationError
    case invalidHeaderType
    case longheaderKeyStateUpdate  // Attempt to modify keyState while parsing a LH packet.
    case ackNumberUnderflow  // packet number < last acked
    case invalidPacketNumber
    case truncatedPacketNumberTooLarge
    case deserializationError
}

enum PacketKeyState: Int, CaseIterable, CustomStringConvertible, Comparable {
    case initial = 0
    case handshake
    case earlyData
    case phase0 /* 1-RTT phase 0 */
    case phase1 /* 1-RTT phase 1 */

    static func < (lhs: PacketKeyState, rhs: PacketKeyState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .initial:
            return "initial"
        case .handshake:
            return "handshake"
        case .earlyData:
            return "0-rtt"
        case .phase0:
            return "kp0"
        case .phase1:
            return "kp1"
        }
    }

    var isHandshakeConfirmed: Bool {
        switch self {
        case .earlyData, .phase0, .phase1:
            return true
        default:
            return false
        }
    }

    var is1RTT: Bool {
        switch self {
        case .phase0, .phase1:
            return true
        default:
            return false
        }
    }
}

@available(Network 0.1.0, *)
struct SentPacketRecord: ~Copyable {
    var transmittedItems: TransmittedItems = TransmittedItems()

    var identifier: PacketIdentifier = .init(space: .initial, number: 0)
    var number: PacketNumber {
        identifier.number
    }
    var numberSpace: PacketNumberSpace {
        identifier.space
    }

    var ecn: IPProtocol.ECN = .nonECT
    var ectMarked: Bool {
        (ecn == .ect0 || ecn == .ect1)
    }

    var sentPath: MultiplexingPathIdentifier = .none

    var totalLength = 0

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let isAckEliciting = Flags(rawValue: 1 << 0)
        static let isInFlightEligible = Flags(rawValue: 1 << 1)
        static let largerPacket = Flags(rawValue: 1 << 2)
        static let isECNValidationPacket = Flags(rawValue: 1 << 3)
    }
    private var flags = Flags()
    var isAckEliciting: Bool {
        get { flags.contains(.isAckEliciting) }
        set {
            if newValue {
                flags.insert(.isAckEliciting)
            } else {
                flags.remove(.isAckEliciting)
            }
        }
    }
    var isInFlightEligible: Bool {
        get { flags.contains(.isInFlightEligible) }
        set {
            if newValue {
                flags.insert(.isInFlightEligible)
            } else {
                flags.remove(.isInFlightEligible)
            }
        }
    }
    var largerPacket: Bool {
        get { flags.contains(.largerPacket) }
        set {
            if newValue {
                flags.insert(.largerPacket)
            } else {
                flags.remove(.largerPacket)
            }
        }
    }
    var isECNValidationPacket: Bool {
        get { flags.contains(.isECNValidationPacket) }
        set {
            if newValue {
                flags.insert(.isECNValidationPacket)
            } else {
                flags.remove(.isECNValidationPacket)
            }
        }
    }

    mutating func inheritFrom(packet: borrowing Packet) {
        self.identifier = packet.identifier
        self.totalLength = packet.totalLength
    }
}

@available(Network 0.1.0, *)
struct Packet: ~Copyable {
    static let longHeaderBaseSize = 5
    static let shortHeaderBaseSize = 1

    private(set) var destinationConnectionID: QUICConnectionID?
    private(set) var sourceConnectionID: QUICConnectionID?

    private(set) var lastAcked: PacketNumber = .none

    // The length of the long or short header, before packet numbers
    var headerLength: UInt16 = 0

    // The length of the payload, including packet number, frames, and tag
    var payloadLength: UInt16 = 0

    // The length of the packet number, which is the first part of the payload
    var packetNumberLength: UInt8 = 0

    // The length of the tag, which is the last part of the payload
    var tagLength: UInt8 = 0

    var totalLength: Int {
        Int(headerLength + payloadLength)
    }

    var packetNumberOffset: Int? {
        guard headerLength > 0 else { return nil }
        return Int(headerLength)
    }
    var headerRange: Range<Int> {
        0..<Int(headerLength) + Int(packetNumberLength)
    }
    var payloadRange: Range<Int> {
        (Int(headerLength) + Int(packetNumberLength))..<(Int(headerLength) + Int(payloadLength) - Int(tagLength))
    }
    var tagRange: Range<Int> {
        (Int(headerLength) + Int(payloadLength) - Int(tagLength))..<(Int(headerLength) + Int(payloadLength))
    }

    // Note: sampleRange is independent of the value of the actual packet number
    // It always starts 4 bytes after the packet number (i.e. assumes 4 bytes packet number)
    var sampleRange: Range<Int> {
        precondition(
            packetNumberOffset != nil,
            "Attempt to use sampleRange before packetNumberOffset is known"
        )
        let sampleStart = packetNumberOffset! + 4
        return sampleStart..<(sampleStart + Int(tagLength))
    }

    private(set) var keyState: PacketKeyState?

    var identifier: PacketIdentifier
    var number: PacketNumber {
        get { identifier.number }
        set(newValue) {
            identifier.number = newValue
        }
    }
    var numberSpace: PacketNumberSpace {
        identifier.space
    }

    // Temporary storage used for logging, only set when datapath logs or QLog is enabled
    var shorthandFrames: [QUICShorthandFrame]?

    private(set) var token: [UInt8]?
    var tokenLength: Int {
        token?.count ?? 0
    }
    var tag: [UInt8]?

    // Initial and Version Negotiation Packet
    private(set) var version: QUICVersion?

    // Version Negotiation
    private(set) var versions: [QUICVersion]?

    // Flags
    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let longHeader = Flags(rawValue: 1 << 0)
        static let spinValue = Flags(rawValue: 1 << 2)
        static let versionNegotiation = Flags(rawValue: 1 << 3)
        static let failedDecryption = Flags(rawValue: 1 << 4)
    }
    private var flags = Flags()
    var longHeader: Bool {
        get { flags.contains(.longHeader) }
        set {
            if newValue {
                flags.insert(.longHeader)
            } else {
                flags.remove(.longHeader)
            }
        }
    }
    var spinValue: Bool {
        get { flags.contains(.spinValue) }
        set {
            if newValue {
                flags.insert(.spinValue)
            } else {
                flags.remove(.spinValue)
            }
        }
    }
    var versionNegotiation: Bool {
        get { flags.contains(.versionNegotiation) }
        set {
            if newValue {
                flags.insert(.versionNegotiation)
            } else {
                flags.remove(.versionNegotiation)
            }
        }
    }
    var failedDecryption: Bool {
        get { flags.contains(.failedDecryption) }
        set {
            if newValue {
                flags.insert(.failedDecryption)
            } else {
                flags.remove(.failedDecryption)
            }
        }
    }

    private(set) var retryFirstOctet: UInt8?
    var retry: Bool {
        retryFirstOctet != nil
    }

    // Note well: For use ONLY with test vectors from RFC 9001
    private var _overrideSentNumberSize: EncodedPacketNumber.Size?
    var overrideSentNumberSize: EncodedPacketNumber.Size? {
        get {
            if let _overrideSentNumberSize {
                #if !DisableErrorLogging
                Logger.proto.error(
                    "WARNING: Reading overrideSentNumberSize only be used for unit testing!"
                )
                #endif
                return _overrideSentNumberSize
            }
            return nil
        }
        set(newValue) {
            if let newValue {
                #if !DisableErrorLogging
                Logger.proto.error(
                    "WARNING: Setting overrideSentNumberSize only be used for unit testing!"
                )
                #endif
                _overrideSentNumberSize = newValue
            } else {
                _overrideSentNumberSize = nil
            }
        }
    }

    init(
        versionNegotiation: Bool = false,
        number: PacketNumber,
        lastAcked: PacketNumber,
        keyState: PacketKeyState,
        destinationConnectionID: QUICConnectionID = QUICConnectionID(0),
        sourceConnectionID: QUICConnectionID = QUICConnectionID(0),
        version: QUICVersion = .v1
    ) {
        identifier = PacketIdentifier.init(
            space: PacketNumberSpace.fromKeyState(keyState: keyState),
            number: number
        )
        self.versionNegotiation = versionNegotiation
        self.longHeader = Packet.requiresLongHeader(keyState: keyState)
        self.lastAcked = lastAcked
        self.keyState = keyState
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.version = version
    }

    // Version Negotiation Packet
    init(
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        version: QUICVersion,
        versions: [QUICVersion]
    ) {
        identifier = PacketIdentifier(space: .initial, number: .none)
        longHeader = true
        versionNegotiation = true

        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.versions = versions

        var headerLength = Packet.longHeaderBaseSize
        headerLength += QUICConnectionID.headerCIDLength + destinationConnectionID.length
        headerLength += QUICConnectionID.headerCIDLength + sourceConnectionID.length
        headerLength += 4 * versions.count

        self.headerLength = UInt16(headerLength)

        self.version = version
    }

    // Initial Packet
    init(
        retryFirstOctet: UInt8? = nil,
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        keyState: PacketKeyState,
        space: PacketNumberSpace,
        version: QUICVersion,
        token: [UInt8],
        tag: [UInt8]? = nil,
        payloadLength: UInt16,
        headerLength: UInt16
    ) {
        self.init(
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            keyState: keyState,
            space: space,
            payloadLength: payloadLength,
            headerLength: headerLength
        )

        self.token = token
        self.version = version
        self.tag = tag
        self.retryFirstOctet = retryFirstOctet
    }

    // 0-RTT Packet, Handshake Packet, and Initial Packets
    init(
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID,
        keyState: PacketKeyState,
        space: PacketNumberSpace,
        payloadLength: UInt16,
        headerLength: UInt16,
        version: QUICVersion? = nil
    ) {
        identifier = PacketIdentifier(
            space: PacketNumberSpace.fromKeyState(keyState: keyState),
            number: .none
        )
        longHeader = true

        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.keyState = keyState

        self.payloadLength = payloadLength

        self.headerLength = headerLength
        self.version = version
    }

    // Short Header Packet
    init(destinationConnectionID: QUICConnectionID, headerLength: UInt16, spin: Bool) {
        identifier = PacketIdentifier(space: .applicationData, number: .none)
        self.destinationConnectionID = destinationConnectionID
        self.headerLength = headerLength
        spinValue = spin

        keyState = .phase0
    }

    static func requiresLongHeader(keyState: PacketKeyState?) -> Bool {
        switch keyState {
        case .phase0, .phase1:
            return false
        default:
            return true
        }
    }

    private mutating func buildLongHeader(
        frame: inout Frame,
        lastAcked: PacketNumber,
        token: [UInt8]? = nil,
        payloadLengthOffset: inout Int?,
        truncatedPacketNumberLength: inout Int,
        headerVersion: UInt32? = nil
    ) throws(QUICError) {
        guard let dcid = destinationConnectionID else {
            throw QUICError.packet(QUICPacketError.invalidDestinationConnectionID)
        }
        guard let scid = sourceConnectionID else {
            throw QUICError.packet(QUICPacketError.invalidSourceConnectionID)
        }
        // QUIC Long Header
        // 0                   1                   2                   3
        // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        // +-+-+-+-+-+-+-+-+
        // |1|1|T T|R R|P P|
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
        // |                           Length (i)                        ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |                    Packet Number (8/16/24/32)               ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |                          Payload (*)                        ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        let preamble: UInt8 = 0xC0  // 0b11RRTTPP
        var headerType: UInt8 = 0
        let rr: UInt8 = 0

        switch keyState {
        case .initial:
            headerType = 0x00
        case .handshake:
            headerType = 0x02
        case .earlyData:
            headerType = 0x01
        case .phase0, .phase1, .none:
            throw QUICError.packet(.invalidHeaderType)
        }

        let truncatedPacketNumber = try number.encode(
            lastAcked: lastAcked,
            fixedSize: overrideSentNumberSize
        )
        let numberLength = truncatedPacketNumber.headerFieldSize
        var version: UInt32 = version?.rawValue ?? QUICVersion.v1.rawValue
        if let headerVersion {
            version = headerVersion
        }
        // common long header elements
        let lengthBeforeWritingHeader = frame.unclaimedLength
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.uint8(preamble | (headerType << 4) | (rr << 2) | numberLength)
            try write.uint32NetworkByteOrder(version)
            try write.uint8(UInt8(dcid.length))
            try write.span(dcid.connectionIDStorage.span.bytes.extracting(0..<dcid.length))
            try write.uint8(UInt8(scid.length))
            try write.span(scid.connectionIDStorage.span.bytes.extracting(0..<scid.length))
        }
        try validateSerializationResult(result)

        if keyState == .initial {
            // this is an initial packet, write the token
            if let token {
                let result2 = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.vle(UInt16(token.count))
                    try write.buffer(token)
                }
                try validateSerializationResult(result2)
            } else {
                let result2 = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.vle(0)
                }
                try validateSerializationResult(result2)
            }
        }
        // payload length is packet number + payload + tag
        let payloadLength = truncatedPacketNumber.size.rawValue + Int(payloadLength) + Int(tagLength)
        // Make it possible to update to this field after write()ing
        payloadLengthOffset = (lengthBeforeWritingHeader - frame.unclaimedLength)
        let result3 = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            // This should be VLE encoded
            try write.uint16NetworkByteOrder(UInt16(1 << 14 | payloadLength))
            try write.encodedPacketNumber(truncatedPacketNumber)
        }
        try validateSerializationResult(result3)

        let lengthAfterWritingHeader = frame.unclaimedLength
        guard let packetNumberLength = UInt8(exactly: truncatedPacketNumber.size.rawValue) else {
            throw QUICError.packet(QUICPacketError.truncatedPacketNumberTooLarge)
        }
        self.packetNumberLength = packetNumberLength
        headerLength =
            UInt16((lengthBeforeWritingHeader - lengthAfterWritingHeader) - Int(self.packetNumberLength))
    }

    // To be called after header is unclaimed
    func updateLongHeaderPayloadLength(
        frame: inout Frame,
        payloadLengthOffset: Int
    ) throws(QUICError) {
        let result = Serializer.serialize(&frame, claim: false) {
            write throws(SerializationError) in
            try write.skip(payloadLengthOffset)
            try write.uint16NetworkByteOrder(UInt16(1 << 14 | self.payloadLength))
        }
        try validateSerializationResult(result)
    }

    private mutating func buildShortHeader(
        frame: inout Frame,
        lastAcked: PacketNumber,
        spin: Bool
    ) throws(QUICError) {
        // 0                   1                   2                   3
        // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        // +-+-+-+-+-+-+-+-+
        // |0|1|S|R|R|K|P P|
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |                Destination Connection ID (0..160)           ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |                     Packet Number (8/16/24/32)              ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |                     Protected Payload (*)                   ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        let preamble: UInt8 = 0x40  // = long header = 0, fixed = 1,

        var spinBit: UInt8 = 0x00
        if spin {
            spinBit = 0x20
        }
        let keyPhase: UInt8 = (keyState == .phase0) ? 0x00 : 0x04
        let truncatedPacketNumber = try number.encode(
            lastAcked: lastAcked,
            fixedSize: overrideSentNumberSize
        )

        // assemble the packet
        guard let dcid = destinationConnectionID else {
            throw QUICError.packet(QUICPacketError.invalidDestinationConnectionID)
        }

        let lengthBeforeWritingHeader = frame.unclaimedLength
        let numberLength = truncatedPacketNumber.headerFieldSize
        let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.uint8(preamble | spinBit | keyPhase | numberLength)
            try write.span(dcid.connectionIDStorage.span.bytes.extracting(0..<dcid.length))
            try write.encodedPacketNumber(truncatedPacketNumber)
        }

        try validateSerializationResult(result)

        let lengthAfterWritingHeader = frame.unclaimedLength
        guard let packetNumberLength = UInt8(exactly: truncatedPacketNumber.size.rawValue) else {
            throw QUICError.packet(QUICPacketError.truncatedPacketNumberTooLarge)
        }
        self.packetNumberLength = packetNumberLength
        headerLength = UInt16((lengthBeforeWritingHeader - lengthAfterWritingHeader) - Int(packetNumberLength))
    }

    // MARK: Serialize to wire format
    mutating func writeHeader(
        into frame: inout Frame,
        lastAcked: PacketNumber,
        token: [UInt8]? = nil,
        payloadLengthOffset: inout Int?,
        truncatedPacketNumberLength: inout Int,
        spin: Bool = false,
        headerVersion: UInt32? = nil,
    ) throws(QUICError) {
        if Packet.requiresLongHeader(keyState: keyState) {
            try buildLongHeader(
                frame: &frame,
                lastAcked: lastAcked,
                token: token,
                payloadLengthOffset: &payloadLengthOffset,
                truncatedPacketNumberLength: &truncatedPacketNumberLength,
                headerVersion: headerVersion
            )
        } else {
            try buildShortHeader(frame: &frame, lastAcked: lastAcked, spin: spin)
        }
    }

    mutating func update(spinValue: Bool) {
        if !longHeader {
            self.spinValue = spinValue
        }
    }

    // MARK: Update KeyState
    // During shortheader processing, keyState will change from .phase0 to phase1
    // Note: keystate is part of the protected region of the header so cannot be
    // determined during initial deserialization when a Packet is initialized
    mutating func updateKeyState(to newState: PacketKeyState) throws(QUICError) {
        if longHeader {
            throw QUICError.packet(QUICPacketError.longheaderKeyStateUpdate)
        }
        keyState = newState
    }

    // MARK: Deserialize from wire

    // Helpers
    private func validateSerializationResult(_ result: SerializationResult) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.packet(QUICPacketError.serializationBufferTooSmall)
        }
    }

    private func validateDeserializationResult(
        _ result: DeserializationResult
    ) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.packet(QUICPacketError.deserializationError)
        }
    }
}

@available(Network 0.1.0, *)
extension InPlaceSerializer where Factory: ~Escapable, Factory: ~Copyable {

    mutating func connectionID(_ value: QUICConnectionID) throws(SerializationError) {
        try self.uint8(UInt8(value.length))
        try self.buffer(value.connectionID)
    }

    mutating func encodedPacketNumber(_ value: EncodedPacketNumber) throws(SerializationError) {
        let encodedSize = value.size.rawValue
        let offset = MemoryLayout<UInt64>.size - encodedSize

        try withUnsafeBytes(of: value.number.bigEndian) { bytes throws(SerializationError) in
            let sourcePtr = bytes.baseAddress!.advanced(by: offset)
            let bufferPtr = UnsafeBufferPointer(
                start: sourcePtr.assumingMemoryBound(to: UInt8.self),
                count: encodedSize
            )
            try self.span(bufferPtr.span.bytes)
        }
    }
}
#endif
