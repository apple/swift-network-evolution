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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class VirtualTimeSchedulerTests: NetTestCase {

    func testImmediatesRunInOrderAndOnlyWhenDriven() {
        let scheduler = VirtualTimeScheduler()
        var log: [String] = []

        scheduler.runImmediate { log.append("first") }
        scheduler.runImmediate {
            log.append("second")
            // Queued while draining, so it must still run inside the same call.
            scheduler.runImmediate { log.append("nested") }
        }
        scheduler.runImmediate { log.append("third") }

        XCTAssertEqual(log, [], "nothing may run on the caller's stack")

        scheduler.runUntilIdle()

        XCTAssertEqual(log, ["first", "second", "third", "nested"])
    }

    func testTimersFireInDeadlineOrderAtTheirDeadline() {
        let scheduler = VirtualTimeScheduler()
        let start = scheduler.now
        var log: [(String, NetworkClock.Instant)] = []

        for (name, delay) in [("late", 30), ("early-a", 10), ("middle", 20), ("early-b", 10)] {
            scheduler.schedule({ log.append((name, scheduler.now)) }, after: .milliseconds(delay), reference: .init())
        }
        // A negative delay is due at once, so it comes before anything with a real delay.
        scheduler.schedule({ log.append(("negative", scheduler.now)) }, after: .milliseconds(-5), reference: .init())

        XCTAssertEqual(scheduler.nextDeadline, start)
        XCTAssertEqual(scheduler.pendingTimerCount, 5)

        scheduler.advance(by: .milliseconds(50))

        XCTAssertEqual(log.map(\.0), ["negative", "early-a", "early-b", "middle", "late"])
        XCTAssertEqual(
            log.map(\.1),
            [0, 10, 10, 20, 30].map { start.advanced(by: .milliseconds($0)) },
            "a task must see its own deadline as the present"
        )
        XCTAssertEqual(scheduler.now, start.advanced(by: .milliseconds(50)), "the clock ends at the target")
        XCTAssertEqual(scheduler.pendingTimerCount, 0)
        XCTAssertNil(scheduler.nextDeadline)
    }

    func testAdvanceFiresTimersArmedDuringTheAdvanceThatLandInsideTheWindow() {
        let scheduler = VirtualTimeScheduler()
        let start = scheduler.now
        var log: [String] = []

        scheduler.schedule(
            {
                log.append("first")
                scheduler.schedule({ log.append("inside") }, after: .milliseconds(10), reference: .init())
                scheduler.schedule({ log.append("beyond") }, after: .milliseconds(50), reference: .init())
            },
            after: .milliseconds(10),
            reference: .init()
        )

        scheduler.advance(by: .milliseconds(30))

        XCTAssertEqual(log, ["first", "inside"])
        XCTAssertEqual(scheduler.pendingTimerCount, 1)
        XCTAssertEqual(scheduler.nextDeadline, start.advanced(by: .milliseconds(60)))
        XCTAssertEqual(scheduler.now, start.advanced(by: .milliseconds(30)))

        XCTAssertTrue(scheduler.runUntilNextTimer())
        XCTAssertEqual(log, ["first", "inside", "beyond"])
        XCTAssertEqual(scheduler.now, start.advanced(by: .milliseconds(60)))
        XCTAssertFalse(scheduler.runUntilNextTimer(), "nothing is left to fire")
    }

    /// The library answers a timer by queueing work on the context, and that work has to be done before
    /// anything later fires. So an advance first runs what is already queued, and after each timer runs
    /// what that timer queued before it takes the next one.
    func testAdvanceRunsQueuedWorkBeforeEachTimer() {
        let scheduler = VirtualTimeScheduler()
        let start = scheduler.now
        var log: [(String, NetworkClock.Instant)] = []

        scheduler.runImmediate { log.append(("queued before the advance", scheduler.now)) }
        scheduler.schedule(
            {
                log.append(("first timer", scheduler.now))
                scheduler.runImmediate { log.append(("queued by the first timer", scheduler.now)) }
            },
            after: .milliseconds(10),
            reference: .init()
        )
        scheduler.schedule(
            { log.append(("second timer", scheduler.now)) },
            after: .milliseconds(20),
            reference: .init()
        )

        scheduler.advance(by: .milliseconds(30))

        XCTAssertEqual(
            log.map(\.0),
            ["queued before the advance", "first timer", "queued by the first timer", "second timer"]
        )
        XCTAssertEqual(log.map(\.1), [0, 10, 10, 20].map { start.advanced(by: .milliseconds($0)) })
    }

    func testRunUntilNextTimerRunsQueuedWorkOnBothSidesOfTheTimer() {
        let scheduler = VirtualTimeScheduler()
        var log: [String] = []

        // The timer does not exist until the queued task has run, so the queue has to drain first.
        scheduler.runImmediate {
            log.append("arms the timer")
            scheduler.schedule(
                {
                    log.append("timer")
                    scheduler.runImmediate { log.append("queued by the timer") }
                },
                after: .milliseconds(10),
                reference: .init()
            )
        }

        XCTAssertTrue(scheduler.runUntilNextTimer())
        XCTAssertEqual(log, ["arms the timer", "timer", "queued by the timer"])
    }

    func testUnscheduleStopsATimer() {
        let scheduler = VirtualTimeScheduler()
        let reference = TimerReference()
        var fired = false

        scheduler.schedule({ fired = true }, after: .milliseconds(10), reference: reference)
        scheduler.unschedule(reference: reference)
        XCTAssertEqual(scheduler.pendingTimerCount, 0)

        // A reference that owns nothing is left alone rather than trapped on.
        scheduler.unschedule(reference: TimerReference())

        scheduler.advance(by: .seconds(1))
        XCTAssertFalse(fired)
    }

    /// The library re-arms a timer by scheduling again under the reference it already holds, and the
    /// default scheduler honours only the latest request. This one must do the same or a re-armed idle
    /// timer would fire twice.
    func testSchedulingUnderTheSameReferenceReplacesTheEarlierTimer() {
        let scheduler = VirtualTimeScheduler()
        let reference = TimerReference()
        var log: [String] = []

        scheduler.schedule({ log.append("earlier") }, after: .milliseconds(10), reference: reference)
        scheduler.schedule({ log.append("later") }, after: .milliseconds(20), reference: reference)
        XCTAssertEqual(scheduler.pendingTimerCount, 1)

        scheduler.advance(by: .milliseconds(30))
        XCTAssertEqual(log, ["later"])
    }

    /// Re-arming and unscheduling find a timer by its reference among every other armed timer. After a long
    /// random run of both, the survivors must still fire in deadline order, ties in the order they were armed.
    func testRandomReArmsAndUnschedulesKeepDeadlineOrder() {
        let scheduler = VirtualTimeScheduler()
        let references = (0..<200).map { _ in TimerReference() }
        var expected: [Int: (delay: Int, order: Int)] = [:]
        var fired: [Int] = []
        // A fixed seed, so a failure reproduces.
        var state: UInt64 = 42
        func roll(_ bound: UInt64) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % bound)
        }

        for order in 0..<5000 {
            let index = roll(200)
            if roll(4) == 0 {
                scheduler.unschedule(reference: references[index])
                expected[index] = nil
            } else {
                // Few distinct delays, so most timers tie with others.
                let delay = roll(25)
                scheduler.schedule({ fired.append(index) }, after: .milliseconds(delay), reference: references[index])
                expected[index] = (delay, order)
            }
        }

        XCTAssertEqual(scheduler.pendingTimerCount, expected.count)
        scheduler.advance(by: .milliseconds(25))

        let expectedOrder =
            expected
            .sorted { ($0.value.delay, $0.value.order) < ($1.value.delay, $1.value.order) }
            .map(\.key)
        XCTAssertEqual(fired, expectedOrder)
        XCTAssertEqual(scheduler.pendingTimerCount, 0)
    }

    func testRunningInSchedulerIsTrueOnlyInsideTasks() {
        let scheduler = VirtualTimeScheduler()
        var seen: [Bool] = []

        XCTAssertFalse(scheduler.runningInScheduler)

        scheduler.runImmediate { seen.append(scheduler.runningInScheduler) }
        scheduler.runUntilIdle()
        XCTAssertFalse(scheduler.runningInScheduler)

        scheduler.schedule({ seen.append(scheduler.runningInScheduler) }, after: .milliseconds(1), reference: .init())
        scheduler.advance(by: .milliseconds(1))
        XCTAssertFalse(scheduler.runningInScheduler)

        XCTAssertEqual(seen, [true, true])
    }

    func testStallGuardTripsOnATaskThatRequeuesItselfWithoutEnd() {
        let scheduler = VirtualTimeScheduler(stepLimit: 50)
        var tripped: [Int] = []
        scheduler.stallHandler = { tripped.append($0) }
        var runs = 0

        func requeue() {
            runs += 1
            scheduler.runImmediate(requeue)
        }
        scheduler.runImmediate(requeue)

        scheduler.runUntilIdle()

        XCTAssertEqual(tripped, [50], "the guard names its limit and trips once per driver call")
        XCTAssertEqual(runs, 50, "the driver call stops at the limit")
        XCTAssertFalse(scheduler.runningInScheduler, "a tripped call still ends cleanly")

        // The next driver call starts a fresh count, so the loop is caught again rather than let through.
        scheduler.runUntilIdle()
        XCTAssertEqual(tripped, [50, 50])
        XCTAssertEqual(runs, 100)
    }

    /// The guard is for work that does not end. A call that runs exactly the limit and then has nothing
    /// left is finished, so it must not be reported as stalled.
    func testStallGuardLeavesACallThatEndsAtTheLimitAlone() {
        let scheduler = VirtualTimeScheduler(stepLimit: 50)
        var tripped = false
        scheduler.stallHandler = { _ in tripped = true }
        var runs = 0

        for _ in 0..<25 {
            scheduler.runImmediate { runs += 1 }
            scheduler.schedule({ runs += 1 }, after: .milliseconds(1), reference: .init())
        }
        scheduler.advance(by: .milliseconds(1))

        XCTAssertEqual(runs, 50)
        XCTAssertFalse(tripped)
    }

    /// `DefaultScheduler` clamps a delay too long to represent instead of trapping on it, so code that
    /// arms such a timer must behave the same here: the timer is held and never comes due.
    func testADelayBeyondTheClockIsHeldAndNeverComesDue() {
        let scheduler = VirtualTimeScheduler()
        var fired = false

        scheduler.schedule({ fired = true }, after: .nanoseconds(Int64.max), reference: .init())
        XCTAssertEqual(scheduler.nextDeadline, .maximum)

        scheduler.advance(by: .days(365))
        XCTAssertFalse(fired)
        XCTAssertEqual(scheduler.pendingTimerCount, 1)
    }

    func testStallGuardCountsTimersAcrossAnAdvance() {
        let scheduler = VirtualTimeScheduler(stepLimit: 20)
        var tripped: [Int] = []
        scheduler.stallHandler = { tripped.append($0) }
        let start = scheduler.now
        let reference = TimerReference()
        var runs = 0

        func rearm() {
            runs += 1
            scheduler.schedule(rearm, after: .milliseconds(1), reference: reference)
        }
        scheduler.schedule(rearm, after: .milliseconds(1), reference: reference)

        scheduler.advance(by: .seconds(1))

        XCTAssertEqual(tripped, [20])
        XCTAssertEqual(runs, 20)
        XCTAssertEqual(scheduler.now, start.advanced(by: .milliseconds(20)), "the clock stops where the guard tripped")
        XCTAssertEqual(scheduler.nextDeadline, start.advanced(by: .milliseconds(21)), "the re-armed timer is kept")
    }

    func testBothClocksAdvanceTogetherAndStayApart() {
        let scheduler = VirtualTimeScheduler()

        let offsetBefore = scheduler.now.duration(to: scheduler.nowAbsolute)
        XCTAssertEqual(offsetBefore, VirtualTimeScheduler.absoluteOffset)
        XCTAssertNotEqual(offsetBefore, .zero, "a context that confuses the clocks must not match by coincidence")

        scheduler.advance(by: .seconds(2))

        XCTAssertEqual(scheduler.now.duration(to: scheduler.nowAbsolute), offsetBefore)
    }

    /// The end-to-end case: a context timer armed from inside a context task fires at its virtual
    /// deadline without the test waiting for it, and the context's own assertion passes on the way.
    func testContextTimerFiresAtTheVirtualDeadlineWithoutRealDelay() {
        let scheduler = VirtualTimeScheduler()
        let context = NetworkContext(identifier: "test", externalScheduler: scheduler)
        let start = context.now
        var firedAt: NetworkClock.Instant?
        var cancelledFired = false

        context.async {
            // `assert()` is what every protocol path checks before touching context state; it has to
            // hold inside a task the scheduler runs.
            context.assert()
            XCTAssertTrue(context.runningInContext)

            _ = context.scheduleTimer(duration: .milliseconds(250)) {
                context.assert()
                firedAt = context.now
            }
            let cancelled = context.scheduleTimer(duration: .milliseconds(100)) {
                cancelledFired = true
            }
            context.unscheduleTimer(cancelled)
        }

        XCTAssertEqual(scheduler.pendingTimerCount, 0, "nothing is armed until the task has run")
        scheduler.runUntilIdle()
        XCTAssertEqual(scheduler.pendingTimerCount, 1)
        XCTAssertNil(firedAt)

        let clock = ContinuousClock()
        let began = clock.now
        scheduler.advance(by: .seconds(10))
        let elapsed = began.duration(to: clock.now)

        XCTAssertEqual(firedAt, start.advanced(by: .milliseconds(250)))
        XCTAssertFalse(cancelledFired)
        XCTAssertEqual(context.now, start.advanced(by: .seconds(10)))
        XCTAssertEqual(context.nowAbsolute, scheduler.nowAbsolute)
        // Ten virtual seconds must not cost anything like ten real ones; the bound is loose on purpose
        // so a slow CI machine cannot fail it.
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}
