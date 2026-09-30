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

// Covers the two doors into the event context: `enter(_:)` (off-scheduler, `await`) and
// `entered(_:)` (scheduler-delivered, synchronous). See `NetworkContextIsolation`.
@available(Network 0.1.0, *)
final class NetworkContextIsolationTests: NetTestCase {

    // MARK: - The synchronous door

    /// Scheduler-delivered work reaches the event context with no `await`. This is the shape every
    /// external-entry overload in the stack -- `deliverConnectedEvent()` and the rest -- ends up in.
    func testEnteredFromSchedulerDeliveredWork() {
        let context = NetworkContext(identifier: "entered")
        let reached = XCTestExpectation(description: "reached the event context")

        context.async {
            // No `await` anywhere in here.
            context.entered { eventContext in
                eventContext.assert()
                reached.fulfill()
            }
        }

        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 5.0), .completed)
    }

    /// The synchronous door carries a `~Copyable` result and a typed `throws`, which is precisely
    /// what `assumeIsolated` cannot do and why the door exists at all.
    func testEnteredCarriesNoncopyableResultAndTypedThrows() {
        struct Token: ~Copyable {
            let value: Int
        }
        struct Failure: Error {
            let code: Int
        }

        let context = NetworkContext(identifier: "entered shapes")
        let checked = XCTestExpectation(description: "both shapes checked")

        context.async {
            let token = context.entered { _ -> Token in Token(value: 7) }
            XCTAssertEqual(token.value, 7)

            do {
                try context.entered { _ throws(Failure) in throw Failure(code: 42) }
                XCTFail("should have thrown")
            } catch let error as Failure {
                // The typed error survived the door rather than widening to `any Error`.
                XCTAssertEqual(error.code, 42)
            } catch {
                XCTFail("error widened to \(type(of: error))")
            }
            checked.fulfill()
        }

        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5.0), .completed)
    }

    /// The accessor form is the same door, used where a closure cannot be introduced: delegating
    /// initializers, and functions with a `consuming` parameter.
    func testEnteredEventContextAccessor() {
        let context = NetworkContext(identifier: "accessor")
        let checked = XCTestExpectation(description: "accessor used")

        context.async {
            context.enteredEventContext.assert()
            checked.fulfill()
        }

        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5.0), .completed)
    }

    /// A context whose scheduler runs inline reports the caller as being on it, so the door opens
    /// without hopping. This is what lets the single-threaded QUIC tests reach the event context
    /// directly instead of needing a bypass.
    func testEnteredWithAnInlineScheduler() {
        final class Inline: NetworkContext.Scheduler {
            func runImmediate(_ task: @escaping (() -> Void)) { task() }
            func schedule(
                _ task: @escaping (() -> Void),
                after delay: NetworkDuration,
                reference: TimerReference
            ) {}
            func unschedule(reference: TimerReference) {}
            var runningInScheduler: Bool { true }
            var now: NetworkClock.Instant { .systemNow }
            var nowAbsolute: NetworkClock.Instant { .systemNowAbsolute }
        }

        let context = NetworkContext(identifier: "inline", externalScheduler: Inline())
        let value = context.entered { _ -> Int in 3 }
        XCTAssertEqual(value, 3)
    }

    // MARK: - The async door

    /// Off-scheduler callers -- the client API, async TLS callbacks -- `await` their way in. The
    /// compiler enforces this: `enter(_:)` is actor-isolated, so it cannot be called without
    /// suspending onto the context's executor.
    func testEnterFromOffTheScheduler() async {
        let context = NetworkContext(identifier: "enter")
        XCTAssertFalse(context.runningInContext, "the test thread is not the context")

        let onContext = await context.enter { _ -> Bool in
            // Inside the door, the caller is on the context's executor.
            context.runningInContext
        }
        XCTAssertTrue(onContext)
    }

    /// The async door carries a `~Copyable` result too, via `sending`.
    func testEnterCarriesNoncopyableResult() async {
        struct Token: ~Copyable {
            let value: Int
        }

        let context = NetworkContext(identifier: "enter noncopyable")
        let token = await context.enter { _ -> Token in Token(value: 11) }
        XCTAssertEqual(token.value, 11)
    }

    /// Both doors reach the *same* event context, so state registered through one is visible
    /// through the other. This is the invariant that makes the split safe rather than two stacks.
    func testBothDoorsShareOneEventContext() async {
        let context = NetworkContext(identifier: "shared state")

        let index = await context.enter { eventContext -> NetworkStateIndex in
            eventContext.registerProtocolEventState()
        }
        XCTAssertFalse(index.isNone)

        let seenThroughSyncDoor = XCTestExpectation(description: "visible through entered")
        context.async {
            context.entered { eventContext in
                // Registered through `enter`, unregistered through `entered`: one shared array.
                eventContext.unregisterProtocolEventState(index)
                seenThroughSyncDoor.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [seenThroughSyncDoor], timeout: 5.0), .completed)
    }

    /// A concurrency-scheduled context uses the scheduler itself as the executor, so the async door
    /// lands on the same serial execution the synchronous door checks for.
    func testDoorsAgreeOnAConcurrencyScheduledContext() async {
        let scheduler = ConcurrencyScheduler(label: "doors")
        let context = NetworkContext(identifier: "doors", externalScheduler: scheduler)

        let onContext = await context.enter { _ -> Bool in scheduler.runningInScheduler }
        XCTAssertTrue(onContext, "the async door must land on the scheduler's execution")

        let reached = XCTestExpectation(description: "sync door reached")
        context.async {
            context.entered { _ in reached.fulfill() }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 5.0), .completed)
    }
}
