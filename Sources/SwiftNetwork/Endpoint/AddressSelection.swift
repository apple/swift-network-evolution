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

// Destination address selection, RFC 6724.
// https://www.rfc-editor.org/rfc/rfc6724
//
// Implements rules 6 (prefer higher precedence), 8 (prefer smaller scope), and 10 (leave
// the order unchanged). Rules 1 through 5, 7, and 9 each depend on knowing which source
// address would be selected for a given destination, or whether the destination is
// reachable at all. This API takes only the destinations, so those rules are not applied.
//
// A caller wanting a general-purpose destination comparator should know what that costs.
// Rule 1 in particular ranks an unreachable destination last, so on a network where one
// address family does not work, a full implementation leads with a usable address and this
// one may not.

// MARK: - Result

/// Which of two destination addresses is preferred.
enum DestinationPreference: Equatable, Sendable {
    /// The first destination is more desirable.
    case first
    /// The second destination is more desirable.
    case second
    /// Neither destination is more desirable than the other.
    case equal
}

// MARK: - Scope

/// An address scope, as used by RFC 6724 rule 8. Raw values are the RFC 4291 multicast
/// scope values, ordered so that a narrower scope compares less than a wider one.
enum RFC6724Scope: Int, Sendable {
    case interfaceLocal = 0x01
    case linkLocal = 0x02
    case siteLocal = 0x05
    case global = 0x0e
}

// MARK: - IPv4

extension IPv4Address {
    /// The RFC 6724 precedence of this address.
    ///
    /// IPv4 is treated as the IPv4-mapped IPv6 prefix `::ffff:0:0/96`.
    var rfc6724Precedence: Int { 35 }

    /// The RFC 6724 scope of this address.
    ///
    /// Loopback (`127.0.0.0/8`) and link-local (`169.254.0.0/16`) are link-local; everything
    /// else is global. Note this uses `isInLoopbackRange`, the whole `127.0.0.0/8` block, and
    /// not `isLoopback`, which is only `127.0.0.1`.
    var rfc6724Scope: RFC6724Scope {
        (isInLoopbackRange || isLinkLocal) ? .linkLocal : .global
    }
}

// MARK: - IPv6

@available(Network 0.1.0, *)
extension IPv6Address {
    /// Whether this is a Teredo address (`2001:0000::/32`).
    var isTeredo: Bool {
        var firstChunk = self.addressValue.0
        return withUnsafeBytes(of: &firstChunk) {
            $0[0] == 0x20 && $0[1] == 0x01 && $0[2] == 0x00 && $0[3] == 0x00
        }
    }

    /// Whether this is an IPv4-compatible address (`::/96`), which excludes the unspecified
    /// (`::`) and loopback (`::1`) addresses.
    var isV4Compat: Bool {
        addressValue.0 == 0 && addressValue.1 == 0 && addressValue.2 == 0
            && !isUnspecified && !isLoopback
    }

    /// Whether this is a 6bone address (`3ffe::/16`).
    var is6bone: Bool {
        var firstChunk = self.addressValue.0
        return withUnsafeBytes(of: &firstChunk) { $0[0] == 0x3f && $0[1] == 0xfe }
    }

    /// The RFC 6724 precedence of this address.
    ///
    /// The default policy table of RFC 6724, checked from the most specific prefix to the
    /// least.
    var rfc6724Precedence: Int {
        if isLoopback { return 50 }  // ::1/128
        if isIPv4Mapped { return 35 }  // ::ffff:0:0/96
        if is6to4 { return 30 }  // 2002::/16
        if isTeredo { return 5 }  // 2001::/32
        if isUniqueLocal { return 3 }  // fc00::/7
        if isV4Compat { return 1 }  // ::/96
        if isSiteLocal { return 1 }  // fec0::/10
        if is6bone { return 1 }  // 3ffe::/16
        return 40  // ::/0
    }

    /// The RFC 6724 scope of this address.
    ///
    /// The loopback address is link-local. The unspecified address, and any address whose
    /// scope is not one of the defined values, is global — neither is ambiguous.
    var rfc6724Scope: RFC6724Scope {
        if isLinkLocal || isLoopback { return .linkLocal }
        if isSiteLocal { return .siteLocal }
        guard isMulticast else { return .global }
        // A multicast address carries its scope in the low nibble of the second byte.
        return withUnsafeBytes(of: address) { RFC6724Scope(rawValue: Int($0[1] & 0x0f)) ?? .global }
    }
}

// MARK: - AddressEndpoint

@available(Network 0.1.0, *)
extension AddressEndpoint {
    /// The RFC 6724 precedence of this endpoint's address, or `0` for address families other
    /// than IPv4 and IPv6. Since every IP address has a precedence of at least 1, a `0` ranks
    /// a non-IP endpoint behind every IP one.
    var rfc6724Precedence: Int {
        switch type {
        case .v4(let address, _): address.rfc6724Precedence
        case .v6(let address, _): address.rfc6724Precedence
        default: 0
        }
    }

    /// The RFC 6724 scope of this endpoint's address as a raw value, or `0` for address
    /// families other than IPv4 and IPv6. A `0` is only ever compared against another `0`,
    /// because precedence separates non-IP endpoints from IP ones first.
    var rfc6724ScopeValue: Int {
        switch type {
        case .v4(let address, _): address.rfc6724Scope.rawValue
        case .v6(let address, _): address.rfc6724Scope.rawValue
        default: 0
        }
    }
}

// MARK: - Comparison

/// Returns which of two destination addresses RFC 6724 rules 6, 8, and 10 prefer, if
/// either.
///
/// Only the destinations are examined: no routing table is consulted and no source address
/// is selected, so the result is a pure function of the two addresses. See the file comment
/// for which rules that leaves out and why it matters.
///
/// - Parameters:
///   - lhs: The first candidate destination.
///   - rhs: The second candidate destination.
/// - Returns: `.first` if `lhs` is preferred, `.second` if `rhs` is, `.equal` if neither.
@available(Network 0.1.0, *)
func preferredDestination(
    between lhs: AddressEndpoint,
    and rhs: AddressEndpoint
) -> DestinationPreference {
    // Rule 6: prefer higher precedence.
    let lhsPrecedence = lhs.rfc6724Precedence
    let rhsPrecedence = rhs.rfc6724Precedence
    if lhsPrecedence != rhsPrecedence {
        return lhsPrecedence > rhsPrecedence ? .first : .second
    }

    // Rule 8: prefer smaller scope.
    let lhsScope = lhs.rfc6724ScopeValue
    let rhsScope = rhs.rfc6724ScopeValue
    if lhsScope != rhsScope {
        return lhsScope < rhsScope ? .first : .second
    }

    // Rule 10: otherwise, leave the order unchanged.
    return .equal
}
