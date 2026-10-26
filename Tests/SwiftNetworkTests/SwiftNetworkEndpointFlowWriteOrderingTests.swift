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
final class SwiftNetworkEndpointFlowWriteOrderingTests: NetTestCase {
    private final class Observed: @unchecked Sendable {
        var senderReady = false
        var receiverReady = false
        var receivedBytes: [UInt8] = []
        var receiveFinished = false
        var completedWrites = 0
        var failedWrites = 0
    }

    private struct ConnectionPair {
        let manual: ManualTimeContext
        let sender: NetworkConnection<NoTransport>
        let receiver: NetworkConnection<NoTransport>
        let observed = Observed()

        func cancel() {
            sender.cancel()
            receiver.cancel()
            manual.run()
        }
    }

    /// A span receive posted before any data arrives has to complete when the data does.
    func testSpanReceivePostedBeforeDataCompletes() {
        let pair = makeConnectionPair(senderPort: 7799, receiverPort: 7800)
        waitUntilReady(pair)

        let observed = pair.observed
        pair.receiver.receive(atLeast: 1, atMost: Int.max, maximumChunks: 4) { result in
            switch result {
            case .success(let message):
                observed.receivedBytes = Array(repeating: 0, count: message.content?.byteCount ?? 0)
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
            observed.receiveFinished = true
        }

        // Run the scheduler so the request is registered before anything is sent
        pair.manual.run()

        // should not have completed yet
        XCTAssertFalse(observed.receiveFinished)

        pair.sender.send(.message(content: [1, 2, 3]))

        // data written, should now be able to complete
        wait(pair, until: { observed.receiveFinished }, "the span receive to complete")
        XCTAssertEqual(observed.receivedBytes.count, 3)

        pair.cancel()
    }

    private func makeConnectionPair(
        senderPort: UInt16,
        receiverPort: UInt16,
        identifier: String = #function
    ) -> ConnectionPair {
        let manual = ManualTimeContext(identifier)
        manual.context.activate()

        func connection(local: UInt16, remote: UInt16) -> NetworkConnection<NoTransport> {
            var parameters = ParametersBuilder<NoTransport>.parameters {
                NoTransport {
                    StreamBridge()
                }
            }
            .localEndpoint(Endpoint(address: IPv4Address.loopback, port: local))
            .parameters
            parameters.context = manual.context
            return NetworkConnection<NoTransport>(
                kind: .noTransport,
                to: Endpoint(address: IPv4Address.loopback, port: remote),
                using: parameters,
                uuid: SystemUUID()
            )
        }
        return ConnectionPair(
            manual: manual,
            sender: connection(local: senderPort, remote: receiverPort),
            receiver: connection(local: receiverPort, remote: senderPort)
        )
    }

    private struct Write: Sendable {
        var bytes: [UInt8]
        var priority: Double = 0.5
        var isComplete = false
    }

    /// Queues writes the way `send` does, but with chosen priorities. Each runs as its own task on
    /// the scheduler unless `inOneTurn` is set, in which case they all run back to back before the
    /// scheduler takes another task.
    private func enqueue(_ connection: NetworkConnection<NoTransport>, _ writes: [Write], inOneTurn: Bool = false) {
        func add(_ write: Write) {
            var request = WriteRequest(content: write.bytes, isComplete: write.isComplete, completion: nil)
            request.relativePriority = write.priority
            connection.withFlow(request) { flow, request in
                flow.addWriteRequestOnContext(request, connection as NetworkChannelBase)
            }
        }
        if inOneTurn {
            connection.context.async { writes.forEach(add) }
        } else {
            for write in writes {
                connection.context.async { add(write) }
            }
        }
    }

    /// Drives the scheduler until `condition` holds, and fails the test if it never does.
    private func wait(
        _ pair: ConnectionPair,
        until condition: () -> Bool,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reached = pair.manual.scheduler.run(until: condition, limit: .seconds(5))
        XCTAssertTrue(reached, "timed out waiting for \(what)", file: file, line: line)
    }

    private func waitUntilReady(_ pair: ConnectionPair) {
        let observed = pair.observed
        pair.sender.onStateUpdate { _, state in
            if case .ready = state { observed.senderReady = true }
        }
        pair.receiver.onStateUpdate { _, state in
            if case .ready = state { observed.receiverReady = true }
        }
        pair.sender.start()
        pair.receiver.start()
        wait(pair, until: { observed.senderReady && observed.receiverReady }, "both connections to be ready")
    }

    /// Returns the bytes the receiver is given once at least `count` have arrived.
    private func receive(on pair: ConnectionPair, count: Int) -> [UInt8] {
        let observed = pair.observed
        observed.receiveFinished = false
        pair.receiver.receive(atLeast: count, atMost: Int.max) { result in
            switch result {
            case .success(let message):
                observed.receivedBytes = message.content ?? []
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
            observed.receiveFinished = true
        }
        wait(pair, until: { observed.receiveFinished }, "\(count) bytes to arrive")
        return observed.receivedBytes
    }

    /// A write that arrives while the flow can send must not be overtaken by a later write of
    /// higher priority, even before the stack has seen it.
    func testWritesOnReadyFlowKeepSubmissionOrderDespitePriority() {
        let pair = makeConnectionPair(senderPort: 7791, receiverPort: 7792)
        waitUntilReady(pair)

        enqueue(pair.sender, [Write(bytes: [1], priority: 0.1), Write(bytes: [2], priority: 0.9), Write(bytes: [3])])

        XCTAssertEqual(receive(on: pair, count: 3), [1, 2, 3])
        pair.cancel()
    }

    /// Writes submitted back to back in one turn of the scheduler reach the stack together; they
    /// must still keep submission order despite priority.
    func testWritesSubmittedInOneTurnKeepSubmissionOrderDespitePriority() {
        let pair = makeConnectionPair(senderPort: 7793, receiverPort: 7794)
        waitUntilReady(pair)

        enqueue(
            pair.sender,
            [
                Write(bytes: [1], priority: 0.1), Write(bytes: [2], priority: 0.9),
                Write(bytes: [3]), Write(bytes: [4], priority: 0.9), Write(bytes: [5], priority: 0.1),
            ],
            inOneTurn: true
        )

        XCTAssertEqual(receive(on: pair, count: 5), [1, 2, 3, 4, 5])
        pair.cancel()
    }

    /// A write that completes the stream must not reach the peer before the writes ahead of it.
    func testCompletingWriteFollowsEarlierWritesSubmittedInOneTurn() {
        let pair = makeConnectionPair(senderPort: 7795, receiverPort: 7796)
        waitUntilReady(pair)

        enqueue(pair.sender, [Write(bytes: [1], priority: 0.2), Write(bytes: [2], isComplete: true)], inOneTurn: true)

        XCTAssertEqual(receive(on: pair, count: 2), [1, 2])
        pair.cancel()
    }

    /// Every write submitted together gets its completion, once, with success.
    func testEveryWriteSubmittedTogetherIsCompleted() {
        let pair = makeConnectionPair(senderPort: 7797, receiverPort: 7798)
        waitUntilReady(pair)

        let writeCount = 8
        let observed = pair.observed
        for byte in 0..<writeCount {
            pair.sender.send(.message(content: [UInt8(byte)])) { result in
                switch result {
                case .success: observed.completedWrites += 1
                case .failure: observed.failedWrites += 1
                }
            }
        }
        wait(pair, until: { observed.completedWrites + observed.failedWrites >= writeCount }, "every write to complete")

        // A completion delivered twice would show once the rest of the queued work has run.
        pair.manual.run()
        XCTAssertEqual(observed.completedWrites, writeCount)
        XCTAssertEqual(observed.failedWrites, 0)
        XCTAssertEqual(receive(on: pair, count: writeCount), Array(0..<UInt8(writeCount)))
        pair.cancel()
    }
}
