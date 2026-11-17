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

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
internal import Darwin
#endif

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetworkTestHarness
#endif

// The setup / teardown boilerplate and the POSIX test servers live in
// SocketTestHarness.swift. UDP datagram tests drive a `UDPLoopbackHarness`
// (two loopback peers); TCP stream tests drive a `TCPClientHarness` (an echo
// server plus one client). The harnesses own connection setup, waiting, and
// teardown, so each test below is just the payload/pattern it exercises.

@available(Network 0.1.0, *)
final class SwiftNetworkSocketTests: NetTestCase {

    // MARK: - Connection lifecycle (UDP)

    func testConnectionStateLifecycle() {
        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")

        let ports = discoverFreeLoopbackPorts(2)
        let remote = Endpoint(address: IPv4Address.loopback, port: ports[0])
        let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: ports[1]))
            .onStateUpdate { _, state in
                if case .ready = state { ready.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
            }

        conn.start()
        wait(for: [ready], timeout: 5.0)

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // MARK: - Basic data path (UDP)

    func testRoundTripEchoIPv4() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectRoundTripEcho([1, 2, 3, 4, 5])
        harness.teardown()
    }

    func testRoundTripEchoLargePayload() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectRoundTripEcho([UInt8](repeating: 0xAB, count: 1400))
        harness.teardown()
    }

    func testRoundTripEchoIPv6() {
        let harness = UDPLoopbackHarness(ipv6: true)
        harness.start()
        harness.expectRoundTripEcho([10, 20, 30])
        harness.teardown()
    }

    func testSendSingleByteDatagram() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectDeliver([0xFF])
        harness.teardown()
    }

    func testMultipleMessagesSequentially() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectSequentialDeliver([
            [1], [2, 3], [4, 5, 6], [7, 8, 9, 10], [11, 12, 13, 14, 15],
        ])
        harness.teardown()
    }

    func testBidirectionalSimultaneousTransfer() {
        let harness = UDPLoopbackHarness()
        harness.start()

        let bothDone = XCTestExpectation(description: "both received")
        bothDone.expectedFulfillmentCount = 2
        let payloadA: [UInt8] = [0xAA, 0xBB]
        let payloadB: [UInt8] = [0xCC, 0xDD]

        harness.c1.send(.message(content: payloadA)) { _ in }
        harness.c2.send(.message(content: payloadB)) { _ in }

        harness.c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadA)
            } else {
                XCTFail("c2 receive failed")
            }
            bothDone.fulfill()
        }
        harness.c1.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadB)
            } else {
                XCTFail("c1 receive failed")
            }
            bothDone.fulfill()
        }

        wait(for: [bothDone], timeout: 10.0)
        harness.teardown()
    }

    // MARK: - Volume / stress (UDP)

    func testRapidBurst100Sends() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectBurstThenDrain((0..<100).map { [UInt8($0 % 256)] })
        harness.teardown()
    }

    func testHighVolumeEcho200Messages() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectSequentialEcho(count: 200) { [UInt8($0 % 256)] }
        harness.teardown()
    }

    func testVaryingPayloadSizes() {
        let harness = UDPLoopbackHarness()
        harness.start()
        let sizes = [1, 100, 500, 1000, 1400, 10]
        harness.expectSequentialDeliver(sizes.map { [UInt8](repeating: 0xAA, count: $0) })
        harness.teardown()
    }

    // MARK: - Backpressure (UDP)

    func testBurstSendsReceiveOneAtATime() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectBurstThenDrain((0..<5).map { [UInt8($0)] }, timeout: 15.0)
        harness.teardown()
    }

    func testMultipleSendsBeforeAnyReads() {
        let harness = UDPLoopbackHarness()
        harness.start()
        // Small delay to let sends queue up before reading.
        harness.expectBurstThenDrain((0..<10).map { [UInt8($0)] }, delayBeforeDrain: 0.1, timeout: 15.0)
        harness.teardown()
    }

    func testDelayedConsumer() {
        let harness = UDPLoopbackHarness()
        harness.start()

        let allDone = XCTestExpectation(description: "delayed consumer")
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let c2 = harness.c2
        harness.c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }
        // Delay the receive by 500ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            c2.receive { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, payload)
                } else {
                    XCTFail("delayed receive failed")
                }
                allDone.fulfill()
            }
        }

        wait(for: [allDone], timeout: 10.0)
        harness.teardown()
    }

    // MARK: - Additional lifecycle tests (UDP)

    func testCancelBeforeStart() {
        let cancelled = XCTestExpectation(description: "cancelled")

        let ports = discoverFreeLoopbackPorts(2)
        let remote = Endpoint(address: IPv4Address.loopback, port: ports[0])
        let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: ports[1]))
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testStartTwoConnectionsSameContext() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()
        harness.teardown()
    }

    // MARK: - Edge case payloads (UDP)

    func testEmptyPayload() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectDeliver([])
        harness.teardown()
    }

    func testMaxSizeDatagram() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectDeliver((0..<1472).map { UInt8($0 % 256) })
        harness.teardown()
    }

    func testPayloadWithAllByteValues() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectDeliver((0...255).map { UInt8($0) })
        harness.teardown()
    }

    // MARK: - Multiple sequential echoes (UDP)

    func testEcho10RoundTrips() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectSequentialEcho(count: 10, timeout: 30.0) { [UInt8($0), UInt8($0 &* 2)] }
        harness.teardown()
    }

    func testEcho50RoundTripsLargePayload() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectSequentialEcho(count: 50) { [UInt8](repeating: UInt8($0 % 256), count: 1000) }
        harness.teardown()
    }

    // MARK: - IPv6 additional tests (UDP)

    func testIPv6SingleByte() {
        let harness = UDPLoopbackHarness(ipv6: true)
        harness.start()
        harness.expectDeliver([0x42])
        harness.teardown()
    }

    func testIPv6BidirectionalEcho() {
        let harness = UDPLoopbackHarness(ipv6: true)
        harness.start()

        let bothDone = XCTestExpectation(description: "both echoed")
        bothDone.expectedFulfillmentCount = 2
        let payloadA: [UInt8] = [0xAA, 0xBB, 0xCC]
        let payloadB: [UInt8] = [0xDD, 0xEE, 0xFF]

        harness.c1.send(.message(content: payloadA)) { _ in }
        harness.c2.send(.message(content: payloadB)) { _ in }

        harness.c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadA)
            } else {
                XCTFail("c2 recv failed")
            }
            bothDone.fulfill()
        }
        harness.c1.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadB)
            } else {
                XCTFail("c1 recv failed")
            }
            bothDone.fulfill()
        }

        wait(for: [bothDone], timeout: 10.0)
        harness.teardown()
    }

    // MARK: - Rapid send-receive patterns (UDP)

    func testAlternatingSendReceive() {
        let harness = UDPLoopbackHarness()
        harness.start()

        let allDone = XCTestExpectation(description: "alternating")
        let count = 20
        nonisolated(unsafe) var completed = 0
        let c1 = harness.c1
        let c2 = harness.c2

        @Sendable func step(_ i: Int) {
            guard i < count else {
                allDone.fulfill()
                return
            }
            // Even iterations flow c1 -> c2, odd iterations c2 -> c1.
            let sender = i % 2 == 0 ? c1 : c2
            let receiver = i % 2 == 0 ? c2 : c1
            sender.send(.message(content: [UInt8(i)])) { _ in }
            receiver.receive { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, [UInt8(i)])
                    completed += 1
                }
                step(i + 1)
            }
        }
        step(0)

        wait(for: [allDone], timeout: 30.0)
        XCTAssertEqual(completed, count)
        harness.teardown()
    }

    func testBurst50ThenDrain() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.expectBurstThenDrain((0..<50).map { [UInt8($0 % 256)] })
        harness.teardown()
    }

    func testSendReceiveWithRandomPayloadSizes() {
        let harness = UDPLoopbackHarness()
        harness.start()
        let sizes = [7, 13, 42, 100, 256, 500, 1, 1000, 3, 1400]
        harness.expectSequentialDeliver(sizes.map { (0..<$0).map { UInt8($0 % 256) } })
        harness.teardown()
    }

    // MARK: - TCP / SocketStreamProtocol tests
    //
    // The stream tests need an actual server side because TCP is connection-
    // oriented; the loopback datagram pattern of "two peers binding to each
    // other's port" doesn't work. TCPClientHarness spins up a TCPEchoServer (a
    // tiny POSIX listener that accepts one connection and echoes everything
    // back until EOF) and drives NetworkConnection<TCP> as the client.

    // MARK: - Connection lifecycle (TCP)

    func testTCPConnectionStateLifecycle() {
        let harness = TCPClientHarness()
        harness.start()
        harness.waitReady()
        harness.teardown()
    }

    func testTCPConnectionRefusedDeliversFailure() {
        // Nothing is listening on this port, so connect must fail. `.ready` is asserted absent from
        // the recorded sequence, which catches it anywhere before the failure rather than only
        // during a fixed wait, and the sequence is dumped when it does appear.
        let failed = XCTestExpectation(description: "tcp failed")
        let cancelled = XCTestExpectation(description: "tcp cancelled")
        let observedStates = NetworkMutex<[NetworkConnection<TCP>.State]>([])

        let remote = Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort())
        let conn = NetworkConnection(to: remote, using: makeTCPParams())
            .onStateUpdate { _, state in
                observedStates.withLock { $0.append(state) }
                if case .failed = state { failed.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
            }
        conn.start()
        wait(for: [failed], timeout: 5.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)

        let states = observedStates.withLock { $0 }
        XCTAssertFalse(
            states.contains(.ready),
            "connection reported ready with nothing listening on the port: \(states)"
        )
    }

    // MARK: - Basic data path (TCP)

    func testTCPRoundTripEchoIPv4() {
        let harness = TCPClientHarness()
        harness.start()
        harness.expectEcho([1, 2, 3, 4, 5])
        harness.teardown()
    }

    func testTCPRoundTripEchoIPv6() {
        let harness = TCPClientHarness(ipv6: true)
        harness.start()
        harness.expectEcho([10, 20, 30])
        harness.teardown()
    }

    func testTCPSendSingleByte() {
        let harness = TCPClientHarness()
        harness.start()
        harness.expectEcho([0xFF])
        harness.teardown()
    }

    func testTCPLargePayloadEcho() {
        let harness = TCPClientHarness()
        harness.start()
        // Stream may deliver the echo across multiple receives — drain.
        harness.expectEcho([UInt8](repeating: 0xAB, count: 8192), drain: true)
        harness.teardown()
    }

    func testTCPMultipleSequentialMessages() {
        let harness = TCPClientHarness()
        harness.start()
        harness.expectSequentialEcho([
            [1], [2, 3], [4, 5, 6], [7, 8, 9, 10], [11, 12, 13, 14, 15],
        ])
        harness.teardown()
    }

    // MARK: - Volume / stress (TCP)

    func testTCPHighVolumeEcho100Messages() {
        let harness = TCPClientHarness()
        harness.start()
        harness.expectSequentialEcho(count: 100) { [UInt8($0 % 256), UInt8(($0 + 1) % 256)] }
        harness.teardown()
    }

    func testTCPVaryingPayloadSizes() {
        let harness = TCPClientHarness()
        harness.start()
        let sizes = [1, 100, 500, 1000, 1400, 4096, 10]
        harness.expectSequentialEcho(sizes.map { [UInt8](repeating: 0xAA, count: $0) }, drain: true)
        harness.teardown()
    }

    // MARK: - Backpressure / lifecycle (TCP)

    func testTCPBurstSendsThenDrain() {
        let harness = TCPClientHarness()
        harness.start()
        // Wait until connected before bursting: on Linux, sending on a socket
        // that is still connecting fails immediately with ENOBUFS.
        harness.waitReady()

        let allDrained = XCTestExpectation(description: "tcp drained")
        let messageCount = 50
        let perMessage: [UInt8] = [0xDE, 0xAD]
        for i in 0..<messageCount {
            harness.conn.send(.message(content: perMessage)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }
        }

        // The echo of all sends arrives as one stream; drain the total byte count.
        let totalBytes = messageCount * perMessage.count
        nonisolated(unsafe) var collected: [UInt8] = []
        let conn = harness.conn
        @Sendable func drain() {
            let need = totalBytes - collected.count
            conn.receive(atLeast: 1, atMost: need) { result in
                if case .success(let msg) = result, let bytes = msg.content {
                    collected.append(contentsOf: bytes)
                    if collected.count >= totalBytes {
                        allDrained.fulfill()
                    } else {
                        drain()
                    }
                } else {
                    XCTFail("receive failed at \(collected.count)")
                }
            }
        }
        drain()

        wait(for: [allDrained], timeout: 30.0)
        XCTAssertEqual(collected.count, totalBytes)
        harness.teardown()
    }

    func testTCPDelayedConsumer() {
        let harness = TCPClientHarness()
        harness.start()
        harness.waitReady()

        let done = XCTestExpectation(description: "delayed tcp consumer")
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let conn = harness.conn
        conn.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }
        // Delay the receive by 500ms — bytes should still be buffered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            conn.receive(atLeast: payload.count, atMost: payload.count) { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, payload)
                } else {
                    XCTFail("delayed receive failed")
                }
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 10.0)
        harness.teardown()
    }

    func testTCPPayloadWithAllByteValues() {
        let harness = TCPClientHarness()
        harness.start()
        harness.expectEcho((0...255).map { UInt8($0) })
        harness.teardown()
    }

    func testTCPCancelBeforeStart() {
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let remote = Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort())
        let conn = NetworkConnection(to: remote, using: makeTCPParams())
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // MARK: - Echo round trips (TCP)

    func testTCPEcho10RoundTrips() {
        let harness = TCPClientHarness()
        harness.start()
        harness.expectSequentialEcho(count: 10, timeout: 30.0) {
            [UInt8($0), UInt8($0 &* 2), UInt8($0 &* 3)]
        }
        harness.teardown()
    }

    // MARK: - Shared base-class behaviour (SocketProtocolBase)
    //
    // These tests exercise paths that run through the shared base:
    // bindSocket, cancelWriteSource, setupReadSource/WriteSource,
    // and the teardown/reinit lifecycle — verified through both
    // SocketDatagramProtocol (UDP) and SocketStreamProtocol (TCP).

    // Verifies that a cancelled connection can be garbage-collected promptly
    // (exercises deinit / teardown paths on both concrete types).
    func testUDPTeardownIsClean() {
        let harness = UDPLoopbackHarness()
        harness.c1.start()
        harness.c1.cancel()
        // teardown() waits for both peers' cancelled state; c2 was never
        // started, but cancel still drives it to cancelled.
        harness.teardown()
        // If teardown is wrong (e.g. write source not resumed before cancel)
        // the DispatchSource will trap on dealloc — reaching here means it is clean.
    }

    // Cancelling before the socket even has a chance to become writable must
    // not crash (exercises the write-source suspend path in cancelWriteSource).
    func testUDPCancelImmediatelyAfterStart() {
        let cancelled = XCTestExpectation(description: "cancelled immediately")
        let ports = discoverFreeLoopbackPorts(2)
        let remote = Endpoint(address: IPv4Address.loopback, port: ports[0])
        let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: ports[1]))
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }
        conn.start()
        // Cancel on the very next runloop tick — write source may still be
        // suspended (never received EAGAIN).
        DispatchQueue.main.async { conn.cancel() }
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPCancelImmediatelyAfterStart() {
        let cancelled = XCTestExpectation(description: "tcp cancelled immediately")
        let remote = Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort())
        let conn = NetworkConnection(to: remote, using: makeTCPParams())
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }
        conn.start()
        DispatchQueue.main.async { conn.cancel() }
        wait(for: [cancelled], timeout: 5.0)
    }

    // Exercises bindSocket through the base class.
    func testUDPBindToExplicitLocalPort() {
        let ready = XCTestExpectation(description: "bound udp ready")
        let cancelled = XCTestExpectation(description: "bound udp cancelled")

        // An explicit localPort verifies bindSocket in the base class succeeds
        // without error.
        let ports = discoverFreeLoopbackPorts(2)
        let remote = Endpoint(address: IPv4Address.loopback, port: ports[0])
        let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: ports[1]))
            .onStateUpdate { _, state in
                if case .ready = state { ready.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
            }
        conn.start()
        wait(for: [ready], timeout: 5.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // Verifies that the write-source fires and triggerOutboundRoomAvailable
    // is called after a datagram send — the upper layer gets the room event.
    func testUDPOutboundRoomAvailableAfterSend() {
        let harness = UDPLoopbackHarness()
        harness.start()

        let sent = XCTestExpectation(description: "sent")
        harness.c1.send(.message(content: [0x01, 0x02])) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5.0)
        harness.teardown()
    }

    // Verifies write-source / triggerOutboundRoomAvailable for TCP.
    func testTCPOutboundRoomAvailableAfterSend() {
        let harness = TCPClientHarness()
        harness.start()
        harness.waitReady()

        let sent = XCTestExpectation(description: "tcp sent")
        harness.conn.send(.message(content: [0xAA])) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5.0)
        harness.teardown()
    }

    // Multiple sequential start/cancel cycles — verifies repeated teardown
    // goes through the base-class cleanup without double-freeing sources.
    func testUDPMultipleCancelCycles() {
        for cycle in 0..<3 {
            let cancelled = XCTestExpectation(description: "cycle \(cycle) cancelled")
            let ports = discoverFreeLoopbackPorts(2)
            let remote = Endpoint(address: IPv4Address.loopback, port: ports[0])
            let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: ports[1]))
                .onStateUpdate { _, state in
                    if case .cancelled = state { cancelled.fulfill() }
                }
            conn.start()
            conn.cancel()
            wait(for: [cancelled], timeout: 5.0)
        }
    }

    func testTCPMultipleCancelCycles() {
        for _ in 0..<3 {
            let harness = TCPClientHarness()
            harness.start()
            harness.waitReady()
            harness.teardown()
        }
    }

    // MARK: - Receive across segment boundaries (regression)
    //
    // Reproduces a stall: when receive(atLeast:) requests more bytes than
    // arrive in the first TCP segment, the bottom delivers the first segment,
    // the consumer's receiveStreamData returns nil (< minimumBytes), and the
    // read source is left suspended. If the read source is only re-armed on a
    // *successful* drain, the bytes that arrive in a later segment are never
    // read and the receive never completes.
    //
    // SplitSendServer pushes `total` bytes as two NODELAY segments separated by
    // a gap, so the first segment is processed (and the source suspended)
    // before the rest arrives. With a correct implementation this completes
    // promptly; with the stall it times out.
    func testTCPReceiveAtLeastSpanningTwoSegments() {
        let firstChunk = 4
        let total = 16  // atLeast spans both segments

        let harness = TCPClientHarness(
            server: SplitSendServer(firstChunk: firstChunk, total: total, gap: 0.5)
        )
        harness.start()

        let done = XCTestExpectation(description: "received full payload across segments")
        harness.conn.receive(atLeast: total, atMost: total) { result in
            switch result {
            case .success(let msg):
                XCTAssertEqual(msg.content?.count, total)
                done.fulfill()
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        harness.teardown()
    }

    // MARK: - EOF handling (regression)

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        #if canImport(Darwin) || canImport(Android)
        getrusage(RUSAGE_SELF, &usage)
        #else
        getrusage(RUSAGE_SELF.rawValue, &usage)
        #endif
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    // Regression: after the peer half-closes (EOF), the read source must stop
    // firing. Previously it stayed armed and EOF keeps the descriptor readable,
    // so the read handler re-fired forever and pegged a CPU core. We detect the
    // spin by measuring process CPU consumed during an idle window after EOF —
    // a busy-loop burns ~a full core; correct behavior consumes ~nothing.
    func testTCPNoBusyLoopAfterEOF() {
        let harness = TCPClientHarness(
            server: ClosingServer(payload: [1, 2, 3, 4])
        )
        harness.start()

        let received = XCTestExpectation(description: "received payload")
        harness.conn.receive(atLeast: 4, atMost: 4) { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, [1, 2, 3, 4])
            } else {
                XCTFail("receive failed")
            }
            received.fulfill()
        }
        wait(for: [received], timeout: 5.0)

        // Both sleeps are load-bearing. The first waits for the bottom to observe the peer's FIN,
        // which has no observable substitute: a second `receive` never completes on it.
        //
        // The second *is* the measurement -- no read event firing is only observable as an absence
        // over an interval -- and it has to stay long, because the assertion is a ratio of CPU to
        // wall time and a short window reports one descheduling of this process as noise.
        Thread.sleep(forTimeInterval: 0.3)
        let before = Self.processCPUSeconds()
        Thread.sleep(forTimeInterval: 1.0)
        let cpu = Self.processCPUSeconds() - before
        XCTAssertLessThan(
            cpu,
            0.3,
            "read source appears to busy-loop after EOF (consumed \(cpu)s CPU while idle)"
        )

        harness.teardown()
    }
}

#if canImport(Darwin)

// MARK: - Socket behaviour

// The tests below check what the socket protocols do to the kernel socket. They find the
// connection's socket by scanning this process's descriptors for one whose peer is the test
// server, then read its state with getsockopt. They use Darwin socket options and sockaddr
// layouts, so they build only on Darwin.

private func peerPort(of fd: CInt) -> UInt16? {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
    }
    guard result == 0 else { return nil }
    return withUnsafePointer(to: &storage) { pointer -> UInt16? in
        switch CInt(pointer.pointee.ss_family) {
        case AF_INET:
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt16(bigEndian: $0.pointee.sin_port)
            }
        case AF_INET6:
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                UInt16(bigEndian: $0.pointee.sin6_port)
            }
        default:
            return nil
        }
    }
}

/// Returns every descriptor in this process that is a socket of `type` connected to `port` on
/// loopback, in ascending order. The Swift socket protocol dups its socket for its dispatch
/// sources, so a connection normally owns two of them. The lower one is normally the original,
/// because the protocol creates the socket before it dups it.
private func descriptors(connectedTo port: UInt16, type: CInt) -> [CInt] {
    (0..<getdtablesize()).filter { fd in
        intOption(fd, SOL_SOCKET, SO_TYPE) == type && peerPort(of: fd) == port
    }
}

private func intOption(_ fd: CInt, _ level: CInt, _ name: CInt) -> CInt? {
    var value: CInt = 0
    var length = socklen_t(MemoryLayout<CInt>.size)
    guard getsockopt(fd, level, name, &value, &length) == 0 else { return nil }
    return value
}

private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
    return address
}

/// Waits up to `timeout` seconds for a connection's socket to appear, then returns the
/// descriptors that `descriptors(connectedTo:type:)` finds.
private func waitForDescriptors(connectedTo port: UInt16, type: CInt, timeout: TimeInterval = 5) -> [CInt] {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let found = descriptors(connectedTo: port, type: type)
        if !found.isEmpty { return found }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return []
}

/// Opens a UDP socket bound to an ephemeral loopback port, to stand in for a peer. Close it when
/// you're done.
@available(Network 0.1.0, *)
private func boundUDPPeer() -> (fd: CInt, port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    var address = loopbackAddress(port: 0)
    _ = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return (fd, boundPortOfDescriptor(fd))
}

nonisolated(unsafe) private var sigpipeCount = 0

/// Records the error a connection failed with, if it failed.
@available(Network 0.1.0, *)
private final class RecordedFailure: @unchecked Sendable {
    private let mutex = NetworkMutex<NetworkError?>(nil)
    var error: NetworkError? { mutex.withLock { $0 } }
    func record(_ error: NetworkError) { mutex.withLock { $0 = error } }
}

@available(Network 0.1.0, *)
extension SwiftNetworkSocketTests {

    // MARK: - Helpers

    private func readyTCPConnection(
        server: any SocketTestServer,
        parameters: ParametersBuilder<TCP>
    ) -> (NetworkConnection<TCP>, XCTestExpectation) {
        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")
        let connection = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: server.listeningPort),
            using: parameters
        )
        connection.onStateUpdate { _, state in
            if case .ready = state { ready.fulfill() }
            if case .cancelled = state { cancelled.fulfill() }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        return (connection, cancelled)
    }

    private func readyUDPConnection(
        to port: UInt16,
        using parameters: ParametersBuilder<UDP>
    ) -> (NetworkConnection<UDP>, XCTestExpectation, RecordedFailure) {
        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")
        let failure = RecordedFailure()
        let connection = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: port), using: parameters)
        connection.onStateUpdate { _, state in
            switch state {
            case .ready: ready.fulfill()
            case .failed(let error): failure.record(error)
            case .cancelled: cancelled.fulfill()
            default: break
            }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        return (connection, cancelled, failure)
    }

    /// Runs `body` on the context's queue and returns its result. The harnesses expect their calls
    /// to come from the context.
    private func onContext<T>(_ context: NetworkContext, _ body: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        context.async {
            result = body()
            done.signal()
        }
        done.wait()
        return result!
    }

    /// Attaches a stream upper harness to a SocketStreamProtocol instance and starts it. Run the
    /// returned harness's calls on `context`.
    private func connectedStreamHarness(
        to remote: Endpoint,
        storage: TestNetworkProtocolStorage,
        parameters: Parameters,
        prepare: ((SocketStreamProtocol) -> Void)? = nil
    ) throws -> StreamUpperHarness<TestStreamLinkageFamily> {
        let context = parameters.context
        let path = PathProperties(parameters: parameters)
        let local = Endpoint(address: IPv4Address.loopback, port: 0)
        let connected = XCTestExpectation(description: "connected")
        var harness: StreamUpperHarness<TestStreamLinkageFamily>?
        context.async {
            let upper = storage.createTestStreamUpperHarness(
                local: local,
                remote: remote,
                parameters: parameters,
                path: path
            )
            let lower = storage.createTestSocketStreamInstance()
            if let prepare {
                storage.socketStreamInstances.forEachElement { instance in
                    if instance.identifier == lower.identifier { prepare(instance) }
                }
            }
            do {
                try TestInboundStreamLinkage(harness: upper).invokeAttachLowerProtocol(
                    lower,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            } catch {
                // The harness registered itself when it was created, so tear it down here.
                // Returning no harness keeps the test from stopping one that never attached.
                XCTFail("Failed to attach the socket protocol: \(error)")
                upper.teardown()
                connected.fulfill()
                return
            }
            harness = upper
            upper.start { isConnected in
                XCTAssertTrue(isConnected)
                connected.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 5), .completed)
        return try XCTUnwrap(harness)
    }

    /// Attaches a datagram upper harness to a SocketDatagramProtocol instance and starts it.
    private func connectedDatagramHarness(
        local: Endpoint,
        remote: Endpoint,
        storage: TestNetworkProtocolStorage,
        parameters: Parameters,
        prepare: ((SocketDatagramProtocol) -> Void)? = nil
    ) throws -> DatagramUpperHarness<TestDatagramLinkageFamily> {
        let context = parameters.context
        let path = PathProperties(parameters: parameters)
        let connected = XCTestExpectation(description: "connected")
        var harness: DatagramUpperHarness<TestDatagramLinkageFamily>?
        context.async {
            let upper = storage.createTestDatagramUpperHarness(
                local: local,
                remote: remote,
                parameters: parameters,
                path: path
            )
            let lower = storage.createTestSocketDatagramInstance()
            if let prepare {
                storage.socketDatagramInstances.forEachElement { instance in
                    if instance.identifier == lower.identifier { prepare(instance) }
                }
            }
            do {
                try TestInboundDatagramLinkage(harness: upper).invokeAttachLowerProtocol(
                    lower,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            } catch {
                // The harness registered itself when it was created, so tear it down here.
                // Returning no harness keeps the test from stopping one that never attached.
                XCTFail("Failed to attach the socket protocol: \(error)")
                upper.teardown()
                connected.fulfill()
                return
            }
            harness = upper
            upper.start { isConnected in
                XCTAssertTrue(isConnected)
                connected.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 5), .completed)
        return try XCTUnwrap(harness)
    }

    /// Sends one datagram on the context, from a frame that carries the values `configure` sets.
    private func send(
        _ payload: [UInt8],
        from harness: DatagramUpperHarness<TestDatagramLinkageFamily>,
        on context: NetworkContext,
        configure: @escaping (inout Frame) -> Void
    ) {
        onContext(context) {
            do {
                guard
                    var frames = try harness.invokeGetDatagramsToSend(
                        maximumDatagramCount: 1,
                        minimumDatagramSize: payload.count
                    )
                else {
                    return XCTFail("no datagram to send")
                }
                frames.iterateMutableFrames { frame in
                    _ = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                        try write.buffer(payload)
                    }
                    frame.collapse()
                    _ = frame.unclaim(fromStart: payload.count)
                    configure(&frame)
                    return false
                }
                try harness.invokeSendDatagrams(frames)
            } catch {
                XCTFail("send failed: \(error)")
            }
        }
    }

    /// Opens a loopback TCP listener for a test to accept on. Close it when you're done.
    private func loopbackListener() -> (fd: CInt, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopbackAddress(port: 0)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(listen(fd, 4), 0)
        return (fd, boundPortOfDescriptor(fd))
    }

    /// Accepts one connection on `listener` and returns its descriptor, or -1 after five seconds.
    /// The timeout makes a connection that never arrives fail the test. Without it, the test never
    /// finishes.
    private func acceptWithTimeout(_ listener: CInt) -> CInt {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5000) == 1 else { return -1 }
        return accept(listener, nil, nil)
    }

    /// Reads one byte from `fd` and returns the result and errno. The read gives up after two
    /// seconds.
    private func readOnce(_ fd: CInt) -> (result: Int, errno: CInt) {
        setReceiveTimeout(fd)
        var byte: UInt8 = 0
        let result = read(fd, &byte, 1)
        return (result, errno)
    }

    /// Binds a Unix-domain socket of `type` to a fresh path in the temporary directory. Close the
    /// descriptor and remove the path when you're done.
    private func unixSocket(type: CInt) throws -> (fd: CInt, path: String) {
        let path = NSTemporaryDirectory() + "swnet-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let fd = socket(AF_UNIX, type, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        try XCTSkipUnless(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path), "temporary path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "couldn't bind \(path): errno \(errno)")
        return (fd, path)
    }

    /// Sets a receive timeout on `fd`, so a read that gets nothing fails the test instead of
    /// blocking it forever.
    private func setReceiveTimeout(_ fd: CInt, seconds: Int = 2) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // Stopping a harness isn't enough. Teardown reaches the socket protocol and cancels its
    // dispatch sources, so a late event, such as the peer's FIN, can't arrive after the storage
    // lets go of the instances.
    private func stopAndTearDown(_ harness: StreamUpperHarness<TestStreamLinkageFamily>, on context: NetworkContext) {
        onContext(context) {
            harness.stop()
            harness.teardown()
        }
    }

    private func stopAndTearDown(
        _ harness: DatagramUpperHarness<TestDatagramLinkageFamily>,
        on context: NetworkContext
    ) {
        onContext(context) {
            harness.stop()
            harness.teardown()
        }
    }

    // MARK: - TCP options

    /// The stream protocol applies TCP_NODELAY and the keepalive options from the TCP options.
    /// SO_SNDLOWAT and IP_TTL are controls. The Swift protocol sets SO_SNDLOWAT on every socket and
    /// applies IP_TTL from the IP options, so they show that the scan found the right socket and
    /// that the parameters reached setup.
    func testTCPOptionsReachTheSocket() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }

        let parameters = ParametersBuilder<TCP>.parameters {
            TCP {
                IP().hopLimit(7)
            }
            .noDelay(true)
            .enableKeepalive(true)
            .keepalive(idleTime: 37, count: 3, interval: 11)
        }
        let (connection, cancelled) = readyTCPConnection(server: server, parameters: parameters)

        let fds = descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM)
        XCTAssertFalse(fds.isEmpty, "found no socket connected to the test server")
        for fd in fds {
            XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_SNDLOWAT), 1, "control: SO_SNDLOWAT on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TTL), 7, "control: IP_TTL on fd \(fd)")
            XCTAssertNotEqual(intOption(fd, IPPROTO_TCP, TCP_NODELAY), 0, "TCP_NODELAY on fd \(fd)")
            XCTAssertNotEqual(intOption(fd, SOL_SOCKET, SO_KEEPALIVE), 0, "SO_KEEPALIVE on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_KEEPALIVE), 37, "TCP_KEEPALIVE on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_KEEPINTVL), 11, "TCP_KEEPINTVL on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_KEEPCNT), 3, "TCP_KEEPCNT on fd \(fd)")
        }

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    // MARK: - SIGPIPE

    /// The stream protocol sets SO_NOSIGPIPE on its socket.
    func testTCPSocketSetsNoSIGPIPE() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }

        let (connection, cancelled) = readyTCPConnection(server: server, parameters: makeTCPParams())
        let fds = descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM)
        XCTAssertFalse(fds.isEmpty, "found no socket connected to the test server")
        for fd in fds {
            XCTAssertNotEqual(intOption(fd, SOL_SOCKET, SO_NOSIGPIPE), 0, "SO_NOSIGPIPE on fd \(fd)")
        }

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// Writing to a peer that has closed must fail the send without raising SIGPIPE. The server
    /// closes without reading, so the client sees EOF and stays connected. Its first write draws
    /// an RST, and the writes after that hit a reset socket. The test counts SIGPIPE with its own
    /// handler, so a missing SO_NOSIGPIPE shows up as a count instead of ending the test runner.
    func testTCPWriteToClosedPeerDoesNotRaiseSIGPIPE() throws {
        var previous = sigaction()
        var counting = sigaction()
        counting.__sigaction_u.__sa_handler = { _ in sigpipeCount += 1 }
        sigemptyset(&counting.sa_mask)
        XCTAssertEqual(sigaction(SIGPIPE, &counting, &previous), 0)
        defer { _ = sigaction(SIGPIPE, &previous, nil) }
        sigpipeCount = 0

        let server = ClosingServer(payload: [])
        try server.start()
        defer { server.stop() }

        let cancelled = XCTestExpectation(description: "cancelled")
        let ready = XCTestExpectation(description: "ready")
        let events = NetworkMutex<[String]>([])
        let connection = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: server.listeningPort),
            using: makeTCPParams()
        )
        connection.onStateUpdate { _, state in
            events.withLock { $0.append("state \(state)") }
            if case .ready = state { ready.fulfill() }
            if case .cancelled = state { cancelled.fulfill() }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        // Let the FIN arrive before writing.
        Thread.sleep(forTimeInterval: 0.2)

        for index in 0..<5 {
            events.withLock { $0.append("send \(index), SIGPIPE so far \(sigpipeCount)") }
            connection.send(.message(content: [UInt8](repeating: 0x5A, count: 1024))) { result in
                events.withLock { $0.append("send \(index) completed: \(result)") }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let log = events.withLock { $0 }
        XCTAssertTrue(log.contains { $0.hasPrefix("send 1 completed") }, "the sends never completed: \(log)")
        XCTAssertEqual(sigpipeCount, 0, "SIGPIPE raised: \(log)")

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    // MARK: - Connect errors

    /// The stream protocol reports the errno from a synchronous connect failure. Connecting a TCP
    /// socket to a multicast address fails synchronously, and the test checks the expected errno
    /// with a plain socket first.
    func testTCPSynchronousConnectFailureReportsTheRealErrno() throws {
        let raw = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(raw, 0)
        _ = fcntl(raw, F_SETFL, fcntl(raw, F_GETFL) | O_NONBLOCK)
        var multicast = loopbackAddress(port: 80)
        multicast.sin_addr = in_addr(s_addr: inet_addr("224.0.0.1"))
        let result = withUnsafePointer(to: &multicast) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(raw, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let expected = errno
        close(raw)
        try XCTSkipIf(
            result == 0 || expected == EINPROGRESS,
            "connect to 224.0.0.1 didn't fail synchronously on this host"
        )

        let failed = XCTestExpectation(description: "failed")
        let cancelled = XCTestExpectation(description: "cancelled")
        let failure = NetworkMutex<NetworkError?>(nil)
        let address = try XCTUnwrap(IPv4Address("224.0.0.1"))
        let connection = NetworkConnection(to: Endpoint(address: address, port: 80), using: makeTCPParams())
        connection.onStateUpdate { _, state in
            if case .failed(let error) = state {
                failure.withLock { $0 = error }
                failed.fulfill()
            }
            if case .cancelled = state { cancelled.fulfill() }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 5), .completed)
        XCTAssertEqual(
            failure.withLock { $0 },
            .posix(expected),
            "a plain connect fails with errno \(expected) (\(String(cString: strerror(expected))))"
        )

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    // MARK: - UDP reads and writes

    /// The datagram protocol reads up to 9216 bytes per datagram, the kernel's default maximum.
    /// Loopback carries a 9000-byte datagram intact, so the receiver must get all of it.
    func testUDPDatagramLargerThan1500BytesArrivesIntact() {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()

        let payload = (0..<9000).map { UInt8(truncatingIfNeeded: $0) }
        let done = XCTestExpectation(description: "received")
        let received = NetworkMutex<[UInt8]?>(nil)
        harness.c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }
        harness.c2.receive { result in
            if case .success(let message) = result {
                received.withLock { $0 = message.content }
            }
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed)
        XCTAssertEqual(received.withLock { $0 }, payload)

        harness.teardown()
    }

    /// A connected UDP socket reports ECONNREFUSED on its next read after the peer port sends an
    /// ICMP port unreachable. The control shows that the kernel does this on loopback, and that the
    /// read consumes the error, so the read after it would block. UDP can recover from such an
    /// error, so the connection must stay ready, and must send and receive once something listens
    /// on the port.
    func testUDPReadErrorKeepsTheFlow() throws {
        let peerPort = discoverFreeLoopbackPort()

        let raw = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(raw, 0)
        var destination = loopbackAddress(port: peerPort)
        _ = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(raw, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var byte: UInt8 = 1
        _ = write(raw, &byte, 1)
        Thread.sleep(forTimeInterval: 0.2)
        _ = fcntl(raw, F_SETFL, fcntl(raw, F_GETFL) | O_NONBLOCK)
        let readResult = read(raw, &byte, 1)
        let readErrno = errno
        let secondRead = read(raw, &byte, 1)
        let secondErrno = errno
        close(raw)
        try XCTSkipUnless(
            readResult < 0 && readErrno == ECONNREFUSED,
            "control: the kernel didn't report ECONNREFUSED (read \(readResult), errno \(readErrno))"
        )
        XCTAssertTrue(
            secondRead < 0 && secondErrno == EWOULDBLOCK,
            "control: the read after the error didn't block (read \(secondRead), errno \(secondErrno))"
        )

        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")
        let failed = XCTestExpectation(description: "failed")
        failed.isInverted = true
        let observed = NetworkMutex<[String]>([])
        let localPort = discoverFreeLoopbackPort()
        let connection = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: peerPort),
            using: makeUDPParams(localPort: localPort)
        )
        connection.onStateUpdate { _, state in
            observed.withLock { $0.append("state \(state)") }
            switch state {
            case .ready: ready.fulfill()
            case .failed: failed.fulfill()
            case .cancelled: cancelled.fulfill()
            default: break
            }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)

        // Nothing listens on the peer port yet, so this datagram draws a port unreachable, and the
        // connection's next read fails with ECONNREFUSED.
        connection.send(.message(content: [1, 2, 3])) { _ in }
        wait(for: [failed], timeout: 0.5)

        // Bring the peer up. The connection must still send to it and receive from it.
        let peer = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var peerAddress = loopbackAddress(port: peerPort)
        let bound = withUnsafePointer(to: &peerAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(peer, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "couldn't bind the peer to port \(peerPort): errno \(errno)")
        setReceiveTimeout(peer)

        connection.send(.message(content: [4, 5, 6])) { _ in }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = read(peer, &buffer, buffer.count)
        XCTAssertEqual(count, 3, "the peer got nothing after the error: \(observed.withLock { $0 })")
        XCTAssertEqual(Array(buffer.prefix(3)), [4, 5, 6])

        let received = XCTestExpectation(description: "received")
        let content = NetworkMutex<[UInt8]?>(nil)
        connection.receive { result in
            if case .success(let message) = result {
                content.withLock { $0 = message.content }
            }
            received.fulfill()
        }
        var reply: [UInt8] = [7, 8, 9]
        var connectionAddress = loopbackAddress(port: localPort)
        let sent = withUnsafePointer(to: &connectionAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(peer, &reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 3)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 2), .completed)
        XCTAssertEqual(content.withLock { $0 }, [7, 8, 9])
        XCTAssertFalse(
            observed.withLock { $0 }.contains { $0.hasPrefix("state failed") },
            "\(observed.withLock { $0 })"
        )

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// The datagram protocol keeps a datagram and waits for room when its write would block.
    /// Loopback UDP never fills its send buffer, so the test swaps the connection's original
    /// descriptor for a full AF_UNIX stream socket with dup2, and the next write returns EAGAIN.
    /// The dispatch sources watch the dup'd descriptor, which the test leaves alone. A full
    /// AF_UNIX datagram socket would return ENOBUFS on Darwin instead, so the test uses a stream
    /// socket. When the test drains the AF_UNIX peer, the datagram must arrive after the filler.
    func testUDPWriteThatWouldBlockWaitsForRoom() throws {
        // The test never reads from this peer.
        let (peer, peerPort) = boundUDPPeer()
        defer { close(peer) }

        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")
        let failed = XCTestExpectation(description: "failed")
        failed.isInverted = true
        let failure = NetworkMutex<NetworkError?>(nil)
        let connection = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: peerPort),
            using: makeUDPParams(localPort: discoverFreeLoopbackPort())
        )
        connection.onStateUpdate { _, state in
            switch state {
            case .ready: ready.fulfill()
            case .failed(let error):
                failure.withLock { $0 = error }
                failed.fulfill()
            case .cancelled: cancelled.fulfill()
            default: break
            }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)

        let fds = descriptors(connectedTo: peerPort, type: SOCK_DGRAM)
        try XCTSkipIf(fds.count != 2, "expected the original and the dup'd descriptor, found \(fds)")

        var pair: [CInt] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        _ = fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL) | O_NONBLOCK)
        // Fill in large writes, then single bytes, so not even a one-byte write fits.
        var fillErrno: CInt = 0
        var filled = 0
        for chunk in [256, 1] {
            var filler = [UInt8](repeating: 0, count: chunk)
            fillErrno = 0
            for _ in 0..<1_000_000 {
                let written = write(pair[0], &filler, filler.count)
                if written < 0 {
                    fillErrno = errno
                    break
                }
                filled += written
            }
        }
        XCTAssertEqual(fillErrno, EAGAIN, "control: the AF_UNIX socket didn't fill up")

        XCTAssertEqual(dup2(pair[0], fds[0]), fds[0])
        connection.send(.message(content: [1, 2, 3])) { _ in }
        wait(for: [failed], timeout: 1)
        XCTAssertNil(failure.withLock { $0 }, "a write that would block failed the connection")

        // If the datagram reached the peer, the protocol wrote to a descriptor the test didn't
        // swap, and the result means nothing.
        _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) | O_NONBLOCK)
        var received = [UInt8](repeating: 0, count: 16)
        try XCTSkipIf(read(peer, &received, received.count) > 0, "the swapped descriptor wasn't the one written to")

        // Drain the AF_UNIX peer. Each read makes room, so the protocol's write source fires and
        // the datagram follows the filler.
        _ = fcntl(pair[1], F_SETFL, fcntl(pair[1], F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var drained: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while drained.count < filled + 3, Date() < deadline {
            let count = read(pair[1], &buffer, buffer.count)
            if count > 0 {
                drained.append(contentsOf: buffer[0..<count])
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        XCTAssertEqual(drained.count, filled + 3, "the datagram didn't follow the filler")
        XCTAssertEqual(Array(drained.suffix(3)), [1, 2, 3])
        XCTAssertNil(failure.withLock { $0 })

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// The datagram protocol drops a datagram that's too large to send and keeps the flow. The
    /// control shows that a UDP socket whose send buffer is smaller than the datagram fails the
    /// send with EMSGSIZE. The test shrinks the connection's send buffer the same way.
    func testUDPDatagramTooLargeToSendKeepsTheFlow() throws {
        let control = socket(AF_INET, SOCK_DGRAM, 0)
        var small: CInt = 2048
        _ = setsockopt(control, SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<CInt>.size))
        var controlPeer = loopbackAddress(port: 9)
        var big = [UInt8](repeating: 0, count: 4000)
        let controlResult = withUnsafePointer(to: &controlPeer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(control, &big, big.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let controlErrno = errno
        close(control)
        try XCTSkipUnless(
            controlResult < 0 && controlErrno == EMSGSIZE,
            "control: an oversize send didn't fail with EMSGSIZE (\(controlResult), errno \(controlErrno))"
        )

        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        setReceiveTimeout(peer.fd)

        let (connection, cancelled, failure) = readyUDPConnection(to: peer.port, using: makeUDPParams(localPort: 0))
        let fds = descriptors(connectedTo: peer.port, type: SOCK_DGRAM)
        try XCTSkipIf(fds.isEmpty, "found no socket connected to the peer")
        for fd in fds {
            XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<CInt>.size)), 0)
        }

        connection.send(.message(content: big)) { _ in }
        connection.send(.message(content: [1, 2, 3])) { _ in }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(peer.fd, &buffer, buffer.count)
        XCTAssertEqual(count, 3, "the datagram after the oversize one didn't arrive")
        XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNil(failure.error, "an oversize datagram failed the connection")

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    // MARK: - Options from the parameters

    /// The datagram protocol applies the IP options, as the stream protocol does.
    /// The first connection is the control. Without the options, the socket keeps the defaults.
    func testUDPIPOptionsReachTheSocket() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }

        let (plain, plainCancelled, _) = readyUDPConnection(to: peer.port, using: makeUDPParams(localPort: 0))
        let plainFDs = descriptors(connectedTo: peer.port, type: SOCK_DGRAM)
        XCTAssertFalse(plainFDs.isEmpty, "found no socket connected to the peer")
        for fd in plainFDs {
            XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TTL), 64, "control: IP_TTL on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_DONTFRAG), 0, "control: IP_DONTFRAG on fd \(fd)")
        }
        plain.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [plainCancelled], timeout: 5), .completed)

        let parameters = ParametersBuilder<UDP>.parameters {
            UDP {
                IP().hopLimit(7).fragmentationDisabled(true)
            }
        }
        let (connection, cancelled, _) = readyUDPConnection(to: peer.port, using: parameters)
        let fds = descriptors(connectedTo: peer.port, type: SOCK_DGRAM)
        XCTAssertFalse(fds.isEmpty, "found no socket connected to the peer")
        for fd in fds {
            XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TTL), 7, "IP_TTL on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_DONTFRAG), 1, "IP_DONTFRAG on fd \(fd)")
        }
        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// The datagram protocol sets UDP_NOCKSUM when the UDP options prefer no checksum. Passing
    /// false to noChecksumPreferred must leave the checksum on.
    func testUDPNoChecksumPreferenceReachesTheSocket() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }

        for preferNoChecksum in [false, true] {
            let parameters = ParametersBuilder<UDP>.parameters {
                UDP().noChecksumPreferred(preferNoChecksum)
            }
            let (connection, cancelled, _) = readyUDPConnection(to: peer.port, using: parameters)
            let fds = descriptors(connectedTo: peer.port, type: SOCK_DGRAM)
            XCTAssertFalse(fds.isEmpty, "found no socket connected to the peer")
            for fd in fds {
                // Darwin reports the option as the kernel's internal flag bit, so check for any
                // non-zero value.
                let value = try XCTUnwrap(intOption(fd, IPPROTO_UDP, UDP_NOCKSUM))
                XCTAssertEqual(
                    value != 0,
                    preferNoChecksum,
                    "UDP_NOCKSUM is \(value) on fd \(fd) with noChecksumPreferred(\(preferNoChecksum))"
                )
            }
            connection.cancel()
            XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        }
    }

    /// Both protocols set SO_REUSEADDR and SO_REUSEPORT when the parameters allow local address
    /// reuse.
    func testLocalAddressReuseReachesTheSocket() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        var udpParameters = makeUDPParams(localPort: 0)
        udpParameters.parameters.reuseLocalAddress = true
        let (udp, udpCancelled, _) = readyUDPConnection(to: peer.port, using: udpParameters)
        let udpFDs = descriptors(connectedTo: peer.port, type: SOCK_DGRAM)
        XCTAssertFalse(udpFDs.isEmpty, "found no UDP socket connected to the peer")
        for fd in udpFDs {
            XCTAssertNotEqual(intOption(fd, SOL_SOCKET, SO_REUSEADDR), 0, "SO_REUSEADDR on UDP fd \(fd)")
            XCTAssertNotEqual(intOption(fd, SOL_SOCKET, SO_REUSEPORT), 0, "SO_REUSEPORT on UDP fd \(fd)")
        }
        udp.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [udpCancelled], timeout: 5), .completed)

        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }
        var tcpParameters = makeTCPParams()
        tcpParameters.parameters.reuseLocalAddress = true
        let (tcp, tcpCancelled) = readyTCPConnection(server: server, parameters: tcpParameters)
        let tcpFDs = descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM)
        XCTAssertFalse(tcpFDs.isEmpty, "found no TCP socket connected to the server")
        for fd in tcpFDs {
            XCTAssertNotEqual(intOption(fd, SOL_SOCKET, SO_REUSEADDR), 0, "SO_REUSEADDR on TCP fd \(fd)")
            XCTAssertNotEqual(intOption(fd, SOL_SOCKET, SO_REUSEPORT), 0, "SO_REUSEPORT on TCP fd \(fd)")
        }
        tcp.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [tcpCancelled], timeout: 5), .completed)
    }

    /// The stream protocol applies the connection timeout, the retransmit drop time, and the
    /// persist timeout from the TCP options.
    func testTCPTimeoutsReachTheSocket() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }

        let parameters = ParametersBuilder<TCP>.parameters {
            TCP()
                .connectionTimeout(9)
                .retransmitConnectionDropTime(13)
                .persistTimeout(11)
        }
        let (connection, cancelled) = readyTCPConnection(server: server, parameters: parameters)
        let fds = descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM)
        XCTAssertFalse(fds.isEmpty, "found no socket connected to the test server")
        for fd in fds {
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT), 9, "TCP_CONNECTIONTIMEOUT on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_RXT_CONNDROPTIME), 13, "TCP_RXT_CONNDROPTIME on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, PERSIST_TIMEOUT), 11, "PERSIST_TIMEOUT on fd \(fd)")
        }
        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// Both protocols report the errno from a failed bind. Each connection asks for a local
    /// port that another socket already holds without SO_REUSEADDR, so bind fails with EADDRINUSE.
    func testBindFailureReportsTheRealErrno() throws {
        let holder = boundUDPPeer()
        defer { close(holder.fd) }
        let tcpHolder = loopbackListener()
        defer { close(tcpHolder.fd) }
        let tcpHeldPort = tcpHolder.port
        let peer = boundUDPPeer()
        defer { close(peer.fd) }

        let udpFailed = XCTestExpectation(description: "UDP failed")
        let udpFailure = NetworkMutex<NetworkError?>(nil)
        let udp = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: peer.port),
            using: makeUDPParams(localPort: holder.port)
        )
        udp.onStateUpdate { _, state in
            if case .failed(let error) = state {
                udpFailure.withLock { $0 = error }
                udpFailed.fulfill()
            }
        }
        udp.start()
        XCTAssertEqual(XCTWaiter.wait(for: [udpFailed], timeout: 5), .completed)
        XCTAssertEqual(udpFailure.withLock { $0 }, .posix(EADDRINUSE))
        udp.cancel()

        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }
        let tcpFailed = XCTestExpectation(description: "TCP failed")
        let tcpFailure = NetworkMutex<NetworkError?>(nil)
        let tcp = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: server.listeningPort),
            using: makeTCPParams(localPort: tcpHeldPort)
        )
        tcp.onStateUpdate { _, state in
            if case .failed(let error) = state {
                tcpFailure.withLock { $0 = error }
                tcpFailed.fulfill()
            }
        }
        tcp.start()
        XCTAssertEqual(XCTWaiter.wait(for: [tcpFailed], timeout: 5), .completed)
        XCTAssertEqual(tcpFailure.withLock { $0 }, .posix(EADDRINUSE))
        tcp.cancel()
    }

    /// The datagram protocol turns on DONTFRAG when QUIC runs over the socket, because QUIC
    /// discovers the path MTU itself. The peer never answers, so the handshake doesn't finish, but
    /// the socket exists from the first Initial packet.
    func testQUICSocketSetsDontFragment() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }

        let cancelled = XCTestExpectation(description: "cancelled")
        let connection = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: peer.port)) {
            QUIC(alpn: ["QUICTest"])
        }
        connection.onStateUpdate { _, state in
            if case .cancelled = state { cancelled.fulfill() }
        }
        connection.start()

        let fds = waitForDescriptors(connectedTo: peer.port, type: SOCK_DGRAM)
        XCTAssertFalse(fds.isEmpty, "found no socket connected to the peer")
        for fd in fds {
            XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_DONTFRAG), 1, "IP_DONTFRAG on fd \(fd)")
        }

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    // MARK: - Metrics

    /// The stream protocol reports a data transfer snapshot from the kernel's TCP statistics, and
    /// an establishment report with the time the connect took.
    func testTCPSocketReportsMetrics() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: server.listeningPort),
            storage: storage,
            parameters: parameters
        )

        defer { stopAndTearDown(harness, on: context) }

        let payload = [UInt8](repeating: 0x42, count: 1000)
        onContext(context) { XCTAssertTrue(harness.write(payload)) }
        var echoed = 0
        let deadline = Date().addingTimeInterval(5)
        while echoed < payload.count, Date() < deadline {
            echoed += onContext(context) { harness.read()?.count ?? 0 }
            if echoed < payload.count { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(echoed, payload.count, "the echo didn't come back")

        guard
            case .dataTransferSnapshot(let snapshot)? = onContext(
                context,
                {
                    harness.getMetrics(requestedNetworkMetric: .dataTransferSnapshot)
                }
            )
        else {
            return XCTFail("no data transfer snapshot")
        }
        XCTAssertGreaterThanOrEqual(snapshot.sentTransportByteCount, UInt64(payload.count))
        XCTAssertGreaterThanOrEqual(snapshot.receivedTransportByteCount, UInt64(payload.count))
        XCTAssertGreaterThan(snapshot.sentIPPacketCount, 0)
        XCTAssertGreaterThan(snapshot.receivedIPPacketCount, 0)
        XCTAssertGreaterThan(snapshot.transportCongestionWindow, 0)

        guard
            case .protocolEstablishmentReports(let reports)? = onContext(
                context,
                {
                    harness.getMetrics(requestedNetworkMetric: .protocolEstablishmentReports)
                }
            )
        else {
            return XCTFail("no establishment reports")
        }
        let report = try XCTUnwrap(reports.first { $0.protocolIdentifier == TCPProtocol.identifier })
        XCTAssertEqual(report.handshakeRTT, report.handshakeDuration)

    }

    /// The datagram protocol counts the bytes and datagrams it sends and receives, and reports them
    /// in the data transfer snapshot.
    func testUDPSocketReportsMetrics() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        setReceiveTimeout(peer.fd)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let localPort = discoverFreeLoopbackPort()
        let upper = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: localPort),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(upper, on: context) }

        onContext(context) { XCTAssertTrue(upper.write([1, 2, 3])) }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(peer.fd, &buffer, buffer.count), 3)

        var reply: [UInt8] = [4, 5, 6, 7, 8]
        var connectionAddress = loopbackAddress(port: localPort)
        let sent = withUnsafePointer(to: &connectionAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(peer.fd, &reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 5)
        var received: [UInt8]? = nil
        let deadline = Date().addingTimeInterval(5)
        while received == nil, Date() < deadline {
            received = onContext(context) { upper.read() }
            if received == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(received, reply)

        guard
            case .dataTransferSnapshot(let snapshot)? = onContext(
                context,
                {
                    upper.getMetrics(requestedNetworkMetric: .dataTransferSnapshot)
                }
            )
        else {
            return XCTFail("no data transfer snapshot")
        }
        XCTAssertEqual(snapshot.sentTransportByteCount, 3)
        XCTAssertEqual(snapshot.sentIPPacketCount, 1)
        XCTAssertEqual(snapshot.receivedTransportByteCount, 5)
        XCTAssertEqual(snapshot.receivedIPPacketCount, 1)

    }

    /// The TCP metadata's send buffer size is the bytes still in the socket's send buffer
    /// (SO_NWRITE). The server accepts but never reads, so the client's send buffer fills and
    /// stays full while the test compares the two.
    func testTCPAvailableSendBufferReportsTheUnsentBytes() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let serverPort = listener.port

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: serverPort),
            storage: storage,
            parameters: parameters
        )

        defer { stopAndTearDown(harness, on: context) }
        let accepted = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }

        onContext(context) { XCTAssertTrue(harness.write([UInt8](repeating: 0x42, count: 8 << 20))) }
        Thread.sleep(forTimeInterval: 0.5)

        let fds = descriptors(connectedTo: serverPort, type: SOCK_STREAM)
        let fd = try XCTUnwrap(fds.first, "found no socket connected to the server")
        let inSendBuffer = try XCTUnwrap(intOption(fd, SOL_SOCKET, SO_NWRITE))
        XCTAssertGreaterThan(inSendBuffer, 0, "control: the send buffer didn't fill")
        let metadata: ProtocolMetadata<TCPProtocol>? = onContext(context) { harness.getMetadata() }
        let tcpMetadata = try XCTUnwrap(metadata?.perProtocolMetadata)
        XCTAssertEqual(Int(tcpMetadata.getSendBufferSize()), Int(inSendBuffer))

        // Drain everything. Once the peer has read it all, the send buffer is empty, so the value
        // must drop to zero. The buffer's capacity, SO_SNDBUF, stays the same.
        _ = fcntl(accepted, F_SETFL, fcntl(accepted, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var drained = 0
        let deadline = Date().addingTimeInterval(10)
        while drained < 8 << 20, Date() < deadline {
            let count = read(accepted, &buffer, buffer.count)
            if count > 0 {
                drained += count
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        XCTAssertEqual(drained, 8 << 20, "the server didn't receive everything")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_NWRITE), 0, "control: the send buffer didn't empty")
        XCTAssertGreaterThan(intOption(fd, SOL_SOCKET, SO_SNDBUF) ?? 0, 0)
        XCTAssertEqual(tcpMetadata.getSendBufferSize(), 0)

    }

    // MARK: - Closing

    /// The stream protocol resets the connection when it's torn down while connected and
    /// nothing asked for a disconnect. That's a forced cancel. The peer's read fails with
    /// ECONNRESET where a graceful close would give it EOF.
    func testTCPForcedTeardownResetsTheConnection() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        )
        let accepted = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }

        onContext(context) { harness.teardown() }
        let (result, readErrno) = readOnce(accepted)
        XCTAssertEqual(result, -1, "the peer read \(result) bytes instead of failing")
        XCTAssertEqual(readErrno, ECONNRESET)
    }

    /// A graceful close must still send a FIN. The first harness stops before it's torn down, which
    /// disconnects the protocol. The second connection uses NetworkConnection.cancel(), which is how
    /// an app closes a connection.
    func testTCPGracefulCloseSendsFIN() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        )
        let harnessPeer = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(harnessPeer, 0)
        defer { close(harnessPeer) }
        let disconnected = XCTestExpectation(description: "disconnected")
        onContext(context) {
            harness.completions.disconnected = { disconnected.fulfill() }
            harness.stop()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 5), .completed)
        onContext(context) { harness.teardown() }
        let harnessRead = readOnce(harnessPeer)
        XCTAssertEqual(harnessRead.result, 0, "after stop, the peer read failed with errno \(harnessRead.errno)")

        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")
        let connection = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            using: makeTCPParams()
        )
        connection.onStateUpdate { _, state in
            if case .ready = state { ready.fulfill() }
            if case .cancelled = state { cancelled.fulfill() }
        }
        connection.start()
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let connectionPeer = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(connectionPeer, 0)
        defer { close(connectionPeer) }
        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        let connectionRead = readOnce(connectionPeer)
        XCTAssertEqual(
            connectionRead.result,
            0,
            "after cancel, the peer read failed with errno \(connectionRead.errno)"
        )
    }

    /// The stream protocol finishes the input and stops reading after a read error. The
    /// peer resets the connection, so the protocol's next read fails with ECONNRESET and the
    /// connection disconnects. No inbound data may follow.
    func testTCPReadErrorStopsTheInput() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        )
        defer { onContext(context) { harness.teardown() } }
        let accepted = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)

        let disconnected = XCTestExpectation(description: "disconnected")
        onContext(context) { harness.completions.disconnected = { disconnected.fulfill() } }
        var reset = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(accepted, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
        close(accepted)
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 5), .completed)

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(
            onContext(context) { harness.inboundDataAvailableReceived },
            "inbound data arrived after the read error disconnected the connection"
        )
    }

    // MARK: - Send low-water mark

    /// The stream protocol raises SO_SNDLOWAT to the unsent byte count when a write stalls, up
    /// to a third of the send buffer, and lowers it to 1 after the next full write. The server
    /// doesn't read until the test drains it.
    func testTCPSendLowWaterMarkFollowsStalledWrites() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }
        let accepted = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }
        let fd = try XCTUnwrap(descriptors(connectedTo: listener.port, type: SOCK_STREAM).first)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_SNDLOWAT), 1, "control: the mark didn't start at 1")

        let total = 8 << 20
        onContext(context) { XCTAssertTrue(harness.write([UInt8](repeating: 0x42, count: total))) }
        Thread.sleep(forTimeInterval: 0.5)
        let stalledMark = try XCTUnwrap(intOption(fd, SOL_SOCKET, SO_SNDLOWAT))
        let sendBufferSize = try XCTUnwrap(intOption(fd, SOL_SOCKET, SO_SNDBUF))
        XCTAssertGreaterThan(stalledMark, 1, "the mark didn't rise while the write was stalled")
        XCTAssertLessThanOrEqual(stalledMark, max(sendBufferSize / 3, 1))

        _ = fcntl(accepted, F_SETFL, fcntl(accepted, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var drained = 0
        let deadline = Date().addingTimeInterval(10)
        while drained < total, Date() < deadline {
            let count = read(accepted, &buffer, buffer.count)
            if count > 0 {
                drained += count
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        XCTAssertEqual(drained, total, "the server didn't receive everything")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_SNDLOWAT), 1, "the mark didn't drop back after the full write")
    }

    // MARK: - Per-packet metadata

    /// The datagram protocol sets IP_TOS to a frame's ECN and DSCP bits when they change, and back
    /// to zero for a frame that carries neither.
    func testUDPSendsEachFramesECNAndDSCP() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        setReceiveTimeout(peer.fd)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort()),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }
        let fd = try XCTUnwrap(descriptors(connectedTo: peer.port, type: SOCK_DGRAM).first)
        var buffer = [UInt8](repeating: 0, count: 16)

        send([1, 2, 3], from: harness, on: context) { frame in
            frame.ecnFlag = .ect0
            frame.dscpValue = 10
        }
        XCTAssertEqual(read(peer.fd, &buffer, buffer.count), 3)
        let expectedTypeOfService = CInt(IPProtocol.ECN.ect0.rawValue) | (10 << 2)
        XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TOS), expectedTypeOfService)

        send([4, 5, 6], from: harness, on: context) { _ in }
        XCTAssertEqual(read(peer.fd, &buffer, buffer.count), 3)
        XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TOS), 0)
    }

    /// A frame that carries ECN but no DSCP keeps the DSCP from the IP options. QUIC marks its
    /// frames ECN-capable without setting a DSCP, so without this the first QUIC packet would clear
    /// the configured DSCP.
    func testUDPFrameWithoutDSCPKeepsTheConfiguredDSCP() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        setReceiveTimeout(peer.fd)

        let parameters = Parameters()
        let ipOptions = IPProtocol.options()
        ipOptions.perProtocolOptions?.dscpValue = 10
        parameters.defaultStack.internet = .ip(ipOptions)
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort()),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }
        let fd = try XCTUnwrap(descriptors(connectedTo: peer.port, type: SOCK_DGRAM).first)
        XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TOS), 10 << 2, "control: the configured DSCP wasn't set")

        send([1, 2, 3], from: harness, on: context) { frame in frame.ecnFlag = .ect0 }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(peer.fd, &buffer, buffer.count), 3)
        let expectedTypeOfService = CInt(IPProtocol.ECN.ect0.rawValue) | (10 << 2)
        XCTAssertEqual(intOption(fd, IPPROTO_IP, IP_TOS), expectedTypeOfService)
    }

    /// The datagram protocol reads a received datagram's ECN bits, and its hop limit when the IP
    /// options ask for it. The control shows that the kernel reports what the peer set.
    func testUDPReceivesTheECNAndHopLimit() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        var tos: CInt = CInt(IPProtocol.ECN.ect1.rawValue)
        var ttl: CInt = 33
        XCTAssertEqual(setsockopt(peer.fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<CInt>.size)), 0)
        XCTAssertEqual(setsockopt(peer.fd, IPPROTO_IP, IP_TTL, &ttl, socklen_t(MemoryLayout<CInt>.size)), 0)

        let parameters = Parameters()
        let ipOptions = IPProtocol.options()
        ipOptions.perProtocolOptions?.receiveHopLimit = true
        parameters.defaultStack.internet = .ip(ipOptions)
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let localPort = discoverFreeLoopbackPort()
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: localPort),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }

        var payload: [UInt8] = [7, 8, 9]
        var connectionAddress = loopbackAddress(port: localPort)
        let sent = withUnsafePointer(to: &connectionAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(peer.fd, &payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 3)

        var received: (ecn: IPProtocol.ECN, hopLimit: UInt8)? = nil
        let deadline = Date().addingTimeInterval(5)
        while received == nil, Date() < deadline {
            received = onContext(context) {
                guard var frames = try? harness.invokeReceiveDatagrams(maximumDatagramCount: 1) else { return nil }
                var values: (IPProtocol.ECN, UInt8)? = nil
                frames.iterateMutableFrames { frame in
                    values = (frame.ecnFlag, frame.hopLimit)
                    frame.finalize(success: true)
                    return true
                }
                return values
            }
            if received == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        let values = try XCTUnwrap(received, "nothing arrived")
        XCTAssertEqual(values.ecn, .ect1)
        XCTAssertEqual(values.hopLimit, 33)
    }

    /// The datagram protocol sends a datagram's service type in a control message when it isn't
    /// best effort. Loopback doesn't report the service type, so this checks that the datagram
    /// still arrives intact through sendmsg.
    func testUDPDatagramWithAServiceClassArrives() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        setReceiveTimeout(peer.fd)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort()),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }

        send([1, 2, 3, 4], from: harness, on: context) { frame in frame.serviceClass = .interactiveVoice }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(peer.fd, &buffer, buffer.count), 4)
        XCTAssertEqual(Array(buffer.prefix(4)), [1, 2, 3, 4])
    }

    /// withServiceType lays out a message as the CMSG macros do on Darwin: a 12-byte header and
    /// padded data, 16 bytes in all. packetInfo reads both messages of a two-message buffer.
    func testControlMessagesMatchTheCMSGLayout() {
        ControlMessages.withServiceType(NET_SERVICE_TYPE_VO) { control, length in
            let header = control.load(as: cmsghdr.self)
            XCTAssertEqual(header.cmsg_level, SOL_SOCKET)
            XCTAssertEqual(header.cmsg_type, SO_NET_SERVICE_TYPE)
            XCTAssertEqual(Int(header.cmsg_len), 12 + 4)
            XCTAssertEqual(Int(length), 16)
            XCTAssertEqual(control.load(fromByteOffset: 12, as: CInt.self), NET_SERVICE_TYPE_VO)
        }

        // An IPv4 TOS byte (ECT(1) plus a DSCP), then an IPv4 TTL byte. Each header is 12 bytes
        // and each message is padded to 16.
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(
                of: cmsghdr(cmsg_len: 13, cmsg_level: CInt(IPPROTO_IP), cmsg_type: IP_RECVTOS),
                as: cmsghdr.self
            )
            buffer[12] = UInt8(IPProtocol.ECN.ect1.rawValue) | (46 << 2)
            buffer.storeBytes(
                of: cmsghdr(cmsg_len: 13, cmsg_level: CInt(IPPROTO_IP), cmsg_type: IP_RECVTTL),
                toByteOffset: 16,
                as: cmsghdr.self
            )
            buffer[28] = 64
        }
        let info = bytes.withUnsafeBytes { ControlMessages.packetInfo($0) }
        XCTAssertEqual(info.ecn, .ect1)
        XCTAssertEqual(info.hopLimit, 64)
    }

    // MARK: - Connect addressing

    /// The stream protocol passes the required interface to connectx as the source interface,
    /// which binds the socket to it. IP_BOUND_IF reports the binding. The first connection is the
    /// control and has no required interface.
    func testTCPRequiredInterfaceScopesTheConnection() throws {
        let loopback = try Interface(name: "lo0")
        let listener = loopbackListener()
        defer { close(listener.fd) }

        for required in [nil, loopback] as [Interface?] {
            var parameters = Parameters()
            parameters.requiredInterface = required
            let context = parameters.context
            let storage = TestNetworkProtocolStorage(context: context)
            defer { onContext(context) { storage.releaseHeldInstances() } }
            let harness = try connectedStreamHarness(
                to: Endpoint(address: IPv4Address.loopback, port: listener.port),
                storage: storage,
                parameters: parameters
            )
            defer {
                onContext(context) {
                    harness.stop()
                    harness.teardown()
                }
            }
            let accepted = acceptWithTimeout(listener.fd)
            defer { close(accepted) }
            let fd = try XCTUnwrap(descriptors(connectedTo: listener.port, type: SOCK_STREAM).first)
            XCTAssertEqual(
                intOption(fd, IPPROTO_IP, IP_BOUND_IF),
                CInt(required?.index ?? 0),
                "IP_BOUND_IF with required interface \(String(describing: required))"
            )
        }
    }

    /// The datagram protocol connects a link-local destination with its endpoint's scope. The peer
    /// listens on fe80::1 on lo0, which only that scope reaches.
    func testUDPLinkLocalConnectUsesTheEndpointsScope() throws {
        let loopback = try Interface(name: "lo0")
        let peer = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var peerAddress = sockaddr_in6()
        peerAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        peerAddress.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "fe80::1", &peerAddress.sin6_addr), 1)
        peerAddress.sin6_scope_id = UInt32(loopback.index)
        let bound = withUnsafePointer(to: &peerAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(peer, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        try XCTSkipUnless(bound == 0, "control: can't bind fe80::1%lo0 (errno \(errno))")
        let peerPort = boundPortOfDescriptor(peer)
        setReceiveTimeout(peer, seconds: 1)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        var remote = Endpoint(address: try XCTUnwrap(IPv6Address("fe80::1")), port: peerPort)
        remote.interface = loopback
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv6Address.any, port: 0),
            remote: remote,
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }

        // In one run out of eleven, the first datagram after a build never arrived, and the cause
        // isn't known. Send up to three. Without the scope ID, none of them can reach the peer.
        var buffer = [UInt8](repeating: 0, count: 16)
        var received = -1
        for _ in 0..<3 where received != 3 {
            onContext(context) { XCTAssertTrue(harness.write([1, 2, 3])) }
            received = read(peer, &buffer, buffer.count)
        }
        XCTAssertEqual(received, 3, "no datagram reached fe80::1%lo0")
    }

    // MARK: - Unix-domain sockets

    /// The stream protocol connects to Unix-domain paths. Data goes both ways.
    func testStreamSocketConnectsToAUnixPath() throws {
        let server = try unixSocket(type: SOCK_STREAM)
        defer {
            close(server.fd)
            unlink(server.path)
        }
        XCTAssertEqual(listen(server.fd, 1), 0)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedStreamHarness(
            to: Endpoint(try XCTUnwrap(AddressEndpoint(server.path))),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }
        let accepted = acceptWithTimeout(server.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }
        setReceiveTimeout(accepted)

        onContext(context) { XCTAssertTrue(harness.write([1, 2, 3])) }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(accepted, &buffer, buffer.count), 3)
        XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])

        var reply: [UInt8] = [4, 5]
        XCTAssertEqual(write(accepted, &reply, reply.count), 2)
        var received: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while received.count < 2, Date() < deadline {
            received += onContext(context) { harness.read() } ?? []
            if received.count < 2 { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(received, [4, 5])
    }

    /// The datagram protocol connects to Unix-domain paths too.
    func testDatagramSocketConnectsToAUnixPath() throws {
        let peer = try unixSocket(type: SOCK_DGRAM)
        defer {
            close(peer.fd)
            unlink(peer.path)
        }
        setReceiveTimeout(peer.fd)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let remote = Endpoint(try XCTUnwrap(AddressEndpoint(peer.path)))
        // The harness needs a local endpoint. The protocol doesn't bind a Unix-domain local
        // endpoint, so passing the remote one only fills the slot.
        let harness = try connectedDatagramHarness(
            local: remote,
            remote: remote,
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }

        onContext(context) { XCTAssertTrue(harness.write([7, 8, 9])) }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(peer.fd, &buffer, buffer.count), 3)
        XCTAssertEqual(Array(buffer.prefix(3)), [7, 8, 9])
    }

    // MARK: - Connected endpoint

    /// The stream protocol reports the local endpoint the kernel assigned once it connects.
    func testStreamSocketReportsTheConnectedLocalEndpoint() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        var socketProtocol: SocketStreamProtocol?
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        ) { socketProtocol = $0 }
        defer { stopAndTearDown(harness, on: context) }
        let accepted = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }

        let reported = onContext(context) { socketProtocol?.connectedLocalEndpoint }
        XCTAssertNotNil(reported)
        XCTAssertEqual(reported?.port, peerPort(of: accepted))
    }

    // MARK: - Adopting and resetting sockets

    /// The stream protocol adopts a socket that's already connected, and carries data both ways
    /// on it.
    func testStreamSocketAdoptsAConnectedSocket() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopbackAddress(port: listener.port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let accepted = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }
        setReceiveTimeout(accepted)

        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        // The protocol owns the client socket from here, and closes it.
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        ) { $0.adoptConnectedSocket(client) }
        defer { stopAndTearDown(harness, on: context) }

        onContext(context) { XCTAssertTrue(harness.write([1, 2, 3])) }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(accepted, &buffer, buffer.count), 3)
        XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])

        var reply: [UInt8] = [4, 5]
        XCTAssertEqual(write(accepted, &reply, reply.count), 2)
        var received: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while received.count < 2, Date() < deadline {
            received += onContext(context) { harness.read() } ?? []
            if received.count < 2 { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(received, [4, 5])
    }

    /// A reset closes the stream protocol's socket and opens a new one, which connects again from
    /// a port the kernel picks.
    func testStreamSocketResetConnectsAgainFromANewPort() throws {
        let listener = loopbackListener()
        defer { close(listener.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        var socketProtocol: SocketStreamProtocol?
        let harness = try connectedStreamHarness(
            to: Endpoint(address: IPv4Address.loopback, port: listener.port),
            storage: storage,
            parameters: parameters
        ) { socketProtocol = $0 }
        defer { stopAndTearDown(harness, on: context) }
        let first = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(first, 0)
        defer { close(first) }
        let firstPort = try XCTUnwrap(peerPort(of: first))

        let instance = try XCTUnwrap(socketProtocol)
        onContext(context) {
            do {
                try instance.reset()
                instance.fromExternal { eventContext in
                    instance.connect(in: &eventContext)
                }
            } catch {
                XCTFail("reset failed: \(error)")
            }
        }
        let second = acceptWithTimeout(listener.fd)
        XCTAssertGreaterThanOrEqual(second, 0)
        defer { close(second) }
        let secondPort = try XCTUnwrap(peerPort(of: second))
        XCTAssertNotEqual(secondPort, firstPort)
        let deadline = Date().addingTimeInterval(5)
        while onContext(context, { instance.connectedLocalEndpoint?.port }) != secondPort, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(onContext(context) { instance.connectedLocalEndpoint?.port }, secondPort)

        // The new socket's sources watch the new socket, so data flows both ways on it.
        setReceiveTimeout(second)
        onContext(context) { XCTAssertTrue(harness.write([1, 2, 3])) }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(read(second, &buffer, buffer.count), 3)
        XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])
        var reply: [UInt8] = [4, 5]
        XCTAssertEqual(write(second, &reply, reply.count), 2)
        var received: [UInt8] = []
        let readDeadline = Date().addingTimeInterval(5)
        while received.count < 2, Date() < readDeadline {
            received += onContext(context) { harness.read() } ?? []
            if received.count < 2 { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(received, [4, 5])
    }

    /// A reset datagram protocol opens a new socket, and data flows both ways on it.
    func testDatagramSocketResetCarriesDataOnTheNewSocket() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        setReceiveTimeout(peer.fd)
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        var socketProtocol: SocketDatagramProtocol?
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: 0),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        ) { socketProtocol = $0 }
        defer { stopAndTearDown(harness, on: context) }
        let instance = try XCTUnwrap(socketProtocol)
        let firstPort = try XCTUnwrap(onContext(context) { instance.connectedLocalEndpoint?.port })

        onContext(context) {
            do {
                try instance.reset()
                instance.fromExternal { eventContext in
                    instance.connect(in: &eventContext)
                }
            } catch {
                XCTFail("reset failed: \(error)")
            }
        }
        let secondPort = try XCTUnwrap(onContext(context) { instance.connectedLocalEndpoint?.port })
        XCTAssertNotEqual(secondPort, firstPort)

        onContext(context) { XCTAssertTrue(harness.write([1, 2, 3])) }
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(recv(peer.fd, &buffer, buffer.count, 0), 3)
        XCTAssertEqual(Array(buffer.prefix(3)), [1, 2, 3])

        var reply: [UInt8] = [4]
        var address = loopbackAddress(port: secondPort)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(peer.fd, &reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 1)
        var received: [UInt8]? = nil
        let deadline = Date().addingTimeInterval(5)
        while received == nil, Date() < deadline {
            received = onContext(context) { harness.read() }
            if received == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(received, [4])
    }

    /// The datagram protocol delivers the data queued with addInitialInboundData before anything
    /// it reads from the socket, and counts it in the transfer snapshot.
    func testDatagramSocketDeliversInitialInboundData() throws {
        let peer = boundUDPPeer()
        defer { close(peer.fd) }
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        var socketProtocol: SocketDatagramProtocol?
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: 0),
            remote: Endpoint(address: IPv4Address.loopback, port: peer.port),
            storage: storage,
            parameters: parameters
        ) {
            $0.addInitialInboundData([9, 8, 7])
            socketProtocol = $0
        }
        defer { stopAndTearDown(harness, on: context) }
        let instance = try XCTUnwrap(socketProtocol)

        // The peer's datagram reaches the socket before the upper protocol reads anything.
        let localPort = try XCTUnwrap(onContext(context) { instance.connectedLocalEndpoint?.port })
        var datagram: [UInt8] = [1]
        var address = loopbackAddress(port: localPort)
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(peer.fd, &datagram, datagram.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 1)
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertEqual(onContext(context) { harness.read() }, [9, 8, 7])
        var second: [UInt8]? = nil
        let deadline = Date().addingTimeInterval(5)
        while second == nil, Date() < deadline {
            second = onContext(context) { harness.read() }
            if second == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(second, [1])
        let snapshot = onContext(context) { () -> DataTransferSnapshot in
            var snapshot = DataTransferSnapshot()
            instance.updateDataTransferSnapshot(&snapshot)
            return snapshot
        }
        XCTAssertEqual(snapshot.receivedTransportByteCount, 4)
        XCTAssertEqual(snapshot.receivedIPPacketCount, 2)
    }

    /// A datagram read that fails with ECONNREFUSED reports a soft error, and the next datagram
    /// that arrives clears it. The flow stays up throughout.
    func testDatagramSocketReportsASoftErrorAndClearsIt() throws {
        let ports = discoverFreeLoopbackPorts(2)
        let peerPort = ports[0]
        let localPort = ports[1]
        let parameters = Parameters()
        let context = parameters.context
        let storage = TestNetworkProtocolStorage(context: context)
        defer { onContext(context) { storage.releaseHeldInstances() } }
        let harness = try connectedDatagramHarness(
            local: Endpoint(address: IPv4Address.loopback, port: localPort),
            remote: Endpoint(address: IPv4Address.loopback, port: peerPort),
            storage: storage,
            parameters: parameters
        )
        defer { stopAndTearDown(harness, on: context) }

        func socketEvents() -> [SocketProtocolEvent] {
            onContext(context) {
                harness.receivedNetworkProtocolEvents.compactMap { event in
                    guard case .custom(let custom) = event.internalEvent else { return nil }
                    return custom as? SocketProtocolEvent
                }
            }
        }

        // Nothing listens on the peer port, so this datagram draws a port unreachable.
        onContext(context) { XCTAssertTrue(harness.write([1])) }
        var deadline = Date().addingTimeInterval(2)
        while !socketEvents().contains(.softError(.posix(ECONNREFUSED))), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try XCTSkipUnless(
            socketEvents().contains(.softError(.posix(ECONNREFUSED))),
            "control: the kernel didn't report ECONNREFUSED: \(socketEvents())"
        )

        let peer = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(peer) }
        var peerAddress = loopbackAddress(port: peerPort)
        let bound = withUnsafePointer(to: &peerAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(peer, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var reply: [UInt8] = [2]
        var connectionAddress = loopbackAddress(port: localPort)
        let sent = withUnsafePointer(to: &connectionAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(peer, &reply, reply.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, 1)
        deadline = Date().addingTimeInterval(2)
        while socketEvents().last != .softErrorCleared, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(socketEvents().last, .softErrorCleared)
    }

    // MARK: - Source addressing

    /// The stream protocol connects from the local endpoint's port. connectx binds it as the
    /// source address.
    func testTCPConnectsFromTheLocalEndpointsPort() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }
        let localPort = discoverFreeLoopbackPort()

        let (connection, cancelled) = readyTCPConnection(
            server: server,
            parameters: makeTCPParams(localPort: localPort)
        )
        let fd = try XCTUnwrap(descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM).first)
        XCTAssertEqual(boundPortOfDescriptor(fd), localPort)

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// When the TCP options reset the local port, the stream protocol connects from the local
    /// endpoint's address and a port the kernel picks. It doesn't set SO_REUSEPORT for it.
    func testTCPResetLocalPortConnectsFromANewPort() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }
        let localPort = discoverFreeLoopbackPort()

        let parameters = makeTCPParams(localPort: localPort)
        let tcpOptions = TCPProtocol.options()
        tcpOptions.resetLocalPort = true
        parameters.parameters.defaultStack.transport = .tcp(tcpOptions)
        let (connection, cancelled) = readyTCPConnection(server: server, parameters: parameters)
        let fd = try XCTUnwrap(descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM).first)
        XCTAssertNotEqual(boundPortOfDescriptor(fd), localPort)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_REUSEPORT), 0)

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// The stream protocol sets TCP_NOTSENT_LOWAT for reduced buffering, and TCP_MAXSEG, once the
    /// connection is up.
    func testTCPConnectedOptionsReachTheSocket() throws {
        let server = TCPEchoServer()
        try server.start()
        defer { server.stop() }

        let parameters = makeTCPParams()
        let tcpOptions = TCPProtocol.options()
        tcpOptions.reduceBuffering = true
        tcpOptions.modifyPerProtocolOptions { $0.maximumSegmentSize = 1200 }
        parameters.parameters.defaultStack.transport = .tcp(tcpOptions)
        let (connection, cancelled) = readyTCPConnection(server: server, parameters: parameters)
        let fds = descriptors(connectedTo: server.listeningPort, type: SOCK_STREAM)
        XCTAssertFalse(fds.isEmpty, "found no socket connected to the test server")
        for fd in fds {
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT), 16 * 1024, "TCP_NOTSENT_LOWAT on fd \(fd)")
            XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_MAXSEG), 1200, "TCP_MAXSEG on fd \(fd)")
        }

        connection.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
    }

    /// The datagram protocol applies the temporary-address preference to an IPv6 socket.
    func testUDPLocalAddressPreferenceReachesTheSocket() throws {
        let peer = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        var peerAddress = sockaddr_in6()
        peerAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        peerAddress.sin6_family = sa_family_t(AF_INET6)
        peerAddress.sin6_addr = in6addr_loopback
        _ = withUnsafePointer(to: &peerAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(peer, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        let peerPort = boundPortOfDescriptor(peer)

        for preference in [IPProtocol.AddressPreference.stable, .temporary] {
            let parameters = ParametersBuilder<UDP>.parameters {
                UDP {
                    IP().localAddressPreference(preference)
                }
            }
            let ready = XCTestExpectation(description: "ready")
            let cancelled = XCTestExpectation(description: "cancelled")
            let connection = NetworkConnection(
                to: Endpoint(address: IPv6Address.loopback, port: peerPort),
                using: parameters
            )
            connection.onStateUpdate { _, state in
                if case .ready = state { ready.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
            }
            connection.start()
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            let fds = descriptors(connectedTo: peerPort, type: SOCK_DGRAM)
            XCTAssertFalse(fds.isEmpty, "found no socket connected to the peer")
            for fd in fds {
                // 63 is IPV6_PREFER_TEMPADDR, which the Darwin overlay doesn't surface.
                XCTAssertEqual(intOption(fd, IPPROTO_IPV6, 63), preference == .temporary ? 1 : 0, "fd \(fd)")
            }
            connection.cancel()
            XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        }
    }
}

#endif  // canImport(Darwin)

#endif
