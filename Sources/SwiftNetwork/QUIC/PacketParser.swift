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
internal import DequeModule
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

@available(Network 0.1.0, *)
struct PacketParser: ~Copyable, PrefixedLoggable {
    var log: LogPrefixer

    // Temporary storage for the frames parsed out of the packet currently being
    // processed.
    var framesReceived = NetworkUniqueDeque<QUICFrame>()

    // Initial capacity for `framesReceived`.
    private static var framesReceivedCapacity: Int { 16 }

    init(logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        self.framesReceived.reserveCapacity(Self.framesReceivedCapacity)
    }

    // Drain any frames which haven't been processed, finalizing the ones holding
    // borrowed buffers so that they aren't leaked.
    mutating func cleanupReceivedFrames() {
        while let receivedFrame = self.framesReceived.popFirst() {
            switch receivedFrame {
            case .crypto(var frame):
                frame.frame.finalize(success: false)
            case .stream(var frame):
                frame.frame.finalize(success: false)
            case .datagram(var frame):
                frame.frame.finalize(success: false)
            default: continue
            }
        }

        // A packet stuffed with single byte frames can grow the deque a long way; a peer
        // shouldn't be able to pin that storage for the lifetime of the connection.
        if self.framesReceived.capacity > QUICPreferences.shared.maxReceivedFramesCapacity {
            self.framesReceived.reallocate(capacity: Self.framesReceivedCapacity)
        }
    }

    private func parsePacketNumber(
        frame: inout Frame,
        pnSize: UInt8
    ) throws(QUICError) -> PacketNumber? {
        var packetNumber: PacketNumber = .none
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.packetNumber(&packetNumber, pnSize: pnSize)
        }
        do {
            try validateDeserializationResult(result)
        } catch {
            log.error("Failed to deserialize packet number")
            return nil
        }
        return packetNumber
    }

    @inline(never)
    private mutating func parseFrames(
        frame: inout Frame,
        packet: inout Packet,
        connection: QUICConnection,
        isLastPacketInFrame: Bool
    ) throws(QUICError) {
        if QUICShorthandFrame.shouldGenerateShorthandFrames(hasQLog: (connection.qLog != nil)) {
            packet.shorthandFrames = .init()
        }
        while frame.unclaimedLength > 0 {
            var rawType: UInt64 = 0
            let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                try read.vle(&rawType)
            }
            try validateDeserializationResult(result)

            guard let type = FrameType(rawValue: rawType) else {
                connection.log.error("Invalid frame type \(rawType) (pn \(packet.number))")
                throw QUICError.frameParse(FrameParseError.invalidType(rawType))
            }
            let typeLength = rawType.variableLengthSize

            // RFC9000: "To ensure simple and efficient implementations of
            // frame parsing, a frame type MUST use the shortest possible
            // encoding."

            if _slowPath(type.isOneByte && typeLength != 1) {
                connection.close(with: .protocolViolation, "Invalid frame type encoding")
                throw QUICError.frameParse(
                    FrameParseError.invalidValue("Invalid frame type encoding")
                )
            }
            let quicFrame = try QUICFrame.parse(
                type: type,
                frame: &frame,
                packet: &packet,
                connection: connection,
                isLastPacketInFrame: isLastPacketInFrame
            )
            self.framesReceived.append(quicFrame)
        }
    }

    @inline(never)
    private func decodePacketNumber(
        frame: inout Frame,
        packet: inout Packet,
        receivedLargestPacketNumber: PacketNumber,
        connection: QUICConnection
    ) throws(QUICError) -> Int {

        var firstOctet: UInt8 = 0
        let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
            try read.uint8(&firstOctet)
        }
        try validateDeserializationResult(result)

        // reclaim deserialized header after protector decryption.
        guard frame.claim(fromStart: Int(packet.headerLength)) else {
            throw QUICError.packet(QUICPacketError.invalidHeaderType)
        }

        let pnSize = (firstOctet & 0x03) + 1

        // Retrieve the reserved bits _after_ decryption of the header.
        let reservedBits: Int
        if packet.longHeader {
            reservedBits = Int(firstOctet & 0x0c)
        } else {
            reservedBits = Int(firstOctet & 0x18)
            if firstOctet & 0x04 != 0 {
                try packet.updateKeyState(to: .phase1)
            } else {
                try packet.updateKeyState(to: .phase0)
            }
        }
        let number = try parsePacketNumber(frame: &frame, pnSize: pnSize)
        guard let number else {
            throw QUICError.packet(QUICPacketError.invalidPacketNumber)
        }

        packet.identifier = PacketIdentifier(space: packet.numberSpace, number: number)
        packet.packetNumberLength = pnSize

        // Decode the packet number.  Slightly improved version from what's in Appendix A.
        let receivedExpectedPacketNumber = receivedLargestPacketNumber + 1
        let packetNumberBits = pnSize * 8
        let packetNumberLength: Int64 = 1 << packetNumberBits
        let packetNumberWindow = packetNumberLength / 2
        let receivedExpectedPacketNumberMasked =
            (receivedLargestPacketNumber.value + packetNumberWindow) & ~(packetNumberLength - 1)

        packet.number = packet.number + Int64(receivedExpectedPacketNumberMasked)

        if packet.number > receivedExpectedPacketNumber + packetNumberWindow,
            packet.number > packetNumberLength
        {
            packet.number = packet.number - Int64(packetNumberLength)
        }
        connection.log.datapath("received pn \(packet.number.value)")
        return reservedBits
    }

    mutating func parse(
        frame: inout Frame,
        connection: QUICConnection,
        path: QUICPath,
        ecn: IPProtocol.ECN
    ) -> Packet? {
        if _slowPath(frame.unclaimedLength < Constants.minimumPacketSize) {
            connection.log.error("Dropping short packet, len=\(frame.unclaimedLength)")
            return nil
        }

        let localCIDLength = connection.localCIDLength
        do throws(QUICError) {
            var packet = try parseHeader(frame: &frame, dcidLength: localCIDLength)
            if packet.versionNegotiation {
                if frame.unclaimedLength != 0 {
                    connection.log.error("Extra data after VERSION_NEGOTIATION")
                    return nil
                }
                return packet
            }
            if packet.retry {
                if frame.unclaimedLength != 0 {
                    connection.log.error("Extra data after RETRY integrity tag")
                    return nil
                }
                return packet
            }

            var receivedLargestPacketNumber = PacketNumber.none
            _ = connection.ack.withAckSpace(
                packetNumberSpace: packet.numberSpace
            ) { ackSpace in
                receivedLargestPacketNumber = ackSpace.largestPNReceived
                return true
            }

            // unclaim deserialized header for protector decryption
            guard frame.unclaim(fromStart: Int(packet.headerLength), fromEnd: 0) else {
                return nil
            }

            packet.tagLength = connection.protector.getTagSize(for: packet.keyState)
            guard openHeader(connection: connection, packet: &packet, frame: &frame) else {
                return nil
            }

            let reservedBits = try decodePacketNumber(
                frame: &frame,
                packet: &packet,
                receivedLargestPacketNumber: receivedLargestPacketNumber,
                connection: connection
            )

            let extraLength: Int
            if packet.longHeader {
                // At this point, the packet number is already claimed, so subtract it from the remaining payload length
                let remainingPayloadLength = Int(packet.payloadLength) - Int(packet.packetNumberLength)
                guard frame.unclaimedLength >= remainingPayloadLength else {
                    connection.log.error(
                        "Short LH packet: \(frame.unclaimedLength) < \(remainingPayloadLength)"
                    )
                    return nil
                }

                extraLength = frame.unclaimedLength - remainingPayloadLength
            } else {
                // Short header packets don't parse out any payload length from the header,
                // and always extend to the end of the outer datagram
                extraLength = 0

                // Payload length includes the packet number length
                packet.payloadLength = UInt16(frame.unclaimedLength + Int(packet.packetNumberLength))
            }

            // unclaim deserialized header for protector decryption
            guard frame.unclaim(fromStart: Int(packet.headerLength) + Int(packet.packetNumberLength))
            else {
                return nil
            }
            do {
                try openPacket(packet: &packet, frame: &frame, connection: connection)
            } catch {
                // Only parse the tag if we have failed decryption, for performance reasons
                // The tag should contain the stateless reset token and we don't want to parse it unnecessarily
                packet.tag = parseTag(frame: &frame)
                packet.failedDecryption = true
                return packet
            }

            // Claim off any extra length from the end to ignore it
            let tagLength = Int(packet.tagLength)
            guard
                frame.claim(
                    fromStart: Int(packet.headerLength) + Int(packet.packetNumberLength),
                    fromEnd: tagLength + extraLength
                )
            else {
                return nil
            }
            defer {
                // At this point, the entire packet payload has been read. If there is another packet at the end,
                // unclaim to expose it, and re-mark the tag length.
                if extraLength > 0 {
                    _ = frame.unclaim(fromStart: 0, fromEnd: tagLength + extraLength)
                    _ = frame.claim(fromStart: tagLength)
                }
            }

            // At this point we have decrypted and authenticated the
            // packet so we're free to close the connection with
            // a PROTOCOL_VIOLATION if needed.

            guard reservedBits == 0 else {
                let reason = "Reserved bits are not zero"
                connection.log.error("\(reason)")
                connection.close(with: .protocolViolation, reason)
                return nil
            }

            if frame.unclaimedLength == 0 {
                connection.log.error("Packet with no frames")
                return packet
            }

            do throws(QUICError) {
                try parseFrames(
                    frame: &frame,
                    packet: &packet,
                    connection: connection,
                    isLastPacketInFrame: extraLength == 0
                )
            } catch {
                // Explicitly release finalize frames in case of error
                self.cleanupReceivedFrames()
                throw error
            }
            return packet
        } catch {
            return nil
        }
    }

    private func parseHeader(frame: inout Frame, dcidLength: Int) throws(QUICError) -> Packet {
        var firstOctet: UInt8 = 0
        let originalLength = frame.unclaimedLength
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.uint8(&firstOctet)
        }
        try validateDeserializationResult(result)

        // Common short/long header bits
        let longHeader = (firstOctet & 0x80) != 0

        var packet: Packet
        if longHeader {
            packet = try parseLongHeader(
                frame: &frame,
                firstOctet: firstOctet,
                originalLength: originalLength
            )
        } else {
            packet = try parseShortHeader(
                frame: &frame,
                firstOctet: firstOctet,
                dcidLength: dcidLength,
                originalLength: originalLength
            )
        }
        return packet
    }

    private func parseLongHeader(
        frame: inout Frame,
        firstOctet: UInt8,
        originalLength: Int,
        isServer: Bool = false
    ) throws(QUICError) -> Packet {
        var rawVersion: UInt32 = 0
        var dcidLength: UInt8 = 0
        var dcidStorage = QUICConnectionIDStorage.empty
        var scidLength: UInt8 = 0
        var scidStorage = QUICConnectionIDStorage.empty
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(&rawVersion)
            try read.uint8(&dcidLength)
            try read.connectionID(&dcidStorage, length: Int(dcidLength))
            try read.uint8(&scidLength)
            try read.connectionID(&scidStorage, length: Int(scidLength))
        }
        try validateDeserializationResult(result)

        let destinationConnectionID = QUICConnectionID(storage: dcidStorage, size: Int(dcidLength))
        let sourceConnectionID = QUICConnectionID(storage: scidStorage, size: Int(scidLength))

        var version = QUICVersion(rawValue: rawVersion)
        // If the server received an unknown version set the version as the negotiation pattern to negotiate a supported version.
        // If the client received a bad version, throw the error here to close the connection.
        if version == nil && isServer {
            version = QUICVersion.negotiationPattern
        }
        guard let version else {
            log.error("Invalid QUIC version: \(rawVersion)")
            throw QUICError.packet(QUICPacketError.invalidVersionNumber)
        }

        // VN and LH have the same header up to this point.
        if version == .negotiation {
            guard frame.unclaimedLength % 4 == 0 else {
                log.error("Odd number of versions: \(frame.unclaimedLength % 4)")
                throw QUICError.packet(QUICPacketError.deserializationError)
            }

            let numberOfVersions = frame.unclaimedLength / 4
            guard numberOfVersions <= 16 else {
                log.error("Too many versions: \(numberOfVersions)")
                throw QUICError.packet(QUICPacketError.deserializationError)
            }

            var versionsBuffer = [UInt32](repeating: 0, count: numberOfVersions)
            let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                for i in 0..<numberOfVersions {
                    try read.uint32NetworkByteOrder(&versionsBuffer[i])
                }
            }
            try validateDeserializationResult(result)
            // Only return valid versions that are not the negotiationPattern
            var versions: [QUICVersion] = []
            for rawVersion in versionsBuffer {
                if let version = QUICVersion(rawValue: rawVersion),
                    version != QUICVersion.negotiationPattern
                {
                    versions.append(version)
                }
            }

            return Packet(
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                version: version,
                versions: versions
            )

        } else {
            let fixed = (firstOctet & 0x40) != 0
            let packetType = (firstOctet & 0x30) >> 4

            if _slowPath(!fixed) {
                log.error("Long header fixed bit is zero")
                throw QUICError.packet(QUICPacketError.deserializationError)
            }

            var payloadLength: UInt16 = 0
            var keyState: PacketKeyState
            switch packetType {
            case 0x0:
                // Initial Packet
                var rawTokenLength: Int = 0
                var tokenBuffer: [UInt8] = []
                let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                    try read.vle(&rawTokenLength)
                    try read.buffer(&tokenBuffer, length: Int(rawTokenLength))
                    try read.vle(&payloadLength)
                }
                try validateDeserializationResult(result)
                keyState = .initial
                return Packet(
                    destinationConnectionID: destinationConnectionID,
                    sourceConnectionID: sourceConnectionID,
                    keyState: keyState,
                    space: PacketNumberSpace.fromKeyState(keyState: keyState),
                    version: version,
                    token: tokenBuffer,
                    payloadLength: payloadLength,
                    headerLength: UInt16(originalLength - frame.unclaimedLength)
                )
            case 0x1:
                // 0-RTT Packet
                keyState = .earlyData
                let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                    try read.vle(&payloadLength)
                }
                try validateDeserializationResult(result)
            case 0x2:
                // Handshake Packet
                keyState = .handshake
                let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                    try read.vle(&payloadLength)
                }
                try validateDeserializationResult(result)
            case 0x3:
                // Retry Packet
                var retryToken: [UInt8] = []
                var retryIntegrityTag: [UInt8] = []
                let tokenLength =
                    frame.unclaimedLength - Int(Constants.retryTokenIntegrityTagLength)
                let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                    try read.buffer(&retryToken, length: tokenLength)
                    try read.buffer(
                        &retryIntegrityTag,
                        length: Int(Constants.retryTokenIntegrityTagLength)
                    )
                }
                try validateDeserializationResult(result)
                keyState = .initial
                return Packet(
                    retryFirstOctet: firstOctet,
                    destinationConnectionID: destinationConnectionID,
                    sourceConnectionID: sourceConnectionID,
                    keyState: keyState,
                    space: PacketNumberSpace.fromKeyState(keyState: keyState),
                    version: version,
                    token: retryToken,
                    tag: retryIntegrityTag,
                    payloadLength: payloadLength,
                    headerLength: UInt16(originalLength - frame.unclaimedLength)
                )

            default:
                throw QUICError.packet(QUICPacketError.deserializationError)
            }
            let space = PacketNumberSpace.fromKeyState(keyState: keyState)

            // MARK: See comment in parseHeader. Length may be different for each packet type
            return Packet(
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                keyState: keyState,
                space: space,
                payloadLength: payloadLength,
                headerLength: UInt16(originalLength - frame.unclaimedLength),
                version: version
            )
        }
    }

    private func parseShortHeader(
        frame: inout Frame,
        firstOctet: UInt8,
        dcidLength: Int,
        originalLength: Int
    ) throws(QUICError) -> Packet {
        let fixed = (firstOctet & 0x40) != 0
        let spinValue = (firstOctet & 0x20) != 0

        if _slowPath(!fixed) {
            log.error("Short header fixed bit is zero")
            throw QUICError.packet(QUICPacketError.deserializationError)
        }

        var dcidStorage = QUICConnectionIDStorage.empty
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.connectionID(&dcidStorage, length: dcidLength)
        }
        try validateDeserializationResult(result)

        let destinationConnectionID = QUICConnectionID(storage: dcidStorage, size: Int(dcidLength))
        return Packet(
            destinationConnectionID: destinationConnectionID,
            headerLength: UInt16(originalLength - frame.unclaimedLength),
            spin: spinValue
        )
    }

    private func openHeader(
        connection: QUICConnection,
        packet: inout Packet,
        frame: inout Frame
    ) -> Bool {
        if connection.state == .versionSent, let dcid = packet.destinationConnectionID {
            connection.protector.deriveInitialSecrets(destinationCID: dcid)
        }

        if let keystate = packet.keyState,
            !connection.protector.openKeyReady(for: keystate)
                || (!connection.state.isConnected && (keystate == .phase0 || keystate == .phase1))
        {
            if keystate == .initial || keystate == .earlyData {
                connection.log.debug("Not queueing INITIAL/0-RTT packets")
                return false
            }
            connection.log.debug(
                "Either encryption level \(keystate) not ready or not yet connected. Currently \(connection.state.isConnected ? "connected" : "not connected"); queueing packet"
            )
            return false
        }

        do {
            try connection.protector.openHeader(&packet, frame: &frame)
        } catch {
            connection.log.error("Packet number undecryptable")
            return false
        }

        return true
    }

    private func openPacket(
        packet: inout Packet,
        frame: inout Frame,
        connection: QUICConnection
    ) throws(QUICError) {
        if _slowPath(
            (connection.keyState == .phase0 || connection.keyState == .phase1)
                && (packet.keyState == .phase0 || packet.keyState == .phase1)
                && connection.keyState != packet.keyState
        ) {
            connection.protector.trafficUpdate(previousKeyState: connection.keyState)
        }

        try connection.protector.open(&packet, frame: &frame)
    }

    private func validateDeserializationResult(
        _ result: DeserializationResult
    ) throws(QUICError) {
        guard result.isValid else {
            throw QUICError.packet(QUICPacketError.deserializationError)
        }
    }

    func retryTokenPresent(_ frame: inout Frame, token: [UInt8]?) -> Bool {
        guard let token else {
            log.error("Token is nil, discarding")
            return false
        }
        guard let firstOctet = try? self.parseFirstOctet(&frame, claim: false) else {
            log.error("Could not parse first octet from packet")
            return false
        }
        let longHeader = (firstOctet & 0x80) != 0
        guard longHeader else {
            log.error("Received invalid packet")
            return false
        }
        let packetType = (firstOctet & 0x30) >> 4
        guard packetType == 0x0 else {
            log.error("Received packet when expecting Initial with retry token")
            return false
        }
        var dcidLength: UInt8 = 0
        var scidLength: UInt8 = 0
        // Do not actually move the cursor
        let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
            // Skip through to the token length and token, do not claim these values
            try read.skip(1)
            try read.skip(4)
            try read.uint8(&dcidLength)
            try read.skip(Int(dcidLength))
            try read.uint8(&scidLength)
            try read.skip(Int(scidLength))
            try read.vle(expect: token.count)
            try read.span(expect: token.span.bytes)
        }
        guard result.isValid else {
            log.error("Could not parse a valid token from the packet")
            return false
        }
        return true
    }

    func parseFirstOctet(_ frame: inout Frame, claim: Bool = true) throws(QUICError) -> UInt8 {
        var firstOctet: UInt8 = 0
        let result = Deserializer.deserialize(&frame, claim: claim) { read throws(DeserializationError) in
            try read.uint8(&firstOctet)
        }
        try validateDeserializationResult(result)
        return firstOctet
    }

    // This mirrors parseHeader() except that Short Header is purposefully not handled here.
    func parsePrelude(frame: inout Frame) -> Packet? {
        // This differs from parseHeader as it may NOT return a packet
        // parsePrelude is also not designed to parse short header packets
        // parsePrelude will only be called from a server context.
        do {
            let originalLength = frame.unclaimedLength
            let firstOctet = try parseFirstOctet(&frame)
            // Common short/long header bits
            let longHeader = (firstOctet & 0x80) != 0

            var packet: Packet
            if longHeader {
                packet = try parseLongHeader(
                    frame: &frame,
                    firstOctet: firstOctet,
                    originalLength: originalLength,
                    isServer: true
                )
                return packet
            }
            // parsePrelude does not handle short headers
            log.datapath("Ignoring short header")
            return nil
        } catch {
            log.datapath("Unable to parse frame")
            return nil
        }
    }

    func parseTag(frame: inout Frame) -> [UInt8]? {
        // The endpoint identifies a received datagram as a stateless reset by comparing the last 16 bytes
        // of the datagram with all Stateless Reset Tokens associated with the remote address on which the datagram was received.
        //
        // Parse the entire payload and only extract the last 16 bytes to set as the tag
        let length = frame.unclaimedLength
        if length >= Constants.statelessResetTokenSize {
            var tag: [UInt8] = []
            let cursor = length - Constants.statelessResetTokenSize
            let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                try read.skip(cursor)  // Move the cursor in the frame to where the SRT starts
                try read.buffer(&tag, length: Constants.statelessResetTokenSize)
            }
            do {
                try validateDeserializationResult(result)
            } catch {
                return nil
            }
            // We only need the last 16 bytes specifically for the stateless reset token
            if tag.count >= Constants.statelessResetTokenSize {
                return tag
            }
        }
        return nil
    }
}

@available(Network 0.1.0, *)
extension Deserializer where Factory: ~Escapable {
    mutating func packetNumber(_ value: inout PacketNumber, pnSize: UInt8) throws(DeserializationError) {
        switch pnSize {
        case 1:
            // 1 byte
            var pn: UInt8 = 0
            try self.uint8(&pn)
            value = PacketNumber(Int64(pn))
        case 2:
            // 2 bytes
            var pn: UInt16 = 0
            try self.uint16NetworkByteOrder(&pn)
            value = PacketNumber(Int64(pn))
        case 3:
            // 3 bytes
            var high: UInt8 = 0
            var middle: UInt8 = 0
            var low: UInt8 = 0
            try self.uint8(&high)
            try self.uint8(&middle)
            try self.uint8(&low)
            let pn = UInt32(high) << 16 | UInt32(middle) << 8 | UInt32(low)
            value = PacketNumber(Int64(pn))
        case 4:
            // 4 bytes
            var pn: UInt32 = 0
            try self.uint32NetworkByteOrder(&pn)
            value = PacketNumber(Int64(pn))
        default:
            value = PacketNumber(-1)
            try invalidate(.validationFailed)
        }
    }

    public mutating func connectionID(
        _ value: inout QUICConnectionIDStorage,
        length: Int
    ) throws(DeserializationError) {
        guard length <= QUICConnectionID.maximumSize else {
            try invalidate(.parsingFailed)
        }
        var mutableBytes = value.mutableSpan
        try self.span(&mutableBytes, length: length)
    }
}
#endif
