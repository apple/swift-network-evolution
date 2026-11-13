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
@_spi(Essentials) @testable import Network
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

    func testInterleave_preferredCountTwoIsTheDefaultAndOneIsTheFloor() {
        // The default Preferred Address Family Count is 2, and values below 1 are clamped to 1.
        // Pinned as literals so neither can drift silently.
        let families = [Family.v6, .v6, .v6, .v4]
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families), [0, 1, 3, 2])
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 2), [0, 1, 3, 2])
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 1), [0, 3, 1, 2])
        XCTAssertEqual(EndpointOrdering.interleaveByFamily(families, preferredFamilyCount: 0), [0, 3, 1, 2])
    }

    func testInterleave_twoEntriesOfDifferentFamiliesAreUnchanged() {
        // The second family already sits at index 1, which is not past the preferred run.
        XCTAssertEqual(EndpointOrdering.interleaveByFamily([Family.v6, .v4]), [0, 1])
    }

    func testInterleave_threeEntriesAreUnchangedWithDefaultCount() {
        // With a preferred count of 2 the second family at index 2 is not past the preferred run.
        XCTAssertEqual(EndpointOrdering.interleaveByFamily([Family.v6, .v6, .v4]), [0, 1, 2])
        // Lowering the count to 1 does promote it.
        XCTAssertEqual(
            EndpointOrdering.interleaveByFamily([Family.v6, .v6, .v4], preferredFamilyCount: 1),
            [0, 2, 1]
        )
    }

    func testInterleave_onlyOnePullUpRegardlessOfFamilyCount() {
        // Three distinct families: only the first entry of the *second* family is promoted;
        // the third family is left where it is.
        enum Three: Equatable { case a, b, c }
        let order = EndpointOrdering.interleaveByFamily([Three.a, .a, .a, .b, .c])
        XCTAssertEqual(order, [0, 1, 3, 2, 4])
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
        XCTAssertEqual(EndpointOrdering.orderEndpoints(endpoints).map(\.addressFamily), [.ipv6, .ipv6, .ipv4, .ipv4])
    }

    func testOrderEndpoints_interleavesFamilies() {
        // Four IPv6 and one IPv4 all sort IPv6-first by RFC 6724; interleaving then pulls the
        // IPv4 address up so it is not tried last. With the default count of 2 it lands third.
        let endpoints = [
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), v6("2001:db8::4"),
            v4("1.2.3.4"),
        ]
        XCTAssertEqual(
            EndpointOrdering.orderEndpoints(endpoints).map(\.addressFamily),
            [.ipv6, .ipv6, .ipv4, .ipv6, .ipv6]
        )
    }

    func testOrderEndpoints_honorsPreferredFamilyCount() {
        let endpoints = [
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), v6("2001:db8::4"),
            v4("1.2.3.4"),
        ]
        XCTAssertEqual(
            EndpointOrdering.orderEndpoints(endpoints, preferredFamilyCount: 1).map(\.addressFamily),
            [.ipv6, .ipv4, .ipv6, .ipv6, .ipv6]
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
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv6, .ipv4, .ipv6, .ipv6])
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

    func testOrderEndpoints_interleavingReachesAcrossServicesSharingAPriority() {
        // Service A is three IPv6 addresses, service B a single IPv4 one, both at priority 10.
        // The run key is priority alone, so the two services form one run and service B's IPv4
        // address is pulled forward into service A's block — hedging against a broken family
        // takes precedence over keeping one service's addresses contiguous.
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::a1", priority: 10, weight: 100),
            v6("2001:db8::a2", priority: 10, weight: 100),
            v6("2001:db8::a3", priority: 10, weight: 100),
            v4("10.0.0.9", priority: 10, weight: 200),
        ])
        XCTAssertEqual(ordered.map(\.weight), [100, 100, 200, 100])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv6, .ipv4, .ipv6])
    }

    // MARK: - orderByServicePriority, SRV origin

    func testPriority_srvOriginTreatsZeroAsTheBestPriority() {
        // An SRV priority comes off the wire, where 0 is an ordinary and most-preferred value —
        // the opposite of a service-binding priority, where 0 means no record at all.
        let entries = [(priority: UInt16(10), weight: UInt16(0)), (priority: UInt16(0), weight: UInt16(0))]
        XCTAssertEqual(EndpointOrdering.orderByServicePriority(entries, priorityOrigin: .srv), [1, 0])
        XCTAssertEqual(EndpointOrdering.orderByServicePriority(entries, priorityOrigin: .serviceBinding), [0, 1])
    }

    func testPriority_srvOriginIgnoresWeight() {
        // Weight is not an ordering key for SRV; the proportional draw handles it instead, so
        // equal priorities keep their input order here however the weights compare.
        let entries = [(priority: UInt16(1), weight: UInt16(200)), (priority: UInt16(1), weight: UInt16(10))]
        XCTAssertEqual(EndpointOrdering.orderByServicePriority(entries, priorityOrigin: .srv), [0, 1])
        XCTAssertEqual(EndpointOrdering.orderByServicePriority(entries, priorityOrigin: .serviceBinding), [1, 0])
    }

    // MARK: - orderBySRVWeight
    //
    // RFC 2782: within one priority, the chance of being drawn is the entry's share of the
    // group's total weight, favouring larger weights. `randomBelow` pins the draw —
    // `{ _ in 0 }` takes the first remaining non-zero-weight entry, `{ $0 - 1 }` the entry whose
    // running weight sits last. The input is assumed already grouped by priority.

    func testSRVWeight_groupsAreOrderedIndependently() {
        let entries = [
            (priority: UInt16(0), weight: UInt16(1)),
            (priority: UInt16(0), weight: UInt16(1)),
            (priority: UInt16(5), weight: UInt16(1)),
        ]
        let order = EndpointOrdering.orderBySRVWeight(entries, randomBelow: { _ in 0 })
        XCTAssertEqual(order, [0, 1, 2])
        assertIsPermutation(order, count: entries.count)
    }

    func testSRVWeight_zeroDrawTakesNonZeroWeightsThenZeroWeights() {
        let entries = [
            (priority: UInt16(0), weight: UInt16(3)),
            (priority: UInt16(0), weight: UInt16(0)),
            (priority: UInt16(0), weight: UInt16(5)),
        ]
        XCTAssertEqual(EndpointOrdering.orderBySRVWeight(entries, randomBelow: { _ in 0 }), [0, 2, 1])
    }

    func testSRVWeight_topDrawTakesTheLastRunningWeightFirst() {
        let entries = [
            (priority: UInt16(0), weight: UInt16(3)),
            (priority: UInt16(0), weight: UInt16(5)),
        ]
        XCTAssertEqual(EndpointOrdering.orderBySRVWeight(entries, randomBelow: { $0 - 1 }), [1, 0])
    }

    func testSRVWeight_allZeroWeightsKeepInputOrder() {
        let entries = [
            (priority: UInt16(0), weight: UInt16(0)),
            (priority: UInt16(0), weight: UInt16(0)),
        ]
        XCTAssertEqual(EndpointOrdering.orderBySRVWeight(entries, randomBelow: { _ in 0 }), [0, 1])
    }

    func testSRVWeight_isAPermutationWithGroupsPreservedUnderRealRandomness() {
        let entries = [
            (priority: UInt16(1), weight: UInt16(10)),
            (priority: UInt16(1), weight: UInt16(20)),
            (priority: UInt16(1), weight: UInt16(0)),
            (priority: UInt16(2), weight: UInt16(0)),
        ]
        let order = EndpointOrdering.orderBySRVWeight(entries, randomBelow: { UInt32.random(in: 0..<$0) })
        assertIsPermutation(order, count: entries.count)
        // The sole priority-2 entry stays last whatever the draw.
        XCTAssertEqual(order.last, 3)
    }

    // MARK: - preferConnectedOrder

    func testPreferConnected_mostConnectedFlowsMovesToTheFront() {
        let uses: [(connectedFlows: UInt32, activeInstances: UInt64)] = [
            (connectedFlows: 0, activeInstances: 0),
            (connectedFlows: 3, activeInstances: 0),
            (connectedFlows: 1, activeInstances: 0),
        ]
        XCTAssertEqual(EndpointOrdering.preferConnectedOrder(uses), [1, 0, 2])
    }

    func testPreferConnected_fallsBackToActiveInstances() {
        // Nothing is connected, so the entry with the most active instances wins instead.
        let uses: [(connectedFlows: UInt32, activeInstances: UInt64)] = [
            (connectedFlows: 0, activeInstances: 1),
            (connectedFlows: 0, activeInstances: 7),
        ]
        XCTAssertEqual(EndpointOrdering.preferConnectedOrder(uses), [1, 0])
    }

    func testPreferConnected_connectedFlowsOutrankActiveInstances() {
        let uses: [(connectedFlows: UInt32, activeInstances: UInt64)] = [
            (connectedFlows: 0, activeInstances: 99),
            (connectedFlows: 1, activeInstances: 0),
        ]
        XCTAssertEqual(EndpointOrdering.preferConnectedOrder(uses), [1, 0])
    }

    func testPreferConnected_nothingInUseOrAlreadyFirstIsANoOp() {
        let idle: [(connectedFlows: UInt32, activeInstances: UInt64)] = [
            (connectedFlows: 0, activeInstances: 0),
            (connectedFlows: 0, activeInstances: 0),
        ]
        XCTAssertEqual(EndpointOrdering.preferConnectedOrder(idle), [0, 1])
        let alreadyFirst: [(connectedFlows: UInt32, activeInstances: UInt64)] = [
            (connectedFlows: 5, activeInstances: 0),
            (connectedFlows: 1, activeInstances: 0),
        ]
        XCTAssertEqual(EndpointOrdering.preferConnectedOrder(alreadyFirst), [0, 1])
    }

    func testPreferConnected_firstOfATieWins() {
        let uses: [(connectedFlows: UInt32, activeInstances: UInt64)] = [
            (connectedFlows: 1, activeInstances: 0),
            (connectedFlows: 2, activeInstances: 0),
            (connectedFlows: 2, activeInstances: 0),
        ]
        XCTAssertEqual(EndpointOrdering.preferConnectedOrder(uses), [1, 0, 2])
    }

    func testOrderEndpoints_preferConnectedLiftsOutOfItsPriorityGroup() {
        // Established use is applied to the whole list, so it can lift an endpoint past a better
        // priority — reusing a live connection outranks a service's stated preference.
        let better = v6("2001:db8::1", priority: 10)
        let connected = v6("2001:db8::9", priority: 20)
        let ordered = EndpointOrdering.orderEndpoints(
            [better, connected],
            readingConnectionUse: { endpoint in
                endpoint.priority == 20
                    ? (connectedFlows: 4, activeInstances: 0) : (connectedFlows: 0, activeInstances: 0)
            }
        )
        XCTAssertEqual(ordered.map(\.priority), [20, 10])
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
        // A Unix-domain endpoint is still an address endpoint, so it does not disqualify the run:
        // interleaving happens among the IP endpoints and the Unix endpoint keeps its slot.
        let unix = Endpoint(AddressEndpoint("/tmp/example.sock")!)
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::1"), v6("2001:db8::2"), v6("2001:db8::3"), v4("1.2.3.4"), unix,
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, .ipv6, .ipv4, .ipv6, .unix])
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
        // An endpoint with no address holds its slot and the addresses interleave around it, the
        // same treatment a Unix-domain endpoint gets. The host keeps index 1, and the IPv4
        // address is pulled into the first free *address* slot past the preferred run — which is
        // index 3, not index 2, because index 1 is not an address slot.
        let host = Endpoint(hostname: "example.com", port: 443)
        let ordered = EndpointOrdering.orderEndpoints([
            v6("2001:db8::1"), host, v6("2001:db8::2"), v6("2001:db8::3"), v4("1.2.3.4"),
        ])
        XCTAssertEqual(ordered.map(\.addressFamily), [.ipv6, nil, .ipv6, .ipv4, .ipv6])
    }
}
