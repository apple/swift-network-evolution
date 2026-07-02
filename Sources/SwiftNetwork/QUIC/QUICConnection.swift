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

#if !NETWORK_NO_SWIFT_QUIC

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

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum QUICConnectionState: CustomStringConvertible {
    case invalid

    // Server only when parsing
    case idle

    // Server
    case versionSent
    case retrySent
    case initialReceived
    case initialProcessed

    // Client
    case versionReceived
    case initialSent
    case retryReceived

    // Client & Server
    case handshake
    case connected

    // Termination
    case closing
    case draining

    public var description: String {
        switch self {
        case .invalid: return "invalid"
        case .idle: return "idle"
        case .versionSent: return "versionSent"
        case .retrySent: return "retrySent"
        case .initialReceived: return "initialReceived"
        case .initialProcessed: return "initialProcessed"
        case .versionReceived: return "versionReceived"
        case .initialSent: return "initialSent"
        case .retryReceived: return "retryReceived"
        case .handshake: return "handshake"
        case .connected: return "connected"
        case .closing: return "closing"
        case .draining: return "draining"
        }
    }

    func isValidStateChange(to newState: QUICConnectionState, logIDString: String) -> Bool {
        switch (self, newState) {
        case (.invalid, .idle),
            (.idle, .initialReceived),
            (.idle, .initialSent),
            (.idle, .retrySent),
            (.idle, .versionSent),
            (.versionSent, .retrySent),
            (.versionSent, .closing),
            (.versionSent, .draining),
            (.versionSent, .initialReceived),
            (.versionReceived, .closing),
            (.versionReceived, .initialSent),
            (.versionReceived, .draining),
            (.initialSent, .versionReceived),
            (.initialSent, .retryReceived),
            (.initialSent, .handshake),
            (.initialSent, .closing),
            (.initialSent, .draining),
            (.initialReceived, .initialProcessed),
            (.initialReceived, .handshake),
            (.initialReceived, .closing),
            (.initialReceived, .draining),
            (.initialProcessed, .handshake),
            (.initialProcessed, .closing),
            (.initialProcessed, .draining),
            (.retryReceived, .initialSent),
            (.retryReceived, .draining),
            (.retrySent, .initialReceived),
            (.retrySent, .draining),
            (.handshake, .connected),
            (.handshake, .closing),
            (.handshake, .draining),
            (.connected, .closing),
            (.connected, .draining),
            (.closing, .draining):
            return true
        default:
            Logger.proto.fault(
                "\(logIDString) Invalid connection state transition: \(self) -> \(newState)"
            )
            return false
        }
    }

    mutating func change(to newState: QUICConnectionState, logIDString: String) {
        #if !DisableDebugLogging
        let loggableSelf = self
        Logger.proto.debug(
            "\(logIDString) connection state transition: \(loggableSelf) -> \(newState)"
        )
        #endif
        _ = isValidStateChange(to: newState, logIDString: logIDString)
        self = newState
    }

    var isTerminal: Bool {
        switch self {
        case .closing, .draining:
            return true
        default:
            return false
        }
    }

    var isConnected: Bool {
        switch self {
        case .connected, .closing, .draining:
            return true
        default:
            return false
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICConnection: ManyToManyApplicationStreamProtocol,
    ManyToManyApplicationDatagramProtocol, ManyToManyOutboundDatagramProtocol,
    StreamListenerHandler, HeterogeneousManyToManyProtocolHandler, TimerSchedulable,
    ProtocolInstanceContainer
{
    public var inboundFlowLinkage = InboundStreamFlowLinkage()
    public var secondaryInboundFlowLinkage = InboundDatagramFlowLinkage()

    public var multiplexedFlows = [MultiplexedFlowIdentifier: QUICStreamInstance]()
    public var multiplexedSecondaryFlows = [MultiplexedFlowIdentifier: QUICDatagramFlow]()
    public var multiplexingPaths = [MultiplexingPathIdentifier: QUICPath]()

    public typealias Flow = QUICStreamInstance
    public typealias UpperProtocol = InboundStreamFlowLinkage

    public typealias SecondaryFlow = QUICDatagramFlow
    public typealias SecondaryUpperProtocol = InboundDatagramFlowLinkage

    public typealias Path = QUICPath

    public var reference: ProtocolInstanceReference { ProtocolInstanceReference(quic: self) }

    public var log = NetworkLoggerState()
    var logPrefixer: LogPrefixer

    public private(set) var context: NetworkContext

    public var eventManager = ProtocolEventManager()

    public var state: QUICConnectionState = .invalid
    var flowControlState = FlowControlState(isStream: false)

    // All the CIDs advertised to the peer
    private(set) var localCIDs = QUICConnectionIDList()
    private var nextLocalCIDSequenceNumber: UInt64 = 1
    private var largestSentLocalCIDSequenceNumber: UInt64 = 1

    // All the CIDs advertised by the peer
    var remoteCIDs = QUICConnectionIDList()

    // The largest "retire prior to" value received
    private var retiredRemoteCIDSequenceNumberThreshold: UInt64 = 0

    private(set) var remoteTransportParametersForEarlyData = false
    private(set) var remoteTransportParameters: TransportParameters?
    private(set) var localTransportParameters: TransportParameters
    private(set) var connectionMetadata = QUICConnectionProtocol.QUICConnectionMetadata()

    private(set) var packetParser: PacketParser

    private(set) var keyState = PacketKeyState.initial
    var remoteMaxDatagramFrameSize = 0
    var remoteMaximumUDPPayloadSize = 0

    var timer: Timer
    private(set) var ack: Ack
    private(set) var ecn: ECN
    var recovery: Recovery
    private(set) var migration = Migration()
    private(set) var crypto: QUICCrypto

    var protector: Protector

    // Values for recovery that need to be stored on the main connection
    private var largestAckedInitialPacketNumber: PacketNumber = .none
    private var largestAckedHandshakePacketNumber: PacketNumber = .none
    private var largestAckedApplicationPacketNumber: PacketNumber = .none
    func largestAckedPacketNumber(space: PacketNumberSpace) -> PacketNumber {
        switch space {
        case .initial: return largestAckedInitialPacketNumber
        case .handshake: return largestAckedHandshakePacketNumber
        case .applicationData: return largestAckedApplicationPacketNumber
        }
    }
    func setLargestAckedPacketNumber(_ number: PacketNumber, space: PacketNumberSpace) {
        switch space {
        case .initial: largestAckedInitialPacketNumber = number
        case .handshake: largestAckedHandshakePacketNumber = number
        case .applicationData: largestAckedApplicationPacketNumber = number
        }
    }

    private(set) var handshakeStartTime: NetworkClock.Instant = .zero
    private(set) var handshakeDuration: NetworkDuration = .zero
    private(set) var handshakeRTT: NetworkDuration = .zero
    private(set) var idleTimeout: NetworkDuration = .zero

    var keepaliveDuration: NetworkDuration = .zero
    var keepaliveTimerID: Timer.TimerID?
    var maxKeepaliveCount = 0
    var unackedKeepaliveCount = 0

    var currentInboundReceiveTimestamp: NetworkClock.Instant?
    var currentSendTimestamp: NetworkClock.Instant?

    @_optimize(speed)
    @inline(__always)
    var now: NetworkClock.Instant {
        if let currentInboundReceiveTimestamp {
            return currentInboundReceiveTimestamp
        } else if let currentSendTimestamp {
            return currentSendTimestamp
        } else {
            return NetworkClock.Instant.now
        }
    }

    var lastPacketReceivedTimestamp: NetworkClock.Instant = .zero
    var lastAckElicitingPacketSentTimestamp: NetworkClock.Instant = .zero
    var lastShorthandTimestamp: NetworkClock.Instant = .zero

    var idleTimerID: Timer.TimerID?
    var logIDNumber: Int = 0
    let signpostID = QUICSignpost.makeSignpostID()
    var signpostConnectInterval: QUICSignpost.IntervalState?

    // Initial version set by client or server
    var initialVersion: QUICVersion? = Constants.defaultVersion
    // The final QUIC version negotiated
    var negotiatedVersion: QUICVersion?
    // Used to return the most up to date version
    public var currentVersion: QUICVersion {
        // If negotiated version is set then this is the final version
        if let negotiatedVersion {
            return negotiatedVersion
        }
        return initialVersion ?? .v1
    }
    public var forceUnsupportedClientVersion: Bool = false

    // MARK: Streams

    var unidirectionalStreams = QUICStreamIDState(.unidirectional)
    var bidirectionalStreams = QUICStreamIDState(.bidirectional)

    private(set) var zombieStreamList = QUICStreamZombieList()

    // List of streams that have app input data in their reassembly queue.
    var pendingReassemblyDequeue = QUICStreamList.pendingReassemblyDequeueList()

    private(set) var knownFlows = [QUICStreamID: MultiplexedFlowIdentifier]()

    private(set) var localCIDLength: Int = 0
    private var initialSourceConnectionID: QUICConnectionID?
    private var initialStatelessResetToken: QUICStatelessResetToken?
    private var disableAutomaticNewConnectionIDs = false
    private var resendRejectedEarlyDataAutomatically = false

    private(set) var allowPMTUD = false
    private(set) var pmtudIgnoreCost = false
    private(set) var pmtudInterval: NetworkDuration? = nil

    private(set) var earlyDataAccepted = false
    private var drainingScheduled = false

    fileprivate var flowsHaveEverMarkedIdle = false

    // MARK: Path

    var currentPath: QUICPath?

    private(set) var initialMSS = Constants.initialMSS
    private(set) var pathPropertiesMTU = 0

    var isPacing: Bool = false

    // MARK: Logging
    public var qlogConfiguration: QLogConfiguration?
    private(set) var qLog: QLog?

    var stats: Statistics

    var logIDString: String { self.log.logPrefix }
    var initialInterface: Interface? = nil

    // MARK: Flags

    private(set) var isServer = false
    private(set) var isCancelled = false
    var hasSentDataBlocked = false
    private(set) var versionReceived = false
    private(set) var retryReceived = false
    private var retrySCID: QUICConnectionID?
    private(set) var spinBitEnabled = false
    private(set) var autoReceivedBuffer = false
    private(set) var outboundDataPending = false
    private(set) var trafficManagementBackground = false
    private(set) var initialKeysDiscarded = false
    private(set) var receivedHandshakePacket = false
    var discardCryptoFrames = false
    private(set) var initialSpinValue = false
    private(set) var retryEnabled = false
    var earlyDataSignalled = false
    private(set) var inError = false
    var hasAdvertisedMaxData = false
    private(set) var waitingForOutstandingKeepAliveAcks = false
    private(set) var tlsOptions: SwiftTLSProtocol.Options?
    private(set) var testSendingShortPackets = false
    private(set) var migrationSupported = false

    // false == IPv6, true == IPv4
    private(set) var initialAddressIsIPv4 = false

    #if NETWORK_EMBEDDED
    let isL4SEnabled = false
    #else
    private(set) var isL4SEnabled = false
    #endif
    private(set) var isHandshakeConfirmed = false

    public var pacingEnabled: Bool = false

    private(set) var datagramUseQuarterStreamID = false
    var datagramUseContextID = false
    var datagramEnableFlowID = false

    private(set) var maximumConcurrentBidirectionalStreams: Int?
    private(set) var maximumConcurrentUnidirectionalStreams: Int?

    private var originalDCID: QUICConnectionID
    var initialDCID: QUICConnectionID?
    var initialToken: [UInt8]?
    var newToken: [UInt8]?

    var closeFrameType: FrameType?

    // The error code and reason sent/received in a CONNECTION_CLOSE frame.
    public var closeError: QUICTransportError?
    var receivedConnectionClose = false

    // The error code and reason sent/received in an APPLICATION_CLOSE frame.
    public var applicationCloseError: QUICApplicationError?
    var receivedApplicationClose = false

    // The error to be reported to app when draining or
    // closing the connection.
    var errorToReport: NetworkError?

    func withCurrentPath(_ block: (borrowing QUICPath) -> Void) {
        guard let currentPath else { return }
        block(currentPath)
    }

    func withCurrentPath(_ block: (borrowing QUICPath) -> Bool) -> Bool {
        guard let currentPath else { return false }
        return block(currentPath)
    }

    public init(context: NetworkContext) {
        self.context = context
        self.logPrefixer = LogPrefixer("[C?]")
        self.packetParser = PacketParser(logPrefixer: self.logPrefixer)
        ack = Ack(logPrefixer: self.logPrefixer)

        let defaultServerCIDLength = 8

        let dcid = QUICConnectionID(defaultServerCIDLength)
        originalDCID = dcid
        protector = Protector(isClient: true, destinationCID: dcid, logPrefixer: self.logPrefixer)
        crypto = QUICCrypto(context: context)

        self.recovery = Recovery(logPrefixer: self.logPrefixer)
        self.localTransportParameters = TransportParameters(logPrefixer: self.logPrefixer)
        self.timer = Timer(logPrefixer: self.logPrefixer)
        self.ecn = ECN()
        self.stats = Statistics()
    }

    public func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        self.isServer = parameters?.isServer ?? false
        self.logPrefixer.log.logPrefix = self.log.logPrefix
        self.initialInterface = path?.directInterface ?? nil
        self.logPrefixer.logIDString = ""

        state.change(to: .idle, logIDString: logPrefixer.logIDString)

        // Setup metadata callbacks
        self.setMetadataHandlers()

        self.timer = Timer(reference: self.reference, logPrefixer: logPrefixer)
        let ackTimerID = timer.insert(description: "ACK") {
            self.ack.timerFired(timeNow: .now)
        }
        self.ack = Ack(connection: self, timerID: ackTimerID, logPrefixer: logPrefixer)

        let recoveryTimerID = timer.insert(description: "Recovery") {
            self.recovery.timerFired(timeNow: .now)
        }
        self.recovery = Recovery(
            connection: self,
            timerID: recoveryTimerID,
            logPrefixer: logPrefixer
        )

        migration.timerID = timer.insert(description: "Migration") {
            self.migration.timerFired(connection: self)
        }

        if let remote, case .address(let remoteAddress) = remote.type,
            case .v4 = remoteAddress.type
        {
            initialAddressIsIPv4 = true
        }

        if let path {
            pathPropertiesMTU = path.mtu
        }

        if let parameters,
            let quicOptions = quicOptions(from: parameters, for: .allFlows),
            let protocolOptions = quicOptions.perProtocolOptions
        {
            self.logIDNumber = quicOptions.logIDNumber ?? 0
            var enableECN = true
            var enableECNEcho = true
            var enableL4s: Bool? = nil  // Default
            enableECN = !protocolOptions.quicConnectionOptions.disableECN
            enableECNEcho = !protocolOptions.quicConnectionOptions.disableECNEcho
            enableL4s = protocolOptions.quicConnectionOptions.enableL4S
            if isServer {
                retryEnabled = protocolOptions.quicConnectionOptions.retry
                // Stateless Reset Token
                let statelessResetToken = TransportParameter.statelessResetToken(
                    statelessResetToken: QUICStatelessResetToken()
                )
                localTransportParameters.append(statelessResetToken)
            } else {
                // A client can force version negotiation by setting the initial version to the negotiationPattern (0x?a?a?a?a)
                if protocolOptions.quicConnectionOptions.forceVersionNegotiation {
                    self.initialVersion = .negotiationPattern
                    log.info("Setting negotiation pattern")
                }
            }
            if let initialSCID = protocolOptions.quicConnectionOptions.initialSourceConnectionID {
                initialSourceConnectionID = initialSCID
            }
            if let statelessResetToken = protocolOptions.quicConnectionOptions
                .initialStatelessResetToken
            {
                initialStatelessResetToken = statelessResetToken
            }
            disableAutomaticNewConnectionIDs =
                protocolOptions.quicConnectionOptions.disableAutomaticNewConnectionIDs
            resendRejectedEarlyDataAutomatically =
                protocolOptions.quicConnectionOptions.resendRejectedEarlyDataAutomatically
            if protocolOptions.quicConnectionOptions.keepaliveCount > 0 {
                maxKeepaliveCount = Int(protocolOptions.quicConnectionOptions.keepaliveCount)
            }

            allowPMTUD = protocolOptions.quicConnectionOptions.pmtud
            pmtudIgnoreCost = protocolOptions.quicConnectionOptions.pmtudIgnoreCost
            pmtudInterval = protocolOptions.quicConnectionOptions.pmtudUpdateInterval

            pacingEnabled = protocolOptions.quicConnectionOptions.enablePacing

            testSendingShortPackets =
                protocolOptions.quicConnectionOptions.testSendingShortPackets

            forceUnsupportedClientVersion = protocolOptions.quicConnectionOptions.forceUnsupportedClientVersion

            qlogConfiguration = protocolOptions.quicConnectionOptions.qlogConfiguration

            datagramUseQuarterStreamID =
                protocolOptions.quicConnectionOptions.datagramQuarterStreamID
            datagramUseContextID = protocolOptions.quicConnectionOptions.datagramContextID
            datagramEnableFlowID = protocolOptions.quicConnectionOptions.datagramEnableFlowID

            maximumConcurrentBidirectionalStreams =
                protocolOptions.quicConnectionOptions.maximumConcurrentBidirectionalStreams
            maximumConcurrentUnidirectionalStreams =
                protocolOptions.quicConnectionOptions.maximumConcurrentUnidirectionalStreams

            if let currentPath {
                currentPath.pacePackets = pacingEnabled
                currentPath.setupL4SState(l4sEnabled: enableL4s)
                if currentPath.l4sEnabled && QUICPreferences.shared.ackCompressionEnabled {
                    // Disable ACK compression when L4S is enabled.
                    ack.disableAckCompression = true
                }
            }
            if !protocolOptions.quicConnectionOptions.disableSpinBit {
                // RFC9000: "Even when the spin bit is not disabled by
                // the administrator, endpoints MUST disable their use
                // of the spin bit for a random selection of at least
                // one in every 16 network paths, or for one in every
                // 16 connection IDs, in order to ensure that QUIC
                // connections that disable the spin bit are commonly
                // observed on the network."
                var randomNumberGenerator = SystemRandomNumberGenerator()
                spinBitEnabled = UInt8.random(in: 0..<16, using: &randomNumberGenerator) > 0
                if !spinBitEnabled {
                    // It's recommended that the spin value is set
                    // to a random value when we are not using the spin bit.
                    initialSpinValue = UInt8.random(in: 0...1) > 0
                }
            } else {
                // The application has asked us to disable the spin bit.
                spinBitEnabled = false
                initialSpinValue = protocolOptions.quicConnectionOptions.spinBitValue
            }
            // Setup ECN
            ecn = ECN(
                echoEnabled: enableECNEcho,
                markingEnabled: enableECN,
                l4sEnabled: enableL4s,
                connection: self,
                logPrefixer: self.logPrefixer
            )
            setupLocalTransportParameters(quicOptions: quicOptions)

            tlsOptions = quicOptions.tlsOptions
        }
        #if QlogOutput
        // There are 2 ways to setup a Qlog directory, one through the configuration and one through Preferences
        if qlogConfiguration == nil && QUICPreferences.shared.quiclogDirectory != "" {
            qlogConfiguration = QLogConfiguration(logPath: QUICPreferences.shared.quiclogDirectory)
        }
        // Only setup qlog if the directory is set
        if let qlogConfiguration {
            self.qLog = QLog(configuration: qlogConfiguration)
            log.info("qlog setup with configuration: \(qlogConfiguration)")
        }
        #endif
        log.info("Setup QUIC connection (spin bit \(spinBitEnabled ? "enabled" : "disabled"))")
    }

    public func setup(
        flow flowID: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {

        guard let parameters,
            let quicOptions = quicOptions(from: parameters, for: flowID),
            let protocolOptions = quicOptions.perProtocolOptions
        else {
            throw NetworkError.posix(EINVAL)
        }

        if protocolOptions.isDatagram {
            guard let datagramFlow = secondaryFlow(for: flowID) else {
                throw NetworkError.posix(ENOENT)
            }
            setupNewDatagramFlow(datagramFlow, with: protocolOptions)
        } else {
            guard let stream = flow(for: flowID) else {
                throw NetworkError.posix(ENOENT)
            }
            setupNewOutboundStream(stream, with: protocolOptions)
        }
    }

    deinit {
        self.qLog = nil
    }

    func setMSS(_ newMSS: Int, on path: QUICPath) {
        if _slowPath(newMSS < Constants.initialMSS) {
            path.mss = Constants.initialMSS
        } else if path.maximumMSS > Constants.initialMSS && newMSS > path.maximumMSS {
            path.mss = path.maximumMSS
        } else if newMSS < path.initialMSS {
            path.mss = path.initialMSS
        } else {
            path.mss = newMSS
        }
        path.congestionControlMSSChanged(mss: path.mss)
        if path == currentPath {
            applyToAllSecondaryFlows { datagramFlow in
                datagramFlow.updateUsableDatagramFrameSize(connection: self, path: path)
            }
        }
    }

    func setInitialMSS(on path: QUICPath) {
        setMSS(initialMSS, on: path)
    }

    func updateMaxBidirectionalStreamsFromApplication(_ maximumStreams: Int) {
        let newMaxStreams = max(maximumStreams, self.bidirectionalStreams.localMaxStreams)
        if newMaxStreams > Constants.maxStreamLimit {
            self.close(with: .streamLimitError, "MAX_STREAMS value over limit")
            self.log.error("Received MAX_STREAMS value too large: \(maximumStreams)")
            return
        }
        log.notice("Advertising MAX_STREAMS bidi: \(newMaxStreams)")
        self.withMutableQUICStreams(unidirectional: false) {
            mutableStreamsState in
            mutableStreamsState.updateLocalMaxStreams(
                server: self.isServer,
                newMaxStreams: Int(newMaxStreams),
                logIDString: self.logPrefixer.logIDString
            )
        }
        self.sendMaxStreamsBidirectional()

        // Trigger sending, since this is an otherwise external event
        self.sendFrames()
    }

    func updateMaxUnidirectionalStreamsFromApplication(_ maximumStreams: Int) {
        let newMaxStreams = max(maximumStreams, self.unidirectionalStreams.localMaxStreams)
        if newMaxStreams > Constants.maxStreamLimit {
            self.close(with: .streamLimitError, "MAX_STREAMS value over limit")
            self.log.error("Received MAX_STREAMS value too large: \(maximumStreams)")
            return
        }
        log.notice("Advertising MAX_STREAMS uni: \(newMaxStreams)")
        self.withMutableQUICStreams(unidirectional: true) {
            mutableStreamsState in
            mutableStreamsState.updateLocalMaxStreams(
                server: self.isServer,
                newMaxStreams: Int(newMaxStreams),
                logIDString: self.logPrefixer.logIDString
            )
        }
        self.sendMaxStreamsUnidirectional()

        // Trigger sending, since this is an otherwise external event
        self.sendFrames()
    }

    func setMetadataHandlers() {

        // Set handlers

        #if !NETWORK_EMBEDDED
        // Setup the local_max_streams_bidirectional_handler
        self.connectionMetadata.setLocalMaxStreamsBidirectional { maxStreams in
            self.updateMaxBidirectionalStreamsFromApplication(Int(maxStreams))
        }

        self.connectionMetadata.setLocalMaxStreamsUnidirectional { (maxStreams: UInt64) in
            self.updateMaxUnidirectionalStreamsFromApplication(Int(maxStreams))
        }

        self.connectionMetadata.setKeepalive { (keepaliveSeconds: UInt16) in
            if keepaliveSeconds == Constants.defaultKeepaliveValue {
                self.keepaliveConfigure(duration: Constants.defaultKeepaliveDuration)
            } else {
                self.keepaliveConfigure(duration: .seconds(keepaliveSeconds))
            }
        }

        // Get handlers
        self.connectionMetadata.getLocalMaxStreamsBidirectional {
            let localMaxStreams = UInt64(self.bidirectionalStreams.localMaxStreams)
            self.log.debug("Local bidi max_streams=\(localMaxStreams)")
            return localMaxStreams
        }
        self.connectionMetadata.getLocalMaxStreamsUnidirectional {
            let localMaxStreams = UInt64(self.unidirectionalStreams.localMaxStreams)
            self.log.debug("Local uni max_streams=\(localMaxStreams)")
            return localMaxStreams
        }
        self.connectionMetadata.getRemoteMaxStreamsBidirectional {
            let remoteMaxStreams = UInt64(self.bidirectionalStreams.remoteMaxStreams)
            self.log.debug("Remote bidi max_streams=\(remoteMaxStreams)")
            return remoteMaxStreams
        }
        self.connectionMetadata.getRemoteMaxStreamsUnidirectional {
            let remoteMaxStreams = UInt64(self.unidirectionalStreams.remoteMaxStreams)
            self.log.debug("Remote uni max_streams=\(remoteMaxStreams)")
            return remoteMaxStreams
        }
        self.connectionMetadata.getKeepalive {
            let keepaliveSeconds = self.keepaliveDuration.seconds
            return UInt16(keepaliveSeconds)
        }

        self.connectionMetadata.getLocalConnectionIDs {
            self.localCIDs.managedConnectionIDs.map { $0.connectionID }
        }
        #endif
    }

    func unsetMetadataHandlers() {
        #if !NETWORK_EMBEDDED
        // Explicitly break any strongly captured references to self from setMetadataHandlers
        self.connectionMetadata.setKeepaliveHandler = nil
        self.connectionMetadata.getKeepaliveHandler = nil
        self.connectionMetadata.setLocalMaxStreamsBidirectionalHandler = nil
        self.connectionMetadata.setLocalMaxStreamsUnidirectionalHandler = nil
        self.connectionMetadata.getLocalMaxStreamsBidirectionalHandler = nil
        self.connectionMetadata.getLocalMaxStreamsUnidirectionalHandler = nil
        self.connectionMetadata.getRemoteMaxStreamsBidirectionalHandler = nil
        self.connectionMetadata.getRemoteMaxStreamsUnidirectionalHandler = nil
        self.connectionMetadata.getLocalConnectionIDsHandler = nil
        #endif
    }

    func validateRemoteTransportParametersUpdate(
        fromEarlyData old: TransportParameters,
        updated new: TransportParameters
    ) {
        guard earlyDataAccepted else { return }

        // If 0-RTT data is accepted by the server, the server MUST NOT reduce any limits
        // or alter any values that might be violated by the client with its 0-RTT data.
        // In particular, a server that accepts 0-RTT data MUST NOT set values for the
        // following parameters that are smaller than the remembered values of the parameters.
        //
        // - active_connection_id_limit
        // - initial_max_data
        // - initial_max_stream_data_bidi_local
        // - initial_max_stream_data_bidi_remote
        // - initial_max_stream_data_uni
        // - initial_max_streams_bidi
        // - initial_max_streams_uni

        let oldCIDLimit = old.intValue(.activeConnectionIDLimit)
        let newCIDLimit = new.intValue(.activeConnectionIDLimit)
        guard newCIDLimit >= oldCIDLimit else {
            log.error(
                "Server reduced active_connection_id_limit from \(oldCIDLimit) to \(newCIDLimit)"
            )
            close(with: .protocolViolation, "Server reduced active_connection_id_limit")
            return
        }

        let oldInitialMaxData = old.intValue(.initialMaxData)
        let newInitialMaxData = new.intValue(.initialMaxData)
        guard newInitialMaxData >= oldInitialMaxData else {
            log.error(
                "Server reduced initial_max_data from \(oldInitialMaxData) to \(newInitialMaxData)"
            )
            close(with: .protocolViolation, "Server reduced initial_max_data")
            return
        }

        let oldInitialMaxStreamDataBidiLocal = old.intValue(.initialMaxStreamDataBidirectionalLocal)
        let newInitialMaxStreamDataBidiLocal = new.intValue(.initialMaxStreamDataBidirectionalLocal)
        guard newInitialMaxStreamDataBidiLocal >= oldInitialMaxStreamDataBidiLocal else {
            log.error(
                "Server reduced initial_max_stream_data_bidi_local from \(oldInitialMaxStreamDataBidiLocal) to \(newInitialMaxStreamDataBidiLocal)"
            )
            close(with: .protocolViolation, "Server reduced initial_max_stream_data_bidi_local")
            return
        }

        let oldInitialMaxStreamDataBidiRemote = old.intValue(
            .initialMaxStreamDataBidirectionalRemote
        )
        let newInitialMaxStreamDataBidiRemote = new.intValue(
            .initialMaxStreamDataBidirectionalRemote
        )
        guard newInitialMaxStreamDataBidiRemote >= oldInitialMaxStreamDataBidiRemote else {
            log.error(
                "Server reduced initial_max_stream_data_bidi_remote from \(oldInitialMaxStreamDataBidiRemote) to \(newInitialMaxStreamDataBidiRemote)"
            )
            close(with: .protocolViolation, "Server reduced initial_max_stream_data_bidi_remote")
            return
        }

        let oldInitialMaxStreamDataUni = old.intValue(.initialMaxStreamDataUnidirectional)
        let newInitialMaxStreamDataUni = new.intValue(.initialMaxStreamDataUnidirectional)
        guard newInitialMaxStreamDataUni >= oldInitialMaxStreamDataUni else {
            log.error(
                "Server reduced initial_max_stream_data_uni from \(oldInitialMaxStreamDataUni) to \(newInitialMaxStreamDataUni)"
            )
            close(with: .protocolViolation, "Server reduced initial_max_stream_data_uni")
            return
        }

        let oldInitialMaxStreamsBidi = old.intValue(.initialMaxStreamsBidirectional)
        let newInitialMaxStreamsBidi = new.intValue(.initialMaxStreamsBidirectional)
        guard newInitialMaxStreamsBidi >= oldInitialMaxStreamsBidi else {
            log.error(
                "Server reduced initial_max_streams_bidi from \(oldInitialMaxStreamsBidi) to \(newInitialMaxStreamsBidi)"
            )
            close(with: .protocolViolation, "Server reduced initial_max_streams_bidi")
            return
        }

        let oldInitialMaxStreamsUni = old.intValue(.initialMaxStreamsUnidirectional)
        let newInitialMaxStreamsUni = new.intValue(.initialMaxStreamsUnidirectional)
        guard newInitialMaxStreamsUni >= oldInitialMaxStreamsUni else {
            log.error(
                "Server reduced initial_max_streams_uni from \(oldInitialMaxStreamsUni) to \(newInitialMaxStreamsUni)"
            )
            close(with: .protocolViolation, "Server reduced initial_max_streams_uni")
            return
        }
    }

    // Set the remote transport parameter values, received as part of the TLS handshake
    // Validation and application to the connection occurs later, when
    // applyRemoteTransportParameters() is called after the handshake completes
    func setRemoteTransportParameters(
        _ remoteTransportParameters: TransportParameters,
        earlyData: Bool
    ) {
        if remoteTransportParametersForEarlyData, !earlyData,
            let fromEarlyData = self.remoteTransportParameters
        {
            validateRemoteTransportParametersUpdate(
                fromEarlyData: fromEarlyData,
                updated: remoteTransportParameters
            )
        }

        self.remoteTransportParametersForEarlyData = earlyData
        self.remoteTransportParameters = remoteTransportParameters
    }

    // Application and validation of the parameters occurs here. This checks that
    // the transport parameter values match the connection values (CIDs, etc),
    // and updates state on the connection
    func applyRemoteTransportParameters(_ remoteTransportParameters: TransportParameters) {
        // An endpoint MUST treat any of the following as a connection
        // error of type PROTOCOL_VIOLATION:
        //
        // - absence of the initial_source_connection_id transport parameter
        // from either endpoint,
        // - absence of the original_destination_connection_id transport
        // parameter from the server,
        // - absence of the retry_source_connection_id transport parameter
        // from the server after receiving a Retry packet,
        // - presence of the retry_source_connection_id transport parameter
        // when no Retry packet was received, or
        // - a mismatch between values received from a peer in these transport
        // parameters and the value sent in the corresponding Destination or
        // Source Connection ID fields of Initial packets.
        guard let initialSCID = remoteTransportParameters[.initialSCID],
            initialSCID.connectionID == self.currentPath?.dcid
        else {
            log.error("Missing/invalid initial SCID")
            close(with: .protocolViolation, "missing/invalid initial SCID TP")
            return
        }

        if !isServer {
            guard let originalDCID = remoteTransportParameters[.originalDCID],
                originalDCID.connectionID == self.originalDCID
            else {
                log.error("Missing/invalid original DCID")
                close(with: .protocolViolation, "missing/invalid original DCID TP")
                return
            }

            let retrySCID = remoteTransportParameters[.retrySCID]
            if retryReceived {
                guard let retrySCID, retrySCID.connectionID == self.retrySCID else {
                    log.error("Missing/invalid RETRY SCID TP")
                    close(with: .protocolViolation, "missing/invalid RETRY SCID TP")
                    return
                }
            } else {
                guard retrySCID == nil else {
                    log.error("RETRY SCID TP without receiving a RETRY")
                    close(with: .protocolViolation, "RETRY SCID TP without receiving a RETRY")
                    return
                }
            }
        }

        /*
         * A client MUST NOT include any server-only transport parameter:
         * original_destination_connection_id, preferred_address,
         * retry_source_connection_id, or stateless_reset_token.
         * A server MUST treat receipt of any of these transport
         * parameters as a connection error of type TRANSPORT_PARAMETER_ERROR.
         */
        if self.isServer
            && (remoteTransportParameters[.originalDCID] != nil
                || remoteTransportParameters[.preferredAddress] != nil
                || remoteTransportParameters[.retrySCID] != nil
                || remoteTransportParameters[.statelessResetToken] != nil)
        {
            log.error("Client sent invalid transport parameters")
            close(with: .transportParameterError, "invalid TP: ODCID/ISCID/SRT/PA")
            return
        }

        // The peer's max_ack_delay is stored in the RTT struct where it's most
        // often used.
        if let remoteMaxAckDelay = remoteTransportParameters[.maxAckDelay] {
            currentPath?.rtt.remoteMaxAckDelay = .milliseconds(remoteMaxAckDelay.value)
        } else {
            currentPath?.rtt.remoteMaxAckDelay = .milliseconds(
                TransportParameter.defaultValue(forType: .maxAckDelay)!
            )
        }

        if let ackDelayExponent = remoteTransportParameters[.ackDelayExponent] {
            ack.remoteDelayExponent = ackDelayExponent.value
        } else {
            ack.remoteDelayExponent = TransportParameter.defaultValue(forType: .ackDelayExponent)!
        }

        // The remote transport parameter determines the limit for how many
        // local CIDs we are allowed to send
        if let activeConnectionIDLimit = remoteTransportParameters[.activeConnectionIDLimit] {
            localCIDs.activeConnectionIDLimit = activeConnectionIDLimit.value
            connectionMetadata.activeConnectionIDLimit = activeConnectionIDLimit.value
        } else {
            localCIDs.activeConnectionIDLimit = TransportParameter.defaultValue(
                forType: .activeConnectionIDLimit
            )!
            connectionMetadata.activeConnectionIDLimit = TransportParameter.defaultValue(
                forType: .activeConnectionIDLimit
            )!
        }

        if let maxUDPPayloadSize = remoteTransportParameters[.maxUDPPayloadSize] {
            remoteMaximumUDPPayloadSize = max(
                min(maxUDPPayloadSize.value, TransportParameters.maxUDPPayloadSize),
                TransportParameters.minUDPPayloadSize
            )
        } else {
            remoteMaximumUDPPayloadSize = TransportParameter.defaultValue(
                forType: .maxUDPPayloadSize
            )!
        }

        withCurrentPath { path in
            guard let dcid = path.dcid, dcid.length > 0 else {
                return
            }
            if !isServer,
                let originalStatelessResetToken = remoteTransportParameters[.statelessResetToken]
            {
                // Server sends its stateless reset token in transport parameters.
                // Parse from transport parameters advertised from the remote.
                // Therefore we delay the addition of dcid to the remote array
                // till handshake completion.
                do throws(QUICError) {
                    try remoteCIDs.insert(
                        sequenceNumber: 0,
                        connectionID: dcid,
                        token: originalStatelessResetToken.statelessResetToken,
                        used: true
                    )
                } catch {
                    // Not a fatal error; duplicates are not a problem for the protocol
                    log.error("Error inserting remote CID: \(error)")
                }
            } else {
                // Stateless reset tokens are optional. Add a special managed connection ID without a stateless retry.
                do throws(QUICError) {
                    try remoteCIDs.insertInitialConnectionID(dcid)
                } catch {
                    // Not a fatal error; duplicates are not a problem for the protocol
                    log.error("Error inserting remote CID: \(error)")
                }
            }
        }

        if let preferredAddress = remoteTransportParameters[.preferredAddress] {
            let preferredAddress = preferredAddress.preferredAddress
            if preferredAddress.connectionID.length > 0 {
                do {
                    try remoteCIDs.insert(
                        sequenceNumber: QUICConnectionIDList.preferredAddressSequenceNumber,
                        connectionID: preferredAddress.connectionID,
                        token: preferredAddress.statelessResetToken
                    )
                } catch {
                    // Not a fatal error
                    log.error("Error inserting remote CID for a preferred address: \(error)")
                }
            }
            migrationSupported = true
            migration.addPreferredAddress(preferredAddress)
        }
    }

    func setCIDsOnLocalTransportParameters(path: QUICPath) {
        if let scid = path.scid {
            let initialSCIDParam = TransportParameter.initialSCID(connectionID: scid)
            localTransportParameters.append(initialSCIDParam)
            log.info("Setting initial SCID (length \(scid.length)) on local transport parameters")

            if isServer, let managedCID = localCIDs.find(connectionID: scid) {
                localTransportParameters.append(
                    .statelessResetToken(statelessResetToken: managedCID.token)
                )
                log.info("Setting SCID stateless reset token on local transport parameters")
            }
        }
        if isServer {
            // Use initialDCID on the server if present on the server, otherwise use originalDCID
            if let _initialDCID = initialDCID {
                let originalDCIDParam = TransportParameter.originalDCID(connectionID: _initialDCID)
                localTransportParameters.append(originalDCIDParam)
            } else {
                let originalDCIDParam = TransportParameter.originalDCID(connectionID: originalDCID)
                localTransportParameters.append(originalDCIDParam)
            }
            if let retrySCID = retrySCID {
                let _retrySCID = TransportParameter.retrySCID(connectionID: retrySCID)
                localTransportParameters.append(_retrySCID)
            }

            log.info(
                "Setting original DCID (length \(originalDCID.length)) on local transport parameters"
            )
        }
    }

    func setupLocalTransportParameters(quicOptions: ProtocolOptions<QUICProtocol>) {

        let activeConnectionIDLimit = TransportParameter.activeConnectionIDLimit(
            value: Constants.activeCIDLimit
        )
        localTransportParameters.append(activeConnectionIDLimit)

        // The local transport parameter determines the limit for how many
        // remote CIDs we are willing to track
        remoteCIDs.activeConnectionIDLimit = activeConnectionIDLimit.value

        log.info("Setting up local transport parameters")

        // Initialize the values for the next stream IDs that we expect
        // to see from the peer.  Since we haven't received any stream yet
        // these values represent the first stream IDs that we expect to see.
        // They will be used when we receive streams out of order.
        if isServer {
            bidirectionalStreams.nextInboundStreamID = QUICStreamID(0)
            unidirectionalStreams.nextInboundStreamID = QUICStreamID(2)
        } else {
            bidirectionalStreams.nextInboundStreamID = QUICStreamID(1)
            unidirectionalStreams.nextInboundStreamID = QUICStreamID(3)
        }

        if var maxUDPPayloadSize = quicOptions.perProtocolOptions?.quicConnectionOptions
            .maxUDPPayloadSize
        {
            if maxUDPPayloadSize < TransportParameters.minUDPPayloadSize {
                maxUDPPayloadSize = UInt16(TransportParameters.minUDPPayloadSize)
            } else if maxUDPPayloadSize > TransportParameters.maxUDPPayloadSize {
                maxUDPPayloadSize = UInt16(TransportParameters.maxUDPPayloadSize)
            }
            localTransportParameters.append(.maxUDPPayloadSize(value: UInt64(maxUDPPayloadSize)))
        }

        if var maxDatagramFrameSize = quicOptions.perProtocolOptions?.quicConnectionOptions
            .maxDatagramFrameSize
        {
            if maxDatagramFrameSize > TransportParameters.maxDatagramFrameSize {
                maxDatagramFrameSize = UInt16(TransportParameters.maxDatagramFrameSize)
            }
            localTransportParameters.append(
                .maxDatagramFrameSize(value: UInt64(maxDatagramFrameSize))
            )
        }

        setupInitialMaxDatas(quicOptions: quicOptions)
        setupInitialMaxStreams(quicOptions: quicOptions)

        if let idleTimeout = quicOptions.perProtocolOptions?.quicConnectionOptions.idleTimeout {
            localTransportParameters.append(
                .maxIdleTimeout(value: UInt64(idleTimeout.milliseconds))
            )
        }
        logTransportParameters(owner: .local, transportParameters: localTransportParameters)
    }

    private func logTransportParameters(
        owner: QLogOwner?,
        transportParameters: TransportParameters
    ) {
        #if QlogOutput
        if let qLog {
            qLog.parametersSet(
                owner: owner,
                transportParameters: transportParameters
            )
        }
        #endif
    }

    // Flow control params are special as they decide whether
    // we should do auto-tuning of receive buffer or not. They
    // get all the QUIC option values and if any one them is
    // not set, then fall back to use protocol default values.
    private func setupInitialMaxDatas(quicOptions: ProtocolOptions<QUICProtocol>) {
        // Setup initialMaxData
        var initialMaxData = quicOptions.connectionOptions.initialMaxData
        if initialMaxData == UInt64.max {
            initialMaxData = UInt64(FlowControlGlobals.shared.initialMaxData)
        }
        localTransportParameters.append(TransportParameter.initialMaxData(value: initialMaxData))

        flowControlState.initializeMaxDataValues(
            remoteMaxData: UInt64(FlowControlGlobals.shared.initialMaxData),
            localMaxData: UInt64(initialMaxData)
        )

        // Setup initialMaxStreamDataBidirectionalLocal
        var initialMaxStreamDataBidirectionalLocal = quicOptions.connectionOptions
            .initialMaxStreamDataBidirectionalLocal
        if initialMaxStreamDataBidirectionalLocal == UInt64.max {
            initialMaxStreamDataBidirectionalLocal = UInt64(
                FlowControlGlobals.shared.initialMaxBidirectionalStreamLocalData
            )
        }
        localTransportParameters.append(
            TransportParameter.initialMaxStreamDataBidirectionalLocal(
                value: initialMaxStreamDataBidirectionalLocal
            )
        )

        // Setup initialMaxStreamDataBidirectionalRemote
        var initialMaxStreamDataBidirectionalRemote = quicOptions.connectionOptions
            .initialMaxStreamDataBidirectionalRemote
        if initialMaxStreamDataBidirectionalRemote == UInt64.max {
            initialMaxStreamDataBidirectionalRemote = UInt64(
                FlowControlGlobals.shared.initialMaxBidirectionalStreamRemoteData
            )
        }
        localTransportParameters.append(
            TransportParameter.initialMaxStreamDataBidirectionalRemote(
                value: initialMaxStreamDataBidirectionalRemote
            )
        )

        // Setup initialMaxStreamDataUnidirectional
        var initialMaxStreamDataUnidirectional = quicOptions.connectionOptions
            .initialMaxStreamDataUnidirectional
        if initialMaxStreamDataUnidirectional == UInt64.max {
            initialMaxStreamDataUnidirectional = UInt64(
                FlowControlGlobals.shared.initialMaxUnidirectionalStreamData
            )
        }
        localTransportParameters.append(
            TransportParameter.initialMaxStreamDataUnidirectional(
                value: initialMaxStreamDataUnidirectional
            )
        )

    }

    private func setupInitialMaxStreams(quicOptions: ProtocolOptions<QUICProtocol>) {
        // Setup initialMaxStreamsBidirectional
        var initialMaxStreamsBidirectional = UInt64(FlowControlGlobals.shared.maxConcurrentStreams)
        if quicOptions.connectionOptions.initialMaxStreamsBidirectional != UInt64.max {
            initialMaxStreamsBidirectional =
                quicOptions.connectionOptions.initialMaxStreamsBidirectional
        }
        let initialMaxStreamsBidirectionalParameter =
            TransportParameter.initialMaxStreamsBidirectional(
                value: UInt64(initialMaxStreamsBidirectional)
            )
        localTransportParameters.append(initialMaxStreamsBidirectionalParameter)

        // Setup initialMaxStreamsUnidirectional
        var initialMaxStreamsUnidirectional = UInt64(FlowControlGlobals.shared.maxConcurrentStreams)
        if quicOptions.connectionOptions.initialMaxStreamsUnidirectional != UInt64.max {
            initialMaxStreamsUnidirectional =
                quicOptions.connectionOptions.initialMaxStreamsUnidirectional
        }
        let initialMaxStreamsUnidirectionalParameter =
            TransportParameter.initialMaxStreamsUnidirectional(
                value: initialMaxStreamsUnidirectional
            )
        localTransportParameters.append(initialMaxStreamsUnidirectionalParameter)

        bidirectionalStreams.updateLocalMaxStreams(
            server: isServer,
            newMaxStreams: (Int(initialMaxStreamsBidirectional)),
            logIDString: logPrefixer.logIDString
        )
        unidirectionalStreams.updateLocalMaxStreams(
            server: isServer,
            newMaxStreams: (Int(initialMaxStreamsUnidirectional)),
            logIDString: logPrefixer.logIDString
        )
    }

    public func connect() {
        log.debug(
            "Received connection start (isServer: \(self.isServer))"
        )

        // Defer closing until end of processing connection
        deferClosing = true
        defer {
            deferClosing = false
            if closeError != nil {
                close()
            }
        }

        // Generate a local CID
        let scid: QUICConnectionID
        if let initialSourceConnectionID {
            if initialSourceConnectionID.isUninitialized {
                // CID was all zeros, just use the length
                scid = QUICConnectionID(initialSourceConnectionID.length)
            } else {
                scid = initialSourceConnectionID
            }
            self.initialSourceConnectionID = nil
        } else {
            let scidLength: Int
            if isServer {
                scidLength = QUICConnectionID.defaultServerSCIDLength
            } else {
                scidLength = QUICConnectionID.defaultClientSCIDLength
            }
            scid = QUICConnectionID(scidLength)
        }
        self.localCIDLength = scid.length

        if isServer, localCIDLength == 0 {
            // Cannot perform active migration with zero-length CIDs
            migration.disableActiveMigration()
            localTransportParameters.append(.disableActiveMigration())
        }

        let statelessResetToken: QUICStatelessResetToken
        if let initialStatelessResetToken {
            statelessResetToken = initialStatelessResetToken
            self.initialStatelessResetToken = nil
        } else {
            statelessResetToken = .init()
        }

        // Set up the initial path
        if currentPath == nil, let initialPath = self.somePath {
            initialPath.pacePackets = pacingEnabled
            initialPath.set(interface: self.initialInterface, priority: 0, isInitial: true)
            log.info("Packet Pacing is \(initialPath.pacePackets ? "enabled" : "disabled")")
            do {
                try localCIDs.insertInitialConnectionID(scid, token: statelessResetToken)
            } catch {
                // Not a fatal error; duplicates are not a problem for the protocol
                log.error("Error inserting initial local CID: \(error)")
            }
            initialPath.setSCID(scid)
            if !isServer {
                initialPath.assignDCID(originalDCID)
            }
            setInitialMSS(on: initialPath)
            currentPath = initialPath
        }

        if isServer {
            // Servers go from .idle to .initialReceived (in preDecryption) upon receiving
            // an initial packet
        } else {
            if state == .idle {
                // Record handshake start time start
                handshakeStartTime = .now

                // Start idle timer to terminate unresponded to connection
                guard clientStartIdleTimer() else {
                    log.error("Unable to start idle timer")
                    deliverDisconnectedEvent(flow: .allFlows, error: NetworkError.posix(EINVAL))
                    return
                }

                signpostConnectInterval = QUICSignpost.connectBegin(id: signpostID)

                withCurrentPath { path in
                    setCIDsOnLocalTransportParameters(path: path)
                }
                guard let tlsOptions, crypto.start(with: self, tlsOptions: tlsOptions) else {
                    log.error("Client failed to start TLS")
                    deliverDisconnectedEvent(flow: .allFlows, error: NetworkError.posix(EINVAL))
                    return
                }

                // Clients will go from .idle to .initialSent when the crypto has started and
                // sends the first packet
                state.change(to: .initialSent, logIDString: logPrefixer.logIDString)
            }
        }
        // Note: any sendFrames() is triggered from crypto, if necessary
    }

    func clientStartIdleTimer() -> Bool {
        precondition(
            !isServer,
            "must only be called when acting as a client. Server connections start when clientHello is received."
        )
        return _startIdleTimer()
    }

    func serverStartIdleTimer() -> Bool {
        precondition(isServer, "must only be called when acting as a server.")
        return _startIdleTimer()
    }

    private func _startIdleTimer() -> Bool {
        let value = localTransportParameters.intValue(.maxIdleTimeout)
        if value > 0 {
            idleTimeout = .milliseconds(value)
            log.debug("Parameter configured idle timeout: \(self.idleTimeout)")
        } else {
            idleTimeout = Constants.defaultIdleTimeout
            log.debug("Default idle timeout: \(self.idleTimeout)")
        }

        idleTimerID = timer.insert(
            description: "Idle timeout",
            fromNow: idleTimeout
        ) {
            self.idleTimeoutFired()
        }

        guard let idleTimerID else {
            let reason = "Failed to start idle timer"
            log.fault(reason)
            close(with: .internalError, reason)
            return false
        }

        log.debug(
            "Starting idle timer \(idleTimerID.description) duration \(self.idleTimeout)"
        )
        return true
    }

    func configureTimeoutPostHandshake() {
        // Only attempt to disable idle timeout if the connection is past the handshake stage
        if state == .connected {
            let idleTimeoutLocal = localTransportParameters.intValue(.maxIdleTimeout)
            let idleTimeoutRemote = remoteTransportParameters?.intValue(.maxIdleTimeout) ?? 0
            // An idle timeout value of 0 implies the absence of idle
            // timeout. Therefore when either of the idle timeouts is 0,
            // consider the other one, else take the minimum of the two.
            let minIdleTimeout =
                (idleTimeoutLocal == 0 || idleTimeoutRemote == 0)
                ? (idleTimeoutLocal + idleTimeoutRemote) : min(idleTimeoutLocal, idleTimeoutRemote)
            if minIdleTimeout == 0 {
                log.info("Idle timeout is not configured by any endpoint, disabling timer")
                if let idleTimerID {
                    timer.remove(idleTimerID)
                }
            }
        }
    }

    func idleTimeoutFired() {
        // Assumption: Timer will not be active unless:
        //   - server: initial packet received
        //   - client: initial packet sent

        // Check when the last activity was recorded
        let now = NetworkClock.Instant.now
        guard now >= lastPacketReceivedTimestamp else {
            log.fault("Now should not be less than lastPacketReceivedTimestamp")
            return
        }
        let delta = lastPacketReceivedTimestamp.duration(to: now)
        if delta < idleTimeout {
            // Calculate how much longer until the new idle timeout
            let sleepDuration = idleTimeout - delta

            // Only reset the timer if it is at least the threshold from now (1ms)
            if sleepDuration >= Timer.timerThreshold {
                log.debug("Idle timer rescheduled for \(sleepDuration)")
                if let idleTimerID {
                    timer.reschedule(
                        identifier: idleTimerID,
                        fromNow: sleepDuration,
                        timerNow: self.now
                    )
                }
                return
            }
        }
        errorToReport = NetworkError.posix(ETIMEDOUT)
        log.info(
            "Idle timeout fired, closing connection due to inactivity \(delta) >= \(idleTimeout)"
        )

        // No packets need to be sent when the idle timeout fires.
        close(sendCloseFrame: false)
    }

    public func connect(flow flowID: MultiplexedFlowIdentifier) {
        log.debug(
            "Received connection start on flow \(flowID.debugDescription) (isServer: \(self.isServer))"
        )
        // For streams (not datagram flows), ensure the stream isn't pending
        if secondaryFlow(for: flowID) == nil {
            // If this is a QUICStream then make sure its not in a pending state
            guard let stream = flow(for: flowID), !stream.pendingStart else {
                log.error(
                    "Flow \(flowID.debugDescription) cannot go connected because it is pending (isServer: \(self.isServer))"
                )
                return
            }
        }
        deliverConnectedEvent(flow: flowID)
    }

    public func teardown() {
        close()
    }

    public func disconnect(error: NetworkError?) {
        if let error {
            if closeError == nil, let transportError = error.quicTransportError {
                closeError = QUICTransportError(transportError, error.description)
            } else if applicationCloseError == nil,
                let applicationError = error.quicApplicationError
            {
                self.applicationCloseError = QUICApplicationError(
                    applicationError,
                    error.description
                )
            }
        }
        close()
    }

    public func teardown(flow: MultiplexedFlowIdentifier) {
        disconnect(flow: flow, direction: .both)
    }

    public func disconnect(flow: MultiplexedFlowIdentifier, error: NetworkError?) {
        disconnect(flow: flow, direction: .both, error: error)
    }

    func outboundDataFinished(flow: MultiplexedFlowIdentifier) {
        disconnect(flow: flow, direction: .outbound)
    }

    enum FlowStopDirection {
        case inbound
        case outbound
        case both
    }

    func disconnect(
        flow flowID: MultiplexedFlowIdentifier,
        direction: FlowStopDirection,
        error: NetworkError? = nil
    ) {
        log.debug(
            "Stopping flow \(flowID.debugDescription) (direction: \(direction))"
        )

        if let error, let applicationError = error.quicApplicationError,
            let stream = flow(for: flowID)
        {
            switch direction {
            case .inbound:
                stream.inboundApplicationError = UInt64(applicationError)
            case .outbound:
                stream.outboundApplicationError = UInt64(applicationError)
            case .both:
                stream.inboundApplicationError = UInt64(applicationError)
                stream.outboundApplicationError = UInt64(applicationError)
            }
        }
        if let stream = flow(for: flowID) {
            switch direction {
            case .both:
                handleStopRead(for: stream)
                stream.writeClosed = handleStopWrite(for: stream)
                stream.readClosed = true
            case .inbound:
                handleStopRead(for: stream)
                stream.readClosed = true
            case .outbound:
                stream.writeClosed = handleStopWrite(for: stream)
            }
            if stream.readClosed, stream.writeClosed {
                stream.close(errorCode: nil)
                stream.log.debug("Closed stream")
            } else {
                stream.log.debug(
                    "stream.readClosed \(stream.readClosed), stream.writeClosed \(stream.writeClosed)"
                )

            }
        } else if let _ = secondaryFlow(for: flowID) {
            deliverDisconnectedEvent(flow: flowID, error: nil)
        } else {
            log.error("No stream for \(flowID), cannot close")
        }

        if state == .connected {
            //  Possibly send CONNECTION_CLOSE, STOP_SENDING and/or RESET_STREAM, STREAM FIN
            sendFrames()
        }
    }

    public func serviceReceivedDatagrams(path pathID: MultiplexingPathIdentifier) {
        let inboundInterval = QUICSignpost.inboundStarting(id: signpostID)

        // Save a timestamp to avoid calculating `now` again during processing
        currentInboundReceiveTimestamp = .now

        // Start anew with pendingItems
        // Detect if any received packet contains a QUIC Frame that unblocks
        // all streams, such as a new MAX_DATA. Includes setting
        // triggerAllStreamsUnblocked = false
        initialPendingItems.inboundStarting()
        handshakePendingItems.inboundStarting()
        applicationPendingItems.inboundStarting()

        // Tell recovery that a batch of packets is starting to be processed; suppress timer updates.
        // Ending recovery is deferred until servicing is done.
        recovery.startBatch()
        defer {
            recovery.endBatch(connection: self)
            currentInboundReceiveTimestamp = nil
        }

        if !pendingReassemblyDequeue.isEmpty {
            log.fault("Pending Reassembly Dequeue is not empty")
        }

        accessReceivedDatagrams(path: pathID) { datagrams in
            while let frame = datagrams.popFirst() {
                handleInbound(frame: frame, from: pathID)
            }
        }

        // Note: inboundStopping() triggers any sendFrames*() as necessary due
        // to this external event
        QUICSignpost.inboundStopping(inboundInterval)
        inboundStopping(path: pathID)
        checkConnectionIdle()
    }

    func handleInbound(
        frame: consuming Frame,
        from pathID: MultiplexingPathIdentifier
    ) {
        deferClosing = true
        defer {
            deferClosing = false
            frame.finalize(success: true)
        }

        let dataLength = frame.unclaimedLength
        QUICSignpost.inbound(id: signpostID, length: dataLength)

        if state.isTerminal {
            log.debug(
                "Ignoring incoming packet (length: \(dataLength)) for connection in terminal state"
            )
            return
        }

        stats.increment(.rxBytes, by: dataLength)
        guard dataLength <= UInt16.max else {
            log.info("Refusing to parse packet with size \(dataLength)")
            return
        }

        log.datapath("Handling inbound packet (length: \(dataLength))")

        guard let path = path(for: pathID) else {
            log.error("Dropping packet from unknown path \(pathID.description)")
            return
        }

        var unvalidatedPath = false
        // Attempt path validation if this is the first packet that we have received on this path.
        if isServer, path != currentPath, !path.isValidated {
            unvalidatedPath = true
            path.beginValidation()
        }

        // If we haven't derived the INITIAL keys, try to do that now.
        if isServer, state == .idle || state == .versionSent || state == .retrySent {
            if state == .retrySent {
                // If the retry has been sent, preflight if this is an initial packet with a token.
                // If so, allow it to proceed through the normal handshake / parsing process
                guard packetParser.retryTokenPresent(&frame, token: initialToken) else {
                    log.error("Initial packet received in retrySent state without a valid token")
                    return
                }
            }
            guard let packet = packetParser.parsePrelude(frame: &frame) else {
                log.datapath("Unable to parse a packet from the frame")
                return
            }

            if !preDecryption(frame: &frame, path: path, packet: packet) {
                return
            }

            // Change state from idle to initial received with key state = handshake
            state.change(to: .initialReceived, logIDString: logPrefixer.logIDString)
            keyState = .handshake
            handshakeStartTime = self.now
            signpostConnectInterval = QUICSignpost.connectBegin(id: signpostID)

            guard serverStartIdleTimer() else {
                let error = "Unable to start server idle timer"
                log.error(error)
                close(with: .internalError, error)
                return
            }

            guard frame.unclaim(fromStart: Int(packet.headerLength), fromEnd: 0) else {
                return
            }
        }

        var coalesced = false
        while frame.unclaimedLength > 0 {
            let continueProcessing = handleInboundPacket(
                frame: &frame,
                path: path,
                ecnFlags: frame.ecnFlag,
                unvalidatedPath: unvalidatedPath,
                coalesced: coalesced
            )
            if !continueProcessing {
                frame.finalize(success: true)
                break
            }

            if closeError != nil {
                frame.finalize(success: false)
                close()
                return
            }

            // Update the receive timestamp used later in keep-alive timer
            // expiry and idle time. Do it only for valid packets
            lastPacketReceivedTimestamp = self.now
            // If we parsed at least one packet and there are still
            // more, consider all packets of this batch coalesced.
            if frame.unclaimedLength > 0 && !coalesced {
                coalesced = true
            }
        }
        frame.finalize(success: true)
    }

    private func handleInboundPacket(
        frame: inout Frame,
        path: QUICPath,
        ecnFlags: IPProtocol.ECN,
        unvalidatedPath: Bool,
        coalesced: Bool
    ) -> Bool {
        let packet = packetParser.parse(frame: &frame, connection: self, path: path, ecn: ecnFlags)
        guard var packet else {
            if state == .connected {
                log.error("Unable to parse packet")
            } else {
                log.info("Unable to parse packet (decryption keys may not be ready)")
            }
            if self.closeError != nil {
                close()
                return false
            }
            return false
        }

        defer {
            // Make sure to always clean up any unprocessed frames when exiting
            packet.cleanupReceivedFrames()
        }

        log(packet: &packet, coalesced: coalesced, outbound: false)
        path.updateBDP(length: packet.totalLength, now: self.now)

        /*
         * Both VN and Retry packets are special.
         * While processing these packets themselves, we should discard
         * these when they are not valid. We MUST not close the
         * connection while processing these packets as their fields are
         * not protected. We may do so when validating version
         * negotiation or retry later while parsing through transport
         * parameters.
         */
        if packet.versionNegotiation {
            handleInboundVersionNegotiation(packet)
            return true
        } else if packet.retry {
            handleInboundRetry(packet)
            return true
        } else if packet.failedDecryption {
            failedDecryption(packet)
            return false
        }

        // Process ECN for all packets, this should be done
        // before packet is appended for ACK below.
        let ceMarked = ECN.processIPCodpoint(
            ecn: self.ecn,
            path: currentPath,
            stats: &stats,
            packetNumberSpace: packet.numberSpace,
            flag: ecnFlags
        )
        let continueProcessing: Bool
        if packet.longHeader {
            continueProcessing = handleInboundLongHeader(packet)
        } else {
            continueProcessing = handleInboundShortHeader(packet, path: path)
        }
        if !continueProcessing {
            return true
        }

        var isAckEliciting = false
        var isNonProbing = false

        while let quicFrame = packet.framesReceived.popFirst() {
            if state == .initialReceived {
                if !QUICFrame.isValidInInitial(frame: quicFrame) {
                    close(
                        with:
                            .protocolViolation,
                        "Client sent initial packet with invalid QUIC frames"
                    )
                    return false
                }
            }
            if QUICFrame.isAckEliciting(frame: quicFrame) {
                isAckEliciting = true
                /*
                 * Mark it as transmittable here so we have a chance
                 * to bundle it with any outgoing frame that might
                 * be generated during processFrame().
                 */
                ack.shouldTransmit(packetNumberSpace: packet.numberSpace)
            }
            if !QUICFrame.isProbing(frame: quicFrame) {
                isNonProbing = true
            }
            if let packetKeystate = packet.keyState,
                packetKeystate == .initial || packetKeystate == .handshake,
                !QUICFrame.isAllowedDuringHandshake(frame: quicFrame)
            {
                log.error("Invalid frame type during the handshake: \(quicFrame.frameType)")
                closeFrameType = quicFrame.frameType
                close(with: .protocolViolation, "invalid frame type during the handshake")
            }
            if !processFrame(quicFrame, packetNumberSpace: packet.numberSpace, path: path) {
                break
            }
        }

        if unvalidatedPath {
            sendFrames(on: path)
        }

        if isServer, isNonProbing, path != currentPath {
            migration.migrate(to: path, connection: self)
        }
        if isAckEliciting {
            ack.unackedPacketCount += 1
            let reordering = processReordering(packet: packet)
            let ackAggressively = ceMarked || reordering
            if ackAggressively {
                // Force ACKs for the next several packets.
                ack.ackAgressively()
            } else if packet.numberSpace == .initial || packet.numberSpace == .handshake {
                // Force an ACK for this packet.
                ack.ackImmediately()
            }
        }

        // Update largest Packet Number
        ack
            .updateLargestPacketNumber(
                packetNumber: packet.number,
                packetNumberSpace: packet.numberSpace
            )
        if isAckEliciting {
            ack
                .updateLargestAckElicitingPacketNumber(
                    packetNumber: packet.number,
                    packetNumberSpace: packet.numberSpace
                )
        }

        return true
    }

    private func handleInboundVersionNegotiation(_ packet: borrowing Packet) {
        if isServer {
            // Version negotiation packets can only be sent by the server.
            log.error("Received a VN packet from a client")
            return
        }
        // A client MUST ignore a Version Negotiation packet if it has already
        // received and acted on a Version Negotiation packet.
        if versionReceived {
            log.error("Received a second VN")
            return
        }

        guard let packetDCID = packet.destinationConnectionID,
            let packetSCID = packet.sourceConnectionID,
            let currentPath = self.currentPath,
            let currentSCID = currentPath.scid,
            let currentDCID = currentPath.dcid
        else {
            log.error("Could not process VN packet, CIDs not available")
            return
        }
        if packetDCID != currentSCID {
            log.error("VN with invalid DCID: \(packetDCID) != \(currentSCID)")
            return
        }
        if packetSCID != currentDCID {
            log.error("VN with invalid SCID: \(packetSCID) != \(currentDCID)")
            return
        }
        guard let packetVersions = packet.versions else {
            log.error("No versions available from inbound packet")
            return
        }
        var matchedVersion: QUICVersion?
        for packetVersion in packetVersions {
            // A client MUST ignore a Version Negotiation packet
            // that lists the client’s chosen version
            if packetVersion == Constants.defaultVersion {
                matchedVersion = packetVersion
                break
            }
        }

        // At this point, it is safe to say that client has received
        // a valid VN and will act on it
        state.change(to: .versionReceived, logIDString: logPrefixer.logIDString)
        versionReceived = true
        guard let version = matchedVersion else {
            close(with: .internalError, "unsupported version")
            return
        }
        negotiatedVersion = version
        recovery.resetPNSpace(packetNumberSpace: .initial, connection: self)
        recovery.resetPNSpace(packetNumberSpace: .handshake, connection: self)
        // Resetting congestion control will reset the pacer too
        currentPath.resetCongestionControl()
        log.info("Retransmitting INITIAL with version \(version.rawValue)")
        // Resetting crypto here will guarantee the initial is sent again
        crypto.stop()
        crypto = QUICCrypto(context: context)
        guard let tlsOptions, crypto.start(with: self, tlsOptions: tlsOptions) else {
            log.error("Failed to start TLS")
            return
        }
        state.change(to: .initialSent, logIDString: logPrefixer.logIDString)
    }

    private func handleInboundRetry(_ packet: borrowing Packet) {
        guard !isServer else {
            // Retry packets can only be sent by the server.
            log.error("Received a RETRY packet from a client")
            return
        }
        guard packet.tokenLength > 0,
            packet.tokenLength <= Constants.retryTokenMaxLength
        else {
            log.error("Discarding RETRY with a bad length token")
            return
        }
        guard let token = packet.token,
            let tag = packet.tag
        else {
            log.error("Discarding RETRY could not parse token or tag")
            return
        }
        guard state == .initialSent else {
            log.error("Received RETRY in state \(state)")
            return
        }
        // After the client has received and processed an
        // Initial or Retry packet from the server, it MUST discard any
        // subsequent Retry packets that it receives.
        guard !retryReceived else {
            log.error("Received second RETRY")
            return
        }

        guard let path = currentPath,
            let pathDCID = path.dcid,
            let pathSCID = path.scid,
            let firstOctet = packet.retryFirstOctet
        else {
            log.error("Received RETRY with path in a bad state")
            return
        }
        guard let version = packet.version else {
            log.error("Received RETRY without a version")
            return
        }
        guard let dcid = packet.destinationConnectionID,
            let scid = packet.sourceConnectionID
        else {
            log.error("Received RETRY with bad CIDs")
            return
        }
        // From a clients perspective:
        // The value in the Unused field is set to an arbitrary value by the server;
        // So the packet's first octet here needs to be captured from the server
        let pseudoRetry = QUICPseudoRetry.assemble(
            firstByte: firstOctet,
            version: version,
            destinationCID: dcid,
            sourceCID: scid,
            originalDCID: pathDCID,
            token: token
        )
        do throws(QUICError) {
            try Protector.openRetry(retryPseudo: pseudoRetry.span.bytes, retryTag: tag.span.bytes)
        } catch {
            log.error("Unable to authenticate retry with error: \(error)")
            return
        }
        guard dcid == pathSCID else {
            log.error("RETRY with invalid DCID: \(dcid) != \(pathSCID)")
            return
        }
        state.change(to: .retryReceived, logIDString: logIDString)
        retryReceived = true
        retrySCID = scid
        path.assignDCID(scid)
        // NOTE: similar to packet builder setting the token to be used with initial / LH packets
        initialToken = token
        recovery.resetPNSpace(packetNumberSpace: .initial, connection: self)
        recovery.resetPNSpace(packetNumberSpace: .handshake, connection: self)
        // Resetting congestion control will reset the pacer too
        path.resetCongestionControl()

        // The protector needs to derive new initial keys using the RETRY's SCID as the new DCID
        protector.deriveInitialSecrets(destinationCID: scid)

        log.info("Retransmitting INITIAL with token len: \(packet.tokenLength)")
        // Resetting crypto here will guarantee the initial is sent again
        crypto.stop()
        crypto = QUICCrypto(context: context)
        guard let tlsOptions, crypto.start(with: self, tlsOptions: tlsOptions) else {
            log.error("Failed to start TLS")
            return
        }
        state.change(to: .initialSent, logIDString: logPrefixer.logIDString)
    }

    private func handleInboundLongHeader(_ packet: borrowing Packet) -> Bool {
        switch state {
        case .idle:
            if !isServer {
                let error = "invalid state for client: idle"
                log.fault(error)
                close(with: .internalError, error)
                return false
            }
            if packet.keyState != .initial {
                let error = "first packet received from the client was not INITIAL"
                log.error(error)
                close(with: .protocolViolation, error)
                return false
            }
            // NOTE: A server MAY send a CONNECTION_CLOSE frame with error
            // code PROTOCOL_VIOLATION in response to the first Initial
            // packet it receives from a client if the UDP datagram is
            // smaller than 1200 octets.
            if isServer && packet.keyState == .initial && packet.totalLength < 1200 {
                let error = "first packet received from the client was smaller than 1200 octets"
                log.error(error)
                close(with: .protocolViolation, error)
                return false
            }
            // Server must set the negotiated version to the version that
            // it accepts on INITIAL packet
            negotiatedVersion = packet.version
            state.change(to: .initialReceived, logIDString: logPrefixer.logIDString)
            keyState = .handshake
            break

        case .initialReceived:
            if !isServer {
                let error = "invalid state for client: initialReceived"
                log.fault(error)
                close(with: .internalError, error)
                return false
            }

            // initial packet MUST contain both a source and destination connection id
            guard let peerSourceConnectionID = packet.sourceConnectionID,
                let peerDestinationConnectionID = packet.destinationConnectionID
            else {
                log.error("State: \(state), initial received packet does not have both CIDs set")
                return false
            }

            // When receiving multiple Initial packets, the initial SCID is known after the first one.
            if self.initialSourceConnectionID != nil {
                // When the INITIAL crypto payload exceeds the size available in a single QUIC packet,
                // more than one INITIAL packet may be received. Check that the connection IDs match
                // and pass the packet on for further processing, but do not repeat the connection setup.
                guard
                    self.originalDCID == peerDestinationConnectionID
                        && self.initialSourceConnectionID == peerSourceConnectionID
                else {
                    log.error("Received multiple Initials with different DCIDs")
                    return false
                }
            } else {
                // Save the client's original DCID.
                originalDCID = peerDestinationConnectionID

                // Don't overwrite the initial set during RETRY.
                if initialDCID == nil {
                    initialDCID = peerDestinationConnectionID
                }

                withCurrentPath { path in
                    // Use the client's SCID as our DCID.
                    path.assignDCID(peerSourceConnectionID)

                    // The server SCID should already be set
                    setCIDsOnLocalTransportParameters(path: path)
                    return
                }

                guard let tlsOptions, crypto.start(with: self, tlsOptions: tlsOptions)
                else {
                    log.error("Server failed to start TLS")
                    return false
                }
            }

            state.change(to: .initialProcessed, logIDString: logPrefixer.logIDString)
            break

        case .versionSent:
            if packet.keyState != .initial {
                close(with: .protocolViolation, "non-initial packet during VN")
                log.error(
                    "Bogus server first packet \(packet.keyState?.description ?? "nil"), expecting version negotiation"
                )
                return false
            }
            // Server only supports the initial version. The client cannot be in this state.
            if let initialVersion = self.initialVersion,
                initialVersion == packet.version
            {
                // Perform the scid / dcid checks separately
                guard let scid = packet.sourceConnectionID,
                    let dcid = packet.destinationConnectionID
                else {
                    log.error("Could not extract scid and dcid from long header")
                    return false
                }
                negotiatedVersion = packet.version
                state.change(to: .initialReceived, logIDString: logPrefixer.logIDString)
                keyState = .handshake

                log.info("New SCID: \(scid)")
                currentPath?.setSCID(scid)
                log.info("New DCID: \(dcid)")
                currentPath?.assignDCID(dcid)
                protector.deriveInitialSecrets(destinationCID: dcid)
            } else {
                close(with: .internalError, "version negotiation failed")
                log.error("Version negotiation failed")
                return false
            }
            break

        case .initialSent:
            guard packet.keyState == .initial else {
                close(with: .protocolViolation, "bogus server first packet")
                log.error(
                    "Bogus server first packet \(packet.keyState?.description ?? "nil")"
                )
                return false
            }
            self.state.change(to: .handshake, logIDString: logPrefixer.logIDString)
            self.keyState = .handshake

            // Peer's DCID will be saved to the array once we are
            // connected.
            if let peerSourceConnectionID = packet.sourceConnectionID {
                withCurrentPath { $0.assignDCID(peerSourceConnectionID) }
            }
        // NOTE: clients that receive an Initial packet
        // with a non-zero Token Length field MUST
        // either discard the packet or generate a
        // connection error of type PROTOCOL_VIOLATION.

        // Note: sendFrames() are still driven from crypto, as needed

        case .initialProcessed, .handshake, .connected, .retryReceived, .versionReceived,
            .retrySent:
            // NOTE: compare token
            log.info("State \(state)")
            break

        case .closing, .draining:
            break

        case .invalid:
            let error = "invalid state: \(state)"
            log.fault(error)
            close(with: .internalError, error)
            return false
        }

        if !receivedHandshakePacket && packet.keyState == .handshake {
            receivedHandshakePacket = true
            if isServer && !initialKeysDiscarded {
                // A server MUST discard Initial keys when it
                // first successfully processes a Handshake
                // packet.
                // Endpoints MUST NOT send Initial packets after
                // this point.
                discardKeys(keyState: .initial)
                initialKeysDiscarded = true
            }
        }

        // Note: the sending of this ACK is still driven by crypto doing
        // sendFrames*() and sent together with any CRYPTO frames
        self.ack.append(
            packetNumberSpace: packet.numberSpace,
            packetNumber: packet.identifier.number,
            now: self.now
        )
        let packetLength = packet.totalLength
        stats.increment(.rxPackets)
        stats.increment(.rxBytes, by: packetLength)
        withCurrentPath { (path: borrowing QUICPath) -> Void in
            path.pathStatistics[.rxPackets] += 1
            path.pathStatistics[.rxBytes] += Int(packetLength)
        }
        return true
    }

    private func validateDCIDFromInboundPacket(
        _ packet: borrowing Packet,
        on path: QUICPath
    ) -> Bool {
        let packetDCID = packet.destinationConnectionID
        guard let packetDCID, let localCIDEntry = localCIDs.find(connectionID: packetDCID) else {
            log.error(
                "DCID mismatch: \(packetDCID?.description ?? "<nil>") != \(currentPath?.scid?.description ?? "<nil>")"
            )
            return false
        }

        // An endpoint SHOULD ensure that its peer has a sufficient number of
        // available and unused connection IDs. The endpoint SHOULD do this by
        // supplying a new connection ID when a connection ID is retired by its
        // peer or when the endpoint receives a packet with a previously unused
        // connection ID.
        guard !localCIDEntry.used else {
            log.datapath("Not changing CIDs because CID \(packetDCID) has been used before")
            return true
        }
        let activeCount = localCIDs.count
        let cidLimit = localCIDs.activeConnectionIDLimit
        log.debug(
            "CID seq=\(localCIDEntry.sequenceNumber) newly used (\(activeCount) active, limit \(cidLimit))"
        )
        if activeCount < cidLimit {
            announceNewConnectionIDs(count: 1)
        } else {
            log.info("Not issuing new CID because peer is already at limit")
        }
        localCIDs.markUsed(localCIDEntry)

        // The DCID matches our issued CID.
        // We therefore need to update SCID to the DCID and, if
        // there was a previous association to a different SCID,
        // we also need to pick a new CID from the peer's list
        // of issued CIDs.
        log.notice("Using new SCID: \(packetDCID)")
        let hadPreviousSCID = path.scid != nil
        path.setSCID(packetDCID)
        guard hadPreviousSCID else {
            return true
        }

        if assignNewDCID(to: path), let pathDCID = path.dcid {
            log.notice("Using new DCID: \(pathDCID)")
        }

        announceNewConnectionIDs(count: 1)

        return true
    }

    func assignNewDCID(to path: QUICPath) -> Bool {
        var eligibleCID: ManagedConnectionID?

        // Look for the preferred address CID if applicable
        if path.isPreferredAddress {
            for remoteCID in self.remoteCIDs {
                guard !remoteCID.used, remoteCID.preferredAddress else {
                    continue
                }
                eligibleCID = remoteCID
                break
            }
        }

        // Otherwise, look for a normal CID
        if eligibleCID == nil {
            for remoteCID in self.remoteCIDs {
                guard !remoteCID.used, !remoteCID.preferredAddress else {
                    continue
                }
                eligibleCID = remoteCID
                break
            }
        }

        guard let eligibleCID else {
            log.error("No available DCIDs to assign")
            return false
        }
        remoteCIDs.markUsed(eligibleCID)
        path.assignDCID(eligibleCID.connectionID)
        return true
    }

    private func handleInboundShortHeader(_ packet: borrowing Packet, path: QUICPath) -> Bool {
        guard let packetKeyState = packet.keyState else {
            log.error("Received short header without keystate set")
            return false
        }
        if packetKeyState != keyState {
            log.notice("Switching to keystate \(packetKeyState)")
            keyState = packetKeyState
        }

        let packetLength = packet.totalLength
        stats.increment(.rxPackets)
        stats.increment(.rxBytes, by: packetLength)
        withCurrentPath { (path: borrowing QUICPath) -> Void in
            path.pathStatistics[.rxPackets] += 1
            path.pathStatistics[.rxBytes] += Int(packetLength)
        }
        self.ack.append(
            packetNumberSpace: packet.numberSpace,
            packetNumber: packet.number,
            now: self.now
        )

        guard
            packet.destinationConnectionID == path.dcid
                || validateDCIDFromInboundPacket(packet, on: path)
        else {
            return false
        }

        if let largestReceivePacketNumber = ack.getLargestReceivedPacketNumber(
            packetNumberSpace: .applicationData
        ) {
            if spinBitEnabled && packet.number > largestReceivePacketNumber {
                // The server reflects the spin value received, while the client "spins" it after one RTT.
                if isServer {
                    // Reflect the spin bit.
                    let spinValue = packet.spinValue
                    path.spinValue = spinValue
                } else {
                    // Spin it!
                    let spinValue = packet.spinValue
                    path.spinValue = !spinValue
                }
            }
        }
        return true
    }

    // All the handleInbound() has been done for now, we can deliver any input
    // data to application in bulk
    func inboundStopping(path: MultiplexingPathIdentifier) {

        // Send pending acks
        if !state.isTerminal {
            _ = ack.processPending(
                connectionWindow: Int(availableRemoteReceiveWindow),
                isAckSet: isAckSet,
                setAckFrame: scheduleAckFrame,
                ecn: ecn
            )
        }

        // Try to send more data on all streams due to a received MAX_DATA or ACK
        if applicationPendingItems.triggerAllStreamsUnblocked {
            applyToAllFlows { stream in
                applicationPendingItems.prependStreamToService(stream)
            }
            sendFrames()
            // We've already processed all the unblocked streams
            applicationPendingItems.unblockedSendStreams.removeAll(connection: self)
        } else {
            while let stream = applicationPendingItems.unblockedSendStreams.removeFirst(
                connection: self
            ) {
                // Try to send data on just a single stream due
                // to a new MAX_STREAM_DATA frame.
                applicationPendingItems.prependStreamToService(stream)
                sendFrames()

                stream.updateOutboundFlowControlCredit(connection: self)
            }
        }

        // Service streams that are pending application reads
        while let stream = pendingReassemblyDequeue.removeFirst(connection: self) {
            let flowID = stream.identifier
            guard let frameArray = stream.dequeueReassembledData(connection: self) else {
                continue
            }

            try? enqueueInboundStreamData(flow: flowID, streamData: frameArray)
            try? deliverEnqueuedInboundStreamData(flow: flowID)

            // When the stream is already in `resetReceived` state,
            // it should be closed when we receive STOP_SENDING, so we
            // only need to handle the `dataRead` state here.
            if stream.receiveState == .dataRead, stream.receivedStopSending {
                stream.close(errorCode: nil)
            } else if !stream.closed, stream.sendState == .dataReceived, stream.receiveState == .dataRead {
                // If both directions are closed, and all data is read, close the stream
                stream.close(errorCode: nil)
            }
        }

        sendFrames()

        initialPendingItems.inboundStopped()
        handshakePendingItems.inboundStopped()
        applicationPendingItems.inboundStopped()
    }

    // Handle an outbound write to stream, queue the data for sending in the
    // send buffer and kick off sending from it. There is just one call with all
    // the written data.
    public func serviceStreamDataToSend(flow flowID: MultiplexedFlowIdentifier) {
        guard let stream = flow(for: flowID) else {
            log.error("Unable to access state for flow \(flowID)")
            return
        }

        guard let streamID = stream.streamID else {
            log.debug("Outbound packet is for an unknown stream ID")
            return
        }

        let outboundInterval = QUICSignpost.outboundStarting(id: signpostID)

        // Save a timestamp to avoid calculating `now` again during processing
        currentSendTimestamp = .now
        defer {
            // Always reset
            QUICSignpost.outboundStopping(outboundInterval)
            currentSendTimestamp = nil
        }

        accessStreamDataToSend(flow: flowID) { streamData in
            while var frame = streamData.popFirst() {

                // If the connection is complete, it is always a FIN
                let dataLength = frame.unclaimedLength
                let connectionComplete = frame.connectionComplete
                let metadataComplete = frame.metadataComplete
                var isFinal = connectionComplete

                // If the metadata is connection mode (so each metadata is a new stream)
                // and the metadata is complete, this is also a FIN

                if frame.protocolMetadatas.count > 0 {
                    if frame.protocolMetadatas[0].metadata.matches(
                        protocolIdentifier: QUICConnectionProtocol.identifier
                    ) {
                        isFinal = isFinal || metadataComplete
                    }
                }
                log.datapath(
                    "Handle outbound stream data for [\(streamID)] (size \(dataLength) metadataComplete: \(metadataComplete), connectionComplete: \(connectionComplete), isFinal: \(isFinal))"
                )

                if dataLength > 0 {
                    processOutbound(frame: frame, flowID: flowID, stream: stream, isLast: isFinal)
                    continue
                } else if isFinal, let _ = knownFlows[streamID] {
                    log.datapath("Treating zero length fin as a stop message")
                    disconnect(flow: flowID, direction: .outbound)
                } else {
                    // For QUIC, empty frames with just metadata are not meaningful if they are not complete
                    log.notice("Not processing outbound data of length 0")
                }
                frame.finalize(success: false)
            }
        }

        if !stream.sendState.dataHasAlreadyBeenSent {
            applicationPendingItems.appendStreamToService(stream)
        }
        // Note: trigger sending of any frames based on this external event
        checkConnectionIdle()
        sendFrames()
    }

    #if !NETWORK_EMBEDDED
    public func getMetadata<P: NetworkProtocol>(
        flow flowID: MultiplexedFlowIdentifier
    ) -> ProtocolMetadata<P>? {
        guard P.self == QUICProtocol.self else {
            return nil
        }

        if case .allFlows = flowID {
            let metadata = QUICProtocol.metadata()
            metadata.perProtocolMetadata?.quicConnectionMetadata = self.connectionMetadata
            return metadata as? ProtocolMetadata<P>
        }

        if let datagramFlow = secondaryFlow(for: flowID) {
            let metadata = QUICProtocol.metadata()
            metadata.perProtocolMetadata?.datagramFlowID = datagramFlow.flowID
            metadata.perProtocolMetadata?.usableDatagramFrameSize = UInt16(
                datagramFlow.usableDatagramSize
            )
            metadata.perProtocolMetadata?.isDatagramFlow = true
            metadata.perProtocolMetadata?.quicConnectionMetadata = self.connectionMetadata
            return metadata as? ProtocolMetadata<P>
        }

        guard let stream = flow(for: flowID),
            let streamID = stream.streamID
        else {
            return nil
        }

        let metadata = QUICProtocol.metadata()
        metadata.perProtocolMetadata = stream.streamMetadata
        metadata.perProtocolMetadata?.quicConnectionMetadata = self.connectionMetadata
        metadata.perProtocolMetadata?.streamID = streamID.value
        if let streamType = stream.streamType {
            metadata.perProtocolMetadata?.streamType = streamType
        }
        return metadata as? ProtocolMetadata<P>
    }
    #endif

    public func updateDataTransferSnapshot(flow: MultiplexedFlowIdentifier, _ snapshot: inout DataTransferSnapshot) {
        snapshot.receivedTransportOutOfOrderByteCount = UInt64(clamping: self.stats[.rxOutOfOrderBytes])
        snapshot.sentTransportRetransmittedByteCount = UInt64(clamping: self.stats[.txRetransmittedBytes])
        snapshot.sentTransportECNCapablePacketCount = UInt64(clamping: self.stats[.ecnCapablePacketsSent])
        snapshot.sentTransportECNCapableAckedPacketCount = UInt64(clamping: self.stats[.ecnCapablePacketsAcknowledged])
        snapshot.sentTransportECNCapableMarkedPacketCount = UInt64(clamping: self.stats[.ecnCapablePacketsMarked])
        snapshot.sentTransportECNCapableLostPacketCount = UInt64(clamping: self.stats[.ecnCapablePacketsLost])
        if let path = currentPath {
            snapshot.transportMinimumRTT = path.rtt.minRTT
            snapshot.transportSmoothedRTT = path.rtt.smoothedRTT
            snapshot.transportCurrentRTT = path.rtt.adjustedRTT
            snapshot.transportRTTVariance = path.rtt.RTTVariance
            path.congestionControlFilloutDataTransferSnapshot(snapshot: &snapshot)
        }
    }

    public var protocolEstablishmentReport: ProtocolEstablishmentReport? {
        var clientAccurateECNState: ClientAccurateECNState = .ecnFeatureDisabled
        var l4sEnabled = false
        if let path = currentPath {
            l4sEnabled = path.l4sEnabled
            if let ecnState = path.ecnState?.state {
                switch ecnState {
                case .probing, .validate:
                    clientAccurateECNState = .ecnFeatureEnabled
                case .manglingDetected:
                    clientAccurateECNState = .ecnNegotiationSuccessECTManglingDetected
                case .handshakeValidationSuccess, .capable:
                    clientAccurateECNState = .ecnNegotiationSuccess
                case .blackholed:
                    clientAccurateECNState = .ecnNegotiationBlackholed
                case .unsupported:
                    clientAccurateECNState = .ecnNotAvailable
                default:
                    break
                }
            }
        }
        var protocolEstablishmentReport = ProtocolEstablishmentReport(
            handshakeMilliseconds: handshakeDuration,
            handshakeRTTMilliseconds: handshakeRTT,
            protocolIdentifier: QUICConnectionProtocol.identifier,
            clientAccurateECNState: clientAccurateECNState
        )
        protocolEstablishmentReport.l4sEnabled = l4sEnabled
        protocolEstablishmentReport.quicMigrationSupported = migrationSupported
        protocolEstablishmentReport.quicStatelessResetReceived = (self.stats[.statelessResetReceived] > 0)
        protocolEstablishmentReport.quicStatelessResetDuringPathProbe = (self.stats[.statelessResetDuringPathProbe] > 0)

        return protocolEstablishmentReport
    }

    func setupNewOutboundStream(
        _ stream: QUICStreamInstance,
        with protocolOptions: QUICStreamProtocol.Options
    ) {
        let isUnidirectional = protocolOptions.isUnidirectional

        let flowID = stream.identifier
        log.debug(
            "Setting up stream for flow ID \(flowID.debugDescription)"
        )

        // When connected, this new stream can become ready right away and
        // StreamID allocation is based on transport parameters.
        // If 0-RTT data is being used (earlyDataSignalled), we need the stream
        // to become ready as well. In that case the streamID will be allocated
        // based on assumed (very high) limits.
        // If not connected, we keep the stream as pending until connection
        // becomes ready, cf. reportReady().
        var streamID: QUICStreamID?
        var streamBlocked: Bool = false
        if state == .connected || earlyDataSignalled {
            streamID = setupStreamID(
                isUnidirectional: isUnidirectional,
                isServer: isServer
            )
            if streamID == nil {
                streamBlocked = true
                log.notice(
                    "Failed to allocate stream ID for flow \(flowID.debugDescription), will be created as pending"
                )
            }
        } else {
            streamID = nil
        }

        stream.streamMetadata.quicConnectionMetadata = self.connectionMetadata
        stream.setup(streamID: streamID, logPrefixer: logPrefixer)

        if let remoteTransportParameters {
            if isUnidirectional {
                let remoteMaxData =
                    remoteTransportParameters.intValue(.initialMaxStreamDataUnidirectional)
                let localMaxData =
                    localTransportParameters.intValue(.initialMaxStreamDataUnidirectional)
                stream.flowControlState.initializeMaxDataValues(
                    remoteMaxData: UInt64(remoteMaxData),
                    localMaxData: UInt64(localMaxData)
                )
            } else {
                let remoteMaxData =
                    remoteTransportParameters.intValue(.initialMaxStreamDataBidirectionalRemote)
                let localMaxData =
                    localTransportParameters.intValue(.initialMaxStreamDataBidirectionalLocal)
                stream.flowControlState.initializeMaxDataValues(
                    remoteMaxData: UInt64(remoteMaxData),
                    localMaxData: UInt64(localMaxData)
                )
            }
        }

        stream.unidirectional = isUnidirectional
        log.debug(
            "Set stream \(stream.streamID?.description ?? "nil") for flow \(flowID.debugDescription)"
        )

        if let streamID {
            log.debug("Set known flow \(flowID.debugDescription) for key \(streamID)")
            knownFlows[streamID] = flowID
            if isUnidirectional {
                self.unidirectionalStreams.incrementActiveStreams()
            } else {
                self.bidirectionalStreams.incrementActiveStreams()
            }
            stream.outboundStreamReady()
        } else {
            log.debug("Add pending stream for flow \(flowID.debugDescription)")
            withMutableQUICStreams(unidirectional: stream.unidirectional) { mutableStreamsState in
                mutableStreamsState.addPending(stream)
            }
            if self.state == .connected && streamBlocked {
                // Send the STREAMS_*_BLOCKED frame if we are connected.
                log.debug("Marked stream (flow \(flowID.debugDescription)) as pending")
                stream.outboundStreamPending(
                    connected: (self.state == .connected),
                    connection: self
                )
            }
        }

        if isUnidirectional {
            stats.increment(.outboundUnidirectionalStreams)
        } else {
            stats.increment(.outboundBidirectionalStreams)
        }

        // Check if there is already data to send
        serviceStreamDataToSend(flow: flowID)
    }

    var deferClosing = false  // Set to defer closing until processing finishes
    public func close(withCryptoError error: Int64, _ reason: String? = nil) {
        closeError = QUICTransportError(cryptoError: error, reason)
        if !deferClosing {
            close(sendCloseFrame: true)
        }
    }

    public func close(
        with error: QUICTransportError.QUICTransportErrorCode,
        _ reason: String? = nil,
        sendCloseFrame: Bool = true
    ) {
        closeError = QUICTransportError(error, reason)
        if !deferClosing {
            close(sendCloseFrame: sendCloseFrame)
        }
    }

    var hasApplicationCloseError: Bool {
        applicationCloseError != nil
    }

    public func close() {
        close(sendCloseFrame: true)
    }

    // Closing all flows, i.e. streams, and the connection itself
    private func close(sendCloseFrame: Bool = true) {
        if state.isTerminal || drainingScheduled {
            log.debug("Already in closing or draining state")
            return
        }
        isPacing = false

        QUICSignpost.disconnect(id: signpostID)

        flushPendingItems()

        var space: PacketNumberSpace = .fromKeyState(keyState: keyState)
        if isServer {
            if !isHandshakeConfirmed, keyState.isHandshakeConfirmed {
                space = .handshake
            } else if keyState == .initial || keyState == .handshake {
                sendConnectionClose(packetNumberSpace: .initial)
            }
        } else if state == .handshake {
            space = .handshake
        }
        log.debug(
            "Closing connection in state \(self.state) (PN space \(space))"
        )

        if sendCloseFrame {
            if hasApplicationCloseError {
                sendApplicationClose()
            } else {
                // Note: this may add a second CONNECTION_CLOSE, in a PN space other than .initial
                sendConnectionClose(packetNumberSpace: space)
            }
        }
        // Send errorToReport here if received either APPLICATION_CLOSE or CONNECTION_CLOSE or
        // if there was a local error that took place before the handshake completed.
        if errorToReport == nil && state != .connected
            || errorToReport == nil && state == .connected
                && (receivedConnectionClose || receivedApplicationClose)
        {
            if let applicationCloseError {
                errorToReport = NetworkError(quicApplicationError: applicationCloseError)
            } else if let closeError {
                errorToReport = NetworkError(quicTransportError: closeError)
            }
        }
        // We have received a bogus first packet and we didn't switch
        // to a valid state.  Don't send a CONNECTION_CLOSE frame in that case.
        if state != .idle {
            // When sending frames, we may receive an error immediately
            // from the lower stack (due to defunct, for example)
            // so switch to closing state before sending packets.
            // Note: sendFrames() before closing TLS based on this external event
            state.change(to: .closing, logIDString: logPrefixer.logIDString)
            sendFrames()
        }
        closeTLSFlow()

        knownFlows.removeAll()
        localTransportParameters.removeAll()
        remoteTransportParameters?.removeAll()

        connectionMetadata = .init()

        deliverDisconnectedEvent(flow: .allFlows, error: errorToReport)

        // After sending a CONNECTION_CLOSE frame, an endpoint immediately enters the closing state
        // After receiving a CONNECTION_CLOSE frame, endpoints enter the draining state;
        // The closing and draining connection states exist to ensure that connections close
        // cleanly and that delayed or reordered packets are properly discarded.
        // These states SHOULD persist for at least three times the current PTO interval as defined in [QUIC-RECOVERY].
        if receivedConnectionClose {
            drainingScheduled = true
            withCurrentPath { path in
                _ = timer.insert(
                    description: "draining",
                    fromNow: path.recoveryState.getMaxPTODrainTime(idleTimeout: self.idleTimeout)
                ) {
                    self.drain()
                }
            }
        } else {
            cleanupAndLogFinalData()
        }

        // Break all of the strong references to the metadata
        self.unsetMetadataHandlers()
    }

    func drain() {
        if state == .idle {
            log.debug("Connection is idle, not draining")
            return
        }

        if state == .draining {
            log.debug("Already in draining state")
            return
        }
        // End in draining
        QUICSignpost.draining(id: signpostID)
        state.change(to: .draining, logIDString: logPrefixer.logIDString)
        cleanupAndLogFinalData()
    }

    func cleanupAndLogFinalData() {
        timer.stop()
        ack.reset()
        recovery.resetAll()
        currentPath = nil
        logSummary()

        writeQLog()
    }

    func keepaliveSendPingFrame(timeSinceLastReceived: NetworkDuration) {
        // N.B.: allow 1ms of leeway.
        if timeSinceLastReceived + .milliseconds(1) >= keepaliveDuration {
            if maxKeepaliveCount > 0 && unackedKeepaliveCount >= maxKeepaliveCount {
                log.error(
                    "Keep-alive timer fired, exceeding \(maxKeepaliveCount) outstanding keep-alives"
                )
                errorToReport = .posix(ETIMEDOUT)
                close(with: .noError, "keepalive limit reached")
                return
            }
            log.info("Sending keep-alive frame, already have \(unackedKeepaliveCount) outstanding")
            unackedKeepaliveCount += 1

            withPendingItems(for: .applicationData) {
                $0.ping = true
                $0.isKeepalive = true
            }

            // Re-arm the timer
            if let keepaliveTimerID = keepaliveTimerID {
                timer.reschedule(
                    identifier: keepaliveTimerID,
                    fromNow: keepaliveDuration,
                    timerNow: self.now
                )
            }
            // Keepalive packets ignore the congestion window.
            sendFrames(ignoreCongestionWindow: true)
            migration.checkForKeepaliveLoss(outstandingCount: unackedKeepaliveCount)
        }
    }

    func keepaliveHandler() {
        // We try to delay the keep-alive by some delta amount
        // depending on when we last received a valid packet
        // from the remote side.
        let now = NetworkClock.Instant.now
        if _slowPath(now < lastPacketReceivedTimestamp) {
            log.fault("Bogus lastPacketReceivedTimestamp")
            return
        }
        stats.increment(.keepAliveFramesSent)
        let timeSinceLastReceived = lastPacketReceivedTimestamp.duration(to: now)
        log.debug(
            "Keepalive: now: \(now), last packet: \(self.lastPacketReceivedTimestamp) timeSinceLastReceived: \(timeSinceLastReceived), interval: \(self.keepaliveDuration)"
        )

        keepaliveSendPingFrame(timeSinceLastReceived: timeSinceLastReceived)
    }

    func keepaliveConfigure(duration: NetworkDuration) {
        if keepaliveDuration == .zero && duration == .zero {
            // Nothing to enable/disable.
            return
        }
        keepaliveDuration = duration
        if self.state != .connected {
            // We're not yet connected, so just save the value and return.
            // We'll setup the timer once we are connected.
            return
        }
        let idleTimeoutLocal = self.localTransportParameters.intValue(.maxIdleTimeout)
        let idleTimeoutRemote = self.remoteTransportParameters?.intValue(.maxIdleTimeout) ?? 0

        // An idle timeout value of 0 implies the absence of idle timeout.
        // Therefore when either of the idle timeouts is 0, consider the other
        // one, else take the minimum of the two.
        var minIdleTime: NetworkDuration = .zero
        if idleTimeoutLocal == 0 {
            minIdleTime = .milliseconds(idleTimeoutRemote)
        } else if idleTimeoutRemote == 0 {
            minIdleTime = .milliseconds(idleTimeoutLocal)
        } else {
            minIdleTime = .milliseconds(min(idleTimeoutLocal, idleTimeoutRemote))
        }
        if keepaliveTimerID == nil {
            keepaliveTimerID = timer.insert(description: "keepalive") {
                self.keepaliveHandler()
            }
        }
        // If connection has a non-zero timeout, keep-alive has to be less
        // than that, else there's no point of performing keep-alives.
        //
        // However if the idle timeout is 0, it just means connection will never
        // timeout however long it remains idle for. In that case we always
        // have to do keep-alives.
        if let timerID = keepaliveTimerID {
            if keepaliveDuration == .zero {
                timer.reschedule(
                    identifier: timerID,
                    fromNow: .zero,
                    timerNow: self.now
                )
                log.notice("Stopped keep-alive timer")
            } else if minIdleTime == .zero || keepaliveDuration < minIdleTime {
                timer.reschedule(
                    identifier: timerID,
                    fromNow: keepaliveDuration,
                    timerNow: self.now
                )
                log.notice("Started keep-alive timer (\(keepaliveDuration)")
            }
        }
    }

    // MARK: Send outbound frames
    // Use PendingItems to keep track of what to send, which includes any newly
    // serviceable stream.

    var initialPendingItems = PendingItems(packetNumberSpace: .initial)
    var handshakePendingItems = PendingItems(packetNumberSpace: .handshake)
    var applicationPendingItems = PendingItems(packetNumberSpace: .applicationData)
    @discardableResult
    func withPendingItems<T>(
        for packetNumberSpace: PacketNumberSpace,
        block: (inout PendingItems) -> T
    ) -> T {
        switch packetNumberSpace {
        case .initial:
            return block(&initialPendingItems)
        case .handshake:
            return block(&handshakePendingItems)
        case .applicationData:
            return block(&applicationPendingItems)
        }
    }
    @discardableResult
    func withPendingItems<T>(
        for packetNumberSpace: PacketNumberSpace,
        frame: consuming QUICFrame,
        block: (inout PendingItems, consuming QUICFrame) -> T
    ) -> T {
        switch packetNumberSpace {
        case .initial:
            return block(&initialPendingItems, frame)
        case .handshake:
            return block(&handshakePendingItems, frame)
        case .applicationData:
            return block(&applicationPendingItems, frame)
        }
    }
    @discardableResult
    func withPendingItemsForKeyState<T>(block: (inout PendingItems) -> T) -> T {
        let packetNumberSpace = PacketNumberSpace.fromKeyState(keyState: self.keyState)
        return withPendingItems(for: packetNumberSpace) { block(&$0) }
    }
    func isAckSet(packetNumberSpace: PacketNumberSpace) -> Bool {
        withPendingItems(for: packetNumberSpace) { $0.isAckSet }
    }
    func scheduleAckFrame(
        packetNumberSpace: PacketNumberSpace,
        ackFrame: consuming QUICFrame,
        sendPing: Bool
    ) {
        withPendingItems(for: packetNumberSpace, frame: ackFrame) { pendingItems, ackFrame in
            pendingItems.setAckFrame(ackFrame, ping: sendPing)
        }
    }

    func flushPendingItems() {
        initialPendingItems.flush()
        handshakePendingItems.flush()
        applicationPendingItems.flush()
    }

    // Indicates whether the asynchronous send continuation is running or not
    private var asyncSendRunning = false

    private func capacityForPacketNumberSpace() -> Int {
        let packetNumberSpace = PacketNumberSpace.fromKeyState(keyState: self.keyState)
        if packetNumberSpace == .applicationData {
            if !applicationPendingItems.stream {
                return 1
            } else {
                return 10
            }
        } else {
            return 1
        }
    }

    @discardableResult
    func sendFrames(ignoreCongestionWindow: Bool = false, delayedACK: Bool = false) -> Bool {
        // Make sure there are packets to send
        guard
            initialPendingItems.hasPendingItems
                || handshakePendingItems.hasPendingItems
                || applicationPendingItems.hasPendingItems
        else {
            return false
        }
        // For ACK bundling purposes make sure to rely on the ACK-delay timer as much as possible,
        // unless an immediate ACK needs to be processed.
        guard !applicationPendingItems.isAckOnly || delayedACK || ack.immediateAcks > 0 else {
            // Make sure the ack-delay timer is armed if returning early
            ack.scheduleDelayedAck()
            return false
        }
        return withCurrentPath { path in
            var sentPackets = NetworkUniqueDeque<SentPacketRecord>(minimumCapacity: capacityForPacketNumberSpace())
            var discardInitialRecoveryState = false
            let success = sendFramesInternal(
                path: path,
                ignoreCongestionWindow: ignoreCongestionWindow,
                retransmission: false,
                sentPackets: &sentPackets,
                discardInitialRecoveryState: &discardInitialRecoveryState
            )

            // Trigger PMTUD if necessary
            var pmtudPackets = path.pmtudState.sendProbe(on: path)
            while let pmtudPacket = pmtudPackets.popFirst() {
                sentPackets.append(pmtudPacket)
            }
            recovery.recordSentPackets(sentPackets, connection: self)
            if discardInitialRecoveryState {
                recovery.resetPNSpace(packetNumberSpace: .initial, connection: self)
                withCurrentPath {
                    recovery.resetPTOCount(path: $0)
                }
            }
            return success
        }
    }

    @discardableResult
    func sendFrames(
        on path: QUICPath,
        ignoreCongestionWindow: Bool = false,
        retransmission: Bool = false
    ) -> Bool {
        var sentPackets = NetworkUniqueDeque<SentPacketRecord>(minimumCapacity: capacityForPacketNumberSpace())
        var discardInitialRecoveryState = false
        let success = sendFramesInternal(
            path: path,
            ignoreCongestionWindow: ignoreCongestionWindow,
            retransmission: retransmission,
            sentPackets: &sentPackets,
            discardInitialRecoveryState: &discardInitialRecoveryState
        )
        recovery.recordSentPackets(sentPackets, connection: self)
        if discardInitialRecoveryState {
            recovery.resetPNSpace(packetNumberSpace: .initial, connection: self)
            withCurrentPath {
                recovery.resetPTOCount(path: $0)
            }
        }
        return success
    }

    @discardableResult
    func sendFramesFromRecovery(
        on path: QUICPath,
        ignoreCongestionWindow: Bool = false,
        retransmission: Bool = false,
        discardInitialRecoveryState: inout Bool
    ) -> NetworkUniqueDeque<SentPacketRecord> {
        var sentPackets = NetworkUniqueDeque<SentPacketRecord>(minimumCapacity: capacityForPacketNumberSpace())
        _ = sendFramesInternal(
            path: path,
            ignoreCongestionWindow: ignoreCongestionWindow,
            retransmission: retransmission,
            sentPackets: &sentPackets,
            discardInitialRecoveryState: &discardInitialRecoveryState
        )
        return sentPackets
    }

    func recordSentPackets(_ block: () -> NetworkUniqueDeque<SentPacketRecord>) {
        let sentPackets = block()
        recovery.recordSentPackets(sentPackets, connection: self)
    }

    public func handleOutboundRoomAvailableEvent(path pathID: MultiplexingPathIdentifier) {
        guard let path = path(for: pathID) else { return }
        sendFrames(on: path)
    }

    private func buildOutboundFrameBatch(availableCongestionWindow: UInt64) -> FrameArray {
        var outboundBatch = FrameArray()
        // If ACK is only set or the connection is blocked just send empty batch
        if applicationPendingItems.isAckSet || self.hasSentDataBlocked {
            return outboundBatch
        }
        let sendDataLength = self.flowControlState.pendingOutboundBytesToSend
        if let currentPath, sendDataLength > 0 {
            var requestedFrameLength: Int = 0
            if let probeMSS = applicationPendingItems.pmtudProbeMSS {
                requestedFrameLength = probeMSS
            } else {
                requestedFrameLength = currentPath.mss
            }
            // For small writes, the standard path works fine, for larger writes create a batched frame array
            if sendDataLength >= requestedFrameLength {
                let minSendLength = Int(truncatingIfNeeded: min(availableCongestionWindow, sendDataLength))
                var batchLength =
                    minSendLength / requestedFrameLength
                    + (minSendLength % requestedFrameLength > 0 ? 1 : 0)
                // If the batch length is too large because the congestion window is large, throttle it down to packetBurstCount per stream.
                // If we need more frames they will be requested when the burst limit is reached
                batchLength = min(batchLength, Constants.packetBurstCount)
                // Only request if we have a batchLength greater than 1
                if batchLength > 1,
                    let outFrames = try? getDatagramsToSend(
                        path: currentPath.identifier,
                        maximumDatagramCount: batchLength,
                        minimumDatagramSize: requestedFrameLength
                    )
                {
                    outboundBatch = outFrames
                }
            }
        }
        return outboundBatch
    }

    private func sendOutboundFrames(_ outboundFrames: consuming FrameArray, on path: QUICPath) {
        guard !outboundFrames.isEmpty else { return }
        do throws(NetworkError) {
            try self.enqueueOutboundDatagrams(
                path: path.identifier,
                datagrams: outboundFrames
            )
            try self.sendEnqueuedOutboundDatagrams(path: path.identifier)
        } catch {
            log.error("Failed to send outbound datagrams: \(error)")
        }
    }

    // Don't use directly, use above sendFrames*()
    private func sendFramesInternal(
        path: QUICPath,
        ignoreCongestionWindow: Bool = false,
        retransmission: Bool = false,
        sentPackets: inout NetworkUniqueDeque<SentPacketRecord>,
        discardInitialRecoveryState: inout Bool
    ) -> Bool {
        // Handle the case of having additional paths at the very beginning of the connection.
        if path.mss == 0 {
            setInitialMSS(on: path)
        }

        var drop = false
        guard canSendFrames(on: path, drop: &drop) else {
            return drop
        }

        var totalSendBytes: UInt64 = 0
        // Ignoring is equivalent to an infinite window
        var availableCongestionWindow = UInt64.max
        if !ignoreCongestionWindow {
            availableCongestionWindow = path.congestionControlAvailableCongestionWindow
        }

        let startSendingTimestamp = self.now
        if path != currentPath {
            // If the isn't current, send only items for the path
            guard path.hasPendingItems(now: startSendingTimestamp) else {
                return false
            }
            var pendingItems = PendingItems(
                packetNumberSpace: PacketNumberSpace.fromKeyState(keyState: keyState)
            )
            path.addPendingItems(&pendingItems, now: startSendingTimestamp)
            var datagramBatch = FrameArray()
            if self.flowControlState.pendingOutboundBytesToSend > 0 && availableCongestionWindow > 0 {
                datagramBatch = buildOutboundFrameBatch(
                    availableCongestionWindow: (availableCongestionWindow - totalSendBytes)
                )
            }
            var outboundFrameArray = FrameArray()
            let success = buildSinglePacketForKeyState(
                self.keyState,
                pendingItems: &pendingItems,
                sentPackets: &sentPackets,
                on: path,
                ignoreCongestionWindow: ignoreCongestionWindow,
                availableCongestionWindow: &availableCongestionWindow,
                totalSendBytes: &totalSendBytes,
                retransmission: retransmission,
                datagramBatch: &datagramBatch,
                outboundFrames: &outboundFrameArray
            )
            if !outboundFrameArray.isEmpty {
                sendOutboundFrames(outboundFrameArray, on: path)
            }
            return success
        }

        // Make sure there is something to send, do not allocate empty frame arrays if we do not have to.
        guard
            initialPendingItems.hasPendingItems || handshakePendingItems.hasPendingItems
                || applicationPendingItems.hasPendingItems
        else {
            return false
        }
        var datagramBatch = FrameArray()
        if self.flowControlState.pendingOutboundBytesToSend > 0 && availableCongestionWindow > 0 {
            datagramBatch = buildOutboundFrameBatch(
                availableCongestionWindow: (availableCongestionWindow - totalSendBytes)
            )
        }

        // Sending on the current path.
        // Add the path frames to the items for application data
        withPendingItems(for: .applicationData) {
            path.addPendingItems(&$0, now: startSendingTimestamp)
        }

        defer {
            if !datagramBatch.isEmpty {
                datagramBatch.finalizeAllFramesAsFailed()
            }
        }

        var outboundFrameArray = FrameArray()
        if !initialKeysDiscarded {
            while initialPendingItems.hasPendingItems {
                if initialKeysDiscarded {
                    initialPendingItems.flush()
                    break
                }

                guard
                    buildSinglePacketForKeyState(
                        .initial,
                        pendingItems: &initialPendingItems,
                        sentPackets: &sentPackets,
                        on: path,
                        ignoreCongestionWindow: ignoreCongestionWindow,
                        availableCongestionWindow: &availableCongestionWindow,
                        totalSendBytes: &totalSendBytes,
                        retransmission: retransmission,
                        datagramBatch: &datagramBatch,
                        outboundFrames: &outboundFrameArray
                    )
                else {
                    break
                }
                if !ignoreCongestionWindow && totalSendBytes >= availableCongestionWindow {
                    break
                }
            }
        }

        while handshakePendingItems.hasPendingItems {
            if isHandshakeConfirmed {
                handshakePendingItems.flush()
                break
            }

            // Discard keys first to make sure we have room in congestion control
            if !isServer && !initialKeysDiscarded {
                discardInitialRecoveryState = true
                discardKeys(keyState: .initial, discardRecoveryState: false)
                initialKeysDiscarded = true
            }

            guard
                buildSinglePacketForKeyState(
                    .handshake,
                    pendingItems: &handshakePendingItems,
                    sentPackets: &sentPackets,
                    on: path,
                    ignoreCongestionWindow: ignoreCongestionWindow,
                    availableCongestionWindow: &availableCongestionWindow,
                    totalSendBytes: &totalSendBytes,
                    retransmission: retransmission,
                    datagramBatch: &datagramBatch,
                    outboundFrames: &outboundFrameArray
                )
            else {
                break
            }
            if !ignoreCongestionWindow && totalSendBytes >= availableCongestionWindow {
                break
            }
        }

        var packetBurst = 0
        var packetBurstTotal = 0
        while applicationPendingItems.hasPendingItems {
            let keyState: PacketKeyState
            if self.keyState == .initial {
                keyState = .earlyData
            } else if self.keyState == .phase1 {
                keyState = .phase1
            } else {
                keyState = .phase0
            }

            guard
                buildSinglePacketForKeyState(
                    keyState,
                    pendingItems: &applicationPendingItems,
                    sentPackets: &sentPackets,
                    on: path,
                    ignoreCongestionWindow: ignoreCongestionWindow,
                    availableCongestionWindow: &availableCongestionWindow,
                    totalSendBytes: &totalSendBytes,
                    retransmission: retransmission,
                    datagramBatch: &datagramBatch,
                    outboundFrames: &outboundFrameArray
                )
            else {
                break
            }

            if !ignoreCongestionWindow && totalSendBytes >= availableCongestionWindow {
                break
            }

            var shouldEndBurst = false
            packetBurst += 1
            packetBurstTotal += 1

            if packetBurstTotal >= Constants.maxPacketBurstCount {
                // The maximum total packet count has been reached
                shouldEndBurst = true
            } else if packetBurst >= Constants.packetBurstCount {
                // The packet burst count has been reached, check the time
                if startSendingTimestamp.duration(to: .now) >= Constants.maxPacketBurstDuration {
                    // The maximum burst time has been reached
                    shouldEndBurst = true
                } else {
                    // Reset the local burst count and continue
                    packetBurst = 0
                    if datagramBatch.isEmpty {
                        // If sending packet bursts and the original batch of prefetched datagrams is empty, fetch a new batch
                        datagramBatch = buildOutboundFrameBatch(
                            availableCongestionWindow: (availableCongestionWindow - totalSendBytes)
                        )
                    }
                }
            }

            // If we've exceeded the send burst limit, trigger an async before servicing more data
            if shouldEndBurst {
                log.datapath("burst limit application data")
                applicationPendingItems.rotateFirstStreamToService()
                burstLimitReached()
                break
            }
        }
        if !outboundFrameArray.isEmpty {
            sendOutboundFrames(outboundFrameArray, on: path)
        }
        return true
    }

    private func buildSinglePacketForKeyState(
        _ keyState: PacketKeyState,
        pendingItems: inout PendingItems,
        sentPackets: inout NetworkUniqueDeque<SentPacketRecord>,
        on path: QUICPath,
        ignoreCongestionWindow: Bool,
        availableCongestionWindow: inout UInt64,
        totalSendBytes: inout UInt64,
        retransmission: Bool,
        datagramBatch: inout FrameArray,
        outboundFrames: inout FrameArray
    ) -> Bool {
        let packetNumberSpace = pendingItems.packetNumberSpace

        if path.isFlowControlled {
            log.datapath("Path is flow controlled")
            return false
        }

        // Server must not send more than 3x the number of bytes received, until
        // the client's address has been validated by receiving a handshake
        // packet. To enforce this constraint limit the congestion window to not send more 3x received.
        if isServer, !receivedHandshakePacket {
            let totalReceivedBytes = stats[.rxBytes] * 3
            let totalSentBytes = stats[.txBytes]
            // Make sure totalReceivedBytes is greater
            if totalReceivedBytes >= totalSentBytes {
                availableCongestionWindow = UInt64(totalReceivedBytes - totalSentBytes)
            } else {
                availableCongestionWindow = 0
            }
            log.debug(
                "Setting available congestion window: \(availableCongestionWindow) until the client is validated"
            )
        }
        guard availableCongestionWindow > 0 || pendingItems.hasNonInFlightEligiblePendingItems
        else {
            log.datapath("Path is congestion controlled")
            return false
        }

        if keyState == .initial {
            // Initial packets are always fully padded, only allow if the congestion window has room
            guard availableCongestionWindow >= path.mss else {
                log.datapath("Path is congestion controlled, cannot fit a full initial packet")
                return false
            }
        }

        guard protector.sealKeyReady(for: keyState) else {
            return false
        }

        var largestAcked = largestAckedPacketNumber(space: packetNumberSpace)
        largestAcked = largestAcked.value == Int.max ? PacketNumber.none : largestAcked

        let space = PacketNumberSpace.fromKeyState(keyState: keyState)
        let tagSize = protector.getTagSize(for: keyState)

        if isPacing {
            let now = NetworkClock.Instant.now
            // lastAckElicitingPacketSentTimestamp can be in the future for kernel packet pacing.
            if now > lastAckElicitingPacketSentTimestamp {
                let idleTime = lastAckElicitingPacketSentTimestamp.duration(to: now)
                if state == .connected && idleTime > Constants.congestionWindowNonvalidatedPeriod {
                    // We have been idle for 3 minutes
                    path.idleTimeoutCongestionControl()
                }
            }
        }

        if !pendingItems.isAckSet && ack.ackRequiresAssembly(packetNumberSpace: packetNumberSpace) {
            func scheduleAckFrame(
                packetNumberSpace: PacketNumberSpace,
                ackFrame: consuming QUICFrame,
                sendPing: Bool
            ) {
                if packetNumberSpace == pendingItems.packetNumberSpace {
                    pendingItems.setAckFrame(ackFrame, ping: sendPing)
                }
            }
            let receivedIPECNCounter = ecn.counters[packetNumberSpace].rxECNPackets
            let _ = ack.assemble(
                for: packetNumberSpace,
                isAckSet: false,  // it was just checked
                setAckFrame: scheduleAckFrame,
                ecnCounter: receivedIPECNCounter,
                now: self.now
            )
        }

        // Request a full size frame, up to the available congestion window,
        // to be able to greedy fill without pre-calculating size
        let requestedFrameLength: Int
        if let probeMSS = pendingItems.pmtudProbeMSS {
            requestedFrameLength = probeMSS
        } else if pendingItems.isAckOnly,
            !Packet.requiresLongHeader(keyState: keyState),
            let dcid = path.dcid
        {
            // For common case of ACK-only packets, calculate the small size required
            // Add buffer for packet number length
            requestedFrameLength =
                (Packet.shortHeaderBaseSize + Int(tagSize) + dcid.length + pendingItems.ackFrameLength + 4)
        } else {
            requestedFrameLength = path.mss
        }

        var outFrame: Frame
        if let batchFrame = datagramBatch.popFirst() {
            // If there are frames in the pool, prefer those first
            outFrame = batchFrame
        } else {
            guard
                var outFrames = try? getDatagramsToSend(
                    path: path.identifier,
                    maximumDatagramCount: 1,
                    minimumDatagramSize: requestedFrameLength
                ),
                let newFrame = outFrames.popFirst()
            else {
                // Note: handleOutboundRoomAvailableEvent will restart sending
                log.debug("QUIC path failed to get a frame")
                return false
            }
            outFrame = newFrame
        }

        let frameLength = outFrame.unclaimedLength
        if frameLength > requestedFrameLength {
            _ = outFrame.collapse(to: requestedFrameLength)
        }

        var totalBytesWrittenInFrame = 0
        repeat {
            let newPacketNumber = protector.getPacketNumber(for: space)

            var packet: Packet?
            var sentPacketRecord = SentPacketRecord()

            do throws(QUICError) {
                packet = try Packet.build(
                    into: &outFrame,
                    number: newPacketNumber,
                    lastAcked: largestAcked,
                    keyState: keyState,
                    path: path,
                    tagSize: tagSize,
                    pendingItems: &pendingItems,
                    sentPacketRecord: &sentPacketRecord,
                    connection: self,
                    availableCongestionWindow: availableCongestionWindow,
                    token: initialToken,
                    stats: &self.stats,
                    version: currentVersion
                )
            } catch {
                if totalBytesWrittenInFrame > 0 {
                    log.debug("Not writing second packet into frame")
                    break
                }
                self.log.error(
                    "Failed to build packet: \(error.info.description), code \(error.info.code)"
                )
                outFrame.finalize(success: false)
                return false
            }

            guard var packet else {
                outFrame.finalize(success: false)
                return false
            }
            let isInFlightEligible = sentPacketRecord.isInFlightEligible
            outFrame.ecnFlag = ECN.outgoingIPCodepoint(
                ecn: self.ecn,
                path: currentPath,
                stats: &stats,
                packet: &sentPacketRecord
            )
            if sentPacketRecord.ectMarked {
                stats.increment(.ecnCapablePacketsSent)
            }

            // Record the largest connection ID sent.
            // This is checked in processRetireConnectionIDFrame.
            if sentPacketRecord.transmittedItems.newConnectionID {
                for newConnectionID in sentPacketRecord.transmittedItems.newConnectionIDs {
                    let sequence = newConnectionID.sequence
                    if sequence > largestSentLocalCIDSequenceNumber {
                        largestSentLocalCIDSequenceNumber = sequence
                    }
                }
            }

            // Claim off any extra bytes at the end to make sure the protector
            // has only a complete packet to work with
            let totalPacketLength = packet.totalLength
            let totalUnclaimed = outFrame.unclaimedLength
            let unclaimedAfterPacket =
                (totalUnclaimed > totalPacketLength) ? (totalUnclaimed - totalPacketLength) : 0
            if unclaimedAfterPacket > 0 {
                guard outFrame.claim(fromStart: 0, fromEnd: unclaimedAfterPacket) else {
                    self.log.error(
                        "Failed to claim \(unclaimedAfterPacket) bytes from end of frame"
                    )
                    outFrame.finalize(success: false)
                    return false
                }
            }

            if isPacing {
                var sendTimeContinuous: NetworkClock.Instant = .zero
                var sendTimeAbsolute: NetworkClock.Instant = .zero
                path.pacer.getSendTime(
                    path: path,
                    packetLength: UInt16(truncatingIfNeeded: totalPacketLength),
                    sendTimeAbsolute: &sendTimeAbsolute,
                    sendTimeContinuous: &sendTimeContinuous
                )
                if sendTimeAbsolute >= .zero {
                    outFrame.departureTime = UInt64(sendTimeAbsolute.time.nanoseconds)
                    stats.increment(.txDepartureTimestamp)
                }
                if sentPacketRecord.isAckEliciting {
                    lastAckElicitingPacketSentTimestamp = sendTimeContinuous
                }
            }
            stats.increment(.txBytes, by: totalPacketLength)
            stats.increment(.txPackets)
            withCurrentPath { (path: borrowing QUICPath) -> Void in
                path.pathStatistics[.txPackets] += 1
                path.pathStatistics[.txBytes] += Int(totalPacketLength)
            }
            // Seal packet, incidentally this also effectively takes the packet number!
            do throws(QUICError) {
                try self.protector.seal(&packet, frame: &outFrame)
            } catch {
                self.log.error(
                    "Failed to seal packet: \(error.info.description), code \(error.info.code)"
                )
                outFrame.finalize(success: false)
                return false
            }

            if unclaimedAfterPacket > 0 {
                guard outFrame.unclaim(fromStart: 0, fromEnd: unclaimedAfterPacket) else {
                    self.log.error(
                        "Failed to unclaim \(unclaimedAfterPacket) bytes from end of frame"
                    )
                    outFrame.finalize(success: false)
                    return false
                }
            }

            // Claim the total packet length, and update the total written bytes
            totalBytesWrittenInFrame += totalPacketLength
            guard outFrame.claim(fromStart: totalPacketLength) else {
                self.log.error("Failed to claim \(totalPacketLength) bytes from start of frame")
                outFrame.finalize(success: false)
                return false
            }

            let longHeader = packet.longHeader
            sentPacketRecord.sentPath = path.identifier
            log(packet: &packet, outbound: true)

            sentPackets.append(sentPacketRecord)

            if isInFlightEligible {
                totalSendBytes += UInt64(totalPacketLength)
            }
            if !ignoreCongestionWindow && totalSendBytes >= availableCongestionWindow {
                self.log.datapath(
                    "Total bytes sent has met the congestion window limit, total bytes \(totalSendBytes) >= congestion window \(availableCongestionWindow)"
                )
                break
            }

            if !testSendingShortPackets {
                break
            }

            // Any short header packet must be the last packet in the frame
            if !longHeader {
                break
            }

            // No room left for another packet!
            let remainingBytes = outFrame.unclaimedLength
            if remainingBytes == 0 {
                break
            }

            // Allow sending a padding-only packet for a second packet
            if !pendingItems.hasPendingItems && !pendingItems.hasPadding {
                break
            }
        } while testSendingShortPackets

        // We may not have used the entire frame with packets. If not, collapse
        // the frame down and unclaim all written bytes
        outFrame.collapse()
        guard outFrame.unclaim(fromStart: totalBytesWrittenInFrame) else {
            self.log.error("Failed to unclaim frame")
            outFrame.finalize(success: false)
            return false
        }

        QUICSignpost.outbound(id: signpostID, length: totalBytesWrittenInFrame)

        outboundFrames.add(frame: outFrame)
        return true
    }

    func retransmitPacket(
        _ packet: borrowing SentPacketRecord,
        discardInitialRecoveryState: inout Bool
    ) -> NetworkUniqueDeque<SentPacketRecord> {
        if let path = path(for: packet.sentPath),
            path.pmtudState.enabled,
            let pmtudProbeMSS = packet.transmittedItems.pmtudProbeMSS
        {
            path.pmtudState.probeLost(
                on: path,
                packetLen: pmtudProbeMSS,
                packetNumber: packet.number
            )
        }

        if !packet.transmittedItems.hasRetransmissibleItems {
            log.datapath("Not retransmitting \(packet.number), ignoring")
            return .init()
        }

        log.datapath("Packet \(packet.number) lost, adding to pending items")
        // Merge the retransmitted data with existing pendingItems
        withPendingItems(for: packet.numberSpace) {
            $0.copyForRetransmission(from: packet.transmittedItems, connection: self)
        }

        // Trigger sending packets.
        guard let currentPath else {
            return .init()
        }
        return sendFramesFromRecovery(on: currentPath, discardInitialRecoveryState: &discardInitialRecoveryState)
    }

    func retransmitOnePacketForced(
        packet: borrowing SentPacketRecord,
        path: QUICPath,
        discardInitialRecoveryState: inout Bool
    ) -> NetworkUniqueDeque<SentPacketRecord> {
        if !packet.transmittedItems.hasRetransmissibleItems {
            log.datapath("Not retransmitting \(packet.number), moving to next")
            return .init()
        }
        // Merge the retransmitted data with existing pendingItems
        withPendingItems(for: packet.numberSpace) {
            $0.copyForRetransmission(from: packet.transmittedItems, connection: self)
        }

        log.datapath("Packet \(packet.number) lost, sending new packet")
        return sendFramesFromRecovery(
            on: path,
            ignoreCongestionWindow: true,
            retransmission: true,
            discardInitialRecoveryState: &discardInitialRecoveryState
        )
    }

    private func log(packet: inout Packet, coalesced: Bool = false, outbound: Bool) {
        #if !NETWORK_EMBEDDED
        if Logger.swiftNetworkDatapathLoggingEnabled {
            let now = NetworkClock.Instant.now
            var delta: NetworkDuration = .milliseconds(0)
            if lastShorthandTimestamp != .zero {
                delta = lastShorthandTimestamp.duration(to: now)
            }
            let arrow = outbound ? "→ " : "← "
            let entry = ShorthandPacket(packet: packet, outgoing: outbound, delta: delta)
            log.datapath(entry.description)
            if let shorthandFrames = packet.shorthandFrames {
                for shorthandFrame in shorthandFrames {
                    log.datapath(arrow + shorthandFrame.description)
                }
            }
            lastShorthandTimestamp = now
        }
        // Support for qlog
        #if QlogOutput
        if let qLog {
            if outbound {
                qLog.packetSent(packet)
            } else {
                qLog.packetReceived(packet, coalesced: coalesced)
            }
        }
        #endif
        #endif

        // Now that we had a chance to log the frames, release the memory.
        packet.shorthandFrames?.removeAll()
    }

    private func processOutbound(
        frame: consuming Frame,
        flowID: MultiplexedFlowIdentifier,
        stream: QUICStreamInstance,
        isLast: Bool
    ) {
        if !isServer, state == .idle {
            state.change(to: .initialSent, logIDString: logPrefixer.logIDString)
        }

        if frame.unclaimedLength > Constants.streamDataMaxSize {
            log.error("Stream data length is too large")
            frame.finalize(success: false)
            return
        }

        stream.addStreamData(frame: frame, isLast: isLast, connection: self)
    }

    internal func handleStopRead(for stream: QUICStreamInstance) {
        if stream.readClosed {
            // Already handled
            return
        }
        stream.log.debug("Read closed")
        if stream.pendingStart {
            if stream.unidirectional {
                self.unidirectionalStreams.removePending(stream)
            } else {
                self.bidirectionalStreams.removePending(stream)
            }
        }

        if stream.receiveState == .receive && !state.isTerminal {
            sendStopSending(stream: stream)
            stream.stopSendRequested = true

            // Create a zombie stream so that we can release
            // resources while we wait for the RESET_STREAM.
            let lastOffset = stream.reassemblyQueue.lastOffset
            let lastSize = lastOffset == 0 ? 0 : lastOffset + 1
            // Using streamID! is safe because a stream cannot not be in receive
            // state without a streamID
            zombieStreamList.append(
                logIDString: stream.logPrefix,
                streamID: stream.streamID!,
                lastSize: UInt64(lastSize),
                localMaxStreamData: stream.flowControlState.inboundMaxData
            )

            // Do we delete this 'stream' somehow, now that it's a zombie?
            // Once it's got no more references it will automatically taken care of
            // with ARC. It may have references in pendingStartStreams (removed above)
            // or one of the QUICStreamLists or the knownFlows[] or clientState, all
            // of which are (must be) taken care of elsewhere.
        }
    }

    internal func handleStopWrite(
        for stream: QUICStreamInstance
    ) -> Bool {
        var closeWrite = true

        stream.log.debug("Write closed for stream")
        if stream.pendingStart {
            if stream.unidirectional {
                unidirectionalStreams.removePending(stream)
            } else {
                bidirectionalStreams.removePending(stream)
            }
        }

        if !state.isTerminal {
            // Send a FIN if we are closing a stream without an error.
            // Otherwise, send RESET_STREAM.
            // Technically, 0 can be valid application error code, but
            // it isn't for HTTP/3, so we can assume it's not set.
            if stream.sendState == .send && stream.outboundApplicationError == nil {
                markStreamFinished(stream: stream)
            } else if stream.sendState == .ready
                || (stream.sendState == .send && !stream.sendBuffer.hasLast
                    && stream.outboundApplicationError != nil)
            {
                // Drop all the pending data.
                stream.emptyPendingData(connection: self)
                sendResetStream(stream: stream)
                // Wait until RESET_STREAM is ACKed before closing this
                // stream.
                closeWrite = false
            }

            if stream.hasMoreSendDataToService {
                stream.log.debug(
                    "Send stream data queue is not empty, deferring close"
                )
                closeWrite = false
            }
        }

        return closeWrite
    }

    // return value indicates if processing should continue. False = stop processing and drop frame
    private func preDecryption(frame: inout Frame, path: QUICPath, packet: borrowing Packet) -> Bool {
        // N.B.: versionSent is an acceptable state because
        //       there might be a delay in receiving the INITIAL packet
        //       and the client might retransmit.
        //
        // Only proceed if we are a server, the packet has a long header of type=keyState == .initial,
        // and connection state is idle, retrySent or versionSent
        guard isServer, packet.longHeader, packet.keyState == .initial,
            state == .idle || state == .retrySent || state == .versionSent
        else {
            return false
        }

        // Server does not recognize the incoming packet version
        if packet.version != self.initialVersion {
            self.negotiatedVersion = self.initialVersion
            sendVersionNegotiation(packet: packet, path: path)
            if state != .versionSent {
                state.change(to: .versionSent, logIDString: logPrefixer.logIDString)
            }
            return false
        }

        if retryEnabled && state != .retrySent {
            // The server includes a connection ID of its choice in the Source Connection ID field.
            // This value MUST NOT be equal to the Destination Connection ID field of the packet sent by the client.
            let scid: QUICConnectionID
            if let determinedSCID = path.scid {
                scid = determinedSCID
            } else {
                // If a new SCID is created for the connection then it needs to be stored
                // in the QUICConnectionIDList so that a future inbound packet is recognized.
                scid = QUICConnectionID(8)
                path.setSCID(scid)
                do {
                    // Remove the old initial CID, and replace
                    _ = localCIDs.retire(sequenceNumber: 0)
                    try localCIDs.insertInitialConnectionID(scid)
                } catch {
                    // Not a fatal error; duplicates are not a problem for the protocol
                    log.error("Error inserting initial local CID: \(error)")
                }
            }
            retrySCID = scid
            var _token: [UInt8] = Array(repeating: 0, count: Int(Constants.retryTokenMaxLength))
            var randomNumberGenerator = SystemRandomNumberGenerator()
            for index in 0..<Constants.retryTokenMaxLength {
                _token[Int(index)] = UInt8.random(in: 0..<UInt8.max, using: &randomNumberGenerator)
            }
            initialToken = _token
            sendRetry(path: path, packet: packet)
            log.notice("New SCID: \(scid)")
            guard let dcid = packet.destinationConnectionID else {
                log.error("Packet does not contain dcid")
                return false
            }
            initialDCID = dcid
            log.info("Server setting initial to \(dcid)")
            state.change(to: .retrySent, logIDString: logIDString)
            return false
        }

        // Create the protector with the INITIAL DCID.
        protector = Protector(
            isClient: false,
            destinationCID: packet.destinationConnectionID!,
            logPrefixer: logPrefixer
        )

        return true
    }

    private func failedDecryption(_ packet: borrowing Packet) {
        if packet.tagLength == Constants.statelessResetTokenSize,
            let packetToken = packet.tag,
            let statelessToken = QUICStatelessResetToken(packetToken)
        {
            self.stats.increment(.statelessResetReceived)
            if remoteCIDs.find(statelessResetToken: statelessToken) != nil {
                if migration.probingPathCount(self) > 0 {
                    self.stats.increment(.statelessResetDuringPathProbe)
                }
                log.info("Received valid stateless reset token")
                errorToReport = NetworkError.posix(ECONNRESET)
                close()
            }
        }
    }

    // Returns true if reordering was detected, and hence an ACK should be sent immediately
    private func processReordering(packet: borrowing Packet) -> Bool {
        let largetACKElicitingPN = ack.getLargestAckElicitingPacketNumber(
            packetNumberSpace: packet.numberSpace
        )
        guard largetACKElicitingPN != .none else { return false }
        //
        // In order to assist loss detection at the sender, an endpoint SHOULD
        //   generate and send an ACK frame without delay when it receives an
        // ack- eliciting packet either:
        //   *  when the received packet has a packet number less than another
        //      ack-eliciting packet that has been received, or
        //   *  when the packet has a packet number larger than the highest-
        //      numbered ack-eliciting packet that has been received and there
        // are missing packets between that packet and this packet.
        //
        //   Ignore those rules if the peer asked us to ignore re-ordering.
        //
        if largetACKElicitingPN > packet.number
            || (largetACKElicitingPN < packet.number
                && ack.packetsMissingBetween(
                    packetNumberSpace: packet.numberSpace,
                    packetNumberLow: largetACKElicitingPN,
                    packetNumberHigh: packet.number
                ))
        {
            log.datapath(
                "reordering/loss detected (received: \(packet.number), largest ack-eliciting: \(largetACKElicitingPN), sending ACK"
            )
            stats.increment(.rxReorderedPackets)
            stats.increment(.rxReorderedBytes, by: Int(packet.totalLength))
            withCurrentPath { path in
                path.pathStatistics[.rxReorderedBytes] += Int(packet.totalLength)
            }
            return true
        }
        return false
    }

    private func canSendFrames(on path: QUICPath, drop: inout Bool) -> Bool {
        guard state != .draining else {
            log.debug("Not sending more frames, in draining state")
            drop = true
            return false
        }
        guard !path.isFlowControlled else {
            log.debug("Path is flow controlled, can't send")
            drop = false
            return false
        }

        // If we are connected, but the path is not in a sendable state, keep
        // waiting.
        if case .connected = state, path.state.isUnusable {
            log.debug("Path is in an unusable state, can't send")
            drop = false
            return false
        }

        return true
    }

    private func closeTLSFlow() {
        crypto.stop()
    }

    private func logSummary() {
        // TODO: log summary integration
    }

    private func writeQLog() {
        #if QlogOutput
        if let qLog {
            guard let configuration = qLog.configuration
            else {
                return
            }
            context.async {
                var flowType: QLogFlowType = .client
                var applicationType = "client"
                if self.isServer {
                    flowType = .server
                    applicationType = "server"
                }
                let title = configuration.logTitle ?? ""
                let connectionID = "C\(self.logIDNumber)"
                var filename = "qlog_\(applicationType)_\(connectionID).qlog"
                if title != "" {
                    filename = "qlog_\(applicationType)_\(title)_\(connectionID).qlog"
                }
                var finalPath: String
                if configuration.logPath.hasSuffix("/") {
                    finalPath = configuration.logPath + filename
                } else {
                    finalPath = configuration.logPath + "/\(filename)"
                }
                qLog.dumpJSONToFile(atPath: finalPath, forFlowType: flowType)
                self.log.info("Wrote qlog file to: \(finalPath)")
            }
        }
        #endif
    }

    func confirmHandshake() {
        if isHandshakeConfirmed {
            return
        }

        if !state.isConnected {
            log.fault("Still running the handshake, unable to discard handshake keys")
            return
        }

        discardKeys(keyState: .handshake)

        if isServer {
            withPendingItemsForKeyState { $0.handshakeDone = true }
            // If server, send NEW_TOKEN frame to the client after handshake for later connections
            // Note that the frame does not actually send because the newToken variable is nil
            withPendingItemsForKeyState { $0.newToken = true }
        }

        isHandshakeConfirmed = true
        log.debug("Handshake keys discarded")

        migration.handshakeConfirmed(self)
    }

    func updateSecretForHandshakeLevel() {
        if !isServer && state != .handshake {
            state.change(to: .handshake, logIDString: logPrefixer.logIDString)
        }
        if isServer && (state == .initialReceived || state == .initialProcessed) {
            state.change(to: .handshake, logIDString: logPrefixer.logIDString)
        }
    }

    func updateEarlyDataAccepted(_ accepted: Bool) {
        discardKeys(keyState: .earlyData)
        if accepted {
            earlyDataAccepted = true
        } else {
            if !resendRejectedEarlyDataAutomatically {
                applicationPendingItems.retransmitStreams.removeAll()
                flowControlState.resetSentBytes()
                applyToAllFlows { stream in
                    stream.resetSendStreamData()
                }
                deliverNetworkProtocolEvent(
                    flow: .allFlows,
                    event: .init(quicEvent: .earlyDataRejected)
                )
            }
        }
    }

    // The TLS handshake has reported that it is complete
    func reportReady() {
        // Crypto should already have set this up using setRemoteTransportParameters()
        guard let remoteTransportParameters, !remoteTransportParametersForEarlyData else {
            let error = "missing peer transport parameters"
            log.error(error)
            close(with: .transportParameterError, error)
            return
        }

        applyRemoteTransportParameters(remoteTransportParameters)
        // Exit early if we're already closed due to an error
        guard closeError == nil else { return }

        setupFlowControl(remoteTransportParameters: remoteTransportParameters)
        // Exit early if we're already closed due to an error
        guard closeError == nil else { return }

        if remoteTransportParameters[.disableActiveMigration] != nil {
            log.info("Peer asked us to disable active migration")
            migration.disableActiveMigration()
        } else if !isServer, self.currentPath?.dcid?.length == 0 {
            log.info("Disabling migration due to zero-length peer CID")
            migration.disableActiveMigration()
        } else {
            migrationSupported = true
        }

        state.change(to: .connected, logIDString: logPrefixer.logIDString)
        if let signpostConnectInterval {
            QUICSignpost.connectEnd(signpostConnectInterval)
        }
        // Now that the connection is connected check if isPacing can be set
        if !isPacing {
            if let currentPath, trafficManagementBackground == false {
                if currentPath.ecnState?.state == .capable || currentPath.pacePackets {
                    isPacing = true
                }
            }
        }

        handshakeDuration = handshakeStartTime.duration(to: .now)
        var currentRTT: NetworkDuration = .milliseconds(0)
        if let currentPath = currentPath {
            currentRTT = currentPath.rtt.smoothedRTT
            handshakeRTT = currentRTT
        }
        log.notice("QUIC connection established in \(handshakeDuration), RTT \(currentRTT)")

        self.keyState = .phase0

        if isServer {
            confirmHandshake()
        }

        logTransportParameters(owner: .remote, transportParameters: remoteTransportParameters)

        // This function should only be called when conn state changed to connected
        // Setup all streams and tell all flows that they are ready
        readyAllOutboundStreams()

        log.notice("Delivering connected")
        deliverConnectedEvent(flow: .allFlows)
        stats.increment(.connectionAttempts)

        // Advertise new CIDs to the peer, up to the amount specified by
        // active_connection_id_limit
        announceNewConnectionIDs()

        if keepaliveDuration != .zero {
            // Configure a keep alive timer that was set up before we were connected.
            keepaliveConfigure(duration: keepaliveDuration)
        }

        withCurrentPath { path in
            path.pmtudState.start(on: path)
        }
        configureTimeoutPostHandshake()
    }

    // Prepares flow control variables in 0-RTT and after the handshake
    func setupFlowControl(remoteTransportParameters: TransportParameters) {
        let initialRemoteMaxStreamsBidirectional = remoteTransportParameters.intValue(
            .initialMaxStreamsBidirectional
        )
        let initialRemoteMaxStreamsUnidirectional = remoteTransportParameters.intValue(
            .initialMaxStreamsUnidirectional
        )

        if initialRemoteMaxStreamsBidirectional > Constants.maxStreamLimit
            || initialRemoteMaxStreamsUnidirectional > Constants.maxStreamLimit
        {
            log.error(
                "Received too large max streams value, bidi: \(initialRemoteMaxStreamsBidirectional) uni: \(initialRemoteMaxStreamsUnidirectional)"
            )
            close(with: .transportParameterError, "initial FC over limit")
            return
        }

        let remoteMaxData = remoteTransportParameters.intValue(.initialMaxData)
        let localMaxData = localTransportParameters.intValue(.initialMaxData)

        flowControlState.initializeMaxDataValues(
            remoteMaxData: UInt64(remoteMaxData),
            localMaxData: UInt64(localMaxData)
        )

        bidirectionalStreams.updateRemoteMaxStreams(
            server: isServer,
            newMaxStreams: initialRemoteMaxStreamsBidirectional,
            logIDString: logPrefixer.logIDString
        )
        unidirectionalStreams.updateRemoteMaxStreams(
            server: isServer,
            newMaxStreams: initialRemoteMaxStreamsUnidirectional,
            logIDString: logPrefixer.logIDString
        )

        let remoteTPMaxDatagramFrameSize = remoteTransportParameters.intValue(.maxDatagramFrameSize)
        setRemoteMaxDatagramFrameSize(remoteTPMaxDatagramFrameSize)
    }

    func setRemoteMaxDatagramFrameSize(_ remoteTPMaxDatagramFrameSize: Int?) {
        defer {
            let remoteMaxDatagramFrameSize = remoteMaxDatagramFrameSize
            log.debug(
                "Remote max datagram size \(remoteMaxDatagramFrameSize)"
            )
        }
        guard let remoteTPMaxDatagramFrameSize else {
            self.remoteMaxDatagramFrameSize = 0
            return
        }
        if remoteTPMaxDatagramFrameSize > TransportParameters.maxDatagramFrameSize {
            self.remoteMaxDatagramFrameSize = Int(TransportParameters.maxDatagramFrameSize)
        } else {
            self.remoteMaxDatagramFrameSize = remoteTPMaxDatagramFrameSize
        }
    }

    private func discardKeys(keyState: PacketKeyState, discardRecoveryState: Bool = true) {
        let space = PacketNumberSpace.fromKeyState(keyState: keyState)

        // Flush first so that we won't send out frames other than ACKs with older key
        withPendingItems(for: space) { $0.flush() }

        protector.drop(keyState: keyState)

        if discardRecoveryState {
            recovery.resetPNSpace(packetNumberSpace: space, connection: self)
            withCurrentPath {
                recovery.resetPTOCount(path: $0)
            }
        }

        #if QlogOutput
        if let qLog {
            qLog.recoveryUpdated(
                ptoCount: 0,
                inRecovery: nil
            )
        }
        #endif
        ack.flush(for: space)
    }

    public func wakeup() {
        self.timer.timerFired()
    }

    func setupStreamID(isUnidirectional: Bool, isServer: Bool) -> QUICStreamID? {
        var streamID: QUICStreamID?
        withMutableQUICStreams(unidirectional: isUnidirectional) { mutableStreamsState in
            streamID = mutableStreamsState.allocateNewOutboundStreamID(
                isServer: isServer,
                logIDString: logPrefixer.logIDString,
                isUnidirectional: isUnidirectional
            )
        }
        return streamID
    }

    func deliverInboundAbortedEvent(stream: QUICStreamInstance, error: NetworkError?) {
        guard let streamID = stream.streamID,
            let _ = knownFlows[streamID]
        else {
            log.error("Cannot deliver inbound aborted event: no flow for stream \(stream.streamID?.value ?? 0)")
            return
        }
        stream.deliverInboundAbortedEvent(error: error)
    }

    func handleStreamClose(stream: QUICStreamInstance, error: NetworkError?) {
        guard let streamID = stream.streamID,
            let flowID = knownFlows[streamID]
        else {
            return
        }
        if let frameArray = stream.dequeueReassembledData(connection: self) {
            do {
                try enqueueInboundStreamData(flow: flowID, streamData: frameArray)
                try deliverEnqueuedInboundStreamData(flow: flowID)
                sendFrames()
            } catch {
                log.error("Error sending frames on stream close: \(error)")
            }
        }
        stream.closed = true
        deliverDisconnectedEvent(flow: flowID, error: error)
        knownFlows.removeValue(forKey: streamID)
        log.datapath("closed stream \(streamID.value)")

        if let streamID = stream.streamID {
            if streamID.isReceiveOnly(server: self.isServer) {
                if let maximumConcurrentUnidirectionalStreams {
                    unidirectionalStreams.decrementActiveStreams()
                    let activeUnidirectionalStreams = unidirectionalStreams.activeStreamsRemaining()

                    log.info("New active unidirectional streams: \(activeUnidirectionalStreams)")

                    let window = maximumConcurrentUnidirectionalStreams / 2
                    let withinThreshold: Bool
                    if let nextstreamID = unidirectionalStreams.nextInboundStreamID {
                        withinThreshold = unidirectionalStreams.newStreamIDsAreBlocked(
                            nextstreamID,
                            server: isServer,
                            window: window
                        )
                        if withinThreshold {
                            log.debug(
                                "Next inbound unidirectional stream is within \(window) of being blocked"
                            )
                        }
                    } else {
                        withinThreshold = false
                    }

                    if withinThreshold,
                        activeUnidirectionalStreams < maximumConcurrentUnidirectionalStreams
                    {
                        let additionalStreamsToAllow =
                            maximumConcurrentUnidirectionalStreams - activeUnidirectionalStreams
                        let originalMaxStreams = unidirectionalStreams.localMaxStreams
                        let newMaxStreams = originalMaxStreams + additionalStreamsToAllow
                        unidirectionalStreams.updateLocalMaxStreams(
                            server: self.isServer,
                            newMaxStreams: newMaxStreams,
                            logIDString: self.logPrefixer.logIDString
                        )
                        sendMaxStreamsUnidirectional()
                    }
                }
            } else if streamID.isLocalBidirectional(server: self.isServer) {
                if let maximumConcurrentBidirectionalStreams {
                    bidirectionalStreams.decrementActiveStreams()
                    let activeBidirectionalStreams = bidirectionalStreams.activeStreamsRemaining()

                    log.info("New active bidirectional streams: \(activeBidirectionalStreams)")

                    log.info(
                        "Max concurrent bidirectional streams: \(maximumConcurrentBidirectionalStreams)"
                    )

                    log.info(
                        "Local max bidirectional streams: \(bidirectionalStreams.localMaxStreams)"
                    )

                    let nextInboundStreamID = bidirectionalStreams.nextInboundStreamID?.value ?? 0
                    log.info("Next inbound bidirectional stream ID: \(nextInboundStreamID)")

                    let window = maximumConcurrentBidirectionalStreams / 2
                    let withinThreshold: Bool
                    if let nextstreamID = bidirectionalStreams.nextInboundStreamID {
                        withinThreshold = bidirectionalStreams.newStreamIDsAreBlocked(
                            nextstreamID,
                            server: isServer,
                            window: window
                        )
                        if withinThreshold {
                            log.debug(
                                "Next inbound bidirectional stream is within \(window) of being blocked"
                            )
                        }
                    } else {
                        withinThreshold = false
                    }

                    if withinThreshold,
                        activeBidirectionalStreams < maximumConcurrentBidirectionalStreams
                    {
                        let additionalStreamsToAllow =
                            maximumConcurrentBidirectionalStreams - activeBidirectionalStreams
                        let originalMaxStreams = bidirectionalStreams.localMaxStreams
                        let newMaxStreams = originalMaxStreams + additionalStreamsToAllow
                        log.info("New max bidirectional streams: \(newMaxStreams)")

                        bidirectionalStreams.updateLocalMaxStreams(
                            server: self.isServer,
                            newMaxStreams: newMaxStreams,
                            logIDString: self.logPrefixer.logIDString
                        )
                        sendMaxStreamsBidirectional()
                    }
                }
            }
        }
    }

    func streamClosedAlready(streamID: QUICStreamID) -> Bool {
        guard
            let largestOutboundStreamID = self.largestOutboundStreamID(
                isBidirectional: streamID.isBidirectional
            )
        else {
            // We never created this type of stream.
            return false
        }
        guard
            let nextInboundStreamID = self.nextInboundStreamID(
                isBidirectional: streamID.isBidirectional
            )
        else {
            log.fault("Next inbound stream id is invalid")
            self.closeError = QUICTransportError(
                .internalError,
                "inconsistent next inbound stream ID"
            )
            return false
        }
        if !QUICStreamInstance.isValid(isServer: isServer, streamID: streamID) {
            // We were unable to look up the stream ID and it's not
            // a stream ID that should have been opened by the peer.
            // Check if it's a stream that we already closed.
            if streamID.value < largestOutboundStreamID.value {
                log.info("[\(streamID)] already closed - last : \(largestOutboundStreamID.value)")
                return true
            } else {
                let peer = isServer ? "server" : "client"
                let streamIntention = isServer ? "client" : "server"
                log.error(
                    "Peer (\(peer) trying to open \(streamIntention) stream - last : \(largestOutboundStreamID.value)"
                )
                self.closeError = QUICTransportError(.streamStateError, "invalid stream ID")
                return false
            }
        }
        if self.streamIDBlocked(streamID: streamID) {
            log.error("Stream ID \(streamID.value) exceeded the maximum allowed")
            self.closeError = QUICTransportError(.streamLimitError, "exceeded maximum stream ID")
            return false
        }
        // Check if the stream is already closed.  If we got here, it was
        // because the lookup failed.  Don't re-create streams that are
        // already closed.
        if streamID.value < nextInboundStreamID.value {
            log.info("Not recreating closed stream \(streamID.value)")
            return true
        } else {
            return false
        }
    }

    func zombieStreamListFinalSizeReceived(streamID: QUICStreamID, finalSize: UInt64) {
        self.zombieStreamList.finalSizeReceived(
            logIDString: logPrefixer.logIDString,
            streamID: streamID,
            finalSize: finalSize,
            connection: self
        )
    }
}

// MARK: Flow Control - Inbound Frame Processing

@available(Network 0.1.0, *)
extension QUICConnection {

    // Process an incoming NEW_TOKEN frame
    func processNewTokenFrame(_ frame: consuming FrameNewToken) -> Bool {
        Logger.proto.info("Received NEW_TOKEN frame")

        // Clients MUST NOT send NEW_TOKEN frames. A server MUST treat receipt of a
        // NEW_TOKEN frame as a connection error of type PROTOCOL_VIOLATION.
        guard !isServer else {
            close(with: .protocolViolation, "Client sent NEW_TOKEN frame")
            return false
        }
        guard frame.token.count > 0 else {
            log.error("NEW_TOKEN frame received with invalid token size \(frame.token.count)")
            return false
        }
        // In the future we need to deliver NEW_TOKEN to client application layer for usage in later connections
        // For now set just set the field locally
        self.newToken = frame.token
        return true
    }

    // Process an incoming STREAM frame
    func processStreamFrame(_ frame: consuming FrameStreamReceived) -> Bool {
        log.datapath(
            "received STREAM frame with id: \(frame.id), offset: \(frame.offset) data length: \(frame.length)"
        )
        guard let streamID = QUICStreamID(frame.id) else {
            log.error("Stream frame with invalid stream ID \(frame.id)")
            frame.frame.finalize(success: true)
            return false
        }

        /*
         * An endpoint that receives a STREAM frame for a send-only stream MUST
         * terminate the connection with error STREAM_STATE_ERROR.
         */
        if streamID.isSendOnly(server: isServer) {
            log.error(
                "STREAM frame received for send-only stream \(streamID)"
            )
            close(with: .streamStateError, "STREAM frame on send-only stream")
            frame.frame.finalize(success: true)
            return false
        }

        let knownFlowID = knownFlows[streamID]
        if knownFlowID == nil {
            let inboundStreamResult = createInboundStreams(streamID: streamID)
            if frame.isFinal && inboundStreamResult.checkZombie {
                zombieStreamList.finalSizeReceived(
                    logIDString: logPrefixer.logIDString,
                    streamID: streamID,
                    finalSize: frame.offset + UInt64(frame.length),
                    connection: self
                )
                frame.frame.finalize(success: true)
                return true
            }
            if !inboundStreamResult.created {
                frame.frame.finalize(success: true)
                return false
            }
        }
        guard let flowID = knownFlowID ?? knownFlows[streamID] else {
            frame.frame.finalize(success: true)
            return true
        }
        guard let stream = flow(for: flowID) else {
            log.error("Cannot look up stream for flowID \(flowID.debugDescription)")
            frame.frame.finalize(success: true)
            return true
        }

        if frame.length > 0 || frame.isFinal {
            return stream.processIncomingStream(connection: self, frame: frame)
        } else {
            stream.log.datapath(
                "unable to handle frame len \(frame.length) offset \(frame.offset) fin \(frame.isFinal) on stream"
            )
            frame.frame.finalize(success: true)
            return true
        }
    }

    // Process incoming CRYPTO frame
    func processCryptoFrame(
        _ frame: consuming FrameCrypto,
        packetNumberSpace: PacketNumberSpace
    ) -> Bool {
        // 7.4.  Cryptographic Message Buffering
        // Once the handshake completes, if an endpoint is unable to
        // buffer all data in a CRYPTO frame, it MAY discard that CRYPTO
        // frame and all CRYPTO frames received in the future, or it MAY
        // close the connection with an CRYPTO_BUFFER_EXCEEDED error
        // code.
        if discardCryptoFrames {
            log.info(
                "Discarded one crypto frame in the crypto PN space \(packetNumberSpace)"
            )
            frame.frame.finalize(success: false)
            return false
        }
        guard
            crypto.appendInput(frame, for: packetNumberSpace)
        else {
            if packetNumberSpace == .handshake {
                close(with: .cryptoBufferExceeded, "exceeded crypto buffer")
                return false
            } else {
                discardCryptoFrames = true
                return true
            }
        }
        return true
    }

    // Handle incoming maxData frame and update the remoteMaxData if needed
    func processMaxDataFrame(_ frame: consuming FrameMaxData) -> Bool {
        let newRemoteMaxData = frame.max
        let oldRemoteMaxData = flowControlState.outboundMaxData
        guard updateOutboundMaxData(to: frame.max) else {
            return false
        }

        log.datapath("MAX_DATA was \(oldRemoteMaxData), is now \(newRemoteMaxData)")

        if flowControlState.outboundMaxData < self.sendOffset {
            close(with: .internalError, "connection remoteMaxData < inOrderOffset")
            return false
        }

        log.datapath("connection has received more credit")
        if hasSentDataBlocked {
            log.datapath("unblocked")
            applicationPendingItems.triggerAllStreamsUnblocked = true
            hasSentDataBlocked = false
        }
        return true
    }

    // Handle incoming maxStreamData frame and update the remoteMaxStreamData if needed
    func processMaxStreamDataFrame(_ frame: consuming FrameMaxStreamData) -> Bool {
        log.datapath("process MAX_STREAM_DATA")

        // 1. check streamID against the protocol streamID
        //    - if is recv only, close STREAM_STATE_ERROR
        let streamID = QUICStreamID(frame.id)
        guard let streamID else {
            close(with: .streamStateError, "Invalid stream ID")
            return false
        }
        /*
         * An endpoint that receives a MAX_STREAM_DATA frame for a receive-only
         * stream MUST terminate the connection with error STREAM_STATE_ERROR
         */
        if streamID.isReceiveOnly(server: self.isServer) {
            log.error(
                "Received MAX_STREAM_DATA for receive-only stream [S\(streamID.value)]"
            )
            close(with: .streamStateError, "MAX_STREAM_DATA for receive-only stream")
            return false
        }

        // 2. Lookup stream
        let knownFlowID = knownFlows[streamID]

        // 3. If new stream
        if knownFlowID == nil {
            if streamID.isSendOnly(server: isServer) {
                // client is sending an update for a stream we haven't (yet) opened
                // close with STREAM_STATE_ERROR
                close(with: .streamStateError, "MAX_STREAM_DATA for stream we haven't opened")
                return false
            }
            // 4. create new stream
            let inboundStreamResult = createInboundStreams(streamID: streamID)
            if inboundStreamResult.checkZombie {
                return true
            } else if !inboundStreamResult.created {
                return false
            }
        }
        // Only act on MAX_STREAM_DATA for a flow that is already set in knownFlows
        guard let flowID = knownFlowID else {
            log.error(
                "MAX_STREAM_DATA for unknown stream [S\(streamID.value)] is not yet supported"
            )
            return false
        }

        // 4. Find stream
        guard let stream = flow(for: flowID) else {
            log.error(
                "MAX_STREAM_DATA for client state on flow \(flowID.debugDescription) and [S\(streamID.value)] is not a QUICStreamInstance"
            )
            return true
        }

        // 5. process max stream data
        stream.processIncomingMaxStreamData(remoteMaxStreamData: frame.max)
        if !stream.listMembership.contains(.unblockedSend), !stream.pendingStart {
            applicationPendingItems.unblockedSendStreams.append(stream)
        }
        return true
    }

    // Handle incoming data blocked frame and notify application protocol if needed
    func processDataBlocked(frame: consuming FrameDataBlocked) -> Bool {
        log.info(
            "Received DATA_BLOCKED (max=\(frame.limit)), previous max data:  \(flowControlState.inboundMaxData)"
        )
        sendInboundFlowControlCredit()
        return true
    }

    // Handle incoming stream data blocked frame and notify application protocol if needed
    func processStreamDataBlocked(frame: consuming FrameStreamDataBlocked) -> Bool {
        guard let stream = streamFromStreamID(frame.id) else {
            log.datapath("invalid streamID: \(frame.id)")
            return false
        }
        guard !stream.streamID!.isSendOnly(server: isServer) else {
            log.error("[S\(frame.id)] received STREAM_DATA_BLOCKED on a send-only stream")
            return false
        }

        stream.log.info(
            "Received STREAM_DATA_BLOCKED (max=\(frame.limit)), previous max stream data:  \(stream.flowControlState.inboundMaxData)"
        )

        stream.sendInboundFlowControlCreditForStreamDataBlocked(connection: self)

        return true
    }

    func processMaxStreams(
        maxStreams: UInt64,
        unidirectional: Bool
    ) -> Bool {
        if maxStreams > Constants.maxStreamLimit {
            close(with: .streamLimitError, "MAX_STREAMS value over limit")
            log.error("Received MAX_STREAMS value too large: \(maxStreams)")
            return false
        }
        if unidirectional {
            if self.unidirectionalStreams.remoteMaxStreams >= maxStreams {
                log.notice(
                    "New MAX_STREAMS_UNI \(maxStreams) doesn't advance current limit \(self.unidirectionalStreams.remoteMaxStreams)"
                )
                return true
            }
            log.notice("Unidirectional max streams now \(maxStreams)")
            self.unidirectionalStreams.remoteMaxStreams = Int(maxStreams)
            self.unidirectionalStreams.updateRemoteMaxStreams(
                server: self.isServer,
                newMaxStreams: Int(maxStreams),
                logIDString: self.logPrefixer.logIDString
            )
        } else {
            if self.bidirectionalStreams.remoteMaxStreams >= maxStreams {
                log.notice(
                    "New MAX_STREAMS_BIDI \(maxStreams) doesn't advance current limit \(self.bidirectionalStreams.remoteMaxStreams)"
                )
                return true
            }
            log.notice("Bidirectional max streams now \(maxStreams)")
            self.bidirectionalStreams.remoteMaxStreams = Int(maxStreams)
            self.bidirectionalStreams.updateRemoteMaxStreams(
                server: self.isServer,
                newMaxStreams: Int(maxStreams),
                logIDString: self.logPrefixer.logIDString
            )
        }
        // NOTE: readyPendingStream will remove them from the pending streams list
        var pendingStreams: [QUICStreamInstance] = []
        withMutableQUICStreams(unidirectional: unidirectional) { mutableStreamsState in
            for stream in mutableStreamsState.pendingStartStreams {
                pendingStreams.append(stream)
            }
        }
        for stream in pendingStreams {
            guard self.readyPendingStream(stream, flowID: stream.identifier) else {
                continue
            }
            let streamType: QUICStreamType = unidirectional ? .unidirectional : .bidirectional
            // To inform QUICStreamMetadata
            stream.streamMetadata.streamID = stream.streamID?.value ?? 0  // Default for QUICStreamMetadata is 0
            stream.streamMetadata.streamType = streamType
            var event = QUICEvent.maxStreamsLimitBidirectionalUpdated(
                maximumStreams: Int(maxStreams)
            )
            if streamType == .unidirectional {
                event = .maxStreamsLimitUnidirectionalUpdated(maximumStreams: Int(maxStreams))
            }
            deliverNetworkProtocolEvent(flow: .allFlows, event: .init(quicEvent: event))
        }
        return true
    }

    // Handle the incoming maxStreamsBidirectional and update remoteMaxStreams if needed
    func processMaxStreamsBidirectionalFrame(
        _ frame: consuming FrameMaxStreamsBidirectional
    ) -> Bool {
        processMaxStreams(
            maxStreams: frame.max,
            unidirectional: false
        )
    }

    // Handle the incoming maxStreamsUnidirectional and update remoteMaxStreams if needed
    func processMaxStreamsUnidirectionalFrame(
        _ frame: consuming FrameMaxStreamsUnidirectional
    ) -> Bool {
        processMaxStreams(
            maxStreams: frame.max,
            unidirectional: true
        )
    }

    func processStreamsBlockedBidirectionalFrame(
        _ frame: consuming FrameStreamsBlockedBidirectional
    ) -> Bool {
        if frame.limit > Constants.maxStreamLimit {
            // Receipt of a frame that encodes a larger stream ID MUST be treated
            // as a connection error of type STREAM_LIMIT_ERROR or FRAME_ENCODING_ERROR.
            close(with: .streamLimitError, "STREAMS_BLOCKED_BIDI exceeds 2**60")
            return false
        }
        log.notice("Streams blocked bidi: \(frame.limit)")
        deliverNetworkProtocolEvent(
            flow: .allFlows,
            event: .init(
                quicEvent: .remoteBidirectionalStreamsBlocked(
                    maximumStreams: Int(exactly: frame.limit) ?? 0
                )
            )
        )
        return true
    }

    func processStreamsBlockedUnidirectionalFrame(
        _ frame: consuming FrameStreamsBlockedUnidirectional
    ) -> Bool {
        if frame.limit > Constants.maxStreamLimit {
            // Receipt of a frame that encodes a larger stream ID MUST be treated
            // as a connection error of type STREAM_LIMIT_ERROR or FRAME_ENCODING_ERROR.
            close(with: .streamLimitError, "STREAMS_BLOCKED_UNI exceeds 2**60")
            return false
        }
        log.notice("Streams blocked uni: \(frame.limit)")
        deliverNetworkProtocolEvent(
            flow: .allFlows,
            event: .init(
                quicEvent: .remoteUnidirectionalStreamsBlocked(
                    maximumStreams: Int(exactly: frame.limit) ?? 0
                )
            )
        )
        return true
    }

    func processAckFrame(
        _ frame: FrameAck,
        packetNumberSpace: PacketNumberSpace,
        path: QUICPath
    ) -> Bool {
        // The loss recovery module only keeps track of ACK-eliciting packets,
        // so we can't query it for the largest packet number sent.
        //
        // We query the packet protector module for the next packet number
        // that we expect to use and compare that with the ACK largest value
        // that we just received.
        // If the largest_sent is zero, it means we never sent anything on this
        // PN space.  If it isn't, it must be at least one more than what we
        // received ack_largest.
        //
        // In theory, we could have gaps of packet numbers, but the current
        // implementation doesn't do that, so in practice that isn't a concern.
        // Even if this check fails, we'll simply try to find a packet number
        // that doesn't exist, but we won't close the connection.
        let largestSent = self.protector.getPacketNumber(for: packetNumberSpace)
        if largestSent == 0 || frame.largest > largestSent - 1 {
            close(with: .protocolViolation, "ACK for a packet that was not sent")
            return false
        }

        recovery.receivedAck(
            ack: frame,
            ackedPath: path,
            connection: self
        )

        // Check if we need to send probes
        let sentPackets = path.pmtudState.tryToSend(on: path)
        recovery.recordSentPackets(sentPackets, connection: self)
        return true
    }

    func processApplicationCloseFrame(_ frame: consuming FrameApplicationClose) -> Bool {
        if frame.errorCode != 0 {
            self.applicationCloseError = QUICApplicationError(frame.errorCode, frame.reason)
            receivedApplicationClose = true
        }
        close()
        return true
    }

    func processConnectionCloseFrame(_ frame: consuming FrameConnectionClose) -> Bool {
        if frame.errorCode != 0 {
            self.closeError = QUICTransportError(frame.errorCode, frame.reason)
            receivedConnectionClose = true
        }
        close()
        return true
    }
}

// MARK: Flow Control - Outbound Frame Processing

@available(Network 0.1.0, *)
extension QUICConnection {

    // Prepare and send maxStreamsBidirectional
    func sendMaxStreamsBidirectional() {
        withPendingItems(for: .applicationData) { $0.maxStreamsBidirectional = true }
    }

    // Prepare and send maxStreamsUnidirectional
    func sendMaxStreamsUnidirectional() {
        withPendingItems(for: .applicationData) { $0.maxStreamsUnidirectional = true }
    }

    // Prepare and send streamsBlockedBidirectional
    func sendStreamsBlockedBidirectional() {
        withPendingItems(for: .applicationData) { $0.streamsBlockedBidirectional = true }
    }

    // Prepare and send streamsBlockedUnidirectional
    func sendStreamsBlockedUnidirectional() {
        withPendingItems(for: .applicationData) { $0.streamsBlockedUnidirectional = true }
    }

    private func sendStopSending(stream: QUICStreamInstance) {
        guard let streamID = stream.streamID else {
            log.notice("Cannot send STOP_SENDING without stream ID")
            return
        }
        // Note: Error can be 0 for stop sending; still send the frame
        var errorCode: UInt64 = 0
        if let applicationErrorCode = stream.inboundApplicationError {
            errorCode = applicationErrorCode
        }
        stream.log.notice("Sending STOP_SENDING, error: \(errorCode)")
        applicationPendingItems.addStreamStopSending(streamID: streamID.value, code: errorCode)
    }

    // Mark stream FIN and trigger servicing
    private func markStreamFinished(stream: QUICStreamInstance) {
        stream.sendBuffer.markStreamFinished()
        applicationPendingItems.appendStreamToService(stream)
    }

    private func sendResetStream(stream: QUICStreamInstance) {
        guard let streamID = stream.streamID else {
            log.notice("Cannot send RESET_STREAM without stream ID")
            return
        }

        var errorCode: UInt64 = 0
        if let applicationErrorCode = stream.outboundApplicationError {
            errorCode = applicationErrorCode
        }

        // sendOffset represents the offset of the next
        // byte that we would write, so we use that for
        // RESET_STREAM's Final Size.
        applicationPendingItems.addStreamReset(
            streamID: streamID.value,
            code: errorCode,
            finalSize: stream.sendOffset
        )
        stream.log.notice("Sending RESET_STREAM, error: \(errorCode)")
        stream.resetSent = true
        stream.sendState.change(logIDString: stream.logPrefix, to: .resetSent)
    }

    private func sendConnectionClose(packetNumberSpace: PacketNumberSpace) {
        withPendingItems(for: packetNumberSpace) { $0.connectionClose = true }
    }

    var connectionCloseErrorToSend: (QUICTransportError, FrameType?) {
        if connectionMetadata.applicationError != UInt64.max,
            let error = QUICTransportError(
                connectionMetadata.applicationError,
                connectionMetadata.applicationErrorReason
            )
        {
            return (
                error,
                closeFrameType
            )
        }
        guard let closeError else {
            // An endpoint sends a CONNECTION_CLOSE frame (type=0x1c or 0x1d) to notify its peer that the connection is being closed.
            // The CONNECTION_CLOSE frame with a type of 0x1c is used to signal errors at only the QUIC layer, or the absence of errors (with the NO_ERROR code).
            return (QUICTransportError(.noError), closeFrameType)
        }
        return (closeError, closeFrameType)
    }

    private func sendApplicationClose() {
        if self.receivedApplicationClose {
            return
        }
        withPendingItemsForKeyState { $0.applicationClose = true }
    }

    var applicationCloseErrorToSend: QUICApplicationError? {
        if connectionMetadata.applicationError != UInt64.max,
            let errorCode = Int64(exactly: connectionMetadata.applicationError)
        {
            return QUICApplicationError(
                errorCode,
                connectionMetadata.applicationErrorReason
            )
        }
        guard let applicationCloseError else {
            return nil
        }
        return applicationCloseError
    }

    func sendVersionNegotiation(packet: borrowing Packet, path: QUICPath) {
        guard let initialVersion = self.initialVersion else {
            log.error("Failed to send version negotiation due to a missing initial version")
            return
        }
        guard let scid = packet.sourceConnectionID,
            let dcid = packet.destinationConnectionID
        else {
            log.error("Failed to parse dcid / scid values from packet")
            return
        }
        let supportedVersions: [QUICVersion] = [initialVersion, .negotiationPattern]

        // Version Negotiation packets are special, they are not a specific frame type and they do not sealed so they can be sent as a one-off.
        // N.B.: The packet scid/dcid are swapped when constructing QUICVersionNegotiation
        guard
            let versionNegotiation = try? QUICVersionNegotiation(
                destinationConnectionID: scid,
                sourceConnectionID: dcid,
                supportedVersions: supportedVersions
            )
        else {
            log.error("Failed to create QUICVersionNegotiation")
            return
        }

        let requestedFrameLength = versionNegotiation.header.count
        guard
            var outFrames = try? getDatagramsToSend(
                path: path.identifier,
                maximumDatagramCount: 1,
                minimumDatagramSize: requestedFrameLength
            ),
            var outFrame = outFrames.popFirst()
        else {
            log.debug("QUIC path failed to get a frame")
            return
        }

        let frameLength = outFrame.unclaimedLength
        guard frameLength >= requestedFrameLength else {
            log.error("Invalid frame length")
            outFrame.finalize(success: false)
            return
        }
        if frameLength > requestedFrameLength {
            _ = outFrame.collapse(to: requestedFrameLength)
        }

        guard let _ = try? versionNegotiation.write(outputFrame: &outFrame, claim: false) else {
            log.error("Failed to write version negotiation frame")
            outFrame.finalize(success: false)
            return
        }

        do throws(NetworkError) {
            try self.enqueueOutboundDatagrams(
                path: path.identifier,
                datagrams: .init(frame: outFrame)
            )
            try self.sendEnqueuedOutboundDatagrams(path: path.identifier)
        } catch {
            log.error("Failed to send version negotiation frame with error: \(error)")
            return
        }
        log.info("Sent version negotiation packet")
    }

    func sendRetry(path: QUICPath, packet: borrowing Packet) {

        guard let packetSCID = packet.sourceConnectionID,
            let packetDCID = packet.destinationConnectionID
        else {
            log.error("Failed to parse CIDs from packet")
            return
        }
        guard let version = packet.version
        else {
            log.error("Failed to parse version value from packet")
            return
        }
        guard let scid = path.scid
        else {
            log.error("Failed to path dcid value from path")
            return
        }
        guard let _token = initialToken
        else {
            log.error("Failed to obtain token for retry")
            return
        }
        guard
            let retryPacket = try? QUICRetryPacket(
                version: version,
                destinationConnectionID: packetSCID,
                sourceConnectionID: scid,
                originalDCID: packetDCID,
                token: _token
            )
        else {
            log.error("Failed to create QUICRetryPacket")
            return
        }
        let requestedFrameLength = retryPacket.header.count
        guard
            var outFrames = try? getDatagramsToSend(
                path: path.identifier,
                maximumDatagramCount: 1,
                minimumDatagramSize: requestedFrameLength
            ),
            var outFrame = outFrames.popFirst()
        else {
            log.debug("QUIC path failed to get a frame")
            return
        }
        let frameLength = outFrame.unclaimedLength
        guard frameLength >= requestedFrameLength else {
            log.error("Invalid frame length")
            outFrame.finalize(success: false)
            return
        }
        if frameLength > requestedFrameLength {
            _ = outFrame.collapse(to: requestedFrameLength)
        }
        guard let _ = try? retryPacket.write(outputFrame: &outFrame, claim: false) else {
            log.error("Failed to write retry frame")
            outFrame.finalize(success: false)
            return
        }
        do throws(NetworkError) {
            try self.enqueueOutboundDatagrams(
                path: path.identifier,
                datagrams: .init(frame: outFrame)
            )
            try self.sendEnqueuedOutboundDatagrams(path: path.identifier)
        } catch {
            log.error("Failed to send retry frame with error: \(error)")
            return
        }
        log.info("Sent retry packet")
    }
}

// MARK: Flow Control - Stream

@available(Network 0.1.0, *)
extension QUICConnection {
    func withMutableQUICStreams(unidirectional: Bool, closure: (inout QUICStreamIDState) -> Void) {
        if unidirectional {
            closure(&unidirectionalStreams)
        } else {
            closure(&bidirectionalStreams)
        }
    }

    func readyPendingStream(
        _ stream: QUICStreamInstance,
        flowID: MultiplexedFlowIdentifier
    ) -> Bool {

        let streamID = setupStreamID(
            isUnidirectional: stream.unidirectional,
            isServer: isServer
        )
        guard let streamID else {
            log.error("Out of streamIDs")
            return false
        }
        stream.resetStreamID(streamID: streamID)

        log.debug("Updating flow \(flowID.debugDescription) for key \(streamID)")

        knownFlows[streamID] = flowID
        if !stream.unidirectional {
            self.bidirectionalStreams.incrementActiveStreams()
            stream.receiveState.change(logIDString: stream.logPrefix, to: .receive)
        } else {
            self.unidirectionalStreams.incrementActiveStreams()
        }
        stream.sendState.change(logIDString: stream.logPrefix, to: .ready)
        startOutboundStream(stream: stream, for: flowID)
        // Deliver the connected event for the newly start flow
        deliverConnectedEvent(flow: flowID)
        return true
    }

    // This function should only be called when the connection is ready,
    // or we are sending early data
    func readyAllOutboundStreams() {
        applyToAllFlows { stream in
            let flowID = stream.identifier
            if stream.sendState == .invalid && stream.receiveState == .invalid {
                if !readyPendingStream(stream, flowID: flowID) {
                    log.error("Could not ready pending stream")
                }
            } else {
                guard stream.streamID != nil else {
                    stream.log.error(
                        "Stream for flow \(flowID) has no streamID"
                    )
                    return
                }
                startOutboundStream(stream: stream, for: flowID)
            }
        }
    }

    func startOutboundStream(
        stream: QUICStreamInstance,
        for flowID: MultiplexedFlowIdentifier
    ) {
        precondition(stream.streamID != nil)
        stream.setupMaxStreamData(
            isServer: isServer,
            remoteTransportParameters: remoteTransportParameters,
            localTransportParameters: localTransportParameters
        )

        if stream.sendState == .ready {
            if stream.unidirectional {
                self.unidirectionalStreams.removePending(stream)
            } else {
                self.bidirectionalStreams.removePending(stream)
            }
        }

        // Add any data necessary to the send queue
        serviceStreamDataToSend(flow: flowID)

        // Kick off send for data in send queue
        applicationPendingItems.appendStreamToService(stream)
    }

    // When the burst limit has been reached for application data, we schedule
    // async work on the stack thread/queue to continue sending on another stream
    // after other operations have had a chance to run (such as receive incoming
    // data, handleInbound() path).
    fileprivate func burstLimitReached() {
        guard !asyncSendRunning else {
            return
        }
        asyncSendRunning = true
        log.datapath("async: scheduling restart after packet burst")
        self.context.async {
            self.resumeSendingAfterBurstLimit()
        }
    }

    fileprivate func resumeSendingAfterBurstLimit() {
        log.datapath("async: resuming sending packets")
        asyncSendRunning = false
        sendFrames()
    }
}

// MARK: Inbound stream creation

@available(Network 0.1.0, *)
extension QUICConnection {

    // Support QUICStreamIDState being ~Copyable
    func checkInboundStreamID(
        _ streamID: QUICStreamID,
        server: Bool
    )
        -> (valid: Bool, checkZombie: Bool)
    {
        if streamID.isBidirectional {
            return bidirectionalStreams.checkInboundStreamID(
                streamID,
                server: server,
                connection: self
            )
        } else {
            return unidirectionalStreams.checkInboundStreamID(
                streamID,
                server: server,
                connection: self
            )
        }
    }

    // Support QUICStreamIDState being ~Copyable
    func nextInboundStreamID(isBidirectional: Bool) -> QUICStreamID? {
        isBidirectional
            ? bidirectionalStreams.nextInboundStreamID
            : unidirectionalStreams.nextInboundStreamID
    }

    // Support QUICStreamIDState being ~Copyable
    func largestOutboundStreamID(isBidirectional: Bool) -> QUICStreamID? {
        isBidirectional
            ? bidirectionalStreams.largestOutboundStreamID
            : unidirectionalStreams.largestOutboundStreamID
    }

    func streamIDBlocked(streamID: QUICStreamID) -> Bool {
        streamID.isBidirectional
            ? bidirectionalStreams.newStreamIDsAreBlocked(streamID)
            : unidirectionalStreams.newStreamIDsAreBlocked(streamID)
    }

    // Creates a stream based on receipt of
    // STREAM/MAX_STREAM_DATA/STOP_SENDING/RESET_STREAM/STREAM_DATA_BLOCKED.
    func createInboundStreams(streamID: QUICStreamID) -> (created: Bool, checkZombie: Bool) {
        let streamIDCheck = self.checkInboundStreamID(streamID, server: isServer)

        if self.closeError != nil {
            return (created: false, checkZombie: false)
        }

        guard streamIDCheck.valid else {
            // Nothing to do, except maybe check the zombies
            return (created: false, checkZombie: streamIDCheck.checkZombie)
        }
        // If the next stream ID does not exist we likely
        // encountered packet loss or reordering and we need to
        // create all the missing streams.
        guard
            let nextInboundStreamID = self.nextInboundStreamID(
                isBidirectional: streamID.isBidirectional
            )
        else {
            Logger.proto.error("Next inbound stream id is not valid")
            return (created: false, checkZombie: streamIDCheck.checkZombie)
        }

        guard !inboundFlowLinkage.isDetached else {
            log.error(
                "No inbound flow handler, cannot accept stream ID \(streamID)"
            )
            // Send STOP_SENDING (and RESET_STREAM for bidirectional streams)
            // so the peer knows we are refusing this stream.
            applicationPendingItems.addStreamStopSending(
                streamID: streamID.value,
                code: 0
            )
            if streamID.isBidirectional {
                applicationPendingItems.addStreamReset(
                    streamID: streamID.value,
                    code: 0,
                    finalSize: 0
                )
            }
            return (created: false, checkZombie: false)
        }

        // Next inbound stream is NOT yet created, but we expect all previous to be found before
        // getting here
        if streamID < nextInboundStreamID {
            // This streamID should've already been created and found previously.
            // This must be stale / lost data from an already closed stream
            return (created: false, checkZombie: false)
        }

        log.datapath("creating missing streams from \(streamID) to \(nextInboundStreamID)")

        if self.streamIDBlocked(streamID: streamID) {
            log.error(
                "Stream ID \(streamID) exceeded the maximum allowed"
            )
            close(with: .streamLimitError, "exceeded maximum stream ID")
            return (created: false, checkZombie: false)
        }

        // Note that this loop is bounded by valid streamIDs because both from: and through: are valid stream IDs
        for newStreamID in stride(
            from: nextInboundStreamID,
            through: streamID,
            by: QUICStreamID.strideLengthToNextOfSameTypeAndInitiator
        ) {
            // create all the missing streams and flows. All will be left invalid until payload or application
            // triggers a transition to active
            let newStream = QUICStreamInstance(parent: self, inbound: true)
            newStream.streamMetadata.quicConnectionMetadata = self.connectionMetadata

            let newFlowIdentifier = newStream.identifier
            multiplexedFlows[newFlowIdentifier] = newStream

            knownFlows[newStreamID] = newFlowIdentifier
            newStream.setup(
                streamID: newStreamID,
                logPrefixer: logPrefixer
            )
            newStream.unidirectional = newStreamID.isUnidirectional

            let abstractMetadata: AbstractProtocolMetadata = ProtocolMetadata<QUICStreamProtocol>(
                protocolIdentifier: QUICStreamProtocol.identifier,
                perProtocolMetadata: newStream.streamMetadata,
                messageIdentifier: SystemUUID(insecure: true)
            )
            deliverNewInboundFlowEvent(newStream.reference, flowMetadata: abstractMetadata)

            log.debug(
                "Set stream \(newStreamID.description) for flow \(newFlowIdentifier.debugDescription)"
            )

            newStream.setupMaxStreamData(
                isServer: isServer,
                remoteTransportParameters: remoteTransportParameters,
                localTransportParameters: localTransportParameters
            )

            newStream.inboundStreamReady()

            if streamID.isBidirectional {
                stats.increment(.inboundBidirectionalStreams)
            } else {
                stats.increment(.inboundUnidirectionalStreams)
            }
            if newStreamID == streamID {
                log.info("Creating inbound stream \(streamID)")
            } else {
                log.info("Creating inbound stream \(newStreamID) (out of order)")
            }
        }  // for newStreamID in stride

        // For now, at least protect from the overflow and add log to be able to diagnose this situation.
        guard let theNextStreamID = streamID.nextOfSameTypeAndInitiator() else {
            log.error("Inbound streams created, but out of future stream credits")
            // We've succeeded in creating the streams above, so return success.
            return (created: true, checkZombie: false)
        }
        if streamID.isBidirectional {
            self.bidirectionalStreams.nextInboundStreamID = theNextStreamID
            self.bidirectionalStreams.incrementActiveStreams()
        } else {
            self.unidirectionalStreams.nextInboundStreamID = theNextStreamID
            self.unidirectionalStreams.incrementActiveStreams()
        }
        return (created: true, checkZombie: false)
    }
}

// MARK: Datagram flow handling

@available(Network 0.1.0, *)
extension QUICConnection {
    // Handle new outbound datagrams being available.
    public func serviceDatagramsToSend(flow flowID: MultiplexedFlowIdentifier) {
        guard secondaryFlow(for: flowID) != nil else {
            log.error("Unable to find datagram flow \(flowID)")
            return
        }

        withPendingItems(for: .applicationData) {
            $0.prependDatagramFlowToService(flowID)
        }

        // Note: trigger sendFrames() based on this external event
        checkConnectionIdle()
        if !sendFrames() {
            log.datapath("failed to send DATAGRAM frames")
        }
    }

    func setupNewDatagramFlow(
        _ flow: QUICDatagramFlow,
        with streamOptions: QUICStreamProtocol.Options
    ) {
        let datagramFlowID: UInt64?
        if datagramEnableFlowID, let associatedStreamID = streamOptions.associatedStreamID,
            datagramUseQuarterStreamID
        {
            datagramFlowID = QUICDatagramFlow.generateFlowID(from: associatedStreamID)
        } else {
            datagramFlowID = nil
        }

        flow.setup(
            datagramFlowID: datagramFlowID,
            contextID: datagramUseContextID ? streamOptions.datagramContextID : nil,
            logPrefixer: logPrefixer
        )

        flow.log.debug(
            "Created outbound datagram flow for \(flow.identifier.debugDescription)"
        )

        withCurrentPath { path in
            flow.updateUsableDatagramFrameSize(connection: self, path: path)
        }
    }

    func processDatagramFrame(_ frame: consuming FrameDatagram) -> Bool {
        if let datagramFlowID = frame.flowID, let contextID = frame.contextID {
            log.datapath(
                "received DATAGRAM frame with length: \(frame.length), flow: \(datagramFlowID), context: \(contextID)"
            )
        } else if let datagramFlowID = frame.flowID {
            log.datapath(
                "received DATAGRAM frame with length: \(frame.length), flow: \(datagramFlowID)"
            )
        } else if let contextID = frame.contextID {
            log.datapath(
                "received DATAGRAM frame with length: \(frame.length), context: \(contextID)"
            )
        } else {
            log.datapath("received DATAGRAM frame with length: \(frame.length)")
        }

        var matchingFlowIdentifier = findSecondaryFlow(where: { candidateFlow in
            guard candidateFlow.contextID == frame.contextID,
                candidateFlow.flowID == frame.flowID
            else {
                return false
            }

            return true
        })

        if matchingFlowIdentifier == nil {
            let newFlow = QUICDatagramFlow(parent: self, inbound: true)
            let newFlowIdentifier = newFlow.identifier
            newFlow.setup(
                datagramFlowID: frame.flowID,
                contextID: frame.contextID,
                logPrefixer: logPrefixer
            )
            multiplexedSecondaryFlows[newFlowIdentifier] = newFlow
            deliverNewInboundSecondaryFlowEvent(newFlow.reference)

            newFlow.log.debug("Created inbound datagram flow for \(newFlowIdentifier)")

            withCurrentPath { path in
                newFlow.updateUsableDatagramFrameSize(connection: self, path: path)
            }

            matchingFlowIdentifier = newFlowIdentifier
        }

        guard let matchingFlowIdentifier else {
            log.error("Failed to get matching datagram flow identifier")
            frame.frame.finalize(success: false)
            return false
        }

        var frame = frame.frame
        frame.metadataComplete = true
        try? enqueueInboundDatagrams(flow: matchingFlowIdentifier, datagrams: .init(frame: frame))
        try? deliverEnqueuedInboundDatagrams(flow: matchingFlowIdentifier)
        return true
    }
}

// MARK: Frame Processing helpers

@available(Network 0.1.0, *)
extension QUICConnection {
    func processFrame(
        _ frame: consuming QUICFrame,
        packetNumberSpace: PacketNumberSpace,
        path: QUICPath
    ) -> Bool {
        let type = frame.frameType
        switch type {
        case .padding:
            guard case .padding(let frame) = frame else { return false }
            return frame.process()
        case .ping:
            guard case .ping(let frame) = frame else { return false }
            return frame.process()
        case .ack, .ackECN:
            guard case .ack(let frame) = frame else { return false }
            return processAckFrame(frame, packetNumberSpace: packetNumberSpace, path: path)
        case .resetStream:
            guard case .resetStream(let frame) = frame else { return false }
            return frame.process(connection: self)
        case .stopSending:
            guard case .stopSending(let frame) = frame else { return false }
            return frame.process(connection: self)
        case .crypto:
            guard case .crypto(let frame) = frame else { return false }
            return processCryptoFrame(frame, packetNumberSpace: packetNumberSpace)
        case .newToken:
            guard case .newToken(let frame) = frame else { return false }
            return processNewTokenFrame(frame)
        case .stream:
            guard case .stream(let frame) = frame else { return false }
            return processStreamFrame(frame)
        case .maxData:
            guard case .maxData(let frame) = frame else { return false }
            return processMaxDataFrame(frame)
        case .maxStreamData:
            guard case .maxStreamData(let frame) = frame else { return false }
            return processMaxStreamDataFrame(frame)
        case .maxStreamsBidirectional:
            guard case .maxStreamsBidirectional(let frame) = frame else { return false }
            return processMaxStreamsBidirectionalFrame(frame)
        case .maxStreamsUnidirectional:
            guard case .maxStreamsUnidirectional(let frame) = frame else { return false }
            return processMaxStreamsUnidirectionalFrame(frame)
        case .dataBlocked:
            guard case .dataBlocked(let frame) = frame else { return false }
            return processDataBlocked(frame: frame)
        case .streamDataBlocked:
            guard case .streamDataBlocked(let frame) = frame else { return false }
            return processStreamDataBlocked(frame: frame)
        case .streamsBlockedBidirectional:
            guard case .streamsBlockedBidirectional(let frame) = frame else { return false }
            return processStreamsBlockedBidirectionalFrame(frame)
        case .streamsBlockedUnidirectional:
            guard case .streamsBlockedUnidirectional(let frame) = frame else { return false }
            return processStreamsBlockedUnidirectionalFrame(frame)
        case .newConnectionID:
            guard case .newConnectionID(let frame) = frame else { return false }
            return processNewConnectionIDFrame(frame)
        case .retireConnectionID:
            guard case .retireConnectionID(let frame) = frame else { return false }
            return processRetireConnectionIDFrame(frame)
        case .pathChallenge:
            guard case .pathChallenge(let frame) = frame else { return false }
            return handlePathChallengeFrame(frame, path: path)
        case .pathResponse:
            guard case .pathResponse(let frame) = frame else { return false }
            return handlePathChallengeResponseFrame(frame, path: path)
        case .connectionClose:
            guard case .connectionClose(let frame) = frame else { return false }
            return processConnectionCloseFrame(frame)
        case .applicationClose:
            guard case .applicationClose(let frame) = frame else { return false }
            return processApplicationCloseFrame(frame)
        case .handshakeDone:
            guard case .handshakeDone(let frame) = frame else { return false }
            return frame.process(connection: self)
        case .datagram:
            guard case .datagram(let frame) = frame else { return false }
            return processDatagramFrame(frame)
        }
    }
}

// MARK: Frame Acknowledgement helpers
@available(Network 0.1.0, *)
extension QUICConnection {
    func acknowledged(
        _ packet: borrowing SentPacketRecord,
        packetNumber: PacketNumber,
        packetNumberSpace: PacketNumberSpace,
        sentPath: QUICPath
    ) {
        packet.transmittedItems.allAcknowledged(
            connection: self,
            packetNumber: packetNumber,
            packetNumberSpace: packetNumberSpace,
            sentPath: sentPath
        )
    }

    func acknowledgedAck(
        frame: TransmittedItems.TransmittedAckFrame,
        packetNumber: PacketNumber,
        packetNumberSpace: PacketNumberSpace,
        sentPath: QUICPath
    ) {
        for block in Ack.blockSequence(frame: frame) {
            ack.acknowledged(
                packetNumberSpace: packetNumberSpace,
                between: block.start,
                and: block.end
            )
        }
    }

    func acknowledgedPMTUDProbe(on path: QUICPath, packetNumber: PacketNumber, mss: Int) {
        guard mss > 0, path.pmtudState.enabled else { return }
        path.pmtudState.probeAcked(on: path, packetLen: mss, packetNumber: packetNumber)
    }

    func acknowledgedKeepalive() {
        if unackedKeepaliveCount > 0 {
            unackedKeepaliveCount -= 1
        }
        log.info("Keep-alive packet acknowledged with \(unackedKeepaliveCount) outstanding")
        migration.checkForKeepaliveLoss(outstandingCount: unackedKeepaliveCount)
    }

    func acknowledgedResetStream(id: UInt64) {
        guard let stream = streamFromStreamID(id) else {
            log.error("Stream frame with invalid stream ID \(id)")
            return
        }

        if stream.sendState == .send {
            log.error(
                "[S\(stream.streamID?.value ?? 0)] in state send (resetSent? \(stream.resetSent))"
            )
        }
        stream.sendState.change(logIDString: logIDString, to: .resetReceived)

        // Only close the stream when the receive side is also in a terminal state.
        if stream.receiveState.dataHasAlreadyBeenReceived {
            let error = NetworkError.posix(ECONNRESET)
            stream.close(errorCode: error)
        }
    }

    func streamFromStreamID(_ id: UInt64) -> QUICStreamInstance? {
        guard let streamID = QUICStreamID(id) else {
            return nil
        }
        return streamFromStreamID(streamID)
    }

    func streamFromStreamID(_ streamID: QUICStreamID) -> QUICStreamInstance? {
        let knownFlowID = knownFlows[streamID]
        guard let flowID = knownFlowID else {
            return nil
        }
        guard let stream = flow(for: flowID) else {
            return nil
        }
        return stream
    }

    func acknowledgedStream(
        flowID: MultiplexedFlowIdentifier,
        offset: UInt64,
        length: UInt64,
        isFinal: Bool
    ) {
        // We've previously sent this STREAM frame, so we're confident it's got
        // valid offset and length. However, it may be old or there may be gaps
        // that have not yet been ACKed.
        guard let stream = flow(for: flowID) else {
            // We sent on this stream, but no longer "know" about it, somehow we got rid of it
            log.datapath("Acknowledgement for unknown flow \(flowID)")
            return
        }
        let streamFinished = stream.sendBuffer.acknowledgedSendData(
            offset: offset,
            length: length,
            log: stream.log
        )
        if isFinal {
            stream.peerAcknowledgedFIN = true
        }
        if streamFinished, stream.peerAcknowledgedFIN, stream.sendState != .dataReceived {
            stream.sendState.change(logIDString: stream.logPrefix, to: .dataReceived)
            if !stream.closed, stream.receiveState == .dataRead {
                // If both directions are closed, and all data is read, close the stream
                stream.close(errorCode: nil)
            }
        }
    }
}

// MARK: Connection Idle / Reuse

@available(Network 0.1.0, *)
extension QUICConnection {

    fileprivate func handleConnectionIdleForFlow(_ flowID: MultiplexedFlowIdentifier) {
        if let stream = flow(for: flowID) {
            stream.applicationMarkedIdle = true
            flowsHaveEverMarkedIdle = true
        } else if let datagramFlow = secondaryFlow(for: flowID) {
            datagramFlow.applicationMarkedIdle = true
            flowsHaveEverMarkedIdle = true
        }
        checkConnectionIdle()
    }

    fileprivate func handleConnectionReusedForFlow(_ flowID: MultiplexedFlowIdentifier) {
        if let stream = flow(for: flowID) {
            stream.applicationMarkedIdle = false
        } else if let datagramFlow = secondaryFlow(for: flowID) {
            datagramFlow.applicationMarkedIdle = false
        }
        checkConnectionIdle()
    }

    fileprivate var connectionIsIdleForAllStreams: Bool {
        // Fast exit if no flow has marked idle
        guard flowsHaveEverMarkedIdle else {
            return false
        }

        // If there are pending send items, not idle
        if initialPendingItems.hasPendingItems || handshakePendingItems.hasPendingItems
            || applicationPendingItems.hasPendingItems
        {
            return false
        }

        // Check if any streams are non idle
        var someFlowIsNonIdle = false
        applyToAllFlows { stream in
            if !stream.applicationMarkedIdle {
                someFlowIsNonIdle = true
            }
        }
        if someFlowIsNonIdle {
            return false
        }
        applyToAllSecondaryFlows { datagramFlow in
            if !datagramFlow.applicationMarkedIdle {
                someFlowIsNonIdle = true
            }
        }
        if someFlowIsNonIdle {
            return false
        }

        // Recovery has outstanding packets, not idle
        if recovery.hasOutstandingPackets {
            return false
        }

        // Everything is idle, return true
        return true
    }

    func checkConnectionIdle() {
        let isIdle = connectionIsIdleForAllStreams
        applyToAllPaths { path in
            let pathIsIdle = isIdle && !path.isProbing && !path.shouldSendPathResponses
            if pathIsIdle && !path.reportedIdleEvent {
                // Need to report idle
                path.reportedIdleEvent = true
                path.lower.invokeApplicationEvent(path.reference, event: .connectionIdle)
            } else if !pathIsIdle && path.reportedIdleEvent {
                // Need to report non-idle
                path.reportedIdleEvent = false
                path.lower.invokeApplicationEvent(path.reference, event: .connectionReused)
            }
        }
    }
}

// MARK: Connection ID Lifecycle

@available(Network 0.1.0, *)
extension QUICConnection {

    public func handleApplicationEvent(
        flow flowID: MultiplexedFlowIdentifier,
        event: ApplicationEvent
    ) -> HandleNetworkEventResult {
        if event == .connectionIdle {
            handleConnectionIdleForFlow(flowID)
            return .consumed
        }
        if event == .connectionReused {
            handleConnectionReusedForFlow(flowID)
            return .consumed
        }
        return handleApplicationEvent(event)
    }

    public func handleApplicationEvent(_ event: ApplicationEvent) -> HandleNetworkEventResult {
        guard let quicEvent = event.quicEvent else {
            return .unconsumed
        }

        switch quicEvent {
        case .announceNewInboundConnectionID(let connectionID, let statelessResetToken):
            log.info("Announcing new CID \(connectionID) to the peer")
            announceNewConnectionID(connectionID, statelessResetToken: statelessResetToken)
        case .retireOutboundConnectionID(let connectionID):
            log.info("Retire outbound CID \(connectionID) to the peer")
            sendRetireConnectionIDFrame(connectionID)
        case .updateMaximumBidirectionalStreams(let maximumStreams):
            log.info("Updating maximum bidirectional streams: \(maximumStreams)")
            updateMaxBidirectionalStreamsFromApplication(maximumStreams)
        case .updateMaximumUnidirectionalStreams(let maximumStreams):
            log.info("Updating maximum unidirectional streams: \(maximumStreams)")
            updateMaxUnidirectionalStreamsFromApplication(maximumStreams)
        }

        return .consumed
    }

    func announceNewConnectionID(
        _ connectionID: QUICConnectionID,
        statelessResetToken: QUICStatelessResetToken
    ) {
        guard localCIDs.activeConnectionIDLimit > localCIDs.count else {
            // Not allowed to send more
            return
        }

        do {
            let newCIDSequenceNumber = nextLocalCIDSequenceNumber
            // Add the new CID to the list of local CIDs
            try localCIDs.insert(
                sequenceNumber: newCIDSequenceNumber,
                connectionID: connectionID,
                token: statelessResetToken,
                used: false
            )

            nextLocalCIDSequenceNumber += 1

            // Send a NEW_CONNECTION_ID frame. For now, don't retire any
            // previous sequence numbers.
            withPendingItemsForKeyState {
                $0.addNewConnectionID(
                    FrameNewConnectionID(
                        sequence: newCIDSequenceNumber,
                        retirePriorToSequence: 0,
                        connectionID: connectionID,
                        statelessResetToken: statelessResetToken
                    )
                )
            }

            deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .newInboundConnectionID(connectionID))
            )
        } catch {
            log.error("Error adding a new local CID: \(error)")
        }
    }

    // Create and announce new CIDs, if allowed
    func announceNewConnectionIDs(count: Int = Constants.defaultMaxConnectionIDs) {
        // Asked to not automatically announce
        guard !disableAutomaticNewConnectionIDs else {
            return
        }

        // Only send new CIDs if using non-zero lengths
        guard localCIDLength > 0 else { return }

        guard localCIDs.activeConnectionIDLimit > localCIDs.count else {
            // Not allowed to send more
            return
        }

        let remainingLimit = localCIDs.activeConnectionIDLimit - localCIDs.count
        let cidCountToAnnounce = min(remainingLimit, count)

        log.info("Sending \(cidCountToAnnounce) new CIDs to the peer")
        for _ in 0..<cidCountToAnnounce {
            // Generate CID, matching original length
            let newCID = QUICConnectionID(localCIDLength)
            let token = QUICStatelessResetToken()
            announceNewConnectionID(newCID, statelessResetToken: token)
        }
    }

    func processNewConnectionIDFrame(_ frame: FrameNewConnectionID) -> Bool {
        let nonZeroLengthCIDs = withCurrentPath { path in
            guard let dcid = path.dcid else {
                log.error("DCID not set, cannot process new connection ID")
                return false
            }
            guard dcid.length > 0 else {
                log.error(
                    "Received NEW_CONNECTION_ID frame for connection with zero-length DCID"
                )
                close(with: .protocolViolation, "NEW_CONNECTION_ID on a zero-length CID connection")
                return false
            }
            return true
        }
        guard nonZeroLengthCIDs else { return false }
        if let currentCID = self.remoteCIDs.find(connectionID: frame.connectionID) {
            // If an endpoint receives a NEW_CONNECTION_ID frame that
            // repeats a previously issued connection ID with a different
            // Stateless Reset Token or a different sequence number, the
            // endpoint MAY treat that receipt as a connection error of type
            // PROTOCOL_VIOLATION.
            if currentCID.sequenceNumber != frame.sequence
                || currentCID.token != frame.statelessResetToken
            {
                let error =
                    "Received NEW_CONNECTION_ID frame with reused CID but different token or sequence"
                log.error(error)
                close(with: .protocolViolation, error)
                return false
            }
            // Otherwise, the peer resent the same info. Ignore it
            return true
        }

        // Retire-prior-to values greater than the Sequence Number MUST be treated as a
        // connection error.
        if frame.retirePriorToSequence > frame.sequence {
            log.error(
                "Received NEW_CONNECTION_ID frame on with retire prior to field larger than seq field"
            )
            close(with: .protocolViolation, "NEW_CONNECTION_ID: invalid retire prior field")
            return false
        }

        // RFC9000:
        // "Upon receipt of an increased Retire Prior To field, the peer MUST
        // stop using the corresponding connection IDs and retire them with
        //  RETIRE_CONNECTION_ID frames before adding the newly provided
        // connection ID to the set of active connection IDs. This ordering
        // allows an endpoint to replace all active connection IDs without the
        // possibility of a peer having no available connection IDs and without
        // exceeding the limit the peer sets in the active_connection_id_limit
        // transport parameter"
        let retiredCIDs = remoteCIDs.retire(priorTo: frame.retirePriorToSequence)
        for retiredCID in retiredCIDs {
            migration.retireDCID(retiredCID.1)

            // Send a protocol notification up the stack
            deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .retiredOutboundConnectionID(retiredCID.1))
            )

            // Send a frame to retire the connection ID
            withPendingItemsForKeyState {
                $0.addRetireConnectionID(
                    FrameRetireConnectionID(sequence: retiredCID.0)
                )
            }

            let success = withCurrentPath { path in
                if path.dcid == retiredCID.1 {
                    guard assignNewDCID(to: path) else {
                        log.error("Asked to retire current DCID but could not allocate a new DCID")
                        close(
                            with:
                                .internalError,
                            "NEW_CONNECTION_ID: unable to allocate a new DCID"
                        )
                        return false
                    }
                }
                return true
            }
            guard success else { return false }
        }

        // An endpoint that receives a NEW_CONNECTION_ID frame with a sequence
        // number smaller than the Retire Prior To field of a previously
        // received NEW_CONNECTION_ID frame MUST send a corresponding
        // RETIRE_CONNECTION_ID frame that retires the newly received
        // connection ID, unless it has already done so for that sequence number.
        if frame.retirePriorToSequence > retiredRemoteCIDSequenceNumberThreshold {
            retiredRemoteCIDSequenceNumberThreshold = frame.retirePriorToSequence
        }
        if frame.sequence < retiredRemoteCIDSequenceNumberThreshold {
            // Send a frame to retire the connection ID
            log.info("Immediately retiring connection ID with sequence \(frame.sequence)")
            withPendingItemsForKeyState {
                $0.addRetireConnectionID(
                    FrameRetireConnectionID(sequence: frame.sequence)
                )
            }
            return true
        }

        // If we have not seen this frame before and haven't reached the
        // active CID limit, add it to the CID table.
        let cidLimit = remoteCIDs.activeConnectionIDLimit
        if remoteCIDs.count < cidLimit {
            do {
                try remoteCIDs.insert(
                    sequenceNumber: frame.sequence,
                    connectionID: frame.connectionID,
                    token: frame.statelessResetToken,
                    used: false
                )
                deliverNetworkProtocolEvent(
                    flow: .allFlows,
                    event: .init(quicEvent: .newOutboundConnectionID(frame.connectionID))
                )
                migration.newDCID(frame.connectionID)
            } catch {
                // RFC 9000: 19.15:
                // Transmission errors, timeouts, and retransmissions might cause the same NEW_CONNECTION_ID frame
                // to be received multiple times. Receipt of the same frame multiple times MUST NOT be treated as
                // a connection error. A receiver can use the sequence number supplied in the NEW_CONNECTION_ID
                // frame to handle receiving the same NEW_CONNECTION_ID frame multiple times.
                log.debug(
                    "Unable to insert received NEW_CONNECTION_ID, may be a duplicate: \(error)"
                )
            }
        } else {
            log.info("Attempt to add new CID that exceeds the configured cid limit (\(cidLimit))")
        }

        return true
    }

    // For inbound (local) CIDs
    func retireConnectionID(sequenceNumber: UInt64) {
        if let retiredCID = localCIDs.retire(sequenceNumber: sequenceNumber) {
            deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(quicEvent: .retiredInboundConnectionID(retiredCID))
            )

            if localCIDs.count < localCIDs.activeConnectionIDLimit {
                announceNewConnectionIDs(count: 1)
            }
        }
    }

    // For inbound (local) CIDs
    func retireConnectionID(_ cid: QUICConnectionID) -> UInt64? {
        guard let managedCID = localCIDs.find(connectionID: cid) else {
            return nil
        }
        let sequenceNumber = managedCID.sequenceNumber
        retireConnectionID(sequenceNumber: sequenceNumber)
        return sequenceNumber
    }

    // For outbound (remote) CIDs
    func sendRetireConnectionIDFrame(_ cid: QUICConnectionID) {
        guard let sequenceNumber = remoteCIDs.retire(connectionID: cid) else {
            return
        }

        // Send a protocol notification up the stack
        deliverNetworkProtocolEvent(
            flow: .allFlows,
            event: .init(quicEvent: .retiredOutboundConnectionID(cid))
        )

        withPendingItemsForKeyState {
            $0.addRetireConnectionID(
                FrameRetireConnectionID(sequence: sequenceNumber)
            )
        }
        sendFrames()
    }

    func processRetireConnectionIDFrame(_ frame: FrameRetireConnectionID) -> Bool {
        // An endpoint cannot send this frame if it was provided with a zero-
        // length connection ID by its peer. An endpoint that provides a zero-
        // length connection ID MUST treat receipt of a RETIRE_CONNECTION_ID
        // frame as a connection error of type PROTOCOL_VIOLATION.
        guard localCIDLength > 0 else {
            log.error(
                "Received RETIRE_CONNECTION_ID frame for connection with zero-length SCID"
            )
            close(
                with:
                    .protocolViolation,
                "RETIRE_CONNECTION_ID on a zero-length CID connection"
            )
            return false
        }

        // RFC 9000 §19.16:
        //
        // Receipt of a RETIRE_CONNECTION_ID frame containing a sequence number
        // greater than any previously sent to the peer MUST be treated as a
        // connection error of type PROTOCOL_VIOLATION.
        if frame.sequence > largestSentLocalCIDSequenceNumber {
            log.error(
                "Received RETIRE_CONNECTION_ID with sequence number greater than what we have ever sent in a NEW_CONNECTION_ID"
            )
            close(with: .protocolViolation, "RETIRE_CONNECTION_ID: invalid sequence number")
            return false
        }

        retireConnectionID(sequenceNumber: frame.sequence)

        return true
    }
}

// MARK: Path Challenge processing

@available(Network 0.1.0, *)
extension QUICConnection {
    @discardableResult
    func handlePathChallengeFrame(
        _ frame: FramePathChallenge,
        path: QUICPath
    ) -> Bool {
        path.handlePathChallenge(frame.data)
        return true
    }

    @discardableResult
    func handlePathChallengeResponseFrame(
        _ frame: FramePathResponse,
        path: QUICPath
    ) -> Bool {
        path.handlePathChallengeResponse(frame.data)
        return true
    }
}

#else
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICConnection: ProtocolInstance, ProtocolInstanceContainer {
    public private(set) var context: NetworkContext
    public init(context: NetworkContext) { self.context = context }
    public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    public var eventManager = ProtocolEventManager()
}
#endif
