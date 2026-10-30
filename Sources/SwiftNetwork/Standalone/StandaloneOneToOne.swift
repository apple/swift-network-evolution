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

#if !NETWORK_EMBEDDED && !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Synchronization) && canImport(Dispatch)

// MARK: - UDP

/// A UDP protocol instance that its owner drives directly.
///
/// The owner writes datagrams from above and reads those UDP delivers, hands UDP packets that arrive
/// from the network (IP datagrams' UDP payloads and headers, as UDP expects them) and collects what
/// UDP wants to send. See `StandaloneQUICConnection` for the loop.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandaloneUDP: StandaloneOneToOneDatagramProtocol, ~Copyable {
    public let environment: StandaloneEnvironment

    private let storage: BaseNetworkProtocolStorage
    private let upper: StandaloneFlowLink
    private let lower: StandaloneLowerLink

    private var context: NetworkContext { environment.context }

    /// Creates a UDP instance between `local` and `remote`.
    public init(
        options: ProtocolOptions<UDPProtocol> = UDPProtocol.options(),
        local: Endpoint,
        remote: Endpoint,
        environment: StandaloneEnvironment
    ) throws(NetworkError) {
        let context = environment.context
        let storage = BaseNetworkProtocolStorage(context: context)
        let (udpUpper, udpLower) = storage.createUDPInstance()
        options.setProtocolInstance(udpUpper.identifier)

        var parameters = Parameters(context: context)
        parameters.defaultStack.transport = .udp(options)
        let path = PathProperties(parameters: parameters)

        let upper = StandaloneFlowLink.make(
            kind: .datagram,
            hasFlowID: false,
            reportsConnectionEvents: true,
            in: &context.eventContext
        )
        let lower = StandaloneLowerLink.make(kind: .datagram, pathID: nil, in: &context.eventContext)

        do throws(NetworkError) {
            try upper.invokeAttachLowerProtocol(
                udpLower,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            try udpUpper.invokeAttachLowerProtocol(
                lower.outboundDatagram,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            context.eventContext.standaloneUnregisterLink(identifier: upper.identifier, slot: upper.slot)
            context.eventContext.standaloneUnregisterLink(identifier: lower.identifier, slot: lower.slot)
            throw error
        }

        self.environment = environment
        self.storage = storage
        self.upper = upper
        self.lower = lower
    }

    deinit {
        let context = environment.context
        let upper = upper
        upper.identifier.fromExternal(in: &context.eventContext) { eventContext in
            upper.teardown(in: &eventContext)
        }
        upper.free(in: &context.eventContext)
        lower.free(in: &context.eventContext)
    }

    public consuming func close() {
        // The work is in `deinit`, which runs as this call ends.
    }

    public func connect() {
        upper.connect(context: context)
    }

    public func disconnect(error: NetworkError?) {
        upper.disconnect(error: error, context: context)
    }

    public func applicationEvent(_ event: ApplicationEvent) {
        upper.applicationEvent(event, context: context)
    }

    public func getMetrics(_ requested: RequestedNetworkMetrics) -> NetworkMetrics? {
        upper.getMetrics(requested, context: context)
    }

    public func receiveFromBelow(_ frames: consuming FrameArray) {
        lower.receive(frames, context: context)
    }

    public func takeOutbound() -> FrameArray {
        lower.takeOutbound(context: context)
    }

    public func deliverNetworkEvent(_ event: NetworkProtocolEvent) {
        lower.deliverNetworkProtocolEvent(event, context: context)
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        try upper.getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            context: context
        )
    }

    public func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        try upper.sendDatagrams(datagrams, context: context)
    }

    public func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
        try upper.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, context: context)
    }
}

// MARK: - TLS record layer

#if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)

/// A record-layer TLS instance that its owner drives directly.
///
/// The application above writes and reads cleartext; TLS turns it into records that the owner moves
/// to and from the network below, and runs the handshake in between. The handshake is driven by
/// `receiveFromBelow` and `takeOutbound`, so two instances can be joined by shuttling packets.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandaloneTLSRecord: StandaloneOneToOneStreamProtocol, ~Copyable {
    public let environment: StandaloneEnvironment

    private let storage: BaseNetworkProtocolStorage
    private let upper: StandaloneFlowLink
    private let lower: StandaloneLowerLink

    private var context: NetworkContext { environment.context }

    /// Creates a TLS instance. `options` must not be shared with another instance.
    public init(
        options: ProtocolOptions<SwiftTLSProtocol>,
        isServer: Bool,
        local: Endpoint,
        remote: Endpoint,
        environment: StandaloneEnvironment
    ) throws(NetworkError) {
        let context = environment.context
        let storage = BaseNetworkProtocolStorage(context: context)
        let (tlsUpper, tlsLower) = storage.createSwiftTLSRecordInstance()
        options.setProtocolInstance(tlsLower.identifier)

        var parameters = Parameters(context: context)
        parameters.isServer = isServer
        parameters.defaultStack.prepend(applicationProtocol: options)
        let path = PathProperties(parameters: parameters)

        let upper = StandaloneFlowLink.make(
            kind: .stream,
            hasFlowID: false,
            reportsConnectionEvents: true,
            in: &context.eventContext
        )
        let lower = StandaloneLowerLink.make(kind: .stream, pathID: nil, in: &context.eventContext)

        do throws(NetworkError) {
            try upper.invokeAttachLowerProtocol(
                tlsLower,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            try tlsUpper.invokeAttachLowerProtocol(
                lower.outboundStream,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch {
            context.eventContext.standaloneUnregisterLink(identifier: upper.identifier, slot: upper.slot)
            context.eventContext.standaloneUnregisterLink(identifier: lower.identifier, slot: lower.slot)
            throw error
        }

        self.environment = environment
        self.storage = storage
        self.upper = upper
        self.lower = lower
    }

    deinit {
        let context = environment.context
        let upper = upper
        upper.identifier.fromExternal(in: &context.eventContext) { eventContext in
            upper.teardown(in: &eventContext)
        }
        upper.free(in: &context.eventContext)
        lower.free(in: &context.eventContext)
    }

    public consuming func close() {
        // The work is in `deinit`, which runs as this call ends.
    }

    public func connect() {
        upper.connect(context: context)
    }

    public func disconnect(error: NetworkError?) {
        upper.disconnect(error: error, context: context)
    }

    public func applicationEvent(_ event: ApplicationEvent) {
        upper.applicationEvent(event, context: context)
    }

    public func getMetrics(_ requested: RequestedNetworkMetrics) -> NetworkMetrics? {
        upper.getMetrics(requested, context: context)
    }

    public func receiveFromBelow(_ frames: consuming FrameArray) {
        lower.receive(frames, context: context)
    }

    public func takeOutbound() -> FrameArray {
        lower.takeOutbound(context: context)
    }

    public func deliverNetworkEvent(_ event: NetworkProtocolEvent) {
        lower.deliverNetworkProtocolEvent(event, context: context)
    }

    public func sendStreamData(_ streamData: consuming FrameArray, early: Bool) throws(NetworkError) {
        try upper.sendStream(streamData, early: early, context: context)
    }

    public func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
        try upper.receiveStream(minimumBytes: minimumBytes, maximumBytes: maximumBytes, context: context)
    }

    public func outboundRoomAvailable() throws(NetworkError) -> Int {
        try upper.outboundRoomAvailable(context: context)
    }

    public func abortInbound(error: NetworkError?) throws(NetworkError) {
        try upper.abortInbound(error: error, context: context)
    }

    public func abortOutbound(error: NetworkError?) throws(NetworkError) {
        try upper.abortOutbound(error: error, context: context)
    }
}

#endif  // HAS_SWIFTTLS_RECORD

#endif
