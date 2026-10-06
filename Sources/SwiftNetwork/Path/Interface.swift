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

#if canImport(Android)
import Android
internal import Logging
#elseif canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

/// The type of underlying media for a network link.
@_spi(Essentials)
@available(Network 0.1.0, *)
public enum InterfaceType: Int, Sendable, CaseIterable {
    /// A virtual or otherwise unknown interface type.
    case other = 0
    /// A Wi-Fi link.
    case wifi = 2
    /// A cellular link.
    case cellular = 3
    /// A wired Ethernet link.
    case wiredEthernet = 4
    /// The loopback interface.
    case loopback = 1
}

/// The subtype of underlying media for a network link.
@_spi(Essentials)
@available(Network 0.1.0, *)
public enum InterfaceSubtype: Int, Sendable, CaseIterable {
    /// A virtual or otherwise unknown interface subtype.
    case other = 0
    /// A Wi-Fi infrastructure subtype.
    case wifiInfrastructure = 3
    /// A Wi-Fi AWDL subtype.
    case wifiAWDL = 4
    /// A coprocessor subtype.
    case coprocessor = 6
    /// A companion subtype.
    case companion = 7
}

#if !NETWORK_PRIVATE
struct InterfaceFlagDefinitions {
    static let INTERFACE_FLAG_EXPENSIVE = 1 << 0
    static let INTERFACE_FLAG_CONSTRAINED = 1 << 1
    static let INTERFACE_FLAG_ULTRA_CONSTRAINED = 1 << 2
    static let INTERFACE_FLAG_TXSTART = 1 << 3
    static let INTERFACE_FLAG_NOACKPRI = 1 << 4
    static let INTERFACE_FLAG_3CARRIERAGG = 1 << 5
    static let INTERFACE_FLAG_MPK_LOG = 1 << 6
    static let INTERFACE_FLAG_SUPPORTS_MULTICAST = 1 << 7
    static let INTERFACE_FLAG_HAS_DNS = 1 << 8
    static let INTERFACE_FLAG_HAS_NAT64 = 1 << 9
    static let INTERFACE_FLAG_IPV4_ROUTABLE = 1 << 10
    static let INTERFACE_FLAG_IPV6_ROUTABLE = 1 << 11
    static let INTERFACE_FLAG_HAS_NETMASK = 1 << 12
    static let INTERFACE_FLAG_HAS_BROADCAST = 1 << 13
    static let INTERFACE_FLAG_LOW_POWER_WAKE = 1 << 14
}
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct Interface: Sendable, Hashable, CustomStringConvertible {

    public var index: Int { backing.storage.index }
    var delegateIndex: Int { backing.storage.delegateIndex }
    var generation: Int { backing.storage.generation }
    public var name: String { backing.storage.name }
    var details: Interface.Details { backing.storage.details }
    var interfaceType: InterfaceType { backing.storage.interfaceType }
    var interfaceSubtype: InterfaceSubtype { backing.storage.interfaceSubtype }

    var isExpensive: Bool { backing.storage.details.flags.contains(.expensive) }
    var isConstrained: Bool { backing.storage.details.flags.contains(.constrained) }
    var isUltraConstrained: Bool { backing.storage.details.flags.contains(.ultraConstrained) }
    var supportsMulticast: Bool { backing.storage.details.flags.contains(.supportsMulticast) }
    var hasDNS: Bool { backing.storage.details.flags.contains(.hasDNS) }
    var hasNAT64: Bool { backing.storage.details.flags.contains(.hasNAT64) }
    var ipv4Routable: Bool { backing.storage.details.flags.contains(.ipv4Routable) }
    var ipv6Routable: Bool { backing.storage.details.flags.contains(.ipv6Routable) }
    var isMultilayerPacketLogging: Bool { backing.storage.details.flags.contains(.multilayerPacketLogging) }
    var txStart: Bool { backing.storage.details.flags.contains(.txStart) }
    var noAckPriority: Bool { backing.storage.details.flags.contains(.noAckPriority) }
    var carrierAggregation: Bool { backing.storage.details.flags.contains(.carrierAggregation) }
    var mtu: Int { backing.storage.details.mtu }
    var hardwareChecksumFlags: Int { backing.storage.details.hardwareChecksumFlags }
    var radioType: Int { backing.storage.details.radioType }
    var ipv4TSOMaxSegmentSize: Int { backing.storage.details.ipv4TSOMaxSegmentSize }
    var ipv6TSOMaxSegmentSize: Int { backing.storage.details.ipv6TSOMaxSegmentSize }
    var ipv4Netmask: IPv4Address? { backing.storage.details.ipv4Netmask }
    var ipv4Broadcast: IPv4Address? { backing.storage.details.ipv4Broadcast }
    var l4sMode: Int { backing.storage.details.l4sMode }
    var lowPowerWake: Bool { backing.storage.details.flags.contains(.lowPowerWake) }

    internal final class BackingClass: Sendable, Hashable {
        static func == (lhs: Interface.BackingClass, rhs: Interface.BackingClass) -> Bool {
            lhs.storage == rhs.storage
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(storage)
        }

        internal struct Storage: Sendable, Hashable {
            let index: Int
            let delegateIndex: Int
            let generation: Int
            let name: String

            let details: Interface.Details
            let interfaceType: InterfaceType
            let interfaceSubtype: InterfaceSubtype

            public func hash(into hasher: inout Hasher) {
                hasher.combine(self.index)
                #if !NETWORK_EMBEDDED
                hasher.combine(self.name)
                #endif
                hasher.combine(self.interfaceType)
                hasher.combine(self.interfaceSubtype)
            }

            init(
                index: Int,
                name: String,
                type: InterfaceType,
                subtype: InterfaceSubtype,
                generation: Int = 0,
                delegateIndex: Int = 0,
                expensive: Bool = false,
                constrained: Bool = false,
                mtu: Int = 0,
                ipv4Netmask: IPv4Address? = nil,
                ipv4Broadcast: IPv4Address? = nil,
                linkQuality: PathProperties.LinkQuality = .unknown
            ) {
                self.name = name
                self.index = index
                self.interfaceType = type
                self.interfaceSubtype = subtype
                self.generation = generation
                self.delegateIndex = delegateIndex
                self.details = Details(
                    expensive: expensive,
                    constrained: constrained,
                    mtu: mtu,
                    ipv4Netmask: ipv4Netmask,
                    ipv4Broadcast: ipv4Broadcast,
                    linkQuality: linkQuality
                )
            }

            #if !NETWORK_PRIVATE
            init(index: Int, name: String) throws(NetworkError) {
                precondition(
                    index <= Int32.max,
                    "Refusing to create an interface with index \(index) too high (>=\(Int32.max)) (name=\"\(name)\""
                )
                self.index = index
                self.name = name
                self.generation = 0
                var socket: SystemSocket
                do {
                    socket = try SystemSocket(
                        protocolFamily: .ipv4,
                        sockType: .datagram,
                        protocolSubType: 0,
                        nonBlocking: false
                    )
                } catch {
                    Logger.interface.error("Failed to create a socket with error: \(error)")
                    throw NetworkError.posix(EINVAL)
                }
                #if !NETWORK_STANDALONE
                self.details = socket.withFileDescriptor { fd in
                    Details(socket: fd, name: name)
                }
                let interfaceType =
                    socket.withFileDescriptor { fd in
                        try? System.interfaceGetInterfaceType(socket: fd, name: name)
                    } ?? .other
                let interfaceSubType =
                    socket.withFileDescriptor { fd in
                        try? System.interfaceGetInterfaceSubType(socket: fd, name: name, interfaceType: interfaceType)
                    } ?? .other
                self.interfaceType = interfaceType
                self.interfaceSubtype = interfaceSubType
                self.delegateIndex = 0
                #else
                self.details = Details()
                self.interfaceType = .other
                self.interfaceSubtype = .other
                self.delegateIndex = 0
                #endif
            }
            #endif

            init(index: Int) throws(NetworkError) {
                precondition(
                    index <= Int32.max,
                    "Refusing to create an interface with index \(index) too high (>=\(Int32.max))"
                )
                var name = ""
                #if !NETWORK_STANDALONE || NETWORK_DRIVERKIT
                do {
                    guard let interfaceName = try System.interfaceGetNameFromIndex(index: UInt32(index)) else {
                        Logger.interface.error("Could not get name from index \(index)")
                        throw NetworkError.posix(EIO)
                    }
                    name = interfaceName
                } catch {
                    Logger.interface.error("interfaceGetNameFromIndex failed for interface index \(index): \(error)")
                    throw NetworkError.posix(ENOENT)
                }
                #else
                name = String("EmbeddedIntf")
                #endif
                try self.init(index: index, name: name)
            }

            init(name: String) throws(NetworkError) {
                var index: UInt32 = 0
                do {
                    index = try System.interfaceNameToIndex(name: name)
                } catch {
                    #if !NETWORK_STANDALONE
                    Logger.interface.error("init(name: String) failed for interface index \(name): \(error)")
                    #endif
                    throw NetworkError.posix(ENOENT)
                }
                // kernel if_nametoindex() should be within valid range 1..Int32.max
                try self.init(index: Int(index), name: name)
            }
        }
        let storage: Storage

        init(storage: Storage) {
            self.storage = storage
        }

        init(throwingStorage: Storage) throws(NetworkError) {
            self.storage = throwingStorage
        }
    }

    #if !NETWORK_EMBEDDED
    typealias Backing = BackingClass
    #else
    // Embedded compiler crashes when using a class within a struct for backing.
    // This uses nested structs only as a workaround.
    internal struct BackingStruct: Sendable, Hashable {
        var storage: BackingClass.Storage
        init(storage: BackingClass.Storage) {
            self.storage = storage
        }
        init(throwingStorage: BackingClass.Storage) throws(NetworkError) {
            self.storage = throwingStorage
        }
    }
    typealias Backing = BackingStruct
    #endif
    internal var backing: Backing

    struct Details: Equatable {
        let mtu: Int
        let ipv4TSOMaxSegmentSize: Int
        let ipv6TSOMaxSegmentSize: Int
        let ipv4Netmask: IPv4Address?
        let ipv4Broadcast: IPv4Address?
        let hardwareChecksumFlags: Int
        let radioType: Int
        let l4sMode: Int
        let linkQuality: PathProperties.LinkQuality

        struct Flags: OptionSet {
            public init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            public var rawValue: UInt32

            static public let expensive = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_EXPENSIVE)
            )
            static public let constrained = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_CONSTRAINED)
            )
            static public let ultraConstrained = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_ULTRA_CONSTRAINED)
            )
            static public let txStart = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_TXSTART)
            )
            static public let noAckPriority = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_NOACKPRI)
            )
            static public let carrierAggregation = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_3CARRIERAGG)
            )
            static public let multilayerPacketLogging = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_MPK_LOG)
            )
            static public let supportsMulticast = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_SUPPORTS_MULTICAST)
            )
            static public let hasDNS = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_HAS_DNS)
            )
            static public let hasNAT64 = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_HAS_NAT64)
            )
            static public let ipv4Routable = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_IPV4_ROUTABLE)
            )
            static public let ipv6Routable = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_IPV6_ROUTABLE)
            )
            static public let hasNetmask = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_HAS_NETMASK)
            )
            static public let hasBroadcast = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_HAS_BROADCAST)
            )
            static public let lowPowerWake = Interface.Details.Flags(
                rawValue: UInt32(InterfaceFlagDefinitions.INTERFACE_FLAG_LOW_POWER_WAKE)
            )
        }
        var flags: Flags = Flags()

        #if NETWORK_PRIVATE
        let privateDetails: PrivateDetails
        #endif

        #if !NETWORK_PRIVATE
        init(socket: Int32, name: String) {
            var mtu = 0
            do {
                mtu = try System.interfaceGetMTU(socket: socket, name: name)
                if try System.interfaceHasFlag(socket: socket, name: name, flag: .supportsMulticast) {
                    self.flags.insert(.supportsMulticast)
                }
            } catch {
                #if !NETWORK_STANDALONE
                Logger.interface.error("Error: \(error)")
                #endif
            }
            self.mtu = mtu
            self.ipv4Netmask = nil
            self.ipv4Broadcast = nil
            self.ipv4TSOMaxSegmentSize = 0
            self.ipv6TSOMaxSegmentSize = 0
            self.hardwareChecksumFlags = 0
            self.radioType = 0
            self.l4sMode = 0
            self.linkQuality = .unknown
        }
        #endif

        init(
            expensive: Bool = false,
            constrained: Bool = false,
            mtu: Int = 0,
            ipv4Netmask: IPv4Address? = nil,
            ipv4Broadcast: IPv4Address? = nil,
            linkQuality: PathProperties.LinkQuality = .unknown
        ) {
            if expensive {
                self.flags.insert(.expensive)
            }
            if constrained {
                self.flags.insert(.constrained)
            }
            self.mtu = mtu
            self.ipv4Netmask = ipv4Netmask
            self.ipv4Broadcast = ipv4Broadcast
            #if NETWORK_PRIVATE
            self.privateDetails = .init()
            #endif
            self.ipv4TSOMaxSegmentSize = 0
            self.ipv6TSOMaxSegmentSize = 0
            self.hardwareChecksumFlags = 0
            self.radioType = 0
            self.l4sMode = 0
            self.linkQuality = linkQuality
        }
    }  // End of Details

    public var description: String {
        self.name
    }

    public static func == (lhs: Interface, rhs: Interface) -> Bool {
        #if !NETWORK_EMBEDDED  // Workaround string comparision for now
        if lhs.name != rhs.name {
            return false
        }
        #endif
        if lhs.index != rhs.index
            || (lhs.interfaceType != rhs.interfaceType && lhs.interfaceType != .other && rhs.interfaceType != .other)
            || (lhs.interfaceSubtype != rhs.interfaceSubtype && lhs.interfaceSubtype != .other
                && rhs.interfaceSubtype != .other)
        {
            // Interface with delegates sometimes return the type of the
            // delegate, not the direct interface. This may cause the types
            // to mismatch. To avoid this, don't fail if one of the interface
            // types is 'other'.
            return false
        } else {
            return true
        }
    }

    func isDeepEqual(to other: Interface) -> Bool {
        if self != other {
            return false
        }
        if self.delegateIndex != other.delegateIndex || self.details != other.details {
            return false
        }
        return true
    }

    static public func isDeepEqualWithOptionals(if1: Interface?, if2: Interface?) -> Bool {
        switch (if1, if2) {
        case (.some(let if1), .some(let if2)):
            let interface1 = if1
            let interface2 = if2
            return interface1.isDeepEqual(to: interface2)
        case (.none, .none):
            return true
        default:
            return false
        }
    }

    init(
        index: Int,
        name: String,
        type: InterfaceType,
        subtype: InterfaceSubtype,
        generation: Int = 0,
        delegateIndex: Int = 0,
        expensive: Bool = false,
        constrained: Bool = false,
        mtu: Int = 0,
        ipv4Netmask: IPv4Address? = nil,
        ipv4Broadcast: IPv4Address? = nil
    ) {
        self.backing = Backing(
            storage: BackingClass.Storage(
                index: index,
                name: name,
                type: type,
                subtype: subtype,
                generation: generation,
                delegateIndex: delegateIndex,
                expensive: expensive,
                constrained: constrained,
                mtu: mtu,
                ipv4Netmask: ipv4Netmask,
                ipv4Broadcast: ipv4Broadcast
            )
        )
    }

    public init(index: Int, name: String) throws(NetworkError) {
        self.backing = try Backing(throwingStorage: BackingClass.Storage(index: index, name: name))
    }

    public init(index: Int) throws(NetworkError) {
        self.backing = try Backing(throwingStorage: BackingClass.Storage(index: index))
    }

    public init(name: String) throws(NetworkError) {
        self.backing = try Backing(throwingStorage: BackingClass.Storage(name: name))
    }
}

#if !NETWORK_EMBEDDED
@available(Network 0.1.0, *)
extension Interface: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case index
        case type
        case subtype
        case generation
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.index, forKey: .index)
        try container.encode(self.interfaceType, forKey: .type)
        try container.encode(self.interfaceSubtype, forKey: .subtype)
        try container.encode(self.generation, forKey: .generation)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let index = try container.decode(Int.self, forKey: .index)
        let type = try container.decode(InterfaceType.self, forKey: .type)
        let subtype = try container.decode(InterfaceSubtype.self, forKey: .subtype)
        let generation = try container.decode(Int.self, forKey: .generation)
        self = Interface(index: index, name: name, type: type, subtype: subtype, generation: generation)
    }
}

@available(Network 0.1.0, *)
extension InterfaceType: Codable {
    enum CodingKeys: String, CodingKey {
        case value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.rawValue, forKey: .value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .value)
        self = InterfaceType(rawValue: value) ?? .other
    }
}

@available(Network 0.1.0, *)
extension InterfaceSubtype: Codable {
    enum CodingKeys: String, CodingKey {
        case value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.rawValue, forKey: .value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .value)
        self = InterfaceSubtype(rawValue: value) ?? .other
    }
}
#endif
