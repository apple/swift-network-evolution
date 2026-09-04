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

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

import XCTest
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

@available(Network 0.1.0, *)
final class SwiftNetworkConnectionTests: NetTestCase {
    func testUDPConnectionInit() throws {
        let c1 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            UDP()
                .noChecksumPreferred(true)
        }
        XCTAssertNotNil(c1)

        let c2 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            UDP {
                IP()
                    .receiveTimeCalculated(true)
            }.noChecksumPreferred(true)
        }
        XCTAssertNotNil(c2)

        let uuid = SystemUUID()
        let c3 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777), uuid: uuid) {
            UDP()
                .noChecksumPreferred(true)
        }
        XCTAssertNotNil(c3)
        XCTAssertEqual(c3.uuid, uuid)
    }

    func testQUICConnectionInit() throws {
        let c1 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            QUIC(alpn: ["QUICTest"])
                .initialMaxBidirectionalStreams(10)
                .tls.earlyDataEnabled(true)
                .tls.ticketsEnabled(true)
        }
        XCTAssertNotNil(c1)

        let c2 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            QUIC(alpn: ["QUICTest"]) {
                UDP()
                    .noChecksumPreferred(true)
            }.initialMaxStreamDataUnidirectional(10)
        }
        XCTAssertNotNil(c2)

        let c3 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            QUIC(alpn: ["QUICTest"]) {
                UDP {
                    IP()
                        .multicastLoopbackDisabled(true)
                }.noChecksumPreferred(true)
            }.initialMaxStreamDataBidirectionalRemote(10)
        }
        XCTAssertNotNil(c3)

        let uuid = SystemUUID()
        let c4 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777), uuid: uuid) {
            QUIC(alpn: ["QUICTest"]) {
                UDP {
                    IP()
                        .multicastLoopbackDisabled(true)
                }.noChecksumPreferred(true)
            }.initialMaxStreamDataBidirectionalRemote(10)
        }
        XCTAssertNotNil(c4)
        XCTAssertEqual(c4.uuid, uuid)

        let c5 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777), uuid: uuid) {
            QUIC(alpn: ["QUICTest"])
                .sourceConnectionIDLength(10)
        }
        XCTAssertNotNil(c5)
    }

    func testQUICConnectionCreateStream() throws {
        let tunnel = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            QUIC(alpn: ["QUICTest"])
        }
        XCTAssertNotNil(tunnel)
        tunnel.openStream { result in
            switch result {
            case .success(let stream):
                XCTAssertNotNil(stream)
            case .failure(let error):
                print("Couldn't create stream: \(error)")
                XCTAssertTrue(false)
            }
        }
    }

    func testQUICStateUpdates() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let tunnel = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            QUIC(alpn: ["QUICTest"])
        }.onStateUpdate { _, state in
            print("New tunnel state \(state)")
            semaphore.signal()
        }.start()
        XCTAssertNotNil(tunnel)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(3)),
            DispatchTimeoutResult.success
        )
    }

    #if IMPORT_SWIFTTLS
    #if canImport(SwiftTLS)
    func testQUICHandshake() {
        let serverSigningKey = P256.Signing.PrivateKey()
        let serverPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        let serverPublicKeys = [[UInt8](serverSigningKey.publicKey.derRepresentation)]

        let group = DispatchGroup()
        group.enter()
        let client = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 8888),
            using: .parameters {
                QUIC(alpn: ["QUICTest"]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.trustedRawPublicKeyCertificates(serverPublicKeys)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 8889))
        )
        .onStateUpdate { _, state in
            print("client \(state)")
            switch state {
            case .ready:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(client)

        group.enter()
        let server = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 8889),
            using: .parameters {
                QUIC(alpn: ["QUICTest"]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.rawPrivateKey(serverPrivateKey)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 8888))
                .serverMode(true)
        )
        .onStateUpdate { _, state in
            print("server \(state)")
            switch state {
            case .ready:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(server)

        server.start()
        client.start()

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )

        let cancelGroup = DispatchGroup()
        cancelGroup.enter()
        cancelGroup.enter()
        client.onStateUpdate { _, state in if case .cancelled = state { cancelGroup.leave() } }
        server.onStateUpdate { _, state in if case .cancelled = state { cancelGroup.leave() } }
        client.cancel()
        server.cancel()
        XCTAssertEqual(
            cancelGroup.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }

    func testQUICDatapathCopy() {
        let serverSigningKey = P256.Signing.PrivateKey()
        let serverPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        let serverPublicKeys = [[UInt8](serverSigningKey.publicKey.derRepresentation)]

        let group = DispatchGroup()
        group.enter()
        let client = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 8888),
            using: .parameters {
                QUIC(alpn: ["QUICTest"]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.trustedRawPublicKeyCertificates(serverPublicKeys)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 8889))
        )
        .onStateUpdate { _, state in
            print("client \(state)")
            switch state {
            case .ready:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(client)

        group.enter()
        let server = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 8889),
            using: .parameters {
                QUIC(alpn: ["QUICTest"]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.rawPrivateKey(serverPrivateKey)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 8888))
                .serverMode(true)
        )
        .onStateUpdate { _, state in
            print("server \(state)")
            switch state {
            case .ready:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(server)

        server.start()
        client.start()

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )

        let dataChunk = Array("Hello World!".utf8)

        group.enter()
        client.openStream { result in
            switch result {
            case .success(let stream):
                group.enter()
                stream.send(.message(content: dataChunk, isComplete: true)) { sendResult in
                    switch sendResult {
                    case .success:
                        break
                    case .failure(let error):
                        XCTFail("send failed with error \(error)")
                    }
                    group.leave()
                }
                break
            case .failure(let error):
                print("Couldn't create stream: \(error)")
            }
            group.leave()
        }

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )

        let cancelGroup = DispatchGroup()
        cancelGroup.enter()
        cancelGroup.enter()
        client.onStateUpdate { _, state in if case .cancelled = state { cancelGroup.leave() } }
        server.onStateUpdate { _, state in if case .cancelled = state { cancelGroup.leave() } }
        client.cancel()
        server.cancel()
        XCTAssertEqual(
            cancelGroup.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }

    class TestWrappedBuffer {
        var buffer: UnsafeMutableRawBufferPointer
        init(capacity: Int) {
            buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 1)
            buffer.initializeMemory(as: UInt8.self, repeating: UInt8(0))
        }

        deinit {
            print("Freeing test buffer")
            buffer.deallocate()
        }
    }

    func testQUICDatapathNoCopy() {
        let serverSigningKey = P256.Signing.PrivateKey()
        let serverPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        let serverPublicKeys = [[UInt8](serverSigningKey.publicKey.derRepresentation)]

        let group = DispatchGroup()
        group.enter()
        let client = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 8888),
            using: .parameters {
                QUIC(alpn: ["QUICTest"]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.trustedRawPublicKeyCertificates(serverPublicKeys)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 8889))
        )
        .onStateUpdate { _, state in
            print("client \(state)")
            switch state {
            case .ready:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(client)

        group.enter()
        let server = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 8889),
            using: .parameters {
                QUIC(alpn: ["QUICTest"]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.rawPrivateKey(serverPrivateKey)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 8888))
                .serverMode(true)
        )
        .onStateUpdate { _, state in
            print("server \(state)")
            switch state {
            case .ready:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(server)

        server.start()
        client.start()

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )

        let wrappedBuffer = TestWrappedBuffer(capacity: 1000)

        group.enter()
        client.openStream { result in
            switch result {
            case .success(let stream):
                group.enter()
                stream.send(wrappedBuffer.buffer, owner: wrappedBuffer, isComplete: true) { sendResult in
                    switch sendResult {
                    case .success:
                        break
                    case .failure(let error):
                        XCTFail("send failed with error \(error)")
                    }
                    group.leave()
                }
                break
            case .failure(let error):
                print("Couldn't create stream: \(error)")
            }
            group.leave()
        }

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )

        let cancelGroup = DispatchGroup()
        cancelGroup.enter()
        cancelGroup.enter()
        client.onStateUpdate { _, state in if case .cancelled = state { cancelGroup.leave() } }
        server.onStateUpdate { _, state in if case .cancelled = state { cancelGroup.leave() } }
        client.cancel()
        server.cancel()
        XCTAssertEqual(
            cancelGroup.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }

    #endif
    #endif

    func testCInterop() throws {
        func toCRetained(_ connection: NetworkChannelBase) -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(connection).toOpaque()
        }

        func fromC(_ connection: UnsafeRawPointer) {
            switch Unmanaged<NetworkChannelBase>.fromOpaque(connection).takeUnretainedValue().kind {
            case .tcp:
                let tcpConnection = Unmanaged<NetworkConnection<TCP>>.fromOpaque(connection).takeUnretainedValue()
                XCTAssertNotNil(tcpConnection)
            case .udp:
                let udpConnection = Unmanaged<NetworkConnection<UDP>>.fromOpaque(connection).takeUnretainedValue()
                XCTAssertNotNil(udpConnection)
                print("UDP in C interop test")
            case .quic:
                let quicConnection = Unmanaged<NetworkConnection<QUIC>>.fromOpaque(connection).takeUnretainedValue()
                XCTAssertNotNil(quicConnection)
                print("QUIC in C interop test")
            case .tls:
                let tlsConnection = Unmanaged<NetworkConnection<TLS>>.fromOpaque(connection).takeUnretainedValue()
                XCTAssertNotNil(tlsConnection)
                print("TLS in C interop test")
            case .noTransport:
                let noTransportConnection = Unmanaged<NetworkConnection<NoTransport>>.fromOpaque(connection)
                    .takeUnretainedValue()
                XCTAssertNotNil(noTransportConnection)
                print("NoTransport in C interop test")
            }
        }

        let c1 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            UDP()
        }
        XCTAssertNotNil(c1)
        let toC1 = toCRetained(c1)
        XCTAssertNotNil(toC1)
        fromC(toC1)

        let c2 = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: 7777)) {
            QUIC(alpn: ["QUICTest"])
        }
        XCTAssertNotNil(c2)
        let toC2 = toCRetained(c2)
        XCTAssertNotNil(toC2)
        fromC(toC2)
    }

    func testUDPInvalidParameters() {
        let group = DispatchGroup()
        group.enter()

        // Create a mismatch between IPv4 and IPv6 endpoints to induce a failure
        let c1 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7778),
            using: .parameters {
                UDP {
                    IP {
                        DatagramBridge()
                    }
                }
            }.localEndpoint(Endpoint(address: IPv6Address.loopback, port: 7777))
        )
        .onStateUpdate { _, state in
            print("c1 \(state)")
            switch state {
            case .ready:
                XCTFail("Should not be ready")
            case .failed(_):
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c1)

        c1.start()

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )

        c1.cancel()
    }

    func testUDPDataPath() {
        let group = DispatchGroup()
        group.enter()
        let c1 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7778),
            using: .parameters {
                UDP {
                    IP {
                        DatagramBridge()
                    }
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7777))
        )
        .onStateUpdate { _, state in
            print("c1 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c1)

        group.enter()
        let c2 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7777),
            using: .parameters {
                UDP {
                    IP {
                        DatagramBridge()
                    }
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7778))
        )
        .onStateUpdate { _, state in
            print("c2 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c2)

        c1.start()
        c2.start()

        c1.send(.message(content: [1, 2, 3])) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("send failed with error \(error)")
            }
        }

        c2.receive { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, [1, 2, 3])
                c1.cancel()
                c2.cancel()
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
        }

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }

    func testNoTransportDataPath() {
        let group = DispatchGroup()
        group.enter()
        let c1 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7778),
            using: .parameters {
                NoTransport {
                    StreamBridge()
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7777))
        )
        .onStateUpdate { _, state in
            print("c1 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c1)

        group.enter()
        let c2 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7777),
            using: .parameters {
                NoTransport {
                    StreamBridge()
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7778))
        )
        .onStateUpdate { _, state in
            print("c2 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c2)

        c1.start()
        c2.start()

        c1.send(.message(content: [1, 2, 3])) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("send failed with error \(error)")
            }
        }

        c2.receive(atLeast: 1, atMost: Int.max) { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, [1, 2, 3])
                c1.cancel()
                c2.cancel()
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
        }

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }

    func testNoTransportSpanDataPath() {
        let group = DispatchGroup()
        group.enter()
        let c1 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7778),
            using: .parameters {
                NoTransport {
                    StreamBridge()
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7777))
        )
        .onStateUpdate { _, state in
            print("c1 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c1)

        group.enter()
        let c2 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7777),
            using: .parameters {
                NoTransport {
                    StreamBridge()
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7778))
        )
        .onStateUpdate { _, state in
            print("c2 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c2)

        c1.start()
        c2.start()

        c1.send(.message(content: [1, 2, 3])) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("send failed with error \(error)")
            }
        }

        c2.receive(atLeast: 1, atMost: Int.max, maximumChunks: 4) { result in
            switch result {
            case .success(let message):
                let span = message.content
                if let span {
                    XCTAssertEqual(span.byteCount, 3)
                    for i in 0..<3 {
                        XCTAssertEqual(span[i], UInt8(exactly: i + 1))
                    }
                } else {
                    XCTFail("No span received")
                }
                c1.cancel()
                c2.cancel()
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
        }

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }

    #if HAS_SWIFTTLS_RECORD
    func testTLSNoTransportDataPath() {
        let group = DispatchGroup()
        group.enter()
        let c1 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7778),
            using: .parameters {
                TLS {
                    NoTransport {
                        StreamBridge()
                    }
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7777))
        )
        .onStateUpdate { _, state in
            print("c1 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c1)

        group.enter()
        let c2 = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7777),
            using: .parameters {
                TLS {
                    NoTransport {
                        StreamBridge()
                    }
                }
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7778))
        )
        .onStateUpdate { _, state in
            print("c2 \(state)")
            switch state {
            case .cancelled:
                group.leave()
            default:
                break
            }
        }
        XCTAssertNotNil(c2)

        c1.start()
        c2.start()

        c1.send(.message(content: [1, 2, 3])) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("send failed with error \(error)")
            }
        }

        c2.receive(atLeast: 1, atMost: Int.max) { result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, [1, 2, 3])
                c1.cancel()
                c2.cancel()
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
        }

        XCTAssertEqual(
            group.wait(timeout: DispatchTime.now() + .seconds(5)),
            DispatchTimeoutResult.success
        )
    }
    #endif
}
