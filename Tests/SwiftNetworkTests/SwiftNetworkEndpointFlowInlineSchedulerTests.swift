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

@available(Network 0.1.0, *)
final class SwiftNetworkEndpointFlowInlineSchedulerTests: NetTestCase {
    /// A scheduler that runs the next `runImmediate` task, and anything that task submits, on the
    /// caller's stack once `runsNextTaskInline` is set. Some schedulers run every task this way.
    /// All other tasks go to a manual scheduler.
    ///
    /// Running every task inline would also run the stack's own event deferral inline, which
    /// re-enters the context's event state; the test only needs the flush task to run inline.
    private final class SometimesInlineScheduler: NetworkContext.Scheduler {
        let manual = ManualScheduler(now: .testBase)
        var runsNextTaskInline = false
        private(set) var inlineTaskCount = 0
        private var inlineTaskDepth = 0
        /// Keeps a task that resubmits itself from overflowing the test's stack.
        private let inlineTaskLimit = 100

        func runImmediate(_ task: @escaping (() -> Void)) {
            let shouldRunInline = (runsNextTaskInline || inlineTaskDepth > 0) && inlineTaskCount < inlineTaskLimit
            if shouldRunInline {
                runsNextTaskInline = false
                inlineTaskCount += 1
                inlineTaskDepth += 1
                task()
                inlineTaskDepth -= 1
            } else {
                manual.runImmediate(task)
            }
        }

        func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
            manual.schedule(task, after: delay, reference: reference)
        }

        func unschedule(reference: TimerReference) {
            manual.unschedule(reference: reference)
        }

        var runningInScheduler: Bool { manual.runningInScheduler }
        var now: NetworkClock.Instant { manual.now }
        var nowAbsolute: NetworkClock.Instant { manual.nowAbsolute }
    }

    // The scheduler runs every task on the test's thread, so nothing here is accessed concurrently.
    private final class Observed: @unchecked Sendable {
        var senderReady = false
        var receiverReady = false
        var receivedBytes: [UInt8] = []
        var receiveFinished = false
    }

    /// A flush task that runs inline inside the `send` that scheduled it finds the flow borrowed.
    /// It must hand the flush to the call holding the flow; retrying from the task recurses until
    /// the stack overflows.
    func testSendDoesNotRecurseWhenSchedulerRunsTasksInline() {
        let scheduler = SometimesInlineScheduler()
        let context = NetworkContext(identifier: #function, externalScheduler: scheduler)
        context.activate()

        func connection(local: UInt16, remote: UInt16) -> NetworkConnection<NoTransport> {
            var parameters = ParametersBuilder<NoTransport>.parameters {
                NoTransport {
                    StreamBridge()
                }
            }
            .localEndpoint(Endpoint(address: IPv4Address.loopback, port: local))
            .parameters
            parameters.context = context
            return NetworkConnection<NoTransport>(
                kind: .noTransport,
                to: Endpoint(address: IPv4Address.loopback, port: remote),
                using: parameters,
                uuid: SystemUUID()
            )
        }
        let senderPort: UInt16 = 7811
        let receiverPort: UInt16 = 7812
        let sender = connection(local: senderPort, remote: receiverPort)
        let receiver = connection(local: receiverPort, remote: senderPort)
        let observed = Observed()
        sender.onStateUpdate { _, state in
            if case .ready = state { observed.senderReady = true }
        }
        receiver.onStateUpdate { _, state in
            if case .ready = state { observed.receiverReady = true }
        }
        sender.start()
        receiver.start()
        XCTAssertTrue(
            scheduler.manual.run(until: { observed.senderReady && observed.receiverReady }, limit: .seconds(5)),
            "timed out waiting for both connections to be ready"
        )

        // `send` queues a task that borrows the flow and schedules the flush from inside it; the
        // flush task is the next one submitted, and runs inline within that borrow.
        sender.send(.message(content: [1, 2, 3]))
        scheduler.runsNextTaskInline = true
        scheduler.manual.run()
        XCTAssertEqual(scheduler.inlineTaskCount, 1, "exactly one task should run inline; a retry loop would run until the limit")

        receiver.receive(atLeast: 3, atMost: Int.max) { result in
            switch result {
            case .success(let message):
                observed.receivedBytes = message.content ?? []
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
            observed.receiveFinished = true
        }
        XCTAssertTrue(
            scheduler.manual.run(until: { observed.receiveFinished }, limit: .seconds(5)),
            "timed out waiting for the bytes to arrive"
        )
        XCTAssertEqual(observed.receivedBytes, [1, 2, 3])

        sender.cancel()
        receiver.cancel()
        scheduler.manual.run()
    }
}
