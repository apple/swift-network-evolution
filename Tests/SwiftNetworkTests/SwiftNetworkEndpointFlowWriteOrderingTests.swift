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
}
