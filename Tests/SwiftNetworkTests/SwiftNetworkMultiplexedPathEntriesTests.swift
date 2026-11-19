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
final class SwiftNetworkMultiplexedPathEntriesTests: XCTestCase {

    // Counts how many paths have been destroyed, so a test can tell whether the entries destroyed a path
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

    func value(_ entries: inout MultiplexedPathEntries<TestPath>, _ pathID: MultiplexingPathIdentifier) -> Int? {
        entries.withPath(pathID) { (path: inout TestPath) in path.value }
    }

    func testInsertAndBorrow() {
        var entries = MultiplexedPathEntries<TestPath>()
        XCTAssertTrue(entries.isEmpty)
        entries.insert(TestPath(value: 10), for: 1)
        entries.insert(TestPath(value: 20), for: 2)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(value(&entries, 1), 10)
        XCTAssertEqual(value(&entries, 2), 20)
        XCTAssertNil(value(&entries, 3))
        XCTAssertTrue(entries.contains(1))
        XCTAssertFalse(entries.contains(3))
        XCTAssertEqual(entries.firstPathIdentifier, 1)
        XCTAssertEqual(entries.pathIdentifiers, [1, 2])
    }

    // The path is changed where it is, so a change made in one borrow is there in the next
    func testBorrowChangesThePathInPlace() {
        var entries = MultiplexedPathEntries<TestPath>()
        entries.insert(TestPath(value: 1), for: 7)
        _ = entries.withPath(7) { (path: inout TestPath) in path.value = 99 }
        XCTAssertEqual(value(&entries, 7), 99)
    }

    // `XCTAssertNil` cannot look at a noncopyable path, so report the removed path's value instead
    func removedValue(_ entries: inout MultiplexedPathEntries<TestPath>, _ pathID: MultiplexingPathIdentifier) -> Int? {
        if let path = entries.remove(pathID) {
            return path.value
        }
        return nil
    }

    func testRemoveHandsBackThePath() {
        let counter = DeinitCounter()
        var entries = MultiplexedPathEntries<TestPath>()
        entries.insert(TestPath(value: 3, counter: counter), for: 1)
        var handedBack: Int?
        if let path = entries.remove(1) {
            handedBack = path.value
            XCTAssertEqual(counter.count, 0, "Removing hands the path back, it does not destroy it")
        }
        XCTAssertEqual(handedBack, 3)
        XCTAssertEqual(counter.count, 1, "Dropping the path it was handed back destroys it")
        XCTAssertNil(value(&entries, 1))
        XCTAssertFalse(entries.contains(1))
        XCTAssertNil(removedValue(&entries, 1))
    }

    // A removed path's entry is reused, and the paths in it are not mixed up
    func testEntriesAreReused() {
        var entries = MultiplexedPathEntries<TestPath>()
        entries.insert(TestPath(value: 1), for: 1)
        entries.insert(TestPath(value: 2), for: 2)
        _ = entries.remove(1)
        entries.insert(TestPath(value: 3), for: 3)
        XCTAssertNil(value(&entries, 1))
        XCTAssertEqual(value(&entries, 2), 2)
        XCTAssertEqual(value(&entries, 3), 3)
        XCTAssertEqual(entries.count, 2)
    }

    func testRemoveAllDestroysEveryPath() {
        let counter = DeinitCounter()
        var entries = MultiplexedPathEntries<TestPath>()
        for id in 1...5 { entries.insert(TestPath(value: id, counter: counter), for: id) }
        entries.removeAll()
        XCTAssertEqual(counter.count, 5)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(value(&entries, 3))
    }

    func testEntriesDestroyTheirPathsWhenTheyGo() {
        let counter = DeinitCounter()
        do {
            var entries = MultiplexedPathEntries<TestPath>()
            for id in 1...3 { entries.insert(TestPath(value: id, counter: counter), for: id) }
            _ = entries.remove(2)
        }
        // The removed path was handed back and dropped by `_`, the other two went with the entries
        XCTAssertEqual(counter.count, 3)
    }

    func testForEachVisitsEveryLivePath() {
        var entries = MultiplexedPathEntries<TestPath>()
        entries.insert(TestPath(value: 1), for: 1)
        entries.insert(TestPath(value: 2), for: 2)
        entries.insert(TestPath(value: 3), for: 3)
        _ = entries.remove(2)
        var seen: [Int] = []
        entries.forEachPath { (path: inout TestPath) in seen.append(path.value) }
        XCTAssertEqual(seen, [1, 3])
    }

    // An iteration covers each live path once, skips one removed before it gets there, visits one that takes
    // the place of a removed path, and does not visit one added past the end it started with. It does not
    // hold the entries between steps.
    func testIterationSkipsRemovedPathsAndStopsAtItsEnd() {
        var entries = MultiplexedPathEntries<TestPath>()
        for id in 1...4 { entries.insert(TestPath(value: id), for: id) }
        let end = entries.entryCount
        var position = 0
        var seen: [Int] = []
        while let id = entries.nextPathIdentifier(from: &position, before: end) {
            seen.append(id)
            // 3 is gone before the iteration reaches it
            if id == 1 { _ = entries.remove(3) }
            // 9 takes the entry 3 left, which is still ahead of the iteration
            if id == 2 { entries.insert(TestPath(value: 9), for: 9) }
            // 10 goes past the end the iteration started with
            if id == 4 { entries.insert(TestPath(value: 10), for: 10) }
        }
        XCTAssertEqual(seen, [1, 2, 9, 4])
        XCTAssertEqual(entries.pathIdentifiers.sorted(), [1, 2, 4, 9, 10])
    }

    // The entry that was lent out last is looked at first, and a hint that no longer fits is never trusted
    func testLookupFollowsTheLastPathLentAndSurvivesAStaleHint() {
        var entries = MultiplexedPathEntries<TestPath>()
        for id in 1...3 { entries.insert(TestPath(value: id * 10), for: id) }
        XCTAssertEqual(value(&entries, 3), 30)
        XCTAssertEqual(entries.lastCachedPosition, 2)
        XCTAssertEqual(entries.find(3), 2)
        XCTAssertEqual(value(&entries, 1), 10)
        XCTAssertEqual(entries.lastCachedPosition, 0)
        XCTAssertEqual(value(&entries, 3), 30)

        // The hinted entry is removed and reused by another path: the old identifier is not found there
        XCTAssertEqual(entries.lastCachedPosition, 2)
        _ = entries.remove(3)
        XCTAssertNil(value(&entries, 3))
        XCTAssertNil(entries.find(3))
        entries.insert(TestPath(value: 40), for: 4)
        XCTAssertEqual(entries.find(4), 2)
        XCTAssertEqual(value(&entries, 4), 40)
        XCTAssertEqual(value(&entries, 2), 20)

        // A hint past the end of emptied entries is ignored
        XCTAssertEqual(entries.lastCachedPosition, 1)
        entries.removeAll()
        XCTAssertNil(entries.find(2))
        entries.insert(TestPath(value: 5), for: 5)
        XCTAssertEqual(value(&entries, 5), 5)
    }
}
