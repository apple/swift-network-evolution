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

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

final class QUICPathStateTests: XCTestCase {
    func testDefaultInitializedState() {
        let state = QUICPathState()
        XCTAssertEqual(state, .invalid)
    }

    func checkAllowedStateTransitions(from: QUICPathState, to: QUICPathState) -> Bool {
        let allowedQUICPathStateTransitions: [(from: QUICPathState, to: QUICPathState)] = [
            (from: .invalid, to: .routeAvailable),
            (from: .invalid, to: .routeEstablished),

            (from: .routeAvailable, to: .routeEstablished),

            (from: .routeEstablished, to: .cidAssigned),

            (from: .cidAssigned, to: .probing),

            (from: .probing, to: .validated),
            (from: .probing, to: .unreachable),

            (from: .validated, to: .routeEstablished),  // CID retirement
            (from: .validated, to: .probing),  //  endpoint can re-probe at path at any time RFC9000:8.2:p4
            // Path marked as unreachable so that we avoid using it.
            (from: .validated, to: .unreachable),
            (from: .validated, to: .closing),

            (from: .unreachable, to: .closing),

            // The path can disappear at any time. Except when marked invalid (should just be deleted)
            (from: .routeAvailable, to: .routeUnavailable),
            (from: .routeEstablished, to: .routeUnavailable),
            (from: .cidAssigned, to: .routeUnavailable),
            (from: .probing, to: .routeUnavailable),
            (from: .validated, to: .routeUnavailable),
            (from: .closing, to: .routeUnavailable),
            (from: .unreachable, to: .routeUnavailable),
        ]

        for (allowedStartState, allowedDestinationState) in allowedQUICPathStateTransitions {
            if allowedStartState == from && allowedDestinationState == to {
                return true
            }
        }
        return false
    }

    func testValidStateChanges() {
        // Check all state transition combinations
        for startState in QUICPathState.allCases {
            for destinationState in QUICPathState.allCases {
                let state = QUICPathState(state: startState)
                let result = state.isValidStateChange(to: destinationState)
                let expected = checkAllowedStateTransitions(from: startState, to: destinationState)

                // If the combination (startState, destinationState) is the allowed list, then the result should be true, otherwise false
                if result != expected {
                    XCTFail("Unexpected state transition from \(startState) to \(destinationState)")
                }
                XCTAssertEqual(
                    result,
                    expected,
                    "Check state transition from \(startState) to \(destinationState)"
                )
            }
        }
    }

    func testMethods() {
        let state = QUICPathState(state: .routeUnavailable)
        XCTAssertFalse(state.isOpenForSending)
        XCTAssertFalse(state.isInvalid)
        XCTAssertFalse(state.isValidated)
        XCTAssertFalse(state.isProbing)
        XCTAssertTrue(state.isUnusable)
        let state2 = QUICPathState(state: .unreachable)
        XCTAssertTrue(state2.isUnusable)
        let state3 = QUICPathState(state: .validated)
        XCTAssertTrue(state3.isOpenForSending)
    }
}

#endif
