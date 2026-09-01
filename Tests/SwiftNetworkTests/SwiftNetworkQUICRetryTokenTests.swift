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
final class SwiftNetworkQUICRetryTokenTests: NetTestCase {
    func testQUICInternalServerForceRetryDuringInitial() throws {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.retry = true
        serverOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate tokens")
                harness.context.async {
                    XCTAssertNotNil(
                        harness.state?.clientInstance.initialToken,
                        "Client should have an initial retry token"
                    )
                    // The server's token was reset after verifying the client token.
                    XCTAssertNil(
                        harness.state?.serverInstance.initialToken,
                        "Server must discard the retry token once validated, so it is never sent in an INITIAL"
                    )
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICInternalServerForceRetryDuringInitialWithGiantALPNList() throws {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.retry = true
        serverOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        var alpnList = ["network_test"]
        for i in 0..<100 {
            alpnList.append("network_test_\(i)")
        }

        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.applicationProtocols = alpnList
        clientOptions.tlsOptions = tlsOptions

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate tokens")
                harness.context.async {
                    XCTAssertNotNil(
                        harness.state?.clientInstance.initialToken,
                        "Client should have an initial retry token"
                    )
                    // The server's token was reset after verifying the client token.
                    XCTAssertNil(
                        harness.state?.serverInstance.initialToken,
                        "Server must discard the retry token once validated, so it is never sent in an INITIAL"
                    )
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICInternalClientForceRetryDuringInitialFollowedByDataExchange() throws {
        let dataBlock: [UInt8] = Array("Hello World!".utf8)
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.retry = true
        serverOptions.connectionOptions.sourceConnectionID = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        QUICTestHarness().runQUICTest(
            dataBlock: dataBlock,
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate tokens")
                harness.context.async {
                    XCTAssertNotNil(
                        harness.state?.clientInstance.initialToken,
                        "Client should have an initial retry token"
                    )
                    // The server's token was reset after verifying the client token.
                    XCTAssertNil(
                        harness.state?.serverInstance.initialToken,
                        "Server must discard the retry token once validated, so it is never sent in an INITIAL"
                    )
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
