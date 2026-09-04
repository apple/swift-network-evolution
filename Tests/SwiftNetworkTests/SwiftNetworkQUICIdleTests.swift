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
                        client.ack.timerFired(at: .now)
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
}
#endif
#endif
#endif
