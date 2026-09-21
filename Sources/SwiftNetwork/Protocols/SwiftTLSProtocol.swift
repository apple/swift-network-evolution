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

@available(Network 0.1.0, *)
protocol SwiftTLSQUICInstance: AnyObject {
    func getLowerLinkage(
        for level: SwiftTLSOptions.EncryptionLevel,
        upperLinkage: InboundStreamLinkage
    ) -> OutboundStreamLinkage
    func updateSecret(_ secret: [UInt8], for level: SwiftTLSOptions.EncryptionLevel, isWrite: Bool)
    func updateEncryptionLevel(_ level: SwiftTLSOptions.EncryptionLevel, isWrite: Bool)
    func updateSessionTickets(_ sessionTicketArray: [[UInt8]])
    func updatePeerQUICTransportParameters(_ peerQUICTransportParameters: [UInt8], earlyData: Bool)
    func updateEarlyDataAccepted(_ earlyDataAccepted: Bool)
    func updateNegotiatedCiphersuite(_ ciphersuite: Int)
}

let SwiftTLSRecordProtocolMaxOutstandingReadBytes: Int = (8 * 1024 * 1024)  // 8MB

// Wrapper to send a value. Ensures that the value is only accessed
// from the context and fails otherwise.
@available(Network 0.1.0, *)
private struct ContextBound<Value>: @unchecked Sendable {
    public let context: NetworkContext

    @usableFromInline
    var _value: Value

    @inlinable
    public init(_ value: Value, context: NetworkContext) {
        context.assert()
        self.context = context
        self._value = value
    }

    @inlinable
    public var value: Value {
        get {
            self.context.assert()
            return self._value
        }
        _modify {
            self.context.assert()
            yield &self._value
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct SwiftTLSProtocol: NetworkProtocol {
    public typealias Options = SwiftTLSProtocolOptions
    public typealias Metadata = SwiftTLSMetadata
    typealias Instance = SwiftTLSInstance

    public init() {}

    public struct SwiftTLSProtocolOptions: PerProtocolOptions {
        var quicInstance: (any SwiftTLSQUICInstance)?

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
            // Note: quicInstance is intentionally not copied - it's set by Crypto.start()
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

    enum SwiftTLSInstanceType {
        case quicHandshakeOnly(SwiftTLSQUICOnlyInstance)
        #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
        case recordLayerTLS(SwiftTLSRecordLayerInstance)
        #endif
    }

    final class SwiftTLSInstance: OneToOneStreamProtocol, ProtocolInstanceContainer {

        var metadata: AbstractProtocolMetadata?
        var upper = InboundStreamLinkage()
        var lower = OutboundStreamLinkage()
        private(set) var context: NetworkContext
        var reference: ProtocolInstanceReference { ProtocolInstanceReference(tls: self) }
        var passthroughEvents = false
        var log = NetworkLoggerState()
        var eventManager = ProtocolEventManager()

        private var instanceType: SwiftTLSInstanceType?

        init(context: NetworkContext) {
            self.context = context
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
                let options = tlsOptions(from: parameters),
                let protocolOptions = options.perProtocolOptions
            else {
                throw NetworkError.posix(EINVAL)
            }

            if protocolOptions.tlsOptions.quicTransportParameters == nil {
                #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
                // use record layer instance if no quic transport params provided
                let instance = try SwiftTLSRecordLayerInstance(self, protocolOptions, parameters)
                instanceType = .recordLayerTLS(instance)
                #else
                throw NetworkError.posix(EINVAL)
                #endif
            } else {
                let instance = SwiftTLSQUICOnlyInstance(self, protocolOptions, parameters)
                instanceType = .quicHandshakeOnly(instance)
            }
        }

        func teardown() {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(let instance):
                instance.teardown()
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                instance.teardown()
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
            instanceType = nil
        }

        func connect() {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(let instance):
                instance.connect()
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                instance.connect()
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }

        func disconnect(error: NetworkError?) {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(_):
                invokeDisconnect(error: error)  // pass through
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                instance.disconnect(error: error)
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }

        func handleDisconnectedEvent(error: NetworkError?) {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(_):
                deliverDisconnectedEvent(error: error)  // pass through
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                instance.handleDisconnectedEvent(error: error)
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }

        func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(let instance):
                try instance.sendStreamData(streamData)
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                try instance.sendStreamData(streamData)
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }

        func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(let instance):
                return try instance.getOutboundStreamDataRoomAvailable()
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                return try instance.getOutboundStreamDataRoomAvailable()
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }

        func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(let instance):
                return try instance.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                return try instance.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes)
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }

        func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
            log.debug("")
            switch instanceType {
            case .quicHandshakeOnly(_):
                return
            #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
            case .recordLayerTLS(let instance):
                return instance.handleInboundDataAvailableEvent(from)
            #endif
            case .none:
                preconditionFailure("instanceType unexpectedly nil")
            }
        }
    }

    final class SwiftTLSQUICOnlyInstance {
        var handle: SwiftTLSInstance

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
        var options: SwiftTLSProtocolOptions

        fileprivate init(_ handle: SwiftTLSInstance, _ options: SwiftTLSProtocolOptions, _ parameters: Parameters?) {
            self.handle = handle
            self.options = options
            if let parameters {
                isServer = parameters.isServer
            }
        }

        final class EncryptionLevelHandler: TopStreamProtocol, ProtocolInstanceContainer {
            var lower = OutboundStreamLinkage()

            let level: SwiftTLSOptions.EncryptionLevel
            var parentInstance: SwiftTLSQUICOnlyInstance?
            public var context: NetworkContext { parentInstance!.handle.context }

            public var reference: ProtocolInstanceReference {
                var reference = ProtocolInstanceReference(tlsEncryptionLevel: self)
                if let parentInstance {
                    reference.parentReference = parentInstance.handle.reference
                }
                return reference
            }

            var eventManager = ProtocolEventManager()

            init(level: SwiftTLSOptions.EncryptionLevel) { self.level = level }

            func destroy() {
                if !lower.isDetached {
                    try? lower.invokeDetach(reference)
                    lower = OutboundStreamLinkage()
                }
                parentInstance = nil
            }

            func handleInboundDataAvailableEvent() {
                guard !lower.isDetached, let parentInstance else {
                    return
                }
                let frameArray = try? lower.invokeReceiveStreamData(reference, minimumBytes: 1, maximumBytes: Int.max)
                guard var frameArray else {
                    return
                }

                while var frame = frameArray.popFirst() {
                    if let bytes = frame.span, !bytes.isEmpty {
                        do {
                            try parentInstance.continueHandshake(with: [UInt8](copying: bytes, maxCount: bytes.count))
                        } catch {
                            parentInstance.handle.log.error("Failed to continue handshake \(error)")
                            let handshakerErrorCode = parentInstance.handshaker.errorCode
                            if handshakerErrorCode != 0 {
                                parentInstance.reportError(handshakerErrorCode)
                            }
                        }
                    } else {
                        frame.finalize(success: false)
                        continue
                    }

                    frame.finalize(success: true)
                }
            }

            func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
                guard !lower.isDetached else {
                    throw NetworkError.posix(EINVAL)
                }
                return try lower.invokeGetOutboundStreamDataRoomAvailable(reference)
            }

            func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
                guard !lower.isDetached else {
                    streamData.finalizeAllFramesAsFailed()
                    throw NetworkError.posix(EINVAL)
                }
                try lower.invokeSendStreamData(reference, streamData: streamData)
            }
        }

        let initialDataHandler = EncryptionLevelHandler(level: .initial)
        let earlyDataHandler = EncryptionLevelHandler(level: .earlyData)
        let handshakeDataHandler = EncryptionLevelHandler(level: .handshake)
        let applicationDataHandler = EncryptionLevelHandler(level: .application)

        func continueHandshake(with message: [UInt8]? = nil) throws(TLSNetworkError) {
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
                if let quicInstance = options.quicInstance {
                    if handshaker.earlyDataAccepted {
                        quicInstance.updateEarlyDataAccepted(true)
                    }

                    if let peerQUICTransportParameters = handshaker.peerQUICTransportParameters {
                        quicInstance.updatePeerQUICTransportParameters(peerQUICTransportParameters, earlyData: false)
                    }

                    let hasWriteEncryptionLevel = (handshaker.writeEncryptionLevel != .initial)
                    let hasReadEncryptionLevel = (handshaker.readEncryptionLevel != .initial)
                    if hasWriteEncryptionLevel || hasReadEncryptionLevel {
                        quicInstance.updateNegotiatedCiphersuite(handshaker.negotiatedCiphersuite)
                        if hasReadEncryptionLevel, let readSecret = handshaker.readEncryptionSecret {
                            quicInstance.updateSecret(readSecret, for: handshaker.readEncryptionLevel, isWrite: false)
                        }
                        if hasWriteEncryptionLevel, let writeSecret = handshaker.writeEncryptionSecret {
                            quicInstance.updateSecret(writeSecret, for: handshaker.writeEncryptionLevel, isWrite: true)
                        }
                    }

                    if !handshaker.receivedSessionTickets.isEmpty {
                        let ticketArray = handshaker.receivedSessionTickets
                        handshaker.receivedSessionTickets = [[UInt8]]()
                        quicInstance.updateSessionTickets(ticketArray)
                    }
                }

                if let dataToSend {
                    if isServer {
                        if serverSentHello {
                            sendMessage(dataToSend, level: .handshake)
                        } else {
                            serverSentHello = true
                            sendMessage(dataToSend, level: .initial)
                        }
                    } else {
                        sendMessage(dataToSend, level: .handshake)
                    }
                } else if handshaker.errorCode != 0 {
                    reportError(handshaker.errorCode)
                }

                if isServer {
                    if handshaker.readEncryptionLevel == .application {
                        completeHandshake()
                    }
                } else {
                    if handshaker.writeEncryptionLevel == .application {
                        completeHandshake()
                    }
                }
            }
        }

        func completeHandshake() {
            let newlyConnected = !isConnected
            isConnected = true

            handle.deliverConnectedEvent()
            if !isServer, newlyConnected, let quicInstance = options.quicInstance, !handshaker.earlyDataAccepted {
                quicInstance.updateEarlyDataAccepted(false)
            }
        }

        func reportError(_ error: Int32) {
            handle.log.error("Reporting TLS error \(error)")
            handle.deliverDisconnectedEvent(error: NetworkError.posix(error))
        }

        func sendMessage(_ message: [UInt8], level: SwiftTLSOptions.EncryptionLevel) {
            let encryptionLevelHandler: EncryptionLevelHandler
            switch level {
            case .initial: encryptionLevelHandler = initialDataHandler
            case .earlyData: encryptionLevelHandler = earlyDataHandler
            case .handshake: encryptionLevelHandler = handshakeDataHandler
            case .application: encryptionLevelHandler = applicationDataHandler
            }

            try? encryptionLevelHandler.sendStreamData(FrameArray(frame: Frame(copyBuffer: message)))
        }

        func teardown() {
            #if canImport(SwiftTLS) && SWIFTTLS_CERTIFICATE_VERIFICATION
            handshaker.setAsyncContinuationHandler(nil)
            #endif
            initialDataHandler.destroy()
            handshakeDataHandler.destroy()
            earlyDataHandler.destroy()
            applicationDataHandler.destroy()
            options.quicInstance = nil
        }

        func connect() {
            guard !isConnected else {
                // Already connected, report
                handle.deliverConnectedEvent()
                return
            }

            guard !startedHandshake else {
                // Already started, ignore
                return
            }

            startedHandshake = true
            #if CLIENT_ONLY
            if isServer {
                handle.log.error("Server TLS not supported")
                reportError(EINVAL)
                return
            }
            #else
            #if SERVER_ONLY
            if !isServer {
                handle.log.error("Client TLS not supported")
                reportError(EINVAL)
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
            guard let quicInstance = options.quicInstance else {
                handle.log.error("Failed to find QUIC instance on TLS options")
                reportError(EINVAL)
                return
            }

            // Link up the per-level handlers
            initialDataHandler.parentInstance = self
            earlyDataHandler.parentInstance = self
            handshakeDataHandler.parentInstance = self
            applicationDataHandler.parentInstance = self
            initialDataHandler.lower = quicInstance.getLowerLinkage(
                for: .initial,
                upperLinkage: initialDataHandler.asUpper
            )
            earlyDataHandler.lower = quicInstance.getLowerLinkage(
                for: .earlyData,
                upperLinkage: earlyDataHandler.asUpper
            )
            handshakeDataHandler.lower = quicInstance.getLowerLinkage(
                for: .handshake,
                upperLinkage: handshakeDataHandler.asUpper
            )
            applicationDataHandler.lower = quicInstance.getLowerLinkage(
                for: .application,
                upperLinkage: applicationDataHandler.asUpper
            )

            #if canImport(SwiftTLS) && SWIFTTLS_CERTIFICATE_VERIFICATION
            let contextBoundSelf = ContextBound(self, context: self.handle.context)
            handshaker.setAsyncContinuationHandler { result in
                contextBoundSelf.value.handle.async {
                    contextBoundSelf.value.handshaker.setAsyncResult(result)
                    do {
                        try contextBoundSelf.value.continueHandshake()
                    } catch {
                        contextBoundSelf.value.handle.log.error("Failed to continue handshake \(error)")
                        let handshakerErrorCode = contextBoundSelf.value.handshaker.errorCode
                        if handshakerErrorCode != 0 {
                            contextBoundSelf.value.reportError(handshakerErrorCode)
                        }
                    }
                }
            }
            #endif

            if isServer {
                do {
                    let handshakeBytes = try handshaker.setupHandshake(options: options.tlsOptions)
                    guard handshakeBytes == nil else {
                        handle.log.error("Server handshaker unexpectedly set up bytes")
                        reportError(EINVAL)
                        return
                    }
                } catch {
                    handle.log.error("Failed to set up server handshaker")
                    reportError(EINVAL)
                    return
                }
            } else {
                guard let handshakeBytesToSend = try? handshaker.setupHandshake(options: options.tlsOptions) else {
                    handle.log.error("Failed to set up client handshaker")
                    reportError(EINVAL)
                    return
                }

                sendMessage(handshakeBytesToSend, level: .initial)
            }

            // Update the encryption secrets for early data
            if handshaker.writeEncryptionLevel != .initial {
                if handshaker.writeEncryptionLevel == .earlyData,
                    let earlyDataTransportParameters = options.resumedQUICTransportParameters
                {
                    quicInstance.updatePeerQUICTransportParameters(earlyDataTransportParameters, earlyData: true)
                }

                quicInstance.updateNegotiatedCiphersuite(handshaker.negotiatedCiphersuite)
                if let readSecret = handshaker.readEncryptionSecret {
                    quicInstance.updateSecret(readSecret, for: handshaker.readEncryptionLevel, isWrite: false)
                }
                if let writeSecret = handshaker.writeEncryptionSecret {
                    quicInstance.updateSecret(writeSecret, for: handshaker.writeEncryptionLevel, isWrite: true)
                }
            }
        }

        func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(ENOTSUP)
        }

        func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
            throw NetworkError.posix(ENOTSUP)
        }

        func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
            throw NetworkError.posix(ENOTSUP)
        }
    }

    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        SwiftTLSInstance(context: context).reference
    }

    public func newPerProtocolOptions() -> SwiftTLSProtocolOptions? { SwiftTLSProtocolOptions() }
    public func newPerProtocolOptions(from existing: SwiftTLSProtocolOptions) -> SwiftTLSProtocolOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> SwiftTLSProtocolOptions? { nil }
    public func newPerProtocolMetadata() -> SwiftTLSMetadata? { SwiftTLSMetadata() }

    static public let identifier = ProtocolIdentifier(name: "swift-tls", level: .application, mapping: .oneToOne)
    #if !NETWORK_PRIVATE
    static let definition = ProtocolDefinition<SwiftTLSProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<SwiftTLSProtocol> { SwiftTLSProtocol.definition.protocolOptions() }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        SwiftTLSProtocol().newProtocolInstance(context: context)!
    }

    #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)
    final class SwiftTLSRecordLayerInstance {
        var handle: SwiftTLSInstance

        var tlsState: SwiftTLSRecordProtocolState {
            tlsManager.state
        }
        var isServer = false
        var tlsManager: SwiftTLSHandshakeAndRecordManager
        var options: SwiftTLSProtocolOptions
        var setConnectionClosed: Bool = false

        #if !os(Linux) && !NETWORK_STANDALONE
        static let successErrorCode = errSecSuccess
        #else
        static let successErrorCode = 0
        #endif

        init(
            _ handle: SwiftTLSInstance,
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
        func disconnect(error: NetworkError?) {
            handle.invokeDisconnect(error: error)  // call disconnect down the stack
        }

        func handleDisconnectedEvent(error: NetworkError?) {
            try? readInputData(ignoreReadLimit: true)

            if !tlsManager.alertSentOrReceived {
                // if lower protocol disconnects without close notify or alert this is a potential truncation attack
                if tlsState == .handshake || tlsState == .connected {
                    handle.log.error("peer disconnected without sending a close notify or alert, potential truncation")
                    handle.deliverDisconnectedEvent(error: .tls(.tlsError))
                    return
                }
            } else if !setConnectionClosed {
                // if we received a close notify we want to make sure upper sees connectionClosed.
                // tell upper to read
                handle.deliverInboundDataAvailableEvent()
            }
            // default to pass through
            handle.deliverDisconnectedEvent(error: error)
        }

        // `connect` is called once our lower protocol is connected
        // It starts the TLS handshake
        // by sending the client hello if we are a client.
        func connect() {
            do {
                if !isServer {
                    try tlsManager.startHandshake()
                    // Send initial handshake data for client
                    try? sendAllOutgoingData()
                }
            } catch {
                handle.log.error("failed to start client handshake: \(error)")
                handle.invokeDisconnect()
            }
        }

        // called after handshake has completed successfully
        // lets our upper protocol
        // know that we are connected
        func completeHandshake() {
            handle.log.debug("handshake completed successfully")
            handle.deliverConnectedEvent()
        }

        // Helper function that sends all outgoing bytes in the
        // TLS manager (encrypted data or handshake bytes)
        func sendAllOutgoingData() throws(NetworkError) {
            if tlsManager.outgoingBytesCount > 0 {
                let outgoingByteCount = tlsManager.outgoingBytesCount
                handle.log.debug("sending \(outgoingByteCount) bytes of data")
                if let outgoingData = tlsManager.getOutput(numBytes: outgoingByteCount) {
                    try handle.invokeSendStreamData(FrameArray(frame: Frame(copyBuffer: [UInt8](outgoingData))))
                }
            }
        }

        // upper protocol uses this callback to write data.
        // only works after handshake is complete
        func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
            // readclosed is never set in SwiftTLS yet, but it indicates
            // we received a close notify (so peer is done sending data)
            // but we can theoretically still write data.
            guard tlsState == .connected || tlsState == .readclosed else {
                handle.log.error("sendStreamData failed - not connected")
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
                try? sendAllOutgoingData()  // send any pending alert bytes
                handle.invokeDisconnect()  // call disconnect down stack.
                return
            }

            handle.log.debug("sending \(totalBytes) bytes of application data")
            // Send any encrypted data that's ready
            try sendAllOutgoingData()
        }

        public func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
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
        func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
            // even if tlsState is now readClosed or disconnected there may be
            // application data buffered in the tlsManager waiting to be read
            guard tlsState != .initial && tlsState != .handshake else {
                handle.log.debug("handshake not completed yet - no application data to return")
                return nil
            }

            // Return any decrypted application data
            var availableDataLength = tlsManager.availableApplicationDataLength
            if availableDataLength == 0 {
                try readInputData()
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

        func readInputData(ignoreReadLimit: Bool = false) throws(NetworkError) {
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
            guard var receivedFrames = try handle.invokeReceiveStreamData(minimumBytes: 1, maximumBytes: maxToRead)
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
                    if tlsManager.errorCode == Self.successErrorCode {
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
            try? sendAllOutgoingData()

            if tlsManager.state == .disconnected {
                let disconnectedError: NetworkError
                if priorTLSState == .handshake {
                    handle.log.debug("handshake failed")
                    disconnectedError = .tls(.handshakeFailed)
                } else {
                    handle.log.debug("tls failed")
                    disconnectedError = .tls(.tlsError)
                }
                handle.deliverDisconnectedEvent(error: disconnectedError)
                handle.invokeDisconnect()
                return
            }

            let justConnected = (priorTLSState == .handshake && tlsManager.state == .connected)
            if tlsManager.state == .handshake || justConnected {
                // Send any pending handshake data
                try? sendAllOutgoingData()
            }

            // Check if handshake completed
            if justConnected {
                handle.log.debug("handshake completed during receive")
                completeHandshake()
                // could change logic to notify when connected (by checking after each frame is processed)
            }
        }

        // called whenever our lower protocol has data ready to be delivered
        // we then use `readInputData` to read all available data.
        // If there is application data available for our upper protocol to read
        // then we let our upper protocol know.
        func handleInboundDataAvailableEvent(_ from: ProtocolInstanceReference) {
            let existingAppDataLength = tlsManager.availableApplicationDataLength
            do {
                try readInputData()
            } catch {
                return
            }
            let availableDataLength = tlsManager.availableApplicationDataLength
            // notify upper protocol if there is new application data available
            if availableDataLength > existingAppDataLength && availableDataLength > 0 {
                if tlsState != .initial && tlsState != .handshake {
                    handle.deliverInboundDataAvailableEvent()
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
