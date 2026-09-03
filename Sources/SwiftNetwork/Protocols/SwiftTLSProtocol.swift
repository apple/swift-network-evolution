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
            // need to be duplicated here and in nwswifttls.m/nwswifttlsrecord.m
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
