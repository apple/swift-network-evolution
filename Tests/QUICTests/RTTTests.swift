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

        // 10 mins have passed, we should get rid of first minute. The third
        // minute's 40us (adjusted) sample is only 510s old, so it is retained.
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.seconds(660)),
            ackDelay: .microseconds(10)
        )

        verifyRTTMeasurements(
            expectedMinRTT: .microseconds(40),
            expectedBaseRTT: .microseconds(40),
            expectedLatestRTT: .microseconds(100),
            expectedAdjustedRTT: .microseconds(90),
            expectedSmoothedRTT: .microseconds(106),
            expectedVariance: .microseconds(52),
            expectedHasInitialMeasurement: true,
            rtt: rtt
        )
    }

    // Verifies that the rollover timestamp advances on every minute rollover.
    // If it doesn't, every sample taken more than one history interval after the
    // first sample is treated as a new rollover, which advances the base RTT
    // index on each sample and prematurely evicts older minimums.
    func testRTTBaseRolloverTimestampAdvances() {
        // Minute 0: lowest base RTT is 40us.
        rtt.processNewSample(
            ackDuration: .microseconds(40),
            packetAckedTime: NetworkClock.Instant(.seconds(0)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(40))

        // Minute 1: a single rollover, followed by more samples within the same
        // minute. There are enough samples to wrap the whole history if each
        // one were wrongly treated as a rollover.
        for i in 0..<(RTT.nbaseHistory + 1) {
            rtt.processNewSample(
                ackDuration: .microseconds(100),
                packetAckedTime: NetworkClock.Instant(.seconds(61) + .milliseconds(Double(i) * 100)),
                ackDelay: .microseconds(0)
            )
            // The minute 0 minimum must still be within the history window.
            XCTAssertEqual(rtt.baseRTT, .microseconds(40), "sample \(i)")
        }

        // Nine intervals after the minute 1 rollover, the history wraps around:
        // the minute 0 minimum is evicted, and the base RTT becomes the minimum
        // of the remaining minutes.
        rtt.processNewSample(
            ackDuration: .microseconds(90),
            packetAckedTime: NetworkClock.Instant(.seconds(602)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(90))
        XCTAssertEqual(rtt.minRTT, .microseconds(40))
    }

    // Verifies that interval boundaries stay aligned to fixed steps from the
    // first sample when samples are sparse and irregularly spaced. If the
    // rollover timestamp were moved to the arrival time of each sample, the
    // fractional part of each gap would be lost, elapsed intervals would be
    // undercounted, and old minimums would stay in the window for more than
    // `nbaseHistory` intervals.
    func testRTTBaseRolloverIrregularSpacing() {
        // Interval 0 [0s, 60s): 40us.
        rtt.processNewSample(
            ackDuration: .microseconds(40),
            packetAckedTime: NetworkClock.Instant(.seconds(0)),
            ackDelay: .microseconds(0)
        )
        // Interval 1 [60s, 120s): 80us.
        rtt.processNewSample(
            ackDuration: .microseconds(80),
            packetAckedTime: NetworkClock.Instant(.seconds(119)),
            ackDelay: .microseconds(0)
        )
        // Interval 3 [180s, 240s): 90us. Three full intervals have elapsed
        // since t=0, even though only 62s have elapsed since the last sample.
        rtt.processNewSample(
            ackDuration: .microseconds(90),
            packetAckedTime: NetworkClock.Instant(.seconds(181)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(40))

        // Interval 9 [540s, 600s): the interval 0 minimum is still in the window.
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.seconds(599)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(40))

        // Interval 10 [600s, 660s): 10 intervals have elapsed, so interval 0's
        // slot is reused and its 40us minimum is evicted. The base RTT becomes
        // the minimum of intervals 1, 3, 9 and 10.
        rtt.processNewSample(
            ackDuration: .microseconds(120),
            packetAckedTime: NetworkClock.Instant(.seconds(605)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(80))
        XCTAssertEqual(rtt.minRTT, .microseconds(40))
    }

    // Verifies that a long idle period (much longer than the history window)
    // invalidates every slot, including the one that was current before the
    // idle period, even when the new sample lands on a different slot.
    func testRTTBaseRolloverLongIdle() {
        // Interval 0, slot 0: 40us.
        rtt.processNewSample(
            ackDuration: .microseconds(40),
            packetAckedTime: NetworkClock.Instant(.seconds(0)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(40))

        // About a day later: 1443 intervals have elapsed, so the new sample
        // lands on slot 3. The slot 0 minimum is long out of the window and
        // must not survive.
        rtt.processNewSample(
            ackDuration: .microseconds(100),
            packetAckedTime: NetworkClock.Instant(.seconds(1443 * 60 + 1)),
            ackDelay: .microseconds(0)
        )
        XCTAssertEqual(rtt.baseRTT, .microseconds(100))
        XCTAssertEqual(rtt.minRTT, .microseconds(40))
    }
}

#endif
