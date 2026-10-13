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

#if canImport(Glibc)
import Glibc
internal import Logging
internal import SwiftNetworkLinuxShim
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
internal import SwiftNetworkLinuxShim
#elseif canImport(os)
internal import os
#endif

// NetlinkAddress represents sockaddr_nl on Linux
struct NetlinkAddress: IPAddress, Hashable, CustomDebugStringConvertible {

    /// A Boolean value that indicates whether this address is a loopback address.
    var isLoopback: Bool { false }

    /// A Boolean value that indicates whether this address is a multicast address.
    var isMulticast: Bool {
        // TODO: Extend using nl_groups
        false
    }

    /// Creates a Netlink address from raw bytes.
    init?(_ bytes: [UInt8]) {
        if bytes.count >= NetlinkAddress.layoutSize {
            #if os(Linux) && NETLINK_ENABLED
            let nl = bytes.withUnsafeBytes { $0.load(as: sockaddr_nl.self) }
            self.init(nl)
            #else
            let sock = bytes.withUnsafeBytes { $0.load(as: sockaddr.self) }
            self.init(sock)
            #endif
        } else {
            return nil
        }
    }

    #if os(Linux) && NETLINK_ENABLED
    // Linux has a specific type: sockaddr_nl
    init(_ sockaddr_nl: sockaddr_nl) {
        self.address = sockaddr_nl
    }
    #else
    // rtsock on Darwin uses sockaddr
    // struct sockaddr route_dst = { .sa_len = 2, .sa_family = PF_ROUTE, .sa_data = { 0, } };
    init(_ sockaddr: sockaddr) {
        self.address = sockaddr
    }
    #endif

    public var addressFamily: AddressFamily {
        .route
    }

    public var debugDescription: String {
        "NetlinkAddress"
    }

    #if os(Linux) && NETLINK_ENABLED
    var address: sockaddr_nl
    var nl_pid: pid_t = 0
    #else
    var address: sockaddr
    #endif

    #if os(Linux) && NETLINK_ENABLED
    private static let layoutSize = MemoryLayout<sockaddr_nl>.size
    #else
    private static let layoutSize = MemoryLayout<sockaddr>.size
    #endif

    public static func == (lhs: NetlinkAddress, rhs: NetlinkAddress) -> Bool {
        var l = lhs
        var r = rhs
        return memcmp(&l, &r, MemoryLayout.size(ofValue: l)) == 0
    }

    public func hash(into hasher: inout Hasher) {
        withUnsafeBytes(of: self.address) {
            hasher.combine(bytes: $0)
        }
    }

}
