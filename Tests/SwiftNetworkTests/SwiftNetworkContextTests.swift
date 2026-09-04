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
