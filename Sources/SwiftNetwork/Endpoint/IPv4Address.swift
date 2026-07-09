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

public struct IPv4Address: IPAddress, Hashable, CustomDebugStringConvertible {

    /// The IPv4 "any" address used for listening.
    public static var any: IPv4Address {
        IPv4Address(UInt32(0x0000_0000).bigEndian)
    }

    /// The IPv4 broadcast address used to broadcast to all hosts.
    public static var broadcast: IPv4Address {
        IPv4Address(UInt32(0xffff_ffff).bigEndian)
    }

    /// The IPv4 loopback address.
    public static var loopback: IPv4Address {
        IPv4Address(UInt32(0x7f00_0001).bigEndian)
    }

    /// A Boolean value that indicates whether this IPv4 address is the loopback address (127.0.0.1).
    public var isLoopback: Bool {
        self == IPv4Address.loopback
    }

    /// A Boolean value that indicates whether this IPv4 address is a multicast address.
    public var isMulticast: Bool {
        let v4WireAddress = self.address
        let mask = (0xF000_0000 as UInt32).bigEndian
        let subnet = (0xE000_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet
    }

    public var isLinkLocal: Bool {
        let v4WireAddress = self.address
        let mask = (0xFFFF_0000 as UInt32).bigEndian
        let subnet = (0xA9FE_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet
    }

    public var isLocalGroup: Bool {
        let v4WireAddress = self.address
        let mask = (0xFFFF_FF00 as UInt32).bigEndian
        let subnet = (0xE000_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet
    }

    public var isZeroNet: Bool {
        let v4WireAddress = self.address
        let mask = (0xFF00_0000 as UInt32).bigEndian
        let subnet = (0x0000_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet
    }

    var isInLoopbackRange: Bool {
        let v4WireAddress = self.address
        let mask = (0xFF00_0000 as UInt32).bigEndian
        let subnet = (0x7F00_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet  // 127.0.0.0/8
    }

    var isDSLite: Bool {
        let v4WireAddress = self.address
        let mask = (0xFFFF_FFF8 as UInt32).bigEndian
        let subnet = (0xC000_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet  // 192.0.0.0/29
    }

    var is6to4RelayAnycast: Bool {
        let v4WireAddress = self.address
        let mask = (0xFFFF_FF00 as UInt32).bigEndian
        let subnet = (0xC058_6300 as UInt32).bigEndian
        return v4WireAddress & mask == subnet  // 192.88.99.0/24
    }

    var isPrivateUse: Bool {
        let v4WireAddress = self.address
        let mask8 = (0xFF00_0000 as UInt32).bigEndian
        let mask12 = (0xFFF0_0000 as UInt32).bigEndian
        let mask16 = (0xFFFF_0000 as UInt32).bigEndian
        return v4WireAddress & mask8 == (0x0A00_0000 as UInt32).bigEndian  // 10.0.0.0/8
            || v4WireAddress & mask12 == (0xAC10_0000 as UInt32).bigEndian  // 172.16.0.0/12
            || v4WireAddress & mask16 == (0xC0A8_0000 as UInt32).bigEndian  // 192.168.0.0/16
    }

    var isSharedAddressSpace: Bool {
        let v4WireAddress = self.address
        let mask = (0xFFC0_0000 as UInt32).bigEndian
        let subnet = (0x6440_0000 as UInt32).bigEndian
        return v4WireAddress & mask == subnet  // 100.64.0.0/10
    }

    var isBroadcast: Bool {
        self == .broadcast  // 255.255.255.255
    }

    // Stored in network byte order
    let address: UInt32

    internal var addressValue: UInt32 {
        address
    }

    var rawValue: UInt32 {
        self.address
    }

    public init(_ rawValue: UInt32) {
        self.address = rawValue
    }

    /// An IPv4 address as a byte array.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count == MemoryLayout<UInt32>.size else {
            return nil
        }
        var address: UInt32 = 0
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        self = IPv4Address(address)
    }

    static func ipv4AddressString(from address: UInt32) -> String {
        withUnsafeBytes(of: address) {
            "\($0[0]).\($0[1]).\($0[2]).\($0[3])"
        }
    }

    public var debugDescription: String {
        Self.ipv4AddressString(from: address)
    }

    var addressFamily: AddressFamily {
        .ipv4
    }

    static public func == (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        if lhs.rawValue == rhs.rawValue {
            return true
        }
        return false
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.address)
    }
}
