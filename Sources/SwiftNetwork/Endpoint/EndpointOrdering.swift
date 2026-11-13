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

// Connection-attempt ordering, as used by Happy Eyeballs. Follows v3, a work in progress in
// the IETF HAPPY working group:
//
//   draft-ietf-happy-happyeyeballs-v3  Happy Eyeballs Version 3 (work in progress)
//   RFC 8305                           Happy Eyeballs Version 2
//
// Only the sorting stage: this neither resolves names nor races connections, so on its own it
// provides none of the concurrency the specification exists to describe. Of the specification's
// configurable values, only the Preferred Address Family Count appears here.
//
// Three of the stages depend on state this file deliberately does not reach for — the routing
// table, per-destination statistics, and which destinations already carry connections. Those are
// parameters of `orderEndpoints`, with defaults that do nothing, so a caller that has the state
// supplies it and a caller that does not still gets a usable order.

/// Namespace for connection-attempt ordering. A caseless `enum` rather than a `struct`, so it
/// cannot be instantiated.
enum EndpointOrdering {}

// MARK: - Portable core
//
// Pure functions over plain values returning index permutations. They name no package type and
// need no imports; keep it that way. Declared in the order the specification applies them,
// whose section numbers are omitted since they move between draft revisions.

extension EndpointOrdering {

    /// How a priority of `0` is to be read, which differs by the record the priority came from.
    enum PriorityOrigin: Sendable {
        /// A SVCB/HTTPS `SvcPriority` (RFC 9460). `0` is reserved for AliasMode and so never
        /// appears as a usable ServiceMode priority: a `0` here means "no service record" and
        /// sorts after every entry that has one.
        case serviceBinding
        /// An SRV priority (RFC 2782), where `0` is an ordinary value and the most preferred one.
        /// Weight is not an ordering key in this mode — see ``orderBySRVWeight(_:randomBelow:)``.
        case srv
    }

    // MARK: Grouping by application protocol and security requirements

    // Not implemented: no endpoint carries ALPN values or security parameters. Its groups are
    // alternatives rather than one list, so it is not a change to `orderEndpoints`.

    // MARK: Grouping by service priority

    /// Orders entries by service priority, then weight, returning an index permutation. Stable,
    /// so equal-rank entries keep their input order.
    ///
    /// Lower priority is preferred. How `0` is read depends on `priorityOrigin`.
    ///
    /// Weight applies to ``PriorityOrigin/serviceBinding`` only, and is a *synthetic* key rather
    /// than a wire value: give each service record one random weight and stamp it on that record's
    /// endpoints, and equal-priority records take a random relative order while each record's own
    /// endpoints stay contiguous. `0` means none supplied, and a `0` never participates.
    ///
    /// - Important: The weight here is not an SRV weight. RFC 2782 wants a weight-proportional
    ///   draw favouring *larger* weights, which this ascending comparison is wrong for on both
    ///   counts; ``PriorityOrigin/srv`` therefore ignores weight and leaves it to
    ///   ``orderBySRVWeight(_:randomBelow:)``.
    static func orderByServicePriority(
        _ entries: [(priority: UInt16, weight: UInt16)],
        priorityOrigin: PriorityOrigin = .serviceBinding
    ) -> [Int] {
        entries.enumerated().sorted { lhs, rhs in
            let (leftPriority, rightPriority) = (lhs.element.priority, rhs.element.priority)
            if leftPriority != rightPriority {
                switch priorityOrigin {
                case .serviceBinding:
                    // A priority of 0 is the absence of one, so it loses to any real priority.
                    if leftPriority == 0 { return false }
                    if rightPriority == 0 { return true }
                case .srv:
                    // Every value is a real priority, 0 included.
                    break
                }
                return leftPriority < rightPriority
            }
            if case .serviceBinding = priorityOrigin {
                let (leftWeight, rightWeight) = (lhs.element.weight, rhs.element.weight)
                if leftWeight != 0, rightWeight != 0, leftWeight != rightWeight {
                    return leftWeight < rightWeight
                }
            }
            // Equal rank: preserve the input order, since `sorted(by:)` is not stable.
            return lhs.offset < rhs.offset
        }.map(\.offset)
    }

    // MARK: Sorting within a group: destination address selection

    // Required. Implemented in `AddressSelection.swift`; `endpointPreference` below adapts it.
    // A caller holding routing-table state can substitute its own comparator — see the
    // `comparingDestinations` parameter of `orderEndpoints`.

    // MARK: Sorting within a group: prefer lower round-trip time

    // Collected by no part of this file. A caller that keeps per-destination timing history folds
    // it into the comparator it passes as `comparingDestinations`.

    // MARK: Sorting within a group: prefer previously-used addresses

    /// Moves the entry with the most established use to the front, returning an index permutation.
    ///
    /// Reusing a destination that already carries connections avoids paying for a new one. Entries
    /// are ranked by connected flows, falling back to active instances when nothing is connected;
    /// the first entry holding the maximum wins. Returns the order unchanged when nothing is in
    /// use, so a caller with no such state can pass zeroes and get a no-op.
    ///
    /// - Note: Exactly one entry moves, and it moves to the *absolute* front. This runs after
    ///   service grouping and can therefore lift an entry out of its priority group — deliberately,
    ///   since an established connection outranks a service's stated preference.
    static func preferConnectedOrder(
        _ uses: [(connectedFlows: UInt32, activeInstances: UInt64)]
    ) -> [Int] {
        var order = Array(uses.indices)
        guard uses.count > 1 else {
            return order
        }

        var preferredIndex: Int?
        if let mostFlows = uses.map(\.connectedFlows).max(), mostFlows > 0 {
            preferredIndex = uses.firstIndex { $0.connectedFlows == mostFlows }
        } else if let mostInstances = uses.map(\.activeInstances).max(), mostInstances > 0 {
            preferredIndex = uses.firstIndex { $0.activeInstances == mostInstances }
        }

        guard let preferredIndex, preferredIndex != 0 else {
            return order
        }
        order.insert(order.remove(at: preferredIndex), at: 0)
        return order
    }

    // MARK: Sorting within a group: interleave address families

    /// Interleaves address families so one family does not monopolize the start of the list,
    /// returning an index permutation.
    ///
    /// The input is assumed already sorted by preference. This keeps the first
    /// `preferredFamilyCount` entries of the leading family, then pulls the first entry of the
    /// *second* family up to the next slot, bounding how many of one family are tried before the
    /// other is tried at all — which is what protects against a family that is advertised but
    /// broken. Returns the order unchanged when that would be a no-op.
    ///
    /// Exactly one entry is ever moved, however many distinct families are present.
    ///
    /// - Parameter preferredFamilyCount: The spec's "Preferred Address Family Count" ("First
    ///   Address Family Count" in RFC 8305). 1 and 2 are both sanctioned; 2 is the default here.
    ///   Below 1 means 1.
    static func interleaveByFamily<Family: Equatable>(
        _ families: [Family],
        preferredFamilyCount: Int = 2
    ) -> [Int] {
        var order = Array(families.indices)
        let preferredCount = max(1, preferredFamilyCount)

        guard let firstFamily = families.first,
            let secondFamilyIndex = families.firstIndex(where: { $0 != firstFamily }),
            secondFamilyIndex > preferredCount
        else {
            return order
        }

        // Removing and reinserting the same element is what makes the result a permutation.
        order.remove(at: secondFamilyIndex)
        order.insert(secondFamilyIndex, at: preferredCount)
        return order
    }

    // MARK: Weighted selection among equal priorities

    /// Orders entries within each priority group by a weight-proportional random draw, returning
    /// an index permutation. RFC 2782.
    ///
    /// The input is assumed already grouped by priority, so each group is a maximal run of equal
    /// priority. Within a group the chance of being drawn is the entry's share of the group's
    /// total weight, favouring *larger* weights — the opposite of the ascending comparison in
    /// ``orderByServicePriority(_:priorityOrigin:)``, and the reason SRV has its own stage. A group
    /// whose weights are all `0` keeps its input order, and once only `0` weights remain they
    /// follow in input order.
    ///
    /// - Parameter randomBelow: Draws a value in `0..<upperBound`. Injected so a caller can make
    ///   the draw deterministic.
    static func orderBySRVWeight(
        _ entries: [(priority: UInt16, weight: UInt16)],
        randomBelow: (UInt32) -> UInt32
    ) -> [Int] {
        guard entries.count > 1 else {
            return Array(entries.indices)
        }

        var order: [Int] = []
        order.reserveCapacity(entries.count)
        var groupStart = entries.startIndex
        while groupStart < entries.endIndex {
            var groupEnd = groupStart
            while groupEnd < entries.endIndex,
                entries[groupEnd].priority == entries[groupStart].priority
            {
                groupEnd += 1
            }
            order += weightedDraw(
                Array(groupStart..<groupEnd),
                entries: entries,
                randomBelow: randomBelow
            )
            groupStart = groupEnd
        }
        return order
    }

    /// Repeatedly draws from `group` in proportion to each entry's weight.
    private static func weightedDraw(
        _ group: [Int],
        entries: [(priority: UInt16, weight: UInt16)],
        randomBelow: (UInt32) -> UInt32
    ) -> [Int] {
        var weightSum = group.reduce(UInt32(0)) { $0 + UInt32(entries[$1].weight) }
        guard group.count > 1, weightSum > 0 else {
            return group
        }

        var remaining = group
        var drawn: [Int] = []
        drawn.reserveCapacity(group.count)
        while !remaining.isEmpty {
            guard weightSum > 0 else {
                // Only zero weights are left; they keep their relative order.
                drawn += remaining
                break
            }
            var random = randomBelow(weightSum)
            var selected = remaining.count - 1
            for (offset, index) in remaining.enumerated() {
                let weight = UInt32(entries[index].weight)
                if random < weight {
                    selected = offset
                    break
                }
                random -= weight
            }
            let index = remaining.remove(at: selected)
            weightSum -= UInt32(entries[index].weight)
            drawn.append(index)
        }
        return drawn
    }
}

// MARK: - Endpoint adapter

@available(Network 0.1.0, *)
extension EndpointOrdering {

    /// Ranks two destinations. Substituted by a caller that can consult the routing table, the
    /// source address that would be selected, or per-destination statistics — none of which this
    /// file reaches for. See ``preferredDestination(between:and:)`` for what the default covers.
    typealias DestinationComparator = (AddressEndpoint, AddressEndpoint) -> DestinationPreference

    /// Reports how much established use an endpoint already carries, for the prefer-connected
    /// stage. Returning zeroes makes that stage a no-op.
    typealias ConnectionUseReader = (Endpoint) -> (connectedFlows: UInt32, activeInstances: UInt64)

    /// Which of two endpoints is the preferred destination. Endpoints carrying no address cannot
    /// be ranked and compare equal, which leaves them where they are in a stable sort.
    private static func endpointPreference(
        _ lhs: Endpoint,
        _ rhs: Endpoint,
        comparingDestinations compare: DestinationComparator
    ) -> DestinationPreference {
        guard case .address(let lhsAddress) = lhs.type, case .address(let rhsAddress) = rhs.type
        else {
            return .equal
        }
        return compare(lhsAddress, rhsAddress)
    }

    /// The family an endpoint takes part in when interleaving, or `nil` if it takes part in
    /// none.
    ///
    /// Interleaving hedges IPv4 against IPv6, so only those two count. An endpoint with no
    /// address has no family at all, and a Unix-domain endpoint has an address family but not an
    /// IP one — neither is something the other family can be a fallback for.
    private static func interleavingFamily(of endpoint: Endpoint) -> AddressFamily? {
        switch endpoint.addressFamily {
        case .ipv4, .ipv6: endpoint.addressFamily
        default: nil
        }
    }

    /// Orders resolved endpoints for connection attempts.
    ///
    /// Service priority is the primary key, then weight. Within one priority, addresses are
    /// ordered by destination address selection — which puts IPv6 ahead of IPv4 in the common
    /// case — and then interleaved by family. An endpoint already carrying connections is lifted
    /// to the front last of all, and an SRV list then takes a weighted draw within each priority.
    ///
    /// Deterministic unless `priorityOrigin` is ``PriorityOrigin/srv``. Randomising equal-priority
    /// service records is otherwise the caller's job: assign each record one random weight (see
    /// ``orderByServicePriority(_:priorityOrigin:)``).
    ///
    /// - Parameters:
    ///   - preferredFamilyCount: See ``interleaveByFamily(_:preferredFamilyCount:)``.
    ///   - priorityOrigin: How a priority of `0` is read, and whether the SRV weighted draw runs.
    ///   - comparingDestinations: See ``DestinationComparator``.
    ///   - readingConnectionUse: See ``ConnectionUseReader``. `nil` skips the stage.
    ///   - randomBelow: The draw used for ``PriorityOrigin/srv``; unused otherwise.
    static func orderEndpoints(
        _ endpoints: [Endpoint],
        preferredFamilyCount: Int = 2,
        priorityOrigin: PriorityOrigin = .serviceBinding,
        comparingDestinations compare: DestinationComparator = {
            preferredDestination(between: $0, and: $1)
        },
        readingConnectionUse readConnectionUse: ConnectionUseReader? = nil,
        randomBelow: (UInt32) -> UInt32 = { UInt32.random(in: 0..<$0) }
    ) -> [Endpoint] {
        guard endpoints.count > 1 else {
            return endpoints
        }

        // Destination address selection, with an index tiebreak so the sort is stable.
        let addressOrdered = endpoints.indices.sorted { lhs, rhs in
            switch endpointPreference(endpoints[lhs], endpoints[rhs], comparingDestinations: compare)
            {
            case .first: true
            case .second: false
            case .equal: lhs < rhs
            }
        }.map { endpoints[$0] }

        // Service priority and weight outrank address preference. Stable, so the ordering above
        // survives as the tiebreak within one service.
        let priorityOrder = orderByServicePriority(
            addressOrdered.map { (priority: $0.priority, weight: $0.weight) },
            priorityOrigin: priorityOrigin
        )
        let prioritized = priorityOrder.map { addressOrdered[$0] }

        // Interleave within each priority. The run key is priority alone, so two services sharing
        // a priority interleave as one block.
        var runs: [[Endpoint]] = []
        for endpoint in prioritized {
            if let pivot = runs.last?.first, pivot.priority == endpoint.priority {
                runs[runs.count - 1].append(endpoint)
            } else {
                runs.append([endpoint])
            }
        }
        var ordered = runs.flatMap { run -> [Endpoint] in
            // Interleave only the endpoints that have an IP family. Everything else holds its
            // slot — an endpoint with no address, and a Unix-domain one, which has an address
            // family but not an IP one. Addresses move only among address slots, so a held slot
            // keeps its absolute position wherever it sits in the run.
            var slots: [Int] = []
            var families: [AddressFamily] = []
            for index in run.indices {
                if let family = interleavingFamily(of: run[index]) {
                    slots.append(index)
                    families.append(family)
                }
            }

            var reordered = run
            let order = interleaveByFamily(families, preferredFamilyCount: preferredFamilyCount)
            for (slot, source) in zip(slots, order) {
                reordered[slot] = run[slots[source]]
            }
            return reordered
        }

        // Established use outranks the ordering above, so it is applied to the whole list.
        if let readConnectionUse {
            ordered = preferConnectedOrder(ordered.map(readConnectionUse)).map { ordered[$0] }
        }

        guard case .srv = priorityOrigin else {
            return ordered
        }
        return orderBySRVWeight(
            ordered.map { (priority: $0.priority, weight: $0.weight) },
            randomBelow: randomBelow
        ).map { ordered[$0] }
    }
}
