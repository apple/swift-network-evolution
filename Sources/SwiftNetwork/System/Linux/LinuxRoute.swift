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

#if os(Linux) && NETLINK_ENABLED

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

internal import Logging
internal import SwiftNetworkLinuxShim

/// A set of Linux system APIs for interacting with the system interface.
internal enum SystemRoute {

    enum Constants {
        static let NETLINK_ROUTE = 0x0
        static let IFADDRSIZE = MemoryLayout<ifaddrmsg>.size
        static let NETLINK_HEADERSIZE = MemoryLayout<nlmsghdr>.size
        static let ROUTE_ATTR_SIZE = MemoryLayout<rtattr>.size
        static let NETLINK_SOCK_SIZE = MemoryLayout<sockaddr_nl>.size
        static let NETLINK_ERRORSIZE = MemoryLayout<nlmsgerr>.size
        static let ROUTEMSG_SIZE = MemoryLayout<rtmsg>.size
    }

    // This is the routing table results, the helper functions provide routing information for various scenarios.
    struct RouteResult {
        var ifaddr: ifaddrmsg
        var routeAttrs: [RouteAttr]

        func isRouteLocal(addressFamily: AddressFamily) -> Bool {
            var interfaceMatch = false
            var dstAddressFound = false
            if addressFamily == .ipv4 {
                // For v4
                var localV4AddressFound = false
                for attribute in self.routeAttrs {
                    if attribute.isDestinationV4Loopback { dstAddressFound = true }
                    if attribute.isLocalV4AddressPresent { localV4AddressFound = true }
                    if attribute.interfaceMatchName(givenName: "lo") { interfaceMatch = true }
                }
                if dstAddressFound && localV4AddressFound && interfaceMatch {
                    return true
                }
            } else {
                // For v6
                for attribute in self.routeAttrs {
                    if attribute.isDestinationV6Loopback { dstAddressFound = true }
                    if attribute.interfaceMatchName(givenName: "lo") { interfaceMatch = true }
                }
                if dstAddressFound && interfaceMatch {
                    return true
                }
            }
            return false
        }

        func isRouteDestinationRoutePresent(addressFamily: AddressFamily) -> Bool {
            var interfaceMatch = false
            var dstAddressFound = false
            if addressFamily == .ipv4 {
                // For v4
                for attribute in self.routeAttrs {
                    if attribute.isDestinationV4Present { dstAddressFound = true }
                    if !attribute.interfaceMatchName(givenName: "lo") { interfaceMatch = true }
                }
            } else {
                // For v6
                for attribute in self.routeAttrs {
                    if attribute.isDestinationV6Present { dstAddressFound = true }
                    if !attribute.interfaceMatchName(givenName: "lo") { interfaceMatch = true }
                }
            }
            if dstAddressFound && interfaceMatch {
                return true
            } else {
                return false
            }
        }
    }

    enum RouteAttr {

        struct IPv4DestinationAddress {
            var addr: IPv4Address
        }

        struct IPv4LocalAddress {
            var addr: IPv4Address
        }

        struct IPv6DestinationAddress {
            var addr: IPv6Address
        }

        struct IPv6LocalAddress {
            var addr: IPv6Address
        }

        struct IPv4BroadcastAddress {
            var addr: IPv4Address
        }

        struct IPv4AnycastAddress {
            var addr: IPv4Address
        }

        struct InterfaceName {
            var name: String = ""
        }

        struct Unspecified {
            var bytes: [UInt8]
            var type: Int
        }

        case v4Dest(IPv4DestinationAddress)
        case v6Dest(IPv6DestinationAddress)
        case v4Local(IPv4LocalAddress)
        case v6Local(IPv6LocalAddress)
        case v4Broadcast(IPv4BroadcastAddress)
        case v4Anycast(IPv4AnycastAddress)
        case name(InterfaceName)
        case unspecified(Unspecified)

        init(type: Int, bytes: [UInt8], addressFamily: AddressFamily) throws {
            if type == IFA_ADDRESS {
                if addressFamily == .ipv4, let v4Addr = IPv4Address(bytes) {
                    self = .v4Dest(IPv4DestinationAddress(addr: v4Addr))
                } else if addressFamily == .ipv6, let v6Addr = IPv6Address(bytes) {
                    self = .v6Dest(IPv6DestinationAddress(addr: v6Addr))
                } else {
                    throw NetworkError.posix(EINVAL)
                }
            } else if type == IFA_LOCAL {
                if addressFamily == .ipv4, let v4Addr = IPv4Address(bytes) {
                    self = .v4Local(IPv4LocalAddress(addr: v4Addr))
                } else if addressFamily == .ipv6, let v6Addr = IPv6Address(bytes) {
                    self = .v6Local(IPv6LocalAddress(addr: v6Addr))
                } else {
                    throw NetworkError.posix(EINVAL)
                }
            } else if type == IFA_LABEL {
                // We drop the last byte here to get rid of the null terminator
                self = .name(InterfaceName(name: String(decoding: bytes.dropLast(1), as: UTF8.self)))
            } else if type == IFA_BROADCAST, let v4Addr = IPv4Address(bytes) {
                self = .v4Broadcast(IPv4BroadcastAddress(addr: v4Addr))
            } else if type == IFA_ANYCAST, let v4Addr = IPv4Address(bytes) {
                self = .v4Anycast(IPv4AnycastAddress(addr: v4Addr))
            } else {
                self = .unspecified(Unspecified(bytes: bytes, type: type))
            }
        }

        var isDestinationV4Present: Bool {
            switch self {
            case .v4Dest(let destAddr):
                return !destAddr.addr.isLoopback
            default:
                return false
            }
        }

        var isDestinationV6Present: Bool {
            switch self {
            case .v6Dest(let destAddr):
                return !destAddr.addr.isLoopback
            default:
                return false
            }
        }

        var isDestinationV4Loopback: Bool {
            switch self {
            case .v4Dest(let destAddr):
                return destAddr.addr.isLoopback
            default:
                return false
            }
        }
        var isDestinationV6Loopback: Bool {
            switch self {
            case .v6Dest(let destAddr):
                return destAddr.addr.isLoopback
            default:
                return false
            }
        }

        func interfaceMatchName(givenName: String) -> Bool {
            switch self {
            case .name(let name):
                return givenName == name.name
            default:
                return false
            }
        }

        var isLocalV4AddressPresent: Bool {
            switch self {
            case .v4Local(_):
                return true
            default:
                return false
            }
        }

        var isLocalV6AddressPresent: Bool {
            switch self {
            case .v6Local(_):
                return true
            default:
                return false
            }
        }
    }

    /// Parses routing-table attributes and appends them to an array.
    ///
    /// Parses multiple `rtattr` values from a routing-table buffer.
    /// The buffer passed in must represent only the `rtattr` data, not the rest of the buffer.
    /// See https://man7.org/linux/man-pages/man7/rtnetlink.7.html
    internal static func parseRouteAttributes(
        buffer: UnsafeBufferPointer<UInt8>,
        totalAttributeBytesSize: Int,
        addressFamily: AddressFamily
    ) throws -> [RouteAttr] {

        // This is what the route message response looks like.
        // In this function we are only parsing the bottom (n) rtattr's
        // [ nlmsghdr ]
        // [ ifaddrmsg / rtmsg ]
        // [ [ rtattr ] ] - The buffer passed in has been cut to the start of the [rtattr]

        var attributes = [RouteAttr]()
        var routeAttrOffset = 0
        let routeAttrEnd = totalAttributeBytesSize
        if routeAttrEnd > buffer.count {
            return attributes  // Short circuit if routeAttrEnd is past buffer.count
        }
        while routeAttrOffset <= routeAttrEnd {
            // If the offset plus the layout size of rtattr is larger than routeAttrEnd, break out of this loop and return.
            if (routeAttrOffset + Constants.ROUTE_ATTR_SIZE) > routeAttrEnd {
                break
            }
            // Advance the buffer to the offset and create a buffer pointer with the sizeof(rtattr)
            let rtattrBufferPointer = UnsafeRawBufferPointer(
                start: buffer.baseAddress!.advanced(by: routeAttrOffset),
                count: Constants.ROUTE_ATTR_SIZE
            )
            let attribute = rtattrBufferPointer.baseAddress!.assumingMemoryBound(to: rtattr.self)

            // The attribute length should be greater than the layout of rtattr, but it should not overrun routeAttrEnd.
            // Make sure the attribute length plus the offset does not over run routeAttrEnd.
            let attributeLength = Int(attribute.pointee.rta_len)
            guard attributeLength >= Constants.ROUTE_ATTR_SIZE && (attributeLength + routeAttrOffset) <= routeAttrEnd
            else {
                break
            }
            // Remember, the count of bytes is the remaining data after rta_type
            //struct rtattr {
            //   unsigned short rta_len;    Length of option
            //   unsigned short rta_type;   Type of option
            //   Data follows
            //};
            let countOfBytes = (attributeLength - Constants.ROUTE_ATTR_SIZE)
            guard countOfBytes > 0 else { continue }

            let dataStart = routeAttrOffset + Constants.ROUTE_ATTR_SIZE
            let dataEnd = dataStart + countOfBytes

            guard dataEnd <= buffer.count else { continue }

            let bytes = Array(buffer[dataStart..<dataEnd])
            let rttAttr = try RouteAttr(
                type: Int(attribute.pointee.rta_type),
                bytes: bytes,
                addressFamily: addressFamily
            )
            attributes.append(rttAttr)
            routeAttrOffset += attributeLength
        }
        return attributes
    }

    /// Performs a routing-table lookup.
    ///
    /// Performs the lookup using `NLM_F_REQUEST` and `RTM_GETADDR`.
    /// The query returns the entire routing table along with the `ifaddrmsg`.
    static func routeGetInterfaceIndex(dst: any IPAddress, scopedIndex: UInt32 = 0) throws -> UInt32 {

        var ifIndex: UInt32 = 0
        let bufferCount = 4096
        var buffer = [UInt8]()
        buffer.reserveCapacity(bufferCount)

        var seq: UInt32 = 1
        var isDstAddrLocal = false
        let protocolFamily = dst.addressFamily

        // Assign the scoped index if passed in and the sockaddr is v6
        if protocolFamily == .ipv6, let v6Address = dst as? IPv6Address {
            isDstAddrLocal = v6Address.isLoopback
        } else if protocolFamily == .ipv4, let v4Address = dst as? IPv4Address {
            isDstAddrLocal = v4Address.isLoopback
        } else {
            // Something went wrong with IPAddress and could not be converted to a sockaddr
            Logger.interface.error("routeGetInterfaceIndex failed to derive the address from the IPAddress")
            return ifIndex
        }
        // Connect a routing, datagram socket.
        let socket = try SystemSocket(
            protocolFamily: .route,
            sockType: .datagram,
            protocolSubType: Int32(SystemInterface.Constants.NETLINK_ROUTE),
            nonBlocking: true
        )

        // netlink socket represented as v4
        var nlAddr = sockaddr_nl()
        nlAddr.nl_family = UInt16(AF_NETLINK)
        var nlAddress = NetlinkAddress(nlAddr)
        try socket.bindSocket(address: nlAddress, bytes: Int(Constants.NETLINK_SOCK_SIZE))

        // Build the write message header:
        // [nlmsghdr]
        // [ifaddrmsg]
        var addrmsg = ifaddrmsg()
        addrmsg.ifa_family = protocolFamily.rawValue
        addrmsg.ifa_index = UInt32(scopedIndex)

        let netlinkMessageLength = UInt32(Constants.NETLINK_HEADERSIZE + Constants.IFADDRSIZE)
        var header = nlmsghdr()
        header.nlmsg_len = netlinkMessageLength
        header.nlmsg_type = UInt16(RTM_GETADDR)
        header.nlmsg_flags = UInt16(NLM_F_REQUEST) | UInt16(NLM_F_ROOT)
        header.nlmsg_seq = UInt32(seq)
        seq &+= 1
        withUnsafeBytes(
            of: &header,
            {
                buffer.append(contentsOf: $0)
            }
        )
        withUnsafeBytes(
            of: &addrmsg,
            {
                buffer.append(contentsOf: $0)
            }
        )

        let writeResult = try buffer.withUnsafeMutableBytes {
            let writeBuffer: UnsafeMutableRawPointer = $0.baseAddress!
            precondition(
                $0.count >= netlinkMessageLength,
                "Size of the buffer was not large enough to hold the netlink header"
            )
            var iov = iovec(iov_base: writeBuffer, iov_len: Int(netlinkMessageLength))
            return try withUnsafeMutableBytes(
                of: &nlAddress,
                { address in
                    try withUnsafeMutablePointer(to: &iov) { iov in
                        var message = msghdr(
                            msg_name: address.baseAddress,
                            msg_namelen: socklen_t(Constants.NETLINK_SOCK_SIZE),
                            msg_iov: iov,
                            msg_iovlen: 1,
                            msg_control: nil,
                            msg_controllen: .zero,
                            msg_flags: .zero
                        )
                        return try socket.sendmsg(msgHdr: &message, flags: 0)
                    }
                }
            )
        }
        // When thinking about the below read operations, they are often structured in format similar to this in c:
        // struct {
        //     struct nlmsghdr nlh;     // Netlink header
        //     struct rtmsg rtm;        // Payload - route message
        //     char rtattrBuffer[1024]; // Buffer for rtattr's
        // } routeRequest;

        if writeResult < 0 {
            Logger.interface.error("routeGetInterfaceIndex write message failed: \(errno)")
            return 0
        }
        // Query the routing table and parse the results.
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bufferCount) { pointer -> UInt32 in
            var routingResults = [RouteResult]()
            var readResult = 0
            var keepReading = true
            repeat {
                var iov = iovec(iov_base: UnsafeMutableRawPointer(pointer.baseAddress!), iov_len: pointer.count)
                readResult = try withUnsafeMutableBytes(
                    of: &nlAddress,
                    { address in
                        try withUnsafeMutablePointer(to: &iov) { iov in
                            var message = msghdr(
                                msg_name: address.baseAddress,
                                msg_namelen: socklen_t(Constants.NETLINK_SOCK_SIZE),
                                msg_iov: iov,
                                msg_iovlen: 1,
                                msg_control: nil,
                                msg_controllen: .zero,
                                msg_flags: .zero
                            )
                            return try withUnsafeMutablePointer(to: &message) { messageHeader in
                                try socket.recvmsg(msgHdr: messageHeader, flags: 0)
                            }
                        }
                    }
                )
                guard readResult >= Constants.NETLINK_HEADERSIZE, readResult <= bufferCount else {
                    Logger.interface.error("routeGetInterfaceIndex read message with bad size: \(errno)")
                    return 0
                }
                let readBuffer = UnsafeBufferPointer(rebasing: pointer[..<readResult])
                let count = readBuffer.count
                var remaining = readBuffer.count
                // Read the piece of the response, the nlmsghdr, the ifaddrmsg, and the list of rtattr.
                while remaining >= Constants.NETLINK_HEADERSIZE {
                    let offset = count - remaining

                    guard (offset + Constants.NETLINK_HEADERSIZE) < readResult else {
                        break
                    }
                    // Get the netlink message header to get nlmsg_type and nlmsg_len
                    let headerBufferPointer = UnsafeRawBufferPointer(
                        start: readBuffer.baseAddress!.advanced(by: offset),
                        count: Constants.NETLINK_HEADERSIZE
                    )
                    guard let header = SafeAccess.loadCStructure(buffer: headerBufferPointer, type: nlmsghdr.self)
                    else {
                        continue
                    }
                    if header.nlmsg_type == NLMSG_ERROR {
                        Logger.interface.error("routeGetInterfaceIndex read message with bad size: \(errno)")
                        keepReading = false
                        break
                    } else if header.nlmsg_type == NLMSG_DONE {
                        keepReading = false
                        break
                    }
                    defer {
                        let size = Int(header.nlmsg_len)
                        remaining -= size
                    }
                    // Make sure there is enough space to read ifaddrmsg
                    guard offset + Constants.NETLINK_HEADERSIZE + Constants.IFADDRSIZE <= readResult else {
                        continue
                    }
                    let ifaddrmsgOffset = offset + Constants.NETLINK_HEADERSIZE
                    let ifaddrBufferPointer = UnsafeRawBufferPointer(
                        start: readBuffer.baseAddress!.advanced(by: ifaddrmsgOffset),
                        count: Constants.IFADDRSIZE
                    )
                    guard let addrmsg = SafeAccess.loadCStructure(buffer: ifaddrBufferPointer, type: ifaddrmsg.self)
                    else {
                        continue
                    }
                    // Get the left over size of bytes and this is the what we need to parse the route attributes from
                    let routeAttrStartOffset = offset + Constants.NETLINK_HEADERSIZE + Constants.IFADDRSIZE
                    // This formula is equivalent to RTM_PAYLOAD(nlmsghdr) in Linux
                    let attributesSize =
                        Int(header.nlmsg_len) - (Constants.NETLINK_HEADERSIZE + Constants.ROUTEMSG_SIZE)

                    let attributeStart = routeAttrStartOffset
                    let attributeEnd = attributeStart + attributesSize
                    // Make sure there is enough space to read rtattr
                    guard attributeEnd <= readResult,
                        (routeAttrStartOffset + attributesSize) <= readResult
                    else {
                        continue
                    }
                    let attributeBuffer = UnsafeBufferPointer(rebasing: pointer[attributeStart..<attributeEnd])
                    let addressFamily = AddressFamily(value: UInt8(addrmsg.ifa_family))
                    let attributes = try self.parseRouteAttributes(
                        buffer: attributeBuffer,
                        totalAttributeBytesSize: attributesSize,
                        addressFamily: addressFamily
                    )
                    let routingResult = RouteResult(ifaddr: addrmsg, routeAttrs: attributes)
                    routingResults.append(routingResult)
                }
            } while keepReading

            // Iterate over the routing results and match address to the route index
            for routeResult in routingResults {
                // First check if scoped interface is set and match on that
                if scopedIndex == routeResult.ifaddr.ifa_index {
                    // Found index, match and return
                    return UInt32(routeResult.ifaddr.ifa_index)
                }

                if routeResult.ifaddr.ifa_family == AF_INET,
                    protocolFamily.rawValue == UInt8(AF_INET),
                    routeResult.routeAttrs.count > 0
                {

                    // Routing local
                    if isDstAddrLocal, routeResult.isRouteLocal(addressFamily: .ipv4) {
                        ifIndex = UInt32(routeResult.ifaddr.ifa_index)
                        break
                    }
                    // Network routable interface
                    else if routeResult.isRouteDestinationRoutePresent(addressFamily: .ipv4) {
                        ifIndex = UInt32(routeResult.ifaddr.ifa_index)
                        break
                    }
                    // Try v6 next
                } else if routeResult.ifaddr.ifa_family == AF_INET6,
                    protocolFamily.rawValue == UInt8(AF_INET6),
                    routeResult.routeAttrs.count > 0
                {
                    // Routing local
                    if isDstAddrLocal, routeResult.isRouteLocal(addressFamily: .ipv6) {
                        ifIndex = UInt32(routeResult.ifaddr.ifa_index)
                        break
                    }
                    // Network routable interface
                    else if routeResult.isRouteDestinationRoutePresent(addressFamily: .ipv6) {
                        ifIndex = UInt32(routeResult.ifaddr.ifa_index)
                        break
                    }
                }
            }
            return ifIndex
        }
    }
}
#elseif os(Linux) || os(Android)
internal enum SystemRoute {
    static func routeGetInterfaceIndex(dst: any IPAddress, scopedIndex: UInt32 = 0) throws -> UInt32 {
        0
    }
}
#endif
