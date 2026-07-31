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
            let (a0, a1, a2, a3) = addressValue
            let (n0, n1, n2, n3) = cidr.network
            let (m0, m1, m2, m3) = cidr.mask
            return (a0 & m0) == n0 && (a1 & m1) == n1 && (a2 & m2) == n2 && (a3 & m3) == n3
        }
        return matchesDomainPattern(debugDescription, pattern: pattern)
    }
}

@available(Network 0.1.0, *)
extension Endpoint {
    /// Returns true if this endpoint matches `pattern`. `"*"` matches all endpoints. Host endpoints
    /// are matched by hostname; address endpoints are matched by IP address or CIDR block.
    func matchesPattern(_ pattern: String) -> Bool {
        if pattern == "*" { return true }
        switch type {
        case .host(let hostEndpoint):
            return matchesDomainPattern(hostEndpoint.name, pattern: pattern)
        case .address(let addressEndpoint):
            switch addressEndpoint.type {
            case .v4(let ipv4, _): return ipv4.matches(pattern: pattern)
            case .v6(let ipv6, _): return ipv6.matches(pattern: pattern)
            default: return false
            }
        default:
            return false
        }
    }
}
