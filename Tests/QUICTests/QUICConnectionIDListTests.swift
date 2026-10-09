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
class QUICConnectionIDListTests: XCTestCase {
    var list = QUICConnectionIDList()

    override func setUp() {
        list = QUICConnectionIDList()
    }

    func testIsEmpty() {
        XCTAssertTrue(list.isEmpty)
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 1,
                connectionID: QUICConnectionID(5),
                token: QUICStatelessResetToken()
            )
        )
        XCTAssertFalse(list.isEmpty)
    }

    func testInsert() {
        let cids = [QUICConnectionID(5), QUICConnectionID(10)]
        XCTAssertEqual(list.count, 0)
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 1,
                connectionID: cids[0],
                token: QUICStatelessResetToken()
            )
        )
        XCTAssertEqual(list.count, 1)
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 2,
                connectionID: cids[1],
                token: QUICStatelessResetToken()
            )
        )
        XCTAssertEqual(list.count, 2)
    }

    func testDuplicate() {
        let c1 = QUICConnectionID(5)
        XCTAssertNoThrow(
            try list.insert(sequenceNumber: 1, connectionID: c1, token: QUICStatelessResetToken())
        )
        XCTAssertThrowsError(
            try list.insert(sequenceNumber: 1, connectionID: c1, token: QUICStatelessResetToken())
        )
        XCTAssertEqual(list.count, 1)
        XCTAssertThrowsError(
            try list.insert(sequenceNumber: 2, connectionID: c1, token: QUICStatelessResetToken())
        )
        XCTAssertEqual(list.count, 1)
    }

    func testFindBySequenceNumber() {
        var cids: [QUICConnectionID] = []
        let initialCID = QUICConnectionID(8)
        XCTAssertNoThrow(
            try list.insertInitialConnectionID(initialCID)
        )
        cids.append(initialCID)
        let maxCIDs = 5
        for sequenceNumber in 1...maxCIDs {
            let cid = QUICConnectionID(8)  // cid size 8
            cids.append(cid)
            XCTAssertNoThrow(
                try list.insert(
                    sequenceNumber: UInt64(sequenceNumber),
                    connectionID: cid,
                    token: QUICStatelessResetToken()
                )
            )
        }
        for sequenceNumber in 0...maxCIDs {
            let foundCID = list.find(sequenceNumber: UInt64(sequenceNumber))
            XCTAssertNotNil(foundCID)
            XCTAssertTrue(foundCID!.connectionID == cids[sequenceNumber])
        }
    }

    func testFindByConnectionID() {
        let c1 = QUICConnectionID(5)
        XCTAssertNoThrow(
            try list.insert(sequenceNumber: 10, connectionID: c1, token: QUICStatelessResetToken())
        )
        XCTAssertNotNil(list.find(connectionID: c1))
    }

    func testRetirePriorTo() {
        var cids: [QUICConnectionID] = []
        let initialCID = QUICConnectionID(8)
        XCTAssertNoThrow(
            try list.insertInitialConnectionID(initialCID)
        )
        cids.append(initialCID)
        let maxCIDs = 5
        for sequenceNumber in 1...maxCIDs {
            let cid = QUICConnectionID(8)  // cid size 8
            cids.append(cid)
            XCTAssertNoThrow(
                try list.insert(
                    sequenceNumber: UInt64(sequenceNumber),
                    connectionID: QUICConnectionID(5),
                    token: QUICStatelessResetToken()
                )
            )
        }
        let retiredCIDs = list.retire(priorTo: UInt64(maxCIDs + 1))
        XCTAssertNotNil(retiredCIDs)
        XCTAssertEqual(retiredCIDs.count, 6)
        XCTAssertTrue(list.isEmpty)
    }

    func testRetireConnectionID() {
        let c1 = QUICConnectionID(5)
        XCTAssertNoThrow(
            try list.insert(sequenceNumber: 10, connectionID: c1, token: QUICStatelessResetToken())
        )
        list.retire(connectionID: c1)
        XCTAssertTrue(list.isEmpty)
        list.retire(connectionID: c1)
    }

    func testIterator() {
        XCTAssertNil(list.next())
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 1,
                connectionID: QUICConnectionID(5),
                token: QUICStatelessResetToken()
            )
        )
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 2,
                connectionID: QUICConnectionID(5),
                token: QUICStatelessResetToken()
            )
        )
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 3,
                connectionID: QUICConnectionID(5),
                token: QUICStatelessResetToken()
            )
        )

        var iterations = 0
        for mc in list {
            XCTAssert(mc.sequenceNumber >= 1 && mc.sequenceNumber <= 3)
            XCTAssertEqual(mc.connectionID.length, 5)
            iterations += 1
        }
        XCTAssertEqual(iterations, list.count)

        // Repeat the loop twice to make sure the iterator resets back to 0.
        iterations = 0
        for mc in list {
            XCTAssert(mc.sequenceNumber >= 1 && mc.sequenceNumber <= 3)
            XCTAssertEqual(mc.connectionID.length, 5)
            iterations += 1
        }
        XCTAssertEqual(iterations, list.count)

    }

    func testInsertInitial() {
        verifyInitialState()

        // Insert an initial CID without a Stateless Reset Token (SRT)
        XCTAssertNoThrow(
            try list.insertInitialConnectionID(QUICConnectionID([0])!)
        )
        XCTAssertEqual(list.count, 1)

        // Insert a non-matching CID
        XCTAssertNoThrow(
            try list.insert(
                sequenceNumber: 1,
                connectionID: QUICConnectionID([5])!,
                token: QUICStatelessResetToken()
            )
        )
        XCTAssertEqual(list.count, 2)

        // Insert an updated initial connection id, including a SRT
        XCTAssertNoThrow(
            try list
                .insert(
                    sequenceNumber: 0,
                    connectionID: QUICConnectionID([0])!,
                    token: QUICStatelessResetToken(),
                    used: true
                )
        )
        XCTAssertEqual(list.count, 2)  // count remains the same
    }

    func testFindInitial() {
        let initialCID = QUICConnectionID([0])!
        verifyInitialState()

        XCTAssertNoThrow(
            try list.insertInitialConnectionID(initialCID)
        )
        XCTAssertEqual(list.count, 1)

        XCTAssertNil(list.find(connectionID: QUICConnectionID([1])!))
        let result = list.find(connectionID: initialCID)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.connectionID == initialCID)
    }

    func testRetireInitialBySequenceNumber() {
        let c1 = QUICConnectionID(5)
        let sequenceNumber = UInt64(0)
        XCTAssertNoThrow(
            try list.insertInitialConnectionID(c1)
        )
        XCTAssertEqual(list.count, 1)

        _ = list.retire(sequenceNumber: sequenceNumber)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.count, 0)
    }

    func testRetireInitialByConnectionID() {
        let c1 = QUICConnectionID(5)
        XCTAssertNoThrow(
            try list.insertInitialConnectionID(c1)
        )
        XCTAssertEqual(list.count, 1)

        list.retire(connectionID: c1)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.count, 0)
    }

    func verifyInitialState() {
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.count, 0)
    }
}

#endif
