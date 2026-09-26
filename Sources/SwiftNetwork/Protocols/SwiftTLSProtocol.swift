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

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

#if canImport(Foundation) && !NETWORK_EMBEDDED
import Foundation
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

#if IMPORT_CRYPTO || IMPORT_SWIFTTLS
#if canImport(CryptoKit)
internal import CryptoKit
#elseif canImport(Crypto)
@preconcurrency internal import Crypto
#endif
#endif

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

#if !NETWORK_PRIVATE
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias TLSProtocol = SwiftTLSProtocol
#endif

let SwiftTLSRecordProtocolMaxOutstandingReadBytes: Int = (8 * 1024 * 1024)  // 8MB

#if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
// The record layer is generic over its instance's linkages, so this cannot be a static stored
// property on it.
#if !os(Linux) && !NETWORK_STANDALONE
private let swiftTLSRecordSuccessErrorCode = errSecSuccess
#else
private let swiftTLSRecordSuccessErrorCode = 0
#endif
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct SwiftTLSProtocol: NetworkProtocol {
    public typealias Options = SwiftTLSProtocolOptions
    public typealias Metadata = SwiftTLSMetadata

    public init() {}

    public struct SwiftTLSProtocolOptions: PerProtocolOptions {
        private var _tlsOptions = SwiftTLSOptionsStorage()

        #if EXPORT_SWIFTTLS
        private typealias SwiftTLSOptionsStorage = SwiftTLSOptions

        public var tlsOptions: SwiftTLSOptions {
            get { _tlsOptions }
            set { _tlsOptions = newValue }
        }

        public mutating func setExternalPSK(identity: [UInt8], epsk: [UInt8]) {
            _tlsOptions.externalPSK = .init(externalIdentity: identity, epsk: .init(data: epsk))
        }
        #else
        private struct SwiftTLSOptionsStorage {
            var serverName: String?
            var quicTransportParameters: [UInt8]?
            var applicationProtocols: [String]?
            var trustedRawPublicKeyCertificates: [[UInt8]]?
            var rawPrivateKey: [UInt8]?
            var enableEarlyData: Bool = false
            var clientAuthRequired: Bool = false
            var externalPSKIdentity: [UInt8]?
            var externalPSKData: [UInt8]?
        }

        var tlsOptions: SwiftTLSOptions {
            get {
                var tlsOptions = SwiftTLSOptions()
                tlsOptions.serverName = _tlsOptions.serverName
                tlsOptions.quicTransportParameters = _tlsOptions.quicTransportParameters
                tlsOptions.applicationProtocols = _tlsOptions.applicationProtocols
                tlsOptions.trustedRawPublicKeyCertificates = _tlsOptions.trustedRawPublicKeyCertificates
                tlsOptions.rawPrivateKey = _tlsOptions.rawPrivateKey
                tlsOptions.enableEarlyData = _tlsOptions.enableEarlyData
                tlsOptions.clientAuthRequired = _tlsOptions.clientAuthRequired
                #if IMPORT_SWIFTTLS
                if let externalPSKIdentity = _tlsOptions.externalPSKIdentity,
                    let externalPSKData = _tlsOptions.externalPSKData
                {
                    tlsOptions.externalPSK = .init(
                        externalIdentity: externalPSKIdentity,
                        epsk: .init(data: externalPSKData)
                    )
                }
                #endif
                return tlsOptions
            }
            set {
                _tlsOptions.serverName = newValue.serverName
                _tlsOptions.quicTransportParameters = newValue.quicTransportParameters
                _tlsOptions.applicationProtocols = newValue.applicationProtocols
                _tlsOptions.trustedRawPublicKeyCertificates = newValue.trustedRawPublicKeyCertificates
                _tlsOptions.rawPrivateKey = newValue.rawPrivateKey
                _tlsOptions.enableEarlyData = newValue.enableEarlyData
                _tlsOptions.clientAuthRequired = newValue.clientAuthRequired
            }
        }

        public mutating func setExternalPSK(identity: [UInt8], epsk: [UInt8]) {
            _tlsOptions.externalPSKIdentity = identity
            _tlsOptions.externalPSKData = epsk
        }
        #endif

        public var serverName: String? {
            get { _tlsOptions.serverName }
            set { _tlsOptions.serverName = newValue }
        }
        public var quicTransportParameters: [UInt8]? {
            get { _tlsOptions.quicTransportParameters }
            set { _tlsOptions.quicTransportParameters = newValue }
        }
        public var applicationProtocols: [String]? {
            get { _tlsOptions.applicationProtocols }
            set { _tlsOptions.applicationProtocols = newValue }
        }

        // Options used for setting up clients or servers
        // with the raw public keys they are willing to
        // trust from their peer.
        public var trustedRawPublicKeyCertificates: [[UInt8]]? {
            get { _tlsOptions.trustedRawPublicKeyCertificates }
            set { _tlsOptions.trustedRawPublicKeyCertificates = newValue }
        }

        // Server or client private key for use with Raw Public Keys
        public var rawPrivateKey: [UInt8]? {
            get { _tlsOptions.rawPrivateKey }
            set { _tlsOptions.rawPrivateKey = newValue }
        }

        public var enableEarlyData: Bool {
            get { _tlsOptions.enableEarlyData }
            set { _tlsOptions.enableEarlyData = newValue }
        }

        public var clientAuthRequired: Bool {
            get { _tlsOptions.clientAuthRequired }
            set { _tlsOptions.clientAuthRequired = newValue }
        }

        // Resumed QUIC transport parameter state, set on clients
        public var resumedQUICTransportParameters: [UInt8]?

        public init() {
            #if EXPORT_SWIFTTLS
            _tlsOptions.keyExchangeGroup = .x25519
            #endif
        }
        public func serialize() -> [UInt8]? { nil }
        public var serializeInParameters: Bool { false }
        public func deepCopy() -> SwiftTLSProtocolOptions {
            var copy = SwiftTLSProtocolOptions()
            copy.serverName = self.serverName
            copy.tlsOptions = self.tlsOptions
            copy.resumedQUICTransportParameters = self.resumedQUICTransportParameters
            return copy
        }
        public func isEqual(to other: SwiftTLSProtocolOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }
        public static func == (lhs: SwiftTLSProtocolOptions, rhs: SwiftTLSProtocolOptions) -> Bool {
            lhs.isEqual(to: rhs, for: .equal)
        }
    }

    public struct SwiftTLSMetadata: PerProtocolMetadata {
        init() {}
        public func isEqual(to other: SwiftTLSMetadata, for: ProtocolCompareMode) -> Bool { true }
    }

    #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
    /// A TLS instance that runs a full record layer, for stacks that are not carrying QUIC.
    final class SwiftTLSRecordInstance<TLSUpperProtocol: InboundStreamLinkage, TLSLowerProtocol: OutboundStreamLinkage>:
        OneToOneStreamProtocol
    {
        private var recordLayer: SwiftTLSRecordLayerInstance<TLSUpperProtocol, TLSLowerProtocol>?

        private func requireRecordLayer() throws(NetworkError) -> SwiftTLSRecordLayerInstance<
            TLSUpperProtocol,
            TLSLowerProtocol
        > {
            guard let recordLayer else { throw NetworkError.posix(EINVAL) }
            return recordLayer
        }

        typealias UpperProtocol = TLSUpperProtocol
        typealias LowerProtocol = TLSLowerProtocol

        var metadata: AbstractProtocolMetadata?
        var upper = UpperProtocol()
        var lower = LowerProtocol()
        private(set) var context: NetworkContext
        var identifier: InstanceIdentifier
        var passthroughEvents = false
        var log = NetworkLoggerState()
        var eventManager = ProtocolEventManager()

        init(context: NetworkContext) {
            self.context = context
            self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
        }

        func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            // Get tls options here
            // note: all logic about what tlsOptions are valid/required
            // should be handled within SwiftTLS, so that logic does not
            // need to be duplicated here.
            guard let parameters,
                let options = parameters.tlsOptions(for: identifier),
                let protocolOptions = options.perProtocolOptions,
                protocolOptions.tlsOptions.quicTransportParameters == nil
            else {
                throw NetworkError.posix(EINVAL)
            }
            recordLayer = try SwiftTLSRecordLayerInstance(self, protocolOptions, parameters)
        }

        func teardown() {
            log.debug("")
            guard let recordLayer else { preconditionFailure("record layer unexpectedly nil") }
            recordLayer.teardown()
            self.recordLayer = nil
        }

        func connect(in eventContext: inout NetworkContext.EventContext) {
            log.debug("")
            guard let recordLayer else { preconditionFailure("record layer unexpectedly nil") }
            recordLayer.connect(in: &eventContext)
        }

        func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
            log.debug("")
            guard let recordLayer else { preconditionFailure("record layer unexpectedly nil") }
            recordLayer.disconnect(error: error, in: &eventContext)
        }

        func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
            log.debug("")
            guard let recordLayer else { preconditionFailure("record layer unexpectedly nil") }
            recordLayer.handleDisconnectedEvent(error: error, in: &eventContext)
        }

        func sendStreamData(
            _ streamData: consuming FrameArray,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            log.debug("")
            let recordLayer: SwiftTLSRecordLayerInstance<TLSUpperProtocol, TLSLowerProtocol>
            do throws(NetworkError) {
                recordLayer = try requireRecordLayer()
            } catch {
                streamData.finalizeAllFramesAsFailed()
                throw error
            }
            try recordLayer.sendStreamData(streamData, in: &eventContext)
        }

        func getOutboundStreamDataRoomAvailable(
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> Int {
            log.debug("")
            return try requireRecordLayer().getOutboundStreamDataRoomAvailable(in: &eventContext)
        }

        func receiveStreamData(
            minimumBytes: Int,
            maximumBytes: Int,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            log.debug("")
            return try requireRecordLayer().receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                in: &eventContext
            )
        }

        func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
            log.debug("")
            guard let recordLayer else { preconditionFailure("record layer unexpectedly nil") }
            recordLayer.handleInboundDataAvailableEvent(in: &eventContext)
        }
    }
    #endif

    /// A TLS instance that runs only the handshake, with QUIC carrying the records.
    #if !NETWORK_NO_SWIFT_QUIC
    final class SwiftTLSQUICOnlyInstance: BottomStreamProtocol, OutboundStreamLinkage, ProtocolInstanceAsLinkage {
        typealias PairedUpperLinkage = QUICCrypto
        typealias LinkageType = SwiftTLSProtocol.SwiftTLSQUICOnlyInstance

        var metadata: AbstractProtocolMetadata?
        var upper = LinkageType.PairedUpperLinkage()
        private(set) var context: NetworkContext
        var identifier: InstanceIdentifier
        var passthroughEvents = false
        var log = NetworkLoggerState()
        var eventManager = ProtocolEventManager()

        var isConnected = false
        var isServer = false
        #if CLIENT_ONLY
        let handshaker = SwiftTLSHandshaker.createClientHandshake()
        #else
        #if SERVER_ONLY
        let handshaker = SwiftTLSHandshaker.createServerHandshake()
        #else
        // Client or server case
        var handshaker = SwiftTLSHandshaker.createClientHandshake()
        #endif
        #endif
        var serverSentHello = false
        var startedHandshake = false
        // Populated by `setup(remote:local:parameters:path:)`, which runs before anything else
        // touches the instance.
        var options = SwiftTLSProtocolOptions()

        /// The QUIC crypto instance this handshake feeds keys and transport parameters to.
        ///
        /// Held strongly, which forms a cycle with `QUICCrypto.tlsInstance`; `teardown()`
        /// breaks it by clearing this reference.
        private var quicCrypto: QUICCrypto?

        /// What the certificate-verification continuation reaches this instance through.
        ///
        /// SwiftTLS copies the continuation handler into its handshake state machine, and clearing
        /// the handler does not clear that copy, so the closure outlives the handshake. It holds
        /// this box rather than the instance, and tearing the handshake down empties the box, which
        /// is what lets the instance go.
        ///
        /// The box crosses into the continuation closure, which runs wherever SwiftTLS completes the
        /// verification, so it has to be `Sendable`; `instance` is only ever read back on the
        /// context, which is what makes that sound.
        private final class AsyncContinuationTarget: @unchecked Sendable {
            var instance: SwiftTLSQUICOnlyInstance?

            init(_ instance: SwiftTLSQUICOnlyInstance) {
                self.instance = instance
            }
        }

        private var asyncContinuationTarget: AsyncContinuationTarget?

        init() {
            quicCrypto = nil
            context = .implicitContext
            identifier = .init()
        }

        init(context: NetworkContext, quicCrypto: QUICCrypto?) {
            self.quicCrypto = quicCrypto
            self.context = context
            self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
        }

        /// Registers using an event context the caller already holds, so the state isn't
        /// re-derived from the context.
        init(
            context: NetworkContext,
            quicCrypto: QUICCrypto?,
            in eventContext: inout NetworkContext.EventContext
        ) {
            self.quicCrypto = quicCrypto
            self.context = context
            self.identifier = InstanceIdentifier(
                eventManager: &self.eventManager,
                in: &eventContext
            )
        }

        func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            guard let parameters,
                let options = parameters.tlsOptions(for: identifier),
                let protocolOptions = options.perProtocolOptions,
                protocolOptions.tlsOptions.quicTransportParameters != nil
            else {
                throw NetworkError.posix(EINVAL)
            }
            self.options = protocolOptions
            isServer = parameters.isServer
        }

        final class EncryptionLevelHandler: TopStreamProtocol, InboundStreamLinkage, ProtocolInstanceAsLinkage {
            typealias PairedLowerLinkage = QUICCrypto

            typealias LinkageType = SwiftTLSProtocol.SwiftTLSQUICOnlyInstance.EncryptionLevelHandler
            typealias LowerProtocol = LinkageType.PairedLowerLinkage

            var lower = LowerProtocol()

            let level: SwiftTLSOptions.EncryptionLevel
            var parentInstance: SwiftTLSQUICOnlyInstance?

            /// Assigns the parent and registers this handler's event state.
            ///
            /// Registration needs the event context, so it takes the state the caller already
            /// holds rather than re-deriving it from the context (which would trip Swift's
            /// exclusivity checking). The context itself comes from the parent, so the identifier
            /// can only be built once a parent has been assigned.
            func setParent(
                _ parentInstance: SwiftTLSQUICOnlyInstance,
                in eventContext: inout NetworkContext.EventContext
            ) {
                self.parentInstance = parentInstance
                identifier = InstanceIdentifier(
                    eventManager: &self.eventManager,
                    in: &eventContext
                )
                identifier.setParentInstance(parentInstance.identifier)
            }
            public var context: NetworkContext { parentInstance!.context }

            public var identifier: InstanceIdentifier

            var eventManager = ProtocolEventManager()

            init(level: SwiftTLSOptions.EncryptionLevel) {
                self.level = level
                self.identifier = .init()
            }
            convenience init() { self.init(level: .initial) }

            func invokeAttachLowerProtocol(
                _ lowerProtocol: QUICCrypto,
                remote: Endpoint?,
                local: Endpoint?,
                parameters: Parameters?,
                path: PathProperties?
            ) throws(NetworkError) {}

            func destroy() {
                // `context` comes from the parent, and `setParent` is also what registers the
                // event state, so an unparented handler has nothing to release.
                guard parentInstance != nil else { return }
                fromExternal { eventContext in
                    destroy(in: &eventContext)
                }
            }

            /// Destroys using an event context the caller already holds.
            func destroy(in eventContext: inout NetworkContext.EventContext) {
                if !lower.isDetached {
                    try? lower.invokeDetach(for: identifier, in: &eventContext)
                    lower = LowerProtocol()
                }
                // Nothing below a top protocol hands its event state back, so release it here.
                unregisterEventManager(in: &eventContext)
                parentInstance = nil
            }

            func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
                guard !lower.isDetached, let parentInstance else {
                    return
                }
                let frameArray = try? lower.invokeReceiveStreamData(
                    minimumBytes: 1,
                    maximumBytes: Int.max,
                    for: identifier,
                    in: &eventContext
                )
                guard var frameArray else {
                    return
                }

                while var frame = frameArray.popFirst() {
                    if let bytes = frame.span, !bytes.isEmpty {
                        do {
                            try parentInstance.continueHandshake(
                                with: [UInt8](copying: bytes, maxCount: bytes.count),
                                in: &eventContext
                            )
                        } catch {
                            parentInstance.log.error("Failed to continue handshake \(error)")
                            let handshakerErrorCode = parentInstance.handshaker.errorCode
                            if handshakerErrorCode != 0 {
                                parentInstance.reportError(handshakerErrorCode, in: &eventContext)
                            }
                        }
                    } else {
                        frame.finalize(success: false)
                        continue
                    }

                    frame.finalize(success: true)
                }
            }

            func getOutboundStreamDataRoomAvailable(
                in eventContext: inout NetworkContext.EventContext
            ) throws(NetworkError) -> Int {
                guard !lower.isDetached else {
                    throw NetworkError.posix(EINVAL)
                }
                return try lower.invokeGetOutboundStreamDataRoomAvailable(for: identifier, in: &eventContext)
            }

            func sendStreamData(
                _ streamData: consuming FrameArray,
                in eventContext: inout NetworkContext.EventContext
            ) throws(NetworkError) {
                guard !lower.isDetached else {
                    streamData.finalizeAllFramesAsFailed()
                    throw NetworkError.posix(EINVAL)
                }
                try lower.invokeSendStreamData(streamData, from: identifier, in: &eventContext)
            }
        }

        let initialDataHandler = EncryptionLevelHandler(level: .initial)
        let earlyDataHandler = EncryptionLevelHandler(level: .earlyData)
        let handshakeDataHandler = EncryptionLevelHandler(level: .handshake)
        let applicationDataHandler = EncryptionLevelHandler(level: .application)

        func continueHandshake(
            with message: [UInt8]? = nil,
            in eventContext: inout NetworkContext.EventContext
        ) throws(TLSNetworkError) {
            var messageToProcess: [UInt8]? = message
            while true {

                // Loop to gather all handshake data into one message
                var dataToSend: [UInt8]?
                while true {
                    do {
                        let singleData = try handshaker.continueHandshake(with: messageToProcess)
                        if let singleData {
                            // Append to data to send
                            if dataToSend != nil {
                                dataToSend = dataToSend! + singleData
                            } else {
                                dataToSend = singleData
                            }

                            if !serverSentHello {
                                // Need to send the initial server message, break this inner loop
                                break
                            }
                        } else {
                            // No more data to send, break this inner loop
                            break
                        }
                    } catch {
                        throw TLSNetworkError.handshakeFailed
                    }
                }

                guard dataToSend != nil || messageToProcess != nil else {
                    // Exit loop if no progress
                    break
                }

                messageToProcess = nil
                if let quicCrypto {
                    if handshaker.earlyDataAccepted {
                        quicCrypto.updateEarlyDataAccepted(true, in: &eventContext)
                    }

                    if let peerQUICTransportParameters = handshaker.peerQUICTransportParameters {
                        quicCrypto.updatePeerQUICTransportParameters(
                            peerQUICTransportParameters,
                            earlyData: false,
                            in: &eventContext
                        )
                    }

                    let hasWriteEncryptionLevel = (handshaker.writeEncryptionLevel != .initial)
                    let hasReadEncryptionLevel = (handshaker.readEncryptionLevel != .initial)
                    if hasWriteEncryptionLevel || hasReadEncryptionLevel {
                        quicCrypto.updateNegotiatedCiphersuite(handshaker.negotiatedCiphersuite)
                        if hasReadEncryptionLevel, let readSecret = handshaker.readEncryptionSecret {
                            quicCrypto.updateSecret(
                                readSecret,
                                for: handshaker.readEncryptionLevel,
                                isWrite: false,
                                in: &eventContext
                            )
                        }
                        if hasWriteEncryptionLevel, let writeSecret = handshaker.writeEncryptionSecret {
                            quicCrypto.updateSecret(
                                writeSecret,
                                for: handshaker.writeEncryptionLevel,
                                isWrite: true,
                                in: &eventContext
                            )
                        }
                    }

                    if !handshaker.receivedSessionTickets.isEmpty {
                        let ticketArray = handshaker.receivedSessionTickets
                        handshaker.receivedSessionTickets = [[UInt8]]()
                        quicCrypto.updateSessionTickets(ticketArray)
                    }
                }

                if let dataToSend {
                    if isServer {
                        if serverSentHello {
                            sendMessage(dataToSend, level: .handshake, in: &eventContext)
                        } else {
                            serverSentHello = true
                            sendMessage(dataToSend, level: .initial, in: &eventContext)
                        }
                    } else {
                        sendMessage(dataToSend, level: .handshake, in: &eventContext)
                    }
                } else if handshaker.errorCode != 0 {
                    reportError(handshaker.errorCode, in: &eventContext)
                }

                if isServer {
                    if handshaker.readEncryptionLevel == .application {
                        completeHandshake(in: &eventContext)
                    }
                } else {
                    if handshaker.writeEncryptionLevel == .application {
                        completeHandshake(in: &eventContext)
                    }
                }
            }
        }

        func completeHandshake(in eventContext: inout NetworkContext.EventContext) {
            let newlyConnected = !isConnected
            isConnected = true

            deliverConnectedEvent(in: &eventContext)
            if !isServer, newlyConnected, let quicCrypto, !handshaker.earlyDataAccepted {
                quicCrypto.updateEarlyDataAccepted(false, in: &eventContext)
            }
        }

        func reportError(_ error: Int32, in eventContext: inout NetworkContext.EventContext) {
            log.error("Reporting TLS error \(error)")
            deliverDisconnectedEvent(error: NetworkError.posix(error), in: &eventContext)
        }

        func sendMessage(
            _ message: [UInt8],
            level: SwiftTLSOptions.EncryptionLevel,
            in eventContext: inout NetworkContext.EventContext
        ) {
            let encryptionLevelHandler: EncryptionLevelHandler
            switch level {
            case .initial: encryptionLevelHandler = initialDataHandler
            case .earlyData: encryptionLevelHandler = earlyDataHandler
            case .handshake: encryptionLevelHandler = handshakeDataHandler
            case .application: encryptionLevelHandler = applicationDataHandler
            }

            try? encryptionLevelHandler.sendStreamData(FrameArray(frame: Frame(copyBuffer: message)), in: &eventContext)
        }

        func teardown(in eventContext: inout NetworkContext.EventContext) {
            unregisterEventManager(in: &eventContext)
        }

        func teardown() {
            #if canImport(SwiftTLS) && SWIFTTLS_CERTIFICATE_VERIFICATION
            handshaker.setAsyncContinuationHandler(nil)
            releaseAsyncContinuationTarget()
            #endif
            initialDataHandler.destroy()
            handshakeDataHandler.destroy()
            earlyDataHandler.destroy()
            applicationDataHandler.destroy()
            quicCrypto = nil
        }

        /// Tears down the handshake state using an event context the caller already holds.
        ///
        /// Named distinctly from `teardown(in:)`, which is the linkage-storage-release hook
        /// from `LowerProtocolLinkage`.
        func teardownHandshake(in eventContext: inout NetworkContext.EventContext) {
            #if canImport(SwiftTLS) && SWIFTTLS_CERTIFICATE_VERIFICATION
            handshaker.setAsyncContinuationHandler(nil)
            releaseAsyncContinuationTarget()
            #endif
            initialDataHandler.destroy(in: &eventContext)
            handshakeDataHandler.destroy(in: &eventContext)
            earlyDataHandler.destroy(in: &eventContext)
            applicationDataHandler.destroy(in: &eventContext)
            quicCrypto = nil
        }

        #if canImport(SwiftTLS) && SWIFTTLS_CERTIFICATE_VERIFICATION
        /// Empties the box the certificate-verification continuation reaches this instance through.
        ///
        /// The handler itself is cleared above, but SwiftTLS's state machine keeps its own copy of
        /// the closure, so emptying the box is what stops that copy from holding this instance.
        private func releaseAsyncContinuationTarget() {
            asyncContinuationTarget?.instance = nil
            asyncContinuationTarget = nil
        }
        #endif

        // Disconnect and the disconnected event are passed straight through: QUIC owns the
        // connection lifetime, this instance only runs the handshake.
        func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
            log.debug("")
            deliverDisconnectedEvent(error: error, in: &eventContext)
        }

        func connect(in eventContext: inout NetworkContext.EventContext) {
            guard !isConnected else {
                // Already connected, report
                deliverConnectedEvent(in: &eventContext)
                return
            }

            guard !startedHandshake else {
                // Already started, ignore
                return
            }

            startedHandshake = true
            #if CLIENT_ONLY
            if isServer {
                log.error("Server TLS not supported")
                reportError(EINVAL, in: &eventContext)
                return
            }
            #else
            #if SERVER_ONLY
            if !isServer {
                log.error("Client TLS not supported")
                reportError(EINVAL, in: &eventContext)
                return
            }
            #else
            if isServer {
                // Switch to server mode
                handshaker = SwiftTLSHandshaker.createServerHandshake()
            }
            #endif
            #endif

            // We currently assume QUIC-only
            guard let quicCrypto else {
                log.error("Failed to find QUIC crypto instance")
                reportError(EINVAL, in: &eventContext)
                return
            }

            // Link up the per-level handlers
            initialDataHandler.setParent(self, in: &eventContext)
            earlyDataHandler.setParent(self, in: &eventContext)
            handshakeDataHandler.setParent(self, in: &eventContext)
            applicationDataHandler.setParent(self, in: &eventContext)
            initialDataHandler.lower = quicCrypto
            quicCrypto.initialLinkage = initialDataHandler
            earlyDataHandler.lower = quicCrypto
            quicCrypto.earlyDataLinkage = earlyDataHandler
            handshakeDataHandler.lower = quicCrypto
            quicCrypto.handshakeLinkage = handshakeDataHandler
            applicationDataHandler.lower = quicCrypto
            quicCrypto.applicationLinkage = applicationDataHandler

            #if canImport(SwiftTLS) && SWIFTTLS_CERTIFICATE_VERIFICATION
            let target = AsyncContinuationTarget(self)
            asyncContinuationTarget = target
            handshaker.setAsyncContinuationHandler { result in
                guard let instance = target.instance else { return }
                instance.async { asyncContext in
                    guard let instance = target.instance else { return }
                    instance.handshaker.setAsyncResult(result)
                    do {
                        try instance.continueHandshake(in: &asyncContext)
                    } catch {
                        instance.log.error("Failed to continue handshake \(error)")
                        let handshakerErrorCode = instance.handshaker.errorCode
                        if handshakerErrorCode != 0 {
                            instance.reportError(handshakerErrorCode, in: &asyncContext)
                        }
                    }
                }
            }
            #endif

            if isServer {
                do {
                    let handshakeBytes = try handshaker.setupHandshake(options: options.tlsOptions)
                    guard handshakeBytes == nil else {
                        log.error("Server handshaker unexpectedly set up bytes")
                        reportError(EINVAL, in: &eventContext)
                        return
                    }
                } catch {
                    log.error("Failed to set up server handshaker")
                    reportError(EINVAL, in: &eventContext)
                    return
                }
            } else {
                guard let handshakeBytesToSend = try? handshaker.setupHandshake(options: options.tlsOptions) else {
                    log.error("Failed to set up client handshaker")
                    reportError(EINVAL, in: &eventContext)
                    return
                }

                sendMessage(handshakeBytesToSend, level: .initial, in: &eventContext)
            }

            // Update the encryption secrets for early data
            if handshaker.writeEncryptionLevel != .initial {
                if handshaker.writeEncryptionLevel == .earlyData,
                    let earlyDataTransportParameters = options.resumedQUICTransportParameters
                {
                    quicCrypto.updatePeerQUICTransportParameters(
                        earlyDataTransportParameters,
                        earlyData: true,
                        in: &eventContext
                    )
                }

                quicCrypto.updateNegotiatedCiphersuite(handshaker.negotiatedCiphersuite)
                if let readSecret = handshaker.readEncryptionSecret {
                    quicCrypto.updateSecret(
                        readSecret,
                        for: handshaker.readEncryptionLevel,
                        isWrite: false,
                        in: &eventContext
                    )
                }
                if let writeSecret = handshaker.writeEncryptionSecret {
                    quicCrypto.updateSecret(
                        writeSecret,
                        for: handshaker.writeEncryptionLevel,
                        isWrite: true,
                        in: &eventContext
                    )
                }
            }
        }

        // Application data never flows through the TLS instance in QUIC mode: QUIC carries the
        // records itself, so these stay unsupported rather than merely unimplemented.
        func sendStreamData(
            _ streamData: consuming FrameArray,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTSUP)
        }

        func sendStreamData(
            _ streamData: consuming FrameArray,
            from instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTSUP)
        }

        func getOutboundStreamDataRoomAvailable(
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> Int {
            throw NetworkError.posix(ENOTSUP)
        }

        func getOutboundStreamDataRoomAvailable(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> Int {
            throw NetworkError.posix(ENOTSUP)
        }

        func receiveStreamData(
            minimumBytes: Int,
            maximumBytes: Int,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            throw NetworkError.posix(ENOTSUP)
        }

        func receiveStreamData(
            minimumBytes: Int,
            maximumBytes: Int,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            throw NetworkError.posix(ENOTSUP)
        }

        func detach(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            upper = .init()
            teardownHandshake(in: &eventContext)
        }

        // The TLS instance is its own lower linkage, so this is the callback half of
        // `QUICCrypto.invokeAttachLowerProtocol`: bind the crypto object as the upper protocol
        // and run setup.
        func invokeAttachUpperProtocol(
            _ upperProtocol: QUICCrypto,
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            var mutableSelf = self
            try mutableSelf.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }
    #endif

    public func newPerProtocolOptions() -> SwiftTLSProtocolOptions? { SwiftTLSProtocolOptions() }
    public func newPerProtocolOptions(from existing: SwiftTLSProtocolOptions) -> SwiftTLSProtocolOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> SwiftTLSProtocolOptions? { nil }
    public func newPerProtocolMetadata() -> SwiftTLSMetadata? { SwiftTLSMetadata() }

    static public let identifier = ProtocolIdentifier(name: "swift-tls", level: .application, mapping: .oneToOne)
    #if !NETWORK_PRIVATE
    static let definition = ProtocolDefinition<SwiftTLSProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<SwiftTLSProtocol> { SwiftTLSProtocol.definition.protocolOptions() }

    #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
    final class SwiftTLSRecordLayerInstance<
        TLSUpperProtocol: InboundStreamLinkage,
        TLSLowerProtocol: OutboundStreamLinkage
    > {
        var handle: SwiftTLSRecordInstance<TLSUpperProtocol, TLSLowerProtocol>

        var tlsState: SwiftTLSRecordProtocolState {
            tlsManager.state
        }
        var isServer = false
        var tlsManager: SwiftTLSHandshakeAndRecordManager
        var options: SwiftTLSProtocolOptions
        var setConnectionClosed: Bool = false

        init(
            _ handle: SwiftTLSRecordInstance<TLSUpperProtocol, TLSLowerProtocol>,
            _ options: SwiftTLSProtocolOptions,
            _ parameters: Parameters?
        ) throws(NetworkError) {
            self.handle = handle
            self.options = options
            if let parameters {
                isServer = parameters.isServer
            }
            do {
                if isServer {
                    tlsManager = try SwiftTLSHandshakeAndRecordManager(options: options.tlsOptions, isServer: true)
                } else {
                    tlsManager = try SwiftTLSHandshakeAndRecordManager(options: options.tlsOptions, isServer: false)
                }
            } catch {
                handle.log.error("failed to initialize tls handshake and record manager: \(error)")
                throw NetworkError.posix(EINVAL)
            }
        }

        func teardown() {}

        // our upper protocol told us to disconnect
        // tls manager will handle sending close notify (if it is complete and we
        // haven't already sent an alert)
        func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
            handle.invokeDisconnect(error: error, in: &eventContext)  // call disconnect down the stack
        }

        func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
            try? readInputData(ignoreReadLimit: true, in: &eventContext)

            if !tlsManager.alertSentOrReceived {
                // if lower protocol disconnects without close notify or alert this is a potential truncation attack
                if tlsState == .handshake || tlsState == .connected {
                    handle.log.error("peer disconnected without sending a close notify or alert, potential truncation")
                    handle.deliverDisconnectedEvent(error: .tls(.tlsError), in: &eventContext)
                    return
                }
            } else if !setConnectionClosed {
                // if we received a close notify we want to make sure upper sees connectionClosed.
                // tell upper to read
                handle.deliverInboundDataAvailableEvent(in: &eventContext)
            }
            // default to pass through
            handle.deliverDisconnectedEvent(error: error, in: &eventContext)
        }

        // `connect` is called once our lower protocol is connected
        // It starts the TLS handshake
        // by sending the client hello if we are a client.
        func connect(in eventContext: inout NetworkContext.EventContext) {
            do {
                if !isServer {
                    try tlsManager.startHandshake()
                    // Send initial handshake data for client
                    try? sendAllOutgoingData(in: &eventContext)
                }
            } catch {
                handle.log.error("failed to start client handshake: \(error)")
                handle.invokeDisconnect(in: &eventContext)
            }
        }

        // called after handshake has completed successfully
        // lets our upper protocol
        // know that we are connected
        func completeHandshake(in eventContext: inout NetworkContext.EventContext) {
            handle.log.debug("handshake completed successfully")
            handle.deliverConnectedEvent(in: &eventContext)
        }

        // Helper function that sends all outgoing bytes in the
        // TLS manager (encrypted data or handshake bytes)
        func sendAllOutgoingData(in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
            if tlsManager.outgoingBytesCount > 0 {
                let outgoingByteCount = tlsManager.outgoingBytesCount
                handle.log.debug("sending \(outgoingByteCount) bytes of data")
                if let outgoingData = tlsManager.getOutput(numBytes: outgoingByteCount) {
                    try handle.invokeSendStreamData(
                        FrameArray(frame: Frame(copyBuffer: [UInt8](outgoingData))),
                        in: &eventContext
                    )
                }
            }
        }

        // upper protocol uses this callback to write data.
        // only works after handshake is complete
        func sendStreamData(
            _ streamData: consuming FrameArray,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            // readclosed is never set in SwiftTLS yet, but it indicates
            // we received a close notify (so peer is done sending data)
            // but we can theoretically still write data.
            guard tlsState == .connected || tlsState == .readclosed else {
                handle.log.error("sendStreamData failed - not connected")
                streamData.finalizeAllFramesAsFailed()
                throw NetworkError.posix(ENOTCONN)
            }

            var totalBytes = 0
            streamData.iterateMutableFrames { frame in
                do throws(SwiftTLSError) {
                    if let bytes = frame.span, !bytes.isEmpty {
                        totalBytes += bytes.count
                        try tlsManager.addApplicationData(bytes: [UInt8](copying: bytes, maxCount: bytes.count))
                    }
                    if frame.connectionComplete {
                        try tlsManager.sendCloseNotify()
                    }
                } catch {
                    handle.log.error("error adding application data \(error)")
                    frame.finalize(success: false)
                    return false
                }
                frame.finalize(success: true)
                return true
            }

            if streamData.unclaimedLength != 0 {
                // we did not finalize all frames and an error must have been hit
                streamData.finalizeAllFramesAsFailed()
                try? sendAllOutgoingData(in: &eventContext)  // send any pending alert bytes
                handle.invokeDisconnect(in: &eventContext)  // call disconnect down stack.
                return
            }

            handle.log.debug("sending \(totalBytes) bytes of application data")
            // Send any encrypted data that's ready
            try sendAllOutgoingData(in: &eventContext)
        }

        public func getOutboundStreamDataRoomAvailable(
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> Int {
            // how much we want to allow upper to queue
            Int(UInt16.max)
        }

        // Our upper protocol uses this callback to read data.
        // It requires the handshake has already completed.
        // It will return all decrypted application data.
        // If we don't have any available data then we try to read from our lower protocol first.
        // If we know that the other side has finished sending data by
        // sending a TLS alert (close notify or error alert) then the final
        // frame returned will have connectionComplete set.

        // If our peer disconnects with no alert (e.g. tcp reset),
        // connectionComplete will not be set on last frame passed up
        // since TLS does not know if that was actually the last byte
        // sent by the peer and we call disconnected up the stack.
        func receiveStreamData(
            minimumBytes: Int,
            maximumBytes: Int,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            // even if tlsState is now readClosed or disconnected there may be
            // application data buffered in the tlsManager waiting to be read
            guard tlsState != .initial && tlsState != .handshake else {
                handle.log.debug("handshake not completed yet - no application data to return")
                return nil
            }

            // Return any decrypted application data
            var availableDataLength = tlsManager.availableApplicationDataLength
            if availableDataLength == 0 {
                try readInputData(in: &eventContext)
                availableDataLength = tlsManager.availableApplicationDataLength
            }
            guard availableDataLength > 0 else {
                handle.log.debug("no decrypted application data available")
                return nil
            }

            let bytesToRead = min(availableDataLength, maximumBytes)
            handle.log.debug("returning \(bytesToRead) bytes of decrypted application data")
            // Check if input is finished:
            // either the peer sent a close notify or fatal alert, OR we sent a fatal alert.
            // If so, we set a connectionComplete flag on the final frame.
            if let decryptedData = tlsManager.getAvailableApplicationData(numBytes: bytesToRead) {
                var frame = Frame(copyBuffer: [UInt8](decryptedData))
                if (tlsManager.state == .readclosed || tlsManager.state == .disconnected)
                    && bytesToRead == availableDataLength
                {
                    frame.connectionComplete = true
                    setConnectionClosed = true
                }
                return FrameArray(frame: frame)
            } else if (tlsManager.state == .readclosed || tlsManager.state == .disconnected) && !setConnectionClosed {
                // we received a close notify and have no application data to send so send an empty frame with connection closed set
                var frame = Frame(copyBuffer: [UInt8]())
                frame.connectionComplete = true
                setConnectionClosed = true
                return FrameArray(frame: frame)
            }
            return nil
        }

        func readInputData(
            ignoreReadLimit: Bool = false,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            let availableAppDataLength = tlsManager.availableApplicationDataLength
            if !ignoreReadLimit && availableAppDataLength > SwiftTLSRecordProtocolMaxOutstandingReadBytes {
                handle.log.debug(
                    "readInputData - above maximum input threshold, skipping reading \(availableAppDataLength)"
                )
                return
            }
            let maxToRead =
                ignoreReadLimit
                ? availableAppDataLength : SwiftTLSRecordProtocolMaxOutstandingReadBytes - availableAppDataLength
            guard
                var receivedFrames = try handle.invokeReceiveStreamData(
                    minimumBytes: 1,
                    maximumBytes: maxToRead,
                    in: &eventContext
                )
            else {
                handle.log.debug("readInputData - no data available")
                return
            }

            guard tlsManager.state != .disconnected && tlsManager.state != .readclosed else {
                handle.log.debug("readInputData failed - called when tls manager in \(self.tlsManager.state) state.")
                receivedFrames.finalizeAllFramesAsFailed()
                return
            }

            var totalReceivedBytes = 0
            var generatedError = false
            let priorTLSState = tlsManager.state

            // Process all incoming network data
            while var frame = receivedFrames.popFirst() {
                do throws(SwiftTLSError) {
                    if var bytes = frame.mutableSpan, !bytes.isEmpty {
                        totalReceivedBytes += bytes.count
                        handle.log.debug("processing \(bytes.count) bytes of incoming data")
                        try bytes.withUnsafeMutableBytes { buffer throws(SwiftTLSError) in
                            try tlsManager.processNetworkData(networkDataIn: buffer)
                        }
                    }
                } catch {
                    handle.log.error("tls manager hit error while processing network data: \(error)")
                    if tlsManager.errorCode == swiftTLSRecordSuccessErrorCode {
                        // If we hit an error then the errorCode should always be set to something
                        preconditionFailure(
                            "tls manager hit error while processing network data, but errorCode not set: \(error)"
                        )
                    }
                    frame.finalize(success: false)
                    generatedError = true
                    break
                }
                frame.finalize(success: true)
            }

            if generatedError {
                // Finalize any unused frames
                receivedFrames.finalizeAllFramesAsFailed()
            }

            // Always try to sending any pending data
            try? sendAllOutgoingData(in: &eventContext)

            if tlsManager.state == .disconnected {
                let disconnectedError: NetworkError
                if priorTLSState == .handshake {
                    handle.log.debug("handshake failed")
                    disconnectedError = .tls(.handshakeFailed)
                } else {
                    handle.log.debug("tls failed")
                    disconnectedError = .tls(.tlsError)
                }
                handle.deliverDisconnectedEvent(error: disconnectedError, in: &eventContext)
                handle.invokeDisconnect(in: &eventContext)
                return
            }

            let justConnected = (priorTLSState == .handshake && tlsManager.state == .connected)
            if tlsManager.state == .handshake || justConnected {
                // Send any pending handshake data
                try? sendAllOutgoingData(in: &eventContext)
            }

            // Check if handshake completed
            if justConnected {
                handle.log.debug("handshake completed during receive")
                completeHandshake(in: &eventContext)
                // could change logic to notify when connected (by checking after each frame is processed)
            }
        }

        // called whenever our lower protocol has data ready to be delivered
        // we then use `readInputData` to read all available data.
        // If there is application data available for our upper protocol to read
        // then we let our upper protocol know.
        func handleInboundDataAvailableEvent(in eventContext: inout NetworkContext.EventContext) {
            let existingAppDataLength = tlsManager.availableApplicationDataLength
            do {
                try readInputData(in: &eventContext)
            } catch {
                return
            }
            let availableDataLength = tlsManager.availableApplicationDataLength
            // notify upper protocol if there is new application data available
            if availableDataLength > existingAppDataLength && availableDataLength > 0 {
                if tlsState != .initial && tlsState != .handshake {
                    handle.deliverInboundDataAvailableEvent(in: &eventContext)
                }
            }
        }
    }
    #endif

}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension ProtocolOptions<SwiftTLSProtocol> {
    public var tlsOptions: SwiftTLSProtocol.Options {
        get {
            perProtocolOptions ?? SwiftTLSProtocol.Options()
        }
        set {
            perProtocolOptions?.tlsOptions = newValue.tlsOptions
        }
    }
}

#if !IMPORT_SWIFTTLS || !canImport(SwiftTLS)

// Stubs for Swift TLS
enum SwiftTLSError: Int, Error, CustomStringConvertible {
    case handshakeFailed
    case invalidTransportParameters
    case internalTLSError

    var description: String {
        switch self {
        case .handshakeFailed: return "Handshake Failed"
        case .invalidTransportParameters: return "Invalid Transport Parameters"
        case .internalTLSError: return "TLS Error: Check error from SwiftTLS"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct SwiftTLSOptions {
    @frozen public enum EncryptionLevel: CustomDebugStringConvertible {
        case initial
        case earlyData
        case handshake
        case application

        public var debugDescription: String {
            switch self {
            case .initial: return "initial"
            case .earlyData: return "early data"
            case .handshake: return "handshake"
            case .application: return "application"
            }
        }
    }

    public var trustedRawPublicKeyCertificates: [[UInt8]]?
    public var rawPrivateKey: [UInt8]?
    public var quicTransportParameters: [UInt8]?
    public var enableEarlyData: Bool = false
    public var applicationProtocols: [String]?
    public var serverName: String? = nil
    public enum KeyExchangeGroup: UInt16 {
        case secp256 = 0x0017
        case secp384 = 0x0018
        case x25519 = 0x001D
        case x25519MLKEM768 = 0x11EC
    }
    public var keyExchangeGroup: KeyExchangeGroup = .secp384

    // When true, server sends CertificateRequest to client during TLS handshake
    public var clientAuthRequired: Bool = false

    public init() {}
}

@available(Network 0.1.0, *)
class SwiftTLSHandshaker {
    public static func createClientHandshake() -> SwiftTLSHandshaker {
        SwiftTLSHandshaker()
    }

    public static func createServerHandshake() -> SwiftTLSHandshaker {
        SwiftTLSHandshaker()
    }

    public var receivedSessionTickets = [[UInt8]]()

    public var errorCode: Int32 { 0 }

    public func setupHandshake(options: SwiftTLSOptions) throws -> [UInt8]? { nil }

    public var writeEncryptionLevel: SwiftTLSOptions.EncryptionLevel { .initial }

    public var readEncryptionLevel: SwiftTLSOptions.EncryptionLevel { .initial }

    public var negotiatedCiphersuite: Int { 0 }

    public var peerQUICTransportParameters: [UInt8]? { nil }

    public var earlyDataAccepted: Bool { false }

    public var readEncryptionSecret: [UInt8]? { nil }

    public var writeEncryptionSecret: [UInt8]? { nil }

    public func continueHandshake(with message: [UInt8]?) throws -> [UInt8]? { nil }
}
#endif
