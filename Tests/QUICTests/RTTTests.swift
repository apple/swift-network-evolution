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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class RTTTests: XCTestCase {
    var rtt: RTT!

    override func setUp() {
        rtt = RTT(logPrefixer: .init("[RTTTests]"))
        rtt.remoteMaxAckDelay = .microseconds(100)
    }

    private func verifyRTTMeasurements(
        expectedMinRTT: NetworkDuration,
        expectedBaseRTT: NetworkDuration,
        expectedLatestRTT: NetworkDuration,
        expectedAdjustedRTT: NetworkDuration,
        expectedSmoothedRTT: NetworkDuration,
        expectedVariance: NetworkDuration,
        expectedHasInitialMeasurement: Bool,
        rtt: borrowing RTT
    ) {
        XCTAssertEqual(rtt.minRTT, expectedMinRTT)
        XCTAssertEqual(rtt.baseRTT, expectedBaseRTT)
        XCTAssertEqual(rtt.latestRTT, expectedLatestRTT)
        XCTAssertEqual(rtt.adjustedRTT, expectedAdjustedRTT)
        XCTAssertEqual(rtt.smoothedRTT, expectedSmoothedRTT)
        XCTAssertEqual(rtt.RTTVariance, expectedVariance)
        XCTAssertEqual(rtt.hasInitialMeasurement, expectedHasInitialMeasurement)
    }

    func testInitialRTT() {
        var rtt = RTT(logPrefixer: .init("[RTTTests]"))
        rtt.remoteMaxAckDelay = .microseconds(100)
        let (initialRTT, _) = rtt.cachedRTT
        XCTAssertEqual(initialRTT, .milliseconds(333))
        verifyRTTMeasurements(
            expectedMinRTT: .seconds(UInt32.max),
            expectedBaseRTT: .seconds(UInt32.max),
            expectedLatestRTT: .milliseconds(333),
            expectedAdjustedRTT: .microseconds(0),
            expectedSmoothedRTT: .milliseconds(333),
            expectedVariance: .milliseconds(166.5),
            expectedHasInitialMeasurement: false,
            rtt: rtt
        )
    }

    func testRTTOneSample() {
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(150),
            expectedBaseRTT: .microseconds(150),
            expectedLatestRTT: .microseconds(150),
            expectedAdjustedRTT: .microseconds(150),
            expectedSmoothedRTT: .microseconds(150),
            expectedVariance: .microseconds(75),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    func testRTTTwoSamples() {
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(150),
            expectedBaseRTT: .microseconds(150),
            expectedLatestRTT: .microseconds(150),
            expectedAdjustedRTT: .microseconds(150),
            expectedSmoothedRTT: .microseconds(150),
            expectedVariance: .microseconds(56),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    func testRTTMin() {
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.microseconds(200)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(100),
            expectedBaseRTT: .microseconds(100),
            expectedLatestRTT: .microseconds(100),
            expectedAdjustedRTT: .microseconds(100),
            expectedSmoothedRTT: .microseconds(144),
            expectedVariance: .microseconds(67),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    func testRTTLatest() {
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.microseconds(200)),
            ackDelay: .microseconds(10)
        )
        rtt.processNewSample(
            ackDuration: .microseconds(210),
            packetAckedTime: NetworkClock.Instant(.microseconds(310)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(100),
            expectedBaseRTT: .microseconds(100),
            expectedLatestRTT: .microseconds(210),
            expectedAdjustedRTT: .microseconds(200),
            expectedSmoothedRTT: .microseconds(151),
            expectedVariance: .microseconds(63),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
        rtt.processNewSample(
            ackDuration: .microseconds(110),
            packetAckedTime: NetworkClock.Instant(.microseconds(210)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(100),
            expectedBaseRTT: .microseconds(100),
            expectedLatestRTT: .microseconds(110),
            expectedAdjustedRTT: .microseconds(100),
            expectedSmoothedRTT: .microseconds(145),
            expectedVariance: .microseconds(59),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    func testRTTMaxDelay() {
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        rtt.remoteMaxAckDelay = .microseconds(1)
        rtt.processNewSample(
            ackDuration: .microseconds(200),
            packetAckedTime: NetworkClock.Instant(.microseconds(300)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(150),
            expectedBaseRTT: .microseconds(150),
            expectedLatestRTT: .microseconds(200),
            expectedAdjustedRTT: .microseconds(199),
            expectedSmoothedRTT: .microseconds(156),
            expectedVariance: .microseconds(67),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
        rtt.remoteMaxAckDelay = .microseconds(10)
        rtt.processNewSample(
            ackDuration: .microseconds(5),
            packetAckedTime: NetworkClock.Instant(.microseconds(105)),
            ackDelay: .microseconds(10)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(5),
            expectedBaseRTT: .microseconds(5),
            expectedLatestRTT: .microseconds(5),
            expectedAdjustedRTT: .microseconds(5),
            expectedSmoothedRTT: .microseconds(137),
            expectedVariance: .microseconds(83),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    func testRTTDelayOverflow() {
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        rtt.remoteMaxAckDelay = .seconds(UInt32.max)
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .seconds(UInt32.max) - .microseconds(5)
        )
        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(150),
            expectedBaseRTT: .microseconds(150),
            expectedLatestRTT: .microseconds(150),
            expectedAdjustedRTT: .microseconds(150),
            expectedSmoothedRTT: .microseconds(150),
            expectedVariance: .microseconds(56),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    func testRTTRemoteMaxAckDelay() {
        rtt.remoteMaxAckDelay = .microseconds(0)
        XCTAssertEqual(rtt.remoteMaxAckDelay, .microseconds(0))
        rtt.remoteMaxAckDelay = .seconds(UInt32.max)
        XCTAssertEqual(rtt.remoteMaxAckDelay, .seconds(UInt32.max))
        rtt.remoteMaxAckDelay = .microseconds(42)
        XCTAssertEqual(rtt.remoteMaxAckDelay, .microseconds(42))
        rtt.remoteMaxAckDelay = .microseconds(65536)
        XCTAssertEqual(rtt.remoteMaxAckDelay, .microseconds(65536))
    }

    func testRTTBase() {
        // First minute has lowest 40us
        rtt.processNewSample(
            ackDuration: .microseconds(150),
            packetAckedTime: NetworkClock.Instant(.microseconds(250)),
            ackDelay: .microseconds(10)
        )
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.seconds(25) + .microseconds(25)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(100),
            expectedBaseRTT: .microseconds(100),
            expectedLatestRTT: .microseconds(100),
            expectedAdjustedRTT: .microseconds(100),
            expectedSmoothedRTT: .microseconds(144),
            expectedVariance: .microseconds(67),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )

        rtt.processNewSample(
            ackDuration: .microseconds(40),
            packetAckedTime: NetworkClock.Instant(.seconds(50)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(40),
            expectedBaseRTT: .microseconds(40),
            expectedLatestRTT: .microseconds(40),
            expectedAdjustedRTT: .microseconds(40),
            expectedSmoothedRTT: .microseconds(131),
            expectedVariance: .microseconds(73),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )

        // Second minute has lowest 70us
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.seconds(70)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(40),
            expectedBaseRTT: .microseconds(40),
            expectedLatestRTT: .microseconds(100),
            expectedAdjustedRTT: .microseconds(90),
            expectedSmoothedRTT: .microseconds(126),
            expectedVariance: .microseconds(64),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )

        rtt.processNewSample(
            ackDuration: .microseconds(70),
            packetAckedTime: NetworkClock.Instant(.seconds(100)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(40),
            expectedBaseRTT: .microseconds(40),
            expectedLatestRTT: .microseconds(70),
            expectedAdjustedRTT: .microseconds(60),
            expectedSmoothedRTT: .microseconds(118),
            expectedVariance: .microseconds(63),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )

        // Third minute has lowest 50us
        rtt.processNewSample(
            ackDuration: .microseconds(50),
            packetAckedTime: NetworkClock.Instant(.seconds(150)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(40),
            expectedBaseRTT: .microseconds(40),
            expectedLatestRTT: .microseconds(50),
            expectedAdjustedRTT: .microseconds(40),
            expectedSmoothedRTT: .microseconds(108),
            expectedVariance: .microseconds(64),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )

        // 10 mins have passed, we should get rid of first minute.
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.seconds(660)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(40),
            expectedBaseRTT: .microseconds(90),
            expectedLatestRTT: .microseconds(100),
            expectedAdjustedRTT: .microseconds(90),
            expectedSmoothedRTT: .microseconds(106),
            expectedVariance: .microseconds(52),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }
}

#endif
