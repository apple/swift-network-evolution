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

#if !NETWORK_EMBEDDED && !NETWORK_PRIVATE && !NETWORK_STANDALONE && !NETWORK_NO_SWIFT_QUIC
#if canImport(Synchronization) && canImport(Dispatch)

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A QUIC connection that its owner drives directly.
///
/// The owner creates the connection with its options, calls `connect()`, and from then on is the
/// application above (streams and datagram flows), the network below (paths), and the scheduler
/// (timers and asyncs). After each call into the connection, the owner asks the environment what
/// the connection wants:
///
/// - `environment.nextTimerDeadline`: a timer to set.
/// - `environment.needsAsync`: a call back as soon as possible.
/// - `environment.drainEvents`: connected, new flow, data available, connection ID and path events.
/// - `takeOutbound(path:)`: datagrams to send on the network.
/// - `receiveStreamData(flow:...)` and `receiveDatagrams(flow:...)`: data to deliver to the
///   application.
///
/// The connection and its environment belong to one execution context.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandaloneQUICConnection: StandaloneManyToManyProtocol, ~Copyable {
    public let environment: StandaloneEnvironment

    private let storage: BaseNetworkProtocolStorage
    private let streamListener: BaseStreamListenerLinkage
    private let datagramListener: BaseDatagramListenerLinkage
    private let multipath: BaseDatagramMultipathLinkage
    private let streamConnection: StandaloneConnectionLink
    private let datagramConnection: StandaloneConnectionLink?
    private var paths: [StandalonePathID: StandaloneLowerLink] = [:]
    private let parameters: Parameters
    private let pathProperties: PathProperties
    private let localEndpoint: Endpoint
    private let remoteEndpoint: Endpoint
    private let releasesFlowsOnDisconnect: Bool

    /// The path created with the connection, from the endpoints it was given.
    public let primaryPath: StandalonePathID

    private var context: NetworkContext { environment.context }

    /// Creates a connection and its first path.
    ///
    /// - Parameters:
    ///   - options: The QUIC options, including TLS options. The connection claims them: they
    ///     must not be shared with another connection.
    ///   - isServer: Whether this side accepts the connection.
    ///   - local: The local endpoint of the first path.
    ///   - remote: The remote endpoint of the first path.
    ///   - environment: The clock, timers and events this connection runs on.
    ///   - acceptsInboundDatagramFlows: Whether datagram flows the peer opens are reported with
    ///     `newInboundFlow`.
    ///   - releasesFlowsOnDisconnect: Whether a flow is detached and freed as its `disconnected` event
    ///     is taken from the queue, so the owner does not call `teardown(flow:)` for it. The flow
    ///     accepts no calls after that event.
    public init(
        options: ProtocolOptions<QUICProtocol>,
        isServer: Bool,
        local: Endpoint,
        remote: Endpoint,
        environment: StandaloneEnvironment,
        acceptsInboundDatagramFlows: Bool = false,
        releasesFlowsOnDisconnect: Bool = false
    ) throws(NetworkError) {
        let context = environment.context
        let storage = BaseNetworkProtocolStorage(context: context)
        let (streamListener, datagramListener, multipath) = storage.createQUICInstance()
        options.setProtocolInstance(streamListener.identifier)

        var parameters = Parameters(context: context)
        parameters.isServer = isServer
        parameters.defaultStack.transport = .quic(options)
        let pathProperties = PathProperties(parameters: parameters)

        let streamConnection = StandaloneConnectionLink.make(
            kind: .stream,
            reportsConnectionEvents: true,
            in: &context.eventContext
        )
        let datagramConnection: StandaloneConnectionLink? =
            acceptsInboundDatagramFlows
            ? StandaloneConnectionLink.make(
                kind: .datagram,
                reportsConnectionEvents: false,
                in: &context.eventContext
            ) : nil
        context.eventContext.standaloneLinks[streamConnection.slot].releasesFlowsOnDisconnect =
            releasesFlowsOnDisconnect
        if let datagramConnection {
            context.eventContext.standaloneLinks[datagramConnection.slot].releasesFlowsOnDisconnect =
                releasesFlowsOnDisconnect
        }
        let primaryPathID = context.eventContext.standaloneMakePathID()
        let pathLink = StandaloneLowerLink.make(kind: .datagram, pathID: primaryPathID, in: &context.eventContext)

        do throws(NetworkError) {
            try streamConnection.invokeAttachLowerProtocol(
                streamListener,
                remote: remote,
                local: local,
                parameters: parameters,
                path: pathProperties
            )
            if let datagramConnection {
                try datagramConnection.invokeAttachLowerProtocol(
                    datagramListener,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: pathProperties
                )
            }
            var multipath = multipath
            try Self.attachPath(
                pathLink,
                storage: storage,
                multipath: &multipath,
                remote: remote,
                local: local,
                parameters: parameters,
                path: pathProperties
            )
        } catch {
            // Nothing is built on the failed attach, so hand back what it registered.
            context.eventContext.standaloneUnregisterLink(
                identifier: streamConnection.identifier,
                slot: streamConnection.slot
            )
            if let datagramConnection {
                context.eventContext.standaloneUnregisterLink(
                    identifier: datagramConnection.identifier,
                    slot: datagramConnection.slot
                )
            }
            context.eventContext.standaloneUnregisterLink(identifier: pathLink.identifier, slot: pathLink.slot)
            throw error
        }

        self.environment = environment
        self.storage = storage
        self.streamListener = streamListener
        self.datagramListener = datagramListener
        self.multipath = multipath
        self.streamConnection = streamConnection
        self.datagramConnection = datagramConnection
        self.paths = [primaryPathID: pathLink]
        self.parameters = parameters
        self.pathProperties = pathProperties
        self.localEndpoint = local
        self.remoteEndpoint = remote
        self.releasesFlowsOnDisconnect = releasesFlowsOnDisconnect
        self.primaryPath = primaryPathID
    }

    /// Attaches a path link below the connection and tells the link which path is above it.
    ///
    /// QUIC attaches a lower from inside a call that holds the event context, so the link cannot
    /// record its upper at attach. The path QUIC built for it is found afterwards.
    private static func attachPath(
        _ link: StandaloneLowerLink,
        storage: BaseNetworkProtocolStorage,
        multipath: inout BaseDatagramMultipathLinkage,
        remote: Endpoint,
        local: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) throws(NetworkError) {
        try multipath.invokeAttachLowerProtocolForNewPath(
            link.outboundDatagramSuppliedUpper,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
        guard let connection = storage.quicInstance(for: multipath) else { throw NetworkError.posix(ENOENT) }
        for quicPath in connection.multiplexingPaths.values where quicPath.lower.identifier == link.identifier {
            link.supplyUpper(quicPath.asUpperLinkage(), context: storage.context)
            return
        }
        throw NetworkError.posix(ENOENT)
    }

    deinit {
        shutdown()
    }

    /// Detaches every flow and the connection, then frees the links.
    ///
    /// Detaching the last upper protocol is what lets the connection retire its paths, timers and
    /// crypto state.
    private func shutdown() {
        let context = environment.context
        for flow in context.eventContext.standaloneAllFlowLinks() {
            flow.identifier.fromExternal(in: &context.eventContext) { eventContext in
                flow.teardown(in: &eventContext)
            }
            flow.free(in: &context.eventContext)
        }
        for connection in [Optional(streamConnection), datagramConnection] {
            guard let connection else { continue }
            connection.identifier.fromExternal(in: &context.eventContext) { eventContext in
                connection.teardown(in: &eventContext)
            }
            connection.free(in: &context.eventContext)
        }
        // The connection's teardown retires its paths.
        for (_, path) in paths {
            path.free(in: &context.eventContext)
        }
    }

    public consuming func close() {
        // The work is in `deinit`, which runs as this call ends, so that dropping a connection
        // without closing it releases the same things.
    }

    // MARK: - Connection

    public func connect() {
        let listener = streamListener
        let link = streamConnection
        listener.invokeConnect(for: link.identifier, in: &context.eventContext)
    }

    public func disconnect(error: NetworkError?) {
        let listener = streamListener
        let link = streamConnection
        listener.invokeDisconnect(error: error, for: link.identifier, in: &context.eventContext)
    }

    public func applicationEvent(_ event: ApplicationEvent) {
        let listener = streamListener
        let link = streamConnection
        listener.invokeApplicationEvent(event: event, for: link.identifier, in: &context.eventContext)
    }

    public func getMetrics(_ requested: RequestedNetworkMetrics) -> NetworkMetrics? {
        let listener = streamListener
        let link = streamConnection
        return listener.invokeGetMetrics(
            requestedNetworkMetric: requested,
            for: link.identifier,
            in: &context.eventContext
        )
    }

    public var isFullyDetached: Bool {
        storage.quicInstance(for: streamListener)?.isFullyDetached ?? true
    }

    // MARK: - Flows

    private func flowLink(_ flow: StandaloneFlowID) throws(NetworkError) -> StandaloneFlowLink {
        guard let link = context.eventContext.standaloneFlowLink(flow) else { throw NetworkError.posix(ENOENT) }
        return link
    }

    public func openStream() throws(NetworkError) -> StandaloneFlowID {
        let link = StandaloneFlowLink.make(
            kind: .stream,
            hasFlowID: true,
            reportsConnectionEvents: false,
            in: &context.eventContext
        )
        let flowID = StandaloneFlowID(slot: link.slot)
        context.eventContext.standaloneLinks[link.slot].releasesFlowsOnDisconnect = releasesFlowsOnDisconnect
        do throws(NetworkError) {
            try streamListener.invokeAttachUpperProtocolToNewFlow(
                link.inboundStream,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: pathProperties
            )
        } catch {
            context.eventContext.standaloneUnregisterLink(identifier: link.identifier, slot: link.slot)
            throw error
        }
        return flowID
    }

    public func openDatagramFlow() throws(NetworkError) -> StandaloneFlowID {
        let link = StandaloneFlowLink.make(
            kind: .datagram,
            hasFlowID: true,
            reportsConnectionEvents: false,
            in: &context.eventContext
        )
        let flowID = StandaloneFlowID(slot: link.slot)
        context.eventContext.standaloneLinks[link.slot].releasesFlowsOnDisconnect = releasesFlowsOnDisconnect
        do throws(NetworkError) {
            try datagramListener.invokeAttachUpperProtocolToNewFlow(
                link.inboundDatagram,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: pathProperties
            )
        } catch {
            context.eventContext.standaloneUnregisterLink(identifier: link.identifier, slot: link.slot)
            throw error
        }
        return flowID
    }

    public func connect(flow: StandaloneFlowID) {
        try? flowLink(flow).connect(context: context)
    }

    public func disconnect(flow: StandaloneFlowID, error: NetworkError?) {
        try? flowLink(flow).disconnect(error: error, context: context)
    }

    public func teardown(flow: StandaloneFlowID) {
        guard let link = context.eventContext.standaloneFlowLink(flow) else { return }
        link.teardown(in: &context.eventContext)
        link.free(in: &context.eventContext)
    }

    public func applicationEvent(flow: StandaloneFlowID, _ event: ApplicationEvent) {
        try? flowLink(flow).applicationEvent(event, context: context)
    }

    public func getMetadata<P: NetworkProtocol>(flow: StandaloneFlowID) -> ProtocolMetadata<P>? {
        try? flowLink(flow).getMetadata(context: context)
    }

    // MARK: - From the application

    public func sendStreamData(
        flow: StandaloneFlowID,
        _ streamData: consuming FrameArray,
        early: Bool
    ) throws(NetworkError) {
        let link: StandaloneFlowLink
        do {
            link = try flowLink(flow)
        } catch {
            streamData.finalizeAllFramesAsFailed()
            throw error
        }
        try link.sendStream(streamData, early: early, context: context)
    }

    public func receiveStreamData(
        flow: StandaloneFlowID,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws(NetworkError) -> FrameArray? {
        try flowLink(flow).receiveStream(minimumBytes: minimumBytes, maximumBytes: maximumBytes, context: context)
    }

    public func abortInbound(flow: StandaloneFlowID, error: NetworkError?) throws(NetworkError) {
        try flowLink(flow).abortInbound(error: error, context: context)
    }

    public func abortOutbound(flow: StandaloneFlowID, error: NetworkError?) throws(NetworkError) {
        try flowLink(flow).abortOutbound(error: error, context: context)
    }

    public func getDatagramsToSend(
        flow: StandaloneFlowID,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        try flowLink(flow).getDatagramsToSend(
            maximumDatagramCount: maximumDatagramCount,
            minimumDatagramSize: minimumDatagramSize,
            context: context
        )
    }

    public func sendDatagrams(flow: StandaloneFlowID, _ datagrams: consuming FrameArray) throws(NetworkError) {
        let link: StandaloneFlowLink
        do {
            link = try flowLink(flow)
        } catch {
            datagrams.finalizeAllFramesAsFailed()
            throw error
        }
        try link.sendDatagrams(datagrams, context: context)
    }

    public func receiveDatagrams(
        flow: StandaloneFlowID,
        maximumDatagramCount: Int
    ) throws(NetworkError) -> FrameArray? {
        try flowLink(flow).receiveDatagrams(maximumDatagramCount: maximumDatagramCount, context: context)
    }

    // MARK: - Paths and the network below

    public mutating func addPath(local: Endpoint, remote: Endpoint) throws(NetworkError) -> StandalonePathID {
        let pathID = context.eventContext.standaloneMakePathID()
        let link = StandaloneLowerLink.make(kind: .datagram, pathID: pathID, in: &context.eventContext)
        var multipath = self.multipath
        do throws(NetworkError) {
            try Self.attachPath(
                link,
                storage: storage,
                multipath: &multipath,
                remote: remote,
                local: local,
                parameters: parameters,
                path: pathProperties
            )
        } catch {
            context.eventContext.standaloneUnregisterLink(identifier: link.identifier, slot: link.slot)
            throw error
        }
        paths[pathID] = link
        return pathID
    }

    public func receiveFromBelow(path: StandalonePathID, _ frames: consuming FrameArray) {
        guard let link = paths[path] else {
            frames.finalizeAllFramesAsFailed()
            return
        }
        link.receive(frames, context: context)
    }

    public func takeOutbound(path: StandalonePathID) -> FrameArray {
        paths[path]?.takeOutbound(context: context) ?? FrameArray()
    }

    public func deliverNetworkEvent(path: StandalonePathID, _ event: NetworkProtocolEvent) {
        paths[path]?.deliverNetworkProtocolEvent(event, context: context)
    }
}

#endif
#endif
