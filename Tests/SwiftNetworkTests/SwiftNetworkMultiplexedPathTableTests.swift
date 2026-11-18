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
@testable @_spi(ProtocolProvider) import SwiftNetwork
#elseif canImport(Network)
@testable @_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkMultiplexedPathTableTests: XCTestCase {

    // Counts how many paths have been destroyed, so a test can tell whether the table destroyed a path
    // it should have handed back, or leaked one it should have destroyed.
    final class DeinitCounter {
        var count = 0
    }

    // A path that is bigger than a handful of words, like a real one
    struct TestPath: ~Copyable {
        var value: Int
        var padding = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let counter: DeinitCounter?

        init(value: Int, counter: DeinitCounter? = nil) {
            self.value = value
            self.counter = counter
        }

        deinit {
            counter?.count += 1
        }
    }

    func value(_ table: inout MultiplexedPathTable<TestPath>, _ pathID: MultiplexingPathIdentifier) -> Int? {
        table.withPath(pathID) { (path: inout TestPath) in path.value }
    }

    func testInsertAndBorrow() {
        var table = MultiplexedPathTable<TestPath>()
        XCTAssertTrue(table.isEmpty)
        table.insert(TestPath(value: 10), for: 1)
        table.insert(TestPath(value: 20), for: 2)
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(value(&table, 1), 10)
        XCTAssertEqual(value(&table, 2), 20)
        XCTAssertNil(value(&table, 3))
        XCTAssertTrue(table.contains(1))
        XCTAssertFalse(table.contains(3))
        XCTAssertEqual(table.firstPathIdentifier, 1)
        XCTAssertEqual(table.pathIdentifiers, [1, 2])
    }

    // The path is changed where it is, so a change made in one borrow is there in the next
    func testBorrowChangesThePathInPlace() {
        var table = MultiplexedPathTable<TestPath>()
        table.insert(TestPath(value: 1), for: 7)
        _ = table.withPath(7) { (path: inout TestPath) in path.value = 99 }
        XCTAssertEqual(value(&table, 7), 99)
    }

    // `XCTAssertNil` cannot look at a noncopyable path, so report the removed path's value instead
    func removedValue(_ table: inout MultiplexedPathTable<TestPath>, _ pathID: MultiplexingPathIdentifier) -> Int? {
        if let path = table.remove(pathID) {
            return path.value
        }
        return nil
    }

    func testRemoveHandsBackThePath() {
        let counter = DeinitCounter()
        var table = MultiplexedPathTable<TestPath>()
        table.insert(TestPath(value: 3, counter: counter), for: 1)
        var handedBack: Int?
        if let path = table.remove(1) {
            handedBack = path.value
            XCTAssertEqual(counter.count, 0, "Removing hands the path back, it does not destroy it")
        }
        XCTAssertEqual(handedBack, 3)
        XCTAssertEqual(counter.count, 1, "Dropping the path it was handed back destroys it")
        XCTAssertNil(value(&table, 1))
        XCTAssertFalse(table.contains(1))
        XCTAssertNil(removedValue(&table, 1))
    }

    // A removed path's entry is reused, and the paths in it are not mixed up
    func testEntriesAreReused() {
        var table = MultiplexedPathTable<TestPath>()
        table.insert(TestPath(value: 1), for: 1)
        table.insert(TestPath(value: 2), for: 2)
        _ = table.remove(1)
        table.insert(TestPath(value: 3), for: 3)
        XCTAssertNil(value(&table, 1))
        XCTAssertEqual(value(&table, 2), 2)
        XCTAssertEqual(value(&table, 3), 3)
        XCTAssertEqual(table.count, 2)
    }

    func testRemoveAllDestroysEveryPath() {
        let counter = DeinitCounter()
        var table = MultiplexedPathTable<TestPath>()
        for id in 1...5 { table.insert(TestPath(value: id, counter: counter), for: id) }
        table.removeAll()
        XCTAssertEqual(counter.count, 5)
        XCTAssertTrue(table.isEmpty)
        XCTAssertNil(value(&table, 3))
    }

    func testTableDestroysItsPathsWhenItGoes() {
        let counter = DeinitCounter()
        do {
            var table = MultiplexedPathTable<TestPath>()
            for id in 1...3 { table.insert(TestPath(value: id, counter: counter), for: id) }
            _ = table.remove(2)
        }
        // The removed path was handed back and dropped by `_`, the other two went with the table
        XCTAssertEqual(counter.count, 3)
    }

    func testForEachVisitsEveryLivePath() {
        var table = MultiplexedPathTable<TestPath>()
        table.insert(TestPath(value: 1), for: 1)
        table.insert(TestPath(value: 2), for: 2)
        table.insert(TestPath(value: 3), for: 3)
        _ = table.remove(2)
        var seen: [Int] = []
        table.forEachPath { (path: inout TestPath) in seen.append(path.value) }
        XCTAssertEqual(seen, [1, 3])
    }

    // An iteration covers each live path once, skips one removed before it gets there, visits one that takes
    // the place of a removed path, and does not visit one added past the end it started with. It does not
    // hold the table between steps.
    func testIterationSkipsRemovedPathsAndStopsAtItsEnd() {
        var table = MultiplexedPathTable<TestPath>()
        for id in 1...4 { table.insert(TestPath(value: id), for: id) }
        let end = table.entryCount
        var position = 0
        var seen: [Int] = []
        while let id = table.nextPathIdentifier(from: &position, before: end) {
            seen.append(id)
            // 3 is gone before the iteration reaches it
            if id == 1 { _ = table.remove(3) }
            // 9 takes the entry 3 left, which is still ahead of the iteration
            if id == 2 { table.insert(TestPath(value: 9), for: 9) }
            // 10 goes past the end the iteration started with
            if id == 4 { table.insert(TestPath(value: 10), for: 10) }
        }
        XCTAssertEqual(seen, [1, 2, 9, 4])
        XCTAssertEqual(table.pathIdentifiers.sorted(), [1, 2, 4, 9, 10])
    }

    // The entry that was lent out last is looked at first, and a hint that no longer fits is never trusted
    func testLookupFollowsTheLastPathLentAndSurvivesAStaleHint() {
        var table = MultiplexedPathTable<TestPath>()
        for id in 1...3 { table.insert(TestPath(value: id * 10), for: id) }
        XCTAssertEqual(value(&table, 3), 30)
        XCTAssertEqual(table.lastCachedPosition, 2)
        XCTAssertEqual(table.find(3), 2)
        XCTAssertEqual(value(&table, 1), 10)
        XCTAssertEqual(table.lastCachedPosition, 0)
        XCTAssertEqual(value(&table, 3), 30)

        // The hinted entry is removed and reused by another path: the old identifier is not found there
        XCTAssertEqual(table.lastCachedPosition, 2)
        _ = table.remove(3)
        XCTAssertNil(value(&table, 3))
        XCTAssertNil(table.find(3))
        table.insert(TestPath(value: 40), for: 4)
        XCTAssertEqual(table.find(4), 2)
        XCTAssertEqual(value(&table, 4), 40)
        XCTAssertEqual(value(&table, 2), 20)

        // A hint past the end of an emptied table is ignored
        XCTAssertEqual(table.lastCachedPosition, 1)
        table.removeAll()
        XCTAssertNil(table.find(2))
        table.insert(TestPath(value: 5), for: 5)
        XCTAssertEqual(value(&table, 5), 5)
    }
}
