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

@_spi(Essentials) import SwiftNetwork
@_spi(Essentials) import SwiftNetworkTestSupport

enum ContentReceiveHarnessError: Error {
    case connectionDidNotBecomeReady
    case injectionUnavailable
    case receiveDidNotComplete
    case receiveFailed(any Error)
    case receiveDeliveredNoContent
    case receivedUnexpectedByteCount(expected: Int, actual: Int)
}

/// A `NetworkConnection` whose link delivers bytes only when told to, driven by a virtual clock.
///
/// Nothing here touches a socket or the wall clock, so what the connection receives and when does
/// not depend on the machine. `receive` is the public `NetworkConnection` call.
@available(Network 0.1.0, *)
final class ContentReceiveHarness: @unchecked Sendable {
    // @unchecked because the connection and its handlers run only on the manual scheduler, which is
    // single threaded, so nothing here is accessed concurrently.
    private let manualTime: ManualTimeContext
    private let connection: NetworkConnection<NoTransport>

    private enum ReceiveOutcome {
        case pending
        case delivered(byteCount: Int)
        case failed(any Error)
        case noContent
    }

    /// State the connection's handlers write, shared with the closures that are built before
    /// `self` is fully initialized.
    private final class Observed: @unchecked Sendable {
        // @unchecked for the same reason as the enclosing type: only the manual scheduler touches it.
        var isReady = false
        var inject: ((Span<UInt8>) -> Void)?
        var receiveOutcome = ReceiveOutcome.pending
    }

    private let observed = Observed()

    /// The ports only name the flow: the link delivers bytes by hand and no socket is bound.
    init(localPort: UInt16 = 7901, remotePort: UInt16 = 7902) throws {
        let manualTime = ManualTimeContext("ContentReceiveHarness")
        manualTime.context.activate()
        self.manualTime = manualTime

        let observed = self.observed
        var builder = ParametersBuilder<NoTransport>.parameters {
            NoTransport {
                CustomLink()
                    .rx { inject in
                        observed.inject = inject
                    }
            }
        }
        .localEndpoint(Endpoint(address: IPv4Address.loopback, port: localPort))
        builder.parameters.context = manualTime.context
        self.connection = NetworkConnection<NoTransport>(
            to: Endpoint(address: IPv4Address.loopback, port: remotePort),
            using: builder
        )

        self.connection.onStateUpdate { _, state in
            switch state {
            case .ready:
                observed.isReady = true
            case .setup, .waiting, .preparing, .failed, .cancelled:
                // The connection is not usable yet, or no longer; `init` fails if it never gets ready.
                break
            }
        }
        self.connection.start()

        let reachedReady = manualTime.scheduler.run(until: { observed.isReady }, limit: .seconds(5))
        if !reachedReady {
            throw ContentReceiveHarnessError.connectionDidNotBecomeReady
        }
    }

    /// Delivers `bytes` to the connection as one frame per `frameSize` bytes, the way a link
    /// delivers one datagram or segment at a time, and runs the scheduler until all of it is queued.
    func deliver(_ bytes: [UInt8], frameSize: Int) throws {
        guard let inject = self.observed.inject else {
            throw ContentReceiveHarnessError.injectionUnavailable
        }
        self.manualTime.context.async {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset &+ frameSize, bytes.count)
                inject(bytes.span.extracting(offset..<end))
                offset = end
            }
        }
        self.manualTime.run()
    }

    /// Posts one content `receive` for exactly `byteCount` bytes and runs the scheduler until it
    /// completes.
    func receive(byteCount: Int) throws {
        let observed = self.observed
        observed.receiveOutcome = .pending
        self.connection.receive(atLeast: byteCount, atMost: byteCount) { result in
            switch result {
            case .success(let message):
                if let content = message.content {
                    observed.receiveOutcome = .delivered(byteCount: content.count)
                } else {
                    observed.receiveOutcome = .noContent
                }
            case .failure(let error):
                observed.receiveOutcome = .failed(error)
            }
        }
        self.manualTime.run()

        switch observed.receiveOutcome {
        case .pending:
            throw ContentReceiveHarnessError.receiveDidNotComplete
        case .delivered(let receivedByteCount):
            if receivedByteCount != byteCount {
                throw ContentReceiveHarnessError.receivedUnexpectedByteCount(
                    expected: byteCount,
                    actual: receivedByteCount
                )
            }
        case .failed(let error):
            throw ContentReceiveHarnessError.receiveFailed(error)
        case .noContent:
            throw ContentReceiveHarnessError.receiveDeliveredNoContent
        }
    }

    func tearDown() {
        self.connection.cancel()
        self.manualTime.run()
    }
}
