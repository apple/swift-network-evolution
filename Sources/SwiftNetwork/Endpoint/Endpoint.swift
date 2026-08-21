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

#if !NETWORK_PRIVATE
@_spi(Essentials)
@available(Network 0.1.0, *)
public class EndpointParent: Hashable, Equatable {
    public func hash(into hasher: inout Hasher) {}
    static public func == (lhs: EndpointParent, rhs: EndpointParent) -> Bool {
        false
    }
    public var description: String { "" }
    var redactedDescription: String { "" }
    public var hash: Int { 0 }
}
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class Endpoint: EndpointParent, EndpointProtocol {
    public enum EndpointType: Sendable {
        case address(AddressEndpoint)
        case applicationService(ApplicationServiceEndpoint)
        case bonjour(BonjourEndpoint)
        case host(HostEndpoint)
        case srv(SRVEndpoint)
        case url(URLEndpoint)
    }

    public var type: EndpointType
    var alternatePort: UInt16? = nil
    var cnames: [Endpoint]? = nil
    public var parentEndpoint: Endpoint? = nil

    #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
    var endpointPrivate = Endpoint.EndpointPrivate()
    #endif

    // MARK: -- Initializers --
    public init(_ address: AddressEndpoint) {
        self.type = .address(address)
        super.init()
    }

    public convenience init(address: IPv4Address, port: UInt16, interface: Interface? = nil) {
        self.init(AddressEndpoint(address: address, port: port, interface: interface))
    }

    public convenience init(address: IPv6Address, port: UInt16, interface: Interface? = nil) {
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

    public convenience init(hostname: String, port: UInt16) {
        self.init(HostEndpoint(name: hostname, port: port))
    }

    public init(_ srv: SRVEndpoint) {
        self.type = .srv(srv)
    }

    public init(_ url: URLEndpoint) {
        self.type = .url(url)
    }

    convenience init?(url: URL) {
        guard let urlEndpoint = URLEndpoint(url: url) else { return nil }
        self.init(urlEndpoint)
    }

    public convenience init?(urlString: String) {
        guard let urlEndpoint = URLEndpoint(string: urlString) else { return nil }
        self.init(urlEndpoint)
    }

    init(_ type: EndpointType) {
        self.type = type
    }

    // MARK: -- Serialization --

    required init?(serializedData: inout [UInt8]) {
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
            super.init()
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
            super.init()
        case AddressFamily.unix.rawValue:
            guard length > 2 else { return nil }
            var path: String = ""
            result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
                try read.fixedLengthUTF8(&path, byteCount: Int(length - 2))
            }
            guard result.isValid else { return nil }
            guard let endpoint = AddressEndpoint(path) else { return nil }
            self.type = .address(endpoint)
            super.init()
        case AddressFamily.unspecified.rawValue:
            #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
            guard let endpointType = Self.deserializeEndpointPrivate(&serializedData) else { return nil }
            self.type = endpointType
            super.init()
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
        if flags.contains(.alternatives) {
            let alternatePort = alternatePort ?? 0
            let otherAlternatePort = other.alternatePort ?? 0
            if alternatePort != otherAlternatePort {
                return false
            }
        }

        if flags.contains(.parent) {
            if parentEndpoint != other.parentEndpoint {
                return false
            }
        }

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

    public override var description: String {
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
    override var redactedDescription: String {
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
        get {
            switch self.type {
            case .address(let endpoint):
                return endpoint.interface
            case .applicationService(let endpoint):
                return endpoint.interface
            case .bonjour(let endpoint):
                return endpoint.interface
            case .host(let endpoint):
                return endpoint.interface
            case .srv(let endpoint):
                return endpoint.interface
            case .url(let endpoint):
                return endpoint.interface
            }
        }

        set {
            switch self.type {
            case .address(var endpoint):
                endpoint.interface = newValue
                self.type = .address(endpoint)
            case .applicationService(var endpoint):
                endpoint.interface = newValue
                self.type = .applicationService(endpoint)
            case .bonjour(var endpoint):
                endpoint.interface = newValue
                self.type = .bonjour(endpoint)
            case .host(var endpoint):
                endpoint.interface = newValue
                self.type = .host(endpoint)
            case .srv(var endpoint):
                endpoint.interface = newValue
                self.type = .srv(endpoint)
            case .url(var endpoint):
                endpoint.interface = newValue
                self.type = .url(endpoint)
            }
        }
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

    public override var hash: Int {
        hashInternal
    }
}
