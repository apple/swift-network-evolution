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
final class SwiftNetworkContextTests: NetTestCase {

    func testContextAsync() {

        let context = NetworkContext(identifier: "test")

        let expectation = XCTestExpectation()

        context.async {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testContextTimer() {

        let context = NetworkContext(identifier: "test")

        let expectation = XCTestExpectation()

        let timerReference = TimerReference()

        context.resetTimer(
            for: timerReference,
            to: .after(.milliseconds(2000)) {
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 5.0)
    }

    func testContextTimerConvenience() {
        let context = NetworkContext(identifier: "test")

        let expectation = XCTestExpectation()

        let timerReference = context.scheduleTimer(duration: .seconds(2)) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
        context.unscheduleTimer(timerReference)
    }

    func testContextTimerMultipleTimers() {
        let context = NetworkContext(identifier: "test")

        let expectation = XCTestExpectation()

        let timerReference1 = context.scheduleTimer(duration: .seconds(2)) {
            expectation.fulfill()
        }

        let timerReference2 = context.scheduleTimer(duration: .seconds(1)) {
            // Do nothing
        }

        XCTAssertNotEqual(timerReference1, timerReference2)

        context.unscheduleTimer(timerReference2)

        wait(for: [expectation], timeout: 5.0)
        context.unscheduleTimer(timerReference1)
    }

    /// A delay under a millisecond must reach the scheduler intact; otherwise it arrives as no
    /// delay at all and the wakeup cannot reach the deadline it was armed for.
    func testContextTimerKeepsASubMillisecondDelay() {
        let scheduler = RecordingScheduler()
        let context = NetworkContext(identifier: "test", externalScheduler: scheduler)

        let timerReference = context.scheduleTimer(duration: .microseconds(625)) {
            XCTFail("The recording scheduler arms nothing, so the task must not run")
        }

        XCTAssertEqual(scheduler.scheduledDelays, [.microseconds(625)])

        context.unscheduleTimer(timerReference)
        XCTAssertEqual(scheduler.unscheduledReferences, [timerReference])
    }

    /// The context must report the external scheduler's time, not the system's.
    func testContextReportsTheExternalSchedulersTime() {
        let scheduler = AdvancingScheduler()
        let context = NetworkContext(identifier: "test", externalScheduler: scheduler)

        XCTAssertEqual(context.now, scheduler.now)
        XCTAssertEqual(context.nowAbsolute, scheduler.nowAbsolute)

        let start = context.now
        scheduler.advance(by: .milliseconds(250))

        XCTAssertEqual(context.now, start.advanced(by: .milliseconds(250)))
    }

    func testLongAdvanceDurationIsHonored() {
        let scheduler = AdvancingScheduler()
        let context = NetworkContext(identifier: "test", externalScheduler: scheduler)

        let start = context.now
        scheduler.advance(by: .days(5))

        XCTAssertEqual(start.duration(to: context.now), .days(5))
    }

    func testShortAdvanceIsExact() {
        let scheduler = AdvancingScheduler()
        let context = NetworkContext(identifier: "test", externalScheduler: scheduler)

        let start = context.now
        // `System.Time.now()` divides down to microseconds,
        // so a 500 ns advance is a duration it cannot represent at all
        scheduler.advance(by: .nanoseconds(500))

        XCTAssertEqual(start.duration(to: context.now), .nanoseconds(500))
    }

    func testBothClocksAdvanceTogether() {
        let scheduler = AdvancingScheduler()
        let context = NetworkContext(identifier: "test", externalScheduler: scheduler)

        let offsetBefore = context.now.duration(to: context.nowAbsolute)
        scheduler.advance(by: .seconds(2))
        let offsetAfter = context.now.duration(to: context.nowAbsolute)

        XCTAssertEqual(
            offsetAfter,
            offsetBefore,
            "the clocks drifted by \(offsetAfter.nanoseconds - offsetBefore.nanoseconds) ns"
        )
    }

    /// A scheduler whose clock a test moves by hand.
    /// **NOTE:** Arms nothing: the tests that use it assert on the time the context reports, not on anything firing.
    private final class AdvancingScheduler: NetworkContext.Scheduler {
        /// The two clocks start apart, so a context that reports one in place of the other fails
        /// the equality check instead of matching by coincidence.
        private(set) var now = NetworkClock.Instant(milliseconds: 1000)
        private(set) var nowAbsolute = NetworkClock.Instant(milliseconds: 5000)

        func advance(by duration: NetworkDuration) {
            now = now.advanced(by: duration)
            nowAbsolute = nowAbsolute.advanced(by: duration)
        }

        func runImmediate(_ task: @escaping (() -> Void)) {
            task()
        }

        func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
        }

        func unschedule(reference: TimerReference) {
        }

        var runningInScheduler: Bool { true }
    }

    /// Records what it was asked to schedule instead of arming anything, so a test can assert on
    /// the delay a caller asked for rather than on time passing.
    private final class RecordingScheduler: NetworkContext.Scheduler {
        var scheduledDelays: [NetworkDuration] = []
        var unscheduledReferences: [TimerReference] = []

        func runImmediate(_ task: @escaping (() -> Void)) {
            task()
        }

        func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
            scheduledDelays.append(delay)
        }

        func unschedule(reference: TimerReference) {
            unscheduledReferences.append(reference)
        }

        var runningInScheduler: Bool { true }

        /// A fixed instant. Nothing here fires on a deadline, so no assertion depends on the time
        /// this scheduler reports.
        var now: NetworkClock.Instant { NetworkClock.Instant(milliseconds: 1000) }
        var nowAbsolute: NetworkClock.Instant { now }
    }

    func testContextTimerReferences() {
        // Ensure timer references are unique
        let timerReference1 = TimerReference()
        let timerReference2 = TimerReference()
        let timerReference3 = TimerReference()

        XCTAssertNotEqual(timerReference1, timerReference2)
        XCTAssertNotEqual(timerReference2, timerReference3)
        XCTAssertNotEqual(timerReference3, timerReference1)
    }
}
