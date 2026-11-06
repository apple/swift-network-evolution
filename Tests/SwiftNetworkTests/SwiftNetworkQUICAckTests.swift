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
final class SwiftNetworkQUICAckTests: NetTestCase {
    // Long enough that the delayed ACK timer cannot fire, nor the peer's PTO
    // fire while an ACK is legitimately delayed, within `ackTimeout`.
    private static let maxAckDelay: NetworkDuration = .seconds(30)
    private static let ackTimeout: TimeInterval = 1

    /// Stretches the client's delayed ACK timer so that any ACK the server sees
    /// within `ackTimeout` was sent without waiting for it.
    private func stretchClientAckDelay(_ harness: QUICTestHarness) {
        harness.onContext {
            guard let client = harness.state?.clientInstance else {
                XCTFail("Client instance needs to be present to proceed")
                return
            }
            client.fromExternal { eventContext in
                client.ack.maxDelay = Self.maxAckDelay
                // Scheduling a delayed ACK keeps an armed deadline, so re-arm it.
                if client.ack.timerScheduled, let timerID = client.ack.timerID {
                    client.timer.reschedule(
                        identifier: timerID,
                        fromNow: client.ack.maxDelay,
                        timerNow: client.now,
                        in: &eventContext
                    )
                }
            }
            harness.state?.serverInstance.currentPath?.rtt.remoteMaxAckDelay = Self.maxAckDelay
        }
    }

    /// Sends any ACK the client still owes, so that it owes none.
    private func flushClientAck(_ harness: QUICTestHarness) {
        harness.onContext {
            guard let client = harness.state?.clientInstance else {
                XCTFail("Client instance needs to be present to proceed")
                return
            }
            client.fromExternal { eventContext in
                client.fireDelayedAckTimer(at: harness.now, in: &eventContext)
            }
            XCTAssertEqual(client.ack.unackedPacketCount, 0, "Client should not owe the peer an ACK")
        }
    }

    /// Has the server send a PING-only packet and returns its packet number.
    private func serverSendsPing(_ harness: QUICTestHarness) -> PacketNumber? {
        var packetNumber: PacketNumber?
        harness.onContext {
            guard let server = harness.state?.serverInstance else {
                XCTFail("Server instance needs to be present to proceed")
                return
            }
            server.fromExternal { eventContext in
                packetNumber = server.protector.getPacketNumber(for: .applicationData)
                server.withPendingItems(for: .applicationData) { $0.ping = true }
                server.sendFrames(in: &eventContext)
            }
        }
        return packetNumber
    }

    private func waitForServerToSeeAck(
        of packetNumber: PacketNumber,
        _ harness: QUICTestHarness,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        harness.wait(
            until: {
                guard let server = harness.state?.serverInstance else { return false }
                let largestAcked = server.largestAckedPacketNumber(space: .applicationData)
                return largestAcked.value != Int.max && largestAcked >= packetNumber
            },
            timeout: Self.ackTimeout,
            what,
            file: file,
            line: line
        )
    }

    func testSecondAckElicitingPacketIsAckedImmediately() {
        // A second unacknowledged ack-eliciting packet is ACKed without waiting for the
        // delayed ACK timer (RFC 9000 Section 13.2.2), even when the ACK is the only
        // frame the receiver has to send.
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterHandshake: { harness in
                self.stretchClientAckDelay(harness)
            },
            afterData: { harness in
                self.flushClientAck(harness)

                guard let firstPing = self.serverSendsPing(harness) else { return }
                harness.onContext {
                    let client = harness.state?.clientInstance
                    XCTAssertEqual(client?.ack.unackedPacketCount, 1, "Client should delay the first ACK")
                }

                guard let secondPing = self.serverSendsPing(harness) else { return }
                XCTAssertGreaterThan(secondPing, firstPing)
                self.waitForServerToSeeAck(of: secondPing, harness, "the client to ACK the second PING")
                harness.onContext {
                    guard let client = harness.state?.clientInstance else { return }
                    XCTAssertEqual(client.ack.unackedPacketCount, 0, "Client should not owe the peer an ACK")
                    XCTAssertFalse(
                        client.applicationPendingItems.isAckSet,
                        "Client should not hold back an ACK it decided to send immediately"
                    )
                }
            }
        )
    }

    func testQueuedAckIsRebuiltToCoverNewPackets() {
        // An ACK frame that is already queued when another ack-eliciting packet arrives
        // must be rebuilt before it is sent, so that it also acknowledges that packet.
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterHandshake: { harness in
                self.stretchClientAckDelay(harness)
            },
            afterData: { harness in
                self.flushClientAck(harness)

                guard let firstPing = self.serverSendsPing(harness) else { return }

                // Queue an ACK for the first PING without sending it.
                harness.onContext {
                    guard let client = harness.state?.clientInstance else {
                        XCTFail("Client instance needs to be present to proceed")
                        return
                    }
                    let queued = client.ack.assemble(
                        for: .applicationData,
                        isAckSet: false,
                        setAckFrame: client.scheduleAckFrame,
                        ecnCounter: nil,
                        now: client.now
                    )
                    XCTAssertTrue(queued, "Client should have an ACK to queue")
                    XCTAssertEqual(client.applicationPendingItems.ackFrame?.largest, firstPing)
                }

                guard let secondPing = self.serverSendsPing(harness) else { return }
                self.waitForServerToSeeAck(of: secondPing, harness, "the queued ACK to cover the second PING")
            }
        )
    }
}
#endif
#endif
#endif
