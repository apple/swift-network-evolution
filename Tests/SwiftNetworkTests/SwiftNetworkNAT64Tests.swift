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
@_spi(Essentials) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) import Network
#endif

@available(Network 0.1.0, *)
final class NAT64AddressTests: NetTestCase {

    // MARK: - canBeSynthesizedNAT64

    func testCanSynthesize_publicAddresses() {
        XCTAssertTrue(IPv4Address([8, 8, 8, 8])!.canBeSynthesizedNAT64)  // Google DNS
        XCTAssertTrue(IPv4Address([1, 1, 1, 1])!.canBeSynthesizedNAT64)  // Cloudflare DNS
        XCTAssertTrue(IPv4Address([1, 0, 0, 0])!.canBeSynthesizedNAT64)  // just outside zeronet
        XCTAssertTrue(IPv4Address([128, 0, 0, 1])!.canBeSynthesizedNAT64)  // just outside loopback range
        XCTAssertTrue(IPv4Address([169, 253, 255, 255])!.canBeSynthesizedNAT64)  // just below link local
        XCTAssertTrue(IPv4Address([169, 255, 0, 0])!.canBeSynthesizedNAT64)  // just above link local
        XCTAssertTrue(IPv4Address([192, 0, 0, 8])!.canBeSynthesizedNAT64)  // just outside DS-Lite (/29)
        XCTAssertTrue(IPv4Address([192, 88, 100, 0])!.canBeSynthesizedNAT64)  // just outside 6to4 relay anycast
        XCTAssertTrue(IPv4Address([223, 255, 255, 255])!.canBeSynthesizedNAT64)  // just below multicast
        XCTAssertTrue(IPv4Address([240, 0, 0, 1])!.canBeSynthesizedNAT64)  // reserved (240.0.0.0/4)
    }

    // Private and shared-space addresses pass canBeSynthesizedNAT64 — they are only
    // blocked for the well-known prefix via isBlocklistedForWellKnownNAT64Prefix.
    func testCanSynthesize_privateAndSharedAddresses() {
        XCTAssertTrue(IPv4Address([10, 0, 0, 0])!.canBeSynthesizedNAT64)
        XCTAssertTrue(IPv4Address([10, 0, 0, 1])!.canBeSynthesizedNAT64)
        XCTAssertTrue(IPv4Address([172, 16, 0, 1])!.canBeSynthesizedNAT64)
        XCTAssertTrue(IPv4Address([192, 168, 1, 1])!.canBeSynthesizedNAT64)
        XCTAssertTrue(IPv4Address([100, 64, 0, 1])!.canBeSynthesizedNAT64)
    }

    // RFC 6890 documentation and benchmarking ranges are explicitly not blocked.
    func testCanSynthesize_documentationRanges() {
        XCTAssertTrue(IPv4Address([192, 0, 2, 1])!.canBeSynthesizedNAT64)  // TEST-NET-1
        XCTAssertTrue(IPv4Address([198, 18, 0, 1])!.canBeSynthesizedNAT64)  // benchmarking
        XCTAssertTrue(IPv4Address([198, 51, 100, 1])!.canBeSynthesizedNAT64)  // TEST-NET-2
        XCTAssertTrue(IPv4Address([203, 0, 113, 1])!.canBeSynthesizedNAT64)  // TEST-NET-3
    }

    func testCannotSynthesize_zeroNet() {
        XCTAssertFalse(IPv4Address([0, 0, 0, 0])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([0, 255, 255, 255])!.canBeSynthesizedNAT64)
    }

    func testCannotSynthesize_loopback() {
        // Full 127.0.0.0/8 range is blocked, not just 127.0.0.1
        XCTAssertFalse(IPv4Address([127, 0, 0, 1])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([127, 0, 0, 2])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([127, 255, 255, 255])!.canBeSynthesizedNAT64)
    }

    func testCannotSynthesize_linkLocal() {
        XCTAssertFalse(IPv4Address([169, 254, 0, 1])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([169, 254, 255, 255])!.canBeSynthesizedNAT64)
    }

    func testCannotSynthesize_dsLite() {
        // 192.0.0.0/29 — first 8 addresses
        XCTAssertFalse(IPv4Address([192, 0, 0, 0])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([192, 0, 0, 7])!.canBeSynthesizedNAT64)
    }

    func testCannotSynthesize_6to4RelayAnycast() {
        XCTAssertFalse(IPv4Address([192, 88, 99, 0])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([192, 88, 99, 255])!.canBeSynthesizedNAT64)
    }

    func testCannotSynthesize_multicast() {
        XCTAssertFalse(IPv4Address([224, 0, 0, 1])!.canBeSynthesizedNAT64)
        XCTAssertFalse(IPv4Address([239, 255, 255, 255])!.canBeSynthesizedNAT64)
    }

    func testCannotSynthesize_broadcast() {
        XCTAssertFalse(IPv4Address([255, 255, 255, 255])!.canBeSynthesizedNAT64)
    }

    // MARK: - isBlocklistedForWellKnownNAT64Prefix

    func testBlocklisted_privateUse() {
        // 10.0.0.0/8
        XCTAssertTrue(IPv4Address([10, 0, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([10, 0, 0, 1])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([10, 255, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([9, 255, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([11, 0, 0, 1])!.isBlocklistedForWellKnownNAT64Prefix)

        // 172.16.0.0/12
        XCTAssertTrue(IPv4Address([172, 16, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([172, 16, 0, 1])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([172, 31, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([172, 15, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([172, 32, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)

        // 192.168.0.0/16
        XCTAssertTrue(IPv4Address([192, 168, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([192, 168, 1, 1])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([192, 168, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([192, 167, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([192, 169, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
    }

    func testBlocklisted_sharedAddressSpace() {
        // 100.64.0.0/10
        XCTAssertTrue(IPv4Address([100, 64, 0, 1])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertTrue(IPv4Address([100, 127, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([100, 128, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([100, 63, 255, 255])!.isBlocklistedForWellKnownNAT64Prefix)
    }

    func testNotBlocklisted_publicAddresses() {
        XCTAssertFalse(IPv4Address([8, 8, 8, 8])!.isBlocklistedForWellKnownNAT64Prefix)
        XCTAssertFalse(IPv4Address([1, 1, 1, 1])!.isBlocklistedForWellKnownNAT64Prefix)
    }

    func testBlocklisted_sharedAddressSpaceBaseAddress() {
        // Explicit base address of 100.64.0.0/10 — not just .1
        XCTAssertTrue(IPv4Address([100, 64, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
    }

    func testBlocklisted_privateUseBaseAddress() {
        // Explicit base address of 192.168.0.0/16
        XCTAssertTrue(IPv4Address([192, 168, 0, 0])!.isBlocklistedForWellKnownNAT64Prefix)
    }

    // MARK: - canBeSynthesizedNAT64 (additional)

    func testCanSynthesize_lowestMulticast() {
        XCTAssertFalse(IPv4Address([224, 0, 0, 0])!.canBeSynthesizedNAT64)  // lowest multicast address
    }

    func testCanSynthesize_oneBelowBroadcast() {
        // 255.255.255.254 — confirms the broadcast block is == check, not a range
        XCTAssertTrue(IPv4Address([255, 255, 255, 254])!.canBeSynthesizedNAT64)
    }

    func testCanSynthesize_sharedSpaceBase() {
        // 100.64.0.0 passes canBeSynthesizedNAT64 — only blocked for WKP
        XCTAssertTrue(IPv4Address([100, 64, 0, 0])!.canBeSynthesizedNAT64)
    }

    // MARK: - NAT64PrefixLength

    func testPrefixLength_bitLengths() {
        XCTAssertEqual(NAT64PrefixLength.prefixLength32.bitLength, 32)
        XCTAssertEqual(NAT64PrefixLength.prefixLength40.bitLength, 40)
        XCTAssertEqual(NAT64PrefixLength.prefixLength48.bitLength, 48)
        XCTAssertEqual(NAT64PrefixLength.prefixLength56.bitLength, 56)
        XCTAssertEqual(NAT64PrefixLength.prefixLength64.bitLength, 64)
        XCTAssertEqual(NAT64PrefixLength.prefixLength96.bitLength, 96)
    }

    func testPrefixLength_rawValues() {
        XCTAssertEqual(NAT64PrefixLength.prefixLength32.rawValue, 4)
        XCTAssertEqual(NAT64PrefixLength.prefixLength40.rawValue, 5)
        XCTAssertEqual(NAT64PrefixLength.prefixLength48.rawValue, 6)
        XCTAssertEqual(NAT64PrefixLength.prefixLength56.rawValue, 7)
        XCTAssertEqual(NAT64PrefixLength.prefixLength64.rawValue, 8)
        XCTAssertEqual(NAT64PrefixLength.prefixLength96.rawValue, 12)
    }

    func testPrefixLength_invalidRawValues() {
        for v: UInt8 in [0, 1, 2, 3, 9, 10, 11, 13, 16, 32, 96, 255] {
            XCTAssertNil(NAT64PrefixLength(rawValue: v), "expected nil for rawValue \(v)")
        }
    }

    // MARK: - NAT64Prefix wellKnownPrefix

    func testWellKnownPrefix_length() {
        XCTAssertEqual(NAT64Prefix.wellKnownPrefix.length, .prefixLength96)
    }

    func testWellKnownPrefix_addressBytes() {
        XCTAssertEqual(
            withUnsafeBytes(of: NAT64Prefix.wellKnownPrefix.address.address) { Data($0) },
            Data([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        )
    }

    // MARK: - NAT64Prefix Equatable and Hashable

    func testEquatable_sameLeadingBytesDifferentTrailingAreEqual() {
        // Two /32 prefixes with identical first 4 bytes but different trailing bytes must be equal
        let a = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([
                0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC,
            ])!
        )
        let b = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([
                0xAA, 0xBB, 0xCC, 0xDD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            ])!
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testEquatable_differentLengthsNotEqual() {
        let addr = IPv6Address([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        let a = NAT64Prefix(length: .prefixLength32, address: addr)
        let b = NAT64Prefix(length: .prefixLength40, address: addr)
        XCTAssertNotEqual(a, b)
    }

    func testEquatable_differentLeadingBytesNotEqual() {
        let a = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        let b = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([0x11, 0x22, 0x33, 0x45, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        XCTAssertNotEqual(a, b)
    }

    func testHashable_setDeduplication() {
        // Six prefixes (one per length) — insert each twice with different trailing bytes
        let addresses: [(NAT64PrefixLength, [UInt8], [UInt8])] = [
            (
                .prefixLength32, [0xAA, 0xBB, 0xCC, 0xDD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                [0xAA, 0xBB, 0xCC, 0xDD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            ),
            (
                .prefixLength40, [0x11, 0x22, 0x33, 0x44, 0x55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                [0x11, 0x22, 0x33, 0x44, 0x55, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            ),
            (
                .prefixLength48, [0x20, 0x01, 0x0D, 0xB8, 0xAB, 0xCD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                [0x20, 0x01, 0x0D, 0xB8, 0xAB, 0xCD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            ),
            (
                .prefixLength56, [0xFE, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                [0xFE, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            ),
            (
                .prefixLength64, [0xFC, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0],
                [0xFC, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            ),
            (
                .prefixLength96, [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0, 0, 0, 0],
                [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]
            ),
        ]
        var set = Set<NAT64Prefix>()
        for (length, b1, b2) in addresses {
            set.insert(NAT64Prefix(length: length, address: IPv6Address(b1)!))
            set.insert(NAT64Prefix(length: length, address: IPv6Address(b2)!))
        }
        XCTAssertEqual(set.count, 6)
    }

    // MARK: - NAT64Prefix description

    func testDescription_suffixMatchesLength() {
        let cases: [(NAT64PrefixLength, [UInt8], String)] = [
            (.prefixLength32, [0xAA, 0xBB, 0xCC, 0xDD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "/32"),
            (.prefixLength40, [0x11, 0x22, 0x33, 0x44, 0x55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "/40"),
            (.prefixLength48, [0x20, 0x01, 0x0D, 0xB8, 0xAB, 0xCD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "/48"),
            (.prefixLength56, [0xFE, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0], "/56"),
            (.prefixLength64, [0xFC, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0], "/64"),
            (.prefixLength96, [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "/96"),
        ]
        for (length, bytes, suffix) in cases {
            let prefix = NAT64Prefix(length: length, address: IPv6Address(bytes)!)
            XCTAssertTrue(
                prefix.debugDescription.hasSuffix(suffix),
                "\(length) description should end with \(suffix), got \(prefix.debugDescription)"
            )
        }
    }

    func testDescription_allZeroPrefixLength96() {
        let zeroAddr = IPv6Address([UInt8](repeating: 0, count: 16))!
        let prefix = NAT64Prefix(length: .prefixLength96, address: zeroAddr)
        XCTAssertEqual(prefix.debugDescription, "::/96")
    }

    // MARK: - synthesized(from:prefix:) helpers

    private var prefix32: NAT64Prefix {
        NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
    }
    private var prefix40: NAT64Prefix {
        NAT64Prefix(
            length: .prefixLength40,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
    }
    private var prefix48: NAT64Prefix {
        NAT64Prefix(
            length: .prefixLength48,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
    }
    private var prefix56: NAT64Prefix {
        NAT64Prefix(
            length: .prefixLength56,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
    }
    private var prefix64: NAT64Prefix {
        NAT64Prefix(
            length: .prefixLength64,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
    }
    private var prefix96: NAT64Prefix {
        NAT64Prefix(
            length: .prefixLength96,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0, 0, 0, 0])!
        )
    }

    // 17.34.51.68 — all four bytes distinct and non-zero
    private var ipv4Ref: IPv4Address { IPv4Address([0x11, 0x22, 0x33, 0x44])! }

    // 192.0.2.33 — TEST-NET-1, passes canBeSynthesizedNAT64
    private var ipv4Public: IPv4Address { IPv4Address([192, 0, 2, 33])! }

    // MARK: - synthesized(from:prefix:) — per-length byte correctness

    func testSynthesized_allPrefixLengths() {
        // ipv4Ref = 17.34.51.68 = [0x11, 0x22, 0x33, 0x44]
        let cases: [(NAT64Prefix, Data)] = [
            (
                prefix32,
                Data([0x20, 0x01, 0x0d, 0xb8, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            ),
            (
                prefix40,
                Data([0x20, 0x01, 0x0d, 0xb8, 0x01, 0x11, 0x22, 0x33, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            ),
            (
                prefix48,
                Data([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x11, 0x22, 0x00, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00])
            ),
            (
                prefix56,
                Data([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x11, 0x00, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00])
            ),
            (
                prefix64,
                Data([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x00, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00])
            ),
            (
                prefix96,
                Data([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44])
            ),
        ]
        for (prefix, expected) in cases {
            let result = IPv6Address.synthesized(from: ipv4Ref, prefix: prefix)
            XCTAssertEqual(
                result.map { withUnsafeBytes(of: $0.address) { Data($0) } },
                expected,
                "synthesis mismatch for \(prefix.length)"
            )
            if prefix.length != .prefixLength96 {
                XCTAssertEqual(
                    result.map { withUnsafeBytes(of: $0.address) { Data($0)[8] } },
                    0,
                    "byte 8 must be zero for \(prefix.length)"
                )
            }
        }
    }

    // MARK: - synthesized(from:prefix:) — byte 8 invariant

    func testSynthesized_byte8AlwaysZero() {
        // 192.51.100.5 — second byte 0x33 is non-zero, confirming byte 8 is always cleared
        let ipv4 = IPv4Address([192, 51, 100, 5])!
        for prefix in [prefix40, prefix48, prefix56, prefix64] {
            let result = IPv6Address.synthesized(from: ipv4, prefix: prefix)
            XCTAssertNotNil(result)
            XCTAssertEqual(
                withUnsafeBytes(of: result!.address) { $0[8] },
                0,
                "byte 8 must be zero for prefix \(prefix.length)"
            )
        }
    }

    // MARK: - synthesized(from:prefix:) — prefix bytes in output

    func testSynthesized_prefixBytesWrittenCorrectly() {
        let result = IPv6Address.synthesized(from: ipv4Ref, prefix: prefix48)
        XCTAssertNotNil(result)
        let bytes: [UInt8] = withUnsafeBytes(of: result!.address) { Array($0) }
        XCTAssertEqual(bytes[0], 0x20)
        XCTAssertEqual(bytes[1], 0x01)
        XCTAssertEqual(bytes[2], 0x0d)
        XCTAssertEqual(bytes[3], 0xb8)
        XCTAssertEqual(bytes[4], 0x12)
        XCTAssertEqual(bytes[5], 0x34)
    }

    // MARK: - synthesized(from:prefix:) — WKP blocklist

    func testSynthesized_wkpBlocklisted() {
        let wkp = NAT64Prefix.wellKnownPrefix
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([10, 0, 0, 1])!, prefix: wkp))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([172, 16, 0, 1])!, prefix: wkp))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([172, 31, 255, 255])!, prefix: wkp))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([192, 168, 1, 1])!, prefix: wkp))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([100, 64, 0, 0])!, prefix: wkp))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([100, 127, 255, 255])!, prefix: wkp))
    }

    func testSynthesized_wkpNotBlocklisted() {
        let wkp = NAT64Prefix.wellKnownPrefix
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([8, 8, 8, 8])!, prefix: wkp))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([172, 15, 255, 255])!, prefix: wkp))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([172, 32, 0, 0])!, prefix: wkp))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([192, 167, 255, 255])!, prefix: wkp))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([192, 169, 0, 0])!, prefix: wkp))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([100, 63, 255, 255])!, prefix: wkp))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([100, 128, 0, 0])!, prefix: wkp))
    }

    // MARK: - synthesized(from:prefix:) — non-WKP accepts private IPs

    func testSynthesized_nonWKPAcceptsPrivateIPs() {
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([10, 1, 2, 3])!, prefix: prefix96))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([192, 168, 1, 1])!, prefix: prefix96))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([100, 64, 1, 1])!, prefix: prefix96))
    }

    // MARK: - synthesized(from:prefix:) — canBeSynthesizedNAT64 propagates

    func testSynthesized_unsynthesizableAddressesReturnNil() {
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([127, 0, 0, 1])!, prefix: prefix96))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([169, 254, 0, 1])!, prefix: prefix96))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([224, 0, 0, 1])!, prefix: prefix96))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([255, 255, 255, 255])!, prefix: prefix96))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([0, 0, 0, 0])!, prefix: prefix96))
    }

    // MARK: - RFC 7050 well-known addresses

    // 192.0.0.170 and 192.0.0.171 are the IPv4 addresses mDNSResponder synthesizes with the
    // well-known prefix (64:ff9b::/96) to discover NAT64 prefix configuration. They must be
    // outside DS-Lite (192.0.0.0/29 covers only .0-.7) so they pass canBeSynthesizedNAT64.
    func testRFC7050_192_0_0_170_notDSLite() {
        XCTAssertTrue(IPv4Address([192, 0, 0, 170])!.canBeSynthesizedNAT64)
        XCTAssertTrue(IPv4Address([192, 0, 0, 171])!.canBeSynthesizedNAT64)
    }

    func testRFC7050_synthesizeWKA1() {
        let result = IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 170])!, prefix: .wellKnownPrefix)
        XCTAssertNotNil(result)
        // 64:ff9b::c000:00aa
        XCTAssertEqual(
            withUnsafeBytes(of: result!.address) { Data($0) },
            Data([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0x00, 0x00, 0xAA])
        )
    }

    func testRFC7050_synthesizeWKA2() {
        let result = IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 171])!, prefix: .wellKnownPrefix)
        XCTAssertNotNil(result)
        // 64:ff9b::c000:00ab
        XCTAssertEqual(
            withUnsafeBytes(of: result!.address) { Data($0) },
            Data([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0x00, 0x00, 0xAB])
        )
    }

    func testRFC7050_extractWKA1() {
        let ipv6 = IPv6Address([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0x00, 0x00, 0xAA])!
        XCTAssertEqual(ipv6.extractedIPv4(using: .wellKnownPrefix), IPv4Address([192, 0, 0, 170])!)
    }

    func testRFC7050_extractWKA2() {
        let ipv6 = IPv6Address([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0x00, 0x00, 0xAB])!
        XCTAssertEqual(ipv6.extractedIPv4(using: .wellKnownPrefix), IPv4Address([192, 0, 0, 171])!)
    }

    // MARK: - extractedIPv4(using:) — per-length byte correctness

    func testExtract_allPrefixLengths() {
        // Same byte layout as testSynthesized_allPrefixLengths — these tables are inverses
        let cases: [(IPv6Address, NAT64Prefix)] = [
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix32
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x01, 0x11, 0x22, 0x33, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix40
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x11, 0x22, 0x00, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix48
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x11, 0x00, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix56
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x00, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00,
                ])!, prefix64
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44,
                ])!, prefix96
            ),
        ]
        for (ipv6, prefix) in cases {
            XCTAssertEqual(
                ipv6.extractedIPv4(using: prefix),
                IPv4Address([0x11, 0x22, 0x33, 0x44])!,
                "extraction mismatch for \(prefix.length)"
            )
        }
    }

    // MARK: - extractedIPv4(using:) — prefix mismatch

    func testExtract_prefixMismatch_wrongBytes() {
        // Byte 0 changed from prefix — prefix check must reject it
        let ipv6 = IPv6Address([
            0xFF, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x00, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00,
        ])!
        XCTAssertNil(ipv6.extractedIPv4(using: prefix64))
    }

    func testExtract_prefixMismatch_wrongLength() {
        // Synthesized with /32, extracted with /40 — byte 4 differs between the two prefixes
        let result = IPv6Address.synthesized(from: ipv4Ref, prefix: prefix32)
        XCTAssertNotNil(result)
        XCTAssertNil(result!.extractedIPv4(using: prefix40))
    }

    // MARK: - extractedIPv4(using:) — byte 8 ignored

    func testExtract_byte8Ignored() {
        // Corrupt byte 8 to 0xFF — extraction must still recover the original IPv4
        let bases: [(IPv6Address, NAT64Prefix)] = [
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x01, 0x11, 0x22, 0x33, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix40
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x11, 0x22, 0x00, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix48
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x11, 0x00, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix56
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x00, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00,
                ])!, prefix64
            ),
        ]
        for (ipv6, prefix) in bases {
            var corrupted: [UInt8] = withUnsafeBytes(of: ipv6.address) { Array($0) }
            corrupted[8] = 0xFF
            let corruptedIPv6 = IPv6Address(corrupted)!
            XCTAssertEqual(
                corruptedIPv6.extractedIPv4(using: prefix),
                IPv4Address([0x11, 0x22, 0x33, 0x44])!,
                "byte 8 corruption should not affect extraction for prefix \(prefix.length)"
            )
        }
    }

    // MARK: - extractedIPv4(using:) — no validation of result

    func testExtract_noValidation_returnsPrivateIPv4() {
        // Extraction reverses the byte table without validating the result — private IPs come back as-is
        let ipv6 = IPv6Address([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1])!
        XCTAssertEqual(ipv6.extractedIPv4(using: .wellKnownPrefix), IPv4Address([192, 168, 1, 1])!)
    }

    // MARK: - Round-trip synthesize → extract

    func testRoundTrip_synthesizeExtract_allLengths() {
        for prefix in [prefix32, prefix40, prefix48, prefix56, prefix64, prefix96] {
            let extracted = IPv6Address.synthesized(from: ipv4Ref, prefix: prefix).flatMap {
                $0.extractedIPv4(using: prefix)
            }
            XCTAssertEqual(extracted, ipv4Ref, "round-trip failed for prefix \(prefix.length)")
        }
    }

    // MARK: - Round-trip extract → synthesize

    func testRoundTrip_extractSynthesize_allLengths() {
        let cases: [(IPv6Address, NAT64Prefix)] = [
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix32
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x01, 0x11, 0x22, 0x33, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix40
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x11, 0x22, 0x00, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix48
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x11, 0x00, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00, 0x00,
                ])!, prefix56
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x00, 0x11, 0x22, 0x33, 0x44, 0x00, 0x00, 0x00,
                ])!, prefix64
            ),
            (
                IPv6Address([
                    0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44,
                ])!, prefix96
            ),
        ]
        for (originalIPv6, prefix) in cases {
            let reSynthesized = originalIPv6.extractedIPv4(using: prefix).flatMap {
                IPv6Address.synthesized(from: $0, prefix: prefix)
            }
            XCTAssertEqual(
                reSynthesized,
                originalIPv6,
                "extract→synthesize round-trip failed for prefix \(prefix.length)"
            )
        }
    }

    // MARK: - extractedIPv4 additional edge cases

    func testExtract_allZerosIPv4Region() {
        // Prefix matches but IPv4 region is all zeros — returns 0.0.0.0, not nil (no validation)
        let ipv6 = IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        XCTAssertEqual(ipv6.extractedIPv4(using: prefix32), IPv4Address([0, 0, 0, 0])!)
    }

    func testExtract_allFFsIPv4Region() {
        // IPv4 region all 0xFF — extraction is mechanical, no validation
        let ipv6 = IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0])!
        XCTAssertEqual(ipv6.extractedIPv4(using: prefix32), IPv4Address([255, 255, 255, 255])!)
    }

    func testExtract_broadcastFromIPv4Region() {
        // 255.255.255.254 embedded via /96 — returned as-is
        let ipv6 = IPv6Address([0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 254])!
        XCTAssertEqual(ipv6.extractedIPv4(using: .wellKnownPrefix), IPv4Address([255, 255, 255, 254])!)
    }

    func testExtract_privateAddressReturnedWithoutValidation() {
        // 192.168.1.1 embedded in WKP — extraction returns it even though synthesis would reject it
        let ipv6 = IPv6Address([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1])!
        XCTAssertEqual(ipv6.extractedIPv4(using: .wellKnownPrefix), IPv4Address([192, 168, 1, 1])!)
    }

    func testExtract_allZeroIPv6_allZeroPrefix() {
        // All-zero IPv6 with all-zero /96 prefix — prefix matches, extracts 0.0.0.0
        let zeroPrefix = NAT64Prefix(length: .prefixLength96, address: IPv6Address([UInt8](repeating: 0, count: 16))!)
        let ipv6 = IPv6Address([UInt8](repeating: 0, count: 16))!
        XCTAssertEqual(ipv6.extractedIPv4(using: zeroPrefix), IPv4Address([0, 0, 0, 0])!)
    }

    // MARK: - synthesized additional boundary addresses

    func testSynthesized_dsLiteBoundary_192_0_0_0() {
        // 192.0.0.0 is first address of DS-Lite /29 — must be blocked
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 0])!, prefix: prefix96))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 0])!, prefix: .wellKnownPrefix))
    }

    func testSynthesized_dsLiteBoundary_192_0_0_7() {
        // 192.0.0.7 is last address of DS-Lite /29 — must be blocked
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 7])!, prefix: prefix96))
    }

    func testSynthesized_dsLiteBoundary_192_0_0_8() {
        // 192.0.0.8 is just outside DS-Lite, not in WKP blocklist — must succeed
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 8])!, prefix: .wellKnownPrefix))
    }

    func testSynthesized_rfc7050_withNonWKPPrefix() {
        // 192.0.0.170 works with any prefix, not just WKP
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 170])!, prefix: prefix96))
        XCTAssertNotNil(IPv6Address.synthesized(from: IPv4Address([192, 0, 0, 171])!, prefix: prefix32))
    }

    func testSynthesized_loopbackRange_127_0_0_0() {
        // 127.0.0.0 is the base of the loopback range — blocked
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([127, 0, 0, 0])!, prefix: prefix96))
    }

    func testSynthesized_zeroAddress() {
        // 0.0.0.0 is always blocked
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([0, 0, 0, 0])!, prefix: prefix96))
        XCTAssertNil(IPv6Address.synthesized(from: IPv4Address([0, 0, 0, 0])!, prefix: .wellKnownPrefix))
    }

    // MARK: - debugDescription edge cases

    func testDebugDescription_2001db8Prefix() {
        let prefix = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        XCTAssertTrue(prefix.debugDescription.hasPrefix("2001:db8"), "got: \(prefix.debugDescription)")
        XCTAssertTrue(prefix.debugDescription.hasSuffix("/32"))
    }

    func testDebugDescription_allZeroAllLengths() {
        let zeroAddr = IPv6Address([UInt8](repeating: 0, count: 16))!
        let expected = [
            (NAT64PrefixLength.prefixLength32, "::/32"),
            (.prefixLength40, "::/40"),
            (.prefixLength48, "::/48"),
            (.prefixLength56, "::/56"),
            (.prefixLength64, "::/64"),
            (.prefixLength96, "::/96"),
        ]
        for (length, desc) in expected {
            XCTAssertEqual(NAT64Prefix(length: length, address: zeroAddr).debugDescription, desc)
        }
    }

    func testDebugDescription_noSuffixOverlap() {
        // Suffix is exactly "/N" — no double slash or malformed output
        for length in [
            NAT64PrefixLength.prefixLength32, .prefixLength40, .prefixLength48,
            .prefixLength56, .prefixLength64, .prefixLength96,
        ] {
            let desc = NAT64Prefix(length: length, address: IPv6Address([UInt8](repeating: 0, count: 16))!)
                .debugDescription
            let parts = desc.split(separator: "/")
            XCTAssertEqual(parts.count, 2, "expected exactly one '/' in \(desc)")
            XCTAssertEqual(parts.last, Substring("\(length.bitLength)"))
        }
    }

    // MARK: - NAT64PrefixLength valid raw values

    func testPrefixLength_allValidRawValuesInitialize() {
        // Complement to testPrefixLength_invalidRawValues — confirm all 6 valid values work
        for v: UInt8 in [4, 5, 6, 7, 8, 12] {
            XCTAssertNotNil(NAT64PrefixLength(rawValue: v), "expected non-nil for rawValue \(v)")
        }
    }

    func testPrefixLength_invalidBoundaryValues() {
        // Values adjacent to valid cases
        XCTAssertNil(NAT64PrefixLength(rawValue: 3))  // below prefixLength32
        XCTAssertNil(NAT64PrefixLength(rawValue: 9))  // gap between prefixLength64 and prefixLength96
        XCTAssertNil(NAT64PrefixLength(rawValue: 10))
        XCTAssertNil(NAT64PrefixLength(rawValue: 11))
        XCTAssertNil(NAT64PrefixLength(rawValue: 13))  // above prefixLength96
        XCTAssertNil(NAT64PrefixLength(rawValue: 255))  // max UInt8
    }

    // MARK: - NAT64Prefix trailing byte zeroing stress

    func testInit_trailingBytesZeroed_prefixLength32() {
        let dirty = IPv6Address([
            0xAA, 0xBB, 0xCC, 0xDD,
            0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
            0xAB, 0xAB, 0xAB, 0xAB,
        ])!
        let prefix = NAT64Prefix(length: .prefixLength32, address: dirty)
        let bytes: [UInt8] = withUnsafeBytes(of: prefix.address.address) { Array($0) }
        // First 4 bytes preserved
        XCTAssertEqual(bytes[0], 0xAA)
        XCTAssertEqual(bytes[1], 0xBB)
        XCTAssertEqual(bytes[2], 0xCC)
        XCTAssertEqual(bytes[3], 0xDD)
        // Bytes 4-15 zeroed
        for i in 4..<16 { XCTAssertEqual(bytes[i], 0, "byte \(i) should be zero") }
    }

    func testInit_trailingBytesZeroed_prefixLength40() {
        let dirty = IPv6Address([
            0x11, 0x22, 0x33, 0x44, 0x55,
            0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
            0xAB, 0xAB, 0xAB,
        ])!
        let prefix = NAT64Prefix(length: .prefixLength40, address: dirty)
        let bytes: [UInt8] = withUnsafeBytes(of: prefix.address.address) { Array($0) }
        XCTAssertEqual(bytes[4], 0x55)
        for i in 5..<16 { XCTAssertEqual(bytes[i], 0, "byte \(i) should be zero") }
    }

    func testInit_trailingBytesZeroed_prefixLength96() {
        // Maximum length — all 12 bytes preserved, last 4 zeroed
        let dirty = IPv6Address([
            0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78,
            0x9a, 0xbc, 0xde, 0xf0,
            0xAB, 0xAB, 0xAB, 0xAB,
        ])!
        let prefix = NAT64Prefix(length: .prefixLength96, address: dirty)
        let bytes: [UInt8] = withUnsafeBytes(of: prefix.address.address) { Array($0) }
        for i in 0..<12 { XCTAssertNotEqual(bytes[i], 0, "byte \(i) unexpectedly zero") }
        for i in 12..<16 { XCTAssertEqual(bytes[i], 0, "byte \(i) should be zero") }
    }

    // MARK: - nat64Prefixes

    private func makePathProperties(prefixes: [NAT64Prefix]?) -> PathProperties {
        var path = PathProperties(parameters: Parameters())
        path.nat64Prefixes = prefixes
        return path
    }

    func testnat64Prefixes_nilInput() {
        XCTAssertNil(makePathProperties(prefixes: nil).nat64Prefixes)
    }

    func testnat64Prefixes_emptyArray() {
        XCTAssertEqual(makePathProperties(prefixes: []).nat64Prefixes, [])
    }

    func testnat64Prefixes_singleEntry() {
        let result = makePathProperties(prefixes: [.wellKnownPrefix]).nat64Prefixes
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first, .wellKnownPrefix)
    }

    func testnat64Prefixes_multipleEntries() {
        let prefix32 = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        let result = makePathProperties(prefixes: [.wellKnownPrefix, prefix32]).nat64Prefixes
        XCTAssertEqual(result?.count, 2)
        XCTAssertEqual(result?[0], .wellKnownPrefix)
        XCTAssertEqual(result?[1], prefix32)
    }

    func testnat64Prefixes_roundTrip_allLengths() {
        let cases: [([UInt8], NAT64PrefixLength)] = [
            ([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], .prefixLength32),
            ([0x20, 0x01, 0x0d, 0xb8, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], .prefixLength40),
            ([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], .prefixLength48),
            ([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0, 0, 0, 0, 0, 0, 0, 0, 0], .prefixLength56),
            ([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0], .prefixLength64),
            ([0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0, 0, 0, 0], .prefixLength96),
        ]
        for (addrBytes, length) in cases {
            let prefix = NAT64Prefix(length: length, address: IPv6Address(addrBytes)!)
            let result = makePathProperties(prefixes: [prefix]).nat64Prefixes
            XCTAssertEqual(result?.count, 1, "expected 1 prefix for length \(length)")
            XCTAssertEqual(result?.first, prefix)
        }
    }
}
