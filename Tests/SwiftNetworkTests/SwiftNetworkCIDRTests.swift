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
final class SwiftNetworkCIDRTests: NetTestCase {

    // MARK: - matchesDomainPattern

    func testDomainPattern_exactMatch() {
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "example.com"))
    }

    func testDomainPattern_exactMatchCaseInsensitive() {
        XCTAssertTrue(matchesDomainPattern("Example.COM", pattern: "example.com"))
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "EXAMPLE.COM"))
    }

    func testDomainPattern_trailingDotStripped() {
        XCTAssertTrue(matchesDomainPattern("example.com.", pattern: "example.com"))
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "example.com."))
    }

    func testDomainPattern_suffixMatch() {
        // "example.com" as pattern matches subdomain "www.example.com"
        XCTAssertTrue(matchesDomainPattern("www.example.com", pattern: "example.com"))
        XCTAssertTrue(matchesDomainPattern("bar.foo.example.com", pattern: "example.com"))
        XCTAssertTrue(matchesDomainPattern("foo.example.com", pattern: "example.com"))
    }

    func testDomainPattern_hostShorterThanPatternStillMatchesOnSuffix() {
        // Once the host is fully consumed against the pattern's rightmost segments it is a
        // match, even if the pattern has extra segments to the left. So a host shorter than
        // the pattern can still match on its suffix.
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "www.example.com"))
        XCTAssertTrue(matchesDomainPattern("com", pattern: "example.com"))
    }

    func testDomainPattern_wildcardOneSegment() {
        XCTAssertTrue(matchesDomainPattern("foo.example.com", pattern: "*.example.com"))
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "*.com."))
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "*.com"))
        XCTAssertTrue(matchesDomainPattern("foo.example.com", pattern: "*.example.*"))
        XCTAssertTrue(matchesDomainPattern("foo.example.com", pattern: "foo.*.com"))
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "example.*"))
    }

    func testDomainPattern_wildcardMatchesDomainItself() {
        // A leading wildcard can match zero segments, so "*.example.com" also matches
        // "example.com" itself (not just its subdomains).
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "*.example.com"))
        // "foo.bar.example.com" has two labels beyond what "example.com" requires, so the
        // algorithm truly reaches the pattern's leading "*" node and returns after,
        // regardless of how many host segments remain to its left ("foo" is never inspected).
        XCTAssertTrue(matchesDomainPattern("foo.bar.example.com", pattern: "*.example.com"))
    }

    func testDomainPattern_wildcardMatchesAnything() {
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "*"))
        XCTAssertTrue(matchesDomainPattern("foo.bar.baz", pattern: "*"))
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "."))
    }

    func testDomainPattern_tldOnlyPattern() {
        // "com" as pattern matches any .com hostname (suffix match)
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: "com"))
        XCTAssertTrue(matchesDomainPattern("www.example.com", pattern: "com"))
    }

    func testDomainPattern_noMatch() {
        XCTAssertFalse(matchesDomainPattern("test.com", pattern: "example.com"))
        XCTAssertFalse(matchesDomainPattern("notexample.com", pattern: "example.com"))
        XCTAssertFalse(matchesDomainPattern("example.com", pattern: "example"))
        XCTAssertFalse(matchesDomainPattern("foo.example.com", pattern: "out.example.*"))
    }

    func testDomainPattern_leadingDotTreatedAsWildcard() {
        // ".example.com" behaves like "*.example.com"
        XCTAssertTrue(matchesDomainPattern("www.example.com", pattern: ".example.com"))
        XCTAssertTrue(matchesDomainPattern("foo.example.com", pattern: ".example.com"))
        // The wildcard can match zero segments, so "example.com" itself matches too.
        XCTAssertTrue(matchesDomainPattern("example.com", pattern: ".example.com"))
    }

    // MARK: - IPv4Address.matches — CIDR

    func testIPv4Matches_cidrHit() {
        let addr = IPv4Address([192, 168, 1, 5])!
        XCTAssertTrue(addr.matches(pattern: "192.168.1.0/24"))
    }

    func testIPv4Matches_cidrBoundaryHigh() {
        let addr = IPv4Address([192, 168, 1, 255])!
        XCTAssertTrue(addr.matches(pattern: "192.168.1.0/24"))
    }

    func testIPv4Matches_cidrBoundaryLow() {
        let addr = IPv4Address([192, 168, 1, 0])!
        XCTAssertTrue(addr.matches(pattern: "192.168.1.0/24"))
    }

    func testIPv4Matches_cidrMiss() {
        let addr = IPv4Address([192, 168, 2, 5])!
        XCTAssertFalse(addr.matches(pattern: "192.168.1.0/24"))
    }

    func testIPv4Matches_cidrSlash32() {
        let addr = IPv4Address([1, 2, 3, 4])!
        XCTAssertTrue(addr.matches(pattern: "1.2.3.4/32"))
        XCTAssertFalse(addr.matches(pattern: "1.2.3.5/32"))
    }

    func testIPv4Matches_cidrSlash0MatchesAll() {
        let addr = IPv4Address([9, 8, 7, 6])!
        XCTAssertTrue(addr.matches(pattern: "0.0.0.0/0"))
    }

    func testIPv4Matches_cidrShorthandTwoOctets() {
        // "17.142/16" expands to "17.142.0.0/16"
        XCTAssertTrue(IPv4Address([17, 142, 160, 1])!.matches(pattern: "17.142/16"))
        XCTAssertTrue(IPv4Address([17, 142, 0, 1])!.matches(pattern: "17.142/16"))
        XCTAssertFalse(IPv4Address([17, 143, 0, 1])!.matches(pattern: "17.142/16"))
    }

    func testIPv4Matches_cidrShorthandOneOctet() {
        // "10/8" expands to "10.0.0.0/8"
        XCTAssertTrue(IPv4Address([10, 0, 0, 1])!.matches(pattern: "10/8"))
        XCTAssertTrue(IPv4Address([10, 255, 255, 255])!.matches(pattern: "10/8"))
        XCTAssertFalse(IPv4Address([11, 0, 0, 1])!.matches(pattern: "10/8"))
    }

    // MARK: - IPv4Address.matches — string fallback

    func testIPv4Matches_stringFallbackExact() {
        let addr = IPv4Address([1, 2, 3, 4])!
        XCTAssertTrue(addr.matches(pattern: "1.2.3.4"))
        XCTAssertFalse(addr.matches(pattern: "1.2.3.5"))
    }

    func testIPv4Matches_wildcardFallback() {
        let addr = IPv4Address([1, 2, 3, 4])!
        XCTAssertTrue(addr.matches(pattern: "*"))
    }

    // MARK: - IPv6Address.matches — CIDR

    func testIPv6Matches_cidrHit() {
        // 2001:db8::1 is inside 2001:db8::/32
        let addr = IPv6Address([
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ])!
        XCTAssertTrue(addr.matches(pattern: "2001:db8::/32"))
    }

    func testIPv6Matches_cidrMiss() {
        // 2001:db9::1 is outside 2001:db8::/32
        let addr = IPv6Address([
            0x20, 0x01, 0x0d, 0xb9, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ])!
        XCTAssertFalse(addr.matches(pattern: "2001:db8::/32"))
    }

    func testIPv6Matches_cidrSlash128() {
        let addr = IPv6Address.loopback
        XCTAssertTrue(addr.matches(pattern: "::1/128"))
        XCTAssertFalse(addr.matches(pattern: "::2/128"))
    }

    func testIPv6Matches_cidrSlash0MatchesAll() {
        XCTAssertTrue(IPv6Address.loopback.matches(pattern: "::/0"))
        XCTAssertTrue(IPv6Address.any.matches(pattern: "::/0"))
    }

    // MARK: - IPv6Address.matches — string fallback

    func testIPv6Matches_stringFallbackExact() {
        XCTAssertTrue(IPv6Address.loopback.matches(pattern: "::1"))
        XCTAssertFalse(IPv6Address.loopback.matches(pattern: "::2"))
    }

    func testIPv6Matches_wildcardFallback() {
        XCTAssertTrue(IPv6Address.loopback.matches(pattern: "*"))
    }

    // MARK: - IPv6Address.isSynthesizedNAT64

    func testIsSynthesizedNAT64_emptyPrefixes() {
        XCTAssertFalse(IPv6Address.loopback.isSynthesizedNAT64(prefixes: []))
    }

    func testIsSynthesizedNAT64_nonMatchingPrefix() {
        let prefix = NAT64Prefix.wellKnownPrefix
        XCTAssertFalse(IPv6Address.loopback.isSynthesizedNAT64(prefixes: [prefix]))
    }

    func testIsSynthesizedNAT64_wellKnownPrefix() {
        let prefix = NAT64Prefix.wellKnownPrefix
        let ipv4 = IPv4Address([8, 8, 8, 8])!
        let synth = IPv6Address.synthesized(from: ipv4, prefix: prefix)!
        XCTAssertTrue(synth.isSynthesizedNAT64(prefixes: [prefix]))
    }

    func testIsSynthesizedNAT64_customPrefix96() {
        let prefix = NAT64Prefix(
            length: .prefixLength96,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        let ipv4 = IPv4Address([1, 1, 1, 1])!
        let synth = IPv6Address.synthesized(from: ipv4, prefix: prefix)!
        XCTAssertTrue(synth.isSynthesizedNAT64(prefixes: [prefix]))
        XCTAssertFalse(IPv6Address.loopback.isSynthesizedNAT64(prefixes: [prefix]))
    }

    func testIsSynthesizedNAT64_customPrefix32() {
        let prefix = NAT64Prefix(
            length: .prefixLength32,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        let ipv4 = IPv4Address([1, 2, 3, 4])!
        let synth = IPv6Address.synthesized(from: ipv4, prefix: prefix)!
        XCTAssertTrue(synth.isSynthesizedNAT64(prefixes: [prefix]))
    }

    func testIsSynthesizedNAT64_allPrefixLengths() {
        let cases: [(NAT64PrefixLength, [UInt8])] = [
            (.prefixLength40, [0x20, 0x01, 0x0d, 0xb8, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            (.prefixLength48, [0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            (.prefixLength56, [0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            (.prefixLength64, [0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0]),
        ]
        let ipv4 = IPv4Address([8, 8, 8, 8])!
        for (length, addrBytes) in cases {
            let prefix = NAT64Prefix(length: length, address: IPv6Address(addrBytes)!)
            let synth = IPv6Address.synthesized(from: ipv4, prefix: prefix)!
            XCTAssertTrue(synth.isSynthesizedNAT64(prefixes: [prefix]), "failed for \(length)")
            XCTAssertFalse(IPv6Address.loopback.isSynthesizedNAT64(prefixes: [prefix]), "false positive for \(length)")
        }
    }

    func testIsSynthesizedNAT64_matchesFirstOfMultiplePrefixes() {
        let wellKnown = NAT64Prefix.wellKnownPrefix
        let custom = NAT64Prefix(
            length: .prefixLength96,
            address: IPv6Address([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])!
        )
        let ipv4 = IPv4Address([8, 8, 8, 8])!
        let synth = IPv6Address.synthesized(from: ipv4, prefix: wellKnown)!
        XCTAssertTrue(synth.isSynthesizedNAT64(prefixes: [custom, wellKnown]))
    }

    // MARK: - Endpoint.matchesPattern

    func testEndpointMatchesPattern_wildcardMatchesAll() {
        let hostEP = Endpoint(hostname: "example.com", port: 80)
        let addrEP = Endpoint(address: IPv4Address([1, 2, 3, 4])!, port: 443)
        XCTAssertTrue(hostEP.matchesPattern("*"))
        XCTAssertTrue(addrEP.matchesPattern("*"))
    }

    func testEndpointMatchesPattern_hostEndpointDomain() {
        let ep = Endpoint(hostname: "www.example.com", port: 80)
        XCTAssertTrue(ep.matchesPattern("example.com"))
        XCTAssertTrue(ep.matchesPattern("*.example.com"))
        XCTAssertFalse(ep.matchesPattern("test.com"))
    }

    func testEndpointMatchesPattern_ipv4AddressCIDR() {
        let ep = Endpoint(address: IPv4Address([192, 168, 1, 10])!, port: 443)
        XCTAssertTrue(ep.matchesPattern("192.168.1.0/24"))
        XCTAssertFalse(ep.matchesPattern("10.0.0.0/8"))
    }

    func testEndpointMatchesPattern_ipv4AddressString() {
        let ep = Endpoint(address: IPv4Address([1, 2, 3, 4])!, port: 80)
        XCTAssertTrue(ep.matchesPattern("1.2.3.4"))
        XCTAssertFalse(ep.matchesPattern("1.2.3.5"))
    }

    func testEndpointMatchesPattern_ipv6AddressCIDR() {
        let addr = IPv6Address([
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ])!
        let ep = Endpoint(address: addr, port: 443)
        XCTAssertTrue(ep.matchesPattern("2001:db8::/32"))
        XCTAssertFalse(ep.matchesPattern("2001:db9::/32"))
    }
}
