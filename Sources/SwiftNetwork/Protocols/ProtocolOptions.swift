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
    /// The configuration that the options of every protocol carry alongside their per-protocol options.
    struct CommonConfiguration {
        var proxyEndpoint: Endpoint? = nil
        var proxyNextHops: [Endpoint]? = nil
        var overrideStackEndpoint: Bool = false
        var prohibitJoining: Bool = false
        #if NETWORK_PRIVATE
        var privateStorage = ProtocolOptionsPrivateStorage()
        #endif
    }

    /// The state a running connection attaches to these particular options. It is not configuration, so a copy of the
    /// options starts without it.
    struct LiveState {
        var associatedProtocolInstance: AssociatedProtocolInstance? = nil
        var topID: Int? = nil
        var logIDNumber: Int? = nil
        var logIDString: String? = nil
    }

    internal enum AssociatedProtocolInstance {
        case instance(_ instance: InstanceIdentifier)
        #if !NETWORK_EMBEDDED
        case legacyHandle(_ handle: UnsafeRawPointer)
        #endif
    }

    // `ProtocolOptions` keeps the common configuration and the live state together with its per-protocol options, and
    // overrides the accessors below to reach them. Each `body` must not read or change these options.
    var commonConfiguration: CommonConfiguration {
        fatalError("Unimplemented")
    }

    func modifyCommonConfiguration(_ body: (_ configuration: inout CommonConfiguration) -> Void) {
        fatalError("Unimplemented")
    }

    var liveState: LiveState {
        fatalError("Unimplemented")
    }

    func modifyLiveState(_ body: (_ liveState: inout LiveState) -> Void) {
        fatalError("Unimplemented")
    }

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

    public func matches(protocolInstance: InstanceIdentifier) -> Bool {
        guard let instance = self.protocolInstance else {
            return false
        }
        return protocolInstance == instance
    }

    public var protocolInstance: InstanceIdentifier? {
        get {
            switch self.liveState.associatedProtocolInstance {
            case .instance(let instance):
                return instance
            #if !NETWORK_EMBEDDED
            case .legacyHandle(_):
                return nil
            #endif
            case .none:
                return nil
            }
        }
        set {
            self.modifyLiveState { $0.associatedProtocolInstance = newValue.map { .instance($0) } }
        }
    }

    #if !NETWORK_EMBEDDED
    public func matches(protocolHandle handle: UnsafeRawPointer) -> Bool {
        guard let protocolHandle = self.protocolHandle else {
            return false
        }
        return protocolHandle == handle
    }

    public var protocolHandle: UnsafeRawPointer? {
        get {
            switch self.liveState.associatedProtocolInstance {
            case .instance(_):
                return nil
            case .legacyHandle(let handle):
                return handle
            case .none:
                return nil
            }
        }
        set {
            self.modifyLiveState { $0.associatedProtocolInstance = newValue.map { .legacyHandle($0) } }
        }
    }

    public func setProtocolInstance(
        _ instance: InstanceIdentifier,
        for handle: UnsafeRawPointer
    ) {
        self.modifyLiveState { liveState in
            guard case .legacyHandle(let existingHandle) = liveState.associatedProtocolInstance,
                existingHandle == handle
            else {
                // Ignore
                return
            }
            liveState.associatedProtocolInstance = .instance(instance)
        }
    }

    public func inheritInstance(from existing: AbstractProtocolOptions) {
        fatalError("Unimplemented")
    }
    #endif

    public func setProtocolInstance(_ identifier: InstanceIdentifier) {
        self.protocolInstance = identifier
    }

    public var identifier: ProtocolIdentifier

    public var topID: Int? {
        get { self.liveState.topID }
        set { self.modifyLiveState { $0.topID = newValue } }
    }
    public var logIDNumber: Int? {
        get { self.liveState.logIDNumber }
        set { self.modifyLiveState { $0.logIDNumber = newValue } }
    }
    public var logIDString: String? {
        get { self.liveState.logIDString }
        set { self.modifyLiveState { $0.logIDString = newValue } }
    }

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

    public var proxyEndpoint: Endpoint? {
        get { self.commonConfiguration.proxyEndpoint }
        set { self.modifyCommonConfiguration { $0.proxyEndpoint = newValue } }
    }
    public var proxyNextHops: [Endpoint]? {
        get { self.commonConfiguration.proxyNextHops }
        set { self.modifyCommonConfiguration { $0.proxyNextHops = newValue } }
    }

    public func addProxyNextHop(_ nextHop: Endpoint) {
        self.modifyCommonConfiguration { configuration in
            if configuration.proxyNextHops == nil {
                configuration.proxyNextHops = [nextHop]
            } else {
                configuration.proxyNextHops!.append(nextHop)
            }
        }
    }

    public func setProxyEndpoint(_ proxyEndpoint: Endpoint?, overrideStackEndpoint: Bool) {
        self.modifyCommonConfiguration { configuration in
            configuration.proxyEndpoint = proxyEndpoint
            configuration.overrideStackEndpoint = overrideStackEndpoint
        }
    }

    #if NETWORK_PRIVATE
    var privateStorage: ProtocolOptionsPrivateStorage {
        get { self.commonConfiguration.privateStorage }
        set { self.modifyCommonConfiguration { $0.privateStorage = newValue } }
    }

    public var cProtocolDefinition: nw_protocol_definition_t? { nil }
    #endif

    public var overrideStackEndpoint: Bool {
        get { self.commonConfiguration.overrideStackEndpoint }
        set { self.modifyCommonConfiguration { $0.overrideStackEndpoint = newValue } }
    }
    public var prohibitJoining: Bool {
        get { self.commonConfiguration.prohibitJoining }
        set { self.modifyCommonConfiguration { $0.prohibitJoining = newValue } }
    }

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
    struct State {
        var perProtocolOptions: P.Options?
        var common = CommonConfiguration()
        var live = LiveState()
    }

    private var state: State

    /// The per-protocol options as a value. Change them with `modifyPerProtocolOptions`, or replace them with
    /// `replacePerProtocolOptions`.
    ///
    /// Changing one field through the setter, as in `options.perProtocolOptions?.field = value`, reads and writes the
    /// options in two steps, so a change made in between is lost. The setter stays for SPI clients that still use it.
    public var perProtocolOptions: P.Options? {
        get { self.state.perProtocolOptions }
        set { self.state.perProtocolOptions = newValue }
    }

    /// Changes the per-protocol options in place, as one step, if there are any. `body` must not touch these options.
    /// Returns the value `body` returns, or `nil` if there are no per-protocol options.
    public func modifyPerProtocolOptions<Result, Failure: Error>(
        _ body: (_ perProtocolOptions: inout P.Options) throws(Failure) -> Result
    ) throws(Failure) -> Result? {
        guard self.state.perProtocolOptions != nil else {
            return nil
        }
        return try body(&self.state.perProtocolOptions!)
    }

    /// Changes the per-protocol options in place, as one step, if there are any. `body` must not touch these options.
    public func modifyPerProtocolOptions<Failure: Error>(
        _ body: (_ perProtocolOptions: inout P.Options) throws(Failure) -> Void
    ) throws(Failure) {
        guard self.state.perProtocolOptions != nil else {
            return
        }
        try body(&self.state.perProtocolOptions!)
    }

    /// Replaces the per-protocol options, as one step.
    public func replacePerProtocolOptions(_ perProtocolOptions: P.Options?) {
        self.state.perProtocolOptions = perProtocolOptions
    }

    override var commonConfiguration: CommonConfiguration {
        self.state.common
    }

    override func modifyCommonConfiguration(_ body: (_ configuration: inout CommonConfiguration) -> Void) {
        body(&self.state.common)
    }

    override var liveState: LiveState {
        self.state.live
    }

    override func modifyLiveState(_ body: (_ liveState: inout LiveState) -> Void) {
        body(&self.state.live)
    }

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

    public init(protocolIdentifier: ProtocolIdentifier, perProtocolOptions: P.Options?) {
        self.state = State(perProtocolOptions: perProtocolOptions)
        super.init(identifier: protocolIdentifier)
    }

    public override func deepCopy() -> Self {
        Self(from: self)
    }

    /// Copies the configuration of `other`. The copy starts without `other`'s live state.
    public init(from other: ProtocolOptions) {
        let otherState = other.state
        var common = otherState.common
        #if NETWORK_PRIVATE
        common.privateStorage = otherState.common.privateStorage.copy()
        #endif
        self.state = State(perProtocolOptions: otherState.perProtocolOptions?.deepCopy(), common: common)
        super.init(identifier: other.identifier)
    }

    public init?(definition: ProtocolDefinition<P>, serializedBytes: [UInt8]) {
        guard let perProtocolOptions = definition.newPerProtocolOptions(from: serializedBytes) else { return nil }
        self.state = State(perProtocolOptions: perProtocolOptions)
        super.init(identifier: definition.identifier)
    }

    public func isEqual(to other: ProtocolOptions, for compareMode: ProtocolCompareMode) -> Bool {
        let selfState = self.state
        let otherState = other.state
        guard selfState.common.proxyEndpoint == otherState.common.proxyEndpoint,
            selfState.common.overrideStackEndpoint == otherState.common.overrideStackEndpoint
        else {
            return false
        }

        #if NETWORK_PRIVATE
        guard selfState.common.privateStorage == otherState.common.privateStorage else {
            return false
        }
        #endif

        // Prohibit joining is deliberately not compared, it is up to protocols themselves to enforce as they desire.
        // This allows protocols within the stack to set prohibit joining on protocol options for other protocols, while
        // new incoming connections that would like to join do not need to match that setting.
        guard self.identifier == other.identifier else {
            return false
        }
        if let lh = selfState.perProtocolOptions, let rh = otherState.perProtocolOptions {
            return lh.isEqual(to: rh, for: compareMode)
        } else if selfState.perProtocolOptions == nil, otherState.perProtocolOptions == nil {
            return true
        }
        return false
    }

    #if !NETWORK_EMBEDDED
    public override func inheritInstance(from existing: AbstractProtocolOptions) {
        guard let existing = existing as? ProtocolOptions else {
            return
        }
        let associatedProtocolInstance = existing.liveState.associatedProtocolInstance
        self.modifyLiveState { $0.associatedProtocolInstance = associatedProtocolInstance }
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
        self.modifyLiveState { liveState in
            liveState.logIDNumber = protocolLogIDNumber
            liveState.logIDString = "[\(prefix)\(parent):\(protocolLogIDNumber)]"
        }
    }

    static func inheritLogID(from: ProtocolOptions, to: ProtocolOptions) {
        let liveState = from.liveState
        to.modifyLiveState { toLiveState in
            toLiveState.logIDNumber = liveState.logIDNumber
            toLiveState.logIDString = liveState.logIDString
        }
    }
}
