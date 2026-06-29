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

@_spi(Essentials)
@available(Network 0.1.0, *)
public enum PathReason: Sendable {
    case none
    case requiresHelper
    case policyDrop
    case noRoute
    case networkAgentUnsatisfied
    case expensiveProhibited
    case interfaceProhibited
    case interfaceTypeProhibited
    case interfaceTypeRequired
    case interfaceRequired
    case networkAgentProhibited
    case networkAgentRequired
    case powerRequired
    case dataProtectionClass
    case invalidParameters
    case thermalLevel
    case batterySaverMode
    case powerPolicy
    case startTime
    case expired
    case duet
    case opportunistic
    case proxy
    case poolBusy
    case networkQuality
    case constrainedProhibited
    case cellularDenied
    case wifiDenied
    case localNetworkProhibited
    case vpnInactive
    case ultraConstrainedNotAllowed
    case ulpnDenied

    internal var genericUnsatisfiedReason: Bool {
        switch self {
        case .cellularDenied:
            return false
        case .wifiDenied:
            return false
        case .localNetworkProhibited:
            return false
        case .vpnInactive:
            return false
        default:
            return true
        }
    }

    internal var hasUnsatisfiedRoute: Bool {
        // We use switch here to ensure that if a new path reason is added the compiler will alert us if that case is not
        // covered here.
        switch self {

        case .none:
            return false
        case .requiresHelper:
            return false
        case .policyDrop:
            return false
        case .networkAgentUnsatisfied:
            return false
        case .interfaceTypeRequired:
            return false
        case .interfaceRequired:
            return false
        case .networkAgentProhibited:
            return false
        case .networkAgentRequired:
            return false
        case .powerRequired:
            return false
        case .dataProtectionClass:
            return false
        case .invalidParameters:
            return false
        case .thermalLevel:
            return false
        case .batterySaverMode:
            return false
        case .powerPolicy:
            return false
        case .startTime:
            return false
        case .expired:
            return false
        case .duet:
            return false
        case .opportunistic:
            return false
        case .proxy:
            return false
        case .poolBusy:
            return false
        case .networkQuality:
            return false
        case .vpnInactive:
            return false

        // These do count as an unsatisfied route
        case .noRoute:
            return true
        case .expensiveProhibited:
            return true
        case .interfaceProhibited:
            return true
        case .interfaceTypeProhibited:
            return true
        case .constrainedProhibited:
            return true
        case .ultraConstrainedNotAllowed:
            return true
        case .cellularDenied:
            return true
        case .wifiDenied:
            return true
        case .localNetworkProhibited:
            return true
        case .ulpnDenied:
            return true
        }
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public enum PathStatus: Sendable, CustomStringConvertible {

    case invalid
    case satisfied
    case unsatisfied
    case satisfiable

    public var description: String {
        switch self {
        case .invalid: return "invalid"
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .satisfiable: return "satisfiable"
        }
    }
}

enum PathEvaluationError: Error {
    case cannotSatisfy
    case noInactiveAgents
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct PathProperties: CustomStringConvertible {

    var overrideInterface: Interface? = nil
    var directInterface: Interface? = nil
    var delegateInterface: Interface? = nil
    var fallbackInterface: Interface? = nil
    var parameters: MutableParametersStorage
    var endpoint: Endpoint? = nil

    var clientID: SystemUUID? = nil
    var flowRegistrationID: SystemUUID? = nil
    var fallbackAgent: SystemUUID? = nil

    public var effectiveMTU: UInt32 = 0
    var _effectiveTrafficClass: UInt32 = 0
    var interfaceTimeDelta: UInt32 = 0
    var fallbackGeneration: UInt32 = 0
    var status: PathStatus = .invalid
    var reason: PathReason = .none
    var reasonDescription: String? = nil

    var customEthertype: UInt16 = 0
    var customIPProtocol: UInt8 = 0
    var nat64Prefixes: [NAT64Prefix]? = nil
    var recommendedMSS: UInt8 = 0
    var linkQualityInternal: Int8 = 0
    var clientNECPFD: Int = -1
    var clientRealPID: Int32 = 0

    struct Flags: OptionSet {
        public var rawValue: UInt64

        static public let weakFallback = Flags(rawValue: 1 << 0)
        static public let noFallbackTimer = Flags(rawValue: 1 << 1)
        static public let fallbackIsForced = Flags(rawValue: 1 << 2)
        static public let fallbackIsPreferred = Flags(rawValue: 1 << 3)
        static public let isLocal = Flags(rawValue: 1 << 4)
        static public let isDirect = Flags(rawValue: 1 << 5)
        static public let hasIPv4 = Flags(rawValue: 1 << 6)
        static public let hasIPv6 = Flags(rawValue: 1 << 7)
        static public let hasNAT64 = Flags(rawValue: 1 << 8)
        static public let trafficMgmtBackground = Flags(rawValue: 1 << 9)
        static public let necpSatisfied = Flags(rawValue: 1 << 10)
        static public let overrideViable = Flags(rawValue: 1 << 11)
        static public let changedFromPrevious = Flags(rawValue: 1 << 12)
        static public let probeConnectivity = Flags(rawValue: 1 << 13)
        static public let linkQualityAbort = Flags(rawValue: 1 << 14)
        static public let checkedDNS = Flags(rawValue: 1 << 15)
        static public let isListener = Flags(rawValue: 1 << 16)
        static public let isInterpose = Flags(rawValue: 1 << 17)
        static public let specificListener = Flags(rawValue: 1 << 18)
        static public let overrideIsExpensive = Flags(rawValue: 1 << 19)
        static public let overrideIsConstrained = Flags(rawValue: 1 << 20)
        static public let overrideIsRoaming = Flags(rawValue: 1 << 21)
        static public let overrideUsesWiFi = Flags(rawValue: 1 << 22)
        static public let overrideUsesCellular = Flags(rawValue: 1 << 23)
        static public let overrideInterfaceScoped = Flags(rawValue: 1 << 24)
        static public let overrideReason = Flags(rawValue: 1 << 25)
        static public let mergedProxyConfigs = Flags(rawValue: 1 << 26)
        static public let hasKextFilter = Flags(rawValue: 1 << 27)
        static public let hasPFRules = Flags(rawValue: 1 << 28)
        static public let hasApplicationLevelFirewall = Flags(rawValue: 1 << 29)
        static public let hasParentalControls = Flags(rawValue: 1 << 30)
        static public let useLinkHeuristics = Flags(rawValue: 1 << 31)
        static public let hasOverrideTrafficClass = Flags(rawValue: 1 << 32)
        static public let fallbackIsOpportunistic = Flags(rawValue: 1 << 33)
    }

    /// The link quality measurement of the link-layer network attachment.
    public enum LinkQuality: Sendable {
        /// No link quality measurement is available.
        case unknown
        /// The link quality is minimal.
        case minimal
        /// The link quality is moderate.
        case moderate
        /// The link quality is good.
        case good

        internal init(_ nw: Int8) {
            switch nw {
            case -2, -1, 0: self = .unknown
            case 10, 20: self = .minimal
            case 50: self = .moderate
            case 100: self = .good
            default: self = .unknown
            }
        }
    }

    var linkQuality: LinkQuality {
        LinkQuality(linkQualityInternal)
    }
    var flags: Flags = Flags()
    var isLocal: Bool {
        get { self.flags.contains(.isLocal) }
        set { if newValue { flags.insert(.isLocal) } else { flags.remove(.isLocal) } }
    }
    var isDirect: Bool {
        get { self.flags.contains(.isDirect) }
        set { if newValue { flags.insert(.isDirect) } else { flags.remove(.isDirect) } }
    }
    var hasIPv4: Bool {
        get { self.flags.contains(.hasIPv4) }
        set { if newValue { flags.insert(.hasIPv4) } else { flags.remove(.hasIPv4) } }
    }
    var hasIPv6: Bool {
        get { self.flags.contains(.hasIPv6) }
        set { if newValue { flags.insert(.hasIPv6) } else { flags.remove(.hasIPv6) } }
    }
    var hasNAT64: Bool {
        get { self.flags.contains(.hasNAT64) }
        set { if newValue { flags.insert(.hasNAT64) } else { flags.remove(.hasNAT64) } }
    }
    var necpSatisfied: Bool {
        get { self.flags.contains(.necpSatisfied) }
        set { if newValue { flags.insert(.necpSatisfied) } else { flags.remove(.necpSatisfied) } }
    }
    var isListener: Bool {
        get { self.flags.contains(.isListener) }
        set { if newValue { flags.insert(.isListener) } else { flags.remove(.isListener) } }
    }
    var specificListener: Bool {
        get { self.flags.contains(.specificListener) }
        set { if newValue { flags.insert(.specificListener) } else { flags.remove(.specificListener) } }
    }
    var isInterpose: Bool {
        get { self.flags.contains(.isInterpose) }
        set { if newValue { flags.insert(.isInterpose) } else { flags.remove(.isInterpose) } }
    }
    var hasOverrideTrafficClass: Bool {
        get { self.flags.contains(.hasOverrideTrafficClass) }
        set { if newValue { flags.insert(.hasOverrideTrafficClass) } else { flags.remove(.hasOverrideTrafficClass) } }
    }
    var overrideIsExpensive: Bool {
        get { self.flags.contains(.overrideIsExpensive) }
        set { if newValue { flags.insert(.overrideIsExpensive) } else { flags.remove(.overrideIsExpensive) } }
    }
    var overrideIsConstrained: Bool {
        get { self.flags.contains(.overrideIsConstrained) }
        set { if newValue { flags.insert(.overrideIsConstrained) } else { flags.remove(.overrideIsConstrained) } }
    }
    var overrideIsRoaming: Bool {
        get { self.flags.contains(.overrideIsRoaming) }
        set { if newValue { flags.insert(.overrideIsRoaming) } else { flags.remove(.overrideIsRoaming) } }
    }
    var overrideUsesWiFi: Bool {
        get { self.flags.contains(.overrideUsesWiFi) }
        set { if newValue { flags.insert(.overrideUsesWiFi) } else { flags.remove(.overrideUsesWiFi) } }
    }
    var overrideUsesCellular: Bool {
        get { self.flags.contains(.overrideUsesCellular) }
        set { if newValue { flags.insert(.overrideUsesCellular) } else { flags.remove(.overrideUsesCellular) } }
    }
    var overrideInterfaceScoped: Bool {
        get { self.flags.contains(.overrideInterfaceScoped) }
        set { if newValue { flags.insert(.overrideInterfaceScoped) } else { flags.remove(.overrideInterfaceScoped) } }
    }
    var overrideReason: Bool {
        get { self.flags.contains(.overrideReason) }
        set { if newValue { flags.insert(.overrideReason) } else { flags.remove(.overrideReason) } }
    }
    var overrideViable: Bool {
        get { self.flags.contains(.overrideViable) }
        set { if newValue { flags.insert(.overrideViable) } else { flags.remove(.overrideViable) } }
    }
    var fallbackWeak: Bool {
        get { flags.contains(.weakFallback) }
        set { if newValue { flags.insert(.weakFallback) } else { flags.remove(.weakFallback) } }
    }
    var fallbackNoTimer: Bool {
        get { flags.contains(.noFallbackTimer) }
        set { if newValue { flags.insert(.noFallbackTimer) } else { flags.remove(.noFallbackTimer) } }
    }
    var fallbackIsPreferred: Bool {
        get { flags.contains(.fallbackIsPreferred) }
        set { if newValue { flags.insert(.fallbackIsPreferred) } else { flags.remove(.fallbackIsPreferred) } }
    }
    var fallbackIsOpportunistic: Bool {
        get { flags.contains(.fallbackIsOpportunistic) }
        set { if newValue { flags.insert(.fallbackIsOpportunistic) } else { flags.remove(.fallbackIsOpportunistic) } }
    }
    var fallbackIsForced: Bool {
        get { flags.contains(.fallbackIsForced) }
        set { if newValue { flags.insert(.fallbackIsForced) } else { flags.remove(.fallbackIsForced) } }
    }
    var checkedDNS: Bool {
        get { flags.contains(.checkedDNS) }
        set { if newValue { flags.insert(.checkedDNS) } else { flags.remove(.checkedDNS) } }
    }
    var trafficMgmtBackground: Bool {
        get { flags.contains(.trafficMgmtBackground) }
        set { if newValue { flags.insert(.trafficMgmtBackground) } else { flags.remove(.trafficMgmtBackground) } }
    }
    var changedFromPrevious: Bool {
        get { flags.contains(.changedFromPrevious) }
        set { if newValue { flags.insert(.changedFromPrevious) } else { flags.remove(.changedFromPrevious) } }
    }
    var probeConnectivity: Bool {
        get { flags.contains(.probeConnectivity) }
        set { if newValue { flags.insert(.probeConnectivity) } else { flags.remove(.probeConnectivity) } }
    }
    var linkQualityAbort: Bool {
        get { flags.contains(.linkQualityAbort) }
        set { if newValue { flags.insert(.linkQualityAbort) } else { flags.remove(.linkQualityAbort) } }
    }
    var mergedProxyConfigs: Bool {
        get { flags.contains(.mergedProxyConfigs) }
        set { if newValue { flags.insert(.mergedProxyConfigs) } else { flags.remove(.mergedProxyConfigs) } }
    }
    var hasKextFilter: Bool {
        get { flags.contains(.hasKextFilter) }
        set { if newValue { flags.insert(.hasKextFilter) } else { flags.remove(.hasKextFilter) } }
    }
    var hasPFRules: Bool {
        get { flags.contains(.hasPFRules) }
        set { if newValue { flags.insert(.hasPFRules) } else { flags.remove(.hasPFRules) } }
    }
    var hasApplicationLevelFirewall: Bool {
        get { flags.contains(.hasApplicationLevelFirewall) }
        set {
            if newValue {
                flags.insert(.hasApplicationLevelFirewall)
            } else {
                flags.remove(.hasApplicationLevelFirewall)
            }
        }
    }
    var hasParentalControls: Bool {
        get { flags.contains(.hasParentalControls) }
        set { if newValue { flags.insert(.hasParentalControls) } else { flags.remove(.hasParentalControls) } }
    }
    var useLinkHeuristics: Bool {
        get { flags.contains(.useLinkHeuristics) }
        set { if newValue { flags.insert(.useLinkHeuristics) } else { flags.remove(.useLinkHeuristics) } }
    }

    var flows = Deque<PathFlow>()

    public mutating func addFlow(_ flow: PathFlow) {
        flows.append(flow)
    }

    public var hasFlows: Bool {
        !flows.isEmpty
    }

    var overrideLocalEndpoint: Endpoint? = nil

    var gateways: Deque<Endpoint>? = nil

    internal init(endpoint: Endpoint?, parameters: MutableParametersStorage) {
        self.endpoint = endpoint
        self.parameters = parameters
    }

    #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
    var privateProperties = PathProperties.PrivateProperties()
    #endif

    #if !NETWORK_PRIVATE && !NETWORK_DRIVERKIT
    public var description: String {
        var debugStr = status.description + " (" + (reasonDescription ?? "no reason") + ")"
        if let directInterface {
            debugStr += ", interface: " + directInterface.name
        }
        if hasIPv4 { debugStr += ", ipv4" }
        if hasIPv6 { debugStr += ", ipv6" }
        if isExpensive { debugStr += ", expensive" }
        if isConstrained { debugStr += ", constrained" }
        if usesInterfaceType(type: .wifi) { debugStr += ", uses wifi" }
        if usesInterfaceType(type: .cellular) { debugStr += ", uses cell" }
        if usesInterfaceType(type: .wifi) { debugStr += ", LQM: \(linkQuality)" }
        if usesInterfaceType(type: .cellular) { debugStr += ", LQM: \(linkQuality)" }
        return debugStr
    }
    #endif

    public init(parameters: Parameters) {
        self.parameters = MutableParametersStorage(parameters)
    }

    var hasUnsatisfiedRoute: Bool {
        status == .unsatisfied && reason.hasUnsatisfiedRoute
    }

    var connectedInterface: Interface? {
        if let overrideInterface { return overrideInterface }
        for flow in flows {
            if flow.interface != nil && flow.viable { return flow.interface }
        }
        return nil
    }

    var isExpensive: Bool {
        if overrideIsExpensive { return true }
        if connectedInterface?.isExpensive == true { return true }
        if self.status != .satisfied || (reason == .networkAgentUnsatisfied || reason == .vpnInactive) {
            return false
        }
        return
            (directInterface?.isExpensive ?? false || delegateInterface?.isExpensive ?? false
            || (!fallbackIsOpportunistic && (fallbackInterface?.isExpensive ?? false)))
    }

    var isConstrained: Bool {
        if overrideIsConstrained { return true }
        if connectedInterface?.isConstrained == true { return true }
        if status != .satisfied, reason == .networkAgentUnsatisfied || reason == .vpnInactive {
            return false
        }
        return
            (directInterface?.isConstrained ?? false || delegateInterface?.isConstrained ?? false
            || (!fallbackIsOpportunistic && (fallbackInterface?.isConstrained ?? false)))
    }

    private func statusIsPreferred(left: PathStatus, right: PathStatus) -> Bool {
        if left == right {
            return false
        }
        if left == .satisfied && right == .unsatisfied {
            return true
        }
        return false
    }

    func isPreferred(otherPath: PathProperties?, preferDifferentInterface: Bool) -> Bool {
        if let other = otherPath {
            if statusIsPreferred(left: self.status, right: other.status) {
                return true
            }
            if statusIsPreferred(left: other.status, right: self.status) {
                return false
            }
            if preferDifferentInterface,
                !(self.directInterface == other.directInterface)
            {
                return true
            }
        }
        return false
    }

    func usesInterfaceType(type: InterfaceType) -> Bool {
        if type == .wifi && overrideUsesWiFi { return true }
        if type == .cellular && overrideUsesCellular { return true }
        if connectedInterface?.interfaceType == type { return true }
        #if NETWORK_PRIVATE
        if status == .satisfiable, type == .cellular, hasUnsatisfiedCellularAgent(internetOnly: false) {
            // Check for satisfiable cellular agents. If the cellular service isn't up,
            // but can be triggered on this path, mark it as cellular
            return true
        }
        #endif
        if status != .satisfied, reason == .networkAgentUnsatisfied || reason == .vpnInactive { return false }
        if directInterface?.interfaceType == type { return true }
        if delegateInterface?.interfaceType == type { return true }
        if !fallbackIsOpportunistic, fallbackInterface?.interfaceType == type { return true }
        return false
    }

    func usesInterfaceSubtype(subtype: InterfaceSubtype) -> Bool {
        if connectedInterface?.interfaceSubtype == subtype { return true }
        if status != .satisfied, reason == .networkAgentUnsatisfied || reason == .vpnInactive { return false }
        if directInterface?.interfaceSubtype == subtype { return true }
        if delegateInterface?.interfaceSubtype == subtype { return true }
        if !fallbackIsOpportunistic, fallbackInterface?.interfaceSubtype == subtype { return true }
        return false
    }

    var isMultilayerPacketLogging: Bool {
        if directInterface?.isMultilayerPacketLogging == true { return true }
        if delegateInterface?.isMultilayerPacketLogging == true { return true }
        return false
    }

    #if !NETWORK_PRIVATE && !NETWORK_DRIVERKIT
    var networkIsSatisfied: Bool {
        directInterface != nil
    }
    #endif

    var hardwareChecksumFlags: UInt32 {
        if networkIsSatisfied, let directInterface {
            return UInt32(directInterface.hardwareChecksumFlags)
        }
        return 0
    }

    var mtu: Int {
        if networkIsSatisfied {
            if effectiveMTU != 0 { return Int(effectiveMTU) }
            if let directInterface { return directInterface.mtu }
            // Do not log the path, we can hit this function from `description`
            #if !NETWORK_EMBEDDED
            Logger.path.error("Unable to determine MTU for path")
            #endif
        }
        return 0
    }

    public var maximumPacketSize: Int {
        var maximumSize = self.mtu
        guard maximumSize > 0 else {
            return 1500
        }

        guard maximumSize >= (IPProtocol.ipv6HeaderLength) else {
            // The MTU is really small. Don't bother subtracting.
            return maximumSize
        }

        if let endpoint,
            case .address(let addressEndpoint) = endpoint.type,
            case .v4 = addressEndpoint.type
        {
            // Offset for an IPv4 header
            maximumSize -= IPProtocol.ipv4HeaderLength
        } else {
            maximumSize -= IPProtocol.ipv6HeaderLength
        }

        return maximumSize
    }

    var effectiveTrafficClass: UInt32 {
        get {
            guard networkIsSatisfied else { return 0 }
            if hasOverrideTrafficClass { return _effectiveTrafficClass }
            if _effectiveTrafficClass != 0 { return _effectiveTrafficClass }
            return parameters.access { $0.trafficClass }
        }
        set {
            _effectiveTrafficClass = newValue
        }
    }

    var effectiveServiceClass: Parameters.ServiceClass {
        get {
            guard networkIsSatisfied else { return .bestEffort }
            return parameters.access { $0.serviceClass }
        }
    }

    public var effectiveLocalEndpoint: Endpoint? {
        if let overrideLocalEndpoint {
            return overrideLocalEndpoint
        }
        if let flow = self.flows.first {
            if let endpoint = flow.localEndpoint {
                return endpoint
            }
        }
        return parameters.access { $0.localAddress }
    }

    public var effectiveRemoteEndpoint: Endpoint? {
        if let flow = self.flows.first {
            if let endpoint = flow.remoteEndpoint {
                return endpoint
            }
        }
        return endpoint
    }
}
