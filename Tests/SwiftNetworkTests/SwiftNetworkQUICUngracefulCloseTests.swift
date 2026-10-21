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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
@_spi(Essentials) import SwiftNetworkTestSupport
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if IMPORT_SWIFTTLS
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Dispatch)
import Dispatch
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
final class SwiftNetworkQUICUngracefulCloseTests: NetTestCase {
    func testQUICServerUnreachable() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }

        // Drop 100% of packets from the client to make the server unreachable
        QUICTestHarness().runQUICTest(
            expectHandshakeError: .posix(ETIMEDOUT),
            clientDrops: .init(0...Int.max),
            clientOptions: clientOptions
        )
    }

    #if !os(Linux) && !os(Android) && canImport(Dispatch)
    func testQUICConcurrentClientConnectionTimeouts() throws {
        // Threads need the system clock; a mock clock is driven from one thread.
        try XCTSkipUnless(QUICTestHarness.usesRealTime, "Needs the system clock")

        // Drop 100% of packets from the client to make the server unreachable
        // Times out 100 clients connection close to the same time
        // This tests ensures that timers are still able to fire if needed even when the connection is going down.
        let context = NetworkContext(identifier: "concurrent")
        let queue = DispatchQueue(label: "concurrent queue", attributes: .concurrent)
        let group = DispatchGroup()
        for _ in 0..<100 {
            group.enter()
            queue.async {
                let clientOptions = QUICProtocol.options()
                clientOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }
                QUICTestHarness(realTime: context).runQUICTest(
                    expectHandshakeError: .posix(ETIMEDOUT),
                    clientDrops: .init(0...Int.max),
                    clientOptions: clientOptions
                )
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: DispatchTime.now() + .seconds(10)), .success)
    }
    #endif

    func testQUICSequentialClientConnectionTimeouts() throws {
        // Clients whose packets are all dropped reach their idle timeout in turn on one context and
        // clock; timers must keep firing while a connection goes down.
        let shared = ManualTimeContext("concurrent")
        for _ in 0..<100 {
            let clientOptions = QUICProtocol.options()
            clientOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }
            QUICTestHarness(manual: shared).runQUICTest(
                expectHandshakeError: .posix(ETIMEDOUT),
                clientDrops: .init(0...Int.max),
                clientOptions: clientOptions
            )
        }
    }

    func testQUICIdleTimeout() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterHandshake: { harness in
                var reportedError: NetworkError?
                harness.onContext {
                    harness.state?.serverHarness.waitForError { error in
                        reportedError = error
                    }
                }
                // Record and wait: nothing has arrived when `onContext` returns, so an assertion in
                // the callback would never run.
                harness.wait(until: { reportedError != nil }, timeout: 5.0, "server idle timeout")
                XCTAssertEqual(reportedError, NetworkError.posix(ETIMEDOUT))
            }
        )
    }

    func testQUICServerTimeoutAfterClientDrops() throws {
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }

        // Drop all packets to the server after the first
        QUICTestHarness().runQUICTest(
            expectHandshakeError: .posix(ETIMEDOUT),
            clientDrops: .init(1...Int.max),
            serverOptions: serverOptions,
        )
    }

    func testQUICServerApplicationCloseBeforeHandshakeComplete() throws {
        // Drop all packets to the server after the first. The client completes the handshake, but the
        // server never sees the client's Finished, so it closes while its key state is still .handshake
        weak var weakClient: QUICConnection?
        weak var weakServer: QUICConnection?
        QUICTestHarness().runQUICTest(
            clientDrops: .init(1...Int.max),
            waitForServerConnected: false,
            afterHandshake: { harness in
                weakClient = harness.state?.clientInstance
                weakServer = harness.state?.serverInstance
                var clientDisconnected = false
                harness.onContext {
                    harness.state?.clientHarness.waitForDisconnected {
                        clientDisconnected = true
                    }
                    harness.state?.serverHarness.stop(error: .init(quicApplicationError: 10, reason: "test"))
                }
                // Recorded and waited on rather than asserted inside the callback: the close has
                // to travel before the client sees it, so an assertion in there would never run.
                // Well below the 30 s idle timeout the client falls back to if it loses the close
                harness.wait(until: { clientDisconnected }, timeout: 5.0, "client to see the close")
                // RFC 9000 Section 10.2.3: a Handshake packet carries CONNECTION_CLOSE with
                // APPLICATION_ERROR instead of APPLICATION_CLOSE.
                XCTAssertEqual(
                    harness.state?.clientInstance.closeError?.code,
                    QUICTransportError.QUICTransportErrorCode.applicationError.rawValue,
                    "Server sent APPLICATION_CLOSE in a Handshake packet"
                )
            }
        )

        // On the system clock the connections finish closing after this returns, so only a mock clock
        // can check; a connection still alive here keeps its timer, and the timer keeps the connection.
        if !QUICTestHarness.usesRealTime {
            XCTAssertNil(weakClient, "The client connection must be released once the test ends")
            XCTAssertNil(weakServer, "The server connection must be released once the test ends")
        }
    }

    #if !NETWORK_PRIVATE
    func testQUICClientClosesOnFrameNotAllowedDuringHandshake() throws {
        // Same setup as above, so the server still sends Handshake packets. RFC 9000 §12.4: a frame
        // that is not permitted in a Handshake packet is a PROTOCOL_VIOLATION for the client
        QUICTestHarness().runQUICTest(
            clientDrops: .init(1...Int.max),
            waitForServerConnected: false,
            afterHandshake: { harness in
                var checked = false
                var clientClosed = false
                harness.onContext {
                    if let server = harness.state?.serverInstance {
                        server.fromExternal { eventContext in
                            // HANDSHAKE_DONE is only allowed in 1-RTT packets
                            server.withPendingItems(for: .handshake) { $0.handshakeDone = true }
                            server.sendFrames(in: &eventContext)
                        }
                    }
                    // Queued behind the delivery of that packet. A later check would pass even without
                    // closing on the violation, because the next server packet also closes the client
                    harness.context.async {
                        clientClosed = harness.state?.clientHarness.receivedDisconnected ?? false
                        checked = true
                    }
                }
                harness.wait(until: { checked }, timeout: 5.0, "the client to handle the packet")
                XCTAssertTrue(
                    clientClosed,
                    "Client did not close on a frame not allowed in a Handshake packet"
                )
            }
        )
    }
    #endif

    func testQUICStatelessResetTokenWithSCID() throws {
        // This test seeds the stateless reset token and the SCID on the server.
        // Then sends a stateless reset packet to the client with the seeded token and verifies the connection closes.
        // Adding the SCID here changes which CID the token is tied to.
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions {
            $0.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        }
        let token: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ]
        serverOptions.modifyConnectionOptions { $0.initialStatelessResetToken = QUICStatelessResetToken(token) }
        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            afterHandshake: { harness in
                var reportedError: NetworkError?
                harness.onContext {
                    harness.state?.clientHarness.waitForError { error in
                        reportedError = error
                    }

                    let statelessResetPacket = try! QUICConnectionUtilities.createStatelessResetPacket(
                        token: QUICStatelessResetToken(token)!,
                        triggeringPacketLength: 35
                    )
                    XCTAssertTrue(statelessResetPacket.count < 35, "The stateless reset is too large")
                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        .init(copyBuffer: statelessResetPacket),
                        to: harness.clientPort
                    )
                }
                harness.wait(until: { reportedError != nil }, timeout: 5.0, "client to report the reset")
                XCTAssertEqual(reportedError, NetworkError.posix(ECONNRESET))
            }
        )
    }

    func testQUICStatelessResetTokenWithoutSCID() throws {
        // This test seeds the stateless reset token on the server.
        // Then sends a stateless reset packet to the client with the seeded token and verifies the connection closes.
        let serverOptions = QUICProtocol.options()
        let token: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ]
        serverOptions.modifyConnectionOptions { $0.initialStatelessResetToken = QUICStatelessResetToken(token) }
        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            afterHandshake: { harness in
                var reportedError: NetworkError?
                harness.onContext {
                    harness.state?.clientHarness.waitForError { error in
                        reportedError = error
                    }

                    let statelessResetPacket = try! QUICConnectionUtilities.createStatelessResetPacket(
                        token: QUICStatelessResetToken(token)!,
                        triggeringPacketLength: 35
                    )
                    XCTAssertTrue(statelessResetPacket.count < 35, "The stateless reset is too large")
                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        .init(copyBuffer: statelessResetPacket),
                        to: harness.clientPort
                    )
                }
                harness.wait(until: { reportedError != nil }, timeout: 5.0, "client to report the reset")
                XCTAssertEqual(reportedError, NetworkError.posix(ECONNRESET))
            }
        )
    }
}
#endif
#endif

#endif
