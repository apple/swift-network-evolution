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

#if os(Linux) || os(Android)
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
internal import Logging
internal import SwiftNetworkLinuxShim

/// A set of Linux system APIs for interacting with the system interface.
internal enum SystemInterface {

    enum Constants {
        // Hexadecimal Constants
        static let SIOCGIFMTU = 0x8921
        static let SIOCGIFFLAGS = 0x8913
        static let IFF_MULTICAST = 0x1000
        static let IFF_LOOPBACK = 0x0008
        static let IFF_RUNNING = 0x0040
        static let IFF_BROADCAST = 0x0002
        static let IFF_UP = 0x0001
        static let SIOCGIWNAME = 0x8B01 /* SIOCGIWNAME is used to verify the presence of Wireless Extensions. */
        static let SIOCGIFHWADDR = 0x8927
        static let ARPHRD_ETHER = 0x0001 /* if_arp.h (linux kernel) */
        static let ARPHRD_IEEE80211 = 0x0321 /* if_arp.h (linux kernel) */
        static let SIOCGIFBRDADDR = 0x8919 /* sockios.h */
        static let SIOCGIFNETMASK = 0x8919 /* sockios.h */
        static let NETLINK_ROUTE = 0x0

        // Decimal Constants
        static let IFNAMSIZ = 16
    }

    @inline(never)
    static func if_indextoname(
        _ index: CInt,
        _ name: UnsafeMutablePointer<CChar>?
    ) throws -> UnsafeMutablePointer<CChar>? {
        try System.syscallOptional {
            sysIfIndexToName(index, name!)
        }
    }

    @inline(never)
    internal static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        try System.syscall(blocking: false) {
            sysIfNameToIndex(name!)
        }.result
    }

    /// Gets the MTU from the interface.
    ///
    /// Uses `ioctl` to fetch the value.
    static func interfaceGetMTU(socket: Int32, name: String) throws -> Int {
        if name.isEmpty {
            return 65535
        }
        var ifr = ifreq()
        return try name.withCString { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: name.count + 1)
            withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { dstPtr in
                dstPtr.copyMemory(from: bytes)
            }
            try System.ioctl(fd: socket, request: CUnsignedLong(Constants.SIOCGIFMTU), ptr: &ifr)
            return Int(ifr.ifr_ifru.ifru_mtu)
        }
    }

    /// Returns a Boolean value that indicates whether an interface has a specific flag.
    ///
    /// For example, `UP`, `RUNNING`, `BROADCAST`, or `MULTICAST`.
    static func interfaceHasFlag(socket: Int32, name: String, flag: Interface.Details.Flags) throws -> Bool {
        if name.isEmpty {
            return false
        }
        var comparisonFlag: UInt16 = 0
        if flag == .supportsMulticast {
            comparisonFlag = UInt16(Constants.IFF_MULTICAST)
        } else if flag == .hasBroadcast {
            comparisonFlag = UInt16(Constants.IFF_BROADCAST)
        } else {
            return false
        }
        var ifr = ifreq()
        return try name.withCString { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: name.count + 1)
            withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { dstPtr in
                dstPtr.copyMemory(from: bytes)
            }
            try System.ioctl(fd: socket, request: CUnsignedLong(Constants.SIOCGIFFLAGS), ptr: &ifr)
            if (UInt32(ifr.ifr_ifru.ifru_flags) & UInt32(comparisonFlag)) != 0 {
                return true
            }
            return false
        }
    }

    /// Returns a Boolean value that indicates whether an interface is loopback.
    static func interfaceIsLoopback(socket: Int32, name: String) throws -> Bool {
        if name.isEmpty {
            return false
        }
        var ifr = ifreq()
        return try name.withCString { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: name.count + 1)
            withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { dstPtr in
                dstPtr.copyMemory(from: bytes)
            }
            try System.ioctl(fd: socket, request: CUnsignedLong(Constants.SIOCGIFFLAGS), ptr: &ifr)
            if (UInt32(ifr.ifr_ifru.ifru_flags) & UInt32(Constants.IFF_LOOPBACK)) != 0 {
                return true
            }
            return false
        }
    }

    /// Returns a Boolean value that indicates whether this is a wireless interface.
    static func interfaceHasWireless(socket: Int32, name: String) throws -> Bool {
        if name.isEmpty {
            return false
        }
        // struct iwreq pwrq; Could be iwreq used here instead of ifreq
        var ifr = ifreq()
        return try name.withCString { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: name.count + 1)
            withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { dstPtr in
                dstPtr.copyMemory(from: bytes)
            }
            try System.ioctl(fd: socket, request: CUnsignedLong(Constants.SIOCGIFHWADDR), ptr: &ifr)
            if ifr.ifr_ifru.ifru_hwaddr.sa_family == CUnsignedLong(Constants.ARPHRD_IEEE80211) {
                return true
            }
            return false
        }
    }

    /// Returns a Boolean value that indicates whether this is an Ethernet interface.
    static func interfaceHasEthernet(socket: Int32, name: String) throws -> Bool {
        if name.isEmpty {
            return false
        }
        var ifr = ifreq()
        return try name.withCString { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: name.count + 1)
            withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { dstPtr in
                dstPtr.copyMemory(from: bytes)
            }
            try System.ioctl(fd: socket, request: CUnsignedLong(Constants.SIOCGIFHWADDR), ptr: &ifr)
            if ifr.ifr_ifru.ifru_hwaddr.sa_family == CUnsignedLong(Constants.ARPHRD_ETHER) {
                return true
            }
            return false
        }
    }

    /// Returns all of the interface flags for the specified interface.
    static func interfaceGetInterfaceFlags(socket: Int32, name: String) throws -> UInt32 {
        if name.isEmpty {
            return 0
        }
        var ifr = ifreq()
        return try name.withCString { ptr in
            let bytes = UnsafeRawBufferPointer(start: ptr, count: name.count + 1)
            withUnsafeMutableBytes(of: &ifr.ifr_ifrn.ifrn_name) { dstPtr in
                dstPtr.copyMemory(from: bytes)
            }
            try System.ioctl(fd: socket, request: CUnsignedLong(Constants.SIOCGIFFLAGS), ptr: &ifr)
            return UInt32(ifr.ifr_ifru.ifru_flags)
        }
    }

    /// Returns the interface type for the specified interface.
    static func interfaceGetInterfaceType(socket: Int32, name: String) throws -> InterfaceType {
        var interfaceType = InterfaceType.other
        // Check for loopback, wireless, and wired.
        if try SystemInterface.interfaceIsLoopback(socket: socket, name: name) {
            interfaceType = .loopback
        } else if try SystemInterface.interfaceHasEthernet(socket: socket, name: name) {
            interfaceType = .wiredEthernet
        } else if try SystemInterface.interfaceHasWireless(socket: socket, name: name) {
            interfaceType = .wifi
        }
        return interfaceType
    }

    static func interfaceGetInterfaceSubType(interfaceType: InterfaceType) -> InterfaceSubtype {
        switch interfaceType {
        case .wifi: return .wifiInfrastructure
        default: return .other
        }
    }

    /// Returns the name of the interface by index.
    static func interfaceGetNameFromIndex(index: UInt32) throws -> String? {
        // NOTE: on Linux calling if_indextoname with an index of 0 will return NULL, which is fine
        // but will set the errno to 6 - abort, which we do not want, so we guard for this here.
        guard index > 0 else {
            Logger.system.error("interfaceGetNameFromIndex cannot be called with index of 0")
            throw NetworkError.posix(EIO)
        }
        let size = Int(Constants.IFNAMSIZ)
        return try withUnsafeTemporaryAllocation(of: CChar.self, capacity: size) { buffer in
            guard let bufferAddress = buffer.baseAddress else {
                let error = errno
                Logger.system.error("if_indextoname failed for interface index \(index): \(error)")
                throw NetworkError.posix(error)
            }
            guard let nameBuffer = try SystemInterface.if_indextoname(CInt(index), bufferAddress) else {
                let error = errno
                Logger.system.error("if_indextoname failed for interface index \(index): \(error)")
                throw NetworkError.posix(error)
            }
            return String(cString: nameBuffer)
        }
    }
}
#endif
