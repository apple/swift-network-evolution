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

#if canImport(Foundation) && !NETWORK_EMBEDDED
import Foundation
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
#if !NETWORK_EMBEDDED
@dynamicMemberLookup
#endif
public struct Endpoint: EndpointProtocol, Hashable, Sendable {
    /// The payload is boxed (`indirect`) because every endpoint type reaches back
    /// to `Endpoint` through ``EndpointCommon/parentEndpoint``; that would make
    /// this a recursive value type otherwise. Boxing also keeps `Endpoint` itself
    /// pointer-sized regardless of which case it holds.
    public indirect enum EndpointType: Sendable {
        case address(AddressEndpoint)
        case applicationService(ApplicationServiceEndpoint)
        case bonjour(BonjourEndpoint)
        case host(HostEndpoint)
        case srv(SRVEndpoint)
        case url(URLEndpoint)
    }

    public var type: EndpointType

    #if NETWORK_DRIVERKIT
    var endpointPrivate = Endpoint.EndpointPrivate()
    #endif

    // MARK: -- Common state --

    /// The common state shared by every endpoint type, forwarded to whichever
    /// case `type` currently holds (unwrapped by `EndpointType.common`). All
    /// individual common fields are reached through the `dynamicMember`
    /// subscript below rather than through per-field switches.
    var common: EndpointCommon {
        get { type.common }
        set { type.common = newValue }
    }

    #if !NETWORK_EMBEDDED
    /// Reads and writes any ``EndpointCommon`` field directly on the endpoint,
    /// e.g. `endpoint.alternatePort` or `endpoint.parentEndpoint`.
    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<EndpointCommon, Value>) -> Value {
        get { common[keyPath: keyPath] }
        set { common[keyPath: keyPath] = newValue }
    }
    #else
    // Embedded Swift has no key paths; forward the common fields explicitly.
    var alternatePort: UInt16? {
        get { common.alternatePort }
        set { common.alternatePort = newValue }
    }
    var cnames: [Endpoint]? {
        get { common.cnames }
        set { common.cnames = newValue }
    }
    public var parentEndpoint: Endpoint? {
        get { common.parentEndpoint }
        set { common.parentEndpoint = newValue }
    }
    var ethernetAddress: EthernetAddress? {
        get { common.ethernetAddress }
        set { common.ethernetAddress = newValue }
    }
    #endif

    // MARK: -- Initializers --
    public init(_ address: AddressEndpoint) {
        self.type = .address(address)
    }

    public init(address: IPv4Address, port: UInt16, interface: Interface? = nil) {
        self.init(AddressEndpoint(address: address, port: port, interface: interface))
    }

    public init(address: IPv6Address, port: UInt16, interface: Interface? = nil) {
        self.init(AddressEndpoint(address: address, port: port, interface: interface))
    }

    public init(_ applicationService: ApplicationServiceEndpoint) {
        self.type = .applicationService(applicationService)
    }

    public init(_ bonjour: BonjourEndpoint) {
        self.type = .bonjour(bonjour)
    }

    #if !NETWORK_PRIVATE
    public init(_ host: HostEndpoint) {
        self.type = .host(host)
    }
    #endif

    public init(hostname: String, port: UInt16) {
        self.init(HostEndpoint(name: hostname, port: port))
    }

    public init(_ srv: SRVEndpoint) {
        self.type = .srv(srv)
    }

    public init(_ url: URLEndpoint) {
        self.type = .url(url)
    }

    init?(url: URL) {
        guard let urlEndpoint = URLEndpoint(url: url) else { return nil }
        self.init(urlEndpoint)
    }

    public init?(urlString: String) {
        guard let urlEndpoint = URLEndpoint(string: urlString) else { return nil }
        self.init(urlEndpoint)
    }

    init(_ type: EndpointType) {
        self.type = type
    }

    // MARK: -- Serialization --

    init?(serializedData: inout [UInt8]) {
        // First two fields:
        // endpointLength: UInt8
        // endpointFamily: UInt8

        var length: UInt8 = 0
        var family: UInt8 = 0

        var result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
            try read.uint8(&length)
            try read.uint8(&family)
        }
        guard result.isValid else { return nil }
        switch family {
        case AddressFamily.ipv4.rawValue:
            guard length == 16 else { return nil }
            var port: UInt16 = 0
            var address = [UInt8]()
            result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
                try read.uint16NetworkByteOrder(&port)
                try read.buffer(&address, length: 4)
            }
            guard result.isValid else { return nil }
            guard let address = IPv4Address(address) else { return nil }
            let endpoint = AddressEndpoint(address: address, port: port)
            self.type = .address(endpoint)
        case AddressFamily.ipv6.rawValue:
            guard length == 28 else { return nil }
            var port: UInt16 = 0
            var address = [UInt8]()
            var scope: UInt32 = 0
            result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
                try read.uint16NetworkByteOrder(&port)
                try read.skip(4)
                try read.buffer(&address, length: 16)
                try read.uint32(&scope)
            }
            guard result.isValid else { return nil }
            guard let address = IPv6Address(address) else { return nil }
            var endpoint = AddressEndpoint(address: address, port: port)
            endpoint.scope = scope
            self.type = .address(endpoint)
        case AddressFamily.unix.rawValue:
            guard length > 2 else { return nil }
            var path: String = ""
            result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
                try read.fixedLengthUTF8(&path, byteCount: Int(length - 2))
            }
            guard result.isValid else { return nil }
            guard let endpoint = AddressEndpoint(path) else { return nil }
            self.type = .address(endpoint)
        case AddressFamily.unspecified.rawValue:
            #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
            guard let endpointType = Self.deserializeEndpointPrivate(&serializedData) else { return nil }
            self.type = endpointType
            #else
            // Other endpoint type, not handled yet
            return nil
            #endif
        default: return nil
        }
    }

    func serialize() -> [UInt8]? {
        switch self.type {
        case .address(let endpoint):
            return endpoint.serialize()
        case .applicationService(let endpoint):
            return endpoint.serialize()
        case .bonjour(let endpoint):
            return endpoint.serialize()
        case .host(let endpoint):
            return endpoint.serialize()
        case .srv(let endpoint):
            return endpoint.serialize()
        case .url(let endpoint):
            return endpoint.serialize()
        }
    }

    // MARK: -- Comparisons --

    public static func == (lhs: Endpoint, rhs: Endpoint) -> Bool {
        lhs.isEqual(to: rhs, flags: .all)
    }

    #if !NETWORK_PRIVATE
    func isEqual(to other: Endpoint, flags: EndpointEqualityFlags) -> Bool {
        switch self.type {
        case .address(let endpoint):
            if case let .address(otherEndpoint) = other.type {
                return endpoint.isEqual(to: otherEndpoint, flags: flags)
            }
        case .applicationService(let endpoint):
            if case let .applicationService(otherEndpoint) = other.type {
                return endpoint.isEqual(to: otherEndpoint, flags: flags)
            }
        case .bonjour(let endpoint):
            if case let .bonjour(otherEndpoint) = other.type {
                return endpoint.isEqual(to: otherEndpoint, flags: flags)
            }
        case .host(let endpoint):
            if case let .host(otherEndpoint) = other.type {
                return endpoint.isEqual(to: otherEndpoint, flags: flags)
            }
        case .srv(let endpoint):
            if case let .srv(otherEndpoint) = other.type {
                return endpoint.isEqual(to: otherEndpoint, flags: flags)
            }
        case .url(let endpoint):
            if case let .url(otherEndpoint) = other.type {
                return endpoint.isEqual(to: otherEndpoint, flags: flags)
            }
        }
        return false
    }
    #endif

    // MARK: -- Description --

    public var description: String {
        #if !NETWORK_EMBEDDED
        return switch self.type {
        case .address(let endpoint): endpoint.description
        case .applicationService(let endpoint): endpoint.description
        case .bonjour(let endpoint): endpoint.description
        case .host(let endpoint): endpoint.description
        case .srv(let endpoint): endpoint.description
        case .url(let endpoint): endpoint.description
        }
        #else
        return "<endpoint>"
        #endif
    }

    #if !NETWORK_PRIVATE
    var redactedDescription: String {
        #if !NETWORK_EMBEDDED
        return switch self.type {
        case .address(let endpoint): endpoint.redactedDescription
        case .applicationService(let endpoint): endpoint.redactedDescription
        case .bonjour(let endpoint): endpoint.redactedDescription
        case .host(let endpoint): endpoint.redactedDescription
        case .srv(let endpoint): endpoint.redactedDescription
        case .url(let endpoint): endpoint.redactedDescription
        }
        #else
        return "<endpoint>"
        #endif
    }
    #endif

    // MARK: -- Computed Properties --

    /// The domain a policy match is evaluated against, from this endpoint or its parent.
    var domainForPolicy: String? {
        var domain: String? =
            switch self.type {
            case .bonjour(let bonjourEndpoint):
                bonjourEndpoint.domainForPolicy
            case .host(let hostEndpoint):
                hostEndpoint.domainForPolicy
            case .srv(let srvEndpoint):
                srvEndpoint.domainForPolicy
            case .url(let urlEndpoint):
                urlEndpoint.domainForPolicy
            default:
                nil
            }
        if domain == nil, let parentEndpoint = self.parentEndpoint {
            domain = parentEndpoint.domainForPolicy
        }
        return domain
    }

    public var port: UInt16 {
        switch self.type {
        case .address(let addressEndpoint):
            return addressEndpoint.port
        case .applicationService(_):
            return 0
        case .bonjour(_):
            return 0
        case .host(let hostEndpoint):
            return hostEndpoint.port
        case .srv(_):
            return 0
        case .url(let urlEndpoint):
            return urlEndpoint.port
        }
    }

    var interface: Interface? {
        get { common.interface }
        set { common.interface = newValue }
    }

    /// The service priority carried by the underlying endpoint, or `0` for endpoint kinds
    /// that do not carry one.
    ///
    /// A `0` means "no priority supplied", not the highest priority: RFC 9460 reserves
    /// SvcPriority 0 for AliasMode, so it never appears as a usable ServiceMode priority.
    var priority: UInt16 {
        switch self.type {
        case .address(let addressEndpoint):
            return addressEndpoint.priority
        case .applicationService(_):
            return 0
        case .bonjour(_):
            return 0
        case .host(let hostEndpoint):
            return hostEndpoint.priority
        case .srv(_):
            return 0
        case .url(_):
            return 0
        }
    }

    /// The service weight carried by the underlying endpoint, or `0` for endpoint kinds that
    /// do not carry one. A `0` means no weight was supplied.
    ///
    /// What a non-zero value *means* depends on where the endpoint came from: it may be an
    /// SRV record's `Weight` field, or a synthetic key a caller assigned in order to rank
    /// equal-priority services. This accessor does not distinguish the two — see
    /// ``orderByServicePriority(_:)`` for which of them it can order correctly.
    var weight: UInt16 {
        switch self.type {
        case .address(let addressEndpoint):
            return addressEndpoint.weight
        case .applicationService(_):
            return 0
        case .bonjour(_):
            return 0
        case .host(let hostEndpoint):
            return hostEndpoint.weight
        case .srv(_):
            return 0
        case .url(_):
            return 0
        }
    }

    /// The address family of this endpoint, or `nil` if it does not carry an address.
    var addressFamily: AddressFamily? {
        guard case .address(let addressEndpoint) = self.type else {
            return nil
        }
        return addressEndpoint.addressFamily
    }

    // MARK: -- Hashing --

    var hashInternal: Int {
        switch self.type {
        case .address(let endpoint):
            return endpoint.hashValue
        case .applicationService(let endpoint):
            return endpoint.hashValue
        case .bonjour(let endpoint):
            return endpoint.hashValue
        case .host(let endpoint):
            return endpoint.hashValue
        case .srv(let endpoint):
            return endpoint.hashValue
        case .url(let endpoint):
            return endpoint.hashValue
        }
    }

    public var hash: Int {
        hashInternal
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hashInternal)
    }
}
