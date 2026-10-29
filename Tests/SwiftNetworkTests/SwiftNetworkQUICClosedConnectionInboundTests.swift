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
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
final class SwiftNetworkQUICClosedConnectionInboundTests: NetTestCase {
    /// Runs `body` on the harness context once the server has finished the receive batch that closed
    /// it. The server's disconnect completion runs in the middle of that batch, so the check is
    /// queued behind it.
    private func afterServerClosed(
        _ harness: QUICTestHarness,
        trigger: @escaping (QUICConnection) -> Void,
        check: @escaping (QUICConnection) -> Void
    ) {
        var checked = false
        harness.onContext {
            guard let state = harness.state else {
                XCTFail("Harness state is gone")
                return
            }
            state.serverHarness.waitForDisconnected {
                // Queued behind the rest of the receive batch that closed the server.
                harness.context.async {
                    check(state.serverInstance)
                    checked = true
                }
            }
            trigger(state.clientInstance)
        }
        // Recorded and waited on rather than asserted in the callback: if the server never closes,
        // the callback never fires and the check would silently not run.
        harness.wait(until: { checked }, timeout: 5.0, "the server to process the closing batch")
    }

    // Should not be probing when connection is taken down
    func testPeerApplicationCloseDoesNotStartPathValidation() {
        QUICTestHarness().runQUICTest(
            afterHandshake: { harness in
                self.afterServerClosed(
                    harness,
                    trigger: { _ in
                        harness.state?.clientHarness.stop(error: .init(quicApplicationError: 0, reason: ""))
                    },
                    check: { server in
                        XCTAssertTrue(server.state.isTerminal, "Server did not close: \(server.state)")
                        let pathStates = server.multiplexingPaths.values.map { $0.state }
                        XCTAssertFalse(
                            pathStates.contains(.probing),
                            "Closed server connection started path validation: \(pathStates)"
                        )
                    }
                )
            }
        )
    }

    // When a datagram in a batch closes the connection, future datagrams should not be processed
    func testDatagramBehindClosingDatagramIsNotProcessed() {
        QUICTestHarness().runQUICTest(
            serverLinkDelay: .milliseconds(50),
            afterHandshake: { harness in
                self.afterServerClosed(
                    harness,
                    trigger: { client in
                        client.fromExternal { eventContext in
                            client.withPendingItems(for: .applicationData) { $0.handshakeDone = true }
                            client.sendFrames(in: &eventContext)
                            client.withPendingItems(for: .applicationData) { $0.ping = true }
                            client.sendFrames(in: &eventContext)
                        }
                    },
                    check: { server in
                        XCTAssertTrue(server.state.isTerminal, "Server did not close: \(server.state)")
                        let pathStates = server.multiplexingPaths.values.map { $0.state }
                        XCTAssertFalse(
                            pathStates.contains(.probing),
                            "Closed server connection started path validation: \(pathStates)"
                        )
                        // The probe is a ~1200 byte datagram sent from a closing connection.
                        let challengesSent = server.multiplexingPaths.values.map { $0.challengesSent }
                        XCTAssertEqual(
                            challengesSent.reduce(0, +),
                            0,
                            "Closed server connection sent PATH_CHALLENGE: \(challengesSent)"
                        )
                    }
                )
            }
        )
    }
}
#endif
#endif
#endif
