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

/// The six prefix lengths defined by RFC 6052 for embedding IPv4 addresses into IPv6.
///
/// Raw values represent the prefix length in **bytes** (not bits). Use `bitLength`
/// to get the length in bits.
@available(Network 0.1.0, *)
public enum NAT64PrefixLength: UInt8, Sendable {
    case prefixLength32 = 4
    case prefixLength40 = 5
    case prefixLength48 = 6
    case prefixLength56 = 7
    case prefixLength64 = 8
    case prefixLength96 = 12

    var bitLength: Int { Int(rawValue) * 8 }

    // Byte positions in a 16-byte IPv6 buffer where each of the 4 IPv4 bytes is placed.
    // Byte 8 is always skipped (reserved per RFC 6052 §2.2).
    var ipv4ByteOffsets: [4 of Int] {
        switch self {
        case .prefixLength32: return [4, 5, 6, 7]
        case .prefixLength40: return [5, 6, 7, 9]
        case .prefixLength48: return [6, 7, 9, 10]
        case .prefixLength56: return [7, 9, 10, 11]
        case .prefixLength64: return [9, 10, 11, 12]
        case .prefixLength96: return [12, 13, 14, 15]
        }
    }
}

/// A NAT64 prefix — a base IPv6 address and length that defines the block of IPv6 address
/// space used to represent IPv4 destinations on a NAT64 network.
///
/// Trailing bytes past `length` are always zeroed so that two prefixes with the same
/// significant bits compare equal regardless of what was in the trailing positions.
@available(Network 0.1.0, *)
@_spi(Essentials)
public struct NAT64Prefix: Hashable, CustomDebugStringConvertible, Sendable {
    /// The prefix length, indicating how many leading bytes of `address` are significant.
    public let length: NAT64PrefixLength

    /// The base IPv6 address of the prefix. Bytes past `length` are always zero.
    public let address: IPv6Address

    /// The IANA well-known NAT64 prefix (`64:ff9b::/96`) defined in RFC 6052 §2.1.
    public static let wellKnownPrefix = NAT64Prefix(
        length: .prefixLength96,
        address: IPv6Address((UInt32(0x0064_ff9b).bigEndian, 0, 0, 0))
    )

    /// Creates a NAT64 prefix with the given length and base address.
    ///
    /// Bytes in `address` past `length` are zeroed so that equality and hashing
    /// consider only the significant prefix bytes.
    public init(length: NAT64PrefixLength, address: IPv6Address) {
        self.length = length
        var bytes: [16 of UInt8] = .init(repeating: 0)
        withUnsafeBytes(of: address.address) { src in
            withUnsafeMutableBytes(of: &bytes) { dst in
                dst.copyBytes(from: src.prefix(Int(length.rawValue)))
            }
        }
        self.address = withUnsafeBytes(of: &bytes) {
            IPv6Address($0.loadUnaligned(as: (UInt32, UInt32, UInt32, UInt32).self))
        }
    }

    public var debugDescription: String {
        "\(address.debugDescription)/\(length.bitLength)"
    }
}

extension IPv4Address {

    var canBeSynthesizedNAT64: Bool {
        if isZeroNet { return false }  // 0.0.0.0/8        source hosts on local network
        if isInLoopbackRange { return false }  // 127.0.0.0/8      loopback
        if isLinkLocal { return false }  // 169.254.0.0/16   link local
        if isDSLite { return false }  // 192.0.0.0/29     DS-Lite
        if is6to4RelayAnycast { return false }  // 192.88.99.0/24   6to4 relay anycast
        if isMulticast { return false }  // 224.0.0.0/4      multicast
        if isBroadcast { return false }  // 255.255.255.255  limited broadcast
        return true
    }

    var isBlocklistedForWellKnownNAT64Prefix: Bool {
        isPrivateUse || isSharedAddressSpace
    }
}

@available(Network 0.1.0, *)
extension IPv6Address {
    // Byte 8 of the synthesized address is always zero (the "u" octet, reserved per RFC 6052 §2.2).
    static func synthesized(from ipv4: IPv4Address, prefix: NAT64Prefix) -> IPv6Address? {
        guard ipv4.canBeSynthesizedNAT64 else { return nil }
        if prefix == .wellKnownPrefix && ipv4.isBlocklistedForWellKnownNAT64Prefix { return nil }

        var v6: [16 of UInt8] = .init(repeating: 0)
        let offsets = prefix.length.ipv4ByteOffsets
        withUnsafeBytes(of: ipv4.address) { v4 in
            withUnsafeMutableBytes(of: &v6) { dst in
                dst[offsets[0]] = v4[0]
                dst[offsets[1]] = v4[1]
                dst[offsets[2]] = v4[2]
                dst[offsets[3]] = v4[3]
                // Prefix bytes overwrite v6[0..<length]; ipv4ByteOffsets always places IPv4 bytes
                // at positions >= length, so the prefix copy never overwrites an IPv4 byte.
                withUnsafeBytes(of: prefix.address.address) { src in
                    dst.copyBytes(from: src.prefix(Int(prefix.length.rawValue)))
                }
            }
        }
        return withUnsafeBytes(of: &v6) {
            IPv6Address($0.loadUnaligned(as: (UInt32, UInt32, UInt32, UInt32).self))
        }
    }

    func extractedIPv4(using prefix: NAT64Prefix) -> IPv4Address? {
        // Byte 8 is intentionally not validated - extraction is a mechanical inverse
        // of synthesized(from:prefix:) and does not enforce RFC 6052 invariants on input.
        let byteCount = Int(prefix.length.rawValue)
        let prefixMatches = withUnsafeBytes(of: self.address) { v6 in
            withUnsafeBytes(of: prefix.address.address) { p in
                v6.prefix(byteCount).elementsEqual(p.prefix(byteCount))
            }
        }
        guard prefixMatches else { return nil }
        let offsets = prefix.length.ipv4ByteOffsets
        var v4: [4 of UInt8] = .init(repeating: 0)
        withUnsafeBytes(of: self.address) { v6 in
            withUnsafeMutableBytes(of: &v4) { dst in
                dst[0] = v6[offsets[0]]
                dst[1] = v6[offsets[1]]
                dst[2] = v6[offsets[2]]
                dst[3] = v6[offsets[3]]
            }
        }
        return withUnsafeBytes(of: &v4) {
            IPv4Address($0.loadUnaligned(as: UInt32.self))
        }
    }
}
