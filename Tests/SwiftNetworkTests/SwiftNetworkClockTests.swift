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
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

@available(Network 0.1.0, *)
final class SwiftNetworkClockTests: NetTestCase {

    func testSize() throws {
        XCTAssertEqual(MemoryLayout<NetworkDuration>.size, 8)
        XCTAssertEqual(MemoryLayout<NetworkDuration>.stride, 8)
        XCTAssertEqual(MemoryLayout<NetworkClock>.size, 0)
        XCTAssertEqual(MemoryLayout<NetworkClock.Instant>.size, 8)
        XCTAssertEqual(MemoryLayout<NetworkClock.Instant>.stride, 8)
    }

    func testDurationZero() throws {
        XCTAssertEqual(NetworkDuration.zero, .seconds(0))
    }

    func testDurationArithmetic() throws {
        let oneSecond: NetworkDuration = .seconds(1)
        let twoSeconds: NetworkDuration = .seconds(2)
        let fourSeconds: NetworkDuration = .seconds(4)

        XCTAssertEqual(oneSecond + oneSecond, .seconds(2))
        XCTAssertEqual(oneSecond + twoSeconds, .seconds(3))
        XCTAssertEqual(twoSeconds + oneSecond, .seconds(3))
        XCTAssertEqual(twoSeconds - oneSecond, .seconds(1))
        XCTAssertEqual(fourSeconds - twoSeconds, .seconds(2))
        XCTAssertEqual(fourSeconds / 2, .seconds(2))
        XCTAssertEqual(fourSeconds * 2, .seconds(8))
    }

    func testDurationLogic() throws {
        let oneSecond: NetworkDuration = .seconds(1)
        let twoSeconds: NetworkDuration = .seconds(2)
        let fourSeconds: NetworkDuration = .seconds(4)

        XCTAssertTrue(oneSecond < twoSeconds)
        XCTAssertTrue(twoSeconds > oneSecond)
        XCTAssertTrue(twoSeconds < fourSeconds)
        XCTAssertTrue(fourSeconds > twoSeconds)
        XCTAssertTrue(oneSecond <= twoSeconds)
        XCTAssertTrue(twoSeconds >= oneSecond)
        XCTAssertTrue(twoSeconds <= fourSeconds)
        XCTAssertTrue(fourSeconds >= twoSeconds)
        XCTAssertFalse(oneSecond >= twoSeconds)
        XCTAssertFalse(twoSeconds <= oneSecond)
        XCTAssertFalse(twoSeconds >= fourSeconds)
        XCTAssertFalse(twoSeconds >= fourSeconds)
        XCTAssertTrue(oneSecond == oneSecond)
        XCTAssertFalse(twoSeconds == fourSeconds)
    }

    func testDurationStaticInitializers() throws {
        let oneMillisecond: NetworkDuration = .milliseconds(1)
        let oneFiveMillisecond: NetworkDuration = .milliseconds(1.5)
        let twoMicroseconds: NetworkDuration = .microseconds(2)
        let threeNanoseconds: NetworkDuration = .nanoseconds(3)

        XCTAssertEqual(oneMillisecond.milliseconds, 1)
        XCTAssertEqual(oneMillisecond.microseconds, 1000)
        XCTAssertEqual(oneFiveMillisecond.microseconds, 1500)
        XCTAssertEqual(twoMicroseconds.microseconds, 2)
        XCTAssertEqual(threeNanoseconds.microseconds, 0)
    }

    func testDurationDescription() throws {
        XCTAssertEqual(NetworkDuration.seconds(1).description, "1.0 s")
        XCTAssertEqual(NetworkDuration.milliseconds(1500).description, "1.5 s")
        XCTAssertEqual(NetworkDuration.milliseconds(1010).description, "1.01 s")
        XCTAssertEqual(NetworkDuration.milliseconds(4002).description, "4.002 s")
        XCTAssertEqual(NetworkDuration.milliseconds(12020).description, "12.02 s")
        XCTAssertEqual(NetworkDuration.milliseconds(12021).description, "12.021 s")
        XCTAssertEqual(NetworkDuration.milliseconds(1776).description, "1.776 s")
        XCTAssertEqual(NetworkDuration.milliseconds(2).description, "2.0 ms")
        XCTAssertEqual(NetworkDuration.microseconds(2020).description, "2.02 ms")
        XCTAssertEqual(NetworkDuration.microseconds(3).description, "3 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(4).description, "4 ns")
    }

    func testNegativeDurationDescription() throws {
        XCTAssertEqual(NetworkDuration.seconds(-1).description, "-1.0 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-1500).description, "-1.5 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-1010).description, "-1.01 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-4002).description, "-4.002 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-12020).description, "-12.02 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-12021).description, "-12.021 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-1776).description, "-1.776 s")
        XCTAssertEqual(NetworkDuration.milliseconds(-2).description, "-2.0 ms")
        XCTAssertEqual(NetworkDuration.microseconds(-2020).description, "-2.02 ms")
        XCTAssertEqual(NetworkDuration.microseconds(-3).description, "-3 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(-4).description, "-4 ns")
    }

    func testDurationRoundedMicroseconds() throws {
        let oneFiveMicroseconds: NetworkDuration = .microseconds(1.5)
        let oneFourMicroseconds: NetworkDuration = .microseconds(1.4)

        XCTAssertEqual(oneFiveMicroseconds.roundedMicroseconds, .microseconds(2))
        XCTAssertEqual(oneFourMicroseconds.roundedMicroseconds, .microseconds(1))
    }

    func testClockMinimumResolution() throws {
        let clock = NetworkClock()
        XCTAssertEqual(clock.minimumResolution, .nanoseconds(1))
    }

    func testInstantNow() throws {
        let clock = NetworkClock()
        XCTAssertNotEqual(clock.now.time, .nanoseconds(0))
    }

    func testInstantAdvanced() throws {
        let instant = NetworkClock.Instant(microseconds: 1000)
        let instantPlus200 = instant.advanced(by: .microseconds(200))
        XCTAssertEqual(instant.time, .microseconds(1000))
        XCTAssertEqual(instantPlus200.time, .microseconds(1200))
    }

    func testInstantDuration() throws {
        let instant = NetworkClock.Instant(microseconds: 1000)
        let instantPlus200 = instant.advanced(by: .microseconds(200))
        XCTAssertEqual(instant.duration(to: instantPlus200), .microseconds(200))
    }

    func testInstantArithmetic() throws {
        let instant = NetworkClock.Instant(microseconds: 1000)
        let instantPlus200 = instant.advanced(by: .microseconds(200))
        let instantMinus200 = instant.advanced(by: .microseconds(-200))

        XCTAssertEqual(instant + .microseconds(200), instantPlus200)
        XCTAssertEqual(instant - .microseconds(200), instantMinus200)
    }

    func testInstantLogic() throws {
        let instant = NetworkClock.Instant(microseconds: 1000)
        let instantPlus200 = instant.advanced(by: .microseconds(200))
        let instantMinus200 = instant.advanced(by: .microseconds(-200))

        XCTAssertTrue(instant == instant)
        XCTAssertTrue(instant < instantPlus200)
        XCTAssertTrue(instant <= instantPlus200)
        XCTAssertTrue(instant > instantMinus200)
        XCTAssertTrue(instant >= instantMinus200)
    }

}

#if !NETWORK_INTERNAL_TESTS
private struct ManualClockUnavailable: LocalizedError, CustomStringConvertible {
    var description: String {
        "the manual clock is not compiled in; build with -Xswiftc -DNETWORK_INTERNAL_TESTS"
    }
    var errorDescription: String? { self.description }
}
#endif

/// Tests for the manually advanced clock behind `NetworkClock.Instant.now`.
@available(Network 0.1.0, *)
final class SwiftNetworkManualClockTests: NetTestCase {
    private let base = NetworkClock.Instant(milliseconds: 1000)

    override func setUpWithError() throws {
        #if !NETWORK_INTERNAL_TESTS
        throw ManualClockUnavailable()
        #endif
    }

    override func tearDown() {
        NetworkClock.Instant.useSystemTime()
    }

    func testSystemClockIsUsedByDefault() {
        let first = NetworkClock.Instant.now
        XCTAssertNotEqual(first, .zero)
        usleep(1)
        let second = NetworkClock.Instant.now
        XCTAssertGreaterThan(second, first)
    }

    func testUseManualTimeFreezesTheClock() {
        NetworkClock.Instant.useManualTime(base)
        XCTAssertEqual(NetworkClock.Instant.now, base)
        // Reading repeatedly must yield the same instant: time no longer moves
        // on its own, which is the entire point of the manual clock.
        usleep(1)
        XCTAssertEqual(NetworkClock.Instant.now, base)
        XCTAssertEqual(NetworkClock.Instant.now, NetworkClock.Instant.now)
    }

    func testUseManualTimeDefaultsAbsoluteToContinuous() {
        NetworkClock.Instant.useManualTime(base)
        XCTAssertEqual(NetworkClock.Instant.nowAbsolute, base)
    }

    func testUseManualTimeKeepsContinuousAndAbsoluteSeparate() {
        let absolute = NetworkClock.Instant(milliseconds: 5000)
        NetworkClock.Instant.useManualTime(base, absolute: absolute)
        XCTAssertEqual(NetworkClock.Instant.now, base)
        XCTAssertEqual(NetworkClock.Instant.nowAbsolute, absolute)
    }

    func testUseManualTimeOverwritesAPreviousManualTime() {
        NetworkClock.Instant.useManualTime(base, absolute: NetworkClock.Instant(milliseconds: 5000))
        let later = NetworkClock.Instant(milliseconds: 2000)
        NetworkClock.Instant.useManualTime(later)
        XCTAssertEqual(NetworkClock.Instant.now, later)
        XCTAssertEqual(NetworkClock.Instant.nowAbsolute, later)
    }

    func testAdvanceManualTimeMovesBothClocks() {
        let absolute = NetworkClock.Instant(milliseconds: 5000)
        NetworkClock.Instant.useManualTime(base, absolute: absolute)
        NetworkClock.Instant.advanceManualTime(by: .milliseconds(250))
        XCTAssertEqual(NetworkClock.Instant.now, base.advanced(by: .milliseconds(250)))
        XCTAssertEqual(NetworkClock.Instant.nowAbsolute, absolute.advanced(by: .milliseconds(250)))
    }

    func testAdvanceManualTimeAccumulates() {
        NetworkClock.Instant.useManualTime(base)
        for _ in 0..<3 {
            NetworkClock.Instant.advanceManualTime(by: .milliseconds(100))
        }
        XCTAssertEqual(NetworkClock.Instant.now, base.advanced(by: .milliseconds(300)))
    }

    func testAdvanceManualTimeByZeroLeavesTheClockAlone() {
        NetworkClock.Instant.useManualTime(base)
        NetworkClock.Instant.advanceManualTime(by: .zero)
        XCTAssertEqual(NetworkClock.Instant.now, base)
    }

    func testAdvanceManualTimeKeepsNanosecondResolution() {
        // `System.Time.now()` truncates to microseconds, so nanosecond steps are
        // only observable on the manual clock.
        NetworkClock.Instant.useManualTime(NetworkClock.Instant(nanoseconds: 1))
        NetworkClock.Instant.advanceManualTime(by: .nanoseconds(1))
        XCTAssertEqual(NetworkClock.Instant.now.time, .nanoseconds(2))
    }

    func testDurationIsMeasuredAcrossManualAdvances() {
        NetworkClock.Instant.useManualTime(base)
        let start = NetworkClock.Instant.now

        NetworkClock.Instant.advanceManualTime(by: .milliseconds(5))

        // The reason the manual clock exists: an exact, reproducible elapsed
        // time with no dependency on how long the test itself took to run.
        XCTAssertEqual(start.duration(to: NetworkClock.Instant.now), .milliseconds(5))
    }

    func testUseSystemTimeRestoresTheSystemClock() {
        NetworkClock.Instant.useManualTime(base)
        XCTAssertEqual(NetworkClock.Instant.now, base)

        NetworkClock.Instant.useSystemTime()

        // `System.Time.now()` reports microseconds since boot, so the restored
        // clock cannot still read the 1 s manual value, and it must keep moving.
        let restored = NetworkClock.Instant.now
        XCTAssertNotEqual(restored, base)
        usleep(1)
        let next = NetworkClock.Instant.now
        XCTAssertGreaterThan(next, restored)
    }

}
