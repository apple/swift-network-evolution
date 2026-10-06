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

    // A RETIRE_CONNECTION_ID frame only leaves the queue once it is sent, and nothing is sent
    // here. A peer that keeps supplying NEW_CONNECTION_ID frames below its own Retire Prior To
    // gets one queued per frame, so the connection has to close once the queue reaches twice the
    // active connection ID limit instead of letting it grow with the peer's frame count.
    func testRetireConnectionIDQueueIsCapped() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
            let newCID = QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!

            let path = self.makePath(dcid: oldCID, sequenceNumber: 0, used: true)
            self.connection.currentPath = path

            let retireLimit = 2 * self.connection.remoteCIDs.activeConnectionIDLimit
            let frameCount = UInt64(4 * retireLimit)

            let maxQueued = self.connection.fromExternal { eventContext in
                // Raise the retire threshold above every sequence number sent below.
                let rotation = FrameNewConnectionID(
                    sequence: frameCount + 1,
                    retirePriorToSequence: frameCount + 1,
                    connectionID: newCID,
                    statelessResetToken: QUICStatelessResetToken()
                )
                _ = self.connection.processNewConnectionIDFrame(rotation, in: &eventContext)

                var maxQueued = 0
                for sequence in 1...frameCount {
                    let frame = FrameNewConnectionID(
                        sequence: sequence,
                        retirePriorToSequence: 0,
                        connectionID: QUICConnectionID([0xC0, UInt8(sequence >> 8), UInt8(sequence & 0xFF)])!,
                        statelessResetToken: QUICStatelessResetToken()
                    )
                    guard self.connection.processNewConnectionIDFrame(frame, in: &eventContext) else {
                        break
                    }
                    maxQueued = max(
                        maxQueued,
                        self.connection.withPendingItemsForKeyState { $0.retireConnectionIDs.count }
                    )
                }
                return maxQueued
            }

            XCTAssertEqual(
                self.connection.closeError?.code,
                QUICTransportError.QUICTransportErrorCode.connectionIDLimitError.rawValue,
                "Connection should close with CONNECTION_ID_LIMIT_ERROR once the queue reaches the limit"
            )
            // The check runs before a frame queues anything, so the frame that arrives with the
            // queue at the limit closes the connection instead of being queued.
            XCTAssertEqual(
                maxQueued,
                retireLimit,
                "Queue should stop growing at the limit"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // Queues `count` RETIRE_CONNECTION_ID frames: one for the DCID in use, retired by a frame that
    // raises Retire Prior To to `threshold`, and one for each later frame below `threshold`.
    private func queueRetireConnectionIDs(
        count: Int,
        threshold: UInt64,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let rotation = FrameNewConnectionID(
            sequence: threshold,
            retirePriorToSequence: threshold,
            connectionID: QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!,
            statelessResetToken: QUICStatelessResetToken()
        )
        _ = connection.processNewConnectionIDFrame(rotation, in: &eventContext)
        for sequence in 1..<UInt64(count) {
            let frame = FrameNewConnectionID(
                sequence: sequence,
                retirePriorToSequence: 0,
                connectionID: QUICConnectionID([0xC0, UInt8(sequence)])!,
                statelessResetToken: QUICStatelessResetToken()
            )
            _ = connection.processNewConnectionIDFrame(frame, in: &eventContext)
        }
    }

    // With the queue at the limit, a NEW_CONNECTION_ID frame that retires nothing adds nothing
    // to it, so it has to be accepted instead of closing the connection.
    func testFrameRetiringNothingIsAcceptedAtRetireLimit() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
            let path = self.makePath(dcid: oldCID, sequenceNumber: 0, used: true)
            self.connection.currentPath = path

            let retireLimit = 2 * self.connection.remoteCIDs.activeConnectionIDLimit
            let threshold = UInt64(retireLimit) + 1

            let accepted = self.connection.fromExternal { eventContext in
                self.queueRetireConnectionIDs(count: retireLimit, threshold: threshold, in: &eventContext)
                let frame = FrameNewConnectionID(
                    sequence: threshold + 1,
                    retirePriorToSequence: threshold,
                    connectionID: QUICConnectionID([0xD1, 0xD2, 0xD3, 0xD4])!,
                    statelessResetToken: QUICStatelessResetToken()
                )
                return self.connection.processNewConnectionIDFrame(frame, in: &eventContext)
            }

            XCTAssertTrue(accepted, "A frame that retires nothing should be accepted")
            XCTAssertNil(self.connection.closeError, "Connection should stay open")
            XCTAssertEqual(
                self.connection.withPendingItemsForKeyState { $0.retireConnectionIDs.count },
                retireLimit,
                "Queue should stay at the limit"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // With the queue one below the limit, a NEW_CONNECTION_ID frame that retires two connection
    // IDs would take it past the limit, so the connection has to close before queueing either.
    func testFrameRetiringSeveralCannotOvershootRetireLimit() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
            let path = self.makePath(dcid: oldCID, sequenceNumber: 0, used: true)
            self.connection.currentPath = path

            let retireLimit = 2 * self.connection.remoteCIDs.activeConnectionIDLimit
            let threshold = UInt64(retireLimit) + 1

            let accepted = self.connection.fromExternal { eventContext in
                self.queueRetireConnectionIDs(count: retireLimit - 1, threshold: threshold, in: &eventContext)
                // A second active connection ID, next to the one the rotation frame supplied.
                let second = FrameNewConnectionID(
                    sequence: threshold + 1,
                    retirePriorToSequence: threshold,
                    connectionID: QUICConnectionID([0xD1, 0xD2, 0xD3, 0xD4])!,
                    statelessResetToken: QUICStatelessResetToken()
                )
                _ = self.connection.processNewConnectionIDFrame(second, in: &eventContext)
                let retiringBoth = FrameNewConnectionID(
                    sequence: threshold + 3,
                    retirePriorToSequence: threshold + 2,
                    connectionID: QUICConnectionID([0xE1, 0xE2, 0xE3, 0xE4])!,
                    statelessResetToken: QUICStatelessResetToken()
                )
                return self.connection.processNewConnectionIDFrame(retiringBoth, in: &eventContext)
            }

            XCTAssertFalse(accepted, "A frame that would take the queue past the limit should be rejected")
            XCTAssertEqual(
                self.connection.closeError?.code,
                QUICTransportError.QUICTransportErrorCode.connectionIDLimitError.rawValue,
                "Connection should close with CONNECTION_ID_LIMIT_ERROR"
            )
            // Closing drops the queue, so check the connection IDs the frame would have retired.
            XCTAssertEqual(
                self.connection.remoteCIDs.count,
                2,
                "Connection should close before retiring any connection ID"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
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
}

#endif
