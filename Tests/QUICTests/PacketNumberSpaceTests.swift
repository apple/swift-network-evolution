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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class PacketNumberSpaceTests: XCTestCase {
    func testPacketNumberSpaceFromKeyState() {
        for state in PacketKeyState.allCases {
            switch state {
            case .initial:
                XCTAssertEqual(
                    PacketNumberSpace.fromKeyState(keyState: state),
                    .initial
                )
            case .handshake:
                XCTAssertEqual(
                    PacketNumberSpace.fromKeyState(keyState: state),
                    .handshake
                )
            case .earlyData, .phase0, .phase1:
                XCTAssertEqual(
                    PacketNumberSpace.fromKeyState(keyState: state),
                    .applicationData
                )

            }
        }
    }

    func testPacketNumberSpaceFromRawValue() {
        var space = PacketNumberSpace(rawValue: 0)
        XCTAssertEqual(space, .initial)

        space = PacketNumberSpace(rawValue: 1)
        XCTAssertEqual(space, .handshake)

        space = PacketNumberSpace(rawValue: 2)
        XCTAssertEqual(space, .applicationData)
    }

    func testPacketNumberSpaceToRawValue() {
        XCTAssertEqual(PacketNumberSpace.initial.rawValue, 0)

        XCTAssertEqual(PacketNumberSpace.handshake.rawValue, 1)

        XCTAssertEqual(PacketNumberSpace.applicationData.rawValue, 2)
    }

    func testByteLength() {
        typealias Vector = (index: Int, value: PacketNumber, expected: Int)
        let testVectors: [Vector] = [
            (0, .initial, 1),
            (1, PacketNumber(0x0000_0000_0000_00FF), 1),
            (2, PacketNumber(0x0000_0000_0000_FF00), 2),
            (3, PacketNumber(0x0000_0000_00FF_0000), 3),
            (4, PacketNumber(0x0000_0000_FF00_0000), 4),
            (5, PacketNumber(0x0000_00FF_0000_0000), 5),
            (6, PacketNumber(0x0000_FF00_0000_0000), 6),
            (7, PacketNumber(0x00FF_0000_0000_0000), 7),
            (8, PacketNumber(0x3f00_0000_0000_0000), 8),
        ]

        for vector in testVectors {
            XCTAssertEqual(vector.value.byteLength(), vector.expected, "for vector \(vector)")
        }
    }

    func testEncodePacketNumberThreeByteMask() throws {
        let packetNumber = PacketNumber(0x110_0000 as Int64)
        let lastAcked = PacketNumber(0x100_0000 as Int64)
        let encoded = try packetNumber.encode(lastAcked: lastAcked)
        XCTAssertEqual(encoded.size, .threeBytes)
        XCTAssertEqual(encoded.number, 0x10_0000, "Packet number must fit within 3 bytes")
    }
}

#endif
