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
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
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
final class SwiftNetworkQUICIdleTests: NetTestCase {
    func testQUICConnectionIdleTracksOwedAck() {
        // The idle state reported to the lower protocol must account for outstanding
        // transmit obligations, not just the application's idle mark.
        // A connection that still owes the peer an ACK is not idle.
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterHandshake: { harness in
                // The test relies on the client still owing a delayed ACK for the echoed
                // data when the idle state is evaluated, and sends that ACK explicitly.
                // Stretch the delayed ACK timer so it cannot fire on its own before then;
                // with the default 25ms delay, slow CI machines can lose that race.
                let expectation = XCTestExpectation(description: "Wait for delayed ACK timer to be extended")
                harness.context.async {
                    if let client = harness.state?.clientInstance {
                        client.fromExternal { eventContext in
                            client.ack.maxDelay = .seconds(30)
                            // The handshake may have already armed the timer with the default
                            // delay, and scheduling a delayed ACK keeps an armed deadline, so
                            // re-arm it with the extended delay.
                            if client.ack.timerScheduled, let timerID = client.ack.timerID {
                                client.timer.reschedule(
                                    identifier: timerID,
                                    fromNow: client.ack.maxDelay,
                                    timerNow: client.now,
                                    in: &eventContext
                                )
                            }
                        }
                    }
                    // Keep the server's view of the client's ACK delay consistent, otherwise
                    // its PTO fires while the ACK is held and the probe forces an immediate ACK.
                    harness.state?.serverInstance.currentPath?.rtt.remoteMaxAckDelay = .seconds(30)
                    expectation.fulfill()
                }
                let waitResult = XCTWaiter.wait(for: [expectation], timeout: 2.0)
                XCTAssertEqual(waitResult, .completed, "Delayed ACK timer should be extended")
            },
            afterData: { harness in
                // Verify the reported idle state follows the transmit obligations
                let expectation = XCTestExpectation(description: "Wait for idle state to be evaluated")
                harness.context.async {
                    let client = harness.state?.clientInstance
                    XCTAssertNotNil(client, "Client instance needs to be present to proceed")
                    if let client {
                        XCTAssertFalse(
                            client.currentPath?.reportedIdleEvent ?? true,
                            "Client should not have reported idle before the application marks idle"
                        )

                        for upperHarness in harness.state?.clientHarness.upperHarnesses ?? [] {
                            upperHarness.invokeConnectionIdleEvent()
                        }

                        // The echoed data has been received but not acknowledged yet, so
                        // a delayed ACK is still owed and the connection is not idle.
                        XCTAssertGreaterThan(
                            client.ack.unackedPacketCount,
                            0,
                            "Client should still owe the peer a delayed ACK"
                        )
                        XCTAssertFalse(
                            client.currentPath?.reportedIdleEvent ?? true,
                            "Client should not have reported idle while an ACK is owed to the peer"
                        )

                        // Once the delayed ACK has been sent there are no obligations left.
                        client.fromExternal { eventContext in
                            client.fireDelayedAckTimer(at: .systemNow, in: &eventContext)
                        }
                        XCTAssertEqual(
                            client.ack.unackedPacketCount,
                            0,
                            "Client should not owe the peer an ACK once the delayed ACK has been sent"
                        )
                        XCTAssertTrue(
                            client.currentPath?.reportedIdleEvent ?? false,
                            "Client should have reported idle once the owed ACK has been sent"
                        )

                        for upperHarness in harness.state?.clientHarness.upperHarnesses ?? [] {
                            upperHarness.invokeConnectionReusedEvent()
                        }
                        XCTAssertFalse(
                            client.currentPath?.reportedIdleEvent ?? true,
                            "Client should not have reported idle after the application reuses the connection"
                        )
                    }
                    expectation.fulfill()
                }
                let waitResult = XCTWaiter.wait(for: [expectation], timeout: 2.0)
                XCTAssertEqual(waitResult, .completed, "Idle state evaluation should complete")
            }
        )
    }

    func testDelayedAckTimerCanSendPMTUDProbe() {
        // Sending a delayed ACK can also send a PMTUD probe, and sending the probe reads
        // the connection's ACK state, so the timer must not still hold that state when it
        // sends.
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.pmtudIgnoreCost = true
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.pmtudIgnoreCost = true

        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait for the delayed ACK timer to fire")
                harness.context.async {
                    let client = harness.state?.clientInstance
                    XCTAssertNotNil(client, "Client instance needs to be present to proceed")
                    if let client, let path = client.currentPath {
                        XCTAssertGreaterThan(
                            client.ack.unackedPacketCount,
                            0,
                            "Client should still owe the peer a delayed ACK"
                        )

                        // Acknowledge a probe short of the path maximum, which leaves the
                        // next probe due on the next transmission.
                        let ipUDPHeaderSize = path.pmtudState.currentPathMTU - path.mss
                        client.fromExternal { eventContext in
                            client.acknowledgedPMTUDProbe(
                                on: path,
                                packetNumber: client.protector.getPacketNumber(for: .applicationData),
                                mss: 1492 - ipUDPHeaderSize,
                                in: &eventContext
                            )
                        }
                        let canSendProbe = path.pmtudState.canSendProbe(on: path, hasPendingItems: false)
                        XCTAssertTrue(
                            canSendProbe,
                            "Client should have a PMTUD probe ready to send alongside the delayed ACK"
                        )

                        client.fromExternal { eventContext in
                            client.fireDelayedAckTimer(at: .systemNow, in: &eventContext)
                        }

                        XCTAssertEqual(
                            client.ack.unackedPacketCount,
                            0,
                            "Client should not owe the peer an ACK once the delayed ACK has been sent"
                        )
                    }
                    expectation.fulfill()
                }
                let waitResult = XCTWaiter.wait(for: [expectation], timeout: 2.0)
                XCTAssertEqual(waitResult, .completed, "Delayed ACK timer should complete")
            },
            clientMTU: 1550
        )
    }
}
#endif
#endif
#endif
