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
#elseif canImport(Darwin)
internal import Darwin
#endif

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
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
        // No listener on this port: connect should fail.
        let failed = XCTestExpectation(description: "tcp failed")
        let cancelled = XCTestExpectation(description: "tcp cancelled")
        let ready = XCTestExpectation(description: "tcp ready")
        ready.isInverted = true

        let remote = Endpoint(address: IPv4Address.loopback, port: discoverFreeLoopbackPort())
        let conn = NetworkConnection(to: remote, using: makeTCPParams())
            .onStateUpdate { _, state in
                if case .failed = state { failed.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
                if case .ready = state { ready.fulfill() }
            }
        conn.start()
        wait(for: [failed, ready], timeout: 5.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
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
        #if canImport(Darwin)
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

        // Give the bottom a moment to observe the peer's FIN (EOF), then sample
        // CPU across an otherwise-idle second.
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

#endif
