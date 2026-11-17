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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
@_spi(Essentials) import SwiftNetworkTestSupport
import Synchronization

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// A client and a server QUIC connection wired to each other in memory.
@available(Network 0.1.0, *)
final class QUICLoopback {

    typealias StreamHarness = StreamUpperHarness<TestStreamLinkageFamily>
    typealias FlowHarness = NewStreamFlowHarness<TestStreamLinkageFamily>

    private static let serverSigningKey = try! P256.Signing.PrivateKey(
        rawRepresentation: Array(UInt8(1)...UInt8(32))
    )

    private static let clientEndpoint = Endpoint(address: IPv4Address([0x0a, 0x00, 0x00, 0x14])!, port: 4433)
    private static let serverEndpoint = Endpoint(address: IPv4Address([0x0a, 0x00, 0x00, 0x75])!, port: 4434)

    let manualTime: ManualTimeContext

    /// How many datagrams the client's bridge has delivered, so a scenario can tell that a drop
    /// it asked for really happened. Datagrams the bridge drops are not counted.
    private let clientDeliveredCounter = DatagramCounter()
    var clientDatagramsDelivered: Int { self.clientDeliveredCounter.count }

    private let storage: TestNetworkProtocolStorage
    private let clientListener: TestStreamListenerLinkage
    private let clientParameters: Parameters
    private var streamsOpened = 0

    let clientStream: StreamHarness
    private let serverFlow: FlowHarness

    private static func makeOptions(
        server: Bool,
        idleTimeout: NetworkDuration,
        maximumConcurrentStreams: Int?
    ) -> ProtocolOptions<QUICProtocol> {
        var tlsOptions = SwiftTLSProtocol.Options()
        tlsOptions.applicationProtocols = ["network_test"]
        tlsOptions.serverName = "quic-test.local"
        if server {
            tlsOptions.rawPrivateKey = [UInt8](Self.serverSigningKey.rawRepresentation)
        } else {
            tlsOptions.trustedRawPublicKeyCertificates = [
                [UInt8](Self.serverSigningKey.publicKey.derRepresentation)
            ]
        }
        let options = QUICStreamProtocol.options()
        options.modifyTLSOptions { $0 = tlsOptions }
        options.modifyConnectionOptions {
            $0.idleTimeout = idleTimeout
            if let maximumConcurrentStreams {
                $0.initialMaxStreamsBidirectional = UInt64(maximumConcurrentStreams)
                $0.maximumConcurrentBidirectionalStreams = maximumConcurrentStreams
            }
        }
        return options
    }

    /// - Parameters:
    ///   - clientDropIndex: Which datagram the client sends should be lost, counted from zero over
    ///     the life of the connection.
    ///   - idleTimeout: QUIC's idle timeout on both endpoints. Raise it for a scenario that lets a lot
    ///     of virtual time pass.
    ///   - maximumConcurrentStreams: QUIC's maximum concurrent bidirectional streams on both
    ///     endpoints. Setting it also makes a connection return stream credit as streams close.
    init(
        linkDelay: NetworkDuration = .zero,
        clientDropIndex: Int? = nil,
        idleTimeout: NetworkDuration = .seconds(30),
        maximumConcurrentStreams: Int? = nil
    ) throws {
        let manualTime = ManualTimeContext("QUICBenchmarks")
        self.manualTime = manualTime
        let context = manualTime.context

        context.activate()
        let storage = TestNetworkProtocolStorage(context: context)
        let clientDeliveredCounter = self.clientDeliveredCounter
        let wiring = try Self.runOnContext(manualTime, orThrow: .endpointSetupFailed) {
            let client = try Self.wireClient(
                storage: storage,
                context: context,
                linkDelay: linkDelay,
                dropIndex: clientDropIndex,
                idleTimeout: idleTimeout,
                maximumConcurrentStreams: maximumConcurrentStreams,
                onDatagramDelivered: { clientDeliveredCounter.increment() }
            )
            let server = try Self.wireServer(
                storage: storage,
                context: context,
                linkDelay: linkDelay,
                idleTimeout: idleTimeout,
                maximumConcurrentStreams: maximumConcurrentStreams
            )
            return Wiring(client: client, server: server)
        }

        self.storage = storage
        self.clientListener = wiring.client.listener
        self.clientParameters = wiring.client.parameters
        self.clientStream = wiring.client.stream
        self.serverFlow = wiring.server

        wiring.server.start { _ in }
        wiring.client.stream.start { _ in }
    }

    private static func runOnContext<Value>(
        _ manualTime: ManualTimeContext,
        orThrow failure: QUICLoopbackError,
        _ work: @escaping () throws -> Value
    ) throws -> Value {
        let outcome = Outcome<Value>()
        manualTime.context.async {
            outcome.result = Result(catching: work)
        }
        manualTime.run()
        guard let result = outcome.result else {
            throw failure
        }
        return try result.get()
    }

    private struct ClientEndpoint {
        var listener: TestStreamListenerLinkage
        var parameters: Parameters
        var stream: StreamHarness
    }

    private struct Wiring {
        var client: ClientEndpoint
        var server: FlowHarness
    }

    private static func bridgeOptions(
        linkDelay: NetworkDuration,
        storage: TestNetworkProtocolStorage
    ) -> (ProtocolOptions<BridgeDatagramProtocol>, TestOutboundDatagramLinkage) {
        let bridge = storage.createTestBridgeDatagramInstance()
        let options = BridgeDatagramProtocol.options()
        options.linkDelay = linkDelay
        options.setProtocolInstance(bridge.identifier)
        return (options, bridge)
    }

    private static func wireClient(
        storage: TestNetworkProtocolStorage,
        context: NetworkContext,
        linkDelay: NetworkDuration,
        dropIndex: Int?,
        idleTimeout: NetworkDuration,
        maximumConcurrentStreams: Int?,
        onDatagramDelivered: @escaping @Sendable () -> Void
    ) throws -> ClientEndpoint {
        let (listener, _, multipath) = storage.createTestQUICInstance()
        let quicOptions = Self.makeOptions(
            server: false,
            idleTimeout: idleTimeout,
            maximumConcurrentStreams: maximumConcurrentStreams
        )
        quicOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
        quicOptions.setProtocolInstance(listener.identifier)

        let (bridgeOptions, bridge) = Self.bridgeOptions(linkDelay: linkDelay, storage: storage)
        bridgeOptions.observeFrameHandler = { _, _ in onDatagramDelivered() }
        if let dropIndex {
            bridgeOptions.datagramDrops = DatagramDrops(dropIndex)
        }

        var parameters = Parameters(context: context)
        parameters.isServer = false
        parameters.defaultStack.transport = .quic(quicOptions)
        parameters.defaultStack.link = .custom(bridgeOptions)
        let path = PathProperties(parameters: parameters)

        let (stream, streamLinkage) = storage.createStreamUpperHarness(
            identifier: "Client",
            local: Self.clientEndpoint,
            remote: Self.serverEndpoint,
            parameters: parameters,
            path: path,
            context: context
        )
        try listener.invokeAttachUpperProtocolToNewFlow(
            streamLinkage,
            remote: Self.serverEndpoint,
            local: Self.clientEndpoint,
            parameters: parameters,
            path: path
        )
        var multipathLinkage = multipath
        try multipathLinkage.invokeAttachLowerProtocolForNewPath(
            bridge,
            remote: Self.serverEndpoint,
            local: Self.clientEndpoint,
            parameters: parameters,
            path: path
        )
        return ClientEndpoint(listener: listener, parameters: parameters, stream: stream)
    }

    private static func wireServer(
        storage: TestNetworkProtocolStorage,
        context: NetworkContext,
        linkDelay: NetworkDuration,
        idleTimeout: NetworkDuration,
        maximumConcurrentStreams: Int?
    ) throws -> FlowHarness {
        let (listener, _, multipath) = storage.createTestQUICInstance()
        let quicOptions = Self.makeOptions(
            server: true,
            idleTimeout: idleTimeout,
            maximumConcurrentStreams: maximumConcurrentStreams
        )
        quicOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
        quicOptions.setProtocolInstance(listener.identifier)

        let (bridgeOptions, bridge) = Self.bridgeOptions(linkDelay: linkDelay, storage: storage)

        var parameters = Parameters(context: context)
        parameters.isServer = true
        parameters.defaultStack.transport = .quic(quicOptions)
        parameters.defaultStack.link = .custom(bridgeOptions)
        let path = PathProperties(parameters: parameters)

        let (flow, flowLinkage) = storage.createNewStreamFlowHarness(
            identifier: "Server",
            local: Self.serverEndpoint,
            remote: Self.clientEndpoint,
            parameters: parameters,
            path: path,
            context: context
        )
        // Attach from the upper linkage so both directions are bound.
        try flowLinkage.invokeAttachLowerProtocol(
            listener,
            remote: Self.clientEndpoint,
            local: Self.serverEndpoint,
            parameters: parameters,
            path: path
        )
        var multipathLinkage = multipath
        try multipathLinkage.invokeAttachLowerProtocolForNewPath(
            bridge,
            remote: Self.clientEndpoint,
            local: Self.serverEndpoint,
            parameters: parameters,
            path: path
        )
        return flow
    }

    /// Drives both peers until `condition` holds. Any time that passes is virtual.
    ///
    /// Throws rather than returning `false`: a benchmark that silently measures a stalled
    /// connection reports a stable number for work that never happened.
    func run(until condition: () -> Bool, within limit: NetworkDuration = .seconds(10)) throws {
        guard self.manualTime.scheduler.run(until: condition, limit: limit) else {
            throw QUICLoopbackError.didNotSettle
        }
    }

    func completeHandshake() throws {
        try self.run(until: { self.clientStream.receivedConnected && self.serverFlow.receivedConnected })
    }

    private func write(_ payload: [UInt8], on stream: StreamHarness, sendFIN: Bool = false) throws {
        guard stream.write(payload, sendFIN: sendFIN) else {
            throw QUICLoopbackError.writeFailed
        }
    }

    /// Drives until `stream` has taken `byteCount` bytes, and its FIN if `finished`.
    ///
    /// A write that flow control drops still returns `true`, and a scenario that
    /// ignores the receiving half measures a send path whose other half never ran.
    ///
    /// Drops read bytes to avoid extra allocs.
    private func run(untilReceived byteCount: Int, on stream: StreamHarness, finished: Bool = false) throws {
        var received = 0
        try self.run(
            until: {
                received += stream.readAndDrop()
                return received >= byteCount && (!finished || stream.receivedFIN)
            }
        )
    }

    /// Writes once on `clientStream` and returns the server's view of the stream it creates.
    ///
    /// The server side does not exist until the client has actually sent something on the stream,
    /// so the first write and the wait have to happen in this order. Scenarios call this outside
    /// the measurement window, then use `send` inside it.
    func primeServerStream(with payload: [UInt8]) throws -> StreamHarness {
        try self.write(payload, on: self.clientStream)
        try self.run(until: { !self.serverFlow.upperHarnesses.isEmpty })
        guard let serverStream = self.serverFlow.upperHarnesses.first else {
            throw QUICLoopbackError.noServerStream
        }
        try self.run(untilReceived: payload.count, on: serverStream)
        return serverStream
    }

    /// Sends `payload` and drives until `serverStream` has delivered all of it.
    func send(_ payload: [UInt8], to serverStream: StreamHarness) throws {
        try self.write(payload, on: self.clientStream)
        try self.run(untilReceived: payload.count, on: serverStream)
    }

    /// Lets `duration` of virtual time pass on an established connection with nothing to send.
    func idle(for duration: NetworkDuration) {
        let scheduler = self.manualTime.scheduler
        let end = scheduler.now.advanced(by: duration)
        // A false return means no timer is armed before `end`, which is expected on a quiet
        // connection; time then jumps straight there.
        if !scheduler.run(until: { scheduler.now >= end }, limit: duration) {
            scheduler.advanceTime(to: end)
        }
        scheduler.run()
    }

    /// Opens a new client stream, sends `request` and finishes it, has the server answer with
    /// `response` and finish its side, and tears both ends down.
    func exchangeOnNewStream(request: [UInt8], response: [UInt8]) throws {
        self.streamsOpened &+= 1
        let identifier = "Stream\(self.streamsOpened)"
        let context = self.manualTime.context
        let storage = self.storage
        let clientListener = self.clientListener
        let parameters = self.clientParameters

        let clientStream = try Self.runOnContext(self.manualTime, orThrow: .streamSetupFailed) {
            let path = PathProperties(parameters: parameters)
            let (stream, linkage) = storage.createStreamUpperHarness(
                identifier: identifier,
                local: Self.clientEndpoint,
                remote: Self.serverEndpoint,
                parameters: parameters,
                path: path,
                context: context
            )
            try clientListener.invokeAttachUpperProtocolToNewFlow(
                linkage,
                remote: Self.serverEndpoint,
                local: Self.clientEndpoint,
                parameters: parameters,
                path: path
            )
            return stream
        }
        clientStream.start()
        try self.run(until: { clientStream.receivedConnected })

        let serversBefore = self.serverFlow.upperHarnesses.count
        try self.write(request, on: clientStream, sendFIN: true)
        try self.run(until: { self.serverFlow.upperHarnesses.count > serversBefore })
        guard let serverStream = self.serverFlow.upperHarnesses.last else {
            throw QUICLoopbackError.noServerStream
        }

        try self.run(untilReceived: request.count, on: serverStream, finished: true)
        try self.write(response, on: serverStream, sendFIN: true)
        try self.run(untilReceived: response.count, on: clientStream, finished: true)

        clientStream.stop()
        serverStream.stop()
        clientStream.teardown()
        serverStream.teardown()
        // Both ends are finished with; keeping the server's would grow the list by one entry per
        // exchange and leave `last` pointing at a finished stream.
        self.serverFlow.upperHarnesses.removeLast()
        // Let the stream-closed bookkeeping, and any credit it returns, reach the peer.
        self.manualTime.run()
    }

    /// Tears down the application layers, which detaches them from QUIC. QUIC retires each
    /// connection once its last upper protocol has gone.
    func tearDown() {
        self.clientStream.stop()
        self.serverFlow.stop()
        self.clientStream.teardown()
        self.serverFlow.teardown()
    }
}

/// A count the bridge's observer, which is `@Sendable`, can add to.
@available(Network 0.1.0, *)
private final class DatagramCounter: Sendable {
    private let storage = Atomic<Int>(0)

    func increment() {
        self.storage.add(1, ordering: .relaxed)
    }

    var count: Int {
        self.storage.load(ordering: .relaxed)
    }
}

/// Carries a value out of a closure queued on the context.
@available(Network 0.1.0, *)
private final class Outcome<Value> {
    var result: Result<Value, any Error>?
}

@available(Network 0.1.0, *)
enum QUICLoopbackError: Error {
    case endpointSetupFailed
    case streamSetupFailed
    case didNotSettle
    case writeFailed
    case noServerStream
    case expectedLossDidNotOccur
}
