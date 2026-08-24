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
@available(Network 0.1.0, *)
typealias QUICTimer = SwiftNetwork.Timer
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
typealias QUICTimer = Network.Timer
#endif

@available(Network 0.1.0, *)
let timerTestsLogPrefixer = LogPrefixer("[TimerTests]")

@available(Network 0.1.0, *)
final class TimerTests: XCTestCase {

    func testOneTimer() {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(1000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(1)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
    }

    func testReschedule() {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one-reschedule", timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .zero)
        timer.reschedule(identifier: oneId, fromNow: .milliseconds(1000), timerNow: .zero)
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(1)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
    }

    func testTwoTimersAtSameTime() throws {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(1000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        let twoId = timer.insert(description: "two", fromNow: .milliseconds(1000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    func testTwoTimersAtDifferentTimes() throws {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(2000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 2000))
        let twoId = timer.insert(description: "two", fromNow: .milliseconds(1000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 2000))
        timer.timerFired(timeNow: .init(milliseconds: 2000))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    func testRecalculateAfterMissingTimer() throws {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(1000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        let twoId = timer.insert(description: "two", fromNow: .milliseconds(1000), timerNow: .init(milliseconds: 1500)) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1500))
        timer.timerFired(timeNow: .init(milliseconds: 1500))
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 2500))
        timer.timerFired(timeNow: .init(milliseconds: 2500))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    // Test that recalculating within 1ms for future times doesn't update the timer
    func testRecalculateWithinThreshold() throws {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .microseconds(1_000_000), timerNow: .zero) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(microseconds: 1_000_000))

        // Start a similar timer only 2 microseconds in the future
        let twoId = timer.insert(
            description: "two",
            fromNow: .microseconds(1_000_000),
            timerNow: .init(microseconds: 2)
        ) { _ in
            semaphore.signal()
        }

        // Timer should stay the same
        XCTAssertEqual(timer.nextDeadline, .init(microseconds: 1_000_000))
        timer.timerFired(timeNow: .init(microseconds: 1_000_000))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    func testAbsoluteNow() {
        XCTAssertGreaterThan(System.Time.nowAbsoluteNanoseconds(), 0)
    }

    func testSpuriousFireRearmsRemainingTimer() {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)

        // A, in 2s
        let idA = timer.insert(description: "A", fromNow: .seconds(2), timerNow: .zero) { _ in
            XCTFail("A was disabled and must not fire")
        }
        XCTAssertEqual(timer.nextDeadline, .init(.seconds(2)))

        // B, 999us after A (crucially, just before the 1ms coalescing threshold)
        let idB = timer.insert(
            description: "B",
            fromNow: .seconds(2) + .microseconds(999),
            timerNow: .zero
        ) { _ in
            semaphore.signal()
        }
        // A was earlier, deadline is unchanged
        XCTAssertEqual(timer.nextDeadline, .init(.seconds(2)))

        // Disable A. B is now the earliest *enabled* entry but the scheduled
        // time should remain at 2s (as B was within the threshold of A).
        timer.reschedule(identifier: idA, fromNow: .zero, timerNow: .zero)
        XCTAssertEqual(timer.nextDeadline, .init(.seconds(2)))

        // Simulate a wakeup which is 0.5ms early. With the 1ms leeway,
        // post-leeway 'now' = 2s + 500us, which is still before B's
        // deadline (2s + 999us), so B doesn't fire and the spurious path runs.
        timer.timerFired(timeNow: .init(.seconds(2) - .microseconds(500)))

        // timerFired needs to rearm the wakeup.
        XCTAssertEqual(timer.nextDeadline, .init(.seconds(2) + .microseconds(999)))

        // Make sure B fires.
        timer.timerFired(timeNow: .init(.seconds(2) + .microseconds(999)))
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(1)),
            DispatchTimeoutResult.success
        )

        timer.remove(idA)
        timer.remove(idB)
    }

    func testCancellationFollowedByCloseInsertRearmsTimer() {
        let timer = QUICTimer(timerReference: TimerReference(), logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)

        let idA = timer.insert(description: "A", fromNow: .seconds(2), timerNow: .zero) { _ in
            XCTFail("A was cancelled and must not fire")
        }
        XCTAssertEqual(timer.nextDeadline, .init(.seconds(2)))

        // Cancel A; disarm the wakeup.
        timer.reschedule(identifier: idA, fromNow: .zero, timerNow: .zero)

        // Schedule a new timer.
        let idB = timer.insert(
            description: "B",
            fromNow: .seconds(2) + .microseconds(500),
            timerNow: .zero
        ) { _ in
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(.seconds(2) + .microseconds(500)))
        timer.timerFired(timeNow: .init(.seconds(2) + .microseconds(500)))
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(1)),
            DispatchTimeoutResult.success
        )

        timer.remove(idA)
        timer.remove(idB)
    }
}

#endif
