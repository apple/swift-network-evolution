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
final class SwiftNetworkEndpointOrderingTests: NetTestCase {

    // MARK: - Helpers

    /// A stand-in family token for the portable-core tests. Using a type the core knows
    /// nothing about is what demonstrates it has no dependency on this package.
    private enum Family: Equatable {
        case v6
        case v4
    }

    private func v4(
        _ string: String,
        port: UInt16 = 443,
        priority: UInt16 = 0,
        weight: UInt16 = 0
    ) -> Endpoint {
        var address = AddressEndpoint(address: IPv4Address(string)!, port: port)
        address.priority = priority
        address.weight = weight
        return Endpoint(address)
    }

    private func v6(
        _ string: String,
        port: UInt16 = 443,
        priority: UInt16 = 0,
        weight: UInt16 = 0
    ) -> Endpoint {
        var address = AddressEndpoint(address: IPv6Address(string)!, port: port)
        address.priority = priority
        address.weight = weight
        return Endpoint(address)
    }

    /// Asserts that `order` is a genuine permutation of `0..<count` — no duplicates, no
    /// dropped entries, nothing out of range. A reordering that loses or repeats an endpoint
    /// is the failure mode that matters.
    private func assertIsPermutation(_ order: [Int], count: Int, line: UInt = #line) {
        XCTAssertEqual(order.count, count, "permutation length", line: line)
        XCTAssertEqual(order.sorted(), Array(0..<count), "not a permutation of 0..<\(count)", line: line)
    }

    // MARK: - interleaveByFamily: cases that must not reorder

    func testInterleave_empty() {
        XCTAssertEqual(EndpointOrdering.interleaveByFamily([Family]()), [])
    }

    func testInterleave_singleEntry() {
        XCTAssertEqual(EndpointOrdering.interleaveByFamily([Family.v6]), [0])
    }

    func testInterleave_allOneFamily() {
        let families = [Family.v6, .v6, .v6, .v6, .v6]
        let order = EndpointOrdering.interleaveByFamily(families)
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        assertIsPermutation(order, count: families.count)
    }

    func testInterleave_secondFamilyAlreadyEarly() {
        // v4 already sits within the preferred run, so nothing is pulled up.
        let families = [Family.v6, .v4, .v6, .v6, .v6]
        let order = EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 2)
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        assertIsPermutation(order, count: families.count)
    }

    func testInterleave_largePreferredCountDisablesReordering() {
        XCTAssertEqual(
            EndpointOrdering.interleaveByFamily([Family.v6, .v6, .v6, .v4], preferredFamilyCount: 10),
            [0, 1, 2, 3]
        )
    }

    // MARK: - interleaveByFamily: the pull-up

    func testInterleave_pullsSecondFamilyUp() {
        // Four IPv6 then one IPv4, preferring two: the IPv4 entry moves to index 2, so at
        // most two IPv6 addresses are tried before IPv4 is tried at all.
        let families = [Family.v6, .v6, .v6, .v6, .v4]
        let order = EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 2)
        XCTAssertEqual(order, [0, 1, 4, 2, 3])
        assertIsPermutation(order, count: families.count)
    }

    func testInterleave_pullUpMovesRatherThanDuplicates() {
        let families = [Family.v6, .v6, .v6, .v4]
        let order = EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 2)
        XCTAssertEqual(order, [0, 1, 3, 2])
        assertIsPermutation(order, count: families.count)
    }

    func testInterleave_onlyFirstSecondFamilyEntryIsPulled() {
        let families = [Family.v6, .v6, .v6, .v6, .v4, .v4]
        let order = EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 2)
        XCTAssertEqual(order, [0, 1, 4, 2, 3, 5])
        assertIsPermutation(order, count: families.count)
    }

    func testInterleave_preferredCountOneIsBothTheDefaultAndTheFloor() {
        // The spec's recommended Preferred Address Family Count is 1, and values below 1 are
        // clamped to it. Pinned as a literal so the default cannot drift silently.
        let families = [Family.v6, .v6, .v6, .v4]
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families), [0, 3, 1, 2])
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 1), [0, 3, 1, 2])
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 0), [0, 3, 1, 2])
    }

    func testInterleave_twoEntriesOfDifferentFamiliesAreUnchanged() {
        // The second family already sits at index 1, which is not past the preferred run.
        XCTAssertEqual(EndpointOrdering.interleaveByFamily([Family.v6, .v4]), [0, 1])
    }

    func testInterleave_threeEntriesPullUpWithDefaultCount() {
        XCTAssertEqual(EndpointOrdering.interleaveByFamily([Family.v6, .v6, .v4]), [0, 2, 1])
    }

    func testInterleave_onlyOnePullUpRegardlessOfFamilyCount() {
        // Three distinct families: only the first entry of the *second* family is promoted;
        // the third family is left where it is.
        enum Three: Equatable { case a, b, c }
        let order = EndpointOrdering.interleaveByFamily([Three.a, .a, .a, .b, .c])
        XCTAssertEqual(order, [0, 3, 1, 2, 4])
        assertIsPermutation(order, count: 5)
    }

    func testInterleave_leadingFamilyIsWhicheverComesFirst() {
        // The function has no notion of "IPv6"; it interleaves whatever leads.
        XCTAssertEqual(
            EndpointOrdering.interleaveByFamily([Family.v4, .v4, .v4, .v6], preferredFamilyCount: 2),
            [0, 1, 3, 2]
        )
    }

    // MARK: - orderByServicePriority

    func testPriority_allZeroPreservesOrder() {
        // The common case: no SVCB records, so every priority and weight is 0.
        let entries = [(priority: UInt16(0), weight: UInt16(0))]
        XCTAssertEqual(EndpointOrdering.orderByServicePriority(entries + entries + entries), [0, 1, 2])
    }

    func testPriority_zeroSortsAfterRealPriorities() {
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([(priority: 0, weight: 0), (priority: 5, weight: 0)]),
            [1, 0]
        )
    }

    func testPriority_lowerPriorityFirst() {
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([
                (priority: 30, weight: 0), (priority: 10, weight: 0), (priority: 20, weight: 0),
            ]),
            [1, 2, 0]
        )
    }

    func testPriority_maxPriorityIsStillARealPriority() {
        // UInt16.max is a legitimate priority and must still outrank the no-service group.
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([(priority: 0, weight: 0), (priority: UInt16.max, weight: 0)]),
            [1, 0]
        )
    }

    func testPriority_realPrioritiesGroupInOrderWithNoServiceLast() {
        let order = EndpointOrdering.orderByServicePriority([
            (priority: 0, weight: 0), (priority: 20, weight: 0), (priority: 10, weight: 0),
            (priority: 0, weight: 0), (priority: 20, weight: 0),
        ])
        // Priority 10, then both 20s in arrival order, then both no-service entries.
        XCTAssertEqual(order, [2, 1, 4, 0, 3])
    }

    func testPriority_lowerWeightFirstWhenBothNonZero() {
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([(priority: 10, weight: 200), (priority: 10, weight: 100)]),
            [1, 0]
        )
    }

    func testPriority_zeroWeightNeverParticipates() {
        // A zero weight means "none supplied", so it must not be read as the lightest.
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([(priority: 10, weight: 200), (priority: 10, weight: 0)]),
            [0, 1]
        )
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([(priority: 10, weight: 0), (priority: 10, weight: 200)]),
            [0, 1]
        )
    }

    func testPriority_equalRankPreservesOrder() {
        let entries = [(priority: UInt16(10), weight: UInt16(5))]
        XCTAssertEqual(EndpointOrdering.orderByServicePriority(entries + entries + entries), [0, 1, 2])
    }

    func testPriority_priorityOutranksWeight() {
        // A better priority wins even when the other entry has a lighter weight.
        XCTAssertEqual(
            EndpointOrdering.orderByServicePriority([(priority: 20, weight: 1), (priority: 10, weight: 999)]),
            [1, 0]
        )
    }

    func testPriority_emptyAndSingle() {
        XCTAssertEqual(EndpointOrdering.orderByServicePriority([]), [])
        XCTAssertEqual(EndpointOrdering.orderByServicePriority([(priority: 7, weight: 3)]), [0])
    }

    // MARK: - orderEndpoints

    func testOrderEndpoints_emptyAndSingle() {
        XCTAssertEqual(EndpointOrdering.orderEndpoints([]).count, 0)
        XCTAssertEqual(EndpointOrdering.orderEndpoints([v4("1.2.3.4")]).count, 1)
    }

    func testOrderEndpoints_globalIPv6BeforeIPv4() {
        // RFC 6724 gives a global IPv6 address precedence 40 against IPv4's 35.
        XCTAssertEqual(
            EndpointOrdering.orderEndpoints([v4("1.2.3.4"), v6("2001:db8::1")]).map(\.addressFamily),
            [.ipv6, .ipv4]
        )
    }

    func testOrderEndpoints_plainAddressesKeepAddressOrdering() {
        // Plain A/AAAA results carry no priority or weight, so the priority pass is a no-op
        // and the RFC 6724 ordering stands.
        let endpoints = [v4("1.2.3.4"), v6("2001:db8::1"), v4("5.6.7.8"), v6("2001:db8::2")]
        XCTAssertEqual(EndpointOrdering.orderEndpoints(endpoints).map(\.addressFamily), [.ipv6, .ipv4, .ipv6, .ipv4])
    }

    func testOrderEndpoints_interleavesFamilies() {
        // Four IPv6 and one IPv4 all sort IPv6-first by RFC 6724; interleaving then pulls the
        // IPv4 address up so it is not tried last. With the default count of 1 it lands second.
        let endpoints = [
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), v6("2001:db8::4"),
            v4("1.2.3.4"),
        ]
        XCTAssertEqual(
            EndpointOrdering.orderEndpoints(endpoints).map(\.addressFamily),
            [.ipv6, .ipv4, .ipv6, .ipv6, .ipv6]
        )
    }

    func testOrderEndpoints_honorsPreferredFamilyCount() {
        let endpoints = [
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), v6("2001:db8::4"),
            v4("1.2.3.4"),
        ]
        XCTAssertEqual(
            EndpointOrdering.orderEndpoints(endpoints, preferredFamilyCount: 2).map(\.addressFamily),
            [.ipv6, .ipv6, .ipv4, .ipv6, .ipv6]
        )
    }

    func testOrderEndpoints_priorityOutranksAddressPreference() {
        // The IPv4 address carries the better (lower, non-zero) priority, so it is tried
        // first even though RFC 6724 prefers the IPv6 address.
        XCTAssertEqual(
            EndpointOrdering.orderEndpoints([v6("2001:db8::1", priority: 20), v4("1.2.3.4", priority: 10)])
                .map(\.addressFamily),
            [.ipv4, .ipv6]
        )
    }

    func testOrderEndpoints_interleavingStaysWithinPriorityRuns() {
        // Priority 10 is three IPv6 and one IPv4; priority 20 is one IPv6. Interleaving must
        // not lift the second run's entry into the first.
        let endpoints = [
            v6("2001:db8::1", priority: 10), v6("2001:db8::2", priority: 10),
            v6("2001:db8::3", priority: 10), v4("1.2.3.4", priority: 10),
            v6("2001:db8::9", priority: 20),
        ]
        let ordered = EndpointOrdering.orderEndpoints(endpoints)
        XCTAssertEqual(ordered.map(\.priority), [10, 10, 10, 10, 20])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv4, .ipv6, .ipv6, .ipv6])
    }

    func testOrderEndpoints_addressSelectionSurvivesAsWithinServiceTiebreak() {
        // Two endpoints of one service, so they tie on priority and weight. The priority pass
        // is stable, so RFC 6724 decides — IPv6 first — rather than being discarded.
        let ordered = EndpointOrdering.orderEndpoints([
            v4("1.2.3.4", priority: 10, weight: 100),
            v6("2001:db8::1", priority: 10, weight: 100),
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv4])
    }

    func testOrderEndpoints_equalPriorityServicesStayContiguous() {
        // Two services at the same priority, distinguished only by their weights, each with an
        // IPv6 and an IPv4 endpoint. Each service's endpoints must stay together as a block,
        // internally ordered by RFC 6724 — this is what gives equal-priority services a random
        // relative order without interleaving their addresses.
        let ordered = EndpointOrdering.orderEndpoints([
            v4("10.0.0.1", priority: 10, weight: 100),
            v6("2001:db8::a1", priority: 10, weight: 100),
            v4("10.0.0.2", priority: 10, weight: 200),
            v6("2001:db8::b1", priority: 10, weight: 200),
        ])
        XCTAssertEqual(ordered.map(\.weight), [100, 100, 200, 200])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv4, .ipv6, .ipv4])
    }

    func testOrderEndpoints_interleavingDoesNotReachAcrossServices() {
        // Service A is three IPv6 addresses, service B a single IPv4 one, both at priority 10.
        // Service A has nothing to interleave with, so its block must be left alone — pulling
        // service B's IPv4 address forward into it would reorder one service relative to
        // another, which no sorting step is allowed to do.
        //
        // This is the case `testOrderEndpoints_equalPriorityServicesStayContiguous` misses:
        // there the families alternate, so interleaving is a no-op and contiguity holds for
        // free. Here the pull-up genuinely fires if the run key is priority alone.
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::a1", priority: 10, weight: 100),
            v6("2001:db8::a2", priority: 10, weight: 100),
            v6("2001:db8::a3", priority: 10, weight: 100),
            v4("10.0.0.9", priority: 10, weight: 200),
        ])
        XCTAssertEqual(ordered.map(\.weight), [100, 100, 100, 200])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv6, .ipv6, .ipv4])
    }

    func testEndpointAccessors_forwardForHostEndpoints() {
        // `Endpoint.priority`/`.weight` switch over all six endpoint kinds. The `.host` arm is
        // otherwise unexercised, and HostEndpoint is where SRV priority/weight would live.
        var host = HostEndpoint(name: "example.com", port: 443)
        host.priority = 10
        host.weight = 20
        let endpoint = Endpoint(host)
        XCTAssertEqual(endpoint.priority, 10)
        XCTAssertEqual(endpoint.weight, 20)
        XCTAssertNil(endpoint.addressFamily)
    }

    func testOrderEndpoints_unixEndpointIsNotAnIPFamily() {
        // A Unix-domain endpoint has an address family (.unix) but not an IP one, so it must not
        // act as the second family. Interleaving hedges IPv4 against IPv6; IPv6 is not a
        // fallback for a Unix socket. It also carries no RFC 6724 precedence, so it ranks last.
        let unix = Endpoint(AddressEndpoint("/tmp/example.sock")!)
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), unix,
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv6, .ipv6, .unix])
    }

    func testOrderEndpoints_unixEndpointDoesNotBlockIPv4Interleaving() {
        // With a real IPv4 address present, interleaving still happens among the IP endpoints
        // and the Unix endpoint keeps its slot.
        let unix = Endpoint(AddressEndpoint("/tmp/example.sock")!)
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), v4("1.2.3.4"), unix,
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv4, .ipv6, .ipv6, .unix])
    }

    func testOrderEndpoints_keepsNonAddressEndpoints() {
        // A host endpoint has no address to compare, so it must be carried through rather
        // than dropped.
        let host = Endpoint(hostname: "example.com", port: 443)
        let ordered = EndpointOrdering.orderEndpoints([v6("2001:db8::1"), host, v4("1.2.3.4")])
        XCTAssertEqual(ordered.count, 3)
        XCTAssertTrue(ordered.contains { $0.addressFamily == nil })
    }

    func testOrderEndpoints_nonAddressEndpointIsNotAFamily() {
        // An endpoint with no address has a `nil` family, which must not be treated as a second
        // address family. It holds its slot rather than being promoted ahead of real addresses,
        // and the three IPv6 addresses have nothing to interleave with.
        let host = Endpoint(hostname: "example.com", port: 443)
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), host,
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv6, .ipv6, nil])
    }

    func testOrderEndpoints_interleavesAroundANonAddressEndpoint() {
        // The host sits between addresses: it keeps index 1, and the IPv4 address is pulled up
        // into the first free address slot after the preferred run rather than to index 1.
        let host = Endpoint(hostname: "example.com", port: 443)
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::1"), host, v6("2001:db8::2"), v6("2001:db8::3"), v4("1.2.3.4"),
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, nil, .ipv4, .ipv6, .ipv6])
    }
}
