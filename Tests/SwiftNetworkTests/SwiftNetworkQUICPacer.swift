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

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

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
final class SwiftNetworkQUICPacer: NetTestCase {
    func testQUICClientPacingMarkedPackets() throws {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.enablePacing = true
        QUICTestHarness().runQUICTest(
            blockSize: 10240,
            blockCount: 4,
            clientOptions: clientOptions,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate departure time")
                harness.context.async {
                    XCTAssertTrue(
                        harness.state?.clientInstance.stats[.txDepartureTimestamp] ?? 0 > 0,
                        "Client Frames should be marked with departureTime"
                    )
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICServerPacingMarkedPackets() throws {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.enablePacing = true
        QUICTestHarness().runQUICTest(
            blockSize: 10240,
            blockCount: 4,
            serverOptions: serverOptions,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate departure time")
                harness.context.async {
                    XCTAssertTrue(
                        harness.state?.serverInstance.stats[.txDepartureTimestamp] ?? 0 > 0,
                        "Server Frames should be marked with departureTime"
                    )
                    expectation.fulfill()
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICPacketPacingDisabled() throws {
        QUICTestHarness().runQUICTest(
            blockSize: 10240,
            blockCount: 4,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate departure time")
                harness.context.async {
                    XCTAssertEqual(
                        harness.state?.clientInstance.stats[.txDepartureTimestamp],
                        0,
                        "Client Frames should NOT be marked with departureTime"
                    )
                    XCTAssertEqual(
                        harness.state?.serverInstance.stats[.txDepartureTimestamp],
                        0,
                        "Server Frames should NOT be marked with departureTime"
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
