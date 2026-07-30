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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum ProtocolCompareMode: CustomStringConvertible {
    case equal  // Full equality
    case association  // Should protocol caches and other stored data be shared?
    case joining  // Should one connection be allowed to join another?
    case joiningProxy  // Should one connection be allowed to share a connection to a proxy with another?
    case joiningPrivacyProxy  // Should one connection be allowed to share a connection to a privacy proxy with another?
    case joiningCompanionProxy  // Should connections be allowed to share a connection to a companion proxy?

    public var description: String {
        switch self {
        case .equal: return "equal"
        case .association: return "association"
        case .joining: return "joining"
        case .joiningProxy: return "joining proxy"
        case .joiningPrivacyProxy: return "joining privacy proxy"
        case .joiningCompanionProxy: return "joining companion proxy"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol PerProtocolOptions: Equatable {
    func serialize() -> [UInt8]?
    var serializeInParameters: Bool { get }
    func deepCopy() -> Self
    func isEqual(to other: Self, for: ProtocolCompareMode) -> Bool
    #if NETWORK_PRIVATE
    var cProtocolDefinition: nw_protocol_definition_t? { get }
    #endif
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public class AbstractProtocolOptions: PerProtocolOptions, Hashable {
    public func isEqual(to: AbstractProtocolOptions, for: ProtocolCompareMode) -> Bool {
        fatalError("Unimplemented")
    }

    public static func == (lhs: AbstractProtocolOptions, rhs: AbstractProtocolOptions) -> Bool {
        lhs.isEqual(to: rhs, for: .equal)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.identifier)
    }

    final public func matches<T>(definition: ProtocolDefinition<T>) -> Bool {
        self.identifier == definition.identifier
    }

    public func matches(identifier: ProtocolIdentifier) -> Bool {
        self.identifier == identifier
    }

    public func matches(protocolInstance: ProtocolInstanceReference) -> Bool {
        guard let instance = self.protocolInstance else {
            return false
        }
        return protocolInstance == instance
    }

    #if !NETWORK_EMBEDDED
    public func matches(protocolHandle handle: UnsafeRawPointer) -> Bool {
        guard let protocolHandle = self.protocolHandle else {
            return false
        }
        return protocolHandle == handle
    }

    internal enum AssociatedProtocolInstance {
        case instance(_ instance: ProtocolInstanceReference)
        case legacyHandle(_ handle: UnsafeRawPointer)
    }
    internal var associatedProtocolInstance: AssociatedProtocolInstance? = nil

    public var protocolInstance: ProtocolInstanceReference? {
        get {
            switch associatedProtocolInstance {
            case .instance(let instance):
                return instance
            case .legacyHandle(_):
                return nil
            case .none:
                return nil
            }
        }
        set {
            guard let newValue = newValue else {
                associatedProtocolInstance = nil
                return
            }
            associatedProtocolInstance = .instance(newValue)
        }
    }

    public var protocolHandle: UnsafeRawPointer? {
        get {
            switch associatedProtocolInstance {
            case .instance(_):
                return nil
            case .legacyHandle(let handle):
                return handle
            case .none:
                return nil
            }
        }
        set {
            guard let newValue = newValue else {
                associatedProtocolInstance = nil
                return
            }
            associatedProtocolInstance = .legacyHandle(newValue)
        }
    }

    public func setProtocolInstance(
        _ instance: ProtocolInstanceReference,
        for handle: UnsafeRawPointer
    ) {
        guard case .legacyHandle(let existingHandle) = associatedProtocolInstance,
            existingHandle == handle
        else {
            // Ignore
            return
        }
        associatedProtocolInstance = .instance(instance)
    }

    public func inheritInstance(from existing: AbstractProtocolOptions) {
        fatalError("Unimplemented")
    }
    #else
    public var protocolInstance: ProtocolInstanceReference? = nil
    #endif

    public func setProtocolInstance(_ reference: ProtocolInstanceReference) {
        self.protocolInstance = reference
    }

    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        nil
    }

    public var identifier: ProtocolIdentifier

    public var topID: Int? = nil
    public var logIDNumber: Int? = nil
    public var logIDString: String? = nil

    public var serializeInParameters: Bool {
        fatalError("Unimplemented")
    }

    public func serialize() -> [UInt8]? {
        fatalError("Unimplemented")
    }

    fileprivate init(identifier: ProtocolIdentifier) {
        self.identifier = identifier
    }

    public func deepCopy() -> Self {
        fatalError("Unimplemented")
    }

    public var proxyEndpoint: Endpoint? = nil
    public var proxyNextHops: [Endpoint]? = nil

    public func addProxyNextHop(_ nextHop: Endpoint) {
        if self.proxyNextHops == nil {
            self.proxyNextHops = [Endpoint]()
        }
        if self.proxyNextHops != nil {
            self.proxyNextHops!.append(nextHop)
        }
    }

    public func setProxyEndpoint(_ proxyEndpoint: Endpoint?, overrideStackEndpoint: Bool) {
        self.proxyEndpoint = proxyEndpoint
        self.overrideStackEndpoint = overrideStackEndpoint
    }

    #if NETWORK_PRIVATE
    var privateStorage = ProtocolOptionsPrivateStorage()

    public var cProtocolDefinition: nw_protocol_definition_t? { nil }
    #endif

    public var overrideStackEndpoint: Bool = false
    public var prohibitJoining: Bool = false

    public var isPersistent: Bool {
        self.identifier.level == .persistentApplication
    }

    #if !NETWORK_EMBEDDED
    var typeErasedPerProtocolOptions: Any? { nil }
    #endif
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class ProtocolOptions<P: NetworkProtocol>: AbstractProtocolOptions {
    public var perProtocolOptions: P.Options? = nil

    #if !NETWORK_EMBEDDED
    override var typeErasedPerProtocolOptions: Any? { perProtocolOptions }
    #endif

    #if NETWORK_PRIVATE
    public override var cProtocolDefinition: nw_protocol_definition_t? { perProtocolOptions?.cProtocolDefinition }
    #endif

    public override var serializeInParameters: Bool {
        perProtocolOptions?.serializeInParameters ?? false
    }

    public override func serialize() -> [UInt8]? {
        perProtocolOptions?.serialize() ?? nil
    }

    public override func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        P().newProtocolInstance(context: context)
    }

    public init(protocolIdentifier: ProtocolIdentifier, perProtocolOptions: P.Options?) {
        self.perProtocolOptions = perProtocolOptions
        super.init(identifier: protocolIdentifier)
    }

    public override func deepCopy() -> Self {
        Self(from: self)
    }

    public init(from other: ProtocolOptions) {
        self.perProtocolOptions = other.perProtocolOptions?.deepCopy()
        super.init(identifier: other.identifier)

        self.proxyEndpoint = other.proxyEndpoint
        self.proxyNextHops = other.proxyNextHops

        #if NETWORK_PRIVATE
        self.privateStorage = other.privateStorage.copy()
        #endif

        self.overrideStackEndpoint = other.overrideStackEndpoint
        self.prohibitJoining = other.prohibitJoining
    }

    public init?(definition: ProtocolDefinition<P>, serializedBytes: [UInt8]) {
        self.perProtocolOptions = definition.newPerProtocolOptions(from: serializedBytes)
        if self.perProtocolOptions == nil { return nil }
        super.init(identifier: definition.identifier)
    }

    public func isEqual(to other: ProtocolOptions, for compareMode: ProtocolCompareMode) -> Bool {
        guard self.proxyEndpoint == other.proxyEndpoint, self.overrideStackEndpoint == other.overrideStackEndpoint
        else {
            return false
        }

        #if NETWORK_PRIVATE
        guard self.privateStorage == other.privateStorage else {
            return false
        }
        #endif

        // Prohibit joining is deliberately not compared, it is up to protocols themselves to enforce as they desire.
        // This allows protocols within the stack to set prohibit joining on protocol options for other protocols, while
        // new incoming connections that would like to join do not need to match that setting.
        guard self.identifier == other.identifier else {
            return false
        }
        if let lh = self.perProtocolOptions, let rh = other.perProtocolOptions {
            return lh.isEqual(to: rh, for: compareMode)
        } else if self.perProtocolOptions == nil, other.perProtocolOptions == nil {
            return true
        }
        return false
    }

    #if !NETWORK_EMBEDDED
    public override func inheritInstance(from existing: AbstractProtocolOptions) {
        guard let existing = existing as? ProtocolOptions else {
            return
        }
        associatedProtocolInstance = existing.associatedProtocolInstance
    }

    public override func isEqual(to other: AbstractProtocolOptions, for compareMode: ProtocolCompareMode) -> Bool {
        guard let other = other as? ProtocolOptions else {
            return false
        }
        return isEqual(to: other, for: compareMode)
    }
    #endif

    public static func == (lhs: ProtocolOptions, rhs: ProtocolOptions) -> Bool {
        lhs.isEqual(to: rhs, for: .equal)
    }

    public func setLogID(prefix: String = "C", parent: String, protocolLogIDNumber: Int) {
        self.logIDNumber = protocolLogIDNumber
        self.logIDString = "[\(prefix)\(parent):\(protocolLogIDNumber)]"
    }

    static func inheritLogID(from: ProtocolOptions, to: ProtocolOptions) {
        to.logIDNumber = from.logIDNumber
        to.logIDString = from.logIDString
    }
}
