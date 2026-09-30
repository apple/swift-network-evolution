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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestSupport)
@_spi(Essentials) import SwiftNetworkTestSupport
#endif

/// Tests for `ManualScheduler`, which owns the clock a test advances explicitly.
@available(Network 0.1.0, *)
final class ManualSchedulerTests: NetTestCase {
    private let base = NetworkClock.Instant.testBase

    private func makeScheduler(nowAbsolute: NetworkClock.Instant? = nil) -> ManualScheduler {
        ManualScheduler(now: self.base, nowAbsolute: nowAbsolute)
    }

    // MARK: - Time

    /// Reading repeatedly must yield the same instant; otherwise a duration measured across a test
    /// depends on the real clock.
    func testTimeDoesNotMoveOnItsOwn() {
        let scheduler = self.makeScheduler()
        XCTAssertEqual(scheduler.now, self.base)
        XCTAssertEqual(scheduler.now, self.base)
    }

    func testAbsoluteDefaultsToContinuous() {
        XCTAssertEqual(self.makeScheduler().nowAbsolute, self.base)
    }

    func testContinuousAndAbsoluteAreSeparate() {
        let absolute = NetworkClock.Instant(milliseconds: 5000)
        let scheduler = self.makeScheduler(nowAbsolute: absolute)
        XCTAssertEqual(scheduler.now, self.base)
        XCTAssertEqual(scheduler.nowAbsolute, absolute)
    }

    func testAdvanceMovesBothClocks() {
        let absolute = NetworkClock.Instant(milliseconds: 5000)
        let scheduler = self.makeScheduler(nowAbsolute: absolute)
        scheduler.advanceTime(by: .milliseconds(250))
        XCTAssertEqual(scheduler.now, self.base.advanced(by: .milliseconds(250)))
        XCTAssertEqual(scheduler.nowAbsolute, absolute.advanced(by: .milliseconds(250)))
    }

    /// `Pacer` converts between the two domains using the offset between them, so a scheduler that
    /// let them drift would make `Pacer` compute a nonsense interval.
    func testAdvanceKeepsTheOffsetBetweenTheClocksFixed() {
        let absolute = NetworkClock.Instant(milliseconds: 5000)
        let scheduler = self.makeScheduler(nowAbsolute: absolute)
        let offsetBefore = scheduler.nowAbsolute.duration(to: scheduler.now)

        scheduler.advanceTime(by: .milliseconds(250))

        XCTAssertEqual(scheduler.nowAbsolute.duration(to: scheduler.now), offsetBefore)
    }

    func testAdvanceAccumulates() {
        let scheduler = self.makeScheduler()
        for _ in 0..<3 {
            scheduler.advanceTime(by: .milliseconds(100))
        }
        XCTAssertEqual(scheduler.now, self.base.advanced(by: .milliseconds(300)))
    }

    func testAdvanceByZeroLeavesTheClockAlone() {
        let scheduler = self.makeScheduler()
        scheduler.advanceTime(by: .zero)
        XCTAssertEqual(scheduler.now, self.base)
    }

    /// `System.Time.now()` truncates to microseconds, so nanosecond steps are only observable on a
    /// manual clock.
    func testNanosecondResolutionIsPreserved() {
        let scheduler = ManualScheduler(now: NetworkClock.Instant(nanoseconds: 1))
        scheduler.advanceTime(by: .nanoseconds(1))
        XCTAssertEqual(scheduler.now.time, .nanoseconds(2))
    }

    /// Elapsed time must be exact, with no dependency on how long the test itself took to run.
    func testDurationIsExactAcrossAdvances() {
        let scheduler = self.makeScheduler()
        let start = scheduler.now
        scheduler.advanceTime(by: .milliseconds(5))
        XCTAssertEqual(start.duration(to: scheduler.now), .milliseconds(5))
    }

    // MARK: - Timers

    /// Advancing the clock must fire a timer that comes due. Nothing in the stack polls the clock,
    /// so a timer only runs because the scheduler ran it.
    func testAdvanceFiresADueTimer() {
        let scheduler = self.makeScheduler()
        var fired = 0
        scheduler.schedule({ fired += 1 }, after: .milliseconds(100), reference: TimerReference())
        XCTAssertEqual(fired, 0)

        scheduler.advanceTime(by: .milliseconds(100))

        XCTAssertEqual(fired, 1)
    }

    /// `run()` must fire a timer whose deadline has already arrived. A zero-delay wakeup is
    /// reachable from production: `Timer.recalculate` clamps an overdue deadline to `.zero`. If
    /// `run()` skips it, the timer waits for an advance the test has no reason to make.
    func testRunFiresATimerThatIsAlreadyDue() {
        let scheduler = self.makeScheduler()
        var fired = 0
        scheduler.schedule({ fired += 1 }, after: .zero, reference: TimerReference())

        scheduler.run()

        XCTAssertEqual(fired, 1)
        XCTAssertEqual(scheduler.now, self.base, "firing a due timer must not invent virtual time")
    }

    func testATimerNotYetDueDoesNotFire() {
        let scheduler = self.makeScheduler()
        var fired = 0
        scheduler.schedule({ fired += 1 }, after: .milliseconds(100), reference: TimerReference())
        scheduler.advanceTime(by: .milliseconds(99))
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    /// A delay under a millisecond must keep its own deadline; otherwise it arrives as a zero
    /// delay. The wakeup has then already passed its deadline, so the handler recomputes the same
    /// delay and arms again forever.
    func testASubMillisecondDelayKeepsItsDeadline() {
        let scheduler = self.makeScheduler()
        var fired = 0
        scheduler.schedule({ fired += 1 }, after: .microseconds(625), reference: TimerReference())

        scheduler.advanceTime(by: .microseconds(624))
        XCTAssertEqual(fired, 0)

        scheduler.advanceTime(by: .microseconds(1))
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(scheduler.now, self.base.advanced(by: .microseconds(625)))
    }

    /// A timer must observe its own deadline, not the end of the advance; otherwise any duration it
    /// measures against `now` is wrong.
    func testATimerSeesTheTimeItWasScheduledFor() {
        let scheduler = self.makeScheduler()
        var observed: NetworkClock.Instant?
        scheduler.schedule({ observed = scheduler.now }, after: .milliseconds(100), reference: TimerReference())

        // Advance well past the deadline in one step.
        scheduler.advanceTime(by: .milliseconds(500))

        XCTAssertEqual(observed, self.base.advanced(by: .milliseconds(100)))
        XCTAssertEqual(scheduler.now, self.base.advanced(by: .milliseconds(500)))
    }

    func testTimersFireInDeadlineOrder() {
        let scheduler = self.makeScheduler()
        var order: [String] = []
        scheduler.schedule({ order.append("late") }, after: .milliseconds(200), reference: TimerReference())
        scheduler.schedule({ order.append("early") }, after: .milliseconds(50), reference: TimerReference())

        scheduler.advanceTime(by: .milliseconds(300))

        XCTAssertEqual(order, ["early", "late"])
    }

    /// Ordering must come from the order the timers were armed, not from however the scheduler
    /// happens to store them.
    func testTimersWithEqualDeadlinesFireInArmOrder() {
        let scheduler = self.makeScheduler()
        var order: [Int] = []
        // Same deadline for all three.
        for index in 0..<3 {
            scheduler.schedule(
                { order.append(index) },
                after: .milliseconds(100),
                reference: TimerReference()
            )
        }

        scheduler.advanceTime(by: .milliseconds(100))

        XCTAssertEqual(order, [0, 1, 2])
    }

    func testUnscheduleCancelsATimer() {
        let scheduler = self.makeScheduler()
        var fired = 0
        let reference = TimerReference()
        scheduler.schedule({ fired += 1 }, after: .milliseconds(100), reference: reference)
        scheduler.unschedule(reference: reference)

        scheduler.advanceTime(by: .milliseconds(500))

        XCTAssertEqual(fired, 0)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testAFiredTimerDoesNotFireTwice() {
        let scheduler = self.makeScheduler()
        var fired = 0
        scheduler.schedule({ fired += 1 }, after: .milliseconds(100), reference: TimerReference())
        scheduler.advanceTime(by: .milliseconds(100))
        scheduler.advanceTime(by: .milliseconds(100))
        XCTAssertEqual(fired, 1)
    }

    /// Rearming from inside a callback is what the QUIC timers do, so the advance has to keep
    /// draining rather than taking one pass.
    func testATimerScheduledByATimerAlsoFires() {
        let scheduler = self.makeScheduler()
        var inner = 0
        scheduler.schedule(
            { scheduler.schedule({ inner += 1 }, after: .milliseconds(50), reference: TimerReference()) },
            after: .milliseconds(100),
            reference: TimerReference()
        )

        scheduler.advanceTime(by: .milliseconds(300))

        XCTAssertEqual(inner, 1)
    }

    // MARK: - Immediate work

    /// `runImmediate` must queue rather than run inline; otherwise it re-enters the caller, which
    /// a serial dispatch queue never does.
    func testImmediateWorkIsQueuedNotRunInline() {
        let scheduler = self.makeScheduler()
        var ran = false
        scheduler.runImmediate { ran = true }
        XCTAssertFalse(ran)
        scheduler.run()
        XCTAssertTrue(ran)
    }

    // MARK: - Wiring into a context

    /// Everything downstream reads time through `context.scheduler`, so a context handed a manual
    /// scheduler must report that scheduler's time; otherwise controlling the scheduler here
    /// controls nothing.
    func testAContextUsesTheSuppliedScheduler() {
        let scheduler = self.makeScheduler()
        let context = NetworkContext(identifier: "manual", externalScheduler: scheduler)

        XCTAssertEqual(context.scheduler.now, self.base)

        scheduler.advanceTime(by: .seconds(1))

        XCTAssertEqual(context.scheduler.now, self.base.advanced(by: .seconds(1)))
    }

    /// A context given no scheduler must still read the real clock, which is what every existing
    /// test depends on.
    func testTheDefaultContextStillUsesTheRealClock() {
        let context = NetworkContext(identifier: "default")
        XCTAssertNotEqual(context.scheduler.now, .zero)
    }

    /// Work submitted before an advance belongs to the instant the caller is standing on, so it
    /// must run before a timer armed for later; otherwise a `runImmediate` is silently overtaken.
    func testQueuedWorkRunsBeforeATimerThatComesDueDuringTheAdvance() {
        let scheduler = self.makeScheduler()
        var order: [String] = []

        scheduler.schedule({ order.append("timer") }, after: .milliseconds(10), reference: TimerReference())
        scheduler.runImmediate { order.append("queued") }

        scheduler.advanceTime(by: .milliseconds(10))

        XCTAssertEqual(order, ["queued", "timer"])
    }

    /// A timer that rearms itself for the instant it just fired on must not spin the advance. The
    /// hold-back is what bounds it, so releasing the hold as the clock moves must not release this.
    func testASelfRearmingZeroDelayTimerDoesNotSpinTheAdvance() {
        let scheduler = self.makeScheduler()
        var fired = 0
        func rearm() {
            fired += 1
            if fired < 100_000 {
                scheduler.schedule({ rearm() }, after: .zero, reference: TimerReference())
            }
        }
        scheduler.schedule({ rearm() }, after: .zero, reference: TimerReference())

        scheduler.advanceTime(by: .milliseconds(1))

        XCTAssertLessThan(fired, 100_000, "a timer rearming itself for the same instant spun the advance")
    }

    /// A timer armed part-way through an advance, for an instant the clock has already reached, must
    /// fire once the clock moves past it. Holding it for the rest of the advance leaves it arbitrarily
    /// overdue -- here 990ms -- and a serial dispatch queue would have run it on the next turn.
    func testATimerArmedMidAdvanceFiresOnceTheClockHasMoved() {
        let scheduler = self.makeScheduler()
        var inner = 0
        // The outer timer fires 10ms in and arms a zero-delay one; the advance runs on to 1000ms.
        scheduler.schedule(
            { scheduler.schedule({ inner += 1 }, after: .zero, reference: TimerReference()) },
            after: .milliseconds(10),
            reference: TimerReference()
        )

        scheduler.advanceTime(by: .seconds(1))

        XCTAssertEqual(inner, 1, "a zero-delay timer armed mid-advance never fired")
    }

    /// A zero-delay timer armed by work that drains at the start of an advance must wait for the
    /// next advance. Firing it inside the advance that armed it is re-entrancy, which a serial
    /// dispatch queue never does.
    func testATimerArmedByTheOpeningDrainWaitsForTheNextAdvance() {
        let scheduler = self.makeScheduler()
        var fired = 0

        scheduler.runImmediate {
            scheduler.schedule({ fired += 1 }, after: .zero, reference: TimerReference())
        }

        scheduler.advanceTime(by: .milliseconds(10))
        XCTAssertEqual(fired, 0, "the timer fired inside the advance that armed it")

        scheduler.run()
        XCTAssertEqual(fired, 1, "the timer never fired on a later advance")
    }
}
