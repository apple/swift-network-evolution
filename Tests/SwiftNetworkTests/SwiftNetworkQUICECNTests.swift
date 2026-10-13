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
#if !NETWORK_PRIVATE
@available(Network 0.1.0, *)
final class SwiftNetworkQUICECNTests: NetTestCase {
    func testQUICTestECNMarkedPacketsSentAndACKed() throws {
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterData: { harness in
                // Verify the pakets with ECN marking reached the other side
                let expectation = XCTestExpectation(description: "Wait to validate ECN")
                harness.context.async {
                    XCTAssertTrue(
                        harness.state?.serverInstance.stats[.ecnCapablePacketsAcknowledged] ?? 0 > 0,
                        "Server should have ACKed ECN marked packets"
                    )
                    XCTAssertTrue(
                        harness.state?.clientInstance.stats[.ecnCapablePacketsSent] ?? 0 > 0,
                        "Clients should have sent ECN marked packets"
                    )
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICTestECNMarkedPacketsDisabled() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.disableECN = true
        clientOptions.connectionOptions.disableECNEcho = true
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.disableECN = true
        serverOptions.connectionOptions.disableECNEcho = true
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterData: { harness in
                // Verify the packets with ECN marking reached the other side
                let expectation = XCTestExpectation(description: "Wait to validate ECN")
                harness.context.async {
                    XCTAssertTrue(
                        harness.state?.serverInstance.stats[.ecnCapablePacketsAcknowledged] == 0,
                        "Server should NOT have ACKed ECN marked packets"
                    )
                    XCTAssertTrue(
                        harness.state?.clientInstance.stats[.ecnCapablePacketsSent] == 0,
                        "Clients should NOT have sent ECN marked packets"
                    )
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    // L4S is applied to the initial path in `connect()`, after the path's own setup has
    // installed its default pacer and congestion control.
    func testQUICTestL4SUsesPrague() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.enableL4S = true
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate L4S")
                harness.context.async {
                    let path = harness.state?.clientInstance.currentPath
                    XCTAssertEqual(path?.l4sEnabled, true, "Client path should have L4S enabled")
                    XCTAssertEqual(path?.congestionControlName, "PRAGUE", "L4S should use Prague")
                    XCTAssertEqual(path?.pacer.enabled, true, "Prague always paces")
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICTestL4SDisabledByDefault() throws {
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate L4S")
                harness.context.async {
                    let path = harness.state?.clientInstance.currentPath
                    XCTAssertEqual(path?.l4sEnabled, false, "Client path should not have L4S enabled")
                    XCTAssertEqual(path?.congestionControlName, "CUBIC", "Default should use CUBIC")
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }
}
#endif
#endif
#endif
#endif
