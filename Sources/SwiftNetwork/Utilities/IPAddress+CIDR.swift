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

// MARK: - CIDR parsing

// Parses an IPv4 CIDR string into a masked network address and subnet mask in network byte order.
// Supports shorthand notation (e.g. "17.142/16" expands to "17.142.0.0/16").
private func parseCIDRv4(_ cidr: String) -> (network: UInt32, mask: UInt32)? {
    let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
        let prefixLen = Int(parts[1]), prefixLen >= 0, prefixLen <= 32
    else { return nil }

    // Expand shorthand notation: "17.142" -> "17.142.0.0", "10" -> "10.0.0.0"
    var addrString = String(parts[0])
    let dotCount = addrString.count(where: { $0 == "." })
    if dotCount < 3 {
        addrString += String(repeating: ".0", count: 3 - dotCount)
    }

    guard let addr = IPv4Address(addrString) else { return nil }
    let hostMask: UInt32 = prefixLen == 0 ? 0 : UInt32.max << UInt32(32 - prefixLen)  // shift by 32 is undefined
    let mask = hostMask.bigEndian
    return (network: addr.addressValue & mask, mask: mask)
}

// Parses an IPv6 CIDR string into a masked network address and subnet mask,
// each represented as four network-byte-order UInt32 chunks.
@available(Network 0.1.0, *)
private func parseCIDRv6(
    _ cidr: String
) -> (network: (UInt32, UInt32, UInt32, UInt32), mask: (UInt32, UInt32, UInt32, UInt32))? {
    let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
        let prefixLen = Int(parts[1]), prefixLen >= 0, prefixLen <= 128
    else { return nil }

    guard let addr = IPv6Address(String(parts[0])) else { return nil }
    let rawNet = addr.addressValue

    // bitsInChunk in 1..32 is safe: shift amount (32 - bitsInChunk) is in 0..31
    func chunkMask(_ bitsInChunk: Int) -> UInt32 {
        guard bitsInChunk > 0 else { return 0 }
        return (UInt32.max << UInt32(32 - bitsInChunk)).bigEndian
    }

    let mask = (
        chunkMask(min(prefixLen, 32)),
        chunkMask(min(max(prefixLen - 32, 0), 32)),
        chunkMask(min(max(prefixLen - 64, 0), 32)),
        chunkMask(min(max(prefixLen - 96, 0), 32))
    )

    let network = (
        rawNet.0 & mask.0,
        rawNet.1 & mask.1,
        rawNet.2 & mask.2,
        rawNet.3 & mask.3
    )

    return (network: network, mask: mask)
}

// MARK: - Domain pattern matching

/// Returns true if `string` matches `pattern` using right-to-left dot-segment comparison.
/// Supports exact matches, suffix matches ("example.com" matches "www.example.com"), and wildcards
/// (`*.example.com`). Both inputs are case-insensitive; trailing dots are stripped before matching.
func matchesDomainPattern(_ string: String, pattern: String) -> Bool {
    let host = (string.hasSuffix(".") ? String(string.dropLast()) : string).lowercased()
    let pat = (pattern.hasSuffix(".") ? String(pattern.dropLast()) : pattern).lowercased()
    if host == pat { return true }
    let hostNodes = host.split(separator: ".", omittingEmptySubsequences: false)
    var patNodes = pat.split(separator: ".", omittingEmptySubsequences: false)
    // A leading empty segment (from a pattern starting with ".", e.g. ".example.com")
    // is treated as a wildcard, matching like "*.example.com".
    if patNodes.first?.isEmpty == true { patNodes[0] = "*" }
    var j = hostNodes.count - 1
    var k = patNodes.count - 1
    while j >= 0 && k >= 0 {
        let pn = patNodes[k]
        let hn = hostNodes[j]
        if pn == hn {
            // A match at either boundary succeeds: a fully-consumed pattern (k == 0) is a
            // suffix match, and a fully-consumed host (j == 0) matches even when pattern
            // segments remain to the left, so "example.com" matches "www.example.com" and
            // "*.example.com" matches the bare "example.com".
            if j == 0 || k == 0 { return true }
            j -= 1
            k -= 1
        } else if pn == "*" {
            while k >= 0 {
                let nx = patNodes[k]
                if nx != "*" { break }
                k -= 1
            }
            if k < 0 { return true }
            let target = patNodes[k]
            while j >= 0 {
                if hostNodes[j] == target { break }
                j -= 1
            }
        } else {
            return false
        }
    }
    return false
}

extension IPv4Address {
    /// Returns true if this address falls within the CIDR block in `pattern`, or if its string
    /// representation matches `pattern` as a domain pattern.
    func matches(pattern: String) -> Bool {
        if let cidr = parseCIDRv4(pattern) {
            return (addressValue & cidr.mask) == cidr.network
        }
        return matchesDomainPattern(debugDescription, pattern: pattern)
    }

    /// Whether this address falls inside an already-parsed IPv4 CIDR block.
    func matchesCIDR(network: UInt32, mask: UInt32) -> Bool {
        (addressValue & mask) == network
    }
}

@available(Network 0.1.0, *)
extension IPv6Address {
    /// Returns true if the leading bytes of this address match any prefix in `prefixes`.
    func isSynthesizedNAT64(prefixes: [NAT64Prefix]) -> Bool {
        withUnsafeBytes(of: self.address) { selfBuf in
            prefixes.contains { (prefix: NAT64Prefix) in
                let len = Int(prefix.length.rawValue)
                return withUnsafeBytes(of: prefix.address.address) { prefixBuf in
                    selfBuf.prefix(len).elementsEqual(prefixBuf.prefix(len))
                }
            }
        }
    }

    /// Returns true if this address falls within the CIDR block in `pattern`, or if its string
    /// representation matches `pattern` as a domain pattern.
    func matches(pattern: String) -> Bool {
        if let cidr = parseCIDRv6(pattern) {
            return matchesCIDR(network: cidr.network, mask: cidr.mask)
        }
        return matchesDomainPattern(debugDescription, pattern: pattern)
    }

    /// Whether this address falls inside an already-parsed IPv6 CIDR block.
    func matchesCIDR(
        network: (UInt32, UInt32, UInt32, UInt32),
        mask: (UInt32, UInt32, UInt32, UInt32)
    ) -> Bool {
        let (a0, a1, a2, a3) = addressValue
        let (n0, n1, n2, n3) = network
        let (m0, m1, m2, m3) = mask
        return (a0 & m0) == n0 && (a1 & m1) == n1 && (a2 & m2) == n2 && (a3 & m3) == n3
    }
}

// MARK: - Endpoint pattern matching

/// How a proxy-exception pattern should be interpreted, decided by the pattern's own shape.
/// Patterns are tried in this order: wildcard, address literal, CIDR, domain.
@available(Network 0.1.0, *)
private enum ProxyPatternKind {
    case wildcard
    case v4Literal(IPv4Address)
    case v6Literal(IPv6Address)
    case v4CIDR(network: UInt32, mask: UInt32)
    case v6CIDR(network: (UInt32, UInt32, UInt32, UInt32), mask: (UInt32, UInt32, UInt32, UInt32))
    case domain

    init(_ pattern: String) {
        if pattern == "*" {
            self = .wildcard
        } else if let v4 = IPv4Address(pattern) {
            self = .v4Literal(v4)
        } else if let v6 = IPv6Address(pattern) {
            self = .v6Literal(v6)
        } else if let cidr = parseCIDRv4(pattern) {
            self = .v4CIDR(network: cidr.network, mask: cidr.mask)
        } else if let cidr = parseCIDRv6(pattern) {
            self = .v6CIDR(network: cidr.network, mask: cidr.mask)
        } else {
            self = .domain
        }
    }
}

@available(Network 0.1.0, *)
extension Endpoint {
    /// Returns true if this endpoint matches `pattern`. The pattern's form decides how they're compared.
    ///
    /// - Address and CIDR patterns only match address endpoints, so `"1.2.3.4"` doesn't match a
    ///   host named `1.2.3.4`.
    /// - Addresses are compared by value, so different spellings of the same IPv6 address match.
    /// - Wildcard text matching applies to IPv4 addresses only, so `"2001:db8:*"` matches nothing.
    func matchesPattern(_ pattern: String) -> Bool {
        // Only host and address endpoints can match, and that's checked before the pattern,
        // so even "*" does not match a bonjour, URL, or service endpoint.
        let addressEndpoint: AddressEndpoint?
        switch type {
        case .address(let endpoint):
            addressEndpoint = endpoint
        case .host:
            addressEndpoint = nil
        default:
            return false
        }

        switch ProxyPatternKind(pattern) {
        case .wildcard:
            return true

        case .v4Literal(let patternAddress):
            guard let addressEndpoint, case .v4(let ipv4, _) = addressEndpoint.type else { return false }
            return ipv4.addressValue == patternAddress.addressValue

        case .v6Literal(let patternAddress):
            guard let addressEndpoint, case .v6(let ipv6, _) = addressEndpoint.type else { return false }
            // The scope must match too, and a bare literal carries no scope.
            return ipv6.addressValue == patternAddress.addressValue && addressEndpoint.scope == 0

        case .v4CIDR(let network, let mask):
            guard let addressEndpoint, case .v4(let ipv4, _) = addressEndpoint.type else { return false }
            return ipv4.matchesCIDR(network: network, mask: mask)

        case .v6CIDR(let network, let mask):
            guard let addressEndpoint, case .v6(let ipv6, _) = addressEndpoint.type else { return false }
            return ipv6.matchesCIDR(network: network, mask: mask)

        case .domain:
            if case .host(let hostEndpoint) = type {
                return matchesDomainPattern(hostEndpoint.name, pattern: pattern)
            }
            guard let addressEndpoint else { return false }
            #if NETWORK_PRIVATE
            // An address resolved from a hostname carries that name as its policy domain, and
            // domain patterns match against it.
            if let policyDomain = domainForPolicy,
                matchesDomainPattern(policyDomain, pattern: pattern)
            {
                return true
            }
            #endif
            // IPv4 only, so that wildcard forms like "17.42.*.10" still work.
            if case .v4(let ipv4, _) = addressEndpoint.type {
                return matchesDomainPattern(ipv4.debugDescription, pattern: pattern)
            }
            return false
        }
    }
}
