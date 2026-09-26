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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
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
        clientOptions.connectionOptions.idleTimeout = .seconds(2)

        // Drop 100% of packets from the client to make the server unreachable
        QUICTestHarness().runQUICTest(
            expectHandshakeError: .posix(ETIMEDOUT),
            clientDrops: .init(0...Int.max),
            clientOptions: clientOptions
        )
    }

    #if !os(Linux) && canImport(Dispatch)
    func testQUICConcurrentClientConnectionTimeouts() throws {
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
                clientOptions.connectionOptions.idleTimeout = .seconds(2)
                QUICTestHarness(context: context).runQUICTest(
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

    func testQUICIdleTimeout() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.idleTimeout = .seconds(2)
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.idleTimeout = .seconds(2)

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait for timeout error")
                harness.context.async {
                    harness.state?.serverHarness.waitForError { error in
                        XCTAssertEqual(error, NetworkError.posix(ETIMEDOUT))
                        expectation.fulfill()
                    }
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICServerTimeoutAfterClientDrops() throws {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.idleTimeout = .seconds(2)

        // Drop all packets to the server after the first
        QUICTestHarness().runQUICTest(
            expectHandshakeError: .posix(ETIMEDOUT),
            clientDrops: .init(1...Int.max),
            serverOptions: serverOptions,
        )
    }

    func testQUICStatelessResetTokenWithSCID() throws {
        // This test seeds the stateless reset token and the SCID on the server.
        // Then sends a stateless reset packet to the client with the seeded token and verifies the connection closes.
        // Adding the SCID here changes which CID the token is tied to.
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let token: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ]
        serverOptions.connectionOptions.initialStatelessResetToken = QUICStatelessResetToken(token)
        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait for reset error")
                harness.context.async {
                    harness.state?.clientHarness.waitForError { error in
                        XCTAssertEqual(error, NetworkError.posix(ECONNRESET))
                        expectation.fulfill()
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
                self.wait(for: [expectation], timeout: 5.0)
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
        serverOptions.connectionOptions.initialStatelessResetToken = QUICStatelessResetToken(token)
        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait for reset error")
                harness.context.async {
                    harness.state?.clientHarness.waitForError { error in
                        XCTAssertEqual(error, NetworkError.posix(ECONNRESET))
                        expectation.fulfill()
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
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }
}
#endif
#endif

#endif
