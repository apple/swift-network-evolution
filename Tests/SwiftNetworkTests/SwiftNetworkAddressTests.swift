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
#if canImport(Android)
import Android
#endif
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

@available(Network 0.1.0, *)
final class SwiftNetworkAddressTests: NetTestCase {

    @discardableResult
    func innerTestIPv4Address(_ bytes: [UInt8], _ description: String) throws -> IPv4Address {
        let v4Addr = IPv4Address(bytes)
        XCTAssertNotNil(v4Addr, "Addresses failed to initialize")

        XCTAssertEqual(v4Addr!.debugDescription, description, "Address description is invalid")

        let secondAddr = IPv4Address(v4Addr!.rawValue)
        XCTAssertEqual(v4Addr, secondAddr, "Addresses should match")
        XCTAssertTrue(v4Addr == secondAddr, "Addresses should compare")
        return v4Addr!
    }

    func testIPv4AddressLocalhost() throws {
        let v4Addr = try innerTestIPv4Address([0x7F, 0x00, 0x00, 0x01], "127.0.0.1")
        XCTAssertTrue(v4Addr.isLoopback, "Address should be loopback")
    }

    func testIPv4AddressMulticast() throws {
        let v4Addr = try innerTestIPv4Address([0xE0, 0x00, 0x00, 0x02], "224.0.0.2")
        XCTAssertTrue(v4Addr.isMulticast, "Address should be multicast")
    }

    func testIPv4Address() throws {
        try innerTestIPv4Address([0x0a, 0x0b, 0x0c, 0x0d], "10.11.12.13")
    }

    @discardableResult
    func innerTestIPv6Address(_ bytes: [UInt8], _ description: String) throws -> IPv6Address {
        let v6Addr = IPv6Address(bytes)
        XCTAssertNotNil(v6Addr, "Addresses failed to initialize")
        XCTAssertEqual(v6Addr!.debugDescription, description, "Address description is invalid")
        return v6Addr!
    }

    func testIPv6Address() throws {
        try innerTestIPv6Address(
            [0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01],
            "2001:db8::1"
        )
    }

    func testIPv6AddressLocalhost() throws {
        let v6Addr = try innerTestIPv6Address(
            [
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01,
            ],
            "::1"
        )
        XCTAssertTrue(v6Addr.isLoopback, "Address should be loopback")
    }

    func testIPv6AddressIPv4Mapped() throws {
        let v6Addr = try innerTestIPv6Address(
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1],
            "::ffff:192.168.1.1"
        )
        XCTAssertTrue(v6Addr.isIPv4Mapped, "Address should be IPv4 mapped")
    }

    func testIPv6AddressNoZeros() throws {
        try innerTestIPv6Address(
            [0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06],
            "2001:db8:1:2:3:4:5:6"
        )
    }

    func testCreateAddrRoundTrip() throws {

        var sinAddr4 = sockaddr_in()
        let _ = "10.0.0.1".withCString { p in
            inet_pton(Int32(AddressFamily.ipv4.rawValue), p, &sinAddr4.sin_addr)
        }

        let v4Address = IPv4Address(sinAddr4.sin_addr.s_addr)
        let _ = try v4Address.withSockAddr { (ptr, size) in
            XCTAssertTrue(ptr.pointee.sa_family == AddressFamily.ipv4.rawValue)
        }

        let v6Address = IPv6Address.loopback
        let _ = try v6Address.withSockAddr { (ptr, size) in
            XCTAssertTrue(ptr.pointee.sa_family == AddressFamily.ipv6.rawValue)
        }
    }

    func testMulticastIPAddress() throws {
        let v4Addr = IPv4Address([0xE0, 0x00, 0x00, 0x01])
        XCTAssertTrue(v4Addr!.isMulticast == true, "Address should be multicast")

        let v6Addr = IPv6Address([
            0xff, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01,
            0xff, 0x34, 0xab, 0xcd,
        ])
        XCTAssertTrue(v6Addr!.isMulticast == true, "Address should be multicast")
    }

    func testEthernetAddress() throws {
        let etherAddr = EthernetAddress([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
        XCTAssertNotNil(etherAddr, "Address failed to initialize")
        guard let etherAddr else { return }

        XCTAssertEqual(etherAddr.debugDescription, "00:1a:2b:3c:4d:5e", "Address description is invalid")

        let broadcastEtherAddr = EthernetAddress([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNotNil(broadcastEtherAddr, "Broadcast address failed to initialize")
        guard let broadcastEtherAddr else { return }
        XCTAssertEqual(broadcastEtherAddr, EthernetAddress.broadcast, "Address not equal")
        XCTAssertEqual(broadcastEtherAddr.debugDescription, "ff:ff:ff:ff:ff:ff", "Address description is invalid")
    }
}
