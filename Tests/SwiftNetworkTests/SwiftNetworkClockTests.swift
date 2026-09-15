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
        XCTAssertEqual(NetworkDuration.microseconds(3).description, "3.0 μs")
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
        XCTAssertEqual(NetworkDuration.microseconds(-3).description, "-3.0 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(-4).description, "-4 ns")
    }

    // Sub-microsecond remainders must survive, as they do for s and ms.
    func testDurationDescriptionFractionalMicroseconds() throws {
        XCTAssertEqual(NetworkDuration.nanoseconds(1500).description, "1.5 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(1010).description, "1.01 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(1999).description, "1.999 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(-1500).description, "-1.5 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(-1999).description, "-1.999 μs")
        XCTAssertEqual(NetworkDuration.nanoseconds(999).description, "999 ns")
        XCTAssertEqual(NetworkDuration.nanoseconds(-999).description, "-999 ns")
    }

    // A minute or more renders as whole coarse units, optionally with one whole
    // sub-unit.
    func testDurationDescriptionCoarseUnits() throws {
        XCTAssertEqual(NetworkDuration.seconds(60).description, "1 min")
        XCTAssertEqual(NetworkDuration.seconds(75).description, "1 min 15 s")
        XCTAssertEqual(NetworkDuration.minutes(1).description, "1 min")
        XCTAssertEqual(NetworkDuration.minutes(59).description, "59 min")
        XCTAssertEqual(NetworkDuration.minutes(60).description, "1 h")
        XCTAssertEqual(NetworkDuration.minutes(90).description, "1 h 30 min")
        XCTAssertEqual(NetworkDuration.minutes(120).description, "2 h")
        XCTAssertEqual(NetworkDuration.hours(2).description, "2 h")
        XCTAssertEqual(NetworkDuration.hours(23).description, "23 h")
        XCTAssertEqual(NetworkDuration.hours(24).description, "1 d")
        XCTAssertEqual(NetworkDuration.hours(26).description, "1 d 2 h")
        XCTAssertEqual(NetworkDuration.days(24).description, "24 d")
        // Just below a minute still uses the decimal seconds form.
        XCTAssertEqual(NetworkDuration.milliseconds(59_999).description, "59.999 s")
    }

    func testNegativeDurationDescriptionCoarseUnits() throws {
        XCTAssertEqual(NetworkDuration.seconds(-60).description, "-1 min")
        XCTAssertEqual(NetworkDuration.seconds(-75).description, "-1 min 15 s")
        XCTAssertEqual(NetworkDuration.minutes(-90).description, "-1 h 30 min")
        XCTAssertEqual(NetworkDuration.minutes(-120).description, "-2 h")
        XCTAssertEqual(NetworkDuration.hours(-26).description, "-1 d 2 h")
        XCTAssertEqual(NetworkDuration.days(-24).description, "-24 d")
    }

    func testDurationScalingByDouble() throws {
        let oneSecond = NetworkDuration.seconds(1)
        XCTAssertEqual(0.5 * oneSecond, .milliseconds(500))
        XCTAssertEqual(oneSecond * 0.5, .milliseconds(500))
        XCTAssertEqual(0.5 * oneSecond, oneSecond * 0.5)
        XCTAssertEqual(0.001 * oneSecond, .milliseconds(1))
        XCTAssertEqual(2.5 * oneSecond, .milliseconds(2500))
        XCTAssertEqual(2.5 * oneSecond, oneSecond * 2.5)
        XCTAssertEqual(-0.5 * oneSecond, .milliseconds(-500))
        XCTAssertEqual(0.0 * oneSecond, .zero)
    }

    func testDurationRatio() throws {
        let oneSecond = NetworkDuration.seconds(1)
        XCTAssertEqual(NetworkDuration.milliseconds(500) / oneSecond, 0.5, accuracy: 1e-9)
        XCTAssertEqual(NetworkDuration.milliseconds(1500) / oneSecond, 1.5, accuracy: 1e-9)
        XCTAssertEqual(oneSecond / oneSecond, 1.0, accuracy: 1e-9)
        XCTAssertEqual(NetworkDuration.microseconds(1) / oneSecond, 1e-6, accuracy: 1e-12)
        XCTAssertEqual(NetworkDuration.milliseconds(-500) / oneSecond, -0.5, accuracy: 1e-9)
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

    func testDurationCompoundAssignment() throws {
        var duration: NetworkDuration = .seconds(1)
        duration += .seconds(2)
        XCTAssertEqual(duration, .seconds(3))
        duration -= .seconds(1)
        XCTAssertEqual(duration, .seconds(2))
        duration -= .seconds(3)
        XCTAssertEqual(duration, .seconds(-1))
    }

    func testDurationRoundedMicrosecondsNegative() throws {
        XCTAssertEqual(NetworkDuration.nanoseconds(-1600).roundedMicroseconds, .microseconds(-2))
        XCTAssertEqual(NetworkDuration.nanoseconds(-1500).roundedMicroseconds, .microseconds(-2))
        XCTAssertEqual(NetworkDuration.nanoseconds(-1400).roundedMicroseconds, .microseconds(-1))
        XCTAssertEqual(NetworkDuration.nanoseconds(-500).roundedMicroseconds, .microseconds(-1))
        XCTAssertEqual(NetworkDuration.nanoseconds(-499).roundedMicroseconds, .zero)
        XCTAssertEqual(NetworkDuration.nanoseconds(500).roundedMicroseconds, .microseconds(1))
        XCTAssertEqual(NetworkDuration.nanoseconds(499).roundedMicroseconds, .zero)
        XCTAssertEqual(NetworkDuration.zero.roundedMicroseconds, .zero)
    }

    func testInstantDifferenceIsADuration() throws {
        let instant = NetworkClock.Instant(microseconds: 1000)
        let later = instant.advanced(by: .microseconds(200))

        let elapsed: NetworkDuration = later - instant
        XCTAssertEqual(elapsed, .microseconds(200))
        XCTAssertEqual(instant - later, .microseconds(-200))
        XCTAssertEqual(later - instant, instant.duration(to: later))
        XCTAssertEqual(instant - instant, .zero)
    }

    func testInstantDescriptionCapsAtSeconds() throws {
        XCTAssertEqual(NetworkClock.Instant(NetworkDuration.hours(2)).description, "7200.0 s")
        XCTAssertEqual(NetworkClock.Instant(NetworkDuration.days(1)).description, "86400.0 s")
        XCTAssertEqual(NetworkDuration.hours(2).description, "2 h")
        XCTAssertEqual(NetworkDuration.days(1).description, "1 d")
        XCTAssertEqual(NetworkClock.Instant(microseconds: 1500).description, "1.5 ms")
    }

    func testInstantInitializersAndConstants() throws {
        XCTAssertEqual(NetworkClock.Instant(milliseconds: 5).time, .milliseconds(5))
        XCTAssertEqual(NetworkClock.Instant(microseconds: 6).time, .microseconds(6))
        XCTAssertEqual(NetworkClock.Instant(nanoseconds: 7).time, .nanoseconds(7))
        XCTAssertEqual(NetworkClock.Instant(NetworkDuration.microseconds(9)).time, .microseconds(9))

        XCTAssertEqual(NetworkClock.Instant.zero.time, .zero)
        XCTAssertEqual(NetworkClock.Instant.maximum.time, .nanoseconds(Int64.max))
        XCTAssertTrue(NetworkClock.Instant.zero < NetworkClock.Instant(microseconds: 1))
        XCTAssertTrue(NetworkClock.Instant.maximum > NetworkClock.Instant(microseconds: 1))
    }

    func testInstantNowAbsoluteIsMonotonic() throws {
        let first = NetworkClock.Instant.systemNowAbsolute
        let second = NetworkClock.Instant.systemNowAbsolute
        XCTAssertNotEqual(first.time, .zero)
        XCTAssertTrue(second >= first)
    }

    func testDurationShiftsCurrentSemantics() throws {
        XCTAssertEqual(NetworkDuration.seconds(4) >> 1, .seconds(2))
        XCTAssertEqual(NetworkDuration.seconds(1) << 1, .seconds(2))

        // Arithmetic shift floors; division truncates toward zero.
        XCTAssertEqual(NetworkDuration.nanoseconds(-3) >> 1, .nanoseconds(-2))
        XCTAssertEqual(NetworkDuration.nanoseconds(-3) / 2, .nanoseconds(-1))

        // Overshifting left yields zero rather than trapping.
        XCTAssertEqual(NetworkDuration.seconds(1) << 64, .zero)
        // And an overflowing shift wraps into a negative duration.
        let overflowed: Int64 = (NetworkDuration.seconds(1) << 34).nanoseconds
        XCTAssertTrue(overflowed < Int64(0))
        // Overshifting right saturates a negative duration at -1 ns.
        XCTAssertEqual(NetworkDuration.seconds(-1) >> 64, .nanoseconds(-1))
    }

    func testRoundedUpMillisecondsRoundsAnyFractionUp() {
        XCTAssertEqual(NetworkDuration.microseconds(2187).roundedUpMilliseconds, 3)
        XCTAssertEqual(NetworkDuration.microseconds(3761).roundedUpMilliseconds, 4)
        XCTAssertEqual(NetworkDuration.microseconds(1).roundedUpMilliseconds, 1)
        XCTAssertEqual(NetworkDuration.microseconds(999).roundedUpMilliseconds, 1)
    }

    func testRoundedUpMillisecondsExactValuesAreUnchanged() {
        XCTAssertEqual(NetworkDuration.milliseconds(2).roundedUpMilliseconds, 2)
        XCTAssertEqual(NetworkDuration.milliseconds(210).roundedUpMilliseconds, 210)
        XCTAssertEqual(NetworkDuration.seconds(1).roundedUpMilliseconds, 1000)
    }

    func testRoundedUpMillisecondsClampsZeroAndNegative() {
        XCTAssertEqual(NetworkDuration.zero.roundedUpMilliseconds, 0)
        XCTAssertEqual(NetworkDuration.microseconds(-1).roundedUpMilliseconds, 0)
        XCTAssertEqual(NetworkDuration.seconds(-9).roundedUpMilliseconds, 0)
    }

    // Rounding up never returns less than truncation, and never more than one extra ms.
    func testRoundedUpMillisecondsNeverPrecedesDeadline() {
        for microseconds in stride(from: Int64(1), through: 5000, by: 37) {
            let duration = NetworkDuration.microseconds(microseconds)
            let roundedUp = duration.roundedUpMilliseconds
            XCTAssertGreaterThanOrEqual(roundedUp, duration.milliseconds)
            XCTAssertLessThanOrEqual(roundedUp, duration.milliseconds + 1)
            XCTAssertGreaterThanOrEqual(
                NetworkDuration.milliseconds(roundedUp).nanoseconds,
                duration.nanoseconds
            )
        }
    }
}
