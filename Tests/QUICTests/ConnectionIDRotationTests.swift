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

@available(Network 0.1.0, *)
let connectionIDRotationTestsLogPrefixer: LogPrefixer = LogPrefixer("[ConnectionIDRotationTests]")

@available(Network 0.1.0, *)
final class ConnectionIDRotationTests: XCTestCase {
    var connection = QUICConnection(context: .implicitContext)

    override func setUp() {
        let expectation = XCTestExpectation()
        connection.context.async {
            try? self.connection.setup(remote: nil, local: nil, parameters: nil, path: nil)
            self.connection.recovery = Recovery(logPrefixer: connectionIDRotationTestsLogPrefixer)
            self.connection.recovery.connection = self.connection
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    override func tearDown() {
        self.connection.currentPath = nil
        // The paths built by `makePath` outlive the test body, so release them.
        self.connection.context.onQueue {
            for path in self.connection.multiplexingPaths.values {
                path.destroyFromExternalTest()
            }
        }
        self.connection.multiplexingPaths.removeAll()
    }

    // Builds a path with `dcid` assigned and registered in `remoteCIDs`, so it mirrors an active
    // path using that CID. Processing NEW_CONNECTION_ID frames doesn't send anything, so the path
    // needs no lower protocol. The path is registered in `multiplexingPaths` so `tearDown`
    // releases it.
    private func makePath(dcid: QUICConnectionID, sequenceNumber: UInt64, used: Bool) -> QUICPath {
        // Every caller builds its paths from inside `context.async`, so this runs on the context.
        let path = QUICPath.makeFromExternalTest(parent: self.connection)
        path.set(interface: nil, priority: 1, isInitial: true)  // -> .routeEstablished
        connection.fromExternal { eventContext in
            path.assignDCID(dcid, in: &eventContext)  // -> .cidAssigned (open for sending)
        }
        try? connection.remoteCIDs.insert(
            sequenceNumber: sequenceNumber,
            connectionID: dcid,
            token: QUICStatelessResetToken(),
            used: used
        )
        connection.multiplexingPaths[path.pathIdentifier] = path
        return path
    }

    // The peer issues seq 1-3, but loss drops those NEW_CONNECTION_ID frames, so remoteCIDs holds
    // only the in-use seq 0 when the rotation frame (seq=4, retirePriorTo=1) arrives. Retiring
    // seq 0 leaves only the CID carried by that frame, so the path has to move to it instead of
    // the connection closing for lack of a DCID.
    func testStarvedPoolRotationUsesReplacementFromSameFrame() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
            let newCID = QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!

            let path = self.makePath(dcid: oldCID, sequenceNumber: 0, used: true)
            self.connection.currentPath = path

            XCTAssertEqual(
                self.connection.remoteCIDs.count,
                1,
                "Pool should start starved down to just the in-use CID"
            )

            let frame = FrameNewConnectionID(
                sequence: 4,
                retirePriorToSequence: 1,
                connectionID: newCID,
                statelessResetToken: QUICStatelessResetToken()
            )
            self.connection.fromExternal { eventContext in
                _ = self.connection.processNewConnectionIDFrame(frame, in: &eventContext)
            }

            XCTAssertNil(
                self.connection.closeError,
                "Connection fatally closed instead of using the CID its own frame supplied"
            )
            XCTAssertEqual(
                self.connection.currentPath?.dcid,
                newCID,
                "Path should be re-pointed to the new CID"
            )
            XCTAssertEqual(
                self.connection.remoteCIDs.count,
                1,
                "Pool should hold exactly the new CID after rotation"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // RFC 9000 5.1.1: a NEW_CONNECTION_ID frame that takes the active CID count past the advertised
    // active_connection_id_limit, without retiring anything, must close the connection with
    // CONNECTION_ID_LIMIT_ERROR. Filling the pool to the limit, or repeating a frame, must not.
    func testNewConnectionIDOverLimitClosesConnection() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!, sequenceNumber: 0, used: true)
            self.connection.currentPath = path
            self.connection.remoteCIDs.activeConnectionIDLimit = 2

            let atLimit = FrameNewConnectionID(
                sequence: 1,
                retirePriorToSequence: 0,
                connectionID: QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!,
                statelessResetToken: QUICStatelessResetToken()
            )
            let overLimit = FrameNewConnectionID(
                sequence: 2,
                retirePriorToSequence: 0,
                connectionID: QUICConnectionID([0xC1, 0xC2, 0xC3, 0xC4])!,
                statelessResetToken: QUICStatelessResetToken()
            )

            self.connection.fromExternal { eventContext in
                XCTAssertTrue(self.connection.processNewConnectionIDFrame(atLimit, in: &eventContext))
                XCTAssertTrue(self.connection.processNewConnectionIDFrame(atLimit, in: &eventContext))
            }
            XCTAssertNil(self.connection.closeError, "Reaching the limit, or a repeated frame, is not an error")
            XCTAssertEqual(self.connection.remoteCIDs.count, 2)

            self.connection.fromExternal { eventContext in
                XCTAssertFalse(self.connection.processNewConnectionIDFrame(overLimit, in: &eventContext))
            }
            XCTAssertEqual(
                self.connection.closeError?.code,
                QUICTransportError.QUICTransportErrorCode.connectionIDLimitError.rawValue,
                "Exceeding the limit should close with CONNECTION_ID_LIMIT_ERROR"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
