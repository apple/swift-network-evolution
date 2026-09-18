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

// Buffer limit for crypto reassembly. Lives outside QUICCrypto because a generic type
// cannot have static stored properties.
@available(Network 0.1.0, *)
enum QUICCryptoConstants {
    static let bufferLimit: Int = 4 * 1024
}

@available(Network 0.1.0, *)
final class QUICCrypto<Families: LinkageFamilyGroup> {
    var eventManager = ProtocolEventManager()

    var identifier: InstanceIdentifier

    var tlsInstance: SwiftTLSProtocol.SwiftTLSQUICOnlyInstance<Families>!

    var outboundCryptoInitialOffset: Int = 0
    var outboundCrypto1RTTOffset: Int = 0
    var outboundCryptoHandshakeOffset: Int = 0

    var parentConnection: QUICConnection<Families>?

    var tlsLinkage: LowerProtocol?  // Linkage for control path on top of TLS

    var initialLinkage: UpperProtocol?
    var earlyDataLinkage: UpperProtocol?
    var handshakeLinkage: UpperProtocol?
    var applicationLinkage: UpperProtocol?

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

    init() {
        identifier = .init()
        tlsInstance = nil
    }

    init(context: NetworkContext) {
        identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
        tlsInstance = SwiftTLSProtocol.SwiftTLSQUICOnlyInstance<Families>(
            context: context,
            quicCrypto: self
        )
    }

    /// Registers using an event context the caller already holds, so the state isn't re-derived
    /// from the context. Use this when replacing the crypto instance from inside the stack, such
    /// as when restarting the handshake after version negotiation or a retry.
    init(context: NetworkContext, in eventContext: inout NetworkContext.EventContext) {
        identifier = InstanceIdentifier(
            eventManager: &self.eventManager,
            context: context,
            in: &eventContext
        )
        tlsInstance = SwiftTLSProtocol.SwiftTLSQUICOnlyInstance<Families>(
            context: context,
            quicCrypto: self,
            in: &eventContext
        )
    }

    func start(
        with parentConnection: QUICConnection<Families>,
        tlsOptions inputTLSOptions: SwiftTLSProtocol.Options,
        in eventContext: inout NetworkContext.EventContext
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

        let tlsOptions = SwiftTLSProtocol.options()
        tlsOptions.setLogID(
            prefix: "QUIC-TLS",
            parent: parentConnection.logIDString,
            protocolLogIDNumber: 0
        )
        tlsOptions.setProtocolInstance(tlsInstance.identifier)
        tlsOptions.perProtocolOptions = mutableTLSOptions

        var tlsParameters = Parameters()
        tlsParameters.isServer = parentConnection.isServer
        tlsParameters.defaultStack.append(applicationProtocol: .swiftTLS(tlsOptions))
        do throws(NetworkError) {
            // Attach from this side (the upper protocol) so both directions are bound:
            // `invokeAttachLowerProtocol` sets `lower` (and therefore `tlsLinkage`) and calls
            // back into `attachUpperProtocol` on the TLS instance. Calling
            // `tlsInstance.attachUpperProtocol` directly would leave `tlsLinkage` nil, so the
            // `invokeConnect` below would silently do nothing and the handshake never starts.
            try self.invokeAttachLowerProtocol(
                tlsInstance,
                remote: nil,
                local: nil,
                parameters: tlsParameters,
                path: nil
            )
        } catch {
            parentConnection.log.error("Failed to attach TLS protocol")
            return false
        }
        self.tlsLinkage?.invokeConnect(for: identifier, in: &eventContext)
        return true
    }

    /// Stops using an event context the caller already holds.
    func stop(in eventContext: inout NetworkContext.EventContext) {
        guard self.parentConnection != nil else {
            // Never started, or already stopped. Both this object and the TLS instance register
            // their event states at init, before `start`, so they still have to be handed back.
            tlsInstance?.teardown(in: &eventContext)
            teardown(in: &eventContext)
            return
        }
        try? self.tlsLinkage?.invokeDetach(for: identifier, in: &eventContext)
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

        // Nothing sits above this crypto object, so no lower linkage ever detaches it and calls
        // `teardown(in:)`. Detaching the TLS instance above releases the encryption-level
        // handlers, which is what `teardown(in:)` waits on, so run it here.
        teardown(in: &eventContext)

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

    func sendAtLevel(_ level: PacketNumberSpace, in eventContext: inout NetworkContext.EventContext) {
        guard let parentConnection else {
            return
        }
        markSendPending(level, on: parentConnection)
        guard parentConnection.sendFrames(in: &eventContext) else {
            parentConnection.log.error("Unable to send Crypto Frames")
            return
        }
    }

    // Notify pending items that there are crypto bytes to get!
    private func markSendPending(_ level: PacketNumberSpace, on parentConnection: QUICConnection<Families>) {
        if level == .initial {
            parentConnection.initialPendingItems.sendCrypto = true
        } else if level == .handshake {
            parentConnection.handshakePendingItems.sendCrypto = true
        } else {
            parentConnection.applicationPendingItems.sendCrypto = true
        }
    }
}

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
extension QUICCrypto {
    func updateSecret(
        _ secret: [UInt8],
        for level: SwiftTLSOptions.EncryptionLevel,
        isWrite: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) {
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

            parentConnection.setupFlowControl(
            remoteTransportParameters: remoteTransportParameters,
            in: &eventContext
        )

            parentConnection.earlyDataSignalled = true
            parentConnection.readyAllOutboundStreams(in: &eventContext)
        }
    }

    func updateEncryptionLevel(_ level: SwiftTLSOptions.EncryptionLevel, isWrite: Bool) {
        parentConnection?.log.debug("Got encryption level update: \(level.debugDescription)")
    }

    func updateSessionTickets(_ sessionTicketArray: [[UInt8]]) {
        parentConnection?.log.debug("Got session tickets")
    }

    func updatePeerQUICTransportParameters(
        _ peerQUICTransportParameters: [UInt8],
        earlyData: Bool,
        in eventContext: inout NetworkContext.EventContext
    ) {
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
                ),
                in: &eventContext
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
                earlyData: earlyData,
                in: &eventContext
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
                    "Failed to deserialize transport parameters",
                    in: &eventContext
                )
            }
        }

        // Free up memory
        var peerQUICTransportParameters = peerQUICTransportParameters
        peerQUICTransportParameters.removeAll()
    }

    func updateEarlyDataAccepted(_ earlyDataAccepted: Bool, in eventContext: inout NetworkContext.EventContext) {
        guard let parentConnection, parentConnection.earlyDataSignalled else { return }
        parentConnection.log.debug("Got early data accepted: \(earlyDataAccepted)")
        parentConnection.updateEarlyDataAccepted(earlyDataAccepted, in: &eventContext)
    }

    func updateNegotiatedCiphersuite(_ ciphersuite: Int) {
        parentConnection?.log.debug("Got negotiated ciphersuite: \(ciphersuite)")
        self.ciphersuite = ciphersuite
    }
}
#endif
#endif

@available(Network 0.1.0, *)
extension QUICCrypto: InboundStreamLinkage, OutboundStreamLinkage, ProtocolInstanceAsLinkage {
    // TLS Instance is our "lower protocol", only one overall.
    typealias PairedLowerLinkage = SwiftTLSProtocol.SwiftTLSQUICOnlyInstance<Families>

    // TLS Encryption Handler is our "upper protocol", one per encryption level.
    typealias PairedUpperLinkage = SwiftTLSProtocol.SwiftTLSQUICOnlyInstance<Families>.EncryptionLevelHandler

    // Binds both directions: set the TLS instance as our lower protocol, then call back into it
    // so it takes this crypto object as its upper protocol and runs setup.
    func invokeAttachLowerProtocol(_ lowerProtocol: PairedLowerLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        var mutableSelf = self
        let overrideUpperLinkage = try mutableSelf.attachLowerProtocol(lowerProtocol)
        _ = overrideUpperLinkage
        try lowerProtocol.invokeAttachUpperProtocol(
            self,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func invokeAttachUpperProtocol(_ upperProtocol: PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        // Every encryption level has to be done with this crypto object before its event
        // state can go away.
        guard initialLinkage == nil, earlyDataLinkage == nil, handshakeLinkage == nil,
            applicationLinkage == nil
        else { return }
        unregisterEventManager(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension QUICCrypto: TopStreamProtocol {
    typealias LinkageType = QUICCrypto<Families>
    typealias LowerProtocol = PairedLowerLinkage

    var context: NetworkContext { parentConnection!.context }

    var lower: LowerProtocol {
        get {
            if let tlsLinkage {
                return tlsLinkage
            }
            return .init()
        }
        set { tlsLinkage = newValue }
    }

    func handleConnectedEvent(in eventContext: inout NetworkContext.EventContext) {
        guard let parentConnection else { return }
        parentConnection.log.info("Connected: TLS finished")
        parentConnection.reportReady(in: &eventContext)
    }

    func handleDisconnectedEvent(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        guard let parentConnection else { return }
        parentConnection.log.error("Disconnected: TLS error \(error?.description ?? "<none>")")
        parentConnection.closeFrameType = .crypto

        // Closing already being deferred, no need to schedule asynchronously
        if parentConnection.deferClosing {
            parentConnection.close(withCryptoError: 0, "TLS error", in: &eventContext)
        } else {
            parentConnection.deferClosing = true
            // Note that close(withCryptoError:) will set the error but not actually
            // close when deferClosing is set. We then async to complete closing.
            // This is done to avoid closing in the wrong protocol state and causing
            // re-entrancy.
            parentConnection.close(withCryptoError: 0, "TLS error", in: &eventContext)
            parentConnection.async { asyncState in
                parentConnection.deferClosing = false
                if parentConnection.closeError != nil {
                    parentConnection.close(sendCloseFrame: true, in: &asyncState)
                }
            }
        }
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
    }

    func appendInput(
        _ cryptoFrame: consuming FrameCrypto,
        for packetNumberSpace: PacketNumberSpace,
        reassemblyQueue: inout ReassemblyQueue,
        frameArray: inout FrameArray,
        linkage: UpperProtocol?,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        guard let linkage else {
            return false
        }
        let bufferLimitForPNSpace =
            packetNumberSpace == .handshake ? 2 * QUICCryptoConstants.bufferLimit : QUICCryptoConstants.bufferLimit
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
            linkage.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
        }
        return true
    }

    /// Appends crypto input using an event context the caller already holds.
    ///
    /// Enters this instance's event scope with `handleCallFromUpperProtocol` so events queued
    /// while appending are delivered — without it the instance is still `idle` and queuing
    /// traps.
    func appendInput(
        _ cryptoFrame: consuming FrameCrypto,
        for packetNumberSpace: PacketNumberSpace,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        identifier.handleCallFromUpperProtocol(cryptoFrame, in: &eventContext) { eventContext, cryptoFrame in
            appendInputInScope(cryptoFrame, for: packetNumberSpace, in: &eventContext)
        }
    }

    private func appendInputInScope(
        _ cryptoFrame: consuming FrameCrypto,
        for packetNumberSpace: PacketNumberSpace,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        switch packetNumberSpace {
        case .initial:
            return appendInput(
                cryptoFrame,
                for: packetNumberSpace,
                reassemblyQueue: &initialReassemblyQueue,
                frameArray: &initialInboundData,
                linkage: initialLinkage,
                in: &eventContext
            )
        case .handshake:
            return appendInput(
                cryptoFrame,
                for: packetNumberSpace,
                reassemblyQueue: &handshakeReassemblyQueue,
                frameArray: &handshakeInboundData,
                linkage: handshakeLinkage,
                in: &eventContext
            )
        case .applicationData:
            return appendInput(
                cryptoFrame,
                for: packetNumberSpace,
                reassemblyQueue: &applicationReassemblyQueue,
                frameArray: &applicationInboundData,
                linkage: applicationLinkage,
                in: &eventContext
            )
        }
    }
}

// Per-Level Sending Callbacks
@available(Network 0.1.0, *)
extension QUICCrypto: OutboundStreamHandler {
    typealias UpperProtocol = PairedUpperLinkage

    func attachUpperProtocol(
        _ upperProtocol: UpperProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
    }

    // One crypto object backs all four TLS encryption-level handlers, so each of them detaches
    // from it in turn. Drop the linkage that is going away; `teardown` releases the event state
    // once the last one is gone.
    func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        if instance == initialLinkage?.identifier { initialLinkage = nil }
        if instance == earlyDataLinkage?.identifier { earlyDataLinkage = nil }
        if instance == handshakeLinkage?.identifier { handshakeLinkage = nil }
        if instance == applicationLinkage?.identifier { applicationLinkage = nil }
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        if let initialLinkage, instance == initialLinkage.identifier { initialLinkage.deliverConnectedEvent(from: identifier, in: &eventContext) }
        if let earlyDataLinkage, instance == earlyDataLinkage.identifier { earlyDataLinkage.deliverConnectedEvent(from: identifier, in: &eventContext) }
        if let handshakeLinkage, instance == handshakeLinkage.identifier { handshakeLinkage.deliverConnectedEvent(from: identifier, in: &eventContext) }
        if let applicationLinkage, instance == applicationLinkage.identifier { applicationLinkage.deliverConnectedEvent(from: identifier, in: &eventContext) }
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {}
    func getMetadata<P>(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) -> ProtocolMetadata<P>?
    where P: NetworkProtocol { nil }
    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        nil
    }
    func encryptionLevel(for instance: InstanceIdentifier) -> SwiftTLSOptions.EncryptionLevel? {
        if instance == initialLinkage?.identifier { return .initial }
        if instance == earlyDataLinkage?.identifier { return .earlyData }
        if instance == handshakeLinkage?.identifier { return .handshake }
        if instance == applicationLinkage?.identifier { return .application }
        return nil
    }

    func packetNumberSpace(for instance: InstanceIdentifier) -> PacketNumberSpace? {
        if instance == initialLinkage?.identifier { return .initial }
        if instance == handshakeLinkage?.identifier { return .handshake }
        if instance == applicationLinkage?.identifier { return .applicationData }
        if instance == earlyDataLinkage?.identifier { return .applicationData }
        return nil
    }

    func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        guard let level = encryptionLevel(for: instance) else {
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
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        guard let _ = encryptionLevel(for: instance) else {
            throw NetworkError.posix(EINVAL)
        }
        return Int(UInt16.max)
    }

    func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        guard let level = packetNumberSpace(for: instance) else {
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
        sendAtLevel(level, in: &eventContext)
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
