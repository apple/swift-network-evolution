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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if !NETWORK_EMBEDDED && canImport(Dispatch)
import Dispatch
#endif

#if canImport(Synchronization)
internal import Synchronization
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICConnectionProtocol: NetworkProtocol {

    public typealias Options = QUICConnectionOptions
    public typealias Metadata = QUICConnectionMetadata
    public typealias Instance = QUICConnection

    #if !NETWORK_EMBEDDED
    typealias QUICMetadataSetterHandler = (@convention(block) (UInt64) -> Void)
    typealias QUICMetadataGetterHandler = (@convention(block) () -> UInt64)
    public typealias QUICMetadata16SetterHandler = (@convention(block) (UInt16) -> Void)
    public typealias QUICMetadata16GetterHandler = (@convention(block) () -> UInt16)
    typealias QUICMetadataBoolSetterHandler = (@convention(block) (Bool) -> Void)
    typealias QUICMetadataBoolGetterHandler = (@convention(block) () -> Bool)
    typealias QUICMetadataInjectPacketHandler = (@convention(block) (UnsafePointer<UInt8>?, Int) -> Void)
    typealias QUICMetadataGetApplicationResultHandler = (
        @convention(block) (@convention(block) @escaping (UInt32, UInt32) -> Void) -> Void
    )
    #endif

    // QUICConnectionOptions -

    public final class QUICConnectionOptions: PerProtocolOptions {

        internal var _initialMaxData: UInt64 = UInt64.max
        public var initialMaxData: UInt64 {
            get { self._initialMaxData }
            set { self._initialMaxData = newValue }
        }

        internal var _initialMaxStreamDataBidirectionalLocal: UInt64 = UInt64.max
        public var initialMaxStreamDataBidirectionalLocal: UInt64 {
            get { self._initialMaxStreamDataBidirectionalLocal }
            set { self._initialMaxStreamDataBidirectionalLocal = newValue }
        }

        internal var _initialMaxStreamDataBidirectionalRemote: UInt64 = UInt64.max
        public var initialMaxStreamDataBidirectionalRemote: UInt64 {
            get { self._initialMaxStreamDataBidirectionalRemote }
            set { self._initialMaxStreamDataBidirectionalRemote = newValue }
        }

        internal var _initialMaxStreamDataUnidirectional: UInt64 = UInt64.max
        public var initialMaxStreamDataUnidirectional: UInt64 {
            get { self._initialMaxStreamDataUnidirectional }
            set { self._initialMaxStreamDataUnidirectional = newValue }
        }

        internal var _initialMaxStreamsBidirectional: UInt64 = UInt64.max
        public var initialMaxStreamsBidirectional: UInt64 {
            get { self._initialMaxStreamsBidirectional }
            set { self._initialMaxStreamsBidirectional = newValue }
        }

        internal var _initialMaxStreamsUnidirectional: UInt64 = UInt64.max
        public var initialMaxStreamsUnidirectional: UInt64 {
            get { self._initialMaxStreamsUnidirectional }
            set { self._initialMaxStreamsUnidirectional = newValue }
        }

        internal var _peerMaxStreamDataBidirectionalLocal: UInt64 = 0
        var peerMaxStreamDataBidirectionalLocal: UInt64 {
            get { self._peerMaxStreamDataBidirectionalLocal }
            set { self._peerMaxStreamDataBidirectionalLocal = newValue }
        }

        internal var _peerMaxStreamDataBidirectionalRemote: UInt64 = 0
        var peerMaxStreamDataBidirectionalRemote: UInt64 {
            get { self._peerMaxStreamDataBidirectionalRemote }
            set { self._peerMaxStreamDataBidirectionalRemote = newValue }
        }

        internal var _peerMaxData: UInt64 = 0
        var peerMaxData: UInt64 {
            get { self._peerMaxData }
            set { self._peerMaxData = newValue }
        }

        internal var _peerMaxDataUnidirectional: UInt64 = 0
        var peerMaxDataUnidirectional: UInt64 {
            get { self._peerMaxDataUnidirectional }
            set { self._peerMaxDataUnidirectional = newValue }
        }

        internal var _peerMaxStreamsBidirectional: UInt64 = 0
        var peerMaxStreamsBidirectional: UInt64 {
            get { self._peerMaxStreamsBidirectional }
            set { self._peerMaxStreamsBidirectional = newValue }
        }

        internal var _peerMaxStreamsUnidirectional: UInt64 = 0
        var peerMaxStreamsUnidirectional: UInt64 {
            get { self._peerMaxStreamsUnidirectional }
            set { self._peerMaxStreamsUnidirectional = newValue }
        }

        #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
        var privateStorage = QUICConnectionOptionsPrivateStorage()
        #endif

        #if !NETWORK_PRIVATE
        var tlsOptions: ProtocolOptions<TLSProtocol>?
        #endif

        #if !NETWORK_STANDALONE
        var quicState: DispatchData? = nil
        var tlsState: DispatchData? = nil
        #endif

        public var sourceConnectionID: [UInt8]? = nil
        public var destinationConnectionID: [UInt8]? = nil
        // NOTE: sessionUpdateBlock is not supported in Embedded
        #if os(Linux)
        var sessionStateUpdateBlock: (@Sendable @convention(block) ([UInt8]?, [UInt8]?) -> Void)?
        #elseif !NETWORK_STANDALONE && canImport(Darwin)
        var sessionStateUpdateBlock: (@Sendable @convention(block) (DispatchData?, DispatchData?) -> Void)? = nil
        #endif
        #if !NETWORK_STANDALONE && !NETWORK_EMBEDDED
        var sessionStateUpdateQueue: DispatchQueue? = nil
        var maxStreamsUpdateQueue: DispatchQueue? = nil
        var maxStreamsUpdateBlock: (@Sendable @convention(block) (UInt8, UInt64) -> Void)? = nil
        #endif

        #if !NETWORK_NO_SWIFT_QUIC
        public var qlogConfiguration: QLogConfiguration?
        #endif

        // Set maximum concurrent streams to let QUIC automatically manage increasing the max stream values
        public var maximumConcurrentBidirectionalStreams: Int?
        public var maximumConcurrentUnidirectionalStreams: Int?

        #if !NETWORK_NO_SWIFT_QUIC
        public var initialSourceConnectionID: QUICConnectionID? {
            get {
                guard let sourceConnectionID else { return nil }
                return QUICConnectionID(sourceConnectionID)
            }
            set {
                guard let newValue else {
                    self.sourceConnectionID = nil
                    return
                }
                self.sourceConnectionID = newValue.connectionID
            }
        }
        public var initialStatelessResetToken: QUICStatelessResetToken?
        #endif

        public var sourceConnectionIDLength: Int {
            get {
                guard let sourceConnectionID else {
                    #if !NETWORK_NO_SWIFT_QUIC
                    return QUICConnectionID.defaultServerSCIDLength
                    #else
                    return 8
                    #endif
                }
                return sourceConnectionID.count
            }
            set {
                if newValue == 0 {
                    sourceConnectionID = nil
                } else {
                    sourceConnectionID = [UInt8](repeating: 0, count: Int(min(newValue, 20)))
                }
            }
        }

        internal var _idleTimeout: NetworkDuration = .seconds(30)
        public var idleTimeout: NetworkDuration {
            get { self._idleTimeout }
            set { self._idleTimeout = newValue }
        }

        // nil = default
        // true = enabled
        // false = disabled
        public var enableL4S: Bool?

        internal var _maxUDPPayloadSize: UInt16 = UInt16.max
        var maxUDPPayloadSize: UInt16 {
            get { self._maxUDPPayloadSize }
            set { self._maxUDPPayloadSize = newValue }
        }

        internal var _maxDatagramFrameSize: UInt16 = 0
        public var maxDatagramFrameSize: UInt16 {
            get { self._maxDatagramFrameSize }
            set { self._maxDatagramFrameSize = newValue }
        }

        internal var _supportWebTransport: Bool = false
        public var supportWebTransport: Bool {
            get { self._supportWebTransport }
            set { self._supportWebTransport = newValue }
        }

        internal var _supportResetStreamAt: Bool = false
        public var supportResetStreamAt: Bool {
            get { self._supportResetStreamAt }
            set { self._supportResetStreamAt = newValue }
        }

        internal var _initialPacketSize: UInt16 = 0
        var initialPacketSize: UInt16 {
            get { self._initialPacketSize }
            set { self._initialPacketSize = newValue }
        }

        internal var _keepaliveCount: UInt16 = 0
        public var keepaliveCount: UInt16 {
            get { self._keepaliveCount }
            set { self._keepaliveCount = newValue }
        }

        internal var _ackDelaySize: UInt8 = 0
        var ackDelaySize: UInt8 {
            get { self._ackDelaySize }
            set { self._ackDelaySize = newValue }
        }

        internal var _maxPathsPerInterface: UInt8 = 0
        var maxPathsPerInterface: UInt8 {
            get { self._maxPathsPerInterface }
            set { self._maxPathsPerInterface = newValue }
        }

        internal var _keyIndex: UInt8 = 0
        var keyIndex: UInt8 {
            get { self._keyIndex }
            set { self._keyIndex = newValue }
        }

        internal var _pqtlsMode: UInt16 = 0
        var pqtlsMode: UInt16 {
            get { self._pqtlsMode }
            set { self._pqtlsMode = newValue }
        }

        public var pmtudUpdateInterval: NetworkDuration? = nil
        #if !NETWORK_STANDALONE
        var pmtudUpdateBlock: (@Sendable @convention(block) (UInt16) -> Void)? = nil
        var pmtudUpdateQueue: DispatchQueue? = nil
        #endif

        // Flag setters / getters

        public var pmtud: Bool {
            get { flags.contains(.pmtud) }
            set { if newValue { flags.insert(.pmtud) } else { flags.remove(.pmtud) } }
        }
        var pmtudIgnoreCost: Bool {
            get { flags.contains(.pmtudIgnoreCost) }
            set { if newValue { flags.insert(.pmtudIgnoreCost) } else { flags.remove(.pmtudIgnoreCost) } }
        }
        var pmtudForNonTransport: Bool {
            get { flags.contains(.pmtudForNonTransport) }
            set { if newValue { flags.insert(.pmtudForNonTransport) } else { flags.remove(.pmtudForNonTransport) } }
        }
        public var retry: Bool {
            get { flags.contains(.retry) }
            set { if newValue { flags.insert(.retry) } else { flags.remove(.retry) } }
        }
        public var forceVersionNegotiation: Bool {
            get { flags.contains(.forceVersionNegotiation) }
            set {
                if newValue { flags.insert(.forceVersionNegotiation) } else { flags.remove(.forceVersionNegotiation) }
            }
        }
        public var datagramEnableFlowID: Bool {
            get { flags.contains(.datagramEnableFlowID) }
            set { if newValue { flags.insert(.datagramEnableFlowID) } else { flags.remove(.datagramEnableFlowID) } }
        }
        public var datagramQuarterStreamID: Bool {
            get { flags.contains(.datagramQuarterStreamID) }
            set {
                if newValue { flags.insert(.datagramQuarterStreamID) } else { flags.remove(.datagramQuarterStreamID) }
            }
        }
        public var datagramContextID: Bool {
            get { flags.contains(.datagramContextID) }
            set { if newValue { flags.insert(.datagramContextID) } else { flags.remove(.datagramContextID) } }
        }
        public var disableECNEcho: Bool {
            get { flags.contains(.disableECNEcho) }
            set { if newValue { flags.insert(.disableECNEcho) } else { flags.remove(.disableECNEcho) } }
        }
        public var disableECN: Bool {
            get { flags.contains(.disableECN) }
            set { if newValue { flags.insert(.disableECN) } else { flags.remove(.disableECN) } }
        }
        var trustCerts: Bool {
            get { flags.contains(.trustCerts) }
            set { if newValue { flags.insert(.trustCerts) } else { flags.remove(.trustCerts) } }
        }
        var addH3ALPN: Bool {
            get { flags.contains(.addH3ALPN) }
            set { if newValue { flags.insert(.addH3ALPN) } else { flags.remove(.addH3ALPN) } }
        }
        var useSwiftTLS: Bool {
            get { flags.contains(.useSwiftTLS) }
            set { if newValue { flags.insert(.useSwiftTLS) } else { flags.remove(.useSwiftTLS) } }
        }
        var clientIdentityIsRawPublicKey: Bool {
            get { flags.contains(.clientIdentityIsRawPublicKey) }
            set {
                if newValue {
                    flags.insert(.clientIdentityIsRawPublicKey)
                } else {
                    flags.remove(.clientIdentityIsRawPublicKey)
                }
            }
        }
        var useX25519: Bool {
            get { flags.contains(.useX25519) }
            set { if newValue { flags.insert(.useX25519) } else { flags.remove(.useX25519) } }
        }
        var migrationForNonTransport: Bool {
            get { flags.contains(.migrationForNonTransport) }
            set {
                if newValue { flags.insert(.migrationForNonTransport) } else { flags.remove(.migrationForNonTransport) }
            }
        }
        var isSpeculativeAttempt: Bool {
            get { flags.contains(.isSpeculativeAttempt) }
            set { if newValue { flags.insert(.isSpeculativeAttempt) } else { flags.remove(.isSpeculativeAttempt) } }
        }
        public var disableSpinBit: Bool {
            get { flags.contains(.disableSpinBit) }
            set { if newValue { flags.insert(.disableSpinBit) } else { flags.remove(.disableSpinBit) } }
        }
        public var spinBitValue: Bool {
            get { flags.contains(.spinBitValue) }
            set { if newValue { flags.insert(.spinBitValue) } else { flags.remove(.spinBitValue) } }
        }
        var peerParametersOverriden: Bool {
            get { flags.contains(.peerParametersOverriden) }
            set {
                if newValue { flags.insert(.peerParametersOverriden) } else { flags.remove(.peerParametersOverriden) }
            }
        }
        var probeSimultaneously: Bool {
            get { flags.contains(.probeSimultaneously) }
            set { if newValue { flags.insert(.probeSimultaneously) } else { flags.remove(.probeSimultaneously) } }
        }
        var phoneCallRelayOptimization: Bool {
            get { flags.contains(.phoneCallRelayOptimization) }
            set {
                if newValue {
                    flags.insert(.phoneCallRelayOptimization)
                } else {
                    flags.remove(.phoneCallRelayOptimization)
                }
            }
        }
        var ignorePathErrors: Bool {
            get { flags.contains(.ignorePathErrors) }
            set { if newValue { flags.insert(.ignorePathErrors) } else { flags.remove(.ignorePathErrors) } }
        }
        var setupPlaceholder: Bool {
            get { flags.contains(.setupPlaceholder) }
            set { if newValue { flags.insert(.setupPlaceholder) } else { flags.remove(.setupPlaceholder) } }
        }
        public var disableAutomaticNewConnectionIDs: Bool {
            get { flags.contains(.disableAutomaticNewConnectionIDs) }
            set {
                if newValue {
                    flags.insert(.disableAutomaticNewConnectionIDs)
                } else {
                    flags.remove(.disableAutomaticNewConnectionIDs)
                }
            }
        }
        public var resendRejectedEarlyDataAutomatically: Bool {
            get { flags.contains(.resendRejectedEarlyDataAutomatically) }
            set {
                if newValue {
                    flags.insert(.resendRejectedEarlyDataAutomatically)
                } else {
                    flags.remove(.resendRejectedEarlyDataAutomatically)
                }
            }
        }
        public var enablePacing: Bool {
            get { flags.contains(.enablePacing) }
            set { if newValue { flags.insert(.enablePacing) } else { flags.remove(.enablePacing) } }
        }

        // Note that this flag changes sending behavior for Long Header packets that reduces efficiency. This should
        // be used for testing only.
        public var testSendingShortPackets: Bool {
            get { flags.contains(.testSendingShortPackets) }
            set {
                if newValue { flags.insert(.testSendingShortPackets) } else { flags.remove(.testSendingShortPackets) }
            }
        }

        public var forceUnsupportedClientVersion: Bool {
            get { flags.contains(.forceUnsupportedClientVersion) }
            set {
                if newValue {
                    flags.insert(.forceUnsupportedClientVersion)
                } else {
                    flags.remove(.forceUnsupportedClientVersion)
                }
            }
        }

        struct Flags: OptionSet {
            public init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            public var rawValue: UInt64
            static public let pmtud = QUICConnectionOptions.Flags(rawValue: 1 << 0)
            static public let pmtudIgnoreCost = QUICConnectionOptions.Flags(rawValue: 1 << 1)
            static public let pmtudForNonTransport = QUICConnectionOptions.Flags(rawValue: 1 << 2)
            static public let retry = QUICConnectionOptions.Flags(rawValue: 1 << 3)
            static public let forceVersionNegotiation = QUICConnectionOptions.Flags(rawValue: 1 << 4)
            static public let datagramEnableFlowID = QUICConnectionOptions.Flags(rawValue: 1 << 5)
            static public let datagramQuarterStreamID = QUICConnectionOptions.Flags(rawValue: 1 << 6)
            static public let datagramContextID = QUICConnectionOptions.Flags(rawValue: 1 << 7)
            static public let disableECNEcho = QUICConnectionOptions.Flags(rawValue: 1 << 8)
            static public let disableECN = QUICConnectionOptions.Flags(rawValue: 1 << 9)
            static public let trustCerts = QUICConnectionOptions.Flags(rawValue: 1 << 10)
            static public let addH3ALPN = QUICConnectionOptions.Flags(rawValue: 1 << 11)
            static public let useSwiftTLS = QUICConnectionOptions.Flags(rawValue: 1 << 12)
            static public let clientIdentityIsRawPublicKey = QUICConnectionOptions.Flags(rawValue: 1 << 13)
            static public let useX25519 = QUICConnectionOptions.Flags(rawValue: 1 << 14)
            static public let migrationForNonTransport = QUICConnectionOptions.Flags(rawValue: 1 << 15)
            static public let isSpeculativeAttempt = QUICConnectionOptions.Flags(rawValue: 1 << 16)
            static public let disableSpinBit = QUICConnectionOptions.Flags(rawValue: 1 << 17)
            static public let spinBitValue = QUICConnectionOptions.Flags(rawValue: 1 << 18)
            static public let peerParametersOverriden = QUICConnectionOptions.Flags(rawValue: 1 << 19)
            static public let ignorePathErrors = QUICConnectionOptions.Flags(rawValue: 1 << 20)
            static public let probeSimultaneously = QUICConnectionOptions.Flags(rawValue: 1 << 21)
            static public let phoneCallRelayOptimization = QUICConnectionOptions.Flags(rawValue: 1 << 22)
            static public let setupPlaceholder = QUICConnectionOptions.Flags(rawValue: 1 << 23)
            static public let disableAutomaticNewConnectionIDs = QUICConnectionOptions.Flags(rawValue: 1 << 24)
            static public let testSendingShortPackets = QUICConnectionOptions.Flags(rawValue: 1 << 25)
            static public let resendRejectedEarlyDataAutomatically = QUICConnectionOptions.Flags(rawValue: 1 << 26)
            static public let enablePacing = QUICConnectionOptions.Flags(rawValue: 1 << 27)
            static public let forceUnsupportedClientVersion = QUICConnectionOptions.Flags(rawValue: 1 << 28)
        }
        var flags: Flags = Flags()

        public init() {
            self.tlsOptions = TLSProtocol.options()
            self.pmtud = true
            self.pmtudIgnoreCost = false
            self.pmtudForNonTransport = false
            self.isSpeculativeAttempt = false
            self.retry = false
            self.forceVersionNegotiation = false
            self.disableSpinBit = false
            self.spinBitValue = false
            self.datagramEnableFlowID = false
            self.datagramQuarterStreamID = false
            self.disableECNEcho = false
            self.disableECN = false
            self.trustCerts = false
            self.addH3ALPN = false
            self.useSwiftTLS = false
            self.keyIndex = UInt8.max
            self.pqtlsMode = 0
            self.phoneCallRelayOptimization = false
            self.ignorePathErrors = false
            self.setupPlaceholder = false
        }

        public func serialize() -> [UInt8]? {
            nil
        }
        public var serializeInParameters: Bool {
            false
        }
        public func deepCopy() -> Self {
            let connectionOptions = Self()
            #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
            connectionOptions.privateStorage = self.privateStorage.deepCopy()
            #endif
            #if !NETWORK_PRIVATE
            connectionOptions.tlsOptions = self.tlsOptions?.deepCopy()
            #endif
            connectionOptions.initialMaxData = self.initialMaxData
            connectionOptions.maxUDPPayloadSize = self.maxUDPPayloadSize
            connectionOptions.idleTimeout = self.idleTimeout
            connectionOptions.initialMaxStreamsBidirectional = self.initialMaxStreamsBidirectional
            connectionOptions.initialMaxStreamsUnidirectional = self.initialMaxStreamsUnidirectional
            connectionOptions.initialMaxStreamDataBidirectionalLocal = self.initialMaxStreamDataBidirectionalLocal
            connectionOptions.initialMaxStreamDataBidirectionalRemote = self.initialMaxStreamDataBidirectionalRemote
            connectionOptions.initialMaxStreamDataUnidirectional = self.initialMaxStreamDataUnidirectional
            connectionOptions.peerMaxStreamDataBidirectionalLocal = self.peerMaxStreamDataBidirectionalLocal
            connectionOptions.peerMaxStreamDataBidirectionalRemote = self.peerMaxStreamDataBidirectionalRemote
            connectionOptions.peerMaxData = self.peerMaxData
            connectionOptions.peerMaxDataUnidirectional = self.peerMaxDataUnidirectional
            connectionOptions.peerMaxStreamsBidirectional = self.peerMaxStreamsBidirectional
            connectionOptions.peerMaxStreamsUnidirectional = self.peerMaxStreamsUnidirectional
            #if !NETWORK_STANDALONE
            connectionOptions.quicState = self.quicState
            connectionOptions.tlsState = self.tlsState
            connectionOptions.sessionStateUpdateBlock = self.sessionStateUpdateBlock
            connectionOptions.sessionStateUpdateQueue = self.sessionStateUpdateQueue
            connectionOptions.maxStreamsUpdateBlock = self.maxStreamsUpdateBlock
            connectionOptions.maxStreamsUpdateQueue = self.maxStreamsUpdateQueue
            #endif
            connectionOptions.keyIndex = self.keyIndex
            connectionOptions.pmtud = self.pmtud
            connectionOptions.pmtudIgnoreCost = self.pmtudIgnoreCost
            connectionOptions.pmtudForNonTransport = self.pmtudForNonTransport
            #if !NETWORK_STANDALONE
            connectionOptions.pmtudUpdateBlock = self.pmtudUpdateBlock
            connectionOptions.pmtudUpdateQueue = self.pmtudUpdateQueue
            #endif
            connectionOptions.pmtudUpdateInterval = self.pmtudUpdateInterval
            connectionOptions.migrationForNonTransport = self.migrationForNonTransport
            connectionOptions.isSpeculativeAttempt = self.isSpeculativeAttempt
            connectionOptions.retry = self.retry
            connectionOptions.datagramEnableFlowID = self.datagramEnableFlowID
            connectionOptions.datagramQuarterStreamID = self.datagramQuarterStreamID
            connectionOptions.datagramContextID = self.datagramContextID
            connectionOptions.maxDatagramFrameSize = self.maxDatagramFrameSize
            connectionOptions.supportWebTransport = self.supportWebTransport
            connectionOptions.supportResetStreamAt = self.supportResetStreamAt
            connectionOptions.initialPacketSize = self.initialPacketSize
            connectionOptions.keepaliveCount = self.keepaliveCount
            connectionOptions.forceVersionNegotiation = self.forceVersionNegotiation
            connectionOptions.ackDelaySize = self.ackDelaySize
            connectionOptions.sourceConnectionID = self.sourceConnectionID
            connectionOptions.destinationConnectionID = self.destinationConnectionID
            #if !NETWORK_NO_SWIFT_QUIC
            connectionOptions.initialStatelessResetToken = self.initialStatelessResetToken
            #endif
            connectionOptions.disableECNEcho = self.disableECNEcho
            connectionOptions.disableECN = self.disableECN
            connectionOptions.enableL4S = self.enableL4S
            connectionOptions.addH3ALPN = self.addH3ALPN
            connectionOptions.useSwiftTLS = self.useSwiftTLS
            connectionOptions.trustCerts = self.trustCerts
            connectionOptions.useX25519 = self.useX25519
            connectionOptions.pqtlsMode = self.pqtlsMode
            connectionOptions.disableSpinBit = self.disableSpinBit
            connectionOptions.spinBitValue = self.spinBitValue
            connectionOptions.peerParametersOverriden = self.peerParametersOverriden
            connectionOptions.probeSimultaneously = self.probeSimultaneously
            connectionOptions.phoneCallRelayOptimization = self.phoneCallRelayOptimization
            connectionOptions.ignorePathErrors = self.ignorePathErrors
            connectionOptions.setupPlaceholder = self.setupPlaceholder
            #if !NETWORK_NO_SWIFT_QUIC
            connectionOptions.qlogConfiguration = self.qlogConfiguration
            #endif
            connectionOptions.flags = self.flags
            return connectionOptions
        }
        public func isEqual(to other: QUICConnectionOptions, for compareMode: ProtocolCompareMode) -> Bool {
            // QUIC ignores the security options for association purposes, as the QUIC caches are not connection specific
            if compareMode == .association {
                return true
            } else {
                guard let lhsTLSOptions = self.tlsOptions,
                    let rhsTLSOptions = other.tlsOptions
                else {
                    return false
                }
                if !lhsTLSOptions.isEqual(to: rhsTLSOptions, for: compareMode) {
                    return false
                }

                #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
                guard self.privateStorage == other.privateStorage else {
                    return false
                }
                #endif

                return true
            }
        }

        public static func == (lhs: QUICConnectionOptions, rhs: QUICConnectionOptions) -> Bool {
            // Only pick a subsection of the state because certain properties are not comparable
            if lhs.initialMaxData == rhs.initialMaxData
                && lhs.initialMaxStreamDataBidirectionalLocal == rhs.initialMaxStreamDataBidirectionalLocal
                && lhs.initialMaxStreamDataBidirectionalRemote == rhs.initialMaxStreamDataBidirectionalRemote
                && lhs.initialMaxStreamDataUnidirectional == rhs.initialMaxStreamDataUnidirectional
                && lhs.initialMaxStreamsBidirectional == rhs.initialMaxStreamsBidirectional
                && lhs.initialMaxStreamsUnidirectional == rhs.initialMaxStreamsUnidirectional
                && lhs.peerMaxStreamDataBidirectionalLocal == rhs.peerMaxStreamDataBidirectionalLocal
                && lhs.peerMaxStreamDataBidirectionalRemote == rhs.peerMaxStreamDataBidirectionalRemote
                && lhs.peerMaxData == rhs.peerMaxData && lhs.peerMaxDataUnidirectional == rhs.peerMaxDataUnidirectional
                && lhs.peerMaxStreamsBidirectional == rhs.peerMaxStreamsBidirectional
                && lhs.peerMaxStreamsUnidirectional == rhs.peerMaxStreamsUnidirectional
                && lhs.idleTimeout == rhs.idleTimeout && lhs.enableL4S == rhs.enableL4S
                && lhs.maxUDPPayloadSize == rhs.maxUDPPayloadSize
                && rhs.maxDatagramFrameSize == lhs.maxDatagramFrameSize
                && lhs.initialPacketSize == rhs.initialPacketSize && lhs.keepaliveCount == rhs.keepaliveCount
                && lhs.ackDelaySize == rhs.ackDelaySize && lhs.maxPathsPerInterface == rhs.maxPathsPerInterface
                && lhs.keyIndex == rhs.keyIndex && lhs.pqtlsMode == rhs.pqtlsMode && lhs.pmtud == rhs.pmtud
                && lhs.pmtudIgnoreCost == rhs.pmtudIgnoreCost && lhs.pmtudForNonTransport == rhs.pmtudForNonTransport
                && lhs.retry == rhs.retry && lhs.forceVersionNegotiation == rhs.forceVersionNegotiation
                && lhs.datagramEnableFlowID == rhs.datagramEnableFlowID
                && lhs.datagramQuarterStreamID == rhs.datagramQuarterStreamID
                && lhs.datagramContextID == rhs.datagramContextID && lhs.disableECNEcho == rhs.disableECNEcho
                && lhs.trustCerts == rhs.trustCerts && lhs.addH3ALPN == rhs.addH3ALPN
                && lhs.useSwiftTLS == rhs.useSwiftTLS && lhs.useX25519 == rhs.useX25519
                && lhs.migrationForNonTransport == rhs.migrationForNonTransport
                && lhs.isSpeculativeAttempt == rhs.isSpeculativeAttempt && lhs.disableSpinBit == rhs.disableSpinBit
                && lhs.peerParametersOverriden == rhs.peerParametersOverriden
                && lhs.probeSimultaneously == rhs.probeSimultaneously
                && lhs.phoneCallRelayOptimization == rhs.phoneCallRelayOptimization
                && lhs.ignorePathErrors == rhs.ignorePathErrors && lhs.setupPlaceholder == rhs.setupPlaceholder
                && lhs.disableAutomaticNewConnectionIDs == rhs.disableAutomaticNewConnectionIDs
                && lhs.testSendingShortPackets == rhs.testSendingShortPackets
                && lhs.supportWebTransport == rhs.supportWebTransport
                && lhs.supportResetStreamAt == rhs.supportResetStreamAt
                && lhs.resendRejectedEarlyDataAutomatically == rhs.resendRejectedEarlyDataAutomatically
                && lhs.enablePacing == rhs.enablePacing
                && lhs.forceUnsupportedClientVersion == rhs.forceUnsupportedClientVersion
            {
                return true
            }
            return false
        }

        #if !NETWORK_STANDALONE
        func setSessionState(
            quicState: DispatchData,
            tlsState: DispatchData
        ) {
            self.tlsState = tlsState
            self.quicState = quicState
        }
        #endif

        #if os(Linux)
        func setSessionStateUpdateBlock(
            _ sessionStateUpdateBlock: (@Sendable @convention(block) ([UInt8]?, [UInt8]?) -> Void)?,
            queue: DispatchQueue
        ) {
            self.sessionStateUpdateBlock = sessionStateUpdateBlock
            self.sessionStateUpdateQueue = queue
        }
        #elseif !NETWORK_STANDALONE && canImport(Darwin)
        func setSessionStateUpdateBlock(
            _ sessionStateUpdateBlock: (@Sendable @convention(block) (DispatchData?, DispatchData?) -> Void)?,
            queue: DispatchQueue
        ) {
            self.sessionStateUpdateBlock = sessionStateUpdateBlock
            self.sessionStateUpdateQueue = queue
        }
        #endif

        #if !NETWORK_STANDALONE
        func executeSessionStateUpdateBlock(quicState: DispatchData, tlsState: DispatchData) -> Bool {
            guard let sessionUpdateBlock = self.sessionStateUpdateBlock,
                let sessionQueue = self.sessionStateUpdateQueue
            else {
                return false
            }
            // NOTE: sessionUpdateBlock is not supported in Embedded
            #if os(Linux)
            let tlsBytes = Array(tlsState[tlsState.startIndex..<tlsState.endIndex])
            let quicStateBytes = Array(quicState[quicState.startIndex..<quicState.endIndex])
            sessionQueue.async {
                sessionUpdateBlock(quicStateBytes, tlsBytes)
            }
            #elseif !NETWORK_EMBEDDED && canImport(Darwin)
            sessionQueue.async {
                sessionUpdateBlock(quicState, tlsState)
            }
            #endif
            return true
        }

        func setMaxStreamsUpdateBlock(
            _ maxStreamsUpdateBlock: (@Sendable @convention(block) (UInt8, UInt64) -> Void)?,
            queue: DispatchQueue
        ) {
            self.maxStreamsUpdateBlock = maxStreamsUpdateBlock
            self.maxStreamsUpdateQueue = queue
        }

        func executePMTUDUpdateBlock(pmtu: UInt16) {
            guard let pmtudUpdateBlock = self.pmtudUpdateBlock,
                let pmtudUpdateQueue = self.pmtudUpdateQueue
            else {
                return
            }
            pmtudUpdateQueue.async {
                pmtudUpdateBlock(pmtu)
            }
        }
        #endif

        func getRemoteTransportParameters(
            maxStreamDataBidirectionalLocal: UnsafeMutablePointer<UInt64>,
            maxStreamDataBidirectionalRemote: UnsafeMutablePointer<UInt64>,
            maxData: UnsafeMutablePointer<UInt64>,
            maxDataUnidirectional: UnsafeMutablePointer<UInt64>,
            maxStreamsBidirectional: UnsafeMutablePointer<UInt64>,
            maxStreamsUnidirectional: UnsafeMutablePointer<UInt64>
        ) -> Bool {
            maxStreamDataBidirectionalLocal.pointee = peerMaxStreamDataBidirectionalLocal
            maxStreamDataBidirectionalRemote.pointee = peerMaxStreamDataBidirectionalRemote
            maxData.pointee = peerMaxData
            maxDataUnidirectional.pointee = peerMaxDataUnidirectional
            maxStreamsBidirectional.pointee = peerMaxStreamsBidirectional
            maxStreamsUnidirectional.pointee = peerMaxStreamsUnidirectional
            return true
        }
    }

    // QUICConnectionMetadata -

    public final class QUICConnectionMetadata: PerProtocolMetadata {

        internal var _applicationError: UInt64 = UInt64.max
        public var applicationError: UInt64 {
            get { self._applicationError }
            set { self._applicationError = newValue }
        }
        public var applicationErrorReason: String?

        public var activeConnectionIDLimit: Int = 0
        public var remoteMaxDatagramFrameSize: UInt16 = 0
        #if NETWORK_PRIVATE
        var privateStorage = QUICConnectionMetadataPrivateStorage()
        #endif

        #if !NETWORK_EMBEDDED
        var setMaxDataHandler: QUICMetadataSetterHandler?
        var setMaxStreamDataBidirectionalLocalHandler: QUICMetadataSetterHandler?
        var setMaxStreamDataBidirectionalRemoteHandler: QUICMetadataSetterHandler?
        var setMaxStreamDataUnidirectionalHandler: QUICMetadataSetterHandler?
        var setLocalMaxStreamsBidirectionalHandler: QUICMetadataSetterHandler?
        var setLocalMaxStreamsUnidirectionalHandler: QUICMetadataSetterHandler?
        var getLocalMaxStreamsBidirectionalHandler: QUICMetadataGetterHandler?
        var getLocalMaxStreamsUnidirectionalHandler: QUICMetadataGetterHandler?
        var setRemoteMaxStreamsBidirectionalHandler: QUICMetadataSetterHandler?
        var setRemoteMaxStreamsUnidirectionalHandler: QUICMetadataSetterHandler?
        var getRemoteMaxStreamsBidirectionalHandler: QUICMetadataGetterHandler?
        var getRemoteMaxStreamsUnidirectionalHandler: QUICMetadataGetterHandler?
        var closeWithErrorHandler: QUICMetadataSetterHandler?
        var getPeerIdleTimeoutHandler: QUICMetadataGetterHandler?
        var setKeepaliveHandler: QUICMetadata16SetterHandler?
        var getKeepaliveHandler: QUICMetadata16GetterHandler?
        var injectPacketHandler: QUICMetadataInjectPacketHandler?
        var setApplicationResultHandler: QUICMetadataBoolSetterHandler?
        var getApplicationResultHandler: QUICMetadataGetApplicationResultHandler?
        var setLinkFlowControlledHandler: QUICMetadataBoolSetterHandler?
        var getResetStreamAtSupportedHandler: QUICMetadataBoolGetterHandler?
        #if !NETWORK_NO_SWIFT_QUIC
        var getLocalConnectionIDsHandler: (() -> [QUICConnectionID])?
        #endif
        #endif

        var isEarlyDataAccepted: Bool = false

        public init() {
            self.applicationError = UInt64.max
        }

        public func isEqual(to other: QUICConnectionMetadata, for: ProtocolCompareMode) -> Bool { true }

        public static func == (lhs: QUICConnectionMetadata, rhs: QUICConnectionMetadata) -> Bool {
            #if NETWORK_PRIVATE
            guard lhs.privateStorage == rhs.privateStorage else {
                return false
            }
            #endif
            guard lhs.applicationError == rhs.applicationError,
                lhs.applicationErrorReason == rhs.applicationErrorReason,
                lhs.isEarlyDataAccepted == rhs.isEarlyDataAccepted,
                lhs.activeConnectionIDLimit == rhs.activeConnectionIDLimit
            else {
                return false
            }

            return true
        }

        #if !NETWORK_EMBEDDED
        public func setMaxData(maxData: UInt64) {
            mutex.withLock { _ in
                guard let setMaxData = self.setMaxDataHandler else {
                    return
                }
                setMaxData(maxData)
            }
        }

        public func setMaxStreamDataBidirectionalLocal(maxStreamDataBidirectionalLocal: UInt64) {
            mutex.withLock { _ in
                guard let setMaxStreamDataBidirectionalLocal = self.setMaxStreamDataBidirectionalLocalHandler else {
                    return
                }
                setMaxStreamDataBidirectionalLocal(maxStreamDataBidirectionalLocal)
            }
        }

        public func setMaxStreamDataBidirectionalRemote(maxStreamDataBidirectionalRemote: UInt64) {
            mutex.withLock { _ in
                guard let setRemoteMaxStreamsBidirectional = self.setRemoteMaxStreamsBidirectionalHandler else {
                    return
                }
                setRemoteMaxStreamsBidirectional(maxStreamDataBidirectionalRemote)
            }
        }

        public func setMaxStreamDataUnidirectional(maxStreamDataUnidirectional: UInt64) {
            mutex.withLock { _ in
                guard let setMaxStreamDataUnidirectional = self.setMaxStreamDataUnidirectionalHandler else {
                    return
                }
                setMaxStreamDataUnidirectional(maxStreamDataUnidirectional)
            }
        }

        public func setLocalMaxStreamsBidirectional(localMaxStreamsBidirectional: UInt64) {
            mutex.withLock { _ in
                guard let setLocalMaxStreamsBidirectional = self.setLocalMaxStreamsBidirectionalHandler else {
                    return
                }
                setLocalMaxStreamsBidirectional(localMaxStreamsBidirectional)
            }
        }

        public func setLocalMaxStreamsUnidirectional(localMaxStreamsUnidirectional: UInt64) {
            mutex.withLock { _ in
                guard let setLocalMaxStreamsUnidirectional = self.setLocalMaxStreamsUnidirectionalHandler else {
                    return
                }
                setLocalMaxStreamsUnidirectional(localMaxStreamsUnidirectional)
            }
        }

        public func setRemoteMaxStreamsUnidirectional(remoteMaxStreamsUnidirectional: UInt64) {
            mutex.withLock { _ in
                guard let setRemoteMaxStreamsUnidirectional = self.setRemoteMaxStreamsUnidirectionalHandler else {
                    return
                }
                setRemoteMaxStreamsUnidirectional(remoteMaxStreamsUnidirectional)
            }
        }

        public func setRemoteMaxStreamsBidirectional(remoteMaxStreamsBidirectional: UInt64) {
            mutex.withLock { _ in
                guard let setRemoteMaxStreamsBidirectional = self.setRemoteMaxStreamsBidirectionalHandler else {
                    return
                }
                setRemoteMaxStreamsBidirectional(remoteMaxStreamsBidirectional)
            }
        }

        public func setKeepalive(keepAlive: UInt16) {
            mutex.withLock { _ in
                guard let setKeepalive = self.setKeepaliveHandler else {
                    return
                }
                setKeepalive(keepAlive)
            }
        }

        func setLinkFlowControlled(linkFlowControlled: Bool) {
            mutex.withLock { _ in
                guard let setLinkFlowControlled = self.setLinkFlowControlledHandler else {
                    return
                }
                setLinkFlowControlled(linkFlowControlled)
            }
        }

        public func closeWithError(applicationError: UInt64) {
            closeMutex.withLock { _ in
                guard let closeWithErrorHandler = self.closeWithErrorHandler else {
                    return
                }
                closeWithErrorHandler(applicationError)
            }
        }

        func injectPacket(packet: UnsafePointer<UInt8>?, length: Int) {
            mutex.withLock { _ in
                guard let packet = packet,
                    let injectPacketHander = self.injectPacketHandler
                else {
                    return
                }
                injectPacketHander(packet, length)
            }
        }

        func reportApplicationResult(success: Bool) {
            mutex.withLock { _ in
                guard let applicationResultHandler = self.setApplicationResultHandler else {
                    return
                }
                applicationResultHandler(success)
            }
        }

        func getApplicationResult(accessBlock: @escaping (UInt32, UInt32) -> Void) {
            mutex.withLock { _ in
                guard let getApplicationResult = self.getApplicationResultHandler else {
                    return
                }
                getApplicationResult(accessBlock)
            }
        }

        func setMaxData(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setMaxDataHandler = handler
            }
        }

        func setMaxStreamDataBidirectionalLocal(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setMaxStreamDataBidirectionalLocalHandler = handler
            }
        }

        func setMaxStreamDataBidirectionalRemote(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setMaxStreamDataBidirectionalRemoteHandler = handler
            }
        }

        func setMaxStreamDataUnidirectional(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setMaxStreamDataUnidirectionalHandler = handler
            }
        }

        func setLocalMaxStreamsUnidirectional(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setLocalMaxStreamsUnidirectionalHandler = handler
            }
        }

        func setLocalMaxStreamsBidirectional(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setLocalMaxStreamsBidirectionalHandler = handler
            }
        }

        func setRemoteMaxStreamsUnidirectional(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setRemoteMaxStreamsUnidirectionalHandler = handler
            }
        }

        func setRemoteMaxStreamsBidirectional(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setRemoteMaxStreamsBidirectionalHandler = handler
            }
        }

        public func setKeepalive(handler: @escaping QUICMetadata16SetterHandler) {
            mutex.withLock { _ in
                self.setKeepaliveHandler = handler
            }
        }

        func setApplicationResult(handler: @escaping QUICMetadataBoolSetterHandler) {
            mutex.withLock { _ in
                self.setApplicationResultHandler = handler
            }
        }

        func setLinkFlowControlled(handler: @escaping QUICMetadataBoolSetterHandler) {
            mutex.withLock { _ in
                self.setLinkFlowControlledHandler = handler
            }
        }

        func setCloseWithError(handler: @escaping QUICMetadataSetterHandler) {
            closeMutex.withLock { _ in
                self.closeWithErrorHandler = handler
            }
        }

        func setInjectPacket(handler: @escaping QUICMetadataInjectPacketHandler) {
            mutex.withLock { _ in
                self.injectPacketHandler = handler
            }
        }

        public func getLocalMaxStreamsUnidirectional() -> UInt64 {
            mutex.withLock { _ in
                var localMaxStreamsUnidirectional: UInt64 = 0
                guard let getLocalMaxStreamsUnidirectional = self.getLocalMaxStreamsUnidirectionalHandler else {
                    return localMaxStreamsUnidirectional
                }
                localMaxStreamsUnidirectional = getLocalMaxStreamsUnidirectional()
                return localMaxStreamsUnidirectional
            }
        }

        public func getLocalMaxStreamsBidirectional() -> UInt64 {
            mutex.withLock { _ in
                var localMaxStreamsBidirectional: UInt64 = 0
                guard let getLocalMaxStreamsBidirectional = self.getLocalMaxStreamsBidirectionalHandler else {
                    return localMaxStreamsBidirectional
                }
                localMaxStreamsBidirectional = getLocalMaxStreamsBidirectional()
                return localMaxStreamsBidirectional
            }
        }

        public func getRemoteMaxStreamsUnidirectional() -> UInt64 {
            mutex.withLock { _ in
                var remoteMaxStreams: UInt64 = 0
                guard let getRemoteMaxStreamsUnidirectional = self.getRemoteMaxStreamsUnidirectionalHandler else {
                    return remoteMaxStreams
                }
                remoteMaxStreams = getRemoteMaxStreamsUnidirectional()
                return remoteMaxStreams
            }
        }

        public func getRemoteMaxStreamsBidirectional() -> UInt64 {
            mutex.withLock { _ in
                var remoteMaxStreams: UInt64 = 0
                guard let getRemoteMaxStreamsBidirectional = self.getRemoteMaxStreamsBidirectionalHandler else {
                    return remoteMaxStreams
                }
                remoteMaxStreams = getRemoteMaxStreamsBidirectional()
                return remoteMaxStreams
            }
        }

        public func getPeerIdleTimeout() -> UInt64 {
            mutex.withLock { _ in
                var peerIdleTimeout: UInt64 = 0
                guard let getPeerIdleTimeout = self.getPeerIdleTimeoutHandler else {
                    return peerIdleTimeout
                }
                peerIdleTimeout = getPeerIdleTimeout()
                return peerIdleTimeout
            }
        }

        public func getKeepalive() -> UInt16 {
            mutex.withLock { _ in
                var keepAlive: UInt16 = 0
                guard let getKeepalive = self.getKeepaliveHandler else {
                    return keepAlive
                }
                keepAlive = getKeepalive()
                return keepAlive
            }
        }

        func getResetStreamAtSupported() -> Bool {
            mutex.withLock { _ in
                var resetStreamAtSupported: Bool = false
                guard let getResetStreamAtSupported = self.getResetStreamAtSupportedHandler else {
                    return resetStreamAtSupported
                }
                resetStreamAtSupported = getResetStreamAtSupported()
                return resetStreamAtSupported
            }
        }

        #if !NETWORK_NO_SWIFT_QUIC
        func getLocalConnectionIDs() -> [QUICConnectionID] {
            mutex.withLock { _ in
                var localConnectionIDs: [QUICConnectionID] = []
                guard let getLocalConnectionIDs = self.getLocalConnectionIDsHandler else {
                    return localConnectionIDs
                }
                localConnectionIDs = getLocalConnectionIDs()
                return localConnectionIDs
            }
        }
        #endif

        func getLocalMaxStreamsUnidirectional(handler: @escaping QUICMetadataGetterHandler) {
            mutex.withLock { _ in
                self.getLocalMaxStreamsUnidirectionalHandler = handler
            }
        }

        func getLocalMaxStreamsBidirectional(handler: @escaping QUICMetadataGetterHandler) {
            mutex.withLock { _ in
                self.getLocalMaxStreamsBidirectionalHandler = handler
            }
        }

        func getRemoteMaxStreamsUnidirectional(handler: @escaping QUICMetadataGetterHandler) {
            mutex.withLock { _ in
                self.getRemoteMaxStreamsUnidirectionalHandler = handler
            }
        }

        func getRemoteMaxStreamsBidirectional(handler: @escaping QUICMetadataGetterHandler) {
            mutex.withLock { _ in
                self.getRemoteMaxStreamsBidirectionalHandler = handler
            }
        }

        func getPeerIdleTimeout(handler: @escaping QUICMetadataGetterHandler) {
            mutex.withLock { _ in
                self.getPeerIdleTimeoutHandler = handler
            }
        }

        func getKeepalive(handler: @escaping QUICMetadata16GetterHandler) {
            mutex.withLock { _ in
                self.getKeepaliveHandler = handler
            }
        }

        func getApplicationResult(handler: @escaping QUICMetadataGetApplicationResultHandler) {
            mutex.withLock { _ in
                self.getApplicationResultHandler = handler
            }
        }

        func getResetStreamAtSupported(handler: @escaping QUICMetadataBoolGetterHandler) {
            mutex.withLock { _ in
                self.getResetStreamAtSupportedHandler = handler
            }
        }

        #if !NETWORK_NO_SWIFT_QUIC
        func getLocalConnectionIDs(handler: @escaping () -> [QUICConnectionID]) {
            mutex.withLock { _ in
                self.getLocalConnectionIDsHandler = handler
            }
        }
        #endif

        func executeLocked(block: () -> Void) {
            mutex.withLock { _ in
                block()
            }
        }

        let mutex = NetworkMutex<Void>(())
        let closeMutex = NetworkMutex(())  // Protects closeWithError().
        #endif
    }

    public init() {}
    public func newPerProtocolOptions() -> QUICConnectionOptions? { QUICConnectionOptions() }
    public func newPerProtocolOptions(from existing: QUICConnectionOptions) -> QUICConnectionOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> QUICConnectionOptions? { nil }
    public func newPerProtocolMetadata() -> QUICConnectionMetadata? { QUICConnectionMetadata() }
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        QUICConnection(context: context).reference
    }

    static let identifier = ProtocolIdentifier(name: "quic-connection", level: .transport, mapping: .manyToOne)

    #if !NETWORK_PRIVATE
    static let definition = ProtocolDefinition<QUICConnectionProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<QUICConnectionProtocol> {
        QUICConnectionProtocol.definition.protocolOptions()
    }
}
