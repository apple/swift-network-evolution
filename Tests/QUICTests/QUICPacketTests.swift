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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

@available(Network 0.1.0, *)
final class PacketTests: XCTestCase {
    func testRequiresLongHeader() {
        for keyState in PacketKeyState.allCases {
            if keyState == .phase0 || keyState == .phase1 {
                XCTAssertFalse(Packet.requiresLongHeader(keyState: keyState))
                continue
            }
            XCTAssertTrue(Packet.requiresLongHeader(keyState: keyState))
        }
    }

    func testPacketKeyStateRequiresLongHeader() {
        for keyState in PacketKeyState.allCases {
            let packet = Packet(
                number: PacketNumber(1),
                lastAcked: 0,
                keyState: keyState
            )
            if keyState == .phase0 || keyState == .phase1 {
                XCTAssertFalse(packet.longHeader)
            } else {
                XCTAssertTrue(packet.longHeader)
            }
        }
    }

    func testCleanupReceivedFrames_drainsEntireDeque() {
        var parser = PacketParser(logPrefixer: LogPrefixer("[PacketTests]"))
        parser.framesReceived.append(
            .stream(frame: FrameStreamReceived(id: 0, offset: 0, data: [1, 2, 3]))
        )
        parser.framesReceived.append(
            .stream(frame: FrameStreamReceived(id: 4, offset: 0, data: [4, 5, 6]))
        )

        parser.cleanupReceivedFrames()

        // Drain leftover frames at the end of the test to avoid precondition failure in deinit.
        defer {
            while let leftover = parser.framesReceived.popFirst() {
                switch leftover {
                case .crypto(var f): f.frame.finalize(success: false)
                case .stream(var f): f.frame.finalize(success: false)
                case .datagram(var f): f.frame.finalize(success: false)
                default: break
                }
            }
        }

        XCTAssertTrue(
            parser.framesReceived.isEmpty,
            "cleanupReceivedFrames must drain all frames, not just the first"
        )
    }

    class PacketBox {
        var packet: Packet
        init(_ packet: consuming Packet) {
            self.packet = packet
        }
    }

    typealias TestVector = (entry: PacketBox, expect: [UInt8], enableSpinBit: Bool)

    func createPacket(
        number: PacketNumber,
        overrideSentNumberSize: EncodedPacketNumber.Size?,
        keyState: PacketKeyState
    ) -> Packet {
        var packet = Packet(
            number: number,
            lastAcked: 0,
            keyState: keyState
        )
        packet.overrideSentNumberSize = overrideSentNumberSize
        return packet
    }

    func testWriteShortHeader() throws {

        let vectors: [TestVector] = [
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .oneByte, keyState: .phase0)
                ),
                [0x40, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .twoBytes, keyState: .phase0)
                ),
                [0x41, 0x0, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .threeBytes, keyState: .phase0)
                ),
                [0x42, 0x0, 0x0, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .fourBytes, keyState: .phase0)
                ),
                [0x43, 0x0, 0x0, 0x0, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: nil, keyState: .phase0)
                ),
                [0x40, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 0x1111, overrideSentNumberSize: nil, keyState: .phase0)
                ),
                [0x41, 0x11, 0x11],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 0x11_1111, overrideSentNumberSize: nil, keyState: .phase0)
                ),
                [0x42, 0x11, 0x11, 0x11],
                false
            ),
            (
                PacketBox(
                    createPacket(
                        number: 0x7fff_ffff,
                        overrideSentNumberSize: nil,
                        keyState: .phase0
                    )
                ),
                [0x43, 0x7f, 0xff, 0xff, 0xff],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .oneByte, keyState: .phase0)
                ),
                [0x60, 0x1],
                true
            ),
            (
                PacketBox(
                    createPacket(number: 0x08, overrideSentNumberSize: .oneByte, keyState: .phase0)
                ),
                [0x60, 0x08],
                true
            ),
        ]
        var theFrame = Frame(count: 100)
        defer {
            theFrame.finalize(success: true)
        }

        var payloadLengthOffset: Int?
        var truncatedPacketNumberLength: Int = 0
        for (number, vector) in vectors.enumerated() {
            try vector.entry.packet.writeHeader(
                into: &theFrame,
                lastAcked: 0,
                payloadLengthOffset: &payloadLengthOffset,
                truncatedPacketNumberLength: &truncatedPacketNumberLength,
                spin: vector.enableSpinBit
            )
            let result = extractPacket(frame: &theFrame)
            XCTAssertEqual(vector.expect, result, "Failed vector: \(number)")
        }
    }

    #if NETWORK_PERF_TESTS
    func testWriteShortHeaderPerformance() {
        var theFrame = Frame(count: 1400)
        defer {
            theFrame.finalize(success: true)
        }

        var packets: [PacketBox] = []
        for idx in 0..<1_000 {
            var packet = createPacket(
                number: PacketNumber(Int64(idx)),
                overrideSentNumberSize: nil,
                keyState: .phase0
            )
            packet.update(spinValue: true)  // avoids log message during test
            let packetBox = PacketBox(packet)
            packets.append(packetBox)
        }
        var payloadLengthOffset: Int?
        var truncatedPacketNumberLength: Int = 0
        measure {
            for _ in 0..<1_000 {
                for packetEntry in packets {
                    try! packetEntry.packet.writeHeader(
                        into: &theFrame,
                        lastAcked: .none,
                        payloadLengthOffset: &payloadLengthOffset,
                        truncatedPacketNumberLength: &truncatedPacketNumberLength,
                        spin: false
                    )
                    theFrame.startOffset = 0
                }
            }
        }
    }
    #endif

    func testWriteLongHeader() throws {
        let vectors: [TestVector] = [

            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .oneByte, keyState: .initial)
                ),
                // Initial packet:     v1 dcid+scid Tlen  PayloadLen  PacketNumber
                [0xc0, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x01, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .twoBytes, keyState: .initial)
                ),
                [0xc1, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x02, 0x0, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .threeBytes, keyState: .initial)
                ),
                [0xc2, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x03, 0x0, 0x0, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: .fourBytes, keyState: .initial)
                ),
                [0xc3, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x04, 0x0, 0x0, 0x0, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 1, overrideSentNumberSize: nil, keyState: .initial)
                ),
                [0xc0, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x01, 0x1],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 0x1111, overrideSentNumberSize: nil, keyState: .initial)
                ),
                [0xc1, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x02, 0x11, 0x11],
                false
            ),
            (
                PacketBox(
                    createPacket(number: 0x11_1111, overrideSentNumberSize: nil, keyState: .initial)
                ),
                [0xc2, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x03, 0x11, 0x11, 0x11],
                false
            ),
            (
                PacketBox(
                    createPacket(
                        number: 0x7fff_ffff,
                        overrideSentNumberSize: nil,
                        keyState: .initial
                    )
                ),
                [0xc3, 0x0, 0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x40, 0x04, 0x7f, 0xff, 0xff, 0xff],
                false
            ),
        ]
        var theFrame = Frame(count: 100)
        defer {
            theFrame.finalize(success: true)
        }

        var payloadLengthOffset: Int?
        var truncatedPacketNumberLength: Int = 0
        for (number, vector) in vectors.enumerated() {
            try vector.entry.packet.writeHeader(
                into: &theFrame,
                lastAcked: 0,
                payloadLengthOffset: &payloadLengthOffset,
                truncatedPacketNumberLength: &truncatedPacketNumberLength,
                spin: false
            )
            let result = extractPacket(frame: &theFrame)
            XCTAssertEqual(vector.expect, result, "Failed vector: \(number)")
        }
    }

    // MARK: - Utilities
    func extractPacket(frame: inout Frame) -> [UInt8] {
        let claimedLength = frame.startOffset
        let frameLength = frame.bufferLength
        XCTAssertTrue(frame.unclaim(fromStart: claimedLength))

        let bytes = frame.span!
        var result = [UInt8](copying: bytes, maxCount: bytes.count)
        // if the test fails, claimedLength may be 0. Don't attempt to trim the result
        if result.count >= (frameLength - claimedLength) {
            result.removeLast(frameLength - claimedLength)
        }
        return result
    }

    func testPacketNumberSpaceIDTruncate() throws {
        typealias Vector = (
            description: String,
            pn: PacketNumber,
            lastAcked: PacketNumber,
            expected: PacketNumber?,
            expectedSize: Int?,
            willThrow: Bool
        )
        let testVectors: [Vector] = [
            // called with bad packet number
            ("Invalid value: packet number = .none", .none, .initial, nil, nil, true),
            // called with packet number not greater than last acked
            ("Invalid value: lastAcked > current packet number", 0, 1, nil, nil, true),
            ("Invalid value: lastAcked == current packet number", 1, 1, nil, nil, true),
            // First packet will be sent with lastAcked not set
            ("Valid first packet", 0, .none, 0, 1, false),
            ("Last 1-byte truncated packet number", 0x7f, 0, 0x7f, 1, false),
            ("First 2-byte encoded packet number", 0x80, 0, 0x80, 2, false),
            ("Last 2-byte encoded packet number", 0x7fff, 0, 0x7fff, 2, false),
            ("First 3-byte encoded packet number", 0x8000, 0, 0x8000, 3, false),
            ("Last 3-byte encoded packet number", 0x7f_ffff, 0, 0x7f_ffff, 3, false),
            ("First 4-byte encoded packet number", 0x80_0000, 0, 0x80_0000, 4, false),
            ("Last 4-byte encoded packet number", 0x7fff_ffff, 0, 0x7fff_ffff, 4, false),
            // RFC 9000: section 17.2 and 17.3 packet number length maximum = 4 bytes
            (
                "Invalid value: encoded packet number too large", 0x8000_0000, 0, 0x8000_0000, nil,
                true
            ),
        ]

        for vector in testVectors {
            var result: EncodedPacketNumber
            let pn = vector.pn
            if vector.willThrow {
                XCTAssertThrowsError(try pn.encode(lastAcked: vector.lastAcked))
            } else {
                result = try pn.encode(lastAcked: vector.lastAcked)
                XCTAssertEqual(
                    vector.expected,
                    PacketNumber(result.number),
                    "Failed test: \(vector.description)"
                )
                XCTAssertEqual(
                    vector.expectedSize,
                    result.size.rawValue,
                    "Failed test: \(vector.description)"
                )
            }
        }
    }

    func testQUICStatelessResetPacket() throws {

        let validToken: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08,
        ]
        let packet = try QUICConnectionUtilities.createStatelessResetPacket(
            token: QUICStatelessResetToken(validToken)!,
            triggeringPacketLength: 35
        )
        XCTAssertEqual(packet.count, 34, "Should have created a valid stateless reset packet")
        let suffixTag = Array(packet.suffix(16))
        XCTAssertEqual(
            suffixTag,
            validToken,
            "Last 16 bytes of the datagram and the token should match"
        )
        XCTAssertTrue((packet[0] & 0x80) == 0, "Packet is not marked as a short header packet")

        XCTAssertThrowsError(
            try QUICConnectionUtilities.createStatelessResetPacket(
                token: QUICStatelessResetToken(validToken)!,
                triggeringPacketLength: 4
            ),
            "Stateless Reset packet bytes needs to be greater than 21 bytes"
        ) { error in
            guard let networkError = error as? NetworkError else {
                XCTFail("Expected a NetworkError, got \(error)")
                return
            }
            XCTAssertEqual(
                networkError.category?.identifier,
                "QUICUtilities",
                "Should fail with the packetFailedToBuild category due to an invalid packet size"
            )
        }
    }

    func testQUICVersionNegotiationPacket() throws {

        let destinationConnectionID = QUICConnectionID([0xAA, 0xBB, 0xCC, 0xDD])!
        let sourceConnectionID = QUICConnectionID([
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        ])!

        let vnPacket = try XCTUnwrap(
            try QUICConnectionUtilities.createVersionNegotiationPacket(
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID
            )
        )

        // firstByte(1) + version(4) + dcidLen(1) + dcid(8) + scidLen(1) + scid(4) + v1(4) + negotiationPattern(4)
        XCTAssertEqual(vnPacket.count, 27, "Should have created a valid version negotiation packet")
        XCTAssertTrue((vnPacket[0] & 0x80) != 0, "Packet is not marked as a long header packet")

        let version = Array(vnPacket[1..<5])
        XCTAssertEqual(version, [0x00, 0x00, 0x00, 0x00], "Version field must be zero")

        // N.B.: the packet dcid/scid are swapped relative to the parameters passed in.
        let packetDcidLength = vnPacket[5]
        XCTAssertEqual(
            packetDcidLength,
            UInt8(sourceConnectionID.length),
            "Packet DCID length should match the provided SCID length"
        )
        let packetDcid = Array(vnPacket[6..<(6 + Int(packetDcidLength))])
        XCTAssertEqual(
            packetDcid,
            sourceConnectionID.connectionID,
            "Packet DCID bytes should match the provided SCID bytes"
        )

        let scidLenOffset = 6 + Int(packetDcidLength)
        let packetScidLength = vnPacket[scidLenOffset]
        XCTAssertEqual(
            packetScidLength,
            UInt8(destinationConnectionID.length),
            "Packet SCID length should match the provided DCID length"
        )
        let scidOffset = scidLenOffset + 1
        let packetScid = Array(vnPacket[scidOffset..<(scidOffset + Int(packetScidLength))])
        XCTAssertEqual(
            packetScid,
            destinationConnectionID.connectionID,
            "Packet SCID bytes should match the provided DCID bytes"
        )

        let versionsOffset = scidOffset + Int(packetScidLength)
        let advertisedVersions = Array(vnPacket[versionsOffset...])
        XCTAssertEqual(
            advertisedVersions,
            [0x00, 0x00, 0x00, 0x01, 0x1a, 0x2a, 0x3a, 0x4a],
            "Should advertise the requested version followed by the negotiation pattern"
        )

        XCTAssertThrowsError(
            try QUICConnectionUtilities.createVersionNegotiationPacket(
                destinationConnectionID: QUICConnectionID([])!,
                sourceConnectionID: QUICConnectionID([])!
            ),
            "Version negotiation packet should fail to build because SCID and DCID are not long enough to form a valid QUIC packet"
        ) { error in
            guard let networkError = error as? NetworkError else {
                XCTFail("Expected a NetworkError, got \(error)")
                return
            }
            XCTAssertEqual(
                networkError.category?.identifier,
                "QUICUtilities",
                "Should fail with the packetFailedToBuild category due to an invalid packet size"
            )
        }
    }

    func testDeserializePacketNumber() throws {
        typealias Vector = (
            description: String,
            bytes: [UInt8],
            pnSize: UInt8,
            expected: PacketNumber
        )
        let testVectors: [Vector] = [
            ("1-byte packet number", [0x7f], 1, 0x7f),
            ("2-byte packet number", [0x7f, 0xff], 2, 0x7fff),
            ("3-byte packet number, low byte only", [0x00, 0x00, 0xff], 3, 0xff),
            ("3-byte packet number, middle byte only", [0x00, 0xff, 0x00], 3, 0xff00),
            ("3-byte packet number, high byte only", [0xff, 0x00, 0x00], 3, 0xff_0000),
            ("3-byte packet number, all bytes", [0x12, 0x34, 0x56], 3, 0x12_3456),
            ("4-byte packet number", [0x7f, 0xff, 0xff, 0xff], 4, 0x7fff_ffff),
        ]

        for vector in testVectors {
            var frame = Frame(copyBuffer: vector.bytes)
            defer {
                frame.finalize(success: true)
            }

            var packetNumber = PacketNumber.none
            let result = Deserializer.deserialize(&frame, claim: true) {
                read throws(DeserializationError) in
                try read.packetNumber(&packetNumber, pnSize: vector.pnSize)
            }
            XCTAssertEqual(
                result,
                .success(parsedBytes: vector.bytes.count, remainingBytes: 0),
                "Failed test: \(vector.description)"
            )
            XCTAssertEqual(packetNumber, vector.expected, "Failed test: \(vector.description)")
        }
    }
}

#endif
