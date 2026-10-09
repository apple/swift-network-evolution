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

#if !NETWORK_PRIVATE
func redactedHash(_ value: String) -> String {
    var hash = Hasher()
    hash.combine(value)
    return "\(hash.finalize())"
}
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct EndpointEqualityFlags: OptionSet, Sendable {
    public init(rawValue: Self.RawValue) {
        self.rawValue = rawValue
    }

    public let rawValue: UInt32

    static public let interface = EndpointEqualityFlags(rawValue: 1 << 0)
    static public let parent = EndpointEqualityFlags(rawValue: 1 << 1)
    static public let proxyParent = EndpointEqualityFlags(rawValue: 1 << 2)
    static public let alternatives = EndpointEqualityFlags(rawValue: 1 << 3)
    static public let publicKeys = EndpointEqualityFlags(rawValue: 1 << 4)

    static public let empty: EndpointEqualityFlags = []
    static public let all: EndpointEqualityFlags = [.interface, .parent, .proxyParent, .alternatives, .publicKeys]
}

@available(Network 0.1.0, *)
extension Endpoint.EndpointType {
    enum EndpointRawType: UInt32 {
        case invalid = 0
        case address = 1
        case host = 2
        case bonjour = 3
        case url = 4
        case srv = 5
        case applicationService = 6
    }

    /// The common state of whichever endpoint this case holds.
    var common: EndpointCommon {
        get {
            switch self {
            case .address(let endpoint): return endpoint.common
            case .applicationService(let endpoint): return endpoint.common
            case .bonjour(let endpoint): return endpoint.common
            case .host(let endpoint): return endpoint.common
            case .srv(let endpoint): return endpoint.common
            case .url(let endpoint): return endpoint.common
            }
        }
        set {
            switch self {
            case .address(var endpoint):
                endpoint.common = newValue
                self = .address(endpoint)
            case .applicationService(var endpoint):
                endpoint.common = newValue
                self = .applicationService(endpoint)
            case .bonjour(var endpoint):
                endpoint.common = newValue
                self = .bonjour(endpoint)
            case .host(var endpoint):
                endpoint.common = newValue
                self = .host(endpoint)
            case .srv(var endpoint):
                endpoint.common = newValue
                self = .srv(endpoint)
            case .url(var endpoint):
                endpoint.common = newValue
                self = .url(endpoint)
            }
        }
    }

    func toRawValue() -> UInt32 {
        switch self {
        case .address(_):
            return EndpointRawType.address.rawValue
        case .applicationService(_):
            return EndpointRawType.applicationService.rawValue
        case .bonjour(_):
            return EndpointRawType.bonjour.rawValue
        case .host(_):
            return EndpointRawType.host.rawValue
        case .srv(_):
            return EndpointRawType.srv.rawValue
        case .url(_):
            return EndpointRawType.url.rawValue
        }
    }

    static func toEndpointType(_ type: UInt32) -> EndpointRawType {
        switch type {
        case 0: return .invalid
        case 1: return .address
        case 2: return .host
        case 3: return .bonjour
        case 4: return .url
        case 5: return .srv
        case 6: return .applicationService
        default: return .invalid
        }
    }
}

@available(Network 0.1.0, *)
protocol EndpointProtocol: CustomStringConvertible {
    func isEqual(to other: Self, flags: EndpointEqualityFlags) -> Bool
    func serialize() -> [UInt8]?
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct EndpointCommon: Equatable, Hashable {
    var interface: Interface?
    var alternatePort: UInt16?
    var cnames: [Endpoint]?
    var parentEndpoint: Endpoint?
    var ethernetAddress: EthernetAddress?
    #if NETWORK_PRIVATE
    var commonPrivate: EndpointCommon_Private?
    #endif

    init(interface: Interface? = nil) {
        self.interface = interface
        #if NETWORK_PRIVATE
        self.commonPrivate = nil
        #endif
    }

    func isEqual(to other: EndpointCommon, flags: EndpointEqualityFlags) -> Bool {
        if flags.contains(.interface) {
            if self.interface != other.interface {
                return false
            }
        }

        if flags.contains(.alternatives) {
            if (self.alternatePort ?? 0) != (other.alternatePort ?? 0) {
                return false
            }
        }

        if flags.contains(.parent) {
            if self.parentEndpoint != other.parentEndpoint {
                return false
            }
        }

        if flags.contains(.interface) {
            if self.ethernetAddress != other.ethernetAddress {
                return false
            }
        }

        #if NETWORK_PRIVATE
        if !self.isPrivateEqual(to: other, flags: flags) {
            return false
        }
        #endif

        return true
    }

    public func hash(into hasher: inout Hasher) {
        if let interface {
            hasher.combine(interface.hashValue)
        }
    }

    public static func == (lhs: EndpointCommon, rhs: EndpointCommon) -> Bool {
        lhs.isEqual(to: rhs, flags: .all)
    }
}

// Every field, including the `Endpoint` values held by `cnames` and `parentEndpoint`, is an
// immutable-on-copy value type, so this is checked `Sendable`. `EndpointCommon_Private` is not
// visible to this package, so that configuration keeps the conformance unchecked.
#if NETWORK_PRIVATE
@available(Network 0.1.0, *)
extension EndpointCommon: @unchecked Sendable {}
#else
@available(Network 0.1.0, *)
extension EndpointCommon: Sendable {}
#endif

/// Exposes every ``EndpointCommon`` field on the conforming type as if it were
/// declared there directly, so that adding a field to `EndpointCommon` (or to
/// `EndpointCommon_Private`) needs no per-field accessor plumbing on each of the
/// endpoint types.
///
/// Embedded Swift does not support key paths, so that build gets explicit
/// forwarding accessors below instead of the `dynamicMember` subscript.
@_spi(Essentials)
@available(Network 0.1.0, *)
#if !NETWORK_EMBEDDED
@dynamicMemberLookup
#endif
public protocol EndpointCommonProtocol: Hashable, Equatable {
    var common: EndpointCommon { get set }
}

#if !NETWORK_EMBEDDED
@_spi(Essentials)
@available(Network 0.1.0, *)
extension EndpointCommonProtocol {
    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<EndpointCommon, Value>) -> Value {
        get { common[keyPath: keyPath] }
        set { common[keyPath: keyPath] = newValue }
    }
}
#else
@available(Network 0.1.0, *)
extension EndpointCommonProtocol {
    var interface: Interface? {
        get { common.interface }
        set { common.interface = newValue }
    }
    var alternatePort: UInt16? {
        get { common.alternatePort }
        set { common.alternatePort = newValue }
    }
    var cnames: [Endpoint]? {
        get { common.cnames }
        set { common.cnames = newValue }
    }
    var parentEndpoint: Endpoint? {
        get { common.parentEndpoint }
        set { common.parentEndpoint = newValue }
    }
    var ethernetAddress: EthernetAddress? {
        get { common.ethernetAddress }
        set { common.ethernetAddress = newValue }
    }
}
#endif

#if !NETWORK_PRIVATE
@available(Network 0.1.0, *)
extension EndpointCommon {
    init?(_ data: inout [UInt8]) {
        self.interface = nil
    }
}
#endif
