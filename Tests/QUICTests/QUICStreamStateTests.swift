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
final class QUICSendStreamStateTests: XCTestCase {
    func testDefaultInitializedState() {
        let state = QUICSendStreamState()
        XCTAssertEqual(state, .invalid)
    }

    func checkAllowedStateTransitions(from: QUICSendStreamState, to: QUICSendStreamState) -> Bool {
        let allowedTransitions: [(from: QUICSendStreamState, to: QUICSendStreamState)] = [
            (from: .invalid, to: .ready),
            (from: .ready, to: .send),
            (from: .ready, to: .resetSent),
            (from: .send, to: .dataSent),
            (from: .send, to: .resetSent),
            (from: .dataSent, to: .resetSent),
            (from: .dataSent, to: .dataReceived),
            (from: .resetSent, to: .resetReceived),
            (from: .dataReceived, to: .resetSent),
        ]
        // If the combination (from state, to state) is the allowed list, then the result should be true, otherwise false
        for (allowedStartState, allowedDestinationState) in allowedTransitions {
            if allowedStartState == from && allowedDestinationState == to {
                return true
            }
        }
        return false
    }

    func testValidStateChanges() {
        // Check all state transition combinations
        for startState in QUICSendStreamState.allCases {
            for destinationState in QUICSendStreamState.allCases {
                let state = QUICSendStreamState(state: startState)
                let result = state.isValidStateChange(logIDString: "stream", to: destinationState)
                let expected = checkAllowedStateTransitions(from: startState, to: destinationState)

                XCTAssertEqual(
                    result,
                    expected,
                    "Check state transition from \(startState) to \(destinationState)"
                )
            }
        }
    }

    func testChangingState() {
        var state = QUICSendStreamState()
        for newState in QUICSendStreamState.allCases {
            // Currently there are not restrictions for how states can change
            // The disallowed state changes only cause log messages
            state.change(logIDString: "stream", to: newState)
            XCTAssertEqual(state, newState)
        }
    }
}

@available(Network 0.1.0, *)
final class QUICReceiveStreamStateTests: XCTestCase {
    func testDefaultInitialState() {
        let state = QUICReceiveStreamState()
        XCTAssertEqual(state, .invalid)
    }

    func checkAllowedStateTransitions(
        from: QUICReceiveStreamState,
        to: QUICReceiveStreamState
    ) -> Bool {
        let allowedTransitions: [(QUICReceiveStreamState, QUICReceiveStreamState)] = [
            (from: .invalid, to: .receive),
            (from: .receive, to: .sizeKnown),
            (from: .receive, to: .resetReceived),
            (from: .sizeKnown, to: .dataReceived),
            (from: .sizeKnown, to: .resetReceived),
            (from: .dataReceived, to: .dataRead),
            (from: .dataReceived, to: .resetReceived),
            (from: .resetReceived, to: .dataReceived),
            (from: .resetReceived, to: .resetRead),
        ]
        // If the combination (from state, to state) is the allowed list, then the result should be true, otherwise false
        for (allowedStartState, allowedDestinationState) in allowedTransitions {
            if allowedStartState == from && allowedDestinationState == to {
                return true
            }
        }
        return false
    }

    func testValidStateChanges() {
        for startState in QUICReceiveStreamState.allCases {
            for destinationState in QUICReceiveStreamState.allCases {
                let state = QUICReceiveStreamState(state: startState)
                let result = state.isValidStateChange(logIDString: "stream", to: destinationState)
                let expected = checkAllowedStateTransitions(from: startState, to: destinationState)

                XCTAssertEqual(
                    result,
                    expected,
                    "Check state transition from \(startState) to \(destinationState)"
                )
            }
        }
    }

    func testChangingState() {
        var state = QUICReceiveStreamState()
        for newState in QUICReceiveStreamState.allCases {
            // Currently there are not restrictions for how states can change
            // The disallowed state changes only cause log messages
            state.change(logIDString: "stream", to: newState)
            XCTAssertEqual(state, newState)
        }
    }
}

#endif
