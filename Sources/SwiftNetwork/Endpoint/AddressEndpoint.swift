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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct AddressEndpoint: Sendable, EndpointProtocol, EndpointCommonProtocol {
    public var common: EndpointCommon
    public enum AddressEndpointType: Sendable, Equatable {
        case v4(IPv4Address, UInt16)
        case v6(IPv6Address, UInt16)
        case unix(String)
        #if NETWORK_PRIVATE
        case vm(VSOCKAddress)
        #endif
        case unspec

        #if NETWORK_EMBEDDED
        public static func == (lhs: AddressEndpointType, rhs: AddressEndpointType) -> Bool {
            switch (lhs, rhs) {
            case (.v4(let lAddress, let lPort), .v4(let rAddress, let rPort)):
                return lAddress == rAddress && lPort == rPort
            case (.v6(let lAddress, let lPort), .v6(let rAddress, let rPort)):
                return lAddress == rAddress && lPort == rPort
            case (.unix, .unix):
                // String comparison here fails to link on embedded
                return false
            case (.unspec, .unspec): return true
            default: return false
            }
        }
        #endif  // NETWORK_EMBEDDED
    }
    public var type: AddressEndpointType
    public var priority: UInt16 = 0
    public var weight: UInt16 = 0
    public var ethernetAddress: EthernetAddress?
    var originalFd: Int32? = nil
    var scope: UInt32 = 0

    // MARK: -- Initializers --

    public init() {
        self.common = EndpointCommon()
        self.type = .unspec
    }

    init(address: IPv4Address, port: UInt16, interface: Interface? = nil, ethernetAddress: EthernetAddress? = nil) {
        self.common = EndpointCommon()
        self.type = .v4(address, port)
        self.interface = interface
        self.ethernetAddress = ethernetAddress
    }

    init(address: IPv6Address, port: UInt16, interface: Interface? = nil, ethernetAddress: EthernetAddress? = nil) {
        self.common = EndpointCommon()
        if address.isIPv4Mapped, let v4Address = address.asIPv4 {
            self.type = .v4(v4Address, port)
        } else {
            self.type = .v6(address, port)
        }

        if let interface {
            self.interface = interface
        } else if let addressInterface = address.interface,
            let interface = try? Interface(index: addressInterface.index)
        {
            self.interface = interface
        }

        self.ethernetAddress = ethernetAddress
    }

    init?(_ path: String) {
        self.common = EndpointCommon()
        #if !NETWORK_STANDALONE
        let max = MemoryLayout<sockaddr_un>.size - (MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0)
        #else
        let max = 104  // This is sun_path[104]
        #endif
        if max < path.count {
            Logger.endpoint.fault("Path \(path) is too large for a unix domain address")
            return nil
        }
        self.type = .unix(path)
        self.interface = nil
    }

    var addressFamily: AddressFamily? {
        switch type {
        case .v4: return .ipv4
        case .v6: return .ipv6
        case .unix: return .unix
        default: return nil
        }
    }

    // MARK: -- Serialization --

    func serialize() -> [UInt8]? {
        switch type {
        case .v4(let address, let port):
            return Serializer.serialize { write in
                write.uint8(16)
                write.uint8(AddressFamily.ipv4.rawValue)
                write.uint16NetworkByteOrder(port)
                write.uint32(address.addressValue)
                write.uint64(0)
            }
        case .v6(let address, let port):
            return Serializer.serialize { write in
                write.uint8(28)
                write.uint8(AddressFamily.ipv6.rawValue)
                write.uint16NetworkByteOrder(port)
                write.uint32(0)
                write.uint32(address.addressValue.0)
                write.uint32(address.addressValue.1)
                write.uint32(address.addressValue.2)
                write.uint32(address.addressValue.3)
                write.uint32(scope)
            }
        case .unix(let path):
            let pathLength = path.utf8.count
            return Serializer.serialize { write in
                write.uint8(UInt8(pathLength + 2))
                write.uint8(AddressFamily.unix.rawValue)
                write.fixedLengthUTF8(path, byteCount: pathLength)
            }
        default: return nil
        }
    }

    // MARK: -- Comparisons --

    public static func == (lhs: AddressEndpoint, rhs: AddressEndpoint) -> Bool {
        lhs.isEqual(to: rhs)
    }

    func isEqual(to other: AddressEndpoint, flags: EndpointEqualityFlags = .empty) -> Bool {
        if !common.isEqual(to: other.common, flags: flags) {
            return false
        }
        if self.type != other.type {
            return false
        }
        if self.originalFd != other.originalFd {
            // If the original fd was saved (as it is for UNIX domain sockets) to differentiate
            // endpoints, use this to validate equality
            return false
        }
        return true
    }

    // MARK: -- Description --

    #if !NETWORK_PRIVATE
    public var description: String {
        switch self.type {
        case .v4(let address, let port):
            return "\(address.debugDescription):\(port)"
        case .v6(let address, let port):
            return "\(address.debugDescription).\(port)"
        case .unix(let path):
            return "AF_UNIX:\"\(path)\""
        case .unspec:
            return "AF_UNSPEC"
        }
    }

    var redactedDescription: String {
        switch self.type {
        case .v4(let address, let port):
            return "IPv4#\(redactedHash(address.debugDescription)):\(port)"
        case .v6(let address, let port):
            return "IPv6#\(redactedHash(address.debugDescription)).\(port)"
        case .unix(let path):
            return "AF_UNIX:sockaddr#\"\(redactedHash(path))\""
        case .unspec:
            return "AF_UNSPEC"
        }
    }
    #endif

    // MARK: -- Computed Properties --

    var port: UInt16 {
        switch self.type {
        case .v4(_, let port):
            return port
        case .v6(_, let port):
            return port
        case .unix(_):
            return 0
        #if NETWORK_PRIVATE
        case .vm(_):
            return 0
        #endif
        case .unspec:
            return 0
        }
    }

    var hostname: String? {
        // TODO: Add more support for IPv4Address/IPv6Address descriptions in SwiftNetwork
        switch self.type {
        case .v4(let v4, _):
            return v4.debugDescription
        case .v6(let v6, _):
            return v6.debugDescription
        case .unix(_):
            return nil
        #if NETWORK_PRIVATE
        case .vm(_):
            return nil
        #endif
        case .unspec:
            return nil
        }
    }

    var isBroadcast: Bool {
        switch self.type {
        case .v4(let address, _):
            return address == IPv4Address.broadcast
        case .v6(let address, _):
            return address == IPv6Address.broadcast
        case .unix(_):
            return false
        #if NETWORK_PRIVATE
        case .vm(_):
            return false
        #endif
        case .unspec:
            return false
        }
    }

    var isMulticast: Bool {
        switch self.type {
        case .v4(let address, _):
            return address.isMulticast
        case .v6(let address, _):
            return address.isMulticast
        case .unix(_):
            return false
        #if NETWORK_PRIVATE
        case .vm(_):
            return false
        #endif
        case .unspec:
            return false
        }
    }

    // MARK: -- Internal --

    func matchesAddress(
        address rhsAddress: IPv4Address,
        port rhsPort: UInt16,
        interfaceIndex: Int32,
        matchInterface: Bool
    ) -> Bool {
        switch self.type {
        case .v4(let address, let port):
            if address != rhsAddress {
                return false
            }
            if port != rhsPort {
                return false
            }
            if !matchInterface {
                return true
            }
            guard let interface else {
                return false
            }
            return interface.index == interfaceIndex
        default:
            return false
        }
    }

    func matchesAddress(
        address rhsAddress: IPv6Address,
        port rhsPort: UInt16,
        interfaceIndex: Int32,
        matchInterface: Bool
    ) -> Bool {
        switch self.type {
        case .v4(_, _):
            guard let v4Address = rhsAddress.asIPv4 else {
                return false
            }
            return self.matchesAddress(
                address: v4Address,
                port: rhsPort,
                interfaceIndex: interfaceIndex,
                matchInterface: matchInterface
            )
        case .v6(let address, port):
            if address != rhsAddress {
                return false
            }
            if port != rhsPort {
                return false
            }
            if !matchInterface {
                return true
            }
            guard let interface else {
                return false
            }
            return interface.index == interfaceIndex
        default:
            return false
        }
    }

    func matchesAddress(address rhsPath: String) -> Bool {
        switch self.type {
        case .unix(let path):
            return path == rhsPath
        default:
            return false
        }
    }

    var isLoopbackOrLocal: Bool {
        switch self.type {
        case .v4(let address, _):
            return address.isLinkLocal || address.isLocalGroup || address.isZeroNet || address.isLoopback
        case .v6(let address, _):
            return address.isLinkLocal || address.isLoopback || address.isMulticastLinkLocal || address.isUnspecified
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.common)
        switch self.type {
        case .v4(let address, let port):
            hasher.combine(address)
            hasher.combine(port)
        case .v6(let address, let port):
            hasher.combine(address)
            hasher.combine(port)
        case .unix(let path):
            #if !NETWORK_EMBEDDED
            hasher.combine(path)
            #else
            break
            #endif
        #if NETWORK_PRIVATE
        case .vm(let vm):
            hasher.combine(vm)
        #endif
        case .unspec:
            break
        }
    }
}
