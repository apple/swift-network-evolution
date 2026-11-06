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

// MARK: - Portable core
//
// Pure functions over plain values returning index permutations. They name no package type and
// need no imports; keep it that way. Declared in the order the specification applies them,
// whose section numbers are omitted since they move between draft revisions.

// MARK: Grouping by application protocol and security requirements

// Not implemented: no endpoint carries ALPN values or security parameters. Its groups are
// alternatives rather than one list, so it is not a change to `orderEndpoints`.

// MARK: Grouping by service priority

/// Orders entries by service priority, then weight, returning an index permutation. Stable, so
/// equal-rank entries keep their input order.
///
/// Priority is a SVCB/HTTPS `SvcPriority` (RFC 9460), lower preferred. `0` is not a priority —
/// it means no service record, and sorts after every entry that has one.
///
/// Weight is a *synthetic* key, not a wire value: give each service record one random weight and
/// stamp it on that record's endpoints, and equal-priority records take a random relative order
/// while each record's own endpoints stay contiguous. `0` means none supplied, and a `0` never
/// participates.
///
/// - Important: Not an SRV weight. RFC 2782 wants a weight-proportional draw favouring *larger*
///   weights, so this ascending comparison is wrong on both counts — and `HostEndpoint` carries
///   the SRV shape, so such endpoints can reach here with no type error.
func orderByServicePriority(_ entries: [(priority: UInt16, weight: UInt16)]) -> [Int] {
    entries.enumerated().sorted { lhs, rhs in
        let (leftPriority, rightPriority) = (lhs.element.priority, rhs.element.priority)
        if leftPriority != rightPriority {
            // A priority of 0 is the absence of one, so it loses to any real priority.
            if leftPriority == 0 { return false }
            if rightPriority == 0 { return true }
            return leftPriority < rightPriority
        }
        let (leftWeight, rightWeight) = (lhs.element.weight, rhs.element.weight)
        if leftWeight != 0, rightWeight != 0, leftWeight != rightWeight {
            return leftWeight < rightWeight
        }
        // Equal rank: preserve the input order, since `sorted(by:)` is not stable.
        return lhs.offset < rhs.offset
    }.map(\.offset)
}

// MARK: Sorting within a group: destination address selection

// Required. Implemented in `AddressSelection.swift`; `endpointPreference` below adapts it.

// MARK: Sorting within a group: prefer lower round-trip time

// Not implemented: no per-destination timing history is collected.

// MARK: Sorting within a group: prefer previously-used addresses

// Not implemented: no record of past successes is kept.

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
/// - Parameter preferredFamilyCount: The spec's "Preferred Address Family Count" ("First
///   Address Family Count" in RFC 8305). Recommended 1; 2 is sanctioned. Below 1 means 1.
func interleaveByFamily<Family: Equatable>(
    _ families: [Family],
    preferredFamilyCount: Int = 1
) -> [Int] {
    let identity = Array(families.indices)
    let preferredCount = max(1, preferredFamilyCount)

    guard let firstFamily = families.first,
        let secondFamilyIndex = families.firstIndex(where: { $0 != firstFamily }),
        secondFamilyIndex > preferredCount
    else {
        return identity
    }

    // Removing and reinserting the same element is what makes the result a permutation.
    var order = identity
    order.remove(at: secondFamilyIndex)
    order.insert(secondFamilyIndex, at: preferredCount)
    return order
}

// MARK: - Endpoint adapter

/// Which of two endpoints is the preferred destination. Endpoints carrying no address cannot be
/// ranked and compare equal, which leaves them where they are in a stable sort.
@available(Network 0.1.0, *)
private func endpointPreference(_ lhs: Endpoint, _ rhs: Endpoint) -> DestinationPreference {
    guard case .address(let lhsAddress) = lhs.type, case .address(let rhsAddress) = rhs.type else {
        return .equal
    }
    return preferredDestination(between: lhsAddress, and: rhsAddress)
}

/// Orders resolved endpoints for connection attempts.
///
/// Service priority and weight are the primary keys. Within one service, addresses are ordered
/// by RFC 6724 destination address selection — which puts IPv6 ahead of IPv4 in the common case
/// — and then interleaved by family. Interleaving never reaches across services.
///
/// Deterministic. Randomising equal-priority services is the caller's job: assign each service
/// record one random weight (see ``orderByServicePriority(_:)``).
///
/// - Parameter preferredFamilyCount: See ``interleaveByFamily(_:preferredFamilyCount:)``.
@available(Network 0.1.0, *)
func orderEndpoints(_ endpoints: [Endpoint], preferredFamilyCount: Int = 1) -> [Endpoint] {
    guard endpoints.count > 1 else {
        return endpoints
    }

    // Destination address selection, with an index tiebreak so the sort is stable.
    let addressOrdered = endpoints.indices.sorted { lhs, rhs in
        switch endpointPreference(endpoints[lhs], endpoints[rhs]) {
        case .first: true
        case .second: false
        case .equal: lhs < rhs
        }
    }.map { endpoints[$0] }

    // Service priority and weight outrank address preference. Stable, so the ordering above
    // survives as the tiebreak within one service.
    let priorityOrder = orderByServicePriority(
        addressOrdered.map { (priority: $0.priority, weight: $0.weight) }
    )
    let prioritized = priorityOrder.map { addressOrdered[$0] }

    // Interleave within each service. The run key is priority *and* weight, so a run is one
    // service, not a whole priority level — keying on priority alone would let interleaving pull
    // one service's address into another's block.
    var runs: [[Endpoint]] = []
    for endpoint in prioritized {
        if let pivot = runs.last?.first,
            pivot.priority == endpoint.priority, pivot.weight == endpoint.weight
        {
            runs[runs.count - 1].append(endpoint)
        } else {
            runs.append([endpoint])
        }
    }
    return runs.flatMap { run -> [Endpoint] in
        // Interleave the addresses only. An endpoint carrying no address has no family, and
        // comparing families for inequality would otherwise read it as the second family and
        // promote it ahead of real addresses. Such endpoints hold their slot; the addresses are
        // permuted among the remaining ones.
        let addressSlots = run.indices.filter { run[$0].addressFamily != nil }
        let order = interleaveByFamily(
            addressSlots.compactMap { run[$0].addressFamily },
            preferredFamilyCount: preferredFamilyCount
        )
        var ordered = run
        for (slot, source) in zip(addressSlots, order) {
            ordered[slot] = run[addressSlots[source]]
        }
        return ordered
    }
}
