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

import Synchronization

@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

@available(Network 0.1.0, *)
final class ConcurrencySchedulerTests: NetTestCase {

    // MARK: - Timer ordering

    func testTimersFireInDeadlineOrder() {
        let scheduler = ConcurrencyScheduler(label: "order")
        let context = NetworkContext(identifier: "order", externalScheduler: scheduler)

        let allFired = XCTestExpectation(description: "all timers fired")
        allFired.expectedFulfillmentCount = 4
        let order = Mutex<[Int]>([])

        // Scheduled shortest-last, so passing requires the scheduler to order by deadline
        // rather than by insertion.
        for (index, milliseconds) in [40, 30, 20, 10].enumerated() {
            _ = context.scheduleTimer(duration: .milliseconds(milliseconds)) {
                order.withLock { $0.append(index) }
                allFired.fulfill()
            }
        }

        XCTAssertEqual(XCTWaiter.wait(for: [allFired], timeout: 5.0), .completed)
        XCTAssertEqual(order.withLock { $0 }, [3, 2, 1, 0])
    }

    /// The re-arm path: a timer inserted while the driver is already sleeping on a later
    /// deadline must cancel that sleep and fire on time.
    func testEarlierTimerRearmsSleepingDriver() {
        let scheduler = ConcurrencyScheduler(label: "rearm")
        let context = NetworkContext(identifier: "rearm", externalScheduler: scheduler)

        let lateFired = XCTestExpectation(description: "late timer fired")
        let earlyFired = XCTestExpectation(description: "early timer fired")
        let firstToFire = Mutex<String?>(nil)

        _ = context.scheduleTimer(duration: .seconds(2)) {
            firstToFire.withLock { if $0 == nil { $0 = "late" } }
            lateFired.fulfill()
        }
        // Give the driver time to actually be asleep on the 2s deadline before undercutting it.
        Thread.sleep(forTimeInterval: 0.1)
        _ = context.scheduleTimer(duration: .milliseconds(50)) {
            firstToFire.withLock { if $0 == nil { $0 = "early" } }
            earlyFired.fulfill()
        }

        // If re-arming were broken the early timer would wait behind the 2s sleep.
        XCTAssertEqual(XCTWaiter.wait(for: [earlyFired], timeout: 1.0), .completed)
        XCTAssertEqual(firstToFire.withLock { $0 }, "early")
        XCTAssertEqual(XCTWaiter.wait(for: [lateFired], timeout: 5.0), .completed)
    }

    func testUnscheduledTimerDoesNotFire() {
        let scheduler = ConcurrencyScheduler(label: "unschedule")
        let context = NetworkContext(identifier: "unschedule", externalScheduler: scheduler)

        let shouldNotFire = XCTestExpectation(description: "cancelled timer fired")
        shouldNotFire.isInverted = true
        let reference = context.scheduleTimer(duration: .milliseconds(50)) {
            shouldNotFire.fulfill()
        }
        context.unscheduleTimer(reference)

        XCTAssertEqual(XCTWaiter.wait(for: [shouldNotFire], timeout: 0.5), .completed)
    }

    /// A timer armed from inside a fired timer's block must still work: `fireDueEntries`
    /// re-arms after draining, so the nested timer has to be picked up.
    func testTimerScheduledFromInsideTimerFires() {
        let scheduler = ConcurrencyScheduler(label: "nested")
        let context = NetworkContext(identifier: "nested", externalScheduler: scheduler)

        let nestedFired = XCTestExpectation(description: "nested timer fired")
        _ = context.scheduleTimer(duration: .milliseconds(20)) {
            _ = context.scheduleTimer(duration: .milliseconds(20)) {
                nestedFired.fulfill()
            }
        }

        XCTAssertEqual(XCTWaiter.wait(for: [nestedFired], timeout: 5.0), .completed)
    }

    // MARK: - Isolation reporting

    /// `runningInScheduler` used to trap for the Dispatch default. Both schedulers now answer it.
    func testRunningInSchedulerReportsCorrectly() {
        let scheduler = ConcurrencyScheduler(label: "isolation")
        let context = NetworkContext(identifier: "isolation", externalScheduler: scheduler)

        XCTAssertFalse(scheduler.runningInScheduler, "the test thread is not the context")

        let checked = XCTestExpectation(description: "checked inside")
        context.async {
            XCTAssertTrue(scheduler.runningInScheduler, "inside async(_:) is the context")
            checked.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5.0), .completed)
    }

    func testDefaultSchedulerReportsRunningInScheduler() {
        let context = NetworkContext(identifier: "default isolation")

        XCTAssertFalse(context.runningInContext, "the test thread is not the context")

        let checked = XCTestExpectation(description: "checked inside")
        context.async {
            XCTAssertTrue(context.runningInContext, "inside async(_:) is the context")
            checked.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5.0), .completed)
    }

    /// Two contexts must not mistake each other's queue for their own.
    func testSchedulersDoNotConfuseEachOthersQueues() {
        let schedulerA = ConcurrencyScheduler(label: "A")
        let schedulerB = ConcurrencyScheduler(label: "B")
        let contextA = NetworkContext(identifier: "A", externalScheduler: schedulerA)

        let checked = XCTestExpectation(description: "checked")
        contextA.async {
            XCTAssertTrue(schedulerA.runningInScheduler)
            XCTAssertFalse(schedulerB.runningInScheduler, "B must not claim A's queue")
            checked.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 5.0), .completed)
    }

    // MARK: - Serial executor

    /// The scheduler is the context's `SerialExecutor`, so a task bound to it runs on the
    /// context's serial execution -- the mechanism that lets `await` enter the context.
    func testTaskBoundToExecutorRunsOnTheContext() async {
        let scheduler = ConcurrencyScheduler(label: "executor")
        let context = NetworkContext(identifier: "executor", externalScheduler: scheduler)

        XCTAssertNotNil(context.serialExecutor, "a concurrency-scheduled context provides one")

        let actor = ContextBoundActor(scheduler: scheduler)
        let onContext = await actor.isOnTheContext()
        XCTAssertTrue(onContext, "actor work must run on the scheduler's serial execution")
    }

    func testDefaultSchedulerProvidesNoSerialExecutor() {
        let context = NetworkContext(identifier: "no executor")
        XCTAssertNil(context.serialExecutor, "the Dispatch default has no SerialExecutor yet")
    }

    /// An actor bound to the context's executor, used to prove work lands on the context.
    private actor ContextBoundActor {
        private let scheduler: ConcurrencyScheduler

        nonisolated var unownedExecutor: UnownedSerialExecutor {
            scheduler.asUnownedSerialExecutor()
        }

        init(scheduler: ConcurrencyScheduler) {
            self.scheduler = scheduler
        }

        func isOnTheContext() -> Bool {
            scheduler.runningInScheduler
        }
    }

    // MARK: - End to end

    /// A real connection driven entirely by the concurrency scheduler, using the async surface.
    /// This is the check that matters: the stack's internals are unchanged, so nothing inside
    /// should notice which scheduler is arming the timers.
    func testConnectionOverConcurrencySchedulerAsyncRoundTrip() async throws {
        let ports = discoverFreeLoopbackPorts(2)

        var builderA = ParametersBuilder<UDP>.parameters { UDP() }
        builderA.parameters.localAddress = Endpoint(address: IPv4Address.loopback, port: ports[1])
        builderA.parameters.context = NetworkContext(
            identifier: "peerA",
            externalScheduler: ConcurrencyScheduler(label: "peerA")
        )

        var builderB = ParametersBuilder<UDP>.parameters { UDP() }
        builderB.parameters.localAddress = Endpoint(address: IPv4Address.loopback, port: ports[0])
        builderB.parameters.context = NetworkContext(
            identifier: "peerB",
            externalScheduler: ConcurrencyScheduler(label: "peerB")
        )

        let peerA = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: ports[0]), using: builderA)
        let peerB = NetworkConnection(to: Endpoint(address: IPv4Address.loopback, port: ports[1]), using: builderB)
        peerA.start()
        peerB.start()

        let payload: [UInt8] = [0x51, 0x52, 0x53]
        try await peerA.send(.message(content: payload))
        let received = try await peerB.receive()
        XCTAssertEqual(received.content, payload)

        peerA.cancel()
        peerB.cancel()
    }
}
