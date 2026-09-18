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

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

#if IMPORT_CRYPTO || IMPORT_SWIFTTLS
#if canImport(CryptoKit)
internal import CryptoKit
#elseif canImport(Crypto)
@preconcurrency internal import Crypto
#endif
#endif

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

@available(Network 0.1.0, *)
final class QUICCrypto {
    var eventManager = ProtocolEventManager()

    var tlsInstance: SwiftTLSProtocol.SwiftTLSInstance

    var outboundCryptoInitialOffset: Int = 0
    var outboundCrypto1RTTOffset: Int = 0
    var outboundCryptoHandshakeOffset: Int = 0

    var parentConnection: QUICConnection?

    var tlsLinkage = OutboundStreamLinkage()  // Linkage for control path on top of TLS

    var initialLinkage = InboundStreamLinkage()
    var earlyDataLinkage = InboundStreamLinkage()
    var handshakeLinkage = InboundStreamLinkage()
    var applicationLinkage = InboundStreamLinkage()

    var initialReassemblyQueue = ReassemblyQueue()
    var handshakeReassemblyQueue = ReassemblyQueue()
    var applicationReassemblyQueue = ReassemblyQueue()

    var initialInboundData = FrameArray()
    var handshakeInboundData = FrameArray()
    var applicationInboundData = FrameArray()
    var initialOutboundData = StreamSendBuffer()
    var handshakeOutboundData = StreamSendBuffer()
    var applicationOutboundData = StreamSendBuffer()
    var initialOutboundDataOffset: UInt64 = 0
    var handshakeOutboundDataOffset: UInt64 = 0
    var applicationOutboundDataOffset: UInt64 = 0

    var ciphersuite: Int = 0

    var enableEarlyData = false

    static let bufferLimit: Int = 4 * 1024

    var asUpper: InboundStreamLinkage { .init(reference: reference) }
    var asLower: OutboundStreamLinkage { .init(reference: reference) }

    struct cryptoQueuedPackets {
    }
    var cryptoQueue = Deque<cryptoQueuedPackets>()

    init(context: NetworkContext) {
        tlsInstance = SwiftTLSProtocol.SwiftTLSInstance(context: context)
    }

    func start(
        with parentConnection: QUICConnection,
        tlsOptions inputTLSOptions: SwiftTLSProtocol.Options
    ) -> Bool {
        self.parentConnection = parentConnection

        initialReassemblyQueue.log = NetworkLoggerState("[TLS-Initial]")
        handshakeReassemblyQueue.log = NetworkLoggerState("[TLS-Handshake]")
        applicationReassemblyQueue.log = NetworkLoggerState("[TLS-Application]")

        enableEarlyData = inputTLSOptions.enableEarlyData

        // Set up values on tlsOptions
        var mutableTLSOptions = inputTLSOptions

        if let transportParameterBytes = try? parentConnection.localTransportParameters.serialize() {
            mutableTLSOptions.quicTransportParameters = transportParameterBytes
        }

        #if IMPORT_SWIFTTLS
        #if canImport(SwiftTLS)
        mutableTLSOptions.quicInstance = self
        #endif
        #endif

        let tlsOptions = SwiftTLSProtocol.options()
        tlsOptions.setLogID(
            prefix: "QUIC-TLS",
            parent: parentConnection.logIDString,
            protocolLogIDNumber: 0
        )
        tlsOptions.setProtocolInstance(tlsInstance.reference)
        tlsOptions.perProtocolOptions = mutableTLSOptions

        var tlsParameters = Parameters()
        tlsParameters.isServer = parentConnection.isServer
        tlsParameters.defaultStack.append(applicationProtocol: .swiftTLS(tlsOptions))
        do throws(NetworkError) {
            self.tlsLinkage = try self.tlsInstance.attachUpperStreamProtocol(
                reference,
                remote: nil,
                local: nil,
                parameters: tlsParameters,
                path: nil
            )
            try self.tlsInstance.attachLowerStreamProtocol(
                self.reference,
                remote: nil,
                local: nil,
                parameters: tlsParameters,
                path: nil
            )
        } catch {
            parentConnection.log.error("Failed to attach TLS protocol")
            return false
        }
        self.tlsLinkage.invokeConnect(reference)
        return true
    }

    func stop() {
        guard self.parentConnection != nil else {
            // Already stopped, ignore
            return
        }
        try? self.tlsLinkage.invokeDetach(reference)
        tlsLinkage = .init()

        initialInboundData.finalizeAllFramesAsFailed()
        handshakeInboundData.finalizeAllFramesAsFailed()
        applicationInboundData.finalizeAllFramesAsFailed()
        initialOutboundData.empty()
        handshakeOutboundData.empty()
        applicationOutboundData.empty()
        initialReassemblyQueue.dequeueAll()
        handshakeReassemblyQueue.dequeueAll()
        applicationReassemblyQueue.dequeueAll()

        self.parentConnection = nil
    }

    func currentOffset(for level: PacketNumberSpace) -> Int {
        switch level {
        case .initial:
            return outboundCryptoInitialOffset
        case .handshake:
            return outboundCryptoHandshakeOffset
        case .applicationData:
            return outboundCrypto1RTTOffset
        }
    }

    func sendAtLevel(_ level: PacketNumberSpace) {
        guard let parentConnection else {
            return
        }
        // Notify pending items that there are crypto bytes to get!
        if level == .initial {
            parentConnection.initialPendingItems.sendCrypto = true
        } else if level == .handshake {
            parentConnection.handshakePendingItems.sendCrypto = true
        } else {
            parentConnection.applicationPendingItems.sendCrypto = true
        }
        guard parentConnection.sendFrames() else {
            parentConnection.log.error("Unable to send Crypto Frames")
            return
        }
    }
}

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
extension QUICCrypto: SwiftTLSQUICInstance {
    func getLowerLinkage(
        for level: SwiftTLSOptions.EncryptionLevel,
        upperLinkage: InboundStreamLinkage
    ) -> OutboundStreamLinkage {
        switch level {
        case .initial: initialLinkage = upperLinkage
        case .earlyData: earlyDataLinkage = upperLinkage
        case .handshake: handshakeLinkage = upperLinkage
        case .application: applicationLinkage = upperLinkage
        }
        return asLower
    }

    func updateSecret(_ secret: [UInt8], for level: SwiftTLSOptions.EncryptionLevel, isWrite: Bool) {
        guard let parentConnection else { return }
        parentConnection.log.debug(
            "Got \(isWrite ? "write" : "read") secret update for level \(level.debugDescription)"
        )
        guard let tlsCiphersuite = TLSCipherSuite(sslCipherSuite: self.ciphersuite) else {
            return
        }
        parentConnection.protector.keyUpdate(
            for: TLSEncryptionLevel(level),
            cipherSuite: tlsCiphersuite,
            secret: SymmetricKey(data: secret),
            isWrite: isWrite
        )
        if level == .handshake {
            parentConnection.updateSecretForHandshakeLevel()
        }

        // Drop 0-RTT keys once 1-RTT keys are available.
        // NOTE: This only drops keys for clients; servers keep the
        // keys to be able to receive packets.
        if !parentConnection.isServer,
            parentConnection.protector.keysReady(for: .earlyData),
            parentConnection.protector.keysReady(for: .phase0)
        {
            parentConnection.protector.drop(keyState: .earlyData)
        }

        // Start the 0-RTT machinery when we first get 0-RTT write keys.
        if !parentConnection.earlyDataSignalled, parentConnection.state != .connected,
            parentConnection.protector.sealKeyReady(for: .earlyData)
        {

            guard let remoteTransportParameters = parentConnection.remoteTransportParameters,
                parentConnection.remoteTransportParametersForEarlyData
            else {
                parentConnection.log.error(
                    "Early data available without remote transport parameters"
                )
                return
            }

            parentConnection.log.debug("Signaling availability of early data")

            parentConnection.setupFlowControl(remoteTransportParameters: remoteTransportParameters)

            parentConnection.earlyDataSignalled = true
            parentConnection.readyAllOutboundStreams()
        }
    }

    func updateEncryptionLevel(_ level: SwiftTLSOptions.EncryptionLevel, isWrite: Bool) {
        parentConnection?.log.debug("Got encryption level update: \(level.debugDescription)")
    }

    func updateSessionTickets(_ sessionTicketArray: [[UInt8]]) {
        parentConnection?.log.debug("Got session tickets")
    }

    func updatePeerQUICTransportParameters(_ peerQUICTransportParameters: [UInt8], earlyData: Bool) {
        guard let parentConnection else {
            return
        }

        // Allow resetting if we now have non-early-data transport parameters
        guard
            parentConnection.remoteTransportParameters == nil
                || (!earlyData && parentConnection.remoteTransportParametersForEarlyData)
        else {
            return
        }

        // If the client has enabled early data, and we now have complete remote transport parameters,
        // send them up to allow the client to store them for future connections
        if !earlyData, !parentConnection.isServer, enableEarlyData {
            parentConnection.deliverNetworkProtocolEvent(
                flow: .allFlows,
                event: .init(
                    quicEvent: .receivedRemoteTransportParameters(
                        transportParameters: peerQUICTransportParameters
                    )
                )
            )
        }

        let parameterBytes = peerQUICTransportParameters.span
        do {
            let remoteTransportParameters = try TransportParameters.deserialize(
                parameterBytes,
                logPrefixer: parentConnection.logPrefixer
            )
            parentConnection.setRemoteTransportParameters(
                remoteTransportParameters,
                earlyData: earlyData
            )
        } catch {
            if earlyData {
                parentConnection.log.error(
                    "Failed to parse transport parameters for early data, ignoring: \(error)"
                )
            } else {
                parentConnection.log.error("Failed to parse transport parameters: \(error)")
                parentConnection.closeFrameType = .crypto
                parentConnection.close(
                    with:
                        .transportParameterError,
                    "Failed to deserialize transport parameters"
                )
            }
        }

        // Free up memory
        var peerQUICTransportParameters = peerQUICTransportParameters
        peerQUICTransportParameters.removeAll()
    }

    func updateEarlyDataAccepted(_ earlyDataAccepted: Bool) {
        guard let parentConnection, parentConnection.earlyDataSignalled else { return }
        parentConnection.log.debug("Got early data accepted: \(earlyDataAccepted)")
        parentConnection.updateEarlyDataAccepted(earlyDataAccepted)
    }

    func updateNegotiatedCiphersuite(_ ciphersuite: Int) {
        parentConnection?.log.debug("Got negotiated ciphersuite: \(ciphersuite)")
        self.ciphersuite = ciphersuite
    }
}
#endif
#endif

@available(Network 0.1.0, *)
extension QUICCrypto: TopStreamProtocol, ProtocolInstanceContainer {
    var context: NetworkContext { parentConnection!.context }

    var lower: OutboundStreamLinkage {
        get { tlsLinkage }
        set { tlsLinkage = newValue }
    }

    var reference: ProtocolInstanceReference { ProtocolInstanceReference(quicCrypto: self) }

    func handleConnectedEvent() {
        guard let parentConnection else { return }
        parentConnection.log.info("Connected: TLS finished")
        parentConnection.fromExternal {
            parentConnection.reportReady()
        }
    }

    func handleDisconnectedEvent(error: NetworkError?) {
        guard let parentConnection else { return }
        parentConnection.log.error("Disconnected: TLS error \(error?.description ?? "<none>")")
        parentConnection.closeFrameType = .crypto

        // Closing already being deferred, no need to schedule asynchronously
        if parentConnection.deferClosing {
            parentConnection.close(withCryptoError: 0, "TLS error")
        } else {
            parentConnection.deferClosing = true
            // Note that close(withCryptoError:) will set the error but not actually
            // close when deferClosing is set. We then async to complete closing.
            // This is done to avoid closing in the wrong protocol state and causing
            // re-entrancy.
            parentConnection.close(withCryptoError: 0, "TLS error")
            parentConnection.async {
                parentConnection.deferClosing = false
                if parentConnection.closeError != nil {
                    parentConnection.close()
                }
            }
        }
    }

    func handleApplicationEvent(_ from: ProtocolInstanceReference, event: ApplicationEvent) {
    }

    func appendInput(
        _ cryptoFrame: consuming FrameCrypto,
        for packetNumberSpace: PacketNumberSpace,
        reassemblyQueue: inout ReassemblyQueue,
        frameArray: inout FrameArray,
        linkage: InboundStreamLinkage
    ) -> Bool {

        let bufferLimitForPNSpace =
            packetNumberSpace == .handshake ? 2 * QUICCrypto.bufferLimit : QUICCrypto.bufferLimit
        guard reassemblyQueue.size <= bufferLimitForPNSpace else {
            parentConnection?.log.error(
                "Read crypto buffer size \(reassemblyQueue.size) is larger than limit \(bufferLimitForPNSpace)"
            )
            cryptoFrame.frame.finalize(success: false)
            return false
        }

        guard reassemblyQueue.canAppendItemsForByteLimit(UInt64(bufferLimitForPNSpace)).acceptable else {
            parentConnection?.log.error(
                "Read crypto buffer has too many items, closing"
            )
            cryptoFrame.frame.finalize(success: false)
            return false
        }

        reassemblyQueue.append(
            frame: cryptoFrame.frame,
            offset: Int(cryptoFrame.offset),
            fin: false
        )
        var wakeUp = false
        while let dequeueItem = reassemblyQueue.dequeue() {
            frameArray.add(frame: dequeueItem.frame)
            wakeUp = true
        }
        if wakeUp {
            linkage.deliverInboundDataAvailableEvent(reference)
        }
        return true
    }

    func appendInput(
        _ cryptoFrame: consuming FrameCrypto,
        for packetNumberSpace: PacketNumberSpace
    ) -> Bool {
        fromExternal(cryptoFrame) { cryptoFrame in
            switch packetNumberSpace {
            case .initial:
                return appendInput(
                    cryptoFrame,
                    for: packetNumberSpace,
                    reassemblyQueue: &initialReassemblyQueue,
                    frameArray: &initialInboundData,
                    linkage: initialLinkage
                )
            case .handshake:
                return appendInput(
                    cryptoFrame,
                    for: packetNumberSpace,
                    reassemblyQueue: &handshakeReassemblyQueue,
                    frameArray: &handshakeInboundData,
                    linkage: handshakeLinkage
                )
            case .applicationData:
                return appendInput(
                    cryptoFrame,
                    for: packetNumberSpace,
                    reassemblyQueue: &applicationReassemblyQueue,
                    frameArray: &applicationInboundData,
                    linkage: applicationLinkage
                )
            }
        }
    }
}

// Per-Level Sending Callbacks
@available(Network 0.1.0, *)
extension QUICCrypto: OutboundStreamHandler {
    #if !NETWORK_EMBEDDED
    func attachUpperProtocol<Linkage: LowerProtocolLinkage>(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> Linkage {
        asLower as! Linkage
    }
    #endif

    func attachUpperStreamProtocol(
        _ from: ProtocolInstanceReference,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) -> OutboundStreamLinkage {
        asLower
    }

    func detach(_ from: ProtocolInstanceReference) throws(NetworkError) {}

    func connect(_ from: ProtocolInstanceReference) {
        InboundStreamLinkage(reference: from).deliverConnectedEvent(reference)
    }

    func disconnect(_ from: ProtocolInstanceReference, error: NetworkError?) {}
    func handleNetworkProtocolEvent(
        _ from: ProtocolInstanceReference,
        event: NetworkProtocolEvent
    ) {}
    func getMetadata<P>(_ from: ProtocolInstanceReference) -> ProtocolMetadata<P>?
    where P: NetworkProtocol { nil }
    func getMetrics(
        _ from: ProtocolInstanceReference,
        requestedNetworkMetric: RequestedNetworkMetrics
    ) -> NetworkMetrics? {
        nil
    }
    func levelForReference(_ from: ProtocolInstanceReference) -> SwiftTLSOptions.EncryptionLevel? {
        if from == initialLinkage.reference { return .initial }
        if from == earlyDataLinkage.reference { return .earlyData }
        if from == handshakeLinkage.reference { return .handshake }
        if from == applicationLinkage.reference { return .application }
        return nil
    }

    func packetNumberSpaceForReference(_ from: ProtocolInstanceReference) -> PacketNumberSpace? {
        if from == initialLinkage.reference { return .initial }
        if from == handshakeLinkage.reference { return .handshake }
        if from == applicationLinkage.reference { return .applicationData }
        if from == earlyDataLinkage.reference { return .applicationData }
        return nil
    }

    func receiveStreamData(
        _ from: ProtocolInstanceReference,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws(NetworkError) -> FrameArray? {
        guard let level = levelForReference(from) else {
            throw NetworkError.posix(EINVAL)
        }
        if level == .initial {
            return initialInboundData.drainArray()
        } else if level == .handshake {
            return handshakeInboundData.drainArray()
        } else if level == .application {
            return applicationInboundData.drainArray()
        }
        throw NetworkError.posix(EINVAL)
    }

    func getOutboundStreamDataRoomAvailable(
        _ from: ProtocolInstanceReference
    ) throws(NetworkError) -> Int {
        guard let _ = levelForReference(from) else {
            throw NetworkError.posix(EINVAL)
        }
        return Int(UInt16.max)
    }

    func sendStreamData(
        _ from: ProtocolInstanceReference,
        streamData: consuming FrameArray
    ) throws(NetworkError) {
        guard let level = packetNumberSpaceForReference(from) else {
            streamData.finalizeAllFramesAsFailed()
            throw NetworkError.posix(EINVAL)
        }
        switch level {
        case .initial:
            initialOutboundData.addSendData(streamData, isLast: false)
        case .handshake:
            handshakeOutboundData.addSendData(streamData, isLast: false)
        case .applicationData:
            applicationOutboundData.addSendData(streamData, isLast: false)
        }
        sendAtLevel(level)
    }

    func copyOutSendData(
        for packetNumberSpace: PacketNumberSpace,
        offset: StreamOffset,
        length: StreamLength,
        into frame: inout Frame
    ) -> StreamLength {
        guard let parentConnection else {
            return 0
        }
        switch packetNumberSpace {
        case .initial:
            return initialOutboundData.copyOutSendData(
                offset: offset,
                length: length,
                into: &frame,
                log: parentConnection.log
            )
        case .handshake:
            return handshakeOutboundData.copyOutSendData(
                offset: offset,
                length: length,
                into: &frame,
                log: parentConnection.log
            )
        case .applicationData:
            return applicationOutboundData.copyOutSendData(
                offset: offset,
                length: length,
                into: &frame,
                log: parentConnection.log
            )
        }
    }

    func remainingOutboundData(
        for packetNumberSpace: PacketNumberSpace
    ) -> (StreamLength, StreamOffset) {
        switch packetNumberSpace {
        case .initial:
            return (
                initialOutboundData.remainingDataLengthToService(
                    currentSendOffset: initialOutboundDataOffset
                ), initialOutboundDataOffset
            )
        case .handshake:
            return (
                handshakeOutboundData.remainingDataLengthToService(
                    currentSendOffset: handshakeOutboundDataOffset
                ), handshakeOutboundDataOffset
            )
        case .applicationData:
            return (
                applicationOutboundData.remainingDataLengthToService(
                    currentSendOffset: applicationOutboundDataOffset
                ), applicationOutboundDataOffset
            )
        }
    }

    func incrementOutboundOffset(for packetNumberSpace: PacketNumberSpace, by offset: StreamOffset) {
        switch packetNumberSpace {
        case .initial: initialOutboundDataOffset += offset
        case .handshake: handshakeOutboundDataOffset += offset
        case .applicationData: applicationOutboundDataOffset += offset
        }
    }

    func storageOutboundStartOffset(for packetNumberSpace: PacketNumberSpace) -> UInt64 {
        switch packetNumberSpace {
        case .initial: initialOutboundData.storageStartOffset
        case .handshake: handshakeOutboundData.storageStartOffset
        case .applicationData: applicationOutboundData.storageStartOffset
        }
    }

    func acknowledged(
        offset: UInt64,
        length: UInt64,
        for packetNumberSpace: PacketNumberSpace
    ) {
        guard let parentConnection else { return }
        switch packetNumberSpace {
        case .initial:
            _ = initialOutboundData.acknowledgedSendData(offset: offset, length: length, log: parentConnection.log)
        case .handshake:
            _ = handshakeOutboundData.acknowledgedSendData(offset: offset, length: length, log: parentConnection.log)
        case .applicationData:
            _ = applicationOutboundData.acknowledgedSendData(offset: offset, length: length, log: parentConnection.log)
        }
    }
}
#endif
