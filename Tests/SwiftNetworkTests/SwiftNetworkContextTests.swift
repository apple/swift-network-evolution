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

        context.resetTimer(
            for: TimerReference(index: 13),
            to: .milliseconds(2000) {
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 5.0)
    }

    func testInlineAsyncDrains() {
        let context = NetworkContext.inlineContext(identifier: "test")
        var log: [String] = []

        context.async { log.append("a") }
        context.async { log.append("b") }
        XCTAssertEqual(log, [], "inline work must not run until drained")

        context.drainInline()
        XCTAssertEqual(log, ["a", "b"])
    }

    func testInlineTimerFiresOnVirtualClock() {
        let context = NetworkContext.inlineContext(identifier: "test")
        var fired = false

        context.resetTimer(for: TimerReference(index: 1), to: .milliseconds(100) { fired = true })
        context.drainInline()
        XCTAssertFalse(fired, "timer not yet due")

        context.advanceInline(byMilliseconds: 50)
        XCTAssertFalse(fired, "still not due at t=50")

        context.advanceInline(byMilliseconds: 60)
        XCTAssertTrue(fired, "timer due at t=110")
    }

    func testInlineTimerUnschedule() {
        let context = NetworkContext.inlineContext(identifier: "test")
        var fired = false
        let ref = TimerReference(index: 2)

        context.resetTimer(for: ref, to: .milliseconds(100) { fired = true })
        context.resetTimer(for: ref, to: .unschedule)
        context.advanceInline(byMilliseconds: 200)
        XCTAssertFalse(fired, "unscheduled timer must not fire")
    }
}
