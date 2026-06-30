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
final class SwiftNetworkQUICSpinBitTests: NetTestCase {
    func testQUICSpinBitEnabledOrDisabled() throws {
        // Even when the client leaves the spin bit enabled there is a chance (1 / 16) that it
        // will be disabled due to language in the spec:
        // "endpoints MUST disable their use of the spin bit for a random selection of at least
        // one in every 16 network paths"
        // If the spin bit is disabled then the test short circuits and ends, if it is enable then it verified
        // it from the server.

        nonisolated(unsafe) var hasSpinBit = true
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate spin bit")
                harness.context.async {
                    defer { expectation.fulfill() }
                    guard let clientInstance = harness.state?.clientInstance,
                        let serverInstance = harness.state?.serverInstance
                    else {
                        XCTFail("State needs to be present to proceed")
                        return
                    }

                    guard clientInstance.spinBitEnabled && serverInstance.spinBitEnabled else {
                        Logger.proto.info("Spin bit was selected to not be enabled, end the test")
                        hasSpinBit = false
                        return
                    }
                }
                self.wait(for: [expectation], timeout: 5.0)
            },
            afterData: { harness in
                guard hasSpinBit else {
                    return
                }

                let expectation = XCTestExpectation(description: "Wait to validate spin bit")
                harness.context.async {
                    defer { expectation.fulfill() }

                    let clientSpinBit = harness.state?.clientInstance.currentPath?.spinValue ?? false
                    let serverSpinBit = harness.state?.serverInstance.currentPath?.spinValue ?? false
                    XCTAssertFalse(clientSpinBit, "Client should have the spin bit set to false")
                    XCTAssertTrue(serverSpinBit, "Server should have the spin bit set to true")
                }
            }
        )
    }

    func testQUICSpinBitDisabled() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.disableSpinBit = true
        clientOptions.connectionOptions.spinBitValue = false
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.disableSpinBit = true
        serverOptions.connectionOptions.spinBitValue = false
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate spin bit")
                harness.context.async {
                    defer { expectation.fulfill() }
                    let clientSpinBit = harness.state?.clientInstance.currentPath?.spinValue ?? false
                    let serverSpinBit = harness.state?.serverInstance.currentPath?.spinValue ?? false
                    XCTAssertFalse(clientSpinBit, "Client should have the spin bit set to false")
                    XCTAssertFalse(serverSpinBit, "Server should have the spin bit set to true")
                }
            }
        )
    }
}
#endif
#endif
#endif
