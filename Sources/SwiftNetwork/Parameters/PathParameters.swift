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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct PathParameters: Hashable, CustomStringConvertible {
    struct ProcessPathValue: Hashable, Sendable {
        // Parameters that influence path selection for process delegation, by value, that
        // can be compared and copied.
        // These items are used for compatibility evaluation for most modes.

        // processUUID is the actual process UUID. effectiveProcessUUID is the effective
        // process UUID. Use the effective process UUID whenever evaluating work
        // to make sure delegation is taken into account.
        var processUUID: SystemUUID
        var effectiveProcessUUID: SystemUUID
        var personaUUID: SystemUUID?

        var delegatedUniquePID: UInt64? = 0

        var pid: Int32 = 0
        var uid: UInt32 = 0

        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        static let sharedProcessInfo: (Int32, UInt32, SystemUUID) = getProcessInfo()
        #elseif !NETWORK_STANDALONE
        // This function gets the current process info
        static func getProcessInfo() -> (Int32, UInt32, SystemUUID) {
            (getpid(), getuid(), SystemUUID.empty)
        }
        // This var stores the process info the first time it is called. Be sure to only
        // call it once we are not going to be able to fork.
        static let sharedProcessInfo: (Int32, UInt32, SystemUUID) = getProcessInfo()
        init() {
            (self.pid, self.uid, self.processUUID) = PathParameters.ProcessPathValue.sharedProcessInfo
            effectiveProcessUUID = processUUID
        }
        #else
        init() {
            self.pid = 0
            self.uid = 0
            self.processUUID = SystemUUID.empty
            effectiveProcessUUID = processUUID
        }
        #endif
    }

    struct PathValue: Hashable, Sendable {
        // Parameters that influence path selection, by value, that can be compared and copied
        // These items are used for compatibility evaluation
        var trafficClass: UInt32 = 0
        var requiredInterfaceType: InterfaceType?
        var requiredInterfaceSubtype: InterfaceSubtype?
        var nextHopRequiredInterfaceType: InterfaceType?
        var nextHopRequiredInterfaceSubtype: InterfaceSubtype?
        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        var pathValuePrivate = PathValuePrivate()
        #endif

        struct Flags: OptionSet, Hashable {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            let rawValue: UInt8
            static let prohibitExpensivePaths = Flags(rawValue: 1 << 0)
            static let prohibitConstrainedPaths = Flags(rawValue: 1 << 1)
            static let allowSocketAccess = Flags(rawValue: 1 << 2)
            static let privacyProxyFailClosed = Flags(rawValue: 1 << 3)
            static let nextHop = Flags(rawValue: 1 << 4)
            static let privacyProxyStrictFailClosed = Flags(rawValue: 1 << 5)
        }
        var flags: Flags = Flags(rawValue: 0)

        var prohibitExpensivePaths: Bool {
            get { flags.contains(.prohibitExpensivePaths) }
            set { if newValue { flags.insert(.prohibitExpensivePaths) } else { flags.remove(.prohibitExpensivePaths) } }
        }

        var prohibitConstrainedPaths: Bool {
            get { flags.contains(.prohibitConstrainedPaths) }
            set {
                if newValue { flags.insert(.prohibitConstrainedPaths) } else { flags.remove(.prohibitConstrainedPaths) }
            }
        }

        var allowSocketAccess: Bool {
            get { flags.contains(.allowSocketAccess) }
            set { if newValue { flags.insert(.allowSocketAccess) } else { flags.remove(.allowSocketAccess) } }
        }

        var privacyProxyFailClosed: Bool {
            get { flags.contains(.privacyProxyFailClosed) }
            set { if newValue { flags.insert(.privacyProxyFailClosed) } else { flags.remove(.privacyProxyFailClosed) } }
        }

        var privacyProxyStrictFailClosed: Bool {
            get { flags.contains(.privacyProxyStrictFailClosed) }
            set {
                if newValue {
                    flags.insert(.privacyProxyStrictFailClosed)
                } else {
                    flags.remove(.privacyProxyStrictFailClosed)
                }
            }
        }

        var nextHop: Bool {
            get { flags.contains(.nextHop) }
            set { if newValue { flags.insert(.nextHop) } else { flags.remove(.nextHop) } }
        }
    }

    struct JoinablePathValue: Hashable, Sendable {
        // Parameters that influence path selection but do not influence compatibility when joining,
        // by value, that can be compared and copied
        // These items are not used for compatibility evaluation for joining protocol stacks.

        var multipathService: Parameters.MultipathServiceType = .disabled
        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        var joinablePathValuePrivate = JoinablePathValuePrivate()
        #endif

        struct Flags: OptionSet, Hashable {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            let rawValue: UInt8
            static let noProxy = Flags(rawValue: 1 << 0)
            static let noWakeFromSleep = Flags(rawValue: 1 << 1)
            static let preferNoProxy = Flags(rawValue: 1 << 2)
            static let noProxyPathSelection = Flags(rawValue: 1 << 3)
            static let privacyProxyFailClosedForUnreachableHosts = Flags(rawValue: 1 << 4)
            static let proxyApplied = Flags(rawValue: 1 << 5)
            static let systemProxy = Flags(rawValue: 1 << 6)
            static let noFallback = Flags(rawValue: 1 << 7)
        }
        var flags: Flags = Flags(rawValue: 0)
        var noProxy: Bool {
            get { flags.contains(.noProxy) }
            set { if newValue { flags.insert(.noProxy) } else { flags.remove(.noProxy) } }
        }
        var noWakeFromSleep: Bool {
            get { flags.contains(.noWakeFromSleep) }
            set { if newValue { flags.insert(.noWakeFromSleep) } else { flags.remove(.noWakeFromSleep) } }
        }
        var preferNoProxy: Bool {
            get { flags.contains(.preferNoProxy) }
            set { if newValue { flags.insert(.preferNoProxy) } else { flags.remove(.preferNoProxy) } }
        }
        var noProxyPathSelection: Bool {
            get { flags.contains(.noProxyPathSelection) }
            set { if newValue { flags.insert(.noProxyPathSelection) } else { flags.remove(.noProxyPathSelection) } }
        }
        var privacyProxyFailClosedForUnreachableHosts: Bool {
            get { flags.contains(.privacyProxyFailClosedForUnreachableHosts) }
            set {
                if newValue {
                    flags.insert(.privacyProxyFailClosedForUnreachableHosts)
                } else {
                    flags.remove(.privacyProxyFailClosedForUnreachableHosts)
                }
            }
        }
        var proxyApplied: Bool {
            get { flags.contains(.proxyApplied) }
            set { if newValue { flags.insert(.proxyApplied) } else { flags.remove(.proxyApplied) } }
        }
        var systemProxy: Bool {
            get { flags.contains(.systemProxy) }
            set { if newValue { flags.insert(.systemProxy) } else { flags.remove(.systemProxy) } }
        }
        var noFallback: Bool {
            get { flags.contains(.noFallback) }
            set { if newValue { flags.insert(.noFallback) } else { flags.remove(.noFallback) } }
        }
    }

    var processPathValue = ProcessPathValue()
    var pathValue = PathValue()
    var joinablePathValue = JoinablePathValue()

    struct InterfacePreferenceValues: Hashable {
        final class InterfacePreferenceValuesBacking: Hashable {
            struct Storage: Hashable {
                var requiredInterface: Interface?
                var prohibitedInterfaceTypes: Deque<InterfaceType>?
                var prohibitedInterfaceSubtypes: Deque<InterfaceSubtype>?
                var preferredInterfaceSubtypes: Deque<InterfaceSubtype>?

                var prohibitedInterfaces: Deque<Interface>?

                #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
                var interfacePreferencePrivate = InterfacePreferencePrivate()
                #endif
            }
            var storage = Storage()

            static func == (
                lhs: PathParameters.InterfacePreferenceValues.InterfacePreferenceValuesBacking,
                rhs: PathParameters.InterfacePreferenceValues.InterfacePreferenceValuesBacking
            ) -> Bool {
                lhs.storage == rhs.storage
            }
            func hash(into hasher: inout Hasher) {
                hasher.combine(storage)
            }

            init() {}

            init(storage: Storage) {
                self.storage = storage
            }

            func copy() -> InterfacePreferenceValuesBacking {
                .init(storage: storage)
            }
        }
        private var backing: InterfacePreferenceValuesBacking?

        /// Guarantees a backing that this value uniquely owns, allocating one if absent and copying
        /// it first if it is shared.
        ///
        /// Every mutating path must go through here. Mutating `backing` directly would let a write
        /// land on storage another copy can see, which is what the copy-on-write is preventing.
        private mutating func ensureUniquelyReferencedBacking() {
            if self.backing == nil {
                self.backing = InterfacePreferenceValuesBacking()
            } else if !isKnownUniquelyReferenced(&self.backing) {
                self.backing = self.backing?.copy()
            }
        }

        var requiredInterface: Interface? {
            get { self.backing?.storage.requiredInterface }
            set {
                self.ensureUniquelyReferencedBacking()
                self.backing!.storage.requiredInterface = newValue
            }
        }
        var prohibitedInterfaceTypes: Deque<InterfaceType>? {
            get { self.backing?.storage.prohibitedInterfaceTypes }
            set {
                self.ensureUniquelyReferencedBacking()
                self.backing!.storage.prohibitedInterfaceTypes = newValue
            }
        }
        var prohibitedInterfaceSubtypes: Deque<InterfaceSubtype>? {
            get { self.backing?.storage.prohibitedInterfaceSubtypes }
            set {
                self.ensureUniquelyReferencedBacking()
                self.backing!.storage.prohibitedInterfaceSubtypes = newValue
            }
        }
        var preferredInterfaceSubtypes: Deque<InterfaceSubtype>? {
            get { self.backing?.storage.preferredInterfaceSubtypes }
            set {
                self.ensureUniquelyReferencedBacking()
                self.backing!.storage.preferredInterfaceSubtypes = newValue
            }
        }
        var prohibitedInterfaces: Deque<Interface>? {
            get { self.backing?.storage.prohibitedInterfaces }
            set {
                self.ensureUniquelyReferencedBacking()
                self.backing!.storage.prohibitedInterfaces = newValue
            }
        }

        init() {}

        init(deepCopy other: InterfacePreferenceValues) {
            if let existing = other.backing?.storage {
                let newBacking = InterfacePreferenceValuesBacking()
                newBacking.storage = existing
                self.backing = newBacking
            }
        }
    }

    var interfacePreferenceValues = InterfacePreferenceValues()

    var requiredInterface: Interface? {
        get { self.interfacePreferenceValues.requiredInterface }
        set {
            self.interfacePreferenceValues.requiredInterface = newValue
        }
    }
    var prohibitedInterfaceTypes: Deque<InterfaceType>? {
        get { self.interfacePreferenceValues.prohibitedInterfaceTypes }
        set {
            self.interfacePreferenceValues.prohibitedInterfaceTypes = newValue
        }
    }
    var prohibitedInterfaceSubtypes: Deque<InterfaceSubtype>? {
        get { self.interfacePreferenceValues.prohibitedInterfaceSubtypes }
        set {
            self.interfacePreferenceValues.prohibitedInterfaceSubtypes = newValue
        }
    }
    var preferredInterfaceSubtypes: Deque<InterfaceSubtype>? {
        get { self.interfacePreferenceValues.preferredInterfaceSubtypes }
        set {
            self.interfacePreferenceValues.preferredInterfaceSubtypes = newValue
        }
    }
    var prohibitedInterfaces: Deque<Interface>? {
        get { self.interfacePreferenceValues.prohibitedInterfaces }
        set {
            self.interfacePreferenceValues.prohibitedInterfaces = newValue
        }
    }
    #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
    var pathParametersPrivate = PathParametersPrivate()
    #endif

    var context = NetworkContext.implicitContext

    struct ProtocolValues: Hashable {
        final class ProtocolValuesBacking: Hashable {
            struct Storage: Hashable {
                var transportOptions: ProtocolStack.TransportProtocol?
                var internetOptions: ProtocolStack.InternetProtocol?
                #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
                var protocolValuesPrivate = ProtocolValuesPrivate()
                #endif

                init() {}

                #if !NETWORK_PRIVATE && !NETWORK_DRIVERKIT
                init(deepCopy other: ProtocolValuesBacking.Storage) {
                    if let transportOptions = other.transportOptions {
                        self.transportOptions = transportOptions.deepCopy()
                    }
                    if let internetOptions = other.internetOptions {
                        self.internetOptions = internetOptions.deepCopy()
                    }
                }
                #endif
            }
            var storage = Storage()

            static func == (
                lhs: PathParameters.ProtocolValues.ProtocolValuesBacking,
                rhs: PathParameters.ProtocolValues.ProtocolValuesBacking
            ) -> Bool {
                lhs.storage == rhs.storage
            }
            func hash(into hasher: inout Hasher) {
                hasher.combine(storage)
            }
        }
        var backing: ProtocolValuesBacking?

        mutating func setupBacking() {
            if self.backing == nil {
                self.backing = ProtocolValuesBacking()
            }
        }

        init() {}

        init(deepCopy other: ProtocolValues) {
            if let existing = other.backing?.storage {
                let newBacking = ProtocolValuesBacking()
                newBacking.storage = ProtocolValuesBacking.Storage(deepCopy: existing)
                self.backing = newBacking
            }
        }
    }

    var protocolValues = ProtocolValues()

    var transportOptions: ProtocolStack.TransportProtocol? {
        get { protocolValues.backing?.storage.transportOptions }
        set {
            protocolValues.setupBacking()
            protocolValues.backing!.storage.transportOptions = newValue
        }
    }
    var internetOptions: ProtocolStack.InternetProtocol? {
        get { protocolValues.backing?.storage.internetOptions }
        set {
            protocolValues.setupBacking()
            protocolValues.backing!.storage.internetOptions = newValue
        }
    }

    var localAddress: Endpoint?

    init() {}
}

// @unchecked Sendable because access is controlled by getters and copy-on-write setters giving this value semantics.
@available(Network 0.1.0, *)
extension PathParameters.InterfacePreferenceValues: @unchecked Sendable {}

// MARK: - Copying and comparing
@available(Network 0.1.0, *)
extension PathParameters {
    init(deepCopy other: PathParameters) {
        self = other
        self.interfacePreferenceValues = InterfacePreferenceValues(deepCopy: other.interfacePreferenceValues)
        self.protocolValues = ProtocolValues(deepCopy: other.protocolValues)
    }

    #if !NETWORK_PRIVATE && !NETWORK_DRIVERKIT
    func isEqual(to other: PathParameters, for compareMode: ProtocolCompareMode) -> Bool {
        guard self.pathValue == other.pathValue else {
            return false
        }

        // Process check is only skipped for proxies (not privacy proxies or companion proxies)
        guard compareMode == .joiningProxy || self.processPathValue == other.processPathValue else {
            return false
        }

        guard
            !(compareMode == .equal || compareMode == .association) || self.joinablePathValue == other.joinablePathValue
        else {
            return false
        }

        guard self.context.sharesWorkloop(with: other.context) else {
            return false
        }

        // Proxies are allowed to join even if protocol caches are isolated
        if compareMode != .joiningProxy && compareMode != .joiningPrivacyProxy && compareMode != .joiningCompanionProxy,
            self.context != other.context,
            self.context.isolateProtocolCache || other.context.isolateProtocolCache
        {
            return false
        }

        guard self.requiredInterface == other.requiredInterface,
            self.prohibitedInterfaceTypes == other.prohibitedInterfaceTypes,
            self.prohibitedInterfaceSubtypes == other.prohibitedInterfaceSubtypes,
            self.preferredInterfaceSubtypes == other.preferredInterfaceSubtypes,
            self.prohibitedInterfaces == other.prohibitedInterfaces
        else {
            return false
        }

        if let lh = self.transportOptions, let rh = other.transportOptions {
            guard lh.isEqual(to: rh, for: compareMode) else {
                return false
            }
        } else {
            guard self.transportOptions == nil, other.transportOptions == nil else {
                return false
            }
        }

        if let lh = self.internetOptions, let rh = other.internetOptions {
            guard lh.isEqual(to: rh, for: compareMode) else {
                return false
            }
        } else {
            guard self.internetOptions == nil, other.internetOptions == nil else {
                return false
            }
        }

        // Only require that local addresses match if both are set, since we will populate the local address automatically
        // from listeners and when creating connections from connected sockets.
        if let lh = self.localAddress, let rh = other.localAddress {
            guard lh == rh else {
                return false
            }
        } else if compareMode == .equal {
            guard self.localAddress == nil, other.localAddress == nil else {
                return false
            }
        }

        guard self.requiredInterface == other.requiredInterface else {
            return false
        }

        return true
    }
    #endif
}

// MARK: - Description and logging
@available(Network 0.1.0, *)
extension PathParameters {
    var description: String {
        #if !NETWORK_EMBEDDED
        var description =
            "context: \(context.identifier) (\(context.privacyLevel)), proc: \(processPathValue.processUUID.uuidString)"
        if processPathValue.processUUID != processPathValue.effectiveProcessUUID {
            description += ", effective proc: \(processPathValue.effectiveProcessUUID.uuidString)"
        }
        if let personaUUID = processPathValue.personaUUID {
            description += ", persona: \(personaUUID)"
        }
        if let delegatedUniquePID = processPathValue.delegatedUniquePID {
            description += ", delegated upid: \(delegatedUniquePID)"
        }
        if pathValue.trafficClass != 0 {
            description += ", traffic class: \(pathValue.trafficClass)"
        }
        #if !NETWORK_STANDALONE
        if processPathValue.pid != getpid() {
            description += ", pid: \(processPathValue.pid)"
        }
        if processPathValue.uid != getuid() {
            description += ", uid: \(processPathValue.uid)"
        }
        #endif
        if let requiredInterfaceType = pathValue.requiredInterfaceType {
            description += ", required interface type: \(requiredInterfaceType)"
        }
        if let requiredInterfaceSubtype = pathValue.requiredInterfaceSubtype {
            description += ", required interface subtype: \(requiredInterfaceSubtype)"
        }
        if let nextHopRequiredInterfaceType = pathValue.nextHopRequiredInterfaceType {
            description += ", next hop required interface type: \(nextHopRequiredInterfaceType)"
        }
        if let nextHopRequiredInterfaceSubtype = pathValue.nextHopRequiredInterfaceSubtype {
            description += ", next hop required interface subtype: \(nextHopRequiredInterfaceSubtype)"
        }
        if joinablePathValue.multipathService != .disabled {
            description += ", multipath service: \(joinablePathValue.multipathService)"
        }
        if pathValue.prohibitExpensivePaths { description += ", prohibit expensive" }
        if pathValue.prohibitConstrainedPaths { description += ", prohibit constrained" }
        if joinablePathValue.noProxy { description += ", no proxy" }
        if joinablePathValue.noWakeFromSleep { description += ", no wake from sleep" }
        if pathValue.allowSocketAccess { description += ", allow socket access" }
        if joinablePathValue.noFallback { description += ", prohibit fallback" }
        if joinablePathValue.preferNoProxy { description += ", prefer no proxy" }
        if joinablePathValue.noProxyPathSelection { description += ", no proxy path selection" }
        if pathValue.privacyProxyFailClosed { description += ", proxy fail closed" }
        if pathValue.privacyProxyStrictFailClosed { description += ", proxy strict fail closed" }
        if joinablePathValue.privacyProxyFailClosedForUnreachableHosts {
            description += ", proxy fail closed for unreachable"
        }

        if let localAddress {
            description += ", local address: \(localAddress)"
        }

        if let requiredInterface {
            description += ", required interface: \(requiredInterface.name)(\(requiredInterface.index))"
        }

        if let prohibitedInterfaceTypes, !prohibitedInterfaceTypes.isEmpty {
            description += ", prohibited types:"
            for interfaceType in prohibitedInterfaceTypes {
                description += " \(interfaceType)"
            }
        }

        if let prohibitedInterfaceSubtypes, !prohibitedInterfaceSubtypes.isEmpty {
            description += ", prohibited subtypes:"
            for interfaceSubtype in prohibitedInterfaceSubtypes {
                description += " \(interfaceSubtype)"
            }
        }

        if let preferredInterfaceSubtypes, !preferredInterfaceSubtypes.isEmpty {
            description += ", preferred subtypes:"
            for interfaceSubtype in preferredInterfaceSubtypes {
                description += " \(interfaceSubtype)"
            }
        }

        if let prohibitedInterfaces, !prohibitedInterfaces.isEmpty {
            description += ", prohibited interfaces:"
            for interface in prohibitedInterfaces {
                description += " \(interface.name)(\(interface.index))"
            }
        }

        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        description += self.privateDescription
        #endif

        return description
        #else
        return "<path parameters>"
        #endif
    }

    var disableLogging: Bool {
        context.disableLogging
    }
}
