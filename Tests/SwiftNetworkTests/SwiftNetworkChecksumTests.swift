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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkChecksumTests: NetTestCase {
    func testIPv4PsuedoHeaderChecksum() {
        let expectedValue = UInt16(15870)
        let checksum = Checksum.ipv4PseudoHeader(
            source: IPv4Address.loopback,
            dest: IPv4Address.loopback,
            length: 42,
            ipProtocolNumber: 17
        )
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")

        let checksum2 = Checksum.ipv4PseudoHeader(
            source: IPv4Address([0x7f, 0x00, 0x00, 0x1])!,
            dest: IPv4Address.loopback,
            length: 42,
            ipProtocolNumber: 17
        )
        XCTAssertEqual(checksum2, expectedValue, "Checksum didn't match (\(checksum2) != \(expectedValue))")

        let expectedValue3 = UInt16(52612)
        let checksum3 = Checksum.ipv4PseudoHeader(
            source: IPv4Address([0xc0, 0xa8, 0x01, 0xb9])!,
            dest: IPv4Address([0xc0, 0xa8, 0x01, 0xa5])!,
            length: 13,
            ipProtocolNumber: 17
        )
        XCTAssertEqual(checksum3, expectedValue3, "Checksum didn't match (\(checksum3) != \(expectedValue3))")
    }

    func testIPv6PsuedoHeaderChecksum() {
        let expectedValue = UInt16(15616)
        let checksum = Checksum.ipv6PseudoHeader(
            source: IPv6Address.loopback,
            dest: IPv6Address.loopback,
            length: 42,
            ipProtocolNumber: 17
        )
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")

        let expectedValue2 = UInt16(222)
        let checksum2 = Checksum.ipv6PseudoHeader(
            source: IPv6Address([
                0xfd, 0x5a, 0x3a, 0x11, 0xd8, 0x84, 0x73, 0x40, 0x00, 0x78, 0x60, 0xe4, 0xd8, 0x54, 0x85, 0x95,
            ])!,
            dest: IPv6Address([
                0xfd, 0x5a, 0x3a, 0x11, 0xd8, 0x84, 0x73, 0x40, 0x08, 0xa7, 0x8a, 0xda, 0x1c, 0x36, 0x68, 0x64,
            ])!,
            length: 42,
            ipProtocolNumber: 17
        )
        XCTAssertEqual(checksum2, expectedValue2, "Checksum didn't match (\(checksum2) != \(expectedValue2))")

        // Test scope-embedded addresses
        let expectedValue3 = UInt16(16381)
        let checksum3 = Checksum.ipv6PseudoHeader(
            source: IPv6Address([
                0xfe, 0x80, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            ])!,
            dest: IPv6Address([
                0xfe, 0x80, 0x12, 0x34, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
            ])!,
            length: 42,
            ipProtocolNumber: 17
        )
        XCTAssertEqual(checksum3, expectedValue3, "Checksum didn't match (\(checksum3) != \(expectedValue3))")
    }

    func testSimpleDataChecksum() {
        let buffer: [UInt8] = [
            0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3,
            4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7,
        ]
        let expectedValue = UInt16(32864)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testTextDataChecksum() {
        var string: String =
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Quisque ultrices maximus ipsum, id placerat ante gravida in. Nullam velit orci, imperdiet at magna consequat, faucibus sagittis urna. Sed nibh dui, vulputate at malesuada interdum, dictum a eros. Aliquam erat volutpat. Mauris molestie, est nec varius lobortis, eros ante accumsan elit, sed molestie velit enim sit amet magna. Donec sed ligula lacinia nisi ullamcorper pretium. Mauris tincidunt gravida quam luctus convallis. Integer non ex ac augue blandit pellentesque eget quis neque. Ut ligula velit, interdum a rutrum sit amet, mattis eget odio. Nam rhoncus eros eget lectus hendrerit, vel mollis odio interdum. Quisque eget pretium dolor. Duis volutpat nisl a porttitor commodo. Pellentesque ultricies lorem posuere mauris porttitor auctor. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas. Nunc ipsum nisl, sollicitudin efficitur aliquet vulputate, iaculis nec urna. Vivamus efficitur accumsan fringilla. Quisque venenatis, tellus semper mattis efficitur, libero tellus eleifend sapien, commodo semper urna tortor non nibh."
        let expectedValue = UInt16(22664)
        let checksum = string.withUTF8 { $0.withUnsafeBytes { $0.checksum16() } }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16EmptyBuffer() {
        let buffer: [UInt8] = []
        let expectedValue = UInt16(0)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16SingleByte() {
        let buffer: [UInt8] = [0xAB]
        let expectedValue = UInt16(0x00AB)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16SingleWord() {
        let buffer: [UInt8] = [0x12, 0x34]
        let expectedValue = UInt16(0x3412)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16OddLength() {
        // This makes sure that the remainder calculates
        let buffer: [UInt8] = [0x01, 0x02, 0x03]
        let expectedValue = UInt16(0x0204)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16evenAllOnesFoldsToUInt16Max() {
        let buffer: [UInt8] = Array(repeating: 0xFF, count: 8)
        let expectedValue = UInt16(0xFFFF)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
        XCTAssertEqual(checksum, UInt16.max, "Checksum didn't match (\(checksum) != \(UInt16.max))")
    }

    func testChecksum16OddAllOnesRequiresDoubleFold() {
        // The double fold lands on a 0x00FF
        let buffer: [UInt8] = Array(repeating: 0xFF, count: 9)
        let expectedValue = UInt16(0x00FF)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16AllZeros() {
        let buffer: [UInt8] = Array(repeating: 0x00, count: 16)
        let expectedValue = UInt16(0)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16MixedOddLength() {
        let buffer: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01]
        let expectedValue = UInt16(0x9D9E)
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(checksum, expectedValue, "Checksum didn't match (\(checksum) != \(expectedValue))")
    }

    func testChecksum16OrderIndependent() {
        let buffer: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let reordered: [UInt8] = [0x07, 0x08, 0x03, 0x04, 0x01, 0x02, 0x05, 0x06]
        let checksum = buffer.withUnsafeBytes { $0.checksum16() }
        let reorderedChecksum = reordered.withUnsafeBytes { $0.checksum16() }
        XCTAssertEqual(
            checksum,
            reorderedChecksum,
            "Checksum didn't match (\(checksum) != \(reorderedChecksum))"
        )
    }
}
