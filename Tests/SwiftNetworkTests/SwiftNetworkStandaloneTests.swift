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

import XCTest

#if !NETWORK_NO_SWIFT_QUIC && !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

// Drives protocols with no linkages: the test is the application above, the network below, and the
// scheduler. Nothing here uses the test harness or a dispatch queue.

@available(Network 0.1.0, *)
extension Array where Element == StandaloneEvent {
    func contains(connected flow: StandaloneFlowID?) -> Bool {
        contains { if case .connected(let f) = $0 { return f == flow } else { return false } }
    }

    func contains(disconnected flow: StandaloneFlowID?) -> Bool {
        contains { if case .disconnected(let f, _) = $0 { return f == flow } else { return false } }
    }

    func contains(inboundDataAvailable flow: StandaloneFlowID?) -> Bool {
        contains { if case .inboundDataAvailable(let f) = $0 { return f == flow } else { return false } }
    }

    var newInboundFlows: [StandaloneFlowID] {
        compactMap { if case .newInboundFlow(let f, _) = $0 { return f } else { return nil } }
    }

    var quicEvents: [QUICEvent] {
        compactMap { if case .network(let e) = $0 { return e.quicEvent } else { return nil } }
    }
}

/// Two environments joined by shuttling packets, with one shared clock.
@available(Network 0.1.0, *)
final class StandaloneLoopback {
    static let start = NetworkClock.Instant.zero.advanced(by: .seconds(1_000))

    let clientEnvironment = StandaloneEnvironment(identifier: "standalone-client", now: start)
    let serverEnvironment = StandaloneEnvironment(identifier: "standalone-server", now: start)
    var clientEvents: [StandaloneEvent] = []
    var serverEvents: [StandaloneEvent] = []
    var now = start

    func collectEvents() {
        clientEnvironment.drainEvents { clientEvents.append($0) }
        serverEnvironment.drainEvents { serverEvents.append($0) }
    }

    /// Moves everything `sender` queued on `senderPath` to `receiver`'s `receiverPath`.
    func shuttle<A: StandaloneManyToManyProtocol & ~Copyable, B: StandaloneManyToManyProtocol & ~Copyable>(
        _ sender: borrowing A,
        _ senderPath: StandalonePathID,
        _ receiver: borrowing B,
        _ receiverPath: StandalonePathID
    ) -> Int {
        let datagrams = sender.takeOutboundDatagrams(path: senderPath)
        for datagram in datagrams {
            receiver.receiveFromBelow(path: receiverPath, datagram)
        }
        return datagrams.count
    }

    /// Runs both sides until `condition` holds, jumping the clock to the next timer when the
    /// network goes quiet. Returns whether `condition` held.
    func run<C: StandaloneManyToManyProtocol & ~Copyable, S: StandaloneManyToManyProtocol & ~Copyable>(
        client: borrowing C,
        clientPath: StandalonePathID,
        server: borrowing S,
        serverPath: StandalonePathID,
        limit: NetworkDuration = .seconds(30),
        until condition: () -> Bool
    ) -> Bool {
        let deadline = now.advanced(by: limit)
        for _ in 0..<10_000 {
            clientEnvironment.turn(now: now)
            serverEnvironment.turn(now: now)
            collectEvents()
            var moved = shuttle(client, clientPath, server, serverPath)
            moved += shuttle(server, serverPath, client, clientPath)
            collectEvents()
            if condition() { return true }
            if moved > 0 || clientEnvironment.needsAsync || serverEnvironment.needsAsync { continue }
            let next = [clientEnvironment.nextTimerDeadline, serverEnvironment.nextTimerDeadline].compactMap { $0 }
                .min()
            guard let next, next <= deadline else { return false }
            now = max(next, now)
        }
        return false
    }
}

@available(Network 0.1.0, *)
final class SwiftNetworkStandaloneTests: NetTestCase {

    static let localIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x14]
    static let remoteIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x75]

    var localEndpoint: Endpoint { Endpoint(address: IPv4Address(Self.localIPv4Address)!, port: 1234) }
    var remoteEndpoint: Endpoint { Endpoint(address: IPv4Address(Self.remoteIPv4Address)!, port: 2345) }

    // MARK: - UDP

    func testStandaloneUDP() throws {
        let environment = StandaloneEnvironment(now: StandaloneLoopback.start)
        let udp = try StandaloneUDP(local: localEndpoint, remote: remoteEndpoint, environment: environment)

        udp.connect()
        environment.turn()
        var events: [StandaloneEvent] = []
        environment.drainEvents { events.append($0) }
        XCTAssertTrue(events.contains(connected: nil), "UDP should report connected")

        XCTAssertTrue(udp.write(Array("hello".utf8)))
        XCTAssertEqual(udp.takeOutboundPackets(), [SwiftNetworkUDPTests.outputIPv4Packet])

        udp.receiveFromBelow(SwiftNetworkUDPTests.inputIPv4Packet)
        environment.drainEvents { events.append($0) }
        XCTAssertTrue(events.contains(inboundDataAvailable: nil), "UDP should report inbound data")
        XCTAssertEqual(udp.read(), Array("there\n".utf8))
        XCTAssertNil(udp.read())

        // A UDP instance with nothing pending asks for no timers and no callbacks.
        XCTAssertNil(environment.nextTimerDeadline)
        XCTAssertFalse(environment.needsAsync)

        udp.disconnect(error: nil)
        udp.close()
        XCTAssertEqual(environment.scheduler.scheduledTimerCount, 0)
    }

    // MARK: - TLS record

    #if HAS_SWIFTTLS_RECORD && IMPORT_SWIFTTLS && canImport(SwiftTLS)

    func testStandaloneTLSRecord() throws {
        let serverKey = P256.Signing.PrivateKey()

        let clientOptions = SwiftTLSProtocol.options()
        var clientTLS = SwiftTLSProtocol.Options()
        clientTLS.applicationProtocols = ["network_test"]
        clientTLS.serverName = "tls-test.local"
        clientTLS.trustedRawPublicKeyCertificates = [[UInt8](serverKey.publicKey.derRepresentation)]
        clientOptions.replacePerProtocolOptions(clientTLS)

        let serverOptions = SwiftTLSProtocol.options()
        var serverTLS = SwiftTLSProtocol.Options()
        serverTLS.applicationProtocols = ["network_test"]
        serverTLS.serverName = "tls-test.local"
        serverTLS.rawPrivateKey = [UInt8](serverKey.rawRepresentation)
        serverOptions.replacePerProtocolOptions(serverTLS)

        let clientEnvironment = StandaloneEnvironment(identifier: "tls-client", now: StandaloneLoopback.start)
        let serverEnvironment = StandaloneEnvironment(identifier: "tls-server", now: StandaloneLoopback.start)
        let client = try StandaloneTLSRecord(
            options: clientOptions,
            isServer: false,
            local: localEndpoint,
            remote: remoteEndpoint,
            environment: clientEnvironment
        )
        let server = try StandaloneTLSRecord(
            options: serverOptions,
            isServer: true,
            local: remoteEndpoint,
            remote: localEndpoint,
            environment: serverEnvironment
        )

        var clientEvents: [StandaloneEvent] = []
        var serverEvents: [StandaloneEvent] = []
        func collect() {
            clientEnvironment.drainEvents { clientEvents.append($0) }
            serverEnvironment.drainEvents { serverEvents.append($0) }
        }

        func shuttle<A: StandaloneOneToOneProtocol & ~Copyable, B: StandaloneOneToOneProtocol & ~Copyable>(
            _ sender: borrowing A,
            _ receiver: borrowing B
        ) -> Int {
            let packets = sender.takeOutboundPackets()
            for packet in packets {
                receiver.receiveFromBelow(packet)
            }
            return packets.count
        }

        server.connect()
        client.connect()
        var rounds = 0
        while !(clientEvents.contains(connected: nil) && serverEvents.contains(connected: nil)) {
            clientEnvironment.turn()
            serverEnvironment.turn()
            collect()
            let moved = shuttle(client, server) + shuttle(server, client)
            collect()
            rounds += 1
            if moved == 0 || rounds > 100 { break }
        }
        XCTAssertTrue(clientEvents.contains(connected: nil), "TLS client should finish the handshake")
        XCTAssertTrue(serverEvents.contains(connected: nil), "TLS server should finish the handshake")

        XCTAssertTrue(client.write(Array("hello over tls".utf8)))
        _ = shuttle(client, server)
        collect()
        XCTAssertTrue(serverEvents.contains(inboundDataAvailable: nil))
        XCTAssertEqual(server.read()?.bytes, Array("hello over tls".utf8))

        client.disconnect(error: nil)
        server.disconnect(error: nil)
        client.close()
        server.close()
    }

    #endif

    // MARK: - QUIC

    let serverSigningKey = P256.Signing.PrivateKey()

    func quicOptions(server: Bool, datagram: Bool = false) -> ProtocolOptions<QUICProtocol> {
        var tlsOptions = SwiftTLSProtocol.Options()
        tlsOptions.applicationProtocols = ["network_test"]
        tlsOptions.serverName = "quic-test.local"
        if server {
            tlsOptions.rawPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        } else {
            tlsOptions.trustedRawPublicKeyCertificates = [[UInt8](serverSigningKey.publicKey.derRepresentation)]
        }
        let options = QUICProtocol.options()
        options.modifyTLSOptions { $0 = tlsOptions }
        if server {
            options.modifyConnectionOptions { $0.initialSourceConnectionID = QUICConnectionID(10) }
            options.modifyConnectionOptions { $0.initialStatelessResetToken = QUICStatelessResetToken() }
        }
        if datagram {
            options.modifyPerProtocolOptions { streamOptions in
                if !server {
                    streamOptions.isDatagram = true
                    streamOptions.associatedStreamID = 0
                }
                streamOptions.modifyQUICConnectionOptions { connectionOptions in
                    connectionOptions.datagramQuarterStreamID = true
                    connectionOptions.datagramEnableFlowID = true
                    connectionOptions.maxDatagramFrameSize = 65535
                }
            }
        }
        return options
    }

    func makeClient(
        _ loopback: StandaloneLoopback,
        datagram: Bool = false,
        releasesFlowsOnDisconnect: Bool = false
    ) throws -> StandaloneQUICConnection {
        try StandaloneQUICConnection(
            options: quicOptions(server: false, datagram: datagram),
            isServer: false,
            local: localEndpoint,
            remote: remoteEndpoint,
            environment: loopback.clientEnvironment,
            releasesFlowsOnDisconnect: releasesFlowsOnDisconnect
        )
    }

    func makeServer(
        _ loopback: StandaloneLoopback,
        datagram: Bool = false,
        releasesFlowsOnDisconnect: Bool = false
    ) throws -> StandaloneQUICConnection {
        try StandaloneQUICConnection(
            options: quicOptions(server: true, datagram: datagram),
            isServer: true,
            local: remoteEndpoint,
            remote: localEndpoint,
            environment: loopback.serverEnvironment,
            acceptsInboundDatagramFlows: datagram,
            releasesFlowsOnDisconnect: releasesFlowsOnDisconnect
        )
    }

    func drive(
        _ loopback: StandaloneLoopback,
        _ client: borrowing StandaloneQUICConnection,
        _ server: borrowing StandaloneQUICConnection,
        until condition: () -> Bool
    ) -> Bool {
        loopback.run(
            client: client,
            clientPath: client.primaryPath,
            server: server,
            serverPath: server.primaryPath,
            until: condition
        )
    }

    func testStandaloneQUICHandshakeAndStreamEcho() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback)
        let server = try makeServer(loopback)

        server.connect()
        client.connect()
        let stream = try client.openStream()
        client.connect(flow: stream)

        XCTAssertTrue(
            drive(loopback, client, server) {
                loopback.clientEvents.contains(connected: stream) && loopback.clientEvents.contains(connected: nil)
            },
            "QUIC client should finish the handshake"
        )

        // The server learns about a stream when data for it arrives.
        XCTAssertTrue(client.writeStream(flow: stream, Array("hello quic".utf8), sendFIN: true))
        XCTAssertTrue(
            drive(loopback, client, server) { !loopback.serverEvents.newInboundFlows.isEmpty },
            "server should see the new stream"
        )
        let serverStream = try XCTUnwrap(loopback.serverEvents.newInboundFlows.first)
        XCTAssertTrue(
            drive(loopback, client, server) { loopback.serverEvents.contains(connected: nil) },
            "the server should report the connection connected"
        )

        // Data that arrived with the stream is already readable; the event only announces data that
        // arrives later.
        let received = try XCTUnwrap(server.readStream(flow: serverStream))
        XCTAssertEqual(received.bytes, Array("hello quic".utf8))
        XCTAssertTrue(received.isFinal)

        // The new-flow event stands for the flow's connect and for the data it arrived with, so
        // neither is reported again.
        XCTAssertFalse(loopback.serverEvents.contains(connected: serverStream))
        XCTAssertFalse(loopback.serverEvents.contains(inboundDataAvailable: serverStream))

        // Echo it back.
        XCTAssertTrue(server.writeStream(flow: serverStream, received.bytes, sendFIN: true))
        XCTAssertTrue(drive(loopback, client, server) { loopback.clientEvents.contains(inboundDataAvailable: stream) })
        let echoed = try XCTUnwrap(client.readStream(flow: stream))
        XCTAssertEqual(echoed.bytes, Array("hello quic".utf8))
        XCTAssertTrue(echoed.isFinal)

        client.teardown(flow: stream)
        server.teardown(flow: serverStream)
        client.close()
        server.close()
    }

    /// With `releasesFlowsOnDisconnect`, a flow is gone once its disconnect has been taken from the
    /// queue, and the owner's `teardown(flow:)` for it does nothing.
    func testStandaloneQUICReleasesFlowsOnDisconnect() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback, releasesFlowsOnDisconnect: true)
        let server = try makeServer(loopback, releasesFlowsOnDisconnect: true)
        server.connect()
        client.connect()
        let stream = try client.openStream()
        client.connect(flow: stream)
        XCTAssertTrue(drive(loopback, client, server) { loopback.clientEvents.contains(connected: stream) })

        // A request and its response, each with a FIN.
        XCTAssertTrue(client.writeStream(flow: stream, Array("ping".utf8), sendFIN: true))
        XCTAssertTrue(drive(loopback, client, server) { !loopback.serverEvents.newInboundFlows.isEmpty })
        let serverStream = try XCTUnwrap(loopback.serverEvents.newInboundFlows.first)
        let request = try XCTUnwrap(server.readStream(flow: serverStream))
        XCTAssertEqual(request.bytes, Array("ping".utf8))
        XCTAssertTrue(server.writeStream(flow: serverStream, Array("pong".utf8), sendFIN: true))
        XCTAssertTrue(drive(loopback, client, server) { loopback.clientEvents.contains(inboundDataAvailable: stream) })
        let response = try XCTUnwrap(client.readStream(flow: stream))
        XCTAssertEqual(response.bytes, Array("pong".utf8))
        XCTAssertTrue(response.isFinal)

        // Both directions are done: each side reports the stream disconnected, and releases it.
        XCTAssertTrue(
            drive(loopback, client, server) {
                loopback.clientEvents.contains(disconnected: stream)
                    && loopback.serverEvents.contains(disconnected: serverStream)
            },
            "both sides should report the stream disconnected"
        )
        XCTAssertNil(client.readStream(flow: stream), "a released flow takes no more calls")
        XCTAssertNil(server.readStream(flow: serverStream))
        client.teardown(flow: stream)
        server.teardown(flow: serverStream)

        // A flow ID names the flow's link slot, which the next flow reuses. The released flow's ID
        // must not reach the flow that took its place.
        let next = try client.openStream()
        XCTAssertNotEqual(next, stream)
        client.connect(flow: next)
        client.teardown(flow: stream)
        XCTAssertNil(client.readStream(flow: stream))
        XCTAssertTrue(client.writeStream(flow: next, Array("again".utf8), sendFIN: true), "the new flow is untouched")
        client.teardown(flow: next)

        client.close()
        server.close()
    }

    /// Streams that hold more than the flow-control windows allow wait for credit, and come back to the
    /// send list as the peer's ACKs and window updates arrive. Every byte of every stream must arrive.
    func testStandaloneQUICStreamsLargerThanTheWindowsComplete() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback)
        let server = try makeServer(loopback)
        server.connect()
        client.connect()

        let streamCount = 8
        let size = 3 << 20
        func pattern(_ stream: Int, _ index: Int) -> UInt8 { UInt8(truncatingIfNeeded: index &* 31 &+ stream) }
        var streams: [StandaloneFlowID] = []
        for _ in 0..<streamCount {
            let flow = try client.openStream()
            client.connect(flow: flow)
            streams.append(flow)
        }
        XCTAssertTrue(
            drive(loopback, client, server) {
                streams.allSatisfy { loopback.clientEvents.contains(connected: $0) }
            },
            "the streams should connect"
        )
        for (stream, flow) in streams.enumerated() {
            let bytes = (0..<size).map { pattern(stream, $0) }
            XCTAssertTrue(client.writeStream(flow: flow, bytes, sendFIN: true))
        }

        var received: [StandaloneFlowID: [UInt8]] = [:]
        var finished: Set<StandaloneFlowID> = []
        let done = drive(loopback, client, server) {
            for flow in loopback.serverEvents.newInboundFlows where !finished.contains(flow) {
                while let read = server.readStream(flow: flow) {
                    received[flow, default: []].append(contentsOf: read.bytes)
                    if read.isFinal {
                        finished.insert(flow)
                        break
                    }
                    if read.bytes.isEmpty { break }
                }
            }
            return finished.count == streamCount
        }
        XCTAssertTrue(done, "every stream should arrive complete")
        XCTAssertEqual(received.count, streamCount)
        // The server sees the streams in the order the client opened them.
        for (stream, flow) in loopback.serverEvents.newInboundFlows.enumerated() {
            let bytes = received[flow] ?? []
            XCTAssertEqual(bytes.count, size)
            XCTAssertTrue(bytes.enumerated().allSatisfy { $0.element == pattern(stream, $0.offset) }, "stream \(stream)")
        }

        for flow in streams { client.teardown(flow: flow) }
        for flow in loopback.serverEvents.newInboundFlows { server.teardown(flow: flow) }
        client.close()
        server.close()
    }

    /// A unidirectional stream gets a unidirectional stream ID (bit 1 of the ID, RFC 9000 Section 2.1),
    /// which the peer is told with the new flow, and the data arrives.
    func testStandaloneQUICUnidirectionalStream() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback)
        let server = try makeServer(loopback)
        server.connect()
        client.connect()

        let bidirectional = try client.openStream()
        let unidirectional = try client.openStream(unidirectional: true)
        client.connect(flow: bidirectional)
        client.connect(flow: unidirectional)
        XCTAssertTrue(
            drive(loopback, client, server) {
                loopback.clientEvents.contains(connected: bidirectional)
                    && loopback.clientEvents.contains(connected: unidirectional)
            },
            "both streams should connect"
        )
        XCTAssertTrue(client.writeStream(flow: bidirectional, Array("both ways".utf8), sendFIN: true))
        XCTAssertTrue(client.writeStream(flow: unidirectional, Array("one way".utf8), sendFIN: true))

        func streamIDs() -> [UInt64] {
            loopback.serverEvents.compactMap { if case .newInboundFlow(_, let tag) = $0 { return tag } else { return nil } }
        }
        XCTAssertTrue(drive(loopback, client, server) { streamIDs().count == 2 }, "the server should see both streams")
        let ids = streamIDs().sorted()
        XCTAssertEqual(ids.map { $0 & 0x3 }, [0x0, 0x2], "client-initiated bidirectional, then client-initiated unidirectional")

        let oneWay = try XCTUnwrap(
            loopback.serverEvents.compactMap { event -> StandaloneFlowID? in
                if case .newInboundFlow(let flow, let tag) = event, tag & 0x2 != 0 { return flow } else { return nil }
            }.first
        )
        let read = try XCTUnwrap(server.readStream(flow: oneWay))
        XCTAssertEqual(read.bytes, Array("one way".utf8))
        XCTAssertTrue(read.isFinal)

        client.teardown(flow: bidirectional)
        client.teardown(flow: unidirectional)
        for case .newInboundFlow(let flow, _) in loopback.serverEvents { server.teardown(flow: flow) }
        client.close()
        server.close()
    }

    func testStandaloneQUICConnectionIDEvents() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback)
        let server = try makeServer(loopback)
        server.connect()
        client.connect()
        let stream = try client.openStream()
        client.connect(flow: stream)

        XCTAssertTrue(
            loopback.run(
                client: client,
                clientPath: client.primaryPath,
                server: server,
                serverPath: server.primaryPath,
                until: { loopback.clientEvents.contains(connected: stream) }
            )
        )

        // The server announces connection IDs to the client right after the handshake.
        XCTAssertTrue(
            loopback.run(
                client: client,
                clientPath: client.primaryPath,
                server: server,
                serverPath: server.primaryPath,
                until: {
                    loopback.clientEvents.quicEvents.contains {
                        if case .newOutboundConnectionID = $0 { return true } else { return false }
                    }
                }
            ),
            "the client should learn a connection ID the server announced"
        )
        XCTAssertTrue(
            loopback.serverEvents.quicEvents.contains {
                if case .newInboundConnectionID = $0 { return true } else { return false }
            },
            "the server should report the connection IDs it announced"
        )

        // Retiring one is an application event from the client, answered with an event.
        var announced: QUICConnectionID?
        for case .newOutboundConnectionID(let connectionID, _) in loopback.clientEvents.quicEvents {
            announced = connectionID
        }
        let connectionID = try XCTUnwrap(announced)
        client.applicationEvent(.init(quicEvent: .retireOutboundConnectionID(connectionID)))
        loopback.collectEvents()
        XCTAssertTrue(
            loopback.clientEvents.quicEvents.contains {
                if case .retiredOutboundConnectionID(let retired, _) = $0 { return retired == connectionID }
                return false
            },
            "the client should report the connection ID it retired"
        )

        client.close()
        server.close()
    }

    func testStandaloneQUICTimerRetransmission() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback)
        let server = try makeServer(loopback)
        server.connect()
        client.connect()
        let stream = try client.openStream()
        client.connect(flow: stream)
        loopback.clientEnvironment.turn(now: loopback.now)

        // Lose the client's first flight.
        let first = client.takeOutboundDatagrams(path: client.primaryPath)
        XCTAssertFalse(first.isEmpty, "the client should have an Initial to send")

        // The client has asked to be woken to retransmit.
        let deadline = try XCTUnwrap(loopback.clientEnvironment.nextTimerDeadline, "a loss timer should be armed")
        XCTAssertGreaterThan(deadline, loopback.now)
        XCTAssertTrue(client.takeOutboundDatagrams(path: client.primaryPath).isEmpty)

        // Firing it produces the retransmission.
        loopback.now = deadline
        loopback.clientEnvironment.turn(now: loopback.now)
        XCTAssertFalse(
            client.takeOutboundDatagrams(path: client.primaryPath).isEmpty,
            "the client should retransmit when its timer fires"
        )

        client.close()
        server.close()
        loopback.clientEnvironment.turn(now: loopback.now)
        XCTAssertEqual(loopback.clientEnvironment.scheduler.scheduledTimerCount, 0, "close cancels timers")
    }

    func testStandaloneQUICDisconnect() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback)
        let server = try makeServer(loopback)
        server.connect()
        client.connect()
        let stream = try client.openStream()
        client.connect(flow: stream)

        XCTAssertTrue(drive(loopback, client, server) { loopback.clientEvents.contains(connected: stream) })

        client.disconnect(error: nil)
        XCTAssertTrue(
            drive(loopback, client, server) {
                loopback.clientEvents.contains(disconnected: nil) && loopback.serverEvents.contains(disconnected: nil)
            },
            "both sides should report the disconnect"
        )

        client.close()
        server.close()
    }
    func testStandaloneQUICDatagramFlow() throws {
        let loopback = StandaloneLoopback()
        let client = try makeClient(loopback, datagram: true)
        let server = try makeServer(loopback, datagram: true)
        server.connect()
        client.connect()
        let flow = try client.openDatagramFlow()
        client.connect(flow: flow)
        XCTAssertTrue(
            drive(loopback, client, server) { loopback.clientEvents.contains(connected: flow) },
            "the datagram flow should connect"
        )

        XCTAssertTrue(client.writeDatagram(flow: flow, Array("datagram".utf8)))
        XCTAssertTrue(
            drive(loopback, client, server) { !loopback.serverEvents.newInboundFlows.isEmpty },
            "the server should see the datagram flow"
        )
        let serverFlow = try XCTUnwrap(loopback.serverEvents.newInboundFlows.first)
        XCTAssertTrue(
            drive(loopback, client, server) { server.readDatagram(flow: serverFlow) == Array("datagram".utf8) },
            "the server should receive the datagram"
        )

        client.close()
        server.close()
    }

    /// A standalone linkage is its identifier and nothing else: no storage, no object behind it.
    func testStandaloneLinkageHoldsOnlyAnIdentifier() throws {
        let environment = StandaloneEnvironment(now: StandaloneLoopback.start)
        let context = environment.context
        let flow = StandaloneFlowLink.make(
            kind: .stream,
            hasFlowID: false,
            reportsConnectionEvents: true,
            in: &context.eventContext
        )
        let lower = StandaloneLowerLink.make(kind: .datagram, pathID: nil, in: &context.eventContext)
        XCTAssertEqual(flow.inboundStream.identifier, flow.identifier)
        XCTAssertNil(flow.inboundStream.storage)
        XCTAssertEqual(lower.outboundDatagram.identifier, lower.identifier)
        XCTAssertNil(lower.outboundDatagram.storage)
        context.eventContext.standaloneUnregisterLink(identifier: flow.identifier, slot: flow.slot)
        context.eventContext.standaloneUnregisterLink(identifier: lower.identifier, slot: lower.slot)
    }
}

#endif
