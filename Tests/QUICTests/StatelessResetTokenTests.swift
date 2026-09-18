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

#if !NETWORK_NO_SWIFT_QUIC

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

@available(Network 0.1.0, *)
class StatelessResetTokenTests: XCTestCase {
    func testRandomInit() {
        let token1 = QUICStatelessResetToken()
        let token2 = QUICStatelessResetToken()

        XCTAssertTrue(token1.isValid)
        XCTAssertTrue(token2.isValid)
        XCTAssertNotEqual(token1, token2)
    }

    func testInit() {
        let token = QUICStatelessResetToken([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        XCTAssertNotNil(token)
        guard let token else { return }
        XCTAssertTrue(token.isValid)
    }

    func testInvalid() {
        let token = QUICStatelessResetToken([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertNotNil(token)
        guard let token else { return }
        XCTAssertFalse(token.isValid)
    }

    func test16ByteStatelessResetToken() {
        let sixteenByteArray: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xff, 0x10,
        ]
        let sixteenByteArrayCopy = sixteenByteArray
        let statelessResetToken = QUICStatelessResetToken(sixteenByteArray)
        XCTAssertNotNil(statelessResetToken)
        guard let statelessResetToken else { return }
        XCTAssertNotNil(statelessResetToken)
        XCTAssertEqual(statelessResetToken.token, sixteenByteArrayCopy)
        XCTAssertEqual(statelessResetToken.description, "0102030405060708090a0b0c0d0eff10")
        XCTAssertEqual(statelessResetToken.description.count, 32)
    }

    func testCompareStatelessResetTokens() {
        let sixteenByteArray: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xff, 0x10,
        ]
        let a = QUICStatelessResetToken(sixteenByteArray)
        let equal = QUICStatelessResetToken(sixteenByteArray)
        let notEqual = QUICStatelessResetToken([
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xff, 0x11,
        ])
        XCTAssertTrue(a == equal)
        XCTAssertFalse(a == notEqual)
    }
}

#endif
