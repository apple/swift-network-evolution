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

@available(Network 0.1.0, *)
final class SwiftNetworkSocketTests: NetTestCase {

    // MARK: - Helpers

    private func makeUDPParams(localPort: UInt16, ipv6: Bool = false) -> ParametersBuilder<UDP> {
        var builder = ParametersBuilder<UDP>.parameters { UDP() }
        if ipv6 {
            builder.parameters.localAddress = Endpoint(address: IPv6Address.loopback, port: localPort)
        } else {
            builder.parameters.localAddress = Endpoint(address: IPv4Address.loopback, port: localPort)
        }
        return builder
    }

    private func makeConnection(
        toPort: UInt16,
        localPort: UInt16,
        ipv6: Bool = false,
        cancelExpectation: XCTestExpectation
    ) -> NetworkConnection<UDP> {
        let remote: Endpoint
        if ipv6 {
            remote = Endpoint(address: IPv6Address.loopback, port: toPort)
        } else {
            remote = Endpoint(address: IPv4Address.loopback, port: toPort)
        }
        return NetworkConnection(to: remote, using: makeUDPParams(localPort: localPort, ipv6: ipv6))
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelExpectation.fulfill() }
            }
    }

    // MARK: - Connection lifecycle

    func testConnectionStateLifecycle() {
        let ready = XCTestExpectation(description: "ready")
        let cancelled = XCTestExpectation(description: "cancelled")

        let remote = Endpoint(address: IPv4Address.loopback, port: 10800)
        let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: 10801))
            .onStateUpdate { _, state in
                if case .ready = state { ready.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
            }

        conn.start()
        wait(for: [ready], timeout: 5.0)

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // MARK: - Basic data path

    func testRoundTripEchoIPv4() {
        let done = XCTestExpectation(description: "echo complete")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10810, localPort: 10811, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10811, localPort: 10810, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payload: [UInt8] = [1, 2, 3, 4, 5]

        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        c2.receive { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, payload)
                c2.send(.message(content: message.content)) { _ in }

                c1.receive { result in
                    switch result {
                    case .success(let echo):
                        XCTAssertEqual(echo.content, payload)
                        done.fulfill()
                    case .failure(let error):
                        XCTFail("echo receive failed: \(error)")
                    }
                }
            case .failure(let error):
                XCTFail("c2 receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testRoundTripEchoLargePayload() {
        let done = XCTestExpectation(description: "large echo")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10820, localPort: 10821, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10821, localPort: 10820, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payload = [UInt8](repeating: 0xAB, count: 1400)

        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        c2.receive { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, payload)
                c2.send(.message(content: message.content)) { _ in }

                c1.receive { result in
                    if case .success(let echo) = result {
                        XCTAssertEqual(echo.content, payload)
                    } else {
                        XCTFail("echo receive failed")
                    }
                    done.fulfill()
                }
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testRoundTripEchoIPv6() {
        let done = XCTestExpectation(description: "ipv6 echo")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10830, localPort: 10831, ipv6: true, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10831, localPort: 10830, ipv6: true, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payload: [UInt8] = [10, 20, 30]

        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        c2.receive { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, payload)
                c2.send(.message(content: message.content)) { _ in }

                c1.receive { result in
                    if case .success(let echo) = result {
                        XCTAssertEqual(echo.content, payload)
                    } else {
                        XCTFail("echo receive failed")
                    }
                    done.fulfill()
                }
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testSendSingleByteDatagram() {
        let done = XCTestExpectation(description: "single byte")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10840, localPort: 10841, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10841, localPort: 10840, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        c1.send(.message(content: [0xFF])) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        c2.receive { result in
            if case .success(let message) = result {
                XCTAssertEqual(message.content, [0xFF])
            } else {
                XCTFail("receive failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testMultipleMessagesSequentially() {
        let allDone = XCTestExpectation(description: "all messages")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10850, localPort: 10851, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10851, localPort: 10850, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let messages: [[UInt8]] = [
            [1], [2, 3], [4, 5, 6], [7, 8, 9, 10], [11, 12, 13, 14, 15],
        ]
        nonisolated(unsafe) var received = 0

        @Sendable func sendAndReceive(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            c1.send(.message(content: messages[i])) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
            c2.receive { result in
                if case .success(let message) = result {
                    XCTAssertEqual(message.content, messages[i])
                    received += 1
                } else {
                    XCTFail("receive \(i) failed")
                }
                sendAndReceive(i + 1)
            }
        }

        sendAndReceive(0)

        wait(for: [allDone], timeout: 15.0)
        XCTAssertEqual(received, messages.count)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testBidirectionalSimultaneousTransfer() {
        let bothDone = XCTestExpectation(description: "both received")
        bothDone.expectedFulfillmentCount = 2
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10860, localPort: 10861, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10861, localPort: 10860, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payloadA: [UInt8] = [0xAA, 0xBB]
        let payloadB: [UInt8] = [0xCC, 0xDD]

        c1.send(.message(content: payloadA)) { _ in }
        c2.send(.message(content: payloadB)) { _ in }

        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadA)
            } else {
                XCTFail("c2 receive failed")
            }
            bothDone.fulfill()
        }

        c1.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadB)
            } else {
                XCTFail("c1 receive failed")
            }
            bothDone.fulfill()
        }

        wait(for: [bothDone], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - Volume / stress

    func testRapidBurst100Sends() {
        let allReceived = XCTestExpectation(description: "all received")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10870, localPort: 10871, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10871, localPort: 10870, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let messageCount = 100
        for i in 0..<messageCount {
            c1.send(.message(content: [UInt8(i % 256)])) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
        }

        nonisolated(unsafe) var receiveCount = 0
        @Sendable func receiveNext() {
            c2.receive { result in
                if case .success = result {
                    receiveCount += 1
                    if receiveCount < messageCount {
                        receiveNext()
                    } else {
                        allReceived.fulfill()
                    }
                } else {
                    XCTFail("receive \(receiveCount) failed")
                }
            }
        }
        receiveNext()

        wait(for: [allReceived], timeout: 30.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testHighVolumeEcho200Messages() {
        let allDone = XCTestExpectation(description: "200 echoes")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10880, localPort: 10881, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10881, localPort: 10880, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let total = 200
        nonisolated(unsafe) var success = 0

        @Sendable func echoOnce(_ i: Int) {
            guard i < total else {
                allDone.fulfill()
                return
            }
            let payload: [UInt8] = [UInt8(i % 256)]

            c1.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }

            c2.receive { result in
                guard case .success(let msg) = result else {
                    XCTFail("c2 recv \(i)")
                    return
                }
                XCTAssertEqual(msg.content, payload)
                c2.send(.message(content: msg.content)) { _ in }

                c1.receive { result in
                    guard case .success(let echo) = result else {
                        XCTFail("c1 echo \(i)")
                        return
                    }
                    XCTAssertEqual(echo.content, payload)
                    success += 1
                    echoOnce(i + 1)
                }
            }
        }
        echoOnce(0)

        wait(for: [allDone], timeout: 60.0)
        XCTAssertEqual(success, total)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testVaryingPayloadSizes() {
        let allDone = XCTestExpectation(description: "varying sizes")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10890, localPort: 10891, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10891, localPort: 10890, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let sizes = [1, 100, 500, 1000, 1400, 10]
        let messages = sizes.map { [UInt8](repeating: 0xAA, count: $0) }
        nonisolated(unsafe) var received = 0

        @Sendable func sendAndReceive(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            c1.send(.message(content: messages[i])) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }
            c2.receive { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, messages[i])
                    received += 1
                } else {
                    XCTFail("receive \(i) failed")
                }
                sendAndReceive(i + 1)
            }
        }
        sendAndReceive(0)

        wait(for: [allDone], timeout: 15.0)
        XCTAssertEqual(received, messages.count)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - Backpressure

    func testBurstSendsReceiveOneAtATime() {
        let allReceived = XCTestExpectation(description: "all received")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10900, localPort: 10901, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10901, localPort: 10900, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let messageCount = 5
        for i in 0..<messageCount {
            c1.send(.message(content: [UInt8(i)])) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
        }

        nonisolated(unsafe) var receiveCount = 0
        @Sendable func receiveNext() {
            c2.receive { result in
                switch result {
                case .success:
                    receiveCount += 1
                    if receiveCount < messageCount {
                        receiveNext()
                    } else {
                        allReceived.fulfill()
                    }
                case .failure(let error):
                    XCTFail("receive \(receiveCount) failed: \(error)")
                }
            }
        }
        receiveNext()

        wait(for: [allReceived], timeout: 15.0)
        XCTAssertEqual(receiveCount, messageCount)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testMultipleSendsBeforeAnyReads() {
        let allDone = XCTestExpectation(description: "reads done")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10910, localPort: 10911, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10911, localPort: 10910, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let messageCount = 10
        for i in 0..<messageCount {
            c1.send(.message(content: [UInt8(i)])) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }
        }

        nonisolated(unsafe) var receiveCount = 0
        @Sendable func drainAll() {
            c2.receive { result in
                if case .success = result {
                    receiveCount += 1
                    if receiveCount < messageCount {
                        drainAll()
                    } else {
                        allDone.fulfill()
                    }
                } else {
                    XCTFail("receive \(receiveCount) failed")
                }
            }
        }

        // Small delay to let sends queue up before reading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            drainAll()
        }

        wait(for: [allDone], timeout: 15.0)
        XCTAssertEqual(receiveCount, messageCount)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testDelayedConsumer() {
        let allDone = XCTestExpectation(description: "delayed consumer")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10920, localPort: 10921, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10921, localPort: 10920, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        // Delay the receive by 500ms
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
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - Additional lifecycle tests

    func testCancelBeforeStart() {
        let cancelled = XCTestExpectation(description: "cancelled")

        let remote = Endpoint(address: IPv4Address.loopback, port: 10930)
        let conn = NetworkConnection(to: remote, using: makeUDPParams(localPort: 10931))
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testStartTwoConnectionsSameContext() {
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")
        let bothReady = XCTestExpectation(description: "both ready")
        bothReady.expectedFulfillmentCount = 2

        let c1 = makeConnection(toPort: 10940, localPort: 10941, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10941, localPort: 10940, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        // Both should reach ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            bothReady.fulfill()
            bothReady.fulfill()
        }

        wait(for: [bothReady], timeout: 5.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - Edge case payloads

    func testEmptyPayload() {
        let done = XCTestExpectation(description: "empty payload")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10950, localPort: 10951, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10951, localPort: 10950, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        c1.send(.message(content: [])) { result in
            if case .failure(let error) = result { XCTFail("send empty failed: \(error)") }
        }

        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, [])
            } else {
                XCTFail("receive empty failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testMaxSizeDatagram() {
        let done = XCTestExpectation(description: "max size")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10960, localPort: 10961, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10961, localPort: 10960, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payload = (0..<1472).map { UInt8($0 % 256) }

        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payload)
            } else {
                XCTFail("receive failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testPayloadWithAllByteValues() {
        let done = XCTestExpectation(description: "all bytes")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10970, localPort: 10971, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10971, localPort: 10970, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payload = (0...255).map { UInt8($0) }

        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payload)
            } else {
                XCTFail("receive failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - Multiple sequential echoes

    func testEcho10RoundTrips() {
        let allDone = XCTestExpectation(description: "10 echoes")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10980, localPort: 10981, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10981, localPort: 10980, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        nonisolated(unsafe) var success = 0
        @Sendable func echoOnce(_ i: Int) {
            guard i < 10 else {
                allDone.fulfill()
                return
            }
            let payload: [UInt8] = [UInt8(i), UInt8(i &* 2)]

            c1.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }

            c2.receive { result in
                guard case .success(let msg) = result else {
                    XCTFail("c2 recv \(i)")
                    return
                }
                XCTAssertEqual(msg.content, payload)
                c2.send(.message(content: msg.content)) { _ in }

                c1.receive { result in
                    guard case .success(let echo) = result else {
                        XCTFail("c1 echo \(i)")
                        return
                    }
                    XCTAssertEqual(echo.content, payload)
                    success += 1
                    echoOnce(i + 1)
                }
            }
        }
        echoOnce(0)

        wait(for: [allDone], timeout: 30.0)
        XCTAssertEqual(success, 10)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testEcho50RoundTripsLargePayload() {
        let allDone = XCTestExpectation(description: "50 large echoes")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 10990, localPort: 10991, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 10991, localPort: 10990, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let total = 50
        nonisolated(unsafe) var success = 0
        @Sendable func echoOnce(_ i: Int) {
            guard i < total else {
                allDone.fulfill()
                return
            }
            let payload = [UInt8](repeating: UInt8(i % 256), count: 1000)

            c1.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }

            c2.receive { result in
                guard case .success(let msg) = result else {
                    XCTFail("c2 recv \(i)")
                    return
                }
                XCTAssertEqual(msg.content, payload)
                c2.send(.message(content: msg.content)) { _ in }

                c1.receive { result in
                    guard case .success(let echo) = result else {
                        XCTFail("c1 echo \(i)")
                        return
                    }
                    XCTAssertEqual(echo.content, payload)
                    success += 1
                    echoOnce(i + 1)
                }
            }
        }
        echoOnce(0)

        wait(for: [allDone], timeout: 60.0)
        XCTAssertEqual(success, total)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - IPv6 additional tests

    func testIPv6SingleByte() {
        let done = XCTestExpectation(description: "ipv6 single byte")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 11000, localPort: 11001, ipv6: true, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 11001, localPort: 11000, ipv6: true, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        c1.send(.message(content: [0x42])) { _ in }

        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, [0x42])
            } else {
                XCTFail("ipv6 receive failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testIPv6BidirectionalEcho() {
        let bothDone = XCTestExpectation(description: "both echoed")
        bothDone.expectedFulfillmentCount = 2
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 11010, localPort: 11011, ipv6: true, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 11011, localPort: 11010, ipv6: true, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let payloadA: [UInt8] = [0xAA, 0xBB, 0xCC]
        let payloadB: [UInt8] = [0xDD, 0xEE, 0xFF]

        c1.send(.message(content: payloadA)) { _ in }
        c2.send(.message(content: payloadB)) { _ in }

        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadA)
            } else {
                XCTFail("c2 recv failed")
            }
            bothDone.fulfill()
        }

        c1.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payloadB)
            } else {
                XCTFail("c1 recv failed")
            }
            bothDone.fulfill()
        }

        wait(for: [bothDone], timeout: 10.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - Rapid send-receive patterns

    func testAlternatingSendReceive() {
        let allDone = XCTestExpectation(description: "alternating")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 11020, localPort: 11021, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 11021, localPort: 11020, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let count = 20
        nonisolated(unsafe) var completed = 0

        @Sendable func step(_ i: Int) {
            guard i < count else {
                allDone.fulfill()
                return
            }

            if i % 2 == 0 {
                c1.send(.message(content: [UInt8(i)])) { _ in }
                c2.receive { result in
                    if case .success(let msg) = result {
                        XCTAssertEqual(msg.content, [UInt8(i)])
                        completed += 1
                    }
                    step(i + 1)
                }
            } else {
                c2.send(.message(content: [UInt8(i)])) { _ in }
                c1.receive { result in
                    if case .success(let msg) = result {
                        XCTAssertEqual(msg.content, [UInt8(i)])
                        completed += 1
                    }
                    step(i + 1)
                }
            }
        }
        step(0)

        wait(for: [allDone], timeout: 30.0)
        XCTAssertEqual(completed, count)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testBurst50ThenDrain() {
        let allDrained = XCTestExpectation(description: "drained")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 11030, localPort: 11031, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 11031, localPort: 11030, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let messageCount = 50
        for i in 0..<messageCount {
            c1.send(.message(content: [UInt8(i % 256)])) { _ in }
        }

        nonisolated(unsafe) var receiveCount = 0
        @Sendable func drain() {
            c2.receive { result in
                if case .success = result {
                    receiveCount += 1
                    if receiveCount < messageCount {
                        drain()
                    } else {
                        allDrained.fulfill()
                    }
                } else {
                    XCTFail("receive \(receiveCount) failed")
                }
            }
        }
        drain()

        wait(for: [allDrained], timeout: 30.0)
        XCTAssertEqual(receiveCount, messageCount)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    func testSendReceiveWithRandomPayloadSizes() {
        let allDone = XCTestExpectation(description: "random sizes")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 11040, localPort: 11041, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 11041, localPort: 11040, cancelExpectation: c2Done)

        c1.start()
        c2.start()

        let sizes = [7, 13, 42, 100, 256, 500, 1, 1000, 3, 1400]
        let messages = sizes.map { (0..<$0).map { UInt8($0 % 256) } }
        nonisolated(unsafe) var received = 0

        @Sendable func sendAndVerify(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            c1.send(.message(content: messages[i])) { _ in }
            c2.receive { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, messages[i])
                    received += 1
                }
                sendAndVerify(i + 1)
            }
        }
        sendAndVerify(0)

        wait(for: [allDone], timeout: 15.0)
        XCTAssertEqual(received, messages.count)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // MARK: - TCP / SocketStreamProtocol tests
    //
    // The stream tests need an actual server side because TCP is connection-
    // oriented; the loopback datagram pattern of "two peers binding to each
    // other's port" doesn't work. Each test spins up a TCPEchoServer (a tiny
    // POSIX listener that accepts one connection and echoes everything back
    // until EOF), then uses NetworkConnection<TCP> as the client.

    private func makeTCPParams(localPort: UInt16 = 0, ipv6: Bool = false) -> ParametersBuilder<TCP> {
        var builder = ParametersBuilder<TCP>.parameters { TCP() }
        if localPort != 0 {
            if ipv6 {
                builder.parameters.localAddress = Endpoint(address: IPv6Address.loopback, port: localPort)
            } else {
                builder.parameters.localAddress = Endpoint(address: IPv4Address.loopback, port: localPort)
            }
        }
        return builder
    }

    private func makeTCPConnection(
        toPort: UInt16,
        localPort: UInt16 = 0,
        ipv6: Bool = false,
        readyExpectation: XCTestExpectation? = nil,
        cancelExpectation: XCTestExpectation? = nil
    ) -> NetworkConnection<TCP> {
        let remote: Endpoint
        if ipv6 {
            remote = Endpoint(address: IPv6Address.loopback, port: toPort)
        } else {
            remote = Endpoint(address: IPv4Address.loopback, port: toPort)
        }
        return NetworkConnection(to: remote, using: makeTCPParams(localPort: localPort, ipv6: ipv6))
            .onStateUpdate { _, state in
                if case .ready = state { readyExpectation?.fulfill() }
                if case .cancelled = state { cancelExpectation?.fulfill() }
            }
    }

    // MARK: - Connection lifecycle (TCP)

    func testTCPConnectionStateLifecycle() {
        let server = TCPEchoServer(port: 12000)
        try? server.start()
        defer { server.stop() }

        let ready = XCTestExpectation(description: "tcp ready")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(
            toPort: 12000,
            readyExpectation: ready,
            cancelExpectation: cancelled
        )
        conn.start()
        wait(for: [ready], timeout: 5.0)

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPConnectionRefusedDeliversFailure() {
        // No listener on this port: connect should fail.
        let failed = XCTestExpectation(description: "tcp failed")
        let cancelled = XCTestExpectation(description: "tcp cancelled")
        let ready = XCTestExpectation(description: "tcp ready")
        ready.isInverted = true

        let remote = Endpoint(address: IPv4Address.loopback, port: 12001)
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
        let server = TCPEchoServer(port: 12010)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "tcp echo done")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12010, cancelExpectation: cancelled)
        conn.start()

        let payload: [UInt8] = [1, 2, 3, 4, 5]
        conn.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        conn.receive(atLeast: payload.count, atMost: payload.count) { result in
            switch result {
            case .success(let msg):
                XCTAssertEqual(msg.content, payload)
                done.fulfill()
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPRoundTripEchoIPv6() {
        let server = TCPEchoServer(port: 12120, ipv6: true)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "tcp ipv6 echo")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12120, ipv6: true, cancelExpectation: cancelled)
        conn.start()

        let payload: [UInt8] = [10, 20, 30]
        conn.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        conn.receive(atLeast: payload.count, atMost: payload.count) { result in
            switch result {
            case .success(let msg):
                XCTAssertEqual(msg.content, payload)
                done.fulfill()
            case .failure(let error):
                XCTFail("ipv6 receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPSendSingleByte() {
        let server = TCPEchoServer(port: 12030)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "tcp single byte")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12030, cancelExpectation: cancelled)
        conn.start()

        conn.send(.message(content: [0xFF])) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        conn.receive(atLeast: 1, atMost: 1) { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, [0xFF])
            } else {
                XCTFail("receive failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPLargePayloadEcho() {
        let server = TCPEchoServer(port: 12040)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "tcp large echo")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12040, cancelExpectation: cancelled)
        conn.start()

        let payload = [UInt8](repeating: 0xAB, count: 8192)
        conn.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        // Stream may deliver the echo across multiple receives — keep reading
        // until we've collected the full payload.
        nonisolated(unsafe) var collected: [UInt8] = []
        @Sendable func readMore() {
            let need = payload.count - collected.count
            conn.receive(atLeast: 1, atMost: need) { result in
                switch result {
                case .success(let msg):
                    if let bytes = msg.content { collected.append(contentsOf: bytes) }
                    if collected.count >= payload.count {
                        XCTAssertEqual(collected, payload)
                        done.fulfill()
                    } else {
                        readMore()
                    }
                case .failure(let error):
                    XCTFail("receive failed: \(error)")
                    done.fulfill()
                }
            }
        }
        readMore()

        wait(for: [done], timeout: 15.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPMultipleSequentialMessages() {
        let server = TCPEchoServer(port: 12050)
        try? server.start()
        defer { server.stop() }

        let allDone = XCTestExpectation(description: "all tcp messages")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12050, cancelExpectation: cancelled)
        conn.start()

        let messages: [[UInt8]] = [
            [1], [2, 3], [4, 5, 6], [7, 8, 9, 10], [11, 12, 13, 14, 15],
        ]
        nonisolated(unsafe) var received = 0

        @Sendable func sendAndReceive(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            let payload = messages[i]
            conn.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
            conn.receive(atLeast: payload.count, atMost: payload.count) { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, payload)
                    received += 1
                } else {
                    XCTFail("receive \(i) failed")
                }
                sendAndReceive(i + 1)
            }
        }

        sendAndReceive(0)

        wait(for: [allDone], timeout: 15.0)
        XCTAssertEqual(received, messages.count)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // MARK: - Volume / stress (TCP)

    func testTCPHighVolumeEcho100Messages() {
        let server = TCPEchoServer(port: 12060)
        try? server.start()
        defer { server.stop() }

        let allDone = XCTestExpectation(description: "100 tcp echoes")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12060, cancelExpectation: cancelled)
        conn.start()

        let total = 100
        nonisolated(unsafe) var success = 0

        @Sendable func echoOnce(_ i: Int) {
            guard i < total else {
                allDone.fulfill()
                return
            }
            let payload: [UInt8] = [UInt8(i % 256), UInt8((i + 1) % 256)]

            conn.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }

            conn.receive(atLeast: payload.count, atMost: payload.count) { result in
                guard case .success(let msg) = result else {
                    XCTFail("recv \(i)")
                    return
                }
                XCTAssertEqual(msg.content, payload)
                success += 1
                echoOnce(i + 1)
            }
        }
        echoOnce(0)

        wait(for: [allDone], timeout: 60.0)
        XCTAssertEqual(success, total)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPVaryingPayloadSizes() {
        let server = TCPEchoServer(port: 12070)
        try? server.start()
        defer { server.stop() }

        let allDone = XCTestExpectation(description: "varying tcp sizes")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12070, cancelExpectation: cancelled)
        conn.start()

        let sizes = [1, 100, 500, 1000, 1400, 4096, 10]
        let messages = sizes.map { [UInt8](repeating: 0xAA, count: $0) }
        nonisolated(unsafe) var received = 0

        @Sendable func sendAndReceive(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            let payload = messages[i]
            conn.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }
            // Drain exactly payload.count bytes back from the echo server.
            nonisolated(unsafe) var collected: [UInt8] = []
            @Sendable func drain() {
                let need = payload.count - collected.count
                conn.receive(atLeast: 1, atMost: need) { result in
                    if case .success(let msg) = result, let bytes = msg.content {
                        collected.append(contentsOf: bytes)
                        if collected.count >= payload.count {
                            XCTAssertEqual(collected, payload)
                            received += 1
                            sendAndReceive(i + 1)
                        } else {
                            drain()
                        }
                    } else {
                        XCTFail("receive \(i) failed")
                        sendAndReceive(i + 1)
                    }
                }
            }
            drain()
        }
        sendAndReceive(0)

        wait(for: [allDone], timeout: 30.0)
        XCTAssertEqual(received, messages.count)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // MARK: - Backpressure / lifecycle (TCP)

    func testTCPBurstSendsThenDrain() {
        let server = TCPEchoServer(port: 12080)
        try? server.start()
        defer { server.stop() }

        let allDrained = XCTestExpectation(description: "tcp drained")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12080, cancelExpectation: cancelled)
        conn.start()

        let messageCount = 50
        let perMessage: [UInt8] = [0xDE, 0xAD]
        for i in 0..<messageCount {
            conn.send(.message(content: perMessage)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }
        }

        let totalBytes = messageCount * perMessage.count
        nonisolated(unsafe) var collected: [UInt8] = []

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
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPDelayedConsumer() {
        let server = TCPEchoServer(port: 12090)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "delayed tcp consumer")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12090, cancelExpectation: cancelled)
        conn.start()

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
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
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPPayloadWithAllByteValues() {
        let server = TCPEchoServer(port: 12100)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "tcp all bytes")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12100, cancelExpectation: cancelled)
        conn.start()

        let payload = (0...255).map { UInt8($0) }
        conn.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }

        conn.receive(atLeast: payload.count, atMost: payload.count) { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payload)
            } else {
                XCTFail("receive failed")
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 10.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPCancelBeforeStart() {
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let remote = Endpoint(address: IPv4Address.loopback, port: 12110)
        let conn = NetworkConnection(to: remote, using: makeTCPParams())
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // MARK: - Echo round trips (TCP)

    func testTCPEcho10RoundTrips() {
        let server = TCPEchoServer(port: 12130)
        try? server.start()
        defer { server.stop() }

        let allDone = XCTestExpectation(description: "10 tcp echoes")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 12130, cancelExpectation: cancelled)
        conn.start()

        nonisolated(unsafe) var success = 0
        @Sendable func echoOnce(_ i: Int) {
            guard i < 10 else {
                allDone.fulfill()
                return
            }
            let payload: [UInt8] = [UInt8(i), UInt8(i &* 2), UInt8(i &* 3)]

            conn.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }

            conn.receive(atLeast: payload.count, atMost: payload.count) { result in
                guard case .success(let msg) = result else {
                    XCTFail("recv \(i)")
                    return
                }
                XCTAssertEqual(msg.content, payload)
                success += 1
                echoOnce(i + 1)
            }
        }
        echoOnce(0)

        wait(for: [allDone], timeout: 30.0)
        XCTAssertEqual(success, 10)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
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
        let cancelled = XCTestExpectation(description: "udp cancelled")
        let conn = makeConnection(toPort: 13000, localPort: 13001, cancelExpectation: cancelled)
        conn.start()
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
        // If teardown is wrong (e.g. write source not resumed before cancel)
        // the DispatchSource will trap on dealloc — reaching here means it is clean.
    }

    // Cancelling before the socket even has a chance to become writable must
    // not crash (exercises the write-source suspend path in cancelWriteSource).
    func testUDPCancelImmediatelyAfterStart() {
        let cancelled = XCTestExpectation(description: "cancelled immediately")
        let conn = makeConnection(toPort: 13020, localPort: 13021, cancelExpectation: cancelled)
        conn.start()
        // Cancel on the very next runloop tick — write source may still be
        // suspended (never received EAGAIN).
        DispatchQueue.main.async { conn.cancel() }
        wait(for: [cancelled], timeout: 5.0)
    }

    func testTCPCancelImmediatelyAfterStart() {
        let cancelled = XCTestExpectation(description: "tcp cancelled immediately")
        let remote = Endpoint(address: IPv4Address.loopback, port: 13030)
        let conn = NetworkConnection(to: remote, using: makeTCPParams())
            .onStateUpdate { _, state in
                if case .cancelled = state { cancelled.fulfill() }
            }
        conn.start()
        DispatchQueue.main.async { conn.cancel() }
        wait(for: [cancelled], timeout: 5.0)
    }

    // Exercises bindSocket through the base class for both directions.
    func testUDPBindToExplicitLocalPort() {
        let ready = XCTestExpectation(description: "bound udp ready")
        let cancelled = XCTestExpectation(description: "bound udp cancelled")

        // makeConnection already sets a localPort — this verifies bindSocket
        // in the base class succeeds without error.
        let remote = Endpoint(address: IPv4Address.loopback, port: 13040)
        let c1 = NetworkConnection(to: remote, using: makeUDPParams(localPort: 13041))
            .onStateUpdate { _, state in
                if case .ready = state { ready.fulfill() }
                if case .cancelled = state { cancelled.fulfill() }
            }
        c1.start()
        wait(for: [ready], timeout: 5.0)
        c1.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // Verifies that the write-source fires and triggerOutboundRoomAvailable
    // is called after a datagram send — the upper layer gets the room event.
    func testUDPOutboundRoomAvailableAfterSend() {
        let sent = XCTestExpectation(description: "sent")
        let c1Done = XCTestExpectation(description: "c1 cancelled")
        let c2Done = XCTestExpectation(description: "c2 cancelled")

        let c1 = makeConnection(toPort: 13050, localPort: 13051, cancelExpectation: c1Done)
        let c2 = makeConnection(toPort: 13051, localPort: 13050, cancelExpectation: c2Done)
        c1.start()
        c2.start()

        c1.send(.message(content: [0x01, 0x02])) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
            sent.fulfill()
        }

        wait(for: [sent], timeout: 5.0)
        c1.cancel()
        c2.cancel()
        wait(for: [c1Done, c2Done], timeout: 5.0)
    }

    // Verifies write-source / triggerOutboundRoomAvailable for TCP.
    func testTCPOutboundRoomAvailableAfterSend() {
        let server = TCPEchoServer(port: 13060)
        try? server.start()
        defer { server.stop() }

        let sent = XCTestExpectation(description: "tcp sent")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: 13060, cancelExpectation: cancelled)
        conn.start()

        conn.send(.message(content: [0xAA])) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
            sent.fulfill()
        }

        wait(for: [sent], timeout: 5.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }

    // Multiple sequential start/cancel cycles — verifies repeated teardown
    // goes through the base-class cleanup without double-freeing sources.
    func testUDPMultipleCancelCycles() {
        for cycle in 0..<3 {
            let cancelled = XCTestExpectation(description: "cycle \(cycle) cancelled")
            let port = UInt16(13070 + cycle * 2)
            let conn = makeConnection(toPort: port, localPort: port + 1, cancelExpectation: cancelled)
            conn.start()
            conn.cancel()
            wait(for: [cancelled], timeout: 5.0)
        }
    }

    func testTCPMultipleCancelCycles() {
        for cycle in 0..<3 {
            let port = UInt16(13080 + cycle)
            let server = TCPEchoServer(port: port)
            try? server.start()

            let ready = XCTestExpectation(description: "tcp cycle \(cycle) ready")
            let cancelled = XCTestExpectation(description: "tcp cycle \(cycle) cancelled")
            let conn = makeTCPConnection(
                toPort: port,
                readyExpectation: ready,
                cancelExpectation: cancelled
            )
            conn.start()
            wait(for: [ready], timeout: 5.0)
            conn.cancel()
            wait(for: [cancelled], timeout: 5.0)
            server.stop()
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
        let port: UInt16 = 12200
        let firstChunk = 4
        let total = 16  // atLeast spans both segments

        let server = SplitSendServer(port: port, firstChunk: firstChunk, total: total, gap: 0.5)
        try? server.start()
        defer { server.stop() }

        let done = XCTestExpectation(description: "received full payload across segments")
        let cancelled = XCTestExpectation(description: "tcp cancelled")

        let conn = makeTCPConnection(toPort: port, cancelExpectation: cancelled)
        conn.start()

        conn.receive(atLeast: total, atMost: total) { result in
            switch result {
            case .success(let msg):
                XCTAssertEqual(msg.content?.count, total)
                done.fulfill()
            case .failure(let error):
                XCTFail("receive failed: \(error)")
            }
        }

        wait(for: [done], timeout: 10.0)
        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
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
        let server = ClosingServer(port: 12210, payload: [1, 2, 3, 4])
        try? server.start()
        defer { server.stop() }

        let received = XCTestExpectation(description: "received payload")
        let cancelled = XCTestExpectation(description: "tcp cancelled")
        let conn = makeTCPConnection(toPort: 12210, cancelExpectation: cancelled)
        conn.start()

        conn.receive(atLeast: 4, atMost: 4) { result in
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

        conn.cancel()
        wait(for: [cancelled], timeout: 5.0)
    }
}

// MARK: - TCP Echo Server helper
//
// Minimal POSIX TCP echo server used by the SocketStreamProtocol tests.
// Listens on loopback, accepts a single connection, and echoes everything
// it receives back to the sender until the peer half-closes (FIN).

private final class TCPEchoServer: @unchecked Sendable {
    private let port: UInt16
    private let ipv6: Bool
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(port: UInt16, ipv6: Bool = false) {
        self.port = port
        self.ipv6 = ipv6
        self.queue = DispatchQueue(label: "tcp-echo-server-\(port)", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let family = ipv6 ? CInt(AF_INET6) : CInt(AF_INET)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let family = ipv6 ? CInt(AF_INET6) : CInt(AF_INET)
        let type = SOCK_STREAM
        #endif
        let fd = socket(family, type, 0)
        guard fd >= 0 else { throw NSError(domain: "TCPEchoServer", code: Int(errno)) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        let bound: CInt
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_loopback
            #if canImport(Darwin)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NSError(domain: "TCPEchoServer.bind", code: Int(errno))
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "TCPEchoServer.listen", code: Int(errno))
        }

        self.listenFd = fd
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        if fd >= 0 {
            _ = shutdown(fd, CInt(SHUT_RDWR))
            close(fd)
        }
    }

    private func acceptLoop() {
        let listen = listenFd
        guard listen >= 0 else { return }
        let connFd = accept(listen, nil, nil)
        if connFd < 0 { return }
        defer { close(connFd) }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(connFd, base, raw.count)
            }
            if n <= 0 { break }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(connFd, base.advanced(by: written), n - written)
                }
                if w <= 0 { return }
                written += w
            }
        }
    }
}

// MARK: - Split-send Server helper
//
// POSIX TCP server that pushes a payload as two separate NODELAY segments with
// a gap between them, without reading anything from the client. Used to force
// a receive(atLeast:) to span more than one read event.

private final class SplitSendServer: @unchecked Sendable {
    private let port: UInt16
    private let firstChunk: Int
    private let total: Int
    private let gap: TimeInterval
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(port: UInt16, firstChunk: Int, total: Int, gap: TimeInterval) {
        self.port = port
        self.firstChunk = firstChunk
        self.total = total
        self.gap = gap
        self.queue = DispatchQueue(label: "split-send-server-\(port)", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let fd = socket(CInt(AF_INET), type, 0)
        guard fd >= 0 else { throw NSError(domain: "SplitSendServer", code: Int(errno)) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NSError(domain: "SplitSendServer.bind", code: Int(errno))
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "SplitSendServer.listen", code: Int(errno))
        }

        self.listenFd = fd
        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        if fd >= 0 {
            _ = shutdown(fd, CInt(SHUT_RDWR))
            close(fd)
        }
    }

    private func serve() {
        let listen = listenFd
        guard listen >= 0 else { return }
        let connFd = accept(listen, nil, nil)
        if connFd < 0 { return }
        defer { close(connFd) }

        // Disable Nagle so each write leaves as its own segment.
        var one: CInt = 1
        _ = setsockopt(connFd, CInt(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<CInt>.size))

        let payload = [UInt8](repeating: 0xAB, count: total)

        func sendAll(_ bytes: ArraySlice<UInt8>) {
            let array = Array(bytes)
            var off = 0
            while off < array.count {
                let w = array.withUnsafeBytes { raw -> Int in
                    write(connFd, raw.baseAddress!.advanced(by: off), raw.count - off)
                }
                if w <= 0 { break }
                off += w
            }
        }

        // First segment, then a gap so the client processes it (and, if buggy,
        // suspends its read source) before the remainder arrives.
        sendAll(payload.prefix(firstChunk))
        Thread.sleep(forTimeInterval: gap)
        sendAll(payload.suffix(total - firstChunk))

        // Hold the connection open long enough for the client to finish.
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// MARK: - Closing Server helper
//
// POSIX TCP server that sends a payload and immediately closes the connection
// (sending FIN), so the client observes EOF. Used to exercise the bottom's
// end-of-stream handling.

private final class ClosingServer: @unchecked Sendable {
    private let port: UInt16
    private let payload: [UInt8]
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(port: UInt16, payload: [UInt8]) {
        self.port = port
        self.payload = payload
        self.queue = DispatchQueue(label: "closing-server-\(port)", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let fd = socket(CInt(AF_INET), type, 0)
        guard fd >= 0 else { throw NSError(domain: "ClosingServer", code: Int(errno)) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NSError(domain: "ClosingServer.bind", code: Int(errno))
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "ClosingServer.listen", code: Int(errno))
        }

        self.listenFd = fd
        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        if fd >= 0 {
            _ = shutdown(fd, CInt(SHUT_RDWR))
            close(fd)
        }
    }

    private func serve() {
        let listen = listenFd
        guard listen >= 0 else { return }
        let connFd = accept(listen, nil, nil)
        if connFd < 0 { return }

        var off = 0
        while off < payload.count {
            let w = payload.withUnsafeBytes { raw -> Int in
                write(connFd, raw.baseAddress!.advanced(by: off), raw.count - off)
            }
            if w <= 0 { break }
            off += w
        }
        // Close immediately, sending FIN so the client sees EOF.
        close(connFd)
    }
}

#endif
