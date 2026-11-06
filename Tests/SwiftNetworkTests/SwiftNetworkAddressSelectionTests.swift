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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkAddressSelectionTests: NetTestCase {

    // MARK: - Helpers

    private func v4(_ string: String, port: UInt16 = 0) -> AddressEndpoint {
        AddressEndpoint(address: IPv4Address(string)!, port: port)
    }

    private func v6(_ string: String, port: UInt16 = 0) -> AddressEndpoint {
        AddressEndpoint(address: IPv6Address(string)!, port: port)
    }

    // MARK: - Precedence (RFC 6724 default policy table)

    func testPrecedence_loopback() {
        XCTAssertEqual(IPv6Address("::1")!.rfc6724Precedence, 50)
    }

    func testPrecedence_global() {
        XCTAssertEqual(IPv6Address("2607:f8b0::1")!.rfc6724Precedence, 40)
    }

    func testPrecedence_v4Mapped() {
        XCTAssertEqual(IPv6Address("::ffff:102:304")!.rfc6724Precedence, 35)
    }

    func testPrecedence_6to4() {
        XCTAssertEqual(IPv6Address("2002::1")!.rfc6724Precedence, 30)
    }

    func testPrecedence_teredo() {
        XCTAssertEqual(IPv6Address("2001:0:1::1")!.rfc6724Precedence, 5)
    }

    func testPrecedence_uniqueLocal() {
        XCTAssertEqual(IPv6Address("fc00::1")!.rfc6724Precedence, 3)
        XCTAssertEqual(IPv6Address("fdff::1")!.rfc6724Precedence, 3)
    }

    func testPrecedence_uniqueLocalLowerBoundary() {
        // fbff::/16 is outside fc00::/7, so it falls through to the ::/0 default.
        XCTAssertEqual(IPv6Address("fbff::1")!.rfc6724Precedence, 40)
    }

    func testPrecedence_siteLocal() {
        XCTAssertEqual(IPv6Address("fec0::1")!.rfc6724Precedence, 1)
    }

    func testPrecedence_6bone() {
        XCTAssertEqual(IPv6Address("3ffe::1")!.rfc6724Precedence, 1)
    }

    func testPrecedence_unspecifiedTakesTheDefault() {
        // `::` is excluded from ::/96, so it lands on the ::/0 row rather than precedence 1.
        XCTAssertEqual(IPv6Address("::")!.rfc6724Precedence, 40)
    }

    func testPrecedence_documentationPrefixIsNotTeredo() {
        // 2001:db8::/32 is the documentation prefix and must take the ::/0 default, not
        // Teredo's 5. Teredo is 2001:0000::/32, so the check needs all four leading bytes —
        // narrowing it to 2001::/16 would reclassify every 2001:db8:: address in these tests
        // and silently invert the IPv6-before-IPv4 orderings the ordering suite asserts.
        XCTAssertEqual(IPv6Address("2001:db8::1")!.rfc6724Precedence, 40)
        XCTAssertFalse(IPv6Address("2001:db8::1")!.isTeredo)
        XCTAssertTrue(IPv6Address("2001:0:1::1")!.isTeredo)
    }

    func testPrecedence_prefixUpperBoundaries() {
        // One past each prefix, to pin the masks. fe00:: in particular is just outside
        // fc00::/7, whose test is `(byte & 0xfe) == 0xfc`.
        XCTAssertEqual(IPv6Address("fe00::1")!.rfc6724Precedence, 40)  // not fc00::/7
        XCTAssertEqual(IPv6Address("2003::1")!.rfc6724Precedence, 40)  // not 2002::/16
        XCTAssertEqual(IPv6Address("3fff::1")!.rfc6724Precedence, 40)  // not 3ffe::/16
    }

    func testPrecedence_ipv4() {
        XCTAssertEqual(IPv4Address("192.168.0.1")!.rfc6724Precedence, 35)
    }

    func testClassification_v4CompatExcludesSpecials() {
        // The only classification not observable through precedence: ::/96, fec0::/10 and
        // 3ffe::/16 all yield 1, so the `::`/`::1` exclusions need checking directly.
        XCTAssertTrue(IPv6Address("::102:304")!.isV4Compat)
        XCTAssertFalse(IPv6Address("::1")!.isV4Compat)
        XCTAssertFalse(IPv6Address("::")!.isV4Compat)
    }

    // MARK: - Scope

    func testScope_globalV6() {
        XCTAssertEqual(IPv6Address("2607:f8b0::1")!.rfc6724Scope, .global)
    }

    func testScope_linkLocalV6() {
        XCTAssertEqual(IPv6Address("fe80::1")!.rfc6724Scope, .linkLocal)
    }

    func testScope_siteLocalV6() {
        XCTAssertEqual(IPv6Address("fec0::1")!.rfc6724Scope, .siteLocal)
    }

    func testScope_loopbackV6IsLinkLocal() {
        XCTAssertEqual(IPv6Address("::1")!.rfc6724Scope, .linkLocal)
    }

    func testScope_unspecifiedV6IsGlobal() {
        XCTAssertEqual(IPv6Address("::")!.rfc6724Scope, .global)
    }

    func testScope_allZeroPrefixWithOtherFinalByteIsGlobal() {
        // Shares the leading 15 zero bytes with `::` and `::1` but is neither.
        XCTAssertEqual(IPv6Address("::2")!.rfc6724Scope, .global)
        XCTAssertEqual(IPv6Address("::ff")!.rfc6724Scope, .global)
    }

    func testScope_fe00PrefixWithoutLinkOrSiteBitsIsGlobal() {
        // fe00::/9 is neither link-local (fe80::/10) nor site-local (fec0::/10).
        XCTAssertEqual(IPv6Address("fe00::1")!.rfc6724Scope, .global)
        XCTAssertEqual(IPv6Address("fe40::1")!.rfc6724Scope, .global)
    }

    func testScope_multicastInterfaceLocal() {
        XCTAssertEqual(IPv6Address("ff01::1")!.rfc6724Scope, .interfaceLocal)
    }

    func testScope_multicastLinkLocal() {
        XCTAssertEqual(IPv6Address("ff02::1")!.rfc6724Scope, .linkLocal)
    }

    func testScope_multicastSiteLocal() {
        XCTAssertEqual(IPv6Address("ff05::1")!.rfc6724Scope, .siteLocal)
    }

    func testScope_multicastGlobal() {
        XCTAssertEqual(IPv6Address("ff0e::1")!.rfc6724Scope, .global)
    }

    func testScope_multicastUndefinedScopesAreGlobal() {
        // ff08 is organization-local, which RFC 6724 does not rank; ff03/ff04 are reserved.
        for address in ["ff03::1", "ff04::1", "ff08::1"] {
            XCTAssertEqual(IPv6Address(address)!.rfc6724Scope, .global, address)
        }
    }

    func testScope_multicastScopeIgnoresFlagBits() {
        // ff12:: is a transient link-local group: the flags nibble must not leak into scope.
        XCTAssertEqual(IPv6Address("ff12::1")!.rfc6724Scope, .linkLocal)
    }

    func testScope_ipv4Global() {
        XCTAssertEqual(IPv4Address("8.8.8.8")!.rfc6724Scope, .global)
    }

    func testScope_ipv4LoopbackCoversTheWholeBlock() {
        // 127.0.0.0/8, not just 127.0.0.1 — guards against using `isLoopback`, which is /32.
        for address in ["127.0.0.1", "127.1.2.3", "127.255.255.254"] {
            XCTAssertEqual(IPv4Address(address)!.rfc6724Scope, .linkLocal, address)
        }
        XCTAssertEqual(IPv4Address("128.0.0.1")!.rfc6724Scope, .global)
    }

    func testScope_ipv4LinkLocalBoundaries() {
        XCTAssertEqual(IPv4Address("169.254.1.1")!.rfc6724Scope, .linkLocal)
        XCTAssertEqual(IPv4Address("169.253.255.255")!.rfc6724Scope, .global)
        XCTAssertEqual(IPv4Address("169.255.0.0")!.rfc6724Scope, .global)
    }

    // MARK: - Scope ordering

    func testScopeOrdering_narrowerScopeIsPreferred() {
        // Pins the enum's raw values, not just its cases: asserting `== .siteLocal` would
        // still pass if a raw value were wrong, which would silently invert rule 8. Every
        // address here is multicast with precedence 40, so rule 6 ties and rule 8 decides.
        let narrowToWide = ["ff01::1", "ff02::1", "ff05::1", "ff0e::1"]
        for (narrower, wider) in zip(narrowToWide, narrowToWide.dropFirst()) {
            XCTAssertEqual(
                preferredDestination(between: v6(narrower), and: v6(wider)),
                .first,
                "\(narrower) should be preferred over \(wider)"
            )
            XCTAssertEqual(
                preferredDestination(between: v6(wider), and: v6(narrower)),
                .second,
                "\(narrower) should be preferred over \(wider)"
            )
        }
    }

    func testScopeOrdering_narrowerUnicastScopeIsPreferred() {
        // The sweep above is all multicast, so it only pins the raw values reached through the
        // multicast nibble. fec0::/10 and 3ffe::/16 both carry precedence 1, so rule 6 ties and
        // rule 8 decides on the unicast path: site-local beats global.
        XCTAssertEqual(preferredDestination(between: v6("fec0::1"), and: v6("3ffe::1")), .first)
        XCTAssertEqual(preferredDestination(between: v6("3ffe::1"), and: v6("fec0::1")), .second)
    }

    // MARK: - Endpoint-level keys

    func testEndpointKeys_v4MappedNormalizesToIPv4() {
        // AddressEndpoint rewrites an IPv4-mapped IPv6 address to .v4, so the endpoint-level
        // keys are IPv4's. Precedence agrees either way (35); scope does not, and the IPv4
        // reading is the one RFC 6724 specifies for an IPv4 address.
        let mapped = AddressEndpoint(address: IPv6Address("::ffff:7f00:1")!, port: 0)
        XCTAssertEqual(mapped.rfc6724Precedence, 35)
        XCTAssertEqual(mapped.rfc6724ScopeValue, RFC6724Scope.linkLocal.rawValue)
    }

    func testEndpointKeys_nonIPAddressFamilyHasNoKeys() {
        XCTAssertEqual(AddressEndpoint().rfc6724Precedence, 0)
        XCTAssertEqual(AddressEndpoint().rfc6724ScopeValue, 0)
    }

    // MARK: - preferredDestination

    func testCompare_higherPrecedenceWins() {
        // Loopback (50) over global (40).
        XCTAssertEqual(preferredDestination(between: v6("::1"), and: v6("2607:f8b0::1")), .first)
        XCTAssertEqual(preferredDestination(between: v6("2607:f8b0::1"), and: v6("::1")), .second)
    }

    func testCompare_v4PreferredOver6to4() {
        // IPv4 precedence 35 beats 6to4 precedence 30.
        XCTAssertEqual(preferredDestination(between: v4("8.8.8.8"), and: v6("2002::1")), .first)
    }

    func testCompare_smallerScopeWinsWhenPrecedenceEqual() {
        let linkLocal = v6("fe80::1")  // precedence 40, link-local
        let global = v6("2607:f8b0::1")  // precedence 40, global
        XCTAssertEqual(preferredDestination(between: linkLocal, and: global), .first)
        XCTAssertEqual(preferredDestination(between: global, and: linkLocal), .second)
    }

    func testCompare_precedenceDominatesScope() {
        // Rule 6 runs before rule 8, so loopback (precedence 50, link-local) beats a
        // link-local unicast (precedence 40, link-local) on precedence alone.
        XCTAssertEqual(preferredDestination(between: v6("::1"), and: v6("fe80::1")), .first)
    }

    func testCompare_equallyRankedAddressesAreEqual() {
        XCTAssertEqual(preferredDestination(between: v6("2607:f8b0::1"), and: v6("2607:f8b0::2")), .equal)
        XCTAssertEqual(preferredDestination(between: v4("8.8.8.8"), and: v4("1.1.1.1")), .equal)
    }

    func testCompare_nonIPRanksBehindIP() {
        // Every IP address has a precedence of at least 1, so rule 6 puts a non-IP endpoint
        // last without the scope sentinel ever being compared against a real scope.
        XCTAssertEqual(preferredDestination(between: v4("8.8.8.8"), and: AddressEndpoint()), .first)
        XCTAssertEqual(preferredDestination(between: AddressEndpoint(), and: v4("8.8.8.8")), .second)
        XCTAssertEqual(preferredDestination(between: v6("fec0::1"), and: AddressEndpoint()), .first)
    }

    func testCompare_twoNonIPEndpointsAreEqual() {
        XCTAssertEqual(preferredDestination(between: AddressEndpoint(), and: AddressEndpoint()), .equal)
    }
}
