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

import XCTest

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkIPTests: NetTestCase {

    // 169.254.156.146
    static let localIPv4Address: [UInt8] = [0xa9, 0xfe, 0x9c, 0x92]

    // 169.254.225.163
    static let remoteIPv4Address: [UInt8] = [0xa9, 0xfe, 0xe1, 0xa3]

    // fe80::1444:4d27:b896:d383
    static let localIPv6Address: [UInt8] = [
        0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44, 0x4d, 0x27, 0xb8, 0x96, 0xd3, 0x83,
    ]

    // fe80::1cd6:90f7:2466:d31b
    static let remoteIPv6Address: [UInt8] = [
        0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6, 0x90, 0xf7, 0x24, 0x66, 0xd3, 0x1b,
    ]

    // 169.254.156.146 -> 169.254.225.163, UDP hello
    static let outputIPv4Packet: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x68, 0x99, 0xa9, 0xfe, 0x9c, 0x92, 0xa9, 0xfe,
        0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    //  169.254.225.163 -> 169.254.156.146, UDP hello
    static let inputIPv4Packet: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x68, 0x99, 0xa9, 0xfe, 0xe1, 0xa3, 0xa9, 0xfe,
        0x9c, 0x92, 0x04, 0xd2, 0xfc, 0xf7, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    // fe80::1444:4d27:b896:d383 -> fe80::1cd6:90f7:2466:d31b, UDP hello
    static let outputIPv6Packet: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44,
        0x4d, 0x27, 0xb8, 0x96, 0xd3, 0x83, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6, 0x90, 0xf7,
        0x24, 0x66, 0xd3, 0x1b, 0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    // fe80::1cd6:90f7:2466:d31b -> fe80::1444:4d27:b896:d383, UDP hello
    static let inputIPv6Packet: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6,
        0x90, 0xf7, 0x24, 0x66, 0xd3, 0x1b, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44, 0x4d, 0x27,
        0xb8, 0x96, 0xd3, 0x83, 0x04, 0xd2, 0xfc, 0xf7, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    //  169.254.225.163 -> 169.254.156.146, UDP hello with DSCP
    static let outputIPv4PacketWithDSCP: [UInt8] = [
        0x45, 0x20, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
        0x40, 0x11, 0x68, 0x79, 0xa9, 0xfe, 0x9c, 0x92,
        0xa9, 0xfe, 0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2,
        0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]
    //  169.254.225.163 -> 169.254.156.146, UDP hello with corrupt checksum
    static let outputIPv4PacketWithCorruptChecksum: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
        0x40, 0x11, 0xef, 0xbe, 0xa9, 0xfe, 0x9c, 0x92,
        0xa9, 0xfe, 0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2,
        0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]
    //  169.254.225.163 -> 169.254.156.146, UDP hello with altered hop limit / checksum
    static let outputIPv4PacketWithAlteredHopLimit: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
        0x20, 0x11, 0x88, 0x99, 0xa9, 0xfe, 0x9c, 0x92,
        0xa9, 0xfe, 0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2,
        0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    static let outputIPv6PacketWithAlteredHopLimit: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x11, 0x20, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44,
        0x4d, 0x27, 0xb8, 0x96, 0xd3, 0x83, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6, 0x90, 0xf7,
        0x24, 0x66, 0xd3, 0x1b, 0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    static let badChecksumInputIPv4Packet: [UInt8] = [
        0x09, 0x29, 0x04, 0xd2, 0x00, 0x0e, 0x9e, 0x00, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]
    static let badPortsInputIPv4Packet: [UInt8] = [
        0x04, 0xd2, 0x09, 0x29, 0x00, 0x0e, 0x9e, 0x69, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]

    static let shortInputIPv4Packet: [UInt8] = [0x01, 0x02]

    static let outputMessage: [UInt8] = [0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f]
    static let inputMessage: [UInt8] = [0x04, 0xd2, 0xfc, 0xf7, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f]

    // 169.254.225.163 -> 169.254.156.146 (for simulation only), fragment 1 of 2: first 8 bytes of inputMessage, MF=1 (More fragments)
    // The first 8 bytes of inputMessage are the UDP header
    // reassemblyID = 0xABCD
    static let twoFragmentInputPacket1: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xAB, 0xCD, 0x20, 0x00, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x04, 0xD2, 0xFC, 0xF7, 0x00, 0x0D, 0xE8, 0x04,
    ]
    // 169.254.225.163 -> 169.254.156.146 (for simulation only), fragment 2 of 2: last 5 bytes of inputMessage, MF=0 (Last fragment)
    // The next 5 bytes of inputMessage are the UDP payload (hello)
    // reassemblyID = 0xABCD
    static let twoFragmentInputPacket2: [UInt8] = [
        0x45, 0x00, 0x00, 0x19, 0xAB, 0xCD, 0x00, 0x01, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x68, 0x65, 0x6C, 0x6C, 0x6F,
    ]

    // 169.254.225.163 -> 169.254.156.146 (for simulation only), fragment 1 of 2: bytes 0–7, MF=1 (More fragments)
    // Fragment 2 uses offset=2 (byte offset 16), skipping offset=1 (byte offset 8).
    // This creates a gap so appendReassembledPackets detects expectedOffset mismatch and drops the sequence.
    // reassemblyID = 0xDEAD
    static let gappedFragmentInputPacket1: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xDE, 0xAD, 0x20, 0x00, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]
    // Fragment at offset=2 (byte offset=16), MF=0 (Last fragment). Skips offset=1 (byte offset=8) entirely.
    // reassemblyID = 0xDEAD
    static let gappedFragmentInputPacket2: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xDE, 0xAD, 0x00, 0x02, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    ]

    // Two fragments, both with MF=1 set (More fragments)
    // reassemblyID = 0xF00D
    static let noTerminalFragmentPacket1: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xF0, 0x0D, 0x20, 0x00, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]
    // Fragment at offset=1 (byte 8), also MF=1 (More fragments)
    // reassemblyID = 0xF00D
    static let noTerminalFragmentPacket2: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xF0, 0x0D, 0x20, 0x01, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ]

    // Two fragments whose combined payload totals 65516 bytes, making rawLength (20 + 65516 = 65536) exceed UInt16.max.
    // reassemblyID = 0xCAFE
    static let overflowFragmentPacket1: [UInt8] = {
        var packet = [UInt8](repeating: 0, count: 32772)
        packet[0] = 0x45
        packet[1] = 0x00
        packet[2] = 0x80
        packet[3] = 0x04
        packet[4] = 0xCA
        packet[5] = 0xFE
        packet[6] = 0x20
        packet[7] = 0x00
        packet[8] = 0x40
        packet[9] = 0x11
        packet[10] = 0x00
        packet[11] = 0x00
        packet[12] = 0xA9
        packet[13] = 0xFE
        packet[14] = 0xE1
        packet[15] = 0xA3
        packet[16] = 0xA9
        packet[17] = 0xFE
        packet[18] = 0x9C
        packet[19] = 0x92
        return packet
    }()

    // reassemblyID = 0xCAFE
    static let overflowFragmentPacket2: [UInt8] = {
        var packet = [UInt8](repeating: 0, count: 32784)
        packet[0] = 0x45
        packet[1] = 0x00
        packet[2] = 0x80
        packet[3] = 0x10
        packet[4] = 0xCA
        packet[5] = 0xFE
        packet[6] = 0x0F
        packet[7] = 0xFE
        packet[8] = 0x40
        packet[9] = 0x11
        packet[10] = 0x00
        packet[11] = 0x00
        packet[12] = 0xA9
        packet[13] = 0xFE
        packet[14] = 0xE1
        packet[15] = 0xA3
        packet[16] = 0xA9
        packet[17] = 0xFE
        packet[18] = 0x9C
        packet[19] = 0x92
        return packet
    }()

    // 169.254.225.163 -> 169.254.156.146 (for simulation only), fragment 1 of 3: bytes 0–7, MF=1, offset=0 (More fragments)
    // reassemblyID = 0xBEEF
    static let threeFragmentInputPacket1: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xBE, 0xEF, 0x20, 0x00, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]
    // fragment 2 of 3: bytes 8–15, MF=1, offset=1 (offsets are in byte increments) (More fragments)
    // reassemblyID = 0xBEEF
    static let threeFragmentInputPacket2: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xBE, 0xEF, 0x20, 0x01, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ]
    // fragment 3 of 3: bytes 16–23, MF=0, offset=2 (offsets are in byte increments) (Last fragment)
    // reassemblyID = 0xBEEF
    static let threeFragmentInputPacket3: [UInt8] = [
        0x45, 0x00, 0x00, 0x1C, 0xBE, 0xEF, 0x00, 0x02, 0x40, 0x11, 0x00, 0x00,
        0xA9, 0xFE, 0xE1, 0xA3, 0xA9, 0xFE, 0x9C, 0x92,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    ]
    // Expected reassembled payload for all of the three fragments above
    // This payload does not represent anything, just that the 3 packets above can be reassembled correctly.
    static let threeFragmentPayload: [UInt8] = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    ]

    // fe80::1cd6:90f7:2466:d31b -> fe80::1444:4d27:b896:d383, fragment 1 of 2: first 8 bytes of inputMessage, MF=1 (More fragments)
    // reassemblyID = 0xABCD1234
    static let twoIPv6FragmentInputPacket1: [UInt8] = [
        // IPv6 base header (40 bytes)
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x01, 0xAB, 0xCD, 0x12, 0x34,
        // Payload: first 8 bytes of inputMessage
        0x04, 0xD2, 0xFC, 0xF7, 0x00, 0x0D, 0xE8, 0x04,
    ]

    // fe80::1cd6:90f7:2466:d31b -> fe80::1444:4d27:b896:d383, fragment 2 of 2: last 5 bytes of inputMessage, MF=0 (Last fragment)
    // reassemblyID = 0xABCD1234
    static let twoIPv6FragmentInputPacket2: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x08, 0xAB, 0xCD, 0x12, 0x34,
        // Payload: last 5 bytes of inputMessage
        0x68, 0x65, 0x6C, 0x6C, 0x6F,
    ]

    // fe80::1cd6:90f7:2466:d31b -> fe80::1444:4d27:b896:d383, fragment 1 of 3: bytes 0-7, MF=1, offset=0 (More fragments)
    // reassemblyID = 0xDEADBEEF
    static let threeIPv6FragmentInputPacket1: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]

    // fragment 2 of 3: bytes 8-15, MF=1, offset=8 (More fragments)
    // reassemblyID = 0xDEADBEEF
    static let threeIPv6FragmentInputPacket2: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x09, 0xDE, 0xAD, 0xBE, 0xEF,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ]

    // fragment 3 of 3: bytes 16-23, MF=0, offset=16 (Last fragment)
    // reassemblyID = 0xDEADBEEF
    static let threeIPv6FragmentInputPacket3: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x10, 0xDE, 0xAD, 0xBE, 0xEF,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    ]

    // Fragment 1 of 2: offset=0, MF=1, 16 payload bytes. Fragment 2 starts at offset=8, overlapping the last 8
    // bytes of fragment 1. RFC 5722 forbids overlapping fragments; the sequence must be rejected.
    // reassemblyID = 0xAABBCCDD
    static let overlappingIPv6FragmentPacket1: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x18, 0x2C, 0x40,  // payloadLength=24 (8 frag hdr + 16 data)
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD,  // offset=0, MF=1
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ]
    // Fragment 2: offset=8 bytes (overlaps last 8 bytes of fragment 1), MF=0.
    // reassemblyID = 0xAABBCCDD
    static let overlappingIPv6FragmentPacket2: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,  // payloadLength=16 (8 frag hdr + 8 data)
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x08, 0xAA, 0xBB, 0xCC, 0xDD,  // offset=8, MF=0 — overlaps fragment 1
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    ]

    // Fragment 1 of 2: offset=0, MF=1, 8 payload bytes.
    // Fragment 2 jumps to offset=16, skipping offset=8. (More fragments)
    // reassemblyID = 0x11223344
    static let gappedIPv6FragmentPacket1: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x01, 0x11, 0x22, 0x33, 0x44,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]
    // Fragment at offset=16 (skips offset=8 entirely), MF=0. (Last fragment)
    // reassemblyID = 0x11223344
    static let gappedIPv6FragmentPacket2: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x10, 0x11, 0x22, 0x33, 0x44,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
    ]

    // Two fragments both with MF=1 (no terminal fragment).
    // reassemblyID = 0x55667788
    static let allMFSetIPv6FragmentPacket1: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x01, 0x55, 0x66, 0x77, 0x88,  // offset=0, MF=1
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]
    // Fragment at offset=8, also MF=1.
    // reassemblyID = 0x55667788
    static let allMFSetIPv6FragmentPacket2: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x10, 0x2C, 0x40,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1C, 0xD6, 0x90, 0xF7, 0x24, 0x66, 0xD3, 0x1B,
        0xFE, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x14, 0x44, 0x4D, 0x27, 0xB8, 0x96, 0xD3, 0x83,
        0x11, 0x00, 0x00, 0x09, 0x55, 0x66, 0x77, 0x88,  // offset=8, MF=1
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ]

    // Two fragments whose combined innerLength totals 65536 bytes, overflowing UInt16.
    // Fragment 1: innerLength=32760, payloadLength=32768 (0x8000)
    // reassemblyID = 0x99AABBCC
    static let overflowIPv6FragmentPacket1: [UInt8] = {
        var packet = [UInt8](repeating: 0, count: 32808)
        packet[0] = 0x60
        packet[4] = 0x80
        packet[5] = 0x00  // payloadLength = 32768
        packet[6] = 0x2C
        packet[7] = 0x40
        packet[8] = 0xFE
        packet[9] = 0x80
        packet[16] = 0x1C
        packet[17] = 0xD6
        packet[18] = 0x90
        packet[19] = 0xF7
        packet[20] = 0x24
        packet[21] = 0x66
        packet[22] = 0xD3
        packet[23] = 0x1B
        packet[24] = 0xFE
        packet[25] = 0x80
        packet[32] = 0x14
        packet[33] = 0x44
        packet[34] = 0x4D
        packet[35] = 0x27
        packet[36] = 0xB8
        packet[37] = 0x96
        packet[38] = 0xD3
        packet[39] = 0x83
        packet[40] = 0x11
        packet[41] = 0x00
        packet[42] = 0x00
        packet[43] = 0x01  // offsetFlags: offset=0, MF=1
        packet[44] = 0x99
        packet[45] = 0xAA
        packet[46] = 0xBB
        packet[47] = 0xCC
        return packet
    }()

    // Fragment 2: offset=32760 (unit=4095, offsetFlags=0x7FF8), MF=0, innerLength=32776.
    // payloadLength = 32784 (0x8010). Combined innerLength: 32760+32776 = 65536 → UInt16 overflow.
    // reassemblyID = 0x99AABBCC
    static let overflowIPv6FragmentPacket2: [UInt8] = {
        var packet = [UInt8](repeating: 0, count: 32824)
        packet[0] = 0x60
        packet[4] = 0x80
        packet[5] = 0x10  // payloadLength = 32784
        packet[6] = 0x2C
        packet[7] = 0x40
        packet[8] = 0xFE
        packet[9] = 0x80
        packet[16] = 0x1C
        packet[17] = 0xD6
        packet[18] = 0x90
        packet[19] = 0xF7
        packet[20] = 0x24
        packet[21] = 0x66
        packet[22] = 0xD3
        packet[23] = 0x1B
        packet[24] = 0xFE
        packet[25] = 0x80
        packet[32] = 0x14
        packet[33] = 0x44
        packet[34] = 0x4D
        packet[35] = 0x27
        packet[36] = 0xB8
        packet[37] = 0x96
        packet[38] = 0xD3
        packet[39] = 0x83
        packet[40] = 0x11
        packet[41] = 0x00
        packet[42] = 0x7F
        packet[43] = 0xF8  // offsetFlags: offset=32760 (4095 units), MF=0
        packet[44] = 0x99
        packet[45] = 0xAA
        packet[46] = 0xBB
        packet[47] = 0xCC
        return packet
    }()

    func internalTestIP(
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        outputPacket: [UInt8],
        inputPacket: [UInt8],
        secondaryInputPacket: [UInt8]? = nil,
        expectFailure: Bool = false,
        dscpValue: UInt8 = 0,
        corrumptChecksum: Bool = false,
        hopLimit: UInt8? = nil
    ) {
        let parameters = Parameters()

        let expectation = XCTestExpectation()
        let context = parameters.context
        context.async {
            defer { expectation.fulfill() }
            let path = PathProperties(parameters: parameters)

            let reference = IPProtocol.instance(context: parameters.context)
            let ipOptions = IPProtocol.options()
            ipOptions.dscpValue = dscpValue
            if corrumptChecksum {
                ipOptions.flags = IPProtocol.IPOptions.Flags(rawValue: 8)
            }
            if let ttl = hopLimit {
                ipOptions.hopLimit = ttl
            }
            ipOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 2)
            ipOptions.setProtocolInstance(reference)
            parameters.defaultStack.internet = .ip(ipOptions)

            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            udpOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            parameters.defaultStack.transport = .udp(udpOptions)

            let ipLinkage = OutboundDatagramLinkage(reference: reference)
            let upperHarness = DatagramUpperHarness(
                identifier: "Client",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                lowerProtocol: ipLinkage
            )
            XCTAssertNotNil(upperHarness, "Failed to attach IP to upper harness")
            guard let upperHarness else {
                return
            }

            let lowerHarness = DatagramLowerHarness(
                identifier: "Client",
                context: parameters.context
            )
            do {
                try reference.attachLowerDatagramProtocol(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach IP to lower harness")
            }

            upperHarness.start { connected in
                XCTAssertTrue(connected, "IP failed to become connected")
            }

            let message = SwiftNetworkIPTests.outputMessage
            let wrote = upperHarness.write(message)
            XCTAssertTrue(wrote, "Failed to write")

            let lastPacketData = lowerHarness.extractLastOutboundPacket()
            XCTAssertNotNil(lastPacketData, "Failed to get IP output packet")
            guard let lastPacketData = lastPacketData else {
                return
            }

            let expectedPacketData = outputPacket.withUnsafeBytes { [UInt8]($0) }

            if case .address(let address) = localEndpoint.type,
                case .v6 = address.type
            {
                // Skip comparing flow label for IPv6
                XCTAssertEqual(lastPacketData[0], expectedPacketData[0], "Failed to generate expected IP output packet")
                var lastPacketDataSuffix = lastPacketData
                lastPacketDataSuffix.removeSubrange(0...3)
                var expectedPacketDataSuffix = expectedPacketData
                expectedPacketDataSuffix.removeSubrange(0...3)
                if expectFailure {
                    // Expected failure path
                } else {
                    // Expected Success path
                    XCTAssertEqual(
                        lastPacketDataSuffix,
                        expectedPacketDataSuffix,
                        "Failed to generate expected IP output packet"
                    )
                }
            } else {
                if expectFailure {
                    // Expected failure path
                    XCTAssertNotEqual(lastPacketData, expectedPacketData)
                } else {
                    // Expected Success path
                    XCTAssertEqual(lastPacketData, expectedPacketData, "Failed to generate expected IP output packet")
                }
            }

            if let secondaryInputPacket {
                lowerHarness.setNextInboundPacket(inputPacket, sendAvailableEvent: false)
                lowerHarness.setNextInboundPacket(secondaryInputPacket)
            } else {
                lowerHarness.setNextInboundPacket(inputPacket)
            }

            let readApplicationBytes = upperHarness.read()
            if expectFailure {
                // Expected failure path
                XCTAssertNil(readApplicationBytes, "Unexpectedly received IP input packet")
            } else {
                // Expected Success path
                XCTAssertNotNil(readApplicationBytes, "Failed to get IP input packet")
                guard let readApplicationBytes = readApplicationBytes else {
                    return
                }

                let expectedInputBytes = SwiftNetworkIPTests.inputMessage

                XCTAssertEqual(expectedInputBytes, readApplicationBytes, "Failed to read expected IP input data")
            }

            upperHarness.stop()
            upperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testIPv4() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet
        )
    }

    func testIPv6() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet
        )
    }

    // These tests should all fail input frame validation
    // sourceAddress does not match remoteAddress
    func testIPAddressMismatchIPv4Local() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            expectFailure: true
        )
    }

    func testIPAddressMismatchIPv6Local() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet,
            expectFailure: true
        )
    }

    func testIPAddressMismatchIPv4Remote() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            expectFailure: true
        )
    }

    func testIPAddressMismatchIPv6Remote() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet,
            expectFailure: true
        )
    }

    func testCorruptChecksum() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4PacketWithCorruptChecksum,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            corrumptChecksum: true
        )
    }

    func testIPReadAfterBadPacket() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.badPortsInputIPv4Packet,
            secondaryInputPacket: SwiftNetworkIPTests.inputIPv4Packet
        )
    }

    func testDSCP() {
        // Test dscp for IPv4
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4PacketWithDSCP,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            dscpValue: 8
        )

    }

    func testHopLimitIPv4() {
        // Test setting ttl / hoplimit for IPv4
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4PacketWithAlteredHopLimit,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            hopLimit: 32
        )
    }

    func testHopLimitIPv6() {
        // Test setting ttl / hoplimit for IPv6
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6PacketWithAlteredHopLimit,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet,
            hopLimit: 32
        )
    }

    func testThreeAIPv4FragmentsToReassemble() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.threeFragmentInputPacket1,
                SwiftNetworkIPTests.threeFragmentInputPacket2,
                SwiftNetworkIPTests.threeFragmentInputPacket3,
            ],
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0)
        )
        XCTAssertNotNil(readBytes, "Failed to receive reassembled IPv4 packet from three fragments")
        if let readBytes {
            XCTAssertEqual(
                readBytes,
                SwiftNetworkIPTests.threeFragmentPayload,
                "Reassembled payload did not match expected"
            )
        }
    }

    func testTwoIPv4FragmentsToReassemble() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.twoFragmentInputPacket1,
                SwiftNetworkIPTests.twoFragmentInputPacket2,
            ],
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0)
        )
        XCTAssertNotNil(readBytes, "Failed to receive reassembled IPv4 packet from two fragments")
        if let readBytes {
            XCTAssertEqual(readBytes, SwiftNetworkIPTests.inputMessage, "Reassembled payload did not match expected")
        }
    }

    // Verifies that appendReassembledPackets discards a fragment when it detects an offset gap.
    // fragment 1 has byte offset 0, fragment 2 jumps to byte offset 16, skipping 8.
    func testGappedIPv4FragmentsProduceNoReassembledFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.gappedFragmentInputPacket1,
                SwiftNetworkIPTests.gappedFragmentInputPacket2,
            ],
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet from a gapped fragment sequence")
    }

    // Verifies that appendReassembledPackets does not create a reassembled fragment without a terminal MF=0 flag.
    func testIPv4AllMFSetFragmentsProduceNoReassembledFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.noTerminalFragmentPacket1,
                SwiftNetworkIPTests.noTerminalFragmentPacket2,
            ],
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet when no terminal fragment was present")
    }

    // Verifies that appendReassembledPackets rejects a complete fragment sequence whose combined
    // payload would cause rawLength (headerLength + totalPayload) exceeds UInt16.max
    func testIPv4ReassembledLengthOverflowProducesNoFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.overflowFragmentPacket1,
                SwiftNetworkIPTests.overflowFragmentPacket2,
            ],
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet when reassembled length overflows UInt16")
    }

    func testTwoIPv6FragmentsToReassemble() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.twoIPv6FragmentInputPacket1,
                SwiftNetworkIPTests.twoIPv6FragmentInputPacket2,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNotNil(readBytes, "Failed to receive reassembled IPv6 packet from two fragments")
        if let readBytes {
            XCTAssertEqual(
                readBytes,
                SwiftNetworkIPTests.inputMessage,
                "Reassembled IPv6 payload did not match expected"
            )
        }
    }

    func testThreeIPv6FragmentsToReassemble() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.threeIPv6FragmentInputPacket1,
                SwiftNetworkIPTests.threeIPv6FragmentInputPacket2,
                SwiftNetworkIPTests.threeIPv6FragmentInputPacket3,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNotNil(readBytes, "Failed to receive reassembled IPv6 packet from three fragments")
        if let readBytes {
            XCTAssertEqual(
                readBytes,
                SwiftNetworkIPTests.threeFragmentPayload,
                "Reassembled IPv6 payload did not match expected"
            )
        }
    }

    // Verifies that a gap between IPv6 fragment offsets prevents reassembly
    // Fragment 1 covers bytes 0–7; fragment 2 starts at byte 16, skipping byte 8–15
    func testGappedIPv6FragmentsProduceNoReassembledFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.gappedIPv6FragmentPacket1,
                SwiftNetworkIPTests.gappedIPv6FragmentPacket2,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet from a gapped IPv6 fragment sequence")
    }

    // Verifies that a sequence with no terminal fragment (all MF=1) is never reassembled
    func testAllMFSetIPv6FragmentsProduceNoReassembledFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.allMFSetIPv6FragmentPacket1,
                SwiftNetworkIPTests.allMFSetIPv6FragmentPacket2,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet when no terminal IPv6 fragment was present")
    }

    // Verifies that a fragment sequence whose combined innerLength overflows UInt16 is rejected
    func testIPv6FragmentOffsetOverflowProducesNoFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.overflowIPv6FragmentPacket1,
                SwiftNetworkIPTests.overflowIPv6FragmentPacket2,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet when IPv6 fragment offset overflows UInt16")
    }

    // Verifies that three fragments arriving out of order (3, 1, 2) are sorted and reassembled correctly
    // Verifies that out-of-order IPv6 fragments (3, 1, 2) are sorted and reassembled correctly
    func testOutOfOrderIPv6FragmentsReassemble() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.threeIPv6FragmentInputPacket3,
                SwiftNetworkIPTests.threeIPv6FragmentInputPacket1,
                SwiftNetworkIPTests.threeIPv6FragmentInputPacket2,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNotNil(readBytes, "Failed to reassemble out-of-order IPv6 fragments")
        if let readBytes {
            XCTAssertEqual(
                readBytes,
                SwiftNetworkIPTests.threeFragmentPayload,
                "Reassembled out-of-order IPv6 payload did not match expected"
            )
        }
    }

    // Verifies that overlapping IPv6 fragments are rejected per RFC 5722
    // Fragment 1 covers bytes 0–15 (MF=1) (More Fragments)
    // Fragment 2 starts at byte 8, overlapping the last 8 bytes of fragment 1
    // The fragmentOffset (8) != expectedOffset (16) check drops the sequence
    func testOverlappingIPv6FragmentsProduceNoReassembledFrame() {
        let readBytes = processIPFragment(
            packets: [
                SwiftNetworkIPTests.overlappingIPv6FragmentPacket1,
                SwiftNetworkIPTests.overlappingIPv6FragmentPacket2,
            ],
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0)
        )
        XCTAssertNil(readBytes, "Unexpectedly received a packet from overlapping IPv6 fragments (RFC 5722 violation)")
    }

    func testIPv4OutboundFragmentation() {
        // Send a 29-byte payload on a path with MTU set to 40 and fragmentation enabled.
        // IPv4 header is 20 bytes, so max payload per fragment = 20 bytes, aligned to 8 = 16 bytes.
        // Expected: 2 fragments — payload[0..<16] with MF=1, payload[16..<29] with MF=0.
        let mtu = 40
        let payload: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x19, 0x1A, 0x1B, 0x1C, 0x1D,
        ]
        let parameters = Parameters()
        let expectation = XCTestExpectation()
        let context = parameters.context
        context.async {
            defer { expectation.fulfill() }
            // Set directInterface so networkIsSatisfied enables mtu
            var path = PathProperties(parameters: parameters)
            path.directInterface = Interface(
                index: 1,
                name: "lo0",
                type: .loopback,
                subtype: .other,
                mtu: mtu
            )
            path.effectiveMTU = UInt32(mtu)

            let reference = IPProtocol.instance(context: parameters.context)
            let ipOptions = IPProtocol.options()
            // Enable fragmentation through IPOptions
            ipOptions.flags = IPProtocol.IPOptions.Flags(rawValue: ipOptions.flags.rawValue)
                .union(.fragmentationEnabledOverridden)
                .union(.fragmentationEnabled)
            ipOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 2)
            ipOptions.setProtocolInstance(reference)
            parameters.defaultStack.internet = .ip(ipOptions)

            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            udpOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            parameters.defaultStack.transport = .udp(udpOptions)

            let localEndpoint = Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0)
            let remoteEndpoint = Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0)
            let ipLinkage = OutboundDatagramLinkage(reference: reference)
            guard
                let upperHarness = DatagramUpperHarness(
                    identifier: "Client",
                    local: localEndpoint,
                    remote: remoteEndpoint,
                    parameters: parameters,
                    path: path,
                    context: parameters.context,
                    lowerProtocol: ipLinkage
                )
            else {
                XCTFail("Failed to attach IP to upper harness")
                return
            }
            let lowerHarness = DatagramLowerHarness(identifier: "Client", context: parameters.context)
            do {
                try reference.attachLowerDatagramProtocol(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach IP to lower harness")
                return
            }
            upperHarness.start { connected in XCTAssertTrue(connected) }
            _ = upperHarness.write(payload)

            var fragments: [[UInt8]] = []
            while lowerHarness.hasOutboundPackets {
                if let packets = lowerHarness.extractLastOutboundPacket() {
                    fragments.append(packets)
                }
            }
            // Expect exactly 2 fragments: 16-byte payload + 13-byte payload
            XCTAssertEqual(fragments.count, 2, "Expected exactly 2 IPv4 fragments")
            guard fragments.count == 2,
                let fragmentOne = fragments.first,
                let fragmentTwo = fragments.last
            else { return }

            // Both must be at least 20 bytes (IPv4 header)
            XCTAssertGreaterThanOrEqual(fragmentOne.count, 20)
            XCTAssertGreaterThanOrEqual(fragmentTwo.count, 20)
            guard fragmentOne.count >= 20, fragmentTwo.count >= 20 else { return }

            // Both fragments must share the same identifier (bytes 4–5 in the header)
            // This is generatated randomly, so make sure both fragments carry the same id
            let id1 = UInt16(fragmentOne[4]) << 8 | UInt16(fragmentOne[5])
            let id2 = UInt16(fragmentTwo[4]) << 8 | UInt16(fragmentTwo[5])
            XCTAssertEqual(id1, id2, "All fragments must share the same IP identifier")

            // Fragment 1: MF=1 (This is the first fragment so MF=1 needs to be set), offset=0
            let flagsOffset1 = UInt16(fragmentOne[6]) << 8 | UInt16(fragmentOne[7])
            XCTAssertNotEqual(flagsOffset1 & 0x2000, 0, "Fragment 1 must have MF=1")
            XCTAssertEqual(flagsOffset1 & 0x1FFF, 0, "Fragment 1 must have offset=0")
            // Fragment 1 payload must be the first 16 bytes (first 16 of the 29 bytes payload)
            XCTAssertEqual(fragmentOne.count, 20 + 16, "Fragment 1 must be header + 16 payload bytes")
            XCTAssertEqual(Array(fragmentOne[20...]), Array(payload[0..<16]))

            // Fragment 2: MF=0 (last fragment), offset=2 (16 bytes / 8 = 2 units)
            let flagsOffset2 = UInt16(fragmentTwo[6]) << 8 | UInt16(fragmentTwo[7])
            XCTAssertEqual(flagsOffset2 & 0x2000, 0, "Fragment 2 must have MF=0")
            XCTAssertEqual(flagsOffset2 & 0x1FFF, 2, "Fragment 2 must have offset=2 (16 bytes)")
            // Fragment 2 payload must be the remaining 13 bytes (last 13 of the 29 bytes payload)
            XCTAssertEqual(fragmentTwo.count, 20 + 13, "Fragment 2 must be header + 13 payload bytes")
            XCTAssertEqual(Array(fragmentTwo[20...]), Array(payload[16...]))

            upperHarness.stop()
            upperHarness.teardown()
        }
        wait(for: [expectation], timeout: 10.0)
    }

    // Sets up a minimal IP harness to test different fragment and reassembly conditions
    private func processIPFragment(
        packets: [[UInt8]],
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        logIDNumber: Int = 2
    ) -> [UInt8]? {
        let parameters = Parameters()
        var result: [UInt8]? = nil
        let expectation = XCTestExpectation()
        let context = parameters.context
        context.async {
            defer { expectation.fulfill() }
            let path = PathProperties(parameters: parameters)
            let ipInstance = IPProtocol.instance(context: parameters.context)
            let ipOptions = IPProtocol.options()
            ipOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: logIDNumber)
            ipOptions.setProtocolInstance(ipInstance)
            parameters.defaultStack.internet = .ip(ipOptions)

            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            udpOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            parameters.defaultStack.transport = .udp(udpOptions)

            let localEndpoint = localEndpoint
            let remoteEndpoint = remoteEndpoint

            let ipLinkage = OutboundDatagramLinkage(reference: ipInstance)
            guard
                let upperHarness = DatagramUpperHarness(
                    identifier: "Client",
                    local: localEndpoint,
                    remote: remoteEndpoint,
                    parameters: parameters,
                    path: path,
                    context: parameters.context,
                    lowerProtocol: ipLinkage
                )
            else {
                XCTFail("Failed to attach IP to upper harness")
                return
            }

            let lowerHarness = DatagramLowerHarness(identifier: "Client", context: parameters.context)
            do {
                try ipInstance.attachLowerDatagramProtocol(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach IP to lower harness")
                return
            }

            upperHarness.start { connected in
                XCTAssertTrue(connected)
            }

            for (index, packet) in packets.enumerated() {
                let isLast = index == packets.count - 1
                lowerHarness.setNextInboundPacket(packet, sendAvailableEvent: isLast)
            }

            result = upperHarness.read()
            upperHarness.stop()
            upperHarness.teardown()
        }
        wait(for: [expectation], timeout: 5.0)
        return result
    }

    func ipEcho(clientEndpoint: Endpoint, serverEndpoint: Endpoint, messages: [[UInt8]]) {
        let clientParameters = Parameters()
        let expectation = XCTestExpectation()
        let context = clientParameters.context
        context.async {
            defer { expectation.fulfill() }
            let clientPath = PathProperties(parameters: clientParameters)
            let clientReference = IPProtocol.instance(context: clientParameters.context)
            let clientOptions = IPProtocol.options()
            clientOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientOptions.setProtocolInstance(clientReference)
            clientParameters.defaultStack.internet = .ip(clientOptions)

            let clientIPLinkage = OutboundDatagramLinkage(reference: clientReference)
            let clientUpperHarness = DatagramUpperHarness(
                identifier: "Client",
                local: clientEndpoint,
                remote: serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: clientParameters.context,
                lowerProtocol: clientIPLinkage
            )
            XCTAssertNotNil(clientUpperHarness, "Failed to attach IP to client input harness")
            guard let clientUpperHarness else {
                return
            }

            let clientLowerHarness = DatagramLowerHarness(identifier: "Client", context: clientParameters.context)
            clientLowerHarness.maximumOutputSize = 9000
            do {
                try clientReference.attachLowerDatagramProtocol(
                    clientLowerHarness.reference,
                    remote: serverEndpoint,
                    local: clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach IP to lower harness")
            }

            let serverParameters = Parameters()
            let serverPath = PathProperties(parameters: serverParameters)
            let serverReference = IPProtocol.instance(context: clientParameters.context)
            let serverOptions = IPProtocol.options()
            serverOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverOptions.setProtocolInstance(serverReference)
            serverParameters.defaultStack.internet = .ip(serverOptions)

            let serverIPLinkage = OutboundDatagramLinkage(reference: serverReference)
            let serverUpperHarness = DatagramUpperHarness(
                identifier: "Server",
                local: serverEndpoint,
                remote: clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: serverParameters.context,
                lowerProtocol: serverIPLinkage
            )
            XCTAssertNotNil(serverUpperHarness, "Failed to attach IP to server input harness")
            guard let serverUpperHarness else {
                return
            }

            let serverLowerHarness = DatagramLowerHarness(identifier: "Server", context: serverParameters.context)
            serverLowerHarness.maximumOutputSize = 9000
            do {
                try serverReference.attachLowerDatagramProtocol(
                    serverLowerHarness.reference,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach IP server to lower harness")
            }

            clientUpperHarness.start { connected in
                XCTAssertTrue(connected, "IP client failed to become connected")
            }

            serverUpperHarness.start { connected in
                XCTAssertTrue(connected, "IP server failed to become connected")
            }

            for message in messages {
                let clientWrote = clientUpperHarness.write(message)
                XCTAssertTrue(clientWrote, "Client failed to write")

                let clientOutboundPacket = clientLowerHarness.extractLastOutboundPacket()
                XCTAssertNotNil(clientOutboundPacket, "Failed to get client IP outbound packet")
                guard let clientOutboundPacket = clientOutboundPacket else {
                    return
                }

                serverLowerHarness.setNextInboundPacket(clientOutboundPacket)

                let serverInboundBytes = serverUpperHarness.read()
                XCTAssertNotNil(serverInboundBytes, "Server failed to get IP inbound packet")
                guard let serverInboundBytes = serverInboundBytes else {
                    return
                }

                XCTAssertEqual(serverInboundBytes, message, "Server inbound packet did not match expected message")

                let serverWrote = serverUpperHarness.write(message)
                XCTAssertTrue(serverWrote, "Server failed to write")

                let serverOutboundPacket = serverLowerHarness.extractLastOutboundPacket()
                XCTAssertNotNil(serverOutboundPacket, "Failed to get server IP outbound packet")
                guard let serverOutboundPacket = serverOutboundPacket else {
                    return
                }

                clientLowerHarness.setNextInboundPacket(serverOutboundPacket)

                let clientInboundBytes = clientUpperHarness.read()
                XCTAssertNotNil(clientInboundBytes, "Client failed to get IP inbound packet")
                guard let clientInboundBytes = clientInboundBytes else {
                    return
                }

                XCTAssertEqual(clientInboundBytes, message, "Client inbound packet did not match expected message")
            }

            clientUpperHarness.stop()
            serverUpperHarness.stop()

            clientUpperHarness.teardown()
            serverUpperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testIPEcho() {
        // This is a somewhat random set of messages, intended to test various lengths types of content
        var messages: [[UInt8]] = [
            [0x01, 0x02, 0x03, 0x4, 0x05, 0x06, 0x07, 0x08],
            [0x00, 0x00],
            [],
            [
                0x25, 0xcc, 0xd1, 0x09, 0x03, 0x31, 0x0c, 0x04, 0xd1, 0x56, 0xb6, 0x80, 0x23, 0x95, 0xa4, 0x09,
                0xc5, 0x12, 0xc7, 0x82, 0x65, 0xfb, 0x2c, 0xa9, 0xff, 0x18, 0xee, 0x7b, 0x78, 0xf3, 0x9d, 0xdb,
                0x1c, 0x5c, 0x51, 0x0e, 0x9d, 0x7d, 0x6e, 0x04, 0x13, 0xe2, 0x96, 0x17, 0xda, 0x1c, 0x61, 0x2d,
                0x2d, 0x6b, 0x43, 0x94, 0x8b, 0xd1, 0x38, 0x6e, 0x58, 0xe7, 0x89, 0x61, 0x7a, 0x00, 0x8c, 0x15,
                0x3e, 0x15, 0x69, 0xbe, 0x0e, 0xe6, 0x68, 0x54, 0x6a, 0x8d, 0x44, 0x25, 0xba, 0xfc, 0xce, 0x1e,
                0x96, 0xef, 0xda, 0xe0, 0x72, 0x0f, 0x81, 0x74, 0x3e, 0x25, 0x9f, 0x3f,
            ],
        ]

        if let lastMessage = messages.last {
            // Make a copy of the last message 50x that is larger, to test a "jumbo" datagram case
            var jumboMessage = [UInt8]()
            for _ in 0..<50 { jumboMessage.append(contentsOf: lastMessage) }
            messages.append(jumboMessage)
        }

        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0)
        ipEcho(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server, messages: messages)

        let ipv6Client = Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0)
        let ipv6Server = Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0)
        ipEcho(clientEndpoint: ipv6Client, serverEndpoint: ipv6Server, messages: messages)
    }
}

#endif
