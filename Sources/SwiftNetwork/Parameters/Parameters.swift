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
public struct Parameters: Hashable, CustomStringConvertible {
    enum DataMode: UInt8, Hashable, CustomStringConvertible {
        case unspecified = 0
        case datagram = 1
        case stream = 2
        case message = 3

        var description: String {
            switch self {
            case .unspecified: return "unspecified"
            case .datagram: return "datagram"
            case .stream: return "stream"
            case .message: return "message"
            }
        }
    }

    public enum MultipathServiceType: UInt8, Hashable, CustomStringConvertible, Sendable {
        case disabled = 0
        case handover = 1
        case interactive = 2
        case aggregate = 3
        case targetBased = 100
        case pureHandover = 101

        public var description: String {
            switch self {
            case .disabled: return "disabled"
            case .handover: return "handover"
            case .interactive: return "interactive"
            case .aggregate: return "aggregate"
            case .targetBased: return "targetBased"
            case .pureHandover: return "pureHandover"
            }
        }
    }

    public enum ExpiredDNSBehavior: Hashable, CustomStringConvertible, Sendable {
        /// Let the system determine whether or not to allow expired DNS answers
        case systemDefault
        /// Explicitly allow the use of expired DNS answers
        case allow
        /// Explicitly prohibit the use of expired DNS answers
        case prohibit
        /// Allow the use of expired DNS answers, and store answers in a persistent per-process cache.
        /// This should only be set for hostnames whose resolutions are not expected to change across networks.
        case persistent

        public var description: String {
            switch self {
            case .systemDefault: return "default"
            case .allow: return "allow"
            case .prohibit: return "prohibit"
            case .persistent: return "persistent"
            }
        }
    }

    public enum ServiceClass: UInt8, CustomStringConvertible, Sendable {
        /// Default priority traffic
        case bestEffort = 0
        /// Bulk traffic, or traffic that can be de-prioritized behind foreground traffic
        case background = 1
        /// Interactive video traffic
        case interactiveVideo = 2
        /// Interactive voice traffic
        case interactiveVoice = 3
        /// Responsive data
        case responsiveData = 4
        /// Signaling
        case signaling = 5

        public var description: String {
            switch self {
            case .bestEffort: return "best effort"
            case .background: return "background"
            case .interactiveVideo: return "interactive video"
            case .interactiveVoice: return "interactive voice"
            case .responsiveData: return "responsive data"
            case .signaling: return "signaling"
            }
        }
    }

    // Parameters by value that can be compared and copied, which
    // are not involved in path selection. These are used only
    // for equality checks, not compatibility checks.

    var listenerUUID: SystemUUID?

    var expectedWorkload: UInt64?

    var sleepKeepaliveInterval: Int?

    // These are enum types that all can fit in a single byte, so store them in smaller fields
    var _dataMode: DataMode = .unspecified
    var ecnEnabled: Bool?
    var serviceClass: ServiceClass = .bestEffort
    var expiredDNSBehavior: ExpiredDNSBehavior = .systemDefault

    struct Flags: OptionSet, Hashable {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        let rawValue: UInt32
        static let dryRun = Flags(rawValue: 1 << 0)
        static let fastOpenEnabled = Flags(rawValue: 1 << 1)
        static let useLongOutstandingQueries = Flags(rawValue: 1 << 2)
        static let ignoreResolverStats = Flags(rawValue: 1 << 3)
        static let resolvePTR = Flags(rawValue: 1 << 4)
        static let reuseLocalAddress = Flags(rawValue: 1 << 5)
        static let receiveAnyInterface = Flags(rawValue: 1 << 6)
        static let customProtocolsOnly = Flags(rawValue: 1 << 7)
        static let localOnly = Flags(rawValue: 1 << 8)
        static let isServer = Flags(rawValue: 1 << 9)
        static let desperateIvan = Flags(rawValue: 1 << 10)
        static let allowUnusableAddresses = Flags(rawValue: 1 << 11)
        static let httpsProxyOverTLS = Flags(rawValue: 1 << 12)
        static let attachProtocolListener = Flags(rawValue: 1 << 13)
        static let prohibitJoiningProtocols = Flags(rawValue: 1 << 14)
        static let allowJoiningConnectedFD = Flags(rawValue: 1 << 15)
        static let multipathForceEnable = Flags(rawValue: 1 << 16)
        static let alwaysOpenListenerSocket = Flags(rawValue: 1 << 17)
        static let neverOpenListenerSocket = Flags(rawValue: 1 << 18)
        static let disableListenerDatapath = Flags(rawValue: 1 << 19)
        static let requiresDNSSECValidation = Flags(rawValue: 1 << 20)
        static let failIfSVCBReceived = Flags(rawValue: 1 << 21)
        static let minimizeLogging = Flags(rawValue: 1 << 22)
        static let stricterPathScoping = Flags(rawValue: 1 << 23)
        static let inheritedFromSilentContext = Flags(rawValue: 1 << 24)
        static let parallelConnectionAttemptsProhibited = Flags(rawValue: 1 << 25)
        static let enableTLSECH = Flags(rawValue: 1 << 26)
        static let connectionGroupTunnelMode = Flags(rawValue: 1 << 27)
    }
    var flags: Flags = [.alwaysOpenListenerSocket]
    var dryRun: Bool {
        get { flags.contains(.dryRun) }
        set { if newValue { flags.insert(.dryRun) } else { flags.remove(.dryRun) } }
    }
    var fastOpenEnabled: Bool {
        get { flags.contains(.fastOpenEnabled) }
        set { if newValue { flags.insert(.fastOpenEnabled) } else { flags.remove(.fastOpenEnabled) } }
    }
    var useLongOutstandingQueries: Bool {
        get { flags.contains(.useLongOutstandingQueries) }
        set {
            if newValue { flags.insert(.useLongOutstandingQueries) } else { flags.remove(.useLongOutstandingQueries) }
        }
    }
    var ignoreResolverStats: Bool {
        get { flags.contains(.ignoreResolverStats) }
        set { if newValue { flags.insert(.ignoreResolverStats) } else { flags.remove(.ignoreResolverStats) } }
    }
    var resolvePTR: Bool {
        get { flags.contains(.resolvePTR) }
        set { if newValue { flags.insert(.resolvePTR) } else { flags.remove(.resolvePTR) } }
    }
    var reuseLocalAddress: Bool {
        get { flags.contains(.reuseLocalAddress) }
        set { if newValue { flags.insert(.reuseLocalAddress) } else { flags.remove(.reuseLocalAddress) } }
    }
    var receiveAnyInterface: Bool {
        get { flags.contains(.receiveAnyInterface) }
        set { if newValue { flags.insert(.receiveAnyInterface) } else { flags.remove(.receiveAnyInterface) } }
    }
    var customProtocolsOnly: Bool {
        get { flags.contains(.customProtocolsOnly) }
        set { if newValue { flags.insert(.customProtocolsOnly) } else { flags.remove(.customProtocolsOnly) } }
    }
    var localOnly: Bool {
        get { flags.contains(.localOnly) }
        set { if newValue { flags.insert(.localOnly) } else { flags.remove(.localOnly) } }
    }
    #if !NETWORK_PRIVATE
    public var isServer: Bool {
        get { flags.contains(.isServer) }
        set { if newValue { flags.insert(.isServer) } else { flags.remove(.isServer) } }
    }
    #endif
    var desperateIvan: Bool {
        get { flags.contains(.desperateIvan) }
        set { if newValue { flags.insert(.desperateIvan) } else { flags.remove(.desperateIvan) } }
    }
    var allowUnusableAddresses: Bool {
        get { flags.contains(.allowUnusableAddresses) }
        set { if newValue { flags.insert(.allowUnusableAddresses) } else { flags.remove(.allowUnusableAddresses) } }
    }
    var httpsProxyOverTLS: Bool {
        get { flags.contains(.httpsProxyOverTLS) }
        set { if newValue { flags.insert(.httpsProxyOverTLS) } else { flags.remove(.httpsProxyOverTLS) } }
    }
    var attachProtocolListener: Bool {
        get { flags.contains(.attachProtocolListener) }
        set { if newValue { flags.insert(.attachProtocolListener) } else { flags.remove(.attachProtocolListener) } }
    }
    var prohibitJoiningProtocols: Bool {
        get { flags.contains(.prohibitJoiningProtocols) }
        set { if newValue { flags.insert(.prohibitJoiningProtocols) } else { flags.remove(.prohibitJoiningProtocols) } }
    }
    var allowJoiningConnectedFD: Bool {
        get { flags.contains(.allowJoiningConnectedFD) }
        set { if newValue { flags.insert(.allowJoiningConnectedFD) } else { flags.remove(.allowJoiningConnectedFD) } }
    }
    var multipathForceEnable: Bool {
        get { flags.contains(.multipathForceEnable) }
        set { if newValue { flags.insert(.multipathForceEnable) } else { flags.remove(.multipathForceEnable) } }
    }
    var alwaysOpenListenerSocket: Bool {
        get { flags.contains(.alwaysOpenListenerSocket) }
        set { if newValue { flags.insert(.alwaysOpenListenerSocket) } else { flags.remove(.alwaysOpenListenerSocket) } }
    }
    var neverOpenListenerSocket: Bool {
        get { flags.contains(.neverOpenListenerSocket) }
        set { if newValue { flags.insert(.neverOpenListenerSocket) } else { flags.remove(.neverOpenListenerSocket) } }
    }
    var disableListenerDatapath: Bool {
        get { flags.contains(.disableListenerDatapath) }
        set { if newValue { flags.insert(.disableListenerDatapath) } else { flags.remove(.disableListenerDatapath) } }
    }
    var requiresDNSSECValidation: Bool {
        get { flags.contains(.requiresDNSSECValidation) }
        set { if newValue { flags.insert(.requiresDNSSECValidation) } else { flags.remove(.requiresDNSSECValidation) } }
    }
    var failIfSVCBReceived: Bool {
        get { flags.contains(.failIfSVCBReceived) }
        set { if newValue { flags.insert(.failIfSVCBReceived) } else { flags.remove(.failIfSVCBReceived) } }
    }
    var minimizeLogging: Bool {
        get { flags.contains(.minimizeLogging) }
        set { if newValue { flags.insert(.minimizeLogging) } else { flags.remove(.minimizeLogging) } }
    }
    var disableLogging: Bool {
        // Parameters disable logging if the context is silent (pathParameters.disableLogging returns true)
        // or if they have the inheritedFromSilentContext override set, which indicates that their context is not
        // currently set to silent, but that they were created while using a context that was set to silent
        pathParameters.disableLogging || inheritedFromSilentContext
    }
    var stricterPathScoping: Bool {
        get { flags.contains(.stricterPathScoping) }
        set { if newValue { flags.insert(.stricterPathScoping) } else { flags.remove(.stricterPathScoping) } }
    }
    var inheritedFromSilentContext: Bool {
        get { flags.contains(.inheritedFromSilentContext) }
        set {
            if newValue { flags.insert(.inheritedFromSilentContext) } else { flags.remove(.inheritedFromSilentContext) }
        }
    }
    var parallelConnectionAttemptsProhibited: Bool {
        get { flags.contains(.parallelConnectionAttemptsProhibited) }
        set {
            if newValue {
                flags.insert(.parallelConnectionAttemptsProhibited)
            } else {
                flags.remove(.parallelConnectionAttemptsProhibited)
            }
        }
    }
    var enableTLSECH: Bool {
        get { flags.contains(.enableTLSECH) }
        set { if newValue { flags.insert(.enableTLSECH) } else { flags.remove(.enableTLSECH) } }
    }
    var connectionGroupTunnelMode: Bool {
        get { flags.contains(.connectionGroupTunnelMode) }
        set {
            if newValue { flags.insert(.connectionGroupTunnelMode) } else { flags.remove(.connectionGroupTunnelMode) }
        }
    }

    #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
    var parametersPrivate = ParametersPrivate()
    #endif

    var pathParameters: PathParameters = PathParameters()

    var extraParentUUIDs: Deque<SystemUUID>?

    public var defaultStack: ProtocolStack

    var transforms: Deque<ProtocolTransform>?

    func accessTCPOptions<T>(_ handler: ((ProtocolOptions<TCPProtocol>?) -> T)) -> T {
        if case .tcp(let tcp) = defaultStack.transport {
            return handler(tcp)
        } else {
            return handler(nil)
        }
    }

    mutating func modifyTCPOptions(_ handler: ((ProtocolOptions<TCPProtocol>) -> Void)) {
        if defaultStack.transport == nil {
            defaultStack.transport = .tcp(TCPProtocol.options())
        }
        if case .tcp(let tcp) = defaultStack.transport {
            handler(tcp)
        }
    }

    var tfo: Bool {
        get { accessTCPOptions { $0?.enableFastOpen ?? false } }
        set {
            fastOpenEnabled = newValue
            modifyTCPOptions { $0.enableFastOpen = newValue }
        }
    }

    var noFastOpenCookie: Bool {
        get { accessTCPOptions { $0?.noFastOpenCookie ?? false } }
        set { modifyTCPOptions { $0.noFastOpenCookie = newValue } }
    }

    var fastOpenForceEnable: Bool {
        get { accessTCPOptions { $0?.fastOpenForceEnable ?? false } }
        set { modifyTCPOptions { $0.fastOpenForceEnable = newValue } }
    }

    var reduceBuffering: Bool {
        get { accessTCPOptions { $0?.reduceBuffering ?? false } }
        set { modifyTCPOptions { $0.reduceBuffering = newValue } }
    }

    var noDelay: Bool {
        get { accessTCPOptions { $0?.noDelay ?? false } }
        set { modifyTCPOptions { $0.noDelay = newValue } }
    }

    var enableKeepalive: Bool {
        get { accessTCPOptions { $0?.enableKeepalive ?? false } }
        set { modifyTCPOptions { $0.enableKeepalive = newValue } }
    }

    var enableKeepaliveOffload: Bool {
        get { accessTCPOptions { $0?.enableKeepaliveOffload ?? false } }
        set { modifyTCPOptions { $0.enableKeepaliveOffload = newValue } }
    }

    var keepaliveIdleTime: UInt32 {
        get { accessTCPOptions { $0?.keepaliveIdleTime ?? 0 } }
        set { modifyTCPOptions { $0.keepaliveIdleTime = newValue } }
    }

    var keepaliveInterval: UInt32 {
        get { accessTCPOptions { $0?.keepaliveInterval ?? 0 } }
        set { modifyTCPOptions { $0.keepaliveInterval = newValue } }
    }

    var enableBackgroundTrafficManagement: Bool {
        get { accessTCPOptions { $0?.enableBackgroundTrafficManagement ?? false } }
        set { modifyTCPOptions { $0.enableBackgroundTrafficManagement = newValue } }
    }

    var dataMode: DataMode {
        get { _dataMode }
        set {
            if defaultStack.transport == nil {
                switch newValue {
                case .stream:
                    defaultStack.transport = .tcp(TCPProtocol.options())
                case .datagram:
                    defaultStack.transport = .udp(UDPProtocol.options())
                default:
                    break
                }
            }
            _dataMode = newValue
        }
    }

    #if !NETWORK_PRIVATE
    public init(noInternetProtocol: Bool = false) {
        defaultStack = ProtocolStack(noInternet: noInternetProtocol)
    }

    public init(from other: Parameters, shallowCopy: Bool = false) {
        self = other
        if shallowCopy {
            self.defaultStack = ProtocolStack(shallowCopy: other.defaultStack)
        } else {
            self.pathParameters = PathParameters(deepCopy: other.pathParameters)
            self.defaultStack = ProtocolStack(deepCopy: other.defaultStack)
        }
    }
    #endif

    func isEquivalentForPathEvaluation(to other: Parameters) -> Bool {
        // If changing behavior of the association compare mode, consider client(s) using
        // isEquivalentForPathEvaluation.
        self.pathParameters.isEqual(to: other.pathParameters, for: .association)
    }

    static func compareMode(
        joiningProxy: Bool,
        joiningSpecificProtocol: Bool,
        isPrivacyProxy: Bool,
        isCompanionProxy: Bool
    ) -> ProtocolCompareMode {
        if joiningProxy {
            if isPrivacyProxy {
                return .joiningPrivacyProxy
            } else if isCompanionProxy {
                return .joiningCompanionProxy
            } else {
                return .joiningProxy
            }
        } else if joiningSpecificProtocol {
            return .joining
        }
        return .association
    }

    #if !NETWORK_PRIVATE
    func isCompatible(with joinParameters: Parameters, at protocolIndex: Int?, joiningProxy: Bool) -> Bool {
        // The values checked for compatibility are those that are used to calculate
        // the path result (path selection parameters). Other parameters are used only
        // for the stack or data path and don't influence being able to share a path.

        let compareMode = Parameters.compareMode(
            joiningProxy: joiningProxy,
            joiningSpecificProtocol: false,
            isPrivacyProxy: false,
            isCompanionProxy: false
        )

        guard self.pathParameters.isEqual(to: joinParameters.pathParameters, for: compareMode) else {
            return false
        }

        guard self.defaultStack.isEqual(to: joinParameters.defaultStack, for: compareMode) else {
            return false
        }

        return true
    }
    #endif

    static func newApplicationServiceParameters() -> Parameters {
        var parameters = Parameters()
        parameters.configureApplicationService()
        return parameters
    }

    mutating func configureApplicationService() {
        // Application service should never use sockets, and should have stream mode by default
        alwaysOpenListenerSocket = false
        dataMode = .stream

        // Set the flag to indicate that we're using a network agent as next hop
        // and therefore any required or prohibited interface type or subtype
        // should be passed to the agent rather than being applied directly.
        nextHop = true
    }

    public enum CustomProtocolConfiguration<T: NetworkProtocol> {
        case customize((_ protocol: ProtocolOptions<T>) -> Void)
    }

    public enum RequiredProtocolConfiguration<T: NetworkProtocol> {
        case defaultConfiguration
        case customize((_ protocolOptions: ProtocolOptions<T>) -> Void)
    }

    public enum OptionalProtocolConfiguration<T: NetworkProtocol> {
        case disableProtocol
        case defaultConfiguration
        case customize((_ protocolOptions: ProtocolOptions<T>) -> Void)
    }

    #if !NETWORK_PRIVATE
    var automaticallyEnableTFO: Bool { false }
    #endif

    #if !NETWORK_EMBEDDED
    init(tls: OptionalProtocolConfiguration<TLSProtocol>, tcp: RequiredProtocolConfiguration<TCPProtocol>) {
        self = Self.init()
        if case .disableProtocol = tls {
            // TLS is disabled
        } else {
            let tlsOptions = TLSProtocol.options()
            if case .customize(let handler) = tls {
                handler(tlsOptions)
            }
            defaultStack.append(applicationProtocol: tlsOptions)
        }

        let tcpOptions = TCPProtocol.options()
        if automaticallyEnableTFO {
            tcpOptions.enableFastOpen = true
            self.fastOpenEnabled = true
        }
        if case .customize(let handler) = tcp {
            handler(tcpOptions)
        }
        defaultStack.transport = .tcp(tcpOptions)
        dataMode = .stream
    }

    init(dtls: OptionalProtocolConfiguration<TLSProtocol>, udp: RequiredProtocolConfiguration<UDPProtocol>) {
        self = Self.init()
        if case .disableProtocol = dtls {
            // DTLS is disabled
        } else {
            let tlsOptions = TLSProtocol.options()
            if case .customize(let handler) = dtls {
                handler(tlsOptions)
            }
            defaultStack.append(applicationProtocol: tlsOptions)
        }
        let udpOptions = UDPProtocol.options()
        if case .customize(let handler) = udp {
            handler(udpOptions)
        }
        defaultStack.transport = .udp(udpOptions)
        dataMode = .datagram
    }

    public init(udp: RequiredProtocolConfiguration<UDPProtocol>) {
        self = Self.init()
        let udpOptions = UDPProtocol.options()
        if case .customize(let handler) = udp {
            handler(udpOptions)
        }
        defaultStack.transport = .udp(udpOptions)
        dataMode = .datagram
    }

    init(quicConnection: RequiredProtocolConfiguration<QUICConnectionProtocol>) {
        self = Self.init()
        let quicOptions = QUICConnectionProtocol.options()
        if case .customize(let handler) = quicConnection {
            handler(quicOptions)
        }
        defaultStack.transport = .quicConnection(quicOptions)

        dataMode = .stream
    }

    init(
        quicStream: RequiredProtocolConfiguration<QUICStreamProtocol>,
        quicConnection: RequiredProtocolConfiguration<QUICConnectionProtocol>
    ) {
        self = Self.init()
        let quicOptions = QUICStreamProtocol.options()
        if case .customize(let handler) = quicStream {
            handler(quicOptions)
        }
        if case .customize(let handler) = quicConnection {
            let quicConnectionOptions = QUICConnectionProtocol.options()
            handler(quicConnectionOptions)
            if let innerOptions = quicConnectionOptions.perProtocolOptions {
                quicOptions.perProtocolOptions?.quicConnectionOptions = innerOptions
            }
        }
        defaultStack.transport = .quic(quicOptions)

        dataMode = .stream
        attachProtocolListener = true
    }

    public init(quic: CustomProtocolConfiguration<QUICProtocol>) {
        self = Self.init()
        let quicOptions = QUICProtocol.options()
        if case .customize(let handler) = quic {
            handler(quicOptions)
        }
        defaultStack.transport = .quic(quicOptions)

        dataMode = .stream
        attachProtocolListener = true
    }

    init(
        tls: RequiredProtocolConfiguration<TLSProtocol>,
        quicConnection: RequiredProtocolConfiguration<QUICConnectionProtocol>,
        tcpFallbackEndpoint: Endpoint? = nil,
        tcpFallback: RequiredProtocolConfiguration<TCPProtocol>
    ) {
        self = Self.init()

        let tlsOptions = TLSProtocol.options()
        if case .customize(let handler) = tls {
            handler(tlsOptions)
        }

        let quicOptions = QUICConnectionProtocol.options()
        quicOptions.prohibitJoining = true
        quicOptions.perProtocolOptions?.tlsOptions = tlsOptions
        if case .customize(let handler) = quicConnection {
            handler(quicOptions)
        }

        let tcpOptions = TCPProtocol.options()
        if case .customize(let handler) = tcpFallback {
            handler(tcpOptions)
        }

        defaultStack.transport = .quicConnection(quicOptions)

        var quicTransform = ProtocolTransform()
        quicTransform.clear(at: .transport)
        quicTransform.append(protocol: quicOptions, at: .transport)
        quicTransform.fallbackMode = .rttTimer
        quicTransform.prohibitDirect = true

        var tcpTransform = ProtocolTransform()
        tcpTransform.replaceEndpoint = tcpFallbackEndpoint
        tcpTransform.append(protocol: tlsOptions, at: .application)
        tcpTransform.append(protocol: tcpOptions, at: .transport)
        tcpTransform.prohibitDirect = true

        transforms = Deque<ProtocolTransform>()
        transforms?.append(quicTransform)
        transforms?.append(tcpTransform)

        dataMode = .stream
    }

    init(
        tls: RequiredProtocolConfiguration<TLSProtocol>,
        quicStream: RequiredProtocolConfiguration<QUICStreamProtocol>,
        quicConnection: RequiredProtocolConfiguration<QUICConnectionProtocol>,
        tcpFallbackEndpoint: Endpoint? = nil,
        tcpFallback: RequiredProtocolConfiguration<TCPProtocol>
    ) {
        self = Self.init()

        let tlsOptions = TLSProtocol.options()
        if case .customize(let handler) = tls {
            handler(tlsOptions)
        }

        let quicOptions = QUICStreamProtocol.options()
        if case .customize(let handler) = quicStream {
            handler(quicOptions)
        }
        if case .customize(let handler) = quicConnection {
            let quicConnectionOptions = QUICConnectionProtocol.options()
            handler(quicConnectionOptions)
            if let innerOptions = quicConnectionOptions.perProtocolOptions {
                quicOptions.perProtocolOptions?.quicConnectionOptions = innerOptions
            }
        }

        quicOptions.prohibitJoining = true
        quicOptions.perProtocolOptions?.quicConnectionOptions.tlsOptions = tlsOptions

        let tcpOptions = TCPProtocol.options()
        if case .customize(let handler) = tcpFallback {
            handler(tcpOptions)
        }

        defaultStack.transport = .quic(quicOptions)

        var quicTransform = ProtocolTransform()
        quicTransform.clear(at: .transport)
        quicTransform.append(protocol: quicOptions, at: .transport)
        quicTransform.fallbackMode = .rttTimer
        quicTransform.prohibitDirect = true

        var tcpTransform = ProtocolTransform()
        tcpTransform.replaceEndpoint = tcpFallbackEndpoint
        tcpTransform.append(protocol: tlsOptions, at: .application)
        tcpTransform.append(protocol: tcpOptions, at: .transport)
        tcpTransform.prohibitDirect = true

        transforms = Deque<ProtocolTransform>()
        transforms?.append(quicTransform)
        transforms?.append(tcpTransform)

        dataMode = .stream
    }

    init(
        customIPProtocolNumber: UInt8,
        ip: RequiredProtocolConfiguration<IPProtocol>
    ) {
        self = Self.init()
        defaultStack.transport = .customIP(CustomIPProtocol.options(protocolNumber: customIPProtocolNumber))
        if case .customize(let handler) = ip {
            let ipOptions = IPProtocol.options()
            handler(ipOptions)
            defaultStack.internet = .ip(ipOptions)
        }
        dataMode = .datagram
    }

    init(legacyTCPSocket: RequiredProtocolConfiguration<TCPProtocol>) {
        self = Self.init()
        let tcpOptions = TCPProtocol.options()
        if case .customize(let handler) = legacyTCPSocket {
            handler(tcpOptions)
        }
        defaultStack.transport = .tcp(tcpOptions)
        dataMode = .stream
        allowSocketAccess = true
    }
    #endif

    public var context: NetworkContext {
        get { pathParameters.context }
        set {
            newValue.activate()
            pathParameters.context = newValue.cacheContext
        }
    }

    var requiredInterfaceType: InterfaceType? {
        get { pathParameters.pathValue.requiredInterfaceType }
        set {
            if nextHop {
                if case .other = newValue {
                    pathParameters.pathValue.nextHopRequiredInterfaceType = nil
                } else {
                    pathParameters.pathValue.nextHopRequiredInterfaceType = newValue
                }
            } else {
                if case .other = newValue {
                    pathParameters.pathValue.requiredInterfaceType = nil
                } else {
                    pathParameters.pathValue.requiredInterfaceType = newValue
                }
            }
        }
    }

    var hasRequiredInterfaceType: Bool { requiredInterfaceType != nil && requiredInterfaceType != .other }

    #if !NETWORK_PRIVATE
    var requiredInterfaceSubtype: InterfaceSubtype? {
        get { pathParameters.pathValue.requiredInterfaceSubtype }
        set {
            if nextHop {
                if case .other = newValue {
                    pathParameters.pathValue.nextHopRequiredInterfaceSubtype = nil
                } else {
                    pathParameters.pathValue.nextHopRequiredInterfaceSubtype = newValue
                }
            } else {
                if case .other = newValue {
                    pathParameters.pathValue.requiredInterfaceSubtype = nil
                } else {
                    pathParameters.pathValue.requiredInterfaceSubtype = newValue
                }
            }
        }
    }
    #endif

    var hasRequiredInterfaceSubtype: Bool { requiredInterfaceSubtype != nil && requiredInterfaceSubtype != .other }
}

// MARK: - Description

@available(Network 0.1.0, *)
extension Parameters {
    public var description: String {
        #if !NETWORK_EMBEDDED
        var description = transportString

        #if !NETWORK_STANDALONE
        if pid != getpid() {
            description += ", pid: \(pid)"
        }
        #endif

        if trafficClass != 0 {
            description += ", traffic class: \(trafficClass)"
        }
        if let expectedWorkload {
            description += ", expected workload: \(expectedWorkload)"
        }
        if let requiredInterface {
            description += ", interface: \(requiredInterface)"
        }
        if let localAddress {
            description += ", local: \(localAddress)"
        }
        if multipathService != .disabled {
            description += ", multipath service: \(multipathService)"
        }
        if fastOpenEnabled { description += ", fast-open" }
        if usesTLS { description += ", tls" }
        if prohibitExpensivePaths { description += ", no expensive" }
        if prohibitConstrainedPaths { description += ", no constrained" }
        if prohibitCellularPaths { description += ", no cellular" }
        if preferNoProxy { description += ", prefer no proxy" }
        if noProxyPathSelection { description += ", no proxy path selection" }
        if privacyProxyFailClosed { description += ", proxy fail closed" }
        if privacyProxyStrictFailClosed { description += ", proxy strict fail closed" }
        if privacyProxyFailClosedForUnreachableHosts { description += ", proxy fail closed for unreachable" }
        if isServer { description += ", server" }
        if attachProtocolListener { description += ", attach protocol listener" }
        if prohibitJoiningProtocols { description += ", prohibit joining protocols" }
        if allowJoiningConnectedFD { description += ", allow joining fd" }
        if !alwaysOpenListenerSocket { description += ", don't always open listener socket" }
        if neverOpenListenerSocket { description += ", never open listener socket" }
        if disableListenerDatapath { description += ", disable listener datapath" }
        if requiresDNSSECValidation { description += ", requires DNSSEC" }
        if minimizeLogging { description += ", minimize logging" }

        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        description += self.privateDescription
        #endif

        return description
        #else
        return "<parameters>"
        #endif
    }

    #if !NETWORK_EMBEDDED
    var extendedDescription: String {
        var description = transportString

        if let expectedWorkload {
            description += ", expected workload: \(expectedWorkload)"
        }
        if fastOpenEnabled { description += ", fast-open" }
        if usesTLS { description += ", tls" }
        if isServer { description += ", server" }
        if attachProtocolListener { description += ", attach protocol listener" }
        if prohibitJoiningProtocols { description += ", prohibit joining protocols" }
        if allowJoiningConnectedFD { description += ", allow joining fd" }
        if !alwaysOpenListenerSocket { description += ", don't always open listener socket" }
        if neverOpenListenerSocket { description += ", never open listener socket" }
        if disableListenerDatapath { description += ", disable listener datapath" }
        if requiresDNSSECValidation { description += ", requires DNSSEC" }
        if reuseLocalAddress { description += ", reuse local address" }
        if failIfSVCBReceived { description += ", fail if SVCB received" }
        if minimizeLogging { description += ", minimize logging" }
        if localOnly { description += ", local only" }
        if stricterPathScoping { description += ", stricter path scoping" }

        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        description += self.extendedPrivateDescription
        #endif

        description += ", \(pathParameters.description)"
        return description
    }

    var transportString: String {
        guard let transportProtocolIdentifier = defaultStack.transport?.identifier else {
            return "generic"
        }
        return transportProtocolIdentifier.name
    }

    var usesTLS: Bool {
        let identifier = ProtocolIdentifier(name: "tls", level: .application, mapping: .oneToOne)
        return defaultStack.includes(protocolIdentifier: identifier)
    }
    #endif
}

// MARK: - Accessors

@available(Network 0.1.0, *)
extension Parameters {
    var processUUID: SystemUUID {
        get { pathParameters.processPathValue.processUUID }
        set { pathParameters.processPathValue.processUUID = newValue }
    }
    var effectiveProcessUUID: SystemUUID {
        get { pathParameters.processPathValue.effectiveProcessUUID }
        set { pathParameters.processPathValue.effectiveProcessUUID = newValue }
    }
    var delegatedUniquePID: UInt64? {
        get { pathParameters.processPathValue.delegatedUniquePID }
        set { pathParameters.processPathValue.delegatedUniquePID = newValue }
    }
    var pid: Int32 {
        get { pathParameters.processPathValue.pid }
        set { pathParameters.processPathValue.pid = newValue }
    }
    func hasDelegatedPID(_ originalPID: Int32) -> Bool {
        pid > 0 && pid != originalPID
    }
    var uid: UInt32 {
        get { pathParameters.processPathValue.uid }
        set { pathParameters.processPathValue.uid = newValue }
    }
    var trafficClass: UInt32 {
        get { pathParameters.pathValue.trafficClass }
        set { pathParameters.pathValue.trafficClass = newValue }
    }
    var requiredInterface: Interface? {
        get { pathParameters.requiredInterface }
        set { pathParameters.requiredInterface = newValue }
    }
    var requiredInterfaceIndex: Int? {
        guard let requiredInterface else {
            return nil
        }
        return requiredInterface.index
    }
    var requiredAddressFamily: IPProtocol.Version {
        get {
            guard let ipOptions = defaultStack.internetOptionsAsIPOptions(mutable: false) else {
                return .any
            }
            return ipOptions.version
        }
        set {
            guard let ipOptions = defaultStack.internetOptionsAsIPOptions(mutable: true) else {
                return
            }
            ipOptions.version = newValue
        }
    }
    var localAddressPreference: IPProtocol.AddressPreference {
        get {
            guard let ipOptions = defaultStack.internetOptionsAsIPOptions(mutable: false) else {
                return .any
            }
            return ipOptions.localAddressPreference
        }
        set {
            guard let ipOptions = defaultStack.internetOptionsAsIPOptions(mutable: true) else {
                return
            }
            ipOptions.localAddressPreference = newValue
        }
    }

    #if !NETWORK_PRIVATE
    var ipProtocolNumber: UInt8? {
        switch defaultStack.transport {
        case .udp, .quic, .quicConnection:
            return UInt8(17)  // IPPROTO_UDP
        case .tcp:
            return UInt8(6)  // IPPROTO_IP
        case .customIP(let options):
            return options.ipProtocolNumber
        default:
            return nil
        }
    }
    #endif

    var upperTransportProtocolisQUIC: Bool {
        switch defaultStack.transport {
        case .udp(let options):
            return options.useQUICStats
        case .quic, .quicConnection:
            return true
        default:
            return false
        }
    }

    var upperTransportProtocolNumber: UInt8? {
        switch defaultStack.transport {
        case .udp(let options):
            if options.useQUICStats {
                return UInt8(253)  // IPPROTO_QUIC
            }
            return nil
        case .quic, .quicConnection:
            return UInt8(253)  // IPPROTO_QUIC
        default:
            return nil
        }
    }

    var localAddress: Endpoint? {
        get { pathParameters.localAddress }
        set {
            guard let newValue,
                case .address = newValue.type
            else {
                pathParameters.localAddress = nil
                return
            }
            pathParameters.localAddress = newValue
        }
    }
    var multipathService: MultipathServiceType {
        get { pathParameters.joinablePathValue.multipathService }
        set { pathParameters.joinablePathValue.multipathService = newValue }
    }
    var isMultipath: Bool { multipathService != .disabled }
    var isMultipathFallbackAllowed: Bool { multipathService == .interactive || multipathService == .aggregate }

    var prohibitExpensivePaths: Bool {
        get { pathParameters.pathValue.prohibitExpensivePaths }
        set { pathParameters.pathValue.prohibitExpensivePaths = newValue }
    }
    var prohibitConstrainedPaths: Bool {
        get { pathParameters.pathValue.prohibitConstrainedPaths }
        set { pathParameters.pathValue.prohibitConstrainedPaths = newValue }
    }
    var prohibitCellularPaths: Bool {
        get { pathParameters.prohibitedInterfaceTypes?.contains(.cellular) ?? false }
    }
    var prohibitedInterfaceTypes: Deque<InterfaceType>? {
        get { pathParameters.prohibitedInterfaceTypes }
        set { pathParameters.prohibitedInterfaceTypes = newValue }
    }
    var hasProhibitedInterfaceTypes: Bool {
        !(pathParameters.prohibitedInterfaceTypes?.isEmpty ?? true)
    }
    mutating func prohibit(interfaceType: InterfaceType) {
        var prohibitedInterfaceTypes: Deque<InterfaceType>
        if let existingProhibitedInterfaceTypes = pathParameters.prohibitedInterfaceTypes {
            prohibitedInterfaceTypes = existingProhibitedInterfaceTypes
        } else {
            prohibitedInterfaceTypes = Deque<InterfaceType>()
        }
        if !prohibitedInterfaceTypes.contains(interfaceType) {
            prohibitedInterfaceTypes.append(interfaceType)
            pathParameters.prohibitedInterfaceTypes = prohibitedInterfaceTypes
        }
    }
    mutating func removeProhibited(interfaceType: InterfaceType) {
        if var prohibitedInterfaceTypes = pathParameters.prohibitedInterfaceTypes {
            prohibitedInterfaceTypes.removeAll { $0 == interfaceType }
            pathParameters.prohibitedInterfaceTypes = prohibitedInterfaceTypes
        }
    }
    mutating func clearProhibitedInterfaceTypes() {
        pathParameters.prohibitedInterfaceTypes = nil
    }
    var prohibitedInterfaceSubtypes: Deque<InterfaceSubtype>? {
        get { pathParameters.prohibitedInterfaceSubtypes }
        set { pathParameters.prohibitedInterfaceSubtypes = newValue }
    }
    var hasProhibitedInterfaceSubypes: Bool {
        !(pathParameters.prohibitedInterfaceSubtypes?.isEmpty ?? true)
    }
    mutating func prohibit(interfaceSubtype: InterfaceSubtype) {
        var prohibitedInterfaceSubtypes: Deque<InterfaceSubtype>
        if let existingProhibitedInterfaceSubtypes = pathParameters.prohibitedInterfaceSubtypes {
            prohibitedInterfaceSubtypes = existingProhibitedInterfaceSubtypes
        } else {
            prohibitedInterfaceSubtypes = Deque<InterfaceSubtype>()
        }
        if !prohibitedInterfaceSubtypes.contains(interfaceSubtype) {
            prohibitedInterfaceSubtypes.append(interfaceSubtype)
            pathParameters.prohibitedInterfaceSubtypes = prohibitedInterfaceSubtypes
        }
    }
    mutating func clearProhibitedInterfaceSubtypes() {
        pathParameters.prohibitedInterfaceSubtypes = nil
    }
    var preferredInterfaceSubtypes: Deque<InterfaceSubtype>? {
        get { pathParameters.preferredInterfaceSubtypes }
        set { pathParameters.preferredInterfaceSubtypes = newValue }
    }
    var hasPreferredInterfaceSubypes: Bool {
        !(pathParameters.preferredInterfaceSubtypes?.isEmpty ?? true)
    }
    mutating func prefer(interfaceSubtype: InterfaceSubtype) {
        var preferredInterfaceSubtypes: Deque<InterfaceSubtype>
        if let existingPreferredInterfaceSubtypes = pathParameters.preferredInterfaceSubtypes {
            preferredInterfaceSubtypes = existingPreferredInterfaceSubtypes
        } else {
            preferredInterfaceSubtypes = Deque<InterfaceSubtype>()
        }
        if !preferredInterfaceSubtypes.contains(interfaceSubtype) {
            preferredInterfaceSubtypes.append(interfaceSubtype)
            pathParameters.preferredInterfaceSubtypes = preferredInterfaceSubtypes
        }
    }
    mutating func clearPreferredInterfaceSubtypes() {
        pathParameters.preferredInterfaceSubtypes = nil
    }
    var prohibitedInterfaces: Deque<Interface>? {
        get { pathParameters.prohibitedInterfaces }
        set { pathParameters.prohibitedInterfaces = newValue }
    }
    var hasProhibitedInterfaces: Bool {
        !(pathParameters.prohibitedInterfaces?.isEmpty ?? true)
    }
    mutating func prohibit(interface: Interface) {
        var prohibitedInterfaces: Deque<Interface>
        if let existingProhibitedInterfaces = pathParameters.prohibitedInterfaces {
            prohibitedInterfaces = existingProhibitedInterfaces
        } else {
            prohibitedInterfaces = Deque<Interface>()
        }
        if !prohibitedInterfaces.contains(interface) {
            prohibitedInterfaces.append(interface)
            pathParameters.prohibitedInterfaces = prohibitedInterfaces
        }
    }
    mutating func clearProhibitedInterfaces() {
        pathParameters.prohibitedInterfaces = nil
    }
    var noFallback: Bool {
        get { pathParameters.joinablePathValue.noFallback }
        set { pathParameters.joinablePathValue.noFallback = newValue }
    }
    var noProxy: Bool {
        get { pathParameters.joinablePathValue.noProxy }
        set { pathParameters.joinablePathValue.noProxy = newValue }
    }
    var preferNoProxy: Bool {
        get { pathParameters.joinablePathValue.preferNoProxy }
        set { pathParameters.joinablePathValue.preferNoProxy = newValue }
    }
    var noProxyPathSelection: Bool {
        get { pathParameters.joinablePathValue.noProxyPathSelection }
        set { pathParameters.joinablePathValue.noProxyPathSelection = newValue }
    }
    var privacyProxyFailClosed: Bool {
        get { pathParameters.pathValue.privacyProxyFailClosed }
        set { pathParameters.pathValue.privacyProxyFailClosed = newValue }
    }
    var privacyProxyStrictFailClosed: Bool {
        get { pathParameters.pathValue.privacyProxyStrictFailClosed }
        set { pathParameters.pathValue.privacyProxyStrictFailClosed = newValue }
    }
    var privacyProxyFailClosedForUnreachableHosts: Bool {
        get { pathParameters.joinablePathValue.privacyProxyFailClosedForUnreachableHosts }
        set { pathParameters.joinablePathValue.privacyProxyFailClosedForUnreachableHosts = newValue }
    }
    var nextHop: Bool {
        get { pathParameters.pathValue.nextHop }
        set { pathParameters.pathValue.nextHop = newValue }
    }
    var allowSocketAccess: Bool {
        get { pathParameters.pathValue.allowSocketAccess }
        set { pathParameters.pathValue.allowSocketAccess = newValue }
    }
    var proxyApplied: Bool {
        get { pathParameters.joinablePathValue.proxyApplied }
        set { pathParameters.joinablePathValue.proxyApplied = newValue }
    }
    var systemProxy: Bool {
        get { pathParameters.joinablePathValue.systemProxy }
        set { pathParameters.joinablePathValue.systemProxy = newValue }
    }
    var noWakeFromSleep: Bool {
        get { pathParameters.joinablePathValue.noWakeFromSleep }
        set { pathParameters.joinablePathValue.noWakeFromSleep = newValue }
    }
    var hasTransforms: Bool {
        guard let transforms = transforms else {
            return false
        }
        return transforms.count > 0
    }
}

// MARK: - Parameters Storage

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class MutableParametersStorage: Hashable, CustomStringConvertible {
    internal var p: Parameters

    public init(_ parameters: Parameters) {
        self.p = parameters
    }

    public var description: String {
        #if !NETWORK_EMBEDDED
        return p.description
        #else
        return "<parameters>"
        #endif
    }

    func accessMutating<R>(_ body: (inout Parameters) -> R) -> R {
        body(&self.p)
    }

    func access<R>(_ body: (borrowing Parameters) -> R) -> R {
        body(self.p)
    }

    public static func == (lhs: MutableParametersStorage, rhs: MutableParametersStorage) -> Bool {
        lhs.p == rhs.p
    }

    public func hash(into hasher: inout Hasher) {
        #if !NETWORK_EMBEDDED
        hasher.combine(p)
        #endif
    }

    var isMultipath: Bool {
        p.isMultipath
    }

    var isMultipathFallbackAllowed: Bool {
        p.isMultipathFallbackAllowed
    }

    var requiredInterface: Interface? {
        p.requiredInterface
    }

    var requiredInterfaceIndex: Int? {
        p.requiredInterfaceIndex
    }

    var allowSocketAccess: Bool {
        p.allowSocketAccess
    }

    var ipProtocolNumber: UInt8? {
        p.ipProtocolNumber
    }

    var upperTransportProtocolisQUIC: Bool {
        p.upperTransportProtocolisQUIC
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class ImmutableParametersStorage: Hashable, CustomStringConvertible {
    internal let p: Parameters

    public init(_ parameters: Parameters) {
        self.p = parameters
    }

    public var description: String {
        #if !NETWORK_EMBEDDED
        return p.description
        #else
        return "<parameters>"
        #endif
    }

    func access<R>(_ body: (borrowing Parameters) -> R) -> R {
        body(self.p)
    }

    public static func == (lhs: ImmutableParametersStorage, rhs: ImmutableParametersStorage) -> Bool {
        lhs.p == rhs.p
    }

    public func hash(into hasher: inout Hasher) {
        #if !NETWORK_EMBEDDED
        hasher.combine(p)
        #endif
    }
}
