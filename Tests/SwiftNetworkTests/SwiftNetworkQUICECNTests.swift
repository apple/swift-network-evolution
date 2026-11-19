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
                // `onContext` rather than an expectation: on a mock clock the test thread is the only
                // thing that can run the work, so blocking would deadlock.
                harness.onContext {
                    XCTAssertTrue(
                        harness.state?.serverInstance.stats[.ecnCapablePacketsAcknowledged] ?? 0 > 0,
                        "Server should have ACKed ECN marked packets"
                    )
                    XCTAssertTrue(
                        harness.state?.clientInstance.stats[.ecnCapablePacketsSent] ?? 0 > 0,
                        "Clients should have sent ECN marked packets"
                    )
                }
            }
        )
    }

    func testQUICTestECNMarkedPacketsDisabled() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { $0.disableECN = true }
        clientOptions.modifyConnectionOptions { $0.disableECNEcho = true }
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.disableECN = true }
        serverOptions.modifyConnectionOptions { $0.disableECNEcho = true }
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterData: { harness in
                // Verify the packets with ECN marking reached the other side
                // `onContext` rather than an expectation: on a mock clock the test thread is the only
                // thing that can run the work, so blocking would deadlock.
                harness.onContext {
                    XCTAssertTrue(
                        harness.state?.serverInstance.stats[.ecnCapablePacketsAcknowledged] == 0,
                        "Server should NOT have ACKed ECN marked packets"
                    )
                    XCTAssertTrue(
                        harness.state?.clientInstance.stats[.ecnCapablePacketsSent] == 0,
                        "Clients should NOT have sent ECN marked packets"
                    )
                }
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
                harness.onContext {
                    let state = harness.state?.clientInstance.withCurrentPath {
                        (path: inout QUICPath) -> (l4s: Bool, name: String, paced: Bool) in
                        (path.l4sEnabled, path.congestionControlName, path.pacer.enabled)
                    }
                    XCTAssertEqual(state?.l4s, true, "Client path should have L4S enabled")
                    XCTAssertEqual(state?.name, "PRAGUE", "L4S should use Prague")
                    XCTAssertEqual(state?.paced, true, "Prague always paces")
                }
            }
        )
    }

    // A path that comes up after the connection is established gets its own L4S and pacing
    // configuration, in the same order as the initial path: `set()` first, then `setupL4S(on:)`.
    func testQUICTestL4SAppliedToAdditionalPath() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.enableL4S = true
        clientOptions.modifyConnectionOptions { $0.enablePacing = true }
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            afterData: { harness in
                harness.onContext {
                    guard let connection = harness.state?.clientInstance else {
                        XCTFail("No client connection")
                        return
                    }
                    let newPath = QUICPath.makeFromExternalTest(parent: connection)
                    let newPathID = newPath.pathIdentifier
                    try! connection.insertPath(newPath, for: newPathID)
                    connection.fromExternal { eventContext in
                        connection.handlePathChanged(
                            path: newPathID,
                            event: .available(local: nil, remote: nil, path: nil, parameters: nil),
                            pathProperties: MultiplexingPathProperties(isPrimary: false, isInjected: false),
                            in: &eventContext
                        )
                    }
                    XCTAssertNotEqual(
                        newPathID,
                        connection.currentPathID,
                        "Test needs a path other than the initial one"
                    )
                    let state = connection.withPath(newPathID) {
                        (path: inout QUICPath) -> (l4s: Bool, name: String, paced: Bool, pacePackets: Bool) in
                        (path.l4sEnabled, path.congestionControlName, path.pacer.enabled, path.pacePackets)
                    }
                    XCTAssertEqual(state?.l4s, true, "Second path should have L4S enabled")
                    XCTAssertEqual(state?.name, "PRAGUE", "Second path should use Prague")
                    XCTAssertEqual(state?.paced, true, "Second path should be paced")
                    XCTAssertEqual(state?.pacePackets, true, "Second path should honor the pacing option")
                }
            }
        )
    }

    func testQUICTestL4SDisabledByDefault() throws {
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterData: { harness in
                harness.onContext {
                    let state = harness.state?.clientInstance.withCurrentPath {
                        (path: inout QUICPath) -> (l4s: Bool, name: String) in
                        (path.l4sEnabled, path.congestionControlName)
                    }
                    XCTAssertEqual(state?.l4s, false, "Client path should not have L4S enabled")
                    XCTAssertEqual(state?.name, "CUBIC", "Default should use CUBIC")
                }
            }
        )
    }
}
#endif
#endif
#endif
#endif
