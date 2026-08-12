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

@_spi(Essentials)
@available(Network 0.1.0, *)
public enum ProtocolLevel: Sendable, Hashable {
    case link
    case internet
    case transport
    case application
    case persistentApplication
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum ProtocolMapping: Sendable {
    case oneToOne
    case manyToOne
    case oneToMany
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct ProtocolIdentifier: Hashable, Sendable {
    #if NETWORK_EMBEDDED
    public var name: String
    #else
    public var name: String {
        get {
            switch self.protocolName {
            case .known(let protocolName):
                return protocolName.rawValue
            case .custom(let name):
                return name
            }
        }
    }
    #endif
    public let level: ProtocolLevel
    public let mapping: ProtocolMapping
    #if !NETWORK_EMBEDDED
    internal let protocolName: Name
    internal enum Name: Hashable {
        internal enum WellKnown: String, Sendable {
            case idle
            case socket
            case ethernet
            case replicate
            case test
            case demux
            case tcp
            case udp
            case swift_udp = "swift-udp"
            case ip
            case custom_ip = "custom-ip"
            case webtransport
            case http1
            case http2
            case http3
            case http_cookie
            case http_connection_state
            case http_authentication
            case http_encoding
            case http_redirect
            case http_resumable_upload
            case http_retry
            case http_security
            case http_sniffing
            case ohttp
            case ohttp_contexts = "ohttp-contexts"
            case http_client
            case http_joining
            case http_messaging
            case shoes
            case masque
            case masque_listener
            case http_connect
            case swift_quic = "swift-quic"
            case quic
            case quic_connection = "quic-connection"
            case tls
            case http
            case swift_ip = "swift-ip"

            internal func mapNameToIndex() -> UInt8 {
                switch self {
                case .idle:
                    return 1
                case .socket:
                    return 2
                case .ethernet:
                    return 3
                case .replicate:
                    return 4
                case .test:
                    return 5
                case .demux:
                    return 6
                case .tcp:
                    return 7
                case .udp:
                    return 8
                case .swift_udp:
                    return 9
                case .ip:
                    return 10
                case .custom_ip:
                    return 11
                case .webtransport:
                    return 12
                case .http1:
                    return 13
                case .http2:
                    return 14
                case .http3:
                    return 15
                case .http_cookie:
                    return 16
                case .http_connection_state:
                    return 17
                case .http_authentication:
                    return 18
                case .http_encoding:
                    return 19
                case .http_redirect:
                    return 20
                case .http_resumable_upload:
                    return 21
                case .http_retry:
                    return 22
                case .http_security:
                    return 23
                case .http_sniffing:
                    return 24
                case .ohttp:
                    return 25
                case .ohttp_contexts:
                    return 26
                case .http_client:
                    return 27
                case .http_joining:
                    return 28
                case .http_messaging:
                    return 29
                case .shoes:
                    return 30
                case .masque:
                    return 31
                case .masque_listener:
                    return 32
                case .http_connect:
                    return 33
                case .swift_quic:
                    return 34
                case .quic:
                    return 35
                case .quic_connection:
                    return 36
                case .tls:
                    return 37
                case .http:
                    return 38
                case .swift_ip:
                    return 39
                }
            }
            static public func == (lhs: WellKnown, rhs: WellKnown) -> Bool {
                lhs.mapNameToIndex() == rhs.mapNameToIndex()
            }
        }
        case known(WellKnown)
        case custom(String)

        init(_ name: String) {
            if let known = WellKnown(rawValue: name) {
                self = .known(known)
            } else {
                self = .custom(name)
            }
        }
    }
    #endif

    public init(name: String, level: ProtocolLevel, mapping: ProtocolMapping) {
        self.level = level
        self.mapping = mapping
        #if NETWORK_EMBEDDED
        self.name = name
        #else
        self.protocolName = Name(name)
        #endif
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public protocol NetworkProtocol: Sendable {
    associatedtype Options: PerProtocolOptions
    associatedtype Metadata: PerProtocolMetadata

    init()
    func newPerProtocolOptions() -> Options?
    func newPerProtocolOptions(from existing: Options) -> Options
    func newPerProtocolOptions(from serializedBytes: [UInt8]) -> Options?
    func newPerProtocolMetadata() -> Metadata?
    func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference?
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct ProtocolDefinition<P: NetworkProtocol>: Equatable, CustomStringConvertible, Sendable {
    let identifier: ProtocolIdentifier
    var networkProtocol: P
    let uniqueIdentifier: SystemUUID?

    public var description: String { self.identifier.name }

    public init(identifier: ProtocolIdentifier, register: Bool = true) {
        self.identifier = identifier
        self.uniqueIdentifier = nil
        self.networkProtocol = P()
        // TODO: Register the protocol automatically
    }

    public init(name: String?, multiplex: Bool = false) {
        let uuid = SystemUUID()
        self.uniqueIdentifier = uuid
        let nameString: String
        if let name = name {
            nameString = name
        } else {
            nameString = uuid.uuidString
        }
        self.identifier = ProtocolIdentifier(
            name: nameString,
            level: .application,
            mapping: multiplex ? .manyToOne : .oneToOne
        )
        self.networkProtocol = P()
    }

    public static func == (lhs: ProtocolDefinition, rhs: ProtocolDefinition) -> Bool {
        lhs.uniqueIdentifier == rhs.uniqueIdentifier && lhs.identifier == rhs.identifier
    }

    func newPerProtocolOptions() -> (P.Options)? { networkProtocol.newPerProtocolOptions() }
    func newPerProtocolOptions(from existing: P.Options) -> (P.Options) {
        networkProtocol.newPerProtocolOptions(from: existing)
    }
    func newPerProtocolOptions(from serializedBytes: [UInt8]) -> (P.Options)? {
        networkProtocol.newPerProtocolOptions(from: serializedBytes)
    }

    func newPerProtocolMetadata() -> (P.Metadata)? { networkProtocol.newPerProtocolMetadata() }

    public func protocolOptions() -> ProtocolOptions<P> {
        ProtocolOptions(protocolIdentifier: self.identifier, perProtocolOptions: self.newPerProtocolOptions())
    }

    public func protocolMetadata(messageIdentifier: SystemUUID = SystemUUID(insecure: true)) -> ProtocolMetadata<P> {
        ProtocolMetadata(
            protocolIdentifier: self.identifier,
            perProtocolMetadata: self.newPerProtocolMetadata(),
            messageIdentifier: messageIdentifier
        )
    }

    #if NETWORK_PRIVATE
    var privateStorage = ProtocolDefinitionPrivateStorage()
    #endif
}
