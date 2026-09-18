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
final class SwiftNetworkQUICVersionNegotiation: NetTestCase {
    func testQUICClientForceVersionNegotiation() throws {
        // This test forces version negotiation from the client by sending the negotiation pattern to the server in the initial.
        // When the server recognizes that this pattern does not match it's initial version it contains then a version negotiation packet
        // is sent from the server to the client. The client picks a suitable version and sends it back in the initial and the handshake continues.

        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.forceVersionNegotiation = true
        clientOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate version")
                harness.context.async {
                    XCTAssertEqual(harness.state?.clientInstance.negotiatedVersion, .v1)
                    XCTAssertEqual(harness.state?.serverInstance.negotiatedVersion, .v1)
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICClientForceVersionNegotiationWithData() throws {

        // This test forces version negotiation from the client by sending the negotiation pattern to the server in the initial.
        // When the server recognizes that this pattern does not match it's initial version it contains then a version negotiation packet
        // is sent from the server to the client. The client picks a suitable version and sends it back in the initial and the handshake continues.
        // After this is all complete, a data exchange takes place to validate the connection.
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.forceVersionNegotiation = true
        clientOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate version")
                harness.context.async {
                    XCTAssertEqual(harness.state?.clientInstance.negotiatedVersion, .v1)
                    XCTAssertEqual(harness.state?.serverInstance.negotiatedVersion, .v1)
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICTestVersionNegotiationWithUnsupportedVersion() throws {
        // This test will inject an unsupported version on the client and verify that the server
        // does not recognize it and attempts to negotiate a supported version.
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        clientOptions.connectionOptions.forceUnsupportedClientVersion = true
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate version")
                harness.context.async {
                    XCTAssertEqual(harness.state?.clientInstance.negotiatedVersion, .v1)
                    XCTAssertEqual(harness.state?.serverInstance.negotiatedVersion, .v1)
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICVerifyClientAndServerVersionOnStandardHandshake() throws {
        // This test does a standard handshake and verifies that each peer has v1 at the end.
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate version")
                harness.context.async {
                    // currentVersion can contain the default or the negotiatedVersion
                    XCTAssertEqual(harness.state?.clientInstance.currentVersion, .v1)
                    XCTAssertEqual(harness.state?.serverInstance.currentVersion, .v1)
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
