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
final class StatisticsTests: XCTestCase {
    var statistics: Statistics!

    override func setUp() {
        statistics = Statistics()
    }

    func testInitialStatistics() {
        for statistic in QUICStatistic.allCases {
            XCTAssertEqual(statistics[statistic], 0)
        }
    }

    func testConnectionStatisticsOpperations() {
        var expectedValue = 0
        XCTAssertEqual(statistics[.rxPackets], expectedValue)

        expectedValue += 5
        statistics[.rxPackets] += 5
        XCTAssertEqual(statistics[.rxPackets], expectedValue)

        expectedValue -= 3
        statistics[.rxPackets] -= 3
        XCTAssertEqual(statistics[.rxPackets], expectedValue)

        expectedValue = 10
        statistics[.rxPackets] = 10
        XCTAssertEqual(statistics[.rxPackets], expectedValue)
    }
}

#endif
