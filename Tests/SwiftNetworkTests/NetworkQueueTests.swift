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

#if canImport(Dispatch)
import XCTest
@_spi(Essentials) @testable import SwiftNetwork

@available(Network 0.1.0, *)
final class NetworkQueueTests: XCTestCase {

    // MARK: - async / ordering

    func testInlineAsyncRunsInOrderOnlyWhenDrained() {
        let queue = NetworkQueue()
        var log: [Int] = []
        queue.async { log.append(1) }
        queue.async { log.append(2) }
        XCTAssertEqual(log, [])
        queue.drain()
        XCTAssertEqual(log, [1, 2])
    }

    func testAsyncIfNeededRunsInlineWhileDraining() {
        let queue = NetworkQueue()
        var order: [String] = []
        queue.async {
            order.append("outer")
            queue.asyncIfNeeded { order.append("inner") }
        }
        queue.drain()
        XCTAssertEqual(order, ["outer", "inner"])
    }

    func testIsCurrentOnlyTrueWhileDraining() {
        let queue = NetworkQueue()
        XCTAssertFalse(queue.isCurrent)
        queue.async { XCTAssertTrue(queue.isCurrent) }
        queue.drain()
        XCTAssertFalse(queue.isCurrent)
    }

    // MARK: - timers

    func testOneShotTimerFiresExactlyOnce() {
        let queue = NetworkQueue()
        var count = 0
        let source = queue.createSource(.timer) { count += 1 }
        source.setTimerValues(fireTime: queue.now + .milliseconds(10))
        source.activate()

        queue.advance(byMilliseconds: 100)
        queue.advance(byMilliseconds: 100)
        XCTAssertEqual(count, 1, "one-shot must not re-fire and must not loop")
    }

    func testRepeatingTimerFiresPerInterval() {
        let queue = NetworkQueue()
        var count = 0
        let source = queue.createSource(.timer) { count += 1 }
        source.setTimerValues(
            fireTime: queue.now + .milliseconds(10),
            interval: 10_000_000  // 10ms
        )
        source.activate()

        queue.advance(byMilliseconds: 35)  // fires at 10, 20, 30
        XCTAssertEqual(count, 3)
    }

    func testSuspendedTimerDoesNotFire() {
        let queue = NetworkQueue()
        var fired = false
        let source = queue.createSource(.timer) { fired = true }
        source.setTimerValues(fireTime: queue.now + .milliseconds(10))
        // never activated
        queue.advance(byMilliseconds: 100)
        XCTAssertFalse(fired)
    }

    func testCancelledTimerDoesNotFireAndRunsCancelBlock() {
        let queue = NetworkQueue()
        var fired = false
        var cancelledRan = false
        let source = queue.createSource(.timer, block: { fired = true }, cancelBlock: { cancelledRan = true })
        source.setTimerValues(fireTime: queue.now + .milliseconds(10))
        source.activate()
        source.cancel()

        queue.advance(byMilliseconds: 100)
        XCTAssertFalse(fired)
        XCTAssertTrue(cancelledRan)
    }

    func testCancelIsIdempotent() {
        let queue = NetworkQueue()
        var cancelCount = 0
        let source = queue.createSource(.timer, block: {}, cancelBlock: { cancelCount += 1 })
        source.activate()
        source.cancel()
        source.cancel()
        XCTAssertEqual(cancelCount, 1)
    }

    func testEarliestTimerFiresFirst() {
        let queue = NetworkQueue()
        var order: [String] = []
        let late = queue.createSource(.timer) { order.append("late") }
        late.setTimerValues(fireTime: queue.now + .milliseconds(50))
        late.activate()
        let early = queue.createSource(.timer) { order.append("early") }
        early.setTimerValues(fireTime: queue.now + .milliseconds(10))
        early.activate()

        queue.advance(byMilliseconds: 100)
        XCTAssertEqual(order, ["early", "late"])
    }

    // MARK: - inline restrictions

    func testInlineTimerSourceConstructs() {
        let queue = NetworkQueue()
        // Read/write sources need kernel event delivery and trap inline; timer sources are fine.
        let timer = queue.createSource(.timer) {}
        XCTAssertNotNil(timer)
    }

    func testDataIsZeroForInlineSource() {
        let queue = NetworkQueue()
        let source = queue.createSource(.timer) {}
        XCTAssertEqual(source.data, 0)
    }
}
#endif
