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
@testable import SwiftNetwork
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkGappyArrayTests: XCTestCase {

    struct GappyElement: ~Copyable {
        let value: Int
        init(value: Int) {
            self.value = value
        }
    }

    func testAdding() throws {
        var ga = NetworkGappyArray<GappyElement>()
        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)

        let first = GappyElement(value: 1)
        _ = ga.insert(first)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 1)

        let second = GappyElement(value: 2)
        _ = ga.insert(second)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 2)

        let third = GappyElement(value: 3)
        _ = ga.insert(third)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 3)
    }

    func testRemovingFromStart() throws {
        var ga = NetworkGappyArray<GappyElement>()
        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)

        let first = GappyElement(value: 1)
        let firstIndex = ga.insert(first)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 1)

        let second = GappyElement(value: 2)
        let secondIndex = ga.insert(second)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 2)

        let third = GappyElement(value: 3)
        let thirdIndex = ga.insert(third)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 3)

        ga.remove(index: firstIndex)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 2)

        ga.remove(index: secondIndex)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 1)

        ga.remove(index: thirdIndex)
        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)
    }

    func testRemovingFromEnd() throws {
        var ga = NetworkGappyArray<GappyElement>()
        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)

        let first = GappyElement(value: 1)
        let firstIndex = ga.insert(first)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 1)

        let second = GappyElement(value: 2)
        let secondIndex = ga.insert(second)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 2)

        let third = GappyElement(value: 3)
        let thirdIndex = ga.insert(third)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 3)

        ga.remove(index: thirdIndex)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 2)

        ga.remove(index: secondIndex)
        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 1)

        ga.remove(index: firstIndex)
        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)
    }

    func testRandomAddAndRemove() throws {
        var ga = NetworkGappyArray<GappyElement>()
        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)

        // Add 50 elements
        var indices = [NetworkStateIndex]()
        for i in 1...50 {
            let element = GappyElement(value: i)
            let newIndex = ga.insert(element)
            indices.append(newIndex)
        }

        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 50)

        // Remove random 25 elements
        indices.shuffle()
        for _ in 1...25 {
            let indexToRemove = indices.popLast()!
            ga.remove(index: indexToRemove)
        }

        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 25)

        // Add 75 elements
        for i in 1...75 {
            let element = GappyElement(value: i)
            let newIndex = ga.insert(element)
            indices.append(newIndex)
        }

        XCTAssertTrue(!ga.isEmpty)
        XCTAssertEqual(ga.count, 100)

        // Remove all elements in random order
        indices.shuffle()
        for index in indices {
            ga.remove(index: index)
        }

        XCTAssertTrue(ga.isEmpty)
        XCTAssertEqual(ga.count, 0)
    }

    func testNoneIsNeverIssued() throws {
        var ga = NetworkGappyArray<GappyElement>()
        XCTAssertTrue(NetworkStateIndex.none.isNone)

        for i in 1...20 {
            let index = ga.insert(GappyElement(value: i))
            XCTAssertFalse(index.isNone)
            XCTAssertNotEqual(index, .none)
            XCTAssertNotEqual(index.rawValue, 0)
        }
    }

    // The generation is a UInt32 that wraps, and zero is reserved for `.none`. Crossing the wrap
    // boundary must skip zero, or a live index would compare equal to `.none`.
    func testGenerationWrapSkipsNone() throws {
        var ga = NetworkGappyArray<GappyElement>()
        ga.setGenerationForTesting(.max - 1)

        // Last generation before wrapping.
        let beforeWrap = ga.insert(GappyElement(value: 1))
        XCTAssertFalse(beforeWrap.isNone)

        // This insertion wraps the counter, which must land on 1 rather than 0.
        let afterWrap = ga.insert(GappyElement(value: 2))
        XCTAssertFalse(afterWrap.isNone)
        XCTAssertNotEqual(afterWrap, .none)
        XCTAssertNotEqual(afterWrap, beforeWrap)

        // Slot 0 wrapped to generation 1, so the raw value is just the slot.
        let next = ga.insert(GappyElement(value: 3))
        XCTAssertFalse(next.isNone)
        XCTAssertNotEqual(next, afterWrap)
    }

    // A slot reused after removal must produce an index distinct from the one it replaced, so a
    // stale index is never mistaken for the new occupant.
    func testReusedSlotGetsDistinctIndex() throws {
        var ga = NetworkGappyArray<GappyElement>()

        // Three elements, so removing the middle one leaves a gap rather than trimming the end.
        let first = ga.insert(GappyElement(value: 1))
        let second = ga.insert(GappyElement(value: 2))
        let third = ga.insert(GappyElement(value: 3))

        ga.remove(index: second)
        let reused = ga.insert(GappyElement(value: 4))

        XCTAssertNotEqual(reused, second)
        XCTAssertNotEqual(reused.rawValue, second.rawValue)
        XCTAssertEqual(ga[reused].value, 4)

        // The untouched indices still address their original elements.
        XCTAssertEqual(ga[first].value, 1)
        XCTAssertEqual(ga[third].value, 3)
    }

    // Gaps are reused in any order, and trimming trailing empty slots must forget exactly the gaps
    // that no longer exist: every surviving element stays addressable, no live slot is handed out
    // twice, and the count stays exact.
    func testGapReuseAndTrimKeepElementsIntact() throws {
        var ga = NetworkGappyArray<GappyElement>()
        var live = [Int: NetworkStateIndex]()
        var nextValue = 0
        func add() {
            nextValue += 1
            live[nextValue] = ga.insert(GappyElement(value: nextValue))
        }

        for _ in 0..<40 { add() }
        // Free every other element, then the tail, so there are interior gaps and a trim.
        for value in live.keys.sorted() where value % 2 == 0 {
            ga.remove(index: live.removeValue(forKey: value)!)
        }
        for value in live.keys.sorted().suffix(10) {
            ga.remove(index: live.removeValue(forKey: value)!)
        }
        XCTAssertEqual(ga.count, live.count)

        for _ in 0..<30 { add() }
        XCTAssertEqual(ga.count, live.count)
        for (value, index) in live {
            XCTAssertEqual(ga[index].value, value)
        }

        // No two live elements share a slot
        XCTAssertEqual(Set(live.values.map { $0.rawValue & 0xFFFF_FFFF }).count, live.count)

        for index in live.values { ga.remove(index: index) }
        XCTAssertTrue(ga.isEmpty)
    }

    // `take` hands back the value, or `nil` if there was nothing at the index. `XCTAssertNil` cannot
    // look at a noncopyable element, so report the element's value instead.
    func took(_ ga: inout NetworkGappyArray<GappyElement>, _ index: NetworkStateIndex) -> Int? {
        if let element = ga.take(index: index) {
            return element.value
        }
        return nil
    }

    // Removing an index that was already removed must change nothing. If it recorded the slot as
    // free a second time, two later inserts would be given the same slot and the first element
    // would be overwritten and destroyed.
    func testRemovingTheSameIndexTwiceDoesNotCorruptTheFreeSlots() throws {
        var ga = NetworkGappyArray<GappyElement>()
        let indices = (1...5).map { ga.insert(GappyElement(value: $0)) }

        XCTAssertEqual(took(&ga, indices[2]), 3)
        XCTAssertEqual(ga.count, 4)
        // The second removal finds nothing and leaves the array as it was
        XCTAssertNil(took(&ga, indices[2]))
        XCTAssertEqual(ga.count, 4)

        // Two inserts fill the one gap and then grow the array: they must not share a slot
        let first = ga.insert(GappyElement(value: 100))
        let second = ga.insert(GappyElement(value: 200))
        XCTAssertEqual(ga.count, 6)
        XCTAssertEqual(ga[first].value, 100)
        XCTAssertEqual(ga[second].value, 200)
        for (position, expected) in [(0, 1), (1, 2), (3, 4), (4, 5)] {
            XCTAssertEqual(ga[indices[position]].value, expected)
        }
    }

    func testTakingAnEmptySlotReturnsNil() throws {
        var ga = NetworkGappyArray<GappyElement>()
        let indices = (1...4).map { ga.insert(GappyElement(value: $0)) }
        XCTAssertEqual(took(&ga, indices[1]), 2)
        XCTAssertNil(took(&ga, indices[1]))
        XCTAssertNil(took(&ga, indices[1]))
        XCTAssertEqual(ga.count, 3)
        // And the array still works
        let added = ga.insert(GappyElement(value: 9))
        XCTAssertEqual(ga[added].value, 9)
        XCTAssertEqual(ga.count, 4)
    }

    // Removing the last slot leaves an empty slot behind it when that one was already free. Removing
    // that slot again must not record a free slot beyond the end of the array, which the next insert
    // would pop and write to.
    func testRemovingAFreedSlotThatIsNowLastDoesNotLeaveAFreeSlotPastTheEnd() throws {
        var ga = NetworkGappyArray<GappyElement>()
        // Enough elements that a single gap is too small a share to trim the array
        let indices = (0..<100).map { ga.insert(GappyElement(value: $0)) }
        XCTAssertEqual(took(&ga, indices[98]), 98)
        XCTAssertEqual(took(&ga, indices[99]), 99)
        XCTAssertEqual(ga.count, 98)

        // Slot 98 is free and is now the last slot. Removing it again finds nothing.
        XCTAssertNil(took(&ga, indices[98]))
        XCTAssertEqual(ga.count, 98)

        let added = (0..<3).map { ga.insert(GappyElement(value: 1000 + $0)) }
        XCTAssertEqual(ga.count, 101)
        for (offset, index) in added.enumerated() {
            XCTAssertEqual(ga[index].value, 1000 + offset)
        }
        for position in 0..<98 {
            XCTAssertEqual(ga[indices[position]].value, position)
        }
    }

    // An index for a slot that no longer exists, because the array was trimmed, finds nothing.
    func testTakingAnIndexPastTheEndReturnsNil() throws {
        var ga = NetworkGappyArray<GappyElement>()
        let indices = (1...3).map { ga.insert(GappyElement(value: $0)) }
        XCTAssertEqual(took(&ga, indices[2]), 3)
        XCTAssertEqual(took(&ga, indices[1]), 2)
        XCTAssertNil(took(&ga, indices[2]))
        XCTAssertNil(took(&ga, indices[1]))
        XCTAssertEqual(ga.count, 1)
        XCTAssertEqual(ga[indices[0]].value, 1)
    }

    // `NetworkStateIndex` exists to fit in a single 64-bit word, and to need no `Optional`.
    func testIndexFitsInOneWord() throws {
        XCTAssertEqual(MemoryLayout<NetworkStateIndex>.size, 8)
        XCTAssertEqual(MemoryLayout<NetworkStateIndex>.stride, 8)
    }
}
