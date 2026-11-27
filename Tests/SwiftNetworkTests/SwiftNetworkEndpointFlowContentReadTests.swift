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

/// The content form of `receive` returns an array built from every frame the stack hands up.
@available(Network 0.1.0, *)
final class SwiftNetworkEndpointFlowContentReadTests: NetTestCase {
    // @unchecked because the connections and their handlers run only on the manual scheduler, which is
    // single threaded, so nothing here is accessed concurrently.
    private final class Observed: @unchecked Sendable {
        var senderReady = false
        var receiverReady = false
        var lastReceive: [UInt8]?
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

    private func makeReadyConnectionPair(
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
        let pair = ConnectionPair(
            manual: manual,
            sender: connection(local: senderPort, remote: receiverPort),
            receiver: connection(local: receiverPort, remote: senderPort)
        )

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
        return pair
    }

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

    /// Queues the writes back to back in one turn of the scheduler, so they reach the stack together.
    private func sendTogether(_ pair: ConnectionPair, _ writes: [[UInt8]]) {
        pair.sender.context.async {
            for bytes in writes {
                let request = WriteRequest(content: bytes, isComplete: false, completion: nil)
                pair.sender.withFlow(request) { flow, request in
                    flow.addWriteRequestOnContext(request, pair.sender as NetworkChannelBase)
                }
            }
        }
    }

    /// Posts one content receive and returns what it delivered.
    private func receiveOnce(on pair: ConnectionPair, atLeast: Int, atMost: Int) -> [UInt8]? {
        let observed = pair.observed
        observed.lastReceive = nil
        pair.receiver.receive(atLeast: atLeast, atMost: atMost) { result in
            switch result {
            case .success(let message):
                if let content = message.content {
                    observed.lastReceive = content
                } else {
                    XCTFail("receive delivered no content")
                }
            case .failure(let error):
                XCTFail("receive failed with error \(error)")
            }
        }
        wait(pair, until: { observed.lastReceive != nil }, "a receive to complete")
        return observed.lastReceive
    }

    /// Frames of different sizes come back as one array, in the order they were written.
    func testFramesOfDifferentSizesAreConcatenatedInOrder() {
        let pair = makeReadyConnectionPair(senderPort: 7803, receiverPort: 7804)

        let writes: [[UInt8]] = [
            [1],
            Array(repeating: 2, count: 7),
            Array(repeating: 3, count: 1500),
            [4, 4],
            Array(repeating: 5, count: 4000),
        ]
        sendTogether(pair, writes)

        let expected = Array(writes.joined())
        XCTAssertEqual(receiveOnce(on: pair, atLeast: expected.count, atMost: Int.max), expected)
        pair.cancel()
    }

    /// A receive that asks for less than has arrived must neither lose nor repeat bytes: what it
    /// returns followed by what later receives return is everything that was written, in order.
    func testMaximumBytesSmallerThanTheDataLosesNothing() {
        let pair = makeReadyConnectionPair(senderPort: 7805, receiverPort: 7806)
        defer { pair.cancel() }

        let writes: [[UInt8]] = [[0, 1, 2], [3, 4, 5, 6], [7, 8, 9]]
        let expected = Array(writes.joined())
        sendTogether(pair, writes)

        // A receive that does not complete has already failed the test, so stop rather than spin.
        guard var received = receiveOnce(on: pair, atLeast: 1, atMost: 4) else { return }
        XCTAssertFalse(received.isEmpty)

        while received.count < expected.count {
            guard let next = receiveOnce(on: pair, atLeast: 1, atMost: 4) else { return }
            received += next
        }

        XCTAssertEqual(received, expected)
    }

    /// A write with no bytes between two others adds nothing and does not disturb the order.
    func testEmptyWriteBetweenOthersAddsNothing() {
        let pair = makeReadyConnectionPair(senderPort: 7807, receiverPort: 7808)

        sendTogether(pair, [[1, 2], [], [3, 4]])

        XCTAssertEqual(receiveOnce(on: pair, atLeast: 4, atMost: Int.max), [1, 2, 3, 4])
        pair.cancel()
    }
}
