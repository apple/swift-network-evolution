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

#if !NETWORK_NO_SWIFT_QUIC

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class QUICConnectionStateTests: XCTestCase {
    // Every state a connection is in once it has been set up and before it starts to close.
    static var liveStates: [QUICConnectionState] {
        [
            .versionSent, .retrySent, .initialReceived, .initialProcessed,
            .versionReceived, .initialSent, .retryReceived,
            .handshake, .connected,
        ]
    }

    func isAllowed(from: QUICConnectionState, to: QUICConnectionState) -> Bool {
        let allowedTransitions: [(from: QUICConnectionState, to: QUICConnectionState)] = [
            (from: .invalid, to: .idle),

            // Client
            (from: .idle, to: .initialSent),
            (from: .initialSent, to: .versionReceived),
            (from: .versionReceived, to: .initialSent),
            (from: .initialSent, to: .retryReceived),
            (from: .retryReceived, to: .initialSent),
            (from: .initialSent, to: .handshake),

            // Server
            (from: .idle, to: .versionSent),
            (from: .retrySent, to: .versionSent),
            (from: .idle, to: .retrySent),
            (from: .versionSent, to: .retrySent),
            (from: .idle, to: .initialReceived),
            (from: .versionSent, to: .initialReceived),
            (from: .retrySent, to: .initialReceived),
            (from: .initialReceived, to: .initialProcessed),
            (from: .initialReceived, to: .handshake),
            (from: .initialProcessed, to: .handshake),

            (from: .handshake, to: .connected),

            (from: .closing, to: .draining),
        ]
        if to == .closing || to == .draining, Self.liveStates.contains(from) {
            return true
        }
        return allowedTransitions.contains { $0.from == from && $0.to == to }
    }

    func testValidStateChanges() {
        for startState in QUICConnectionState.allCases {
            for destinationState in QUICConnectionState.allCases {
                XCTAssertEqual(
                    startState.canTransition(to: destinationState),
                    isAllowed(from: startState, to: destinationState),
                    "Check state transition from \(startState) to \(destinationState)"
                )
            }
        }
    }

    // A connection that never left idle has nothing to close, and close() leaves its state alone.
    func testUnstartedConnectionCannotClose() {
        for state in [QUICConnectionState.invalid, .idle] {
            XCTAssertFalse(state.canTransition(to: .closing), "\(state)")
            XCTAssertFalse(state.canTransition(to: .draining), "\(state)")
        }
    }

    func testTerminalStatesDoNotCloseAgain() {
        XCTAssertFalse(QUICConnectionState.closing.canTransition(to: .closing))
        XCTAssertFalse(QUICConnectionState.draining.canTransition(to: .closing))
        XCTAssertFalse(QUICConnectionState.draining.canTransition(to: .draining))
    }

    // A server that sent a Retry closes like any other, and answers an Initial with an unsupported
    // version with Version Negotiation.
    func testRetryStatesCanCloseAndNegotiateVersion() {
        XCTAssertTrue(QUICConnectionState.retrySent.canTransition(to: .closing))
        XCTAssertTrue(QUICConnectionState.retryReceived.canTransition(to: .closing))
        XCTAssertTrue(QUICConnectionState.retrySent.canTransition(to: .versionSent))
    }

    func testAwaitingClientInitial() {
        for state in QUICConnectionState.allCases {
            XCTAssertEqual(
                state.isAwaitingClientInitial,
                state == .idle || state == .versionSent || state == .retrySent,
                "\(state)"
            )
        }
    }

    func testProcessingClientInitial() {
        for state in QUICConnectionState.allCases {
            XCTAssertEqual(
                state.isProcessingClientInitial,
                state == .initialReceived || state == .initialProcessed,
                "\(state)"
            )
        }
    }

    // MARK: On a connection

    /// Runs `body` with a connection that has been set up, so it starts out idle like a real one.
    func withConnection(isServer: Bool = false, _ body: (QUICConnection) -> Void) {
        let clock = TestClockContext("QUICConnectionStateTests")
        let connection = clock.onQueue { QUICConnection(context: clock.context) }
        defer { clock.onQueue { connection.destroyFromExternalTest() } }
        clock.onQueue {
            var parameters = Parameters()
            parameters.isServer = isServer
            try? connection.setup(remote: nil, local: nil, parameters: parameters, path: nil)
            XCTAssertEqual(connection.state, .idle)
            body(connection)
        }
    }

    // An invalid transition is logged but still takes effect.
    func testInvalidTransitionIsApplied() {
        withConnection { connection in
            connection.moveToConnectedFromExternalTest()
            XCTAssertEqual(connection.state, .connected)
            connection.state = .handshake
            XCTAssertEqual(connection.state, .handshake)
        }
    }

    func testHandshakeKeysMoveClientToHandshake() {
        withConnection { connection in
            connection.state = .initialSent
            connection.updateSecretForHandshakeLevel()
            XCTAssertEqual(connection.state, .handshake)
        }
    }

    func testHandshakeKeysMoveServerToHandshake() {
        for initialState in [QUICConnectionState.initialReceived, .initialProcessed] {
            withConnection(isServer: true) { connection in
                connection.state = .initialReceived
                if initialState == .initialProcessed {
                    connection.state = .initialProcessed
                }
                connection.updateSecretForHandshakeLevel()
                XCTAssertEqual(connection.state, .handshake, "\(initialState)")
            }
        }
    }
}

#endif
