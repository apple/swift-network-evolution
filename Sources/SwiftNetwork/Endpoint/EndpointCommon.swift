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
    var interface: Interface? { get }
    func isEqual(to other: Self, flags: EndpointEqualityFlags) -> Bool
    func serialize() -> [UInt8]?
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct EndpointCommon: Sendable, Equatable, Hashable {
    let interface: Interface?
    #if NETWORK_PRIVATE
    let commonPrivate: EndpointCommon_Private?
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

        #if NETWORK_PRIVATE
        if commonPrivate != other.commonPrivate {
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
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public protocol EndpointCommonProtocol: Hashable, Equatable {
    var common: EndpointCommon { get set }
}

#if !NETWORK_PRIVATE
@available(Network 0.1.0, *)
extension EndpointCommonProtocol {
    var interface: Interface? {
        get { common.interface }
        set { common = EndpointCommon(interface: newValue) }
    }
}

@available(Network 0.1.0, *)
extension EndpointCommon {
    init?(_ data: inout [UInt8]) {
        self.interface = nil
    }
}
#endif
