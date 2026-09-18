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
final class SwiftNetworkQUICStatisticsTests: NetTestCase {
    func testQUICStatisticsForOneStream() throws {
        QUICTestHarness().runQUICTest(
            blockSize: 10240,
            blockCount: 4,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate stats")
                harness.context.async {
                    defer { expectation.fulfill() }

                    let clientConnectionStats = harness.state?.clientInstance.stats.connectionStatistics
                    XCTAssertNotNil(clientConnectionStats)
                    guard let clientConnectionStats else {
                        return
                    }
                    let totalSentBytes = 10240 * 4
                    XCTAssertTrue(clientConnectionStats[.rxBytes]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txBytes]! > 0)
                    XCTAssertTrue(clientConnectionStats[.rxPackets]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txPackets]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txStreamBytes]! > 0)
                    XCTAssertTrue(clientConnectionStats[.rxStreamBytes]! > 0)
                    XCTAssertEqual(clientConnectionStats[.txStreamBytes]!, totalSentBytes)
                    XCTAssertEqual(clientConnectionStats[.rxStreamBytes]!, totalSentBytes)
                    XCTAssertEqual(clientConnectionStats[.outboundBidirectionalStreams], 1)
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }

    func testQUICStatisticsForMultipleStreams() throws {
        QUICTestHarness().runQUICTest(
            streamCount: 6,
            blockSize: 10240,
            blockCount: 4,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait to validate stats")
                harness.context.async {
                    defer { expectation.fulfill() }

                    let clientConnectionStats = harness.state?.clientInstance.stats.connectionStatistics
                    XCTAssertNotNil(clientConnectionStats)
                    guard let clientConnectionStats else {
                        return
                    }
                    XCTAssertTrue(clientConnectionStats[.rxBytes]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txBytes]! > 0)
                    XCTAssertTrue(clientConnectionStats[.rxPackets]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txPackets]! > 0)
                    XCTAssertEqual(clientConnectionStats[.outboundBidirectionalStreams], 6)
                    XCTAssertEqual(clientConnectionStats[.txInitialCryptoFrames], 1)
                    XCTAssertEqual(clientConnectionStats[.rxInitialCryptoFrames], 1)
                    XCTAssertEqual(clientConnectionStats[.txHandshakeCryptoFrames], 1)
                    XCTAssertEqual(clientConnectionStats[.rxHandshakeCryptoFrames], 1)
                    XCTAssertEqual(clientConnectionStats[.connectionAttempts], 1)
                    XCTAssertTrue(clientConnectionStats[.rxStreamFrames]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txStreamFrames]! > 0)
                    XCTAssertTrue(clientConnectionStats[.txStreamBytes]! > 0)
                    XCTAssertTrue(clientConnectionStats[.rxStreamBytes]! > 0)
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )
    }
}

#endif
#endif
#endif
