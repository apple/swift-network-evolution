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

// Exercises the `await` send/receive surface over real loopback sockets, reusing the same
// harnesses as the callback tests so the two paths are compared on equal footing.
//
// These use XCTest rather than Swift Testing because `UDPLoopbackHarness` and `TCPClientHarness`
// are built on `XCTestExpectation`/`XCTWaiter` for readiness and teardown; XCTest supports async
// test methods directly, so nothing is lost.
@available(Network 0.1.0, *)
final class SwiftNetworkAsyncConnectionTests: NetTestCase {

    // MARK: - Round trips

    func testUDPAsyncRoundTrip() async throws {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()

        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        try await harness.c1.send(.message(content: payload))
        let received = try await harness.c2.receive()
        XCTAssertEqual(received.content, payload)

        harness.teardown()
    }

    func testTCPAsyncRoundTripEcho() async throws {
        let harness = TCPClientHarness()
        harness.start()
        harness.waitReady()

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        try await harness.conn.send(.message(content: payload))
        let echoed = try await harness.conn.receive(atLeast: payload.count, atMost: payload.count)
        XCTAssertEqual(echoed.content, payload)

        harness.teardown()
    }

    /// Several sequential round trips, to confirm each `await` resumes against the right request
    /// rather than an earlier one's completion.
    func testUDPAsyncSequentialRoundTrips() async throws {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()

        for index in 0..<10 {
            let payload: [UInt8] = [UInt8(index), UInt8(index &* 2), UInt8(index &* 3)]
            try await harness.c1.send(.message(content: payload))
            let received = try await harness.c2.receive()
            XCTAssertEqual(received.content, payload, "round trip \(index)")
        }

        harness.teardown()
    }

    // MARK: - Concurrency

    /// Overlapping awaited sends from separate child tasks must all complete. This is the case
    /// that would trip exclusivity if an `await` were held across the event context.
    func testConcurrentAsyncSendsAllComplete() async throws {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()

        let messageCount = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<messageCount {
                group.addTask {
                    try await harness.c1.send(.message(content: [UInt8(index)]))
                }
            }
            try await group.waitForAll()
        }

        // Drain what arrived. UDP on loopback may still coalesce or drop, so this asserts that
        // receiving keeps working after the burst rather than a specific delivery count.
        let received = try await harness.c2.receive()
        XCTAssertNotNil(received.content)

        harness.teardown()
    }

    /// The async and callback surfaces address the same request queues, so a message sent with
    /// `await` must be visible to a callback receive and vice versa.
    func testAsyncAndCallbackSurfacesInteroperate() async throws {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()

        // await send -> callback receive
        let toCallback: [UInt8] = [0x10, 0x20]
        let callbackReceived = XCTestExpectation(description: "callback receive")
        harness.c2.receive { result in
            if case .success(let message) = result {
                XCTAssertEqual(message.content, toCallback)
            } else {
                XCTFail("callback receive failed")
            }
            callbackReceived.fulfill()
        }
        try await harness.c1.send(.message(content: toCallback))
        XCTAssertEqual(XCTWaiter.wait(for: [callbackReceived], timeout: 10.0), .completed)

        // callback send -> await receive
        let toAsync: [UInt8] = [0x30, 0x40]
        harness.c1.send(.message(content: toAsync)) { result in
            if case .failure(let error) = result { XCTFail("callback send failed: \(error)") }
        }
        let asyncReceived = try await harness.c2.receive()
        XCTAssertEqual(asyncReceived.content, toAsync)

        harness.teardown()
    }

    // MARK: - Cancellation

    /// `cancel()` is the documented escape hatch for a pending awaited receive: task cancellation
    /// is not propagated per-operation, but cancelling the channel fails every queued request.
    /// This pins that behaviour so the documentation stays honest.
    func testCancelUnblocksPendingAsyncReceive() async throws {
        let harness = UDPLoopbackHarness()
        harness.start()
        harness.waitBothReady()

        let receiveStarted = XCTestExpectation(description: "receive queued")
        let receiveTask = Task {
            receiveStarted.fulfill()
            return try await harness.c2.receive()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [receiveStarted], timeout: 5.0), .completed)
        // Let the read request reach the context before cancelling it.
        try await Task.sleep(for: .milliseconds(100))

        harness.c2.cancel()

        do {
            _ = try await receiveTask.value
            XCTFail("receive should have failed once the channel was cancelled")
        } catch let error as NetworkError {
            // failPendingRequests() completes queued reads with ECANCELED.
            XCTAssertEqual(error, NetworkError.posix(ECANCELED))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }

        harness.c1.cancel()
    }
}
