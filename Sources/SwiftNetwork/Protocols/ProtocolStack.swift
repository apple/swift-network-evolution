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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class ProtocolStack: Hashable {
    public enum ApplicationProtocol: Hashable {
        case none
        case quic(_ options: ProtocolOptions<QUICProtocol>)
        case swiftTLS(_ options: ProtocolOptions<SwiftTLSProtocol>)
        #if !NETWORK_EMBEDDED
        case custom(_ options: AbstractProtocolOptions)
        #endif

        func deepCopy() -> ApplicationProtocol {
            switch self {
            case .none: return .none
            case .quic(let options): return .quic(options.deepCopy())
            case .swiftTLS(let options): return .swiftTLS(options.deepCopy())
            #if !NETWORK_EMBEDDED
            case .custom(let options): return .custom(options.deepCopy())
            #endif
            }
        }
        public func hash(into hasher: inout Hasher) {
            switch self {
            case .none: hasher.combine(0)
            case .quic(let options): hasher.combine(options.identifier)
            case .swiftTLS(let options): hasher.combine(options.identifier)
            #if !NETWORK_EMBEDDED
            case .custom(let options): hasher.combine(options.identifier)
            #endif
            }
        }
        func isEqual(to: ApplicationProtocol, for compareMode: ProtocolCompareMode) -> Bool {
            switch (self, to) {
            case (.none, .none): return true
            case (.quic(let loptions), .quic(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            case (.swiftTLS(let loptions), .swiftTLS(let roptions)):
                return loptions.isEqual(to: roptions, for: compareMode)
            #if !NETWORK_EMBEDDED
            case (.custom(let loptions), .custom(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            #endif
            default: return false
            }
        }
        public static func == (lhs: ProtocolStack.ApplicationProtocol, rhs: ProtocolStack.ApplicationProtocol) -> Bool {
            lhs.isEqual(to: rhs, for: .equal)
        }
        func matches<T>(definition: ProtocolDefinition<T>) -> Bool {
            switch self {
            case .none: return false
            case .quic(let options): return options.matches(definition: definition)
            case .swiftTLS(let options): return options.matches(definition: definition)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(definition: definition)
            #endif
            }
        }
        func matches(identifier: ProtocolIdentifier) -> Bool {
            switch self {
            case .none: return false
            case .quic(let options): return options.matches(identifier: identifier)
            case .swiftTLS(let options): return options.matches(identifier: identifier)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(identifier: identifier)
            #endif
            }
        }
        func matches(protocolInstance: ProtocolInstanceReference) -> Bool {
            switch self {
            case .none: return false
            case .quic(let options): return options.matches(protocolInstance: protocolInstance)
            case .swiftTLS(let options): return options.matches(protocolInstance: protocolInstance)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(protocolInstance: protocolInstance)
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        func matches(protocolHandle handle: UnsafeRawPointer) -> Bool {
            switch self {
            case .none: return false
            case .quic(let options): return options.matches(protocolHandle: handle)
            case .swiftTLS(let options): return options.matches(protocolHandle: handle)
            case .custom(let options): return options.matches(protocolHandle: handle)
            }
        }
        var options: AbstractProtocolOptions? {
            switch self {
            case .none: return nil
            case .quic(let options): return options
            case .swiftTLS(let options): return options
            case .custom(let options): return options
            }
        }
        #endif
        var identifier: ProtocolIdentifier? {
            switch self {
            case .none: return nil
            case .quic(let options): return options.identifier
            case .swiftTLS(let options): return options.identifier
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.identifier
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        init(options: AbstractProtocolOptions) {
            if let options = options as? ProtocolOptions<QUICProtocol> {
                self = .quic(options)
            } else if let options = options as? ProtocolOptions<SwiftTLSProtocol> {
                self = .swiftTLS(options)
            } else {
                self = .custom(options)
            }
        }
        #endif
    }

    public enum InternetProtocol: Hashable {
        case defaultIP
        case ip(_ options: ProtocolOptions<IPProtocol>)
        #if !NETWORK_EMBEDDED
        case custom(_ options: AbstractProtocolOptions)
        #endif

        func deepCopy() -> InternetProtocol {
            switch self {
            case .defaultIP: return .defaultIP
            case .ip(let options): return .ip(options.deepCopy())
            #if !NETWORK_EMBEDDED
            case .custom(let options): return .custom(options.deepCopy())
            #endif
            }
        }
        public func hash(into hasher: inout Hasher) {
            switch self {
            case .defaultIP: hasher.combine(0)
            case .ip(let options): hasher.combine(options.identifier)
            #if !NETWORK_EMBEDDED
            case .custom(let options): hasher.combine(options.identifier)
            #endif
            }
        }
        func isEqual(to: InternetProtocol, for compareMode: ProtocolCompareMode) -> Bool {
            switch (self, to) {
            case (.defaultIP, .defaultIP): return true
            case (.ip(let loptions), .ip(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            #if !NETWORK_EMBEDDED
            case (.custom(let loptions), .custom(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            #endif
            case (.defaultIP, .ip(let option)): return option.perProtocolOptions?.isDefault ?? false
            case (.ip(let option), .defaultIP): return option.perProtocolOptions?.isDefault ?? false
            #if !NETWORK_EMBEDDED
            default: return false
            #endif
            }
        }
        public static func == (lhs: ProtocolStack.InternetProtocol, rhs: ProtocolStack.InternetProtocol) -> Bool {
            lhs.isEqual(to: rhs, for: .equal)
        }
        func matches<T>(definition: ProtocolDefinition<T>) -> Bool {
            switch self {
            case .defaultIP: return definition.identifier == IPProtocol.identifier
            case .ip(let options): return options.matches(definition: definition)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(definition: definition)
            #endif
            }
        }
        func matches(identifier: ProtocolIdentifier) -> Bool {
            switch self {
            case .defaultIP: return identifier == IPProtocol.identifier
            case .ip(let options): return options.matches(identifier: identifier)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(identifier: identifier)
            #endif
            }
        }
        func matches(protocolInstance: ProtocolInstanceReference) -> Bool {
            switch self {
            case .defaultIP: return false
            case .ip(let options): return options.matches(protocolInstance: protocolInstance)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(protocolInstance: protocolInstance)
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        func matches(protocolHandle handle: UnsafeRawPointer) -> Bool {
            switch self {
            case .defaultIP: return false
            case .ip(let options): return options.matches(protocolHandle: handle)
            case .custom(let options): return options.matches(protocolHandle: handle)
            }
        }
        var options: AbstractProtocolOptions {
            switch self {
            case .defaultIP: return IPProtocol.options()
            case .ip(let options): return options
            case .custom(let options): return options
            }
        }
        #endif
        var identifier: ProtocolIdentifier {
            switch self {
            case .defaultIP: return IPProtocol.identifier
            case .ip(let options): return options.identifier
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.identifier
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        init(options: AbstractProtocolOptions) {
            if let options = options as? ProtocolOptions<IPProtocol> {
                if let ipOptions = options.perProtocolOptions, ipOptions.isDefault {
                    self = .defaultIP
                } else {
                    self = .ip(options)
                }
            } else {
                self = .custom(options)
            }
        }
        #endif
    }

    public enum TransportProtocol: Hashable {
        case none
        case udp(_ options: ProtocolOptions<UDPProtocol>)
        case tcp(_ options: ProtocolOptions<TCPProtocol>)
        case quic(_ options: ProtocolOptions<QUICProtocol>)
        case quicConnection(_ options: ProtocolOptions<QUICConnectionProtocol>)
        case customIP(_ options: ProtocolOptions<CustomIPProtocol>)
        #if !NETWORK_EMBEDDED
        case custom(_ options: AbstractProtocolOptions)
        #endif

        func deepCopy() -> TransportProtocol {
            switch self {
            case .none: return .none
            case .udp(let options): return .udp(options.deepCopy())
            case .tcp(let options): return .tcp(options.deepCopy())
            case .quic(let options): return .quic(options.deepCopy())
            case .quicConnection(let options): return .quicConnection(options.deepCopy())
            case .customIP(let options): return .customIP(options.deepCopy())
            #if !NETWORK_EMBEDDED
            case .custom(let options): return .custom(options.deepCopy())
            #endif
            }
        }
        public func hash(into hasher: inout Hasher) {
            switch self {
            case .none: hasher.combine(0)
            case .udp(let options): hasher.combine(options.identifier)
            case .tcp(let options): hasher.combine(options.identifier)
            case .quic(let options): hasher.combine(options.identifier)
            case .quicConnection(let options): hasher.combine(options.identifier)
            case .customIP(let options): hasher.combine(options.identifier)
            #if !NETWORK_EMBEDDED
            case .custom(let options): hasher.combine(options.identifier)
            #endif
            }
        }
        func isEqual(to: TransportProtocol, for compareMode: ProtocolCompareMode) -> Bool {
            switch (self, to) {
            case (.none, .none): return true
            case (.udp(let loptions), .udp(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            case (.tcp(let loptions), .tcp(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            case (.quic(let loptions), .quic(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            case (.quicConnection(let loptions), .quicConnection(let roptions)):
                return loptions.isEqual(to: roptions, for: compareMode)
            case (.customIP(let loptions), .customIP(let roptions)):
                return loptions.isEqual(to: roptions, for: compareMode)
            #if !NETWORK_EMBEDDED
            case (.custom(let loptions), .custom(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            #endif
            default:
                return false
            }
        }
        public static func == (lhs: ProtocolStack.TransportProtocol, rhs: ProtocolStack.TransportProtocol) -> Bool {
            lhs.isEqual(to: rhs, for: .equal)
        }
        func matches<T>(definition: ProtocolDefinition<T>) -> Bool {
            switch self {
            case .none: return false
            case .udp(let options): return options.matches(definition: definition)
            case .tcp(let options): return options.matches(definition: definition)
            case .quic(let options): return options.matches(definition: definition)
            case .quicConnection(let options): return options.matches(definition: definition)
            case .customIP(let options): return options.matches(definition: definition)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(definition: definition)
            #endif
            }
        }
        func matches(identifier: ProtocolIdentifier) -> Bool {
            switch self {
            case .none: return false
            case .udp(let options): return options.matches(identifier: identifier)
            case .tcp(let options): return options.matches(identifier: identifier)
            case .quic(let options): return options.matches(identifier: identifier)
            case .quicConnection(let options): return options.matches(identifier: identifier)
            case .customIP(let options): return options.matches(identifier: identifier)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(identifier: identifier)
            #endif
            }
        }
        func matches(protocolInstance: ProtocolInstanceReference) -> Bool {
            switch self {
            case .none: return false
            case .udp(let options): return options.matches(protocolInstance: protocolInstance)
            case .tcp(let options): return options.matches(protocolInstance: protocolInstance)
            case .quic(let options): return options.matches(protocolInstance: protocolInstance)
            case .quicConnection(let options): return options.matches(protocolInstance: protocolInstance)
            case .customIP(let options): return options.matches(protocolInstance: protocolInstance)
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(protocolInstance: protocolInstance)
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        func matches(protocolHandle handle: UnsafeRawPointer) -> Bool {
            switch self {
            case .none: return false
            case .udp(let options): return options.matches(protocolHandle: handle)
            case .tcp(let options): return options.matches(protocolHandle: handle)
            case .quic(let options): return options.matches(protocolHandle: handle)
            case .quicConnection(let options): return options.matches(protocolHandle: handle)
            case .customIP(let options): return options.matches(protocolHandle: handle)
            case .custom(let options): return options.matches(protocolHandle: handle)
            }
        }
        var options: AbstractProtocolOptions? {
            switch self {
            case .none: return nil
            case .udp(let options): return options
            case .tcp(let options): return options
            case .quic(let options): return options
            case .quicConnection(let options): return options
            case .customIP(let options): return options
            case .custom(let options): return options
            }
        }
        #endif
        var identifier: ProtocolIdentifier? {
            switch self {
            case .none: return nil
            case .udp(let options): return options.identifier
            case .tcp(let options): return options.identifier
            case .quic(let options): return options.identifier
            case .quicConnection(let options): return options.identifier
            case .customIP(let options): return options.identifier
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.identifier
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        init(options: AbstractProtocolOptions) {
            if let options = options as? ProtocolOptions<UDPProtocol> {
                self = .udp(options)
            } else if let options = options as? ProtocolOptions<TCPProtocol> {
                self = .tcp(options)
            } else if let options = options as? ProtocolOptions<QUICProtocol> {
                self = .quic(options)
            } else if let options = options as? ProtocolOptions<QUICConnectionProtocol> {
                self = .quicConnection(options)
            } else if let options = options as? ProtocolOptions<CustomIPProtocol> {
                self = .customIP(options)
            } else {
                self = .custom(options)
            }
        }
        #endif
    }

    public enum LinkProtocol: Hashable {
        case none
        #if !NETWORK_EMBEDDED
        case custom(_ options: AbstractProtocolOptions)
        #endif

        func deepCopy() -> LinkProtocol {
            switch self {
            case .none: return .none
            #if !NETWORK_EMBEDDED
            case .custom(let options): return .custom(options.deepCopy())
            #endif
            }
        }
        public func hash(into hasher: inout Hasher) {
            switch self {
            case .none: hasher.combine(0)
            #if !NETWORK_EMBEDDED
            case .custom(let options): hasher.combine(options.identifier)
            #endif
            }
        }
        func isEqual(to: LinkProtocol, for compareMode: ProtocolCompareMode) -> Bool {
            switch (self, to) {
            case (.none, .none): return true
            #if !NETWORK_EMBEDDED
            case (.custom(let loptions), .custom(let roptions)): return loptions.isEqual(to: roptions, for: compareMode)
            default: return false
            #endif
            }
        }
        public static func == (lhs: ProtocolStack.LinkProtocol, rhs: ProtocolStack.LinkProtocol) -> Bool {
            lhs.isEqual(to: rhs, for: .equal)
        }
        func matches<T>(definition: ProtocolDefinition<T>) -> Bool {
            switch self {
            case .none: return false
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(definition: definition)
            #endif
            }
        }
        func matches(identifier: ProtocolIdentifier) -> Bool {
            switch self {
            case .none: return false
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(identifier: identifier)
            #endif
            }
        }
        func matches(protocolInstance: ProtocolInstanceReference) -> Bool {
            switch self {
            case .none: return false
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.matches(protocolInstance: protocolInstance)
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        func matches(protocolHandle handle: UnsafeRawPointer) -> Bool {
            switch self {
            case .none: return false
            case .custom(let options): return options.matches(protocolHandle: handle)
            }
        }
        var options: AbstractProtocolOptions? {
            switch self {
            case .none: return nil
            case .custom(let options): return options
            }
        }
        #endif
        var identifier: ProtocolIdentifier? {
            switch self {
            case .none: return nil
            #if !NETWORK_EMBEDDED
            case .custom(let options): return options.identifier
            #endif
            }
        }
        #if !NETWORK_EMBEDDED
        init(options: AbstractProtocolOptions) {
            self = .custom(options)
        }
        #endif
    }

    var persistentApplication: Deque<ApplicationProtocol> = Deque<ApplicationProtocol>()
    var application: Deque<ApplicationProtocol> = Deque<ApplicationProtocol>()
    public var transport: TransportProtocol? = nil
    public var internet: InternetProtocol? = nil
    public var link: LinkProtocol? = nil

    #if !NETWORK_EMBEDDED
    var internetOptions: AbstractProtocolOptions? {
        get {
            if case .defaultIP = self.internet {
                self.internet = .ip(IPProtocol.options())
            }
            return self.internet?.options ?? nil
        }
    }
    #endif

    func internetOptionsAsIPOptions(mutable: Bool) -> ProtocolOptions<IPProtocol>? {
        if mutable, case .defaultIP = self.internet {
            self.internet = .ip(IPProtocol.options())
        }
        if case .ip(let options) = self.internet {
            return options
        }
        return nil
    }

    var originalProxiedTransport: TransportProtocol? = nil
    var secondaryTransport: TransportProtocol? = nil

    public init(noInternet: Bool = false) {
        if !noInternet {
            internet = .defaultIP
        }
    }

    init(deepCopy other: ProtocolStack) {
        for proto in other.persistentApplication {
            self.persistentApplication.append(proto.deepCopy())
        }
        for proto in other.application {
            self.application.append(proto.deepCopy())
        }
        if let proto = other.transport {
            self.transport = proto.deepCopy()
        }
        if let proto = other.secondaryTransport {
            self.secondaryTransport = proto.deepCopy()
        }
        if let proto = other.originalProxiedTransport {
            self.originalProxiedTransport = proto.deepCopy()
        }
        if let proto = other.internet {
            self.internet = proto.deepCopy()
        }
        if let proto = other.link {
            self.link = proto.deepCopy()
        }
    }

    init(shallowCopy other: ProtocolStack) {
        for proto in other.persistentApplication {
            self.persistentApplication.append(proto)
        }
        for proto in other.application {
            self.application.append(proto)
        }
        if let proto = other.transport {
            self.transport = proto
        }
        if let proto = other.secondaryTransport {
            self.secondaryTransport = proto
        }
        if let proto = other.originalProxiedTransport {
            self.originalProxiedTransport = proto
        }
        if let proto = other.internet {
            self.internet = proto
        }
        if let proto = other.link {
            self.link = proto
        }
    }

    var upperTransportProtocol: TransportProtocol? {
        guard let transport else { return nil }
        switch transport {
        case .udp(let options):
            guard options.useQUICStats else {
                return transport
            }
            var quicOptions: TransportProtocol?
            for applicationProtocol in applicationProtocols {
                if case .quic(let innerQUICOptions) = applicationProtocol {
                    quicOptions = TransportProtocol.quic(innerQUICOptions)
                    // Keep going so that we find the lowest copy of quic in the stack
                }
            }
            return quicOptions
        default:
            return transport
        }
    }

    #if !NETWORK_EMBEDDED
    public func prepend(applicationProtocol: ApplicationProtocol) {
        if persistentApplication.count > 0 {
            // Already have persistent protocols, prepend
            persistentApplication.prepend(applicationProtocol)
            return
        }

        if let options = applicationProtocol.options, options.isPersistent {
            persistentApplication.prepend(applicationProtocol)
        } else {
            application.prepend(applicationProtocol)
        }
    }

    public func append(applicationProtocol: ApplicationProtocol) {
        if let options = applicationProtocol.options, options.isPersistent {
            // Any existing application protocols now must become persistent
            persistentApplication.append(contentsOf: application)
            persistentApplication.append(applicationProtocol)
            application.removeAll()
        } else {
            application.append(applicationProtocol)
        }
    }

    public func prepend(applicationProtocol: AbstractProtocolOptions) {
        prepend(applicationProtocol: ApplicationProtocol(options: applicationProtocol))
    }

    public func append(applicationProtocol: AbstractProtocolOptions) {
        append(applicationProtocol: ApplicationProtocol(options: applicationProtocol))
    }
    #else
    public func prepend(applicationProtocol: ApplicationProtocol) {
        if persistentApplication.count > 0 {
            // Already have persistent protocols, prepend
            persistentApplication.prepend(applicationProtocol)
        } else {
            application.prepend(applicationProtocol)
        }
    }

    public func append(applicationProtocol: ApplicationProtocol) {
        application.append(applicationProtocol)
    }
    #endif

    var applicationProtocolCount: Int {
        persistentApplication.count + application.count
    }

    var applicationProtocols: Deque<ApplicationProtocol> {
        persistentApplication + application
    }

    var hasPersistentApplicationProtocols: Bool {
        !persistentApplication.isEmpty
    }

    func applicationProtocol(at index: Int) -> ApplicationProtocol {
        let persistentSize = persistentApplication.count
        if index < persistentSize {
            return persistentApplication[index]
        }
        return application[index - persistentSize]
    }

    func insert(applicationProtocol: ApplicationProtocol, before: ApplicationProtocol) {
        var insertIndex: Int? = nil
        for index in 0..<persistentApplication.count {
            let proto = persistentApplication[index]
            if proto.isEqual(to: before, for: .equal) {
                insertIndex = index
                break
            }
        }
        if let insertIndex = insertIndex {
            persistentApplication.insert(applicationProtocol, at: insertIndex)
            return
        }
        for index in 0..<application.count {
            let proto = application[index]
            if proto.isEqual(to: before, for: .equal) {
                insertIndex = index
                break
            }
        }
        if let insertIndex = insertIndex {
            application.insert(applicationProtocol, at: insertIndex)
        }
    }

    func insert(applicationProtocol: ApplicationProtocol, after: ApplicationProtocol) {
        var insertIndex: Int? = nil
        for index in 0..<persistentApplication.count {
            let proto = persistentApplication[index]
            if proto.isEqual(to: after, for: .equal) {
                insertIndex = index + 1
                break
            }
        }
        if let insertIndex = insertIndex {
            persistentApplication.insert(applicationProtocol, at: insertIndex)
            return
        }
        for index in 0..<application.count {
            let proto = application[index]
            if proto.isEqual(to: after, for: .equal) {
                insertIndex = index + 1
                break
            }
        }
        if let insertIndex = insertIndex {
            application.insert(applicationProtocol, at: insertIndex)
        }
    }

    func clearApplicationProtocols(persistent: Bool = true, nonPersistent: Bool = true) {
        if persistent {
            persistentApplication.removeAll()
        }
        if nonPersistent {
            application.removeAll()
        }
    }

    func clearTransportProtocols() {
        transport = nil
        secondaryTransport = nil
    }

    func includes<P>(protocolDefinition: ProtocolDefinition<P>) -> Bool {
        for proto in persistentApplication {
            if proto.matches(definition: protocolDefinition) { return true }
        }
        for proto in application {
            if proto.matches(definition: protocolDefinition) { return true }
        }
        if let transport = transport, transport.matches(definition: protocolDefinition) { return true }
        if let secondaryTransport = secondaryTransport, secondaryTransport.matches(definition: protocolDefinition) {
            return true
        }
        if let internet = internet, internet.matches(definition: protocolDefinition) { return true }
        if let link = link, link.matches(definition: protocolDefinition) { return true }
        return false
    }

    func includes(protocolIdentifier: ProtocolIdentifier) -> Bool {
        for proto in persistentApplication {
            if proto.matches(identifier: protocolIdentifier) { return true }
        }
        for proto in application {
            if proto.matches(identifier: protocolIdentifier) { return true }
        }
        if let transport = transport, transport.matches(identifier: protocolIdentifier) { return true }
        if let secondaryTransport = secondaryTransport, secondaryTransport.matches(identifier: protocolIdentifier) {
            return true
        }
        if let internet = internet, internet.matches(identifier: protocolIdentifier) { return true }
        if let link = link, link.matches(identifier: protocolIdentifier) { return true }
        return false
    }

    func remove<P>(protocolDefinition: ProtocolDefinition<P>) {
        persistentApplication.removeAll { $0.matches(definition: protocolDefinition) }
        application.removeAll { $0.matches(definition: protocolDefinition) }
        if let transport = transport, transport.matches(definition: protocolDefinition) { self.transport = nil }
        if let secondaryTransport = secondaryTransport, secondaryTransport.matches(definition: protocolDefinition) {
            self.secondaryTransport = nil
        }
        if let internet = internet, internet.matches(definition: protocolDefinition) { self.internet = nil }
        if let link = link, link.matches(definition: protocolDefinition) { self.link = nil }
    }

    func remove(protocolIdentifier: ProtocolIdentifier) {
        persistentApplication.removeAll { $0.matches(identifier: protocolIdentifier) }
        application.removeAll { $0.matches(identifier: protocolIdentifier) }
        if let transport = transport, transport.matches(identifier: protocolIdentifier) { self.transport = nil }
        if let secondaryTransport = secondaryTransport, secondaryTransport.matches(identifier: protocolIdentifier) {
            self.secondaryTransport = nil
        }
        if let internet = internet, internet.matches(identifier: protocolIdentifier) { self.internet = nil }
        if let link = link, link.matches(identifier: protocolIdentifier) { self.link = nil }
    }

    #if !NETWORK_EMBEDDED
    func replace<T>(protocolDefinition: ProtocolDefinition<T>, with newOptions: AbstractProtocolOptions) {
        var newArray = Deque<ApplicationProtocol>()
        for proto in persistentApplication {
            if proto.matches(definition: protocolDefinition) || proto.matches(identifier: newOptions.identifier) {
                newArray.append(ApplicationProtocol(options: newOptions))
            } else {
                newArray.append(proto)
            }
        }
        persistentApplication = newArray

        newArray = Deque<ApplicationProtocol>()
        for proto in application {
            if proto.matches(definition: protocolDefinition) || proto.matches(identifier: newOptions.identifier) {
                newArray.append(ApplicationProtocol(options: newOptions))
            } else {
                newArray.append(proto)
            }
        }
        application = newArray

        if let transport = transport,
            transport.matches(definition: protocolDefinition) || transport.matches(identifier: newOptions.identifier)
        {
            self.transport = TransportProtocol(options: newOptions)
        }
        if let secondaryTransport = secondaryTransport,
            secondaryTransport.matches(definition: protocolDefinition)
                || secondaryTransport.matches(identifier: newOptions.identifier)
        {
            self.secondaryTransport = TransportProtocol(options: newOptions)
        }
        if let internet = internet,
            internet.matches(definition: protocolDefinition) || internet.matches(identifier: newOptions.identifier)
        {
            self.internet = InternetProtocol(options: newOptions)
        }
        if let link = link,
            link.matches(definition: protocolDefinition) || link.matches(identifier: newOptions.identifier)
        {
            self.link = LinkProtocol(options: newOptions)
        }
    }

    internal func protocolOptionsWithLevel(for handle: UnsafeRawPointer) -> (AbstractProtocolOptions, ProtocolLevel)? {
        for applicationProtocol in self.persistentApplication {
            if applicationProtocol.matches(protocolHandle: handle),
                let options = applicationProtocol.options
            {
                return (options, .application)
            }
        }

        for applicationProtocol in self.application {
            if applicationProtocol.matches(protocolHandle: handle),
                let options = applicationProtocol.options
            {
                return (options, .application)
            }
        }

        if let transportProtocol = self.transport,
            transportProtocol.matches(protocolHandle: handle),
            let options = transportProtocol.options
        {
            return (options, ProtocolLevel.transport)
        }

        if let transportProtocol = self.secondaryTransport,
            transportProtocol.matches(protocolHandle: handle),
            let options = transportProtocol.options
        {
            return (options, .transport)
        }

        if let internetProtocol = self.internet,
            internetProtocol.matches(protocolHandle: handle)
        {
            return (internetProtocol.options, .internet)
        }

        if let linkProtocol = self.link,
            linkProtocol.matches(protocolHandle: handle),
            let options = linkProtocol.options
        {
            return (options, .link)
        }
        return nil
    }

    internal func protocolOptions(for identifier: ProtocolIdentifier) -> AbstractProtocolOptions? {
        for applicationProtocol in self.persistentApplication {
            if applicationProtocol.matches(identifier: identifier) {
                return applicationProtocol.options
            }
        }

        for applicationProtocol in self.application {
            if applicationProtocol.matches(identifier: identifier) {
                return applicationProtocol.options
            }
        }

        if let transportProtocol = self.transport, transportProtocol.matches(identifier: identifier) {
            return transportProtocol.options
        }

        if let transportProtocol = self.secondaryTransport, transportProtocol.matches(identifier: identifier) {
            return transportProtocol.options
        }

        if let internetProtocol = self.internet, internetProtocol.matches(identifier: identifier) {
            return internetProtocol.options
        }

        if let linkProtocol = self.link, linkProtocol.matches(identifier: identifier) {
            return linkProtocol.options
        }
        return nil
    }

    internal func protocolOptions(for instance: ProtocolInstanceReference) -> AbstractProtocolOptions? {
        for applicationProtocol in self.persistentApplication {
            if applicationProtocol.matches(protocolInstance: instance) {
                return applicationProtocol.options
            }
        }

        for applicationProtocol in self.application {
            if applicationProtocol.matches(protocolInstance: instance) {
                return applicationProtocol.options
            }
        }

        if let transportProtocol = self.transport, transportProtocol.matches(protocolInstance: instance) {
            return transportProtocol.options
        }

        if let transportProtocol = self.secondaryTransport, transportProtocol.matches(protocolInstance: instance) {
            return transportProtocol.options
        }

        if let internetProtocol = self.internet, internetProtocol.matches(protocolInstance: instance) {
            return internetProtocol.options
        }

        if let linkProtocol = self.link, linkProtocol.matches(protocolInstance: instance) {
            return linkProtocol.options
        }
        return nil
    }

    internal func protocolOptions(for handle: UnsafeRawPointer) -> AbstractProtocolOptions? {
        for applicationProtocol in self.persistentApplication {
            if applicationProtocol.matches(protocolHandle: handle) {
                return applicationProtocol.options
            }
        }

        for applicationProtocol in self.application {
            if applicationProtocol.matches(protocolHandle: handle) {
                return applicationProtocol.options
            }
        }

        if let transportProtocol = self.transport, transportProtocol.matches(protocolHandle: handle) {
            return transportProtocol.options
        }

        if let transportProtocol = self.secondaryTransport, transportProtocol.matches(protocolHandle: handle) {
            return transportProtocol.options
        }

        if let internetProtocol = self.internet, internetProtocol.matches(protocolHandle: handle) {
            return internetProtocol.options
        }

        if let linkProtocol = self.link, linkProtocol.matches(protocolHandle: handle) {
            return linkProtocol.options
        }
        return nil
    }

    internal func setProtocolInstance(
        _ instance: ProtocolInstanceReference,
        for handle: UnsafeRawPointer
    ) {
        for applicationProtocol in self.persistentApplication {
            applicationProtocol.options?.setProtocolInstance(instance, for: handle)
        }

        for applicationProtocol in self.application {
            applicationProtocol.options?.setProtocolInstance(instance, for: handle)
        }

        self.transport?.options?.setProtocolInstance(instance, for: handle)
        self.secondaryTransport?.options?.setProtocolInstance(instance, for: handle)
        self.internet?.options.setProtocolInstance(instance, for: handle)
        self.link?.options?.setProtocolInstance(instance, for: handle)
    }
    #endif

    func isEqual(to other: ProtocolStack, for compareMode: ProtocolCompareMode) -> Bool {
        guard self.persistentApplication.count == other.persistentApplication.count else {
            return false
        }
        for index in 0..<self.persistentApplication.count {
            let optionsl = self.persistentApplication[index]
            let optionsr = other.persistentApplication[index]
            if !optionsl.isEqual(to: optionsr, for: compareMode) {
                return false
            }
        }
        guard self.application.count == other.application.count else {
            return false
        }
        for index in 0..<self.application.count {
            let optionsl = self.application[index]
            let optionsr = other.application[index]
            if !optionsl.isEqual(to: optionsr, for: compareMode) {
                return false
            }
        }
        if let optionsl = self.transport, let optionsr = other.transport {
            if !optionsl.isEqual(to: optionsr, for: compareMode) {
                return false
            }
        } else if self.transport != nil || other.transport != nil {
            return false
        }
        if let optionsl = self.originalProxiedTransport, let optionsr = other.originalProxiedTransport {
            if !optionsl.isEqual(to: optionsr, for: compareMode) {
                return false
            }
        } else if self.originalProxiedTransport != nil || other.originalProxiedTransport != nil {
            return false
        }
        // TODO: Note that secondary transport it not checked (and wasn't in C). Mistake?
        if let optionsl = self.internet, let optionsr = other.internet {
            if !optionsl.isEqual(to: optionsr, for: compareMode) {
                return false
            }
        } else if self.internet != nil || other.internet != nil {
            return false
        }
        return true
    }

    static public func == (lhs: ProtocolStack, rhs: ProtocolStack) -> Bool {
        lhs.isEqual(to: rhs, for: .equal)
    }

    public func hash(into hasher: inout Hasher) {
        for proto in persistentApplication {
            hasher.combine(proto.identifier)
        }
        for proto in application {
            hasher.combine(proto.identifier)
        }
        hasher.combine(transport?.identifier)
        hasher.combine(secondaryTransport?.identifier)
        hasher.combine(originalProxiedTransport?.identifier)
        hasher.combine(internet?.identifier)
        hasher.combine(link?.identifier)
    }
}
