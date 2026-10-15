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

@available(Network 0.1.0, *)
public struct IPv6Address: IPAddress, Hashable, CustomDebugStringConvertible {

    /// The IPv6 "any" address.
    public static var any: IPv6Address {
        IPv6Address((0, 0, 0, 0))
    }

    /// The IPv6 broadcast address.
    public static var broadcast: IPv6Address {
        IPv6Address((0, 0, 0, 0))
    }

    /// The IPv6 loopback address.
    public static var loopback: IPv6Address {
        IPv6Address((0, 0, 0, UInt32(1).bigEndian))
    }

    /// A Boolean value that indicates whether this is the loopback address.
    ///
    /// The IPv6 loopback address is `::1`.
    public var isLoopback: Bool {
        (self == IPv6Address.loopback)
    }

    var isLinkLocal: Bool {
        var addressFirstChunk = self.address.0
        return withUnsafeBytes(of: &addressFirstChunk) {
            $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80
        }
    }

    var isSiteLocal: Bool {
        var addressFirstChunk = self.address.0
        return withUnsafeBytes(of: &addressFirstChunk) {
            $0[0] == 0xfe && ($0[1] & 0xc0) == 0xc0
        }
    }

    var isUnspecified: Bool {
        self == IPv6Address.any
    }

    var isScopeLinkLocal: Bool {
        isLinkLocal || isMulticastLinkLocal
    }

    var isMulticastLinkLocal: Bool {
        isMulticast && multicastFlags != 0x30 && multicastScope == 0x02
    }

    var isMulticastInterfaceLocal: Bool {
        isMulticast && multicastScope == 0x01
    }

    var isScopeEmbedded: Bool {
        isLinkLocal || isMulticastLinkLocal || isMulticastInterfaceLocal
    }

    var multicastScope: UInt8 {
        var addressFirstChunk = self.address.0
        return withUnsafeBytes(of: &addressFirstChunk) { $0[1] & 0xff }
    }

    var multicastFlags: UInt8 {
        var addressFirstChunk = self.address.0
        return withUnsafeBytes(of: &addressFirstChunk) { $0[1] & 0xf0 }
    }

    /// A Boolean value that indicates whether this is a multicast address.
    var isMulticast: Bool {
        var addressFirstChunk = self.address.0
        return withUnsafeBytes(of: &addressFirstChunk) { $0[0] == 0xff }
    }

    /// A Boolean value that indicates whether this is an IPv4-mapped address.
    ///
    /// For example, `::ffff:1.2.3.4`.
    public var isIPv4Mapped: Bool {
        Self.isIPv4Mapped(from: address)
    }

    /// The IPv4 address for an IPv4-mapped IPv6 address.
    ///
    /// Returns `nil` if this address isn't IPv4-mapped.
    public var asIPv4: IPv4Address? {
        guard self.isIPv4Mapped else {
            return nil
        }
        return IPv4Address(self.address.3)
    }

    // Values stored in network byte order
    internal let address: (UInt32, UInt32, UInt32, UInt32)

    internal var addressValue: (UInt32, UInt32, UInt32, UInt32) {
        address
    }

    public var rawValue: (UInt32, UInt32, UInt32, UInt32) {
        self.address
    }

    public init(_ tuple: (UInt32, UInt32, UInt32, UInt32)) {
        self.address = tuple
    }

    /// An IPv6 address as a byte array.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count == MemoryLayout<UInt32>.size * 4 else {
            return nil
        }

        var address: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        withUnsafeMutableBytes(of: &address.0) { $0.copyBytes(from: bytes[0...3]) }
        withUnsafeMutableBytes(of: &address.1) { $0.copyBytes(from: bytes[4...7]) }
        withUnsafeMutableBytes(of: &address.2) { $0.copyBytes(from: bytes[8...11]) }
        withUnsafeMutableBytes(of: &address.3) { $0.copyBytes(from: bytes[12...15]) }
        self = IPv6Address(address)
    }

    /// An IPv6 address parsed from a string (e.g. `"2001:db8::1"` or `"::1"`).
    public init?(_ string: String) {
        guard let groups = IPv6Address.parseToGroups(string) else { return nil }
        self.init(
            (
                (UInt32(groups[0]) << 16 | UInt32(groups[1])).bigEndian,
                (UInt32(groups[2]) << 16 | UInt32(groups[3])).bigEndian,
                (UInt32(groups[4]) << 16 | UInt32(groups[5])).bigEndian,
                (UInt32(groups[6]) << 16 | UInt32(groups[7])).bigEndian
            )
        )
    }

    // Parses an IPv6 address string into its 8 UInt16 groups, in address order, without allocating.
    // Handles :: compression, full notation, and a trailing dotted quad.
    private static func parseToGroups(_ addr: String) -> [8 of UInt16]? {
        var searchIndex = addr.startIndex

        // Position of '::' in the string, if present. Used to expand compressed zeros.
        var doubleColonRange: Range<String.Index>? = nil
        while searchIndex < addr.endIndex {
            let nextIndex = addr.index(after: searchIndex)
            if nextIndex < addr.endIndex && addr[searchIndex] == ":" && addr[nextIndex] == ":" {
                doubleColonRange = searchIndex..<addr.index(after: nextIndex)
                break
            }
            searchIndex = nextIndex
        }

        // Parses one side of a `::` into `groups`, returning how many groups it wrote.
        // A dotted quad is only allowed as the final component of the address, so
        // `endsAddress` is false for the half before a `::`.
        func parseHalf(_ half: Substring, endsAddress: Bool, into groups: inout [8 of UInt16]) -> Int? {
            if half.isEmpty { return 0 }
            var count = 0
            var rest = half
            while true {
                let part = rest.prefix { $0 != ":" }
                let isLast = part.endIndex == rest.endIndex
                if endsAddress, isLast, part.contains(".") {
                    guard count <= 6, let v4 = IPv4Address.parseDottedQuad(part) else { return nil }
                    groups[count] = UInt16(truncatingIfNeeded: v4 >> 16)
                    groups[count + 1] = UInt16(truncatingIfNeeded: v4)
                    count += 2
                } else {
                    guard count < 8, !part.isEmpty, part.count <= 4,
                        part.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                        let value = UInt16(part, radix: 16)
                    else { return nil }
                    groups[count] = value
                    count += 1
                }
                if isLast { return count }
                rest = rest[rest.index(after: part.endIndex)...]
            }
        }

        var left: [8 of UInt16] = .init(repeating: 0)
        if let range = doubleColonRange {
            var right: [8 of UInt16] = .init(repeating: 0)
            guard let leftCount = parseHalf(addr[..<range.lowerBound], endsAddress: false, into: &left),
                let rightCount = parseHalf(addr[range.upperBound...], endsAddress: true, into: &right)
            else { return nil }
            // `::` must stand in for at least one group.
            guard leftCount + rightCount < 8 else { return nil }
            for k in 0..<rightCount {
                left[8 - rightCount + k] = right[k]
            }
            return left
        } else {
            guard parseHalf(addr[...], endsAddress: true, into: &left) == 8 else { return nil }
            return left
        }
    }

    static func isIPv4Mapped(from address: (UInt32, UInt32, UInt32, UInt32)) -> Bool {
        address.0 == 0 && address.1 == 0 && address.2 == UInt32(0x0000_ffff).bigEndian
    }

    static func ipv6AddressString(from address: (UInt32, UInt32, UInt32, UInt32)) -> String {
        guard !isIPv4Mapped(from: address) else {
            return "::ffff:\(IPv4Address.ipv4AddressString(from: address.3))"
        }

        let byteCount = 16
        let wordSize = 2
        let wordCount = byteCount / wordSize

        // Preprocess: Convert bytewise array into wordwise array (16-bit words)
        var words = [UInt16](repeating: 0, count: byteCount / wordSize)
        withUnsafeBytes(of: address) {
            for i in 0..<byteCount {
                // Pack two bytes into each 16-bit word (big-endian)
                words[i / 2] |= UInt16($0[i]) << ((1 - (i % 2)) << 3)
            }
        }

        // Find the longest run of 0x00's for :: shorthanding
        struct Run {
            var base: Int
            var len: Int
        }

        var best = Run(base: -1, len: 0)
        var cur = Run(base: -1, len: 0)

        for i in 0..<wordCount {
            if words[i] == 0 {
                if cur.base == -1 {
                    cur.base = i
                    cur.len = 1
                } else {
                    cur.len += 1
                }
            } else {
                if cur.base != -1 {
                    if best.base == -1 || cur.len > best.len {
                        best = cur
                    }
                    cur.base = -1
                }
            }
        }

        // Check if the last run is the best
        if cur.base != -1 {
            if best.base == -1 || cur.len > best.len {
                best = cur
            }
        }

        // Only compress if we have at least 2 consecutive zeros
        if best.base != -1 && best.len < 2 {
            best.base = -1
        }

        // Format the result
        var result = ""

        for i in 0..<wordCount {
            // Are we inside the best run of 0x00's?
            if best.base != -1 && i >= best.base && i < (best.base + best.len) {
                if i == best.base {
                    result.append(":")
                }
                continue
            }

            // Are we following an initial run of 0x00s or any real hex?
            if i != 0 {
                result.append(":")
            }

            // Append the hex word (lowercase, no leading zeros)
            result.append(String(words[i], radix: 16, uppercase: false))
        }

        // Was it a trailing run of 0x00's?
        if best.base != -1 && (best.base + best.len) == wordCount {
            result.append(":")
        }

        return result
    }

    public var debugDescription: String {
        Self.ipv6AddressString(from: address)
    }

    var addressFamily: AddressFamily {
        .ipv6
    }

    static public func == (lhs: IPv6Address, rhs: IPv6Address) -> Bool {
        lhs.address == rhs.address
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.address.0)
        hasher.combine(self.address.1)
        hasher.combine(self.address.2)
        hasher.combine(self.address.3)
    }

    var interface: Interface? {
        nil
    }
}
