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
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkMultiplexedFlowTableTests: XCTestCase {

    // Counts how many flows have been destroyed, so a test can tell whether the table destroyed a
    // flow it should have handed back, or leaked one it should have destroyed.
    final class DeinitCounter {
        var count = 0
    }

    struct TestFlow: ~Copyable {
        var value: Int
        let counter: DeinitCounter?

        init(value: Int, counter: DeinitCounter? = nil) {
            self.value = value
            self.counter = counter
        }

        deinit {
            counter?.count += 1
        }
    }

    // A flow identifier carries the event state slot in its low 32 bits and a generation above it.
    func id(slot: UInt64, generation: UInt64 = 1) -> MultiplexedFlowIdentifier {
        MultiplexedFlowIdentifier(testValue: (generation << 32) | slot)
    }

    func value(
        _ table: inout MultiplexedFlowTable<TestFlow>,
        _ flowID: MultiplexedFlowIdentifier
    ) -> Int? {
        table.withFlow(flowID) { (flow: inout TestFlow) in flow.value }
    }

    // `XCTAssertNil` cannot look at a noncopyable flow, so report the removed flow's value instead.
    func removed(_ table: inout MultiplexedFlowTable<TestFlow>, _ flowID: MultiplexedFlowIdentifier) -> Int? {
        if let flow = table.remove(flowID) {
            return flow.value
        }
        return nil
    }

    func testStartsEmpty() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.count, 0)
        XCTAssertFalse(table.contains(id(slot: 1)))
        XCTAssertNil(table.firstFlowIdentifier)
        XCTAssertTrue(table.flowIdentifiers.isEmpty)
        XCTAssertNil(value(&table, id(slot: 1)))
    }

    func testInsertAndLookup() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        table.insert(TestFlow(value: 10), for: id(slot: 1))
        table.insert(TestFlow(value: 20), for: id(slot: 2))
        table.insert(TestFlow(value: 30), for: id(slot: 7))

        XCTAssertFalse(table.isEmpty)
        XCTAssertEqual(table.count, 3)
        XCTAssertTrue(table.contains(id(slot: 1)))
        XCTAssertTrue(table.contains(id(slot: 7)))
        XCTAssertFalse(table.contains(id(slot: 3)))
        XCTAssertEqual(value(&table, id(slot: 1)), 10)
        XCTAssertEqual(value(&table, id(slot: 2)), 20)
        XCTAssertEqual(value(&table, id(slot: 7)), 30)
        XCTAssertNil(value(&table, id(slot: 3)))
    }

    func testWithFlowMutatesTheStoredFlow() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        table.insert(TestFlow(value: 1), for: id(slot: 5))

        table.withFlow(id(slot: 5)) { (flow: inout TestFlow) in flow.value = 99 }
        XCTAssertEqual(value(&table, id(slot: 5)), 99)
    }

    func testWithFlowReturnsNilWithoutRunningTheBodyForUnknownFlow() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        table.insert(TestFlow(value: 1), for: id(slot: 5))

        var ran = false
        let result: Int? = table.withFlow(id(slot: 6)) { (flow: inout TestFlow) -> Int in
            ran = true
            return flow.value
        }
        XCTAssertNil(result)
        XCTAssertFalse(ran)
    }

    func testWithFlowRethrowsTypedError() throws {
        struct Boom: Error, Equatable {}
        var table = MultiplexedFlowTable<TestFlow>()
        table.insert(TestFlow(value: 1), for: id(slot: 5))

        do throws(Boom) {
            _ = try table.withFlow(id(slot: 5)) { (_: inout TestFlow) throws(Boom) in
                throw Boom()
            }
            XCTFail("Expected the body's error to propagate")
        } catch {
            XCTAssertEqual(error, Boom())
        }
        // The flow is still there after the throw
        XCTAssertEqual(value(&table, id(slot: 5)), 1)
    }

    func testRemoveHandsTheFlowBack() throws {
        let counter = DeinitCounter()
        var table = MultiplexedFlowTable<TestFlow>()
        table.insert(TestFlow(value: 42, counter: counter), for: id(slot: 3))
        table.insert(TestFlow(value: 43, counter: counter), for: id(slot: 4))

        var removed = table.remove(id(slot: 3))
        XCTAssertEqual(removed?.value, 42)
        // Handing the flow back does not destroy it
        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(table.contains(id(slot: 3)))
        XCTAssertEqual(table.count, 1)
        // The other flow is untouched
        XCTAssertEqual(value(&table, id(slot: 4)), 43)

        removed = nil
        XCTAssertEqual(counter.count, 1)
    }

    func testRemoveUnknownFlowReturnsNil() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        table.insert(TestFlow(value: 1), for: id(slot: 3))

        XCTAssertNil(removed(&table, id(slot: 4)))
        // Removing twice only succeeds once
        XCTAssertNotNil(removed(&table, id(slot: 3)))
        XCTAssertNil(removed(&table, id(slot: 3)))
        XCTAssertTrue(table.isEmpty)
    }

    // A reused event state slot comes back with a new generation. The identifier of the flow that
    // used to be there must not find the new flow.
    func testStaleIdentifierDoesNotFindFlowThatReusedTheSlot() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let old = id(slot: 9, generation: 1)
        let reused = id(slot: 9, generation: 2)

        table.insert(TestFlow(value: 1), for: old)
        XCTAssertNotNil(removed(&table, old))
        table.insert(TestFlow(value: 2), for: reused)

        XCTAssertFalse(table.contains(old))
        XCTAssertNil(value(&table, old))
        XCTAssertNil(removed(&table, old))
        XCTAssertEqual(value(&table, reused), 2)
        XCTAssertEqual(table.count, 1)
    }

    // Two live flows can share an event state slot (different generations), so their searches start
    // at the same place. Both must be reachable, and removing either must leave the other alone.
    func testFlowsSharingAnEventStateSlotAreBothReachable() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let first = id(slot: 9, generation: 1)
        let second = id(slot: 9, generation: 2)

        table.insert(TestFlow(value: 1), for: first)
        table.insert(TestFlow(value: 2), for: second)
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(value(&table, first), 1)
        XCTAssertEqual(value(&table, second), 2)

        // Removing the one that was placed first leaves the other findable
        XCTAssertEqual(removed(&table, first), 1)
        XCTAssertFalse(table.contains(first))
        XCTAssertEqual(value(&table, second), 2)

        XCTAssertEqual(removed(&table, second), 2)
        XCTAssertTrue(table.isEmpty)
    }

    func testRemovingTheLaterFlowOfASharedEventStateSlotLeavesTheEarlierOne() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let first = id(slot: 9, generation: 1)
        let second = id(slot: 9, generation: 2)

        table.insert(TestFlow(value: 1), for: first)
        table.insert(TestFlow(value: 2), for: second)

        XCTAssertEqual(removed(&table, second), 2)
        XCTAssertFalse(table.contains(second))
        XCTAssertEqual(value(&table, first), 1)
    }

    // Event state slots of any size are stored and found; the size of the table follows the number of
    // flows, not the largest slot.
    func testLargeEventStateSlotsAreSupported() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let large = id(slot: 1 << 20)
        let huge = id(slot: 0xFFFF_FFFE)

        table.insert(TestFlow(value: 1), for: id(slot: 1))
        table.insert(TestFlow(value: 2), for: large)
        table.insert(TestFlow(value: 3), for: huge)

        XCTAssertEqual(table.count, 3)
        XCTAssertEqual(value(&table, large), 2)
        XCTAssertEqual(value(&table, huge), 3)
        XCTAssertEqual(value(&table, id(slot: 1)), 1)

        XCTAssertEqual(removed(&table, large), 2)
        XCTAssertFalse(table.contains(large))
        XCTAssertEqual(value(&table, huge), 3)
    }

    // MARK: Searches that share a starting place
    //
    // The table finds a flow by starting at a place taken from the low bits of its identifier, and
    // looking along from there. With room for up to four flows the table has eight places, so
    // slots 1, 9 and 17 (and 7, 15 and 23) all start at the same place.

    func testIdentifiersThatStartAtTheSamePlaceAreAllReachable() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let ids = [1, 9, 17].map { id(slot: UInt64($0)) }
        for (offset, flowID) in ids.enumerated() {
            table.insert(TestFlow(value: offset), for: flowID)
        }
        for (offset, flowID) in ids.enumerated() {
            XCTAssertEqual(value(&table, flowID), offset)
        }
        // A slot that starts at the same place but is not in the table is not found
        XCTAssertNil(value(&table, id(slot: 25)))
        XCTAssertFalse(table.contains(id(slot: 25)))
    }

    // Removing a flow from the middle of a run must not hide the flows after it
    func testRemovingFromTheMiddleOfARunKeepsTheFlowsAfterIt() throws {
        for removedOffset in 0..<3 {
            var table = MultiplexedFlowTable<TestFlow>()
            let ids = [1, 9, 17].map { id(slot: UInt64($0)) }
            for (offset, flowID) in ids.enumerated() {
                table.insert(TestFlow(value: offset), for: flowID)
            }
            XCTAssertEqual(removed(&table, ids[removedOffset]), removedOffset)
            for (offset, flowID) in ids.enumerated() where offset != removedOffset {
                XCTAssertEqual(value(&table, flowID), offset, "removed \(removedOffset)")
            }
            XCTAssertFalse(table.contains(ids[removedOffset]))
            XCTAssertEqual(table.count, 2)
        }
    }

    // A flow that starts later in a run than a flow removed ahead of it can move up to fill the gap,
    // but one that starts after the gap must stay where its own search will find it.
    func testRemovingKeepsFlowsWithDifferentStartsReachable() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        // 1 and 9 start at the same place; 2 starts one place on and is pushed along by 9
        let a = id(slot: 1)
        let b = id(slot: 9)
        let c = id(slot: 2)
        let d = id(slot: 3)
        for (offset, flowID) in [a, b, c, d].enumerated() {
            table.insert(TestFlow(value: offset), for: flowID)
        }
        XCTAssertEqual(removed(&table, a), 0)
        XCTAssertEqual(value(&table, b), 1)
        XCTAssertEqual(value(&table, c), 2)
        XCTAssertEqual(value(&table, d), 3)
        XCTAssertEqual(removed(&table, c), 2)
        XCTAssertEqual(value(&table, b), 1)
        XCTAssertEqual(value(&table, d), 3)
    }

    // A run that starts near the end of the table carries on at the start of it
    func testARunThatWrapsAroundTheEndSurvivesRemovals() throws {
        for removedOffset in 0..<3 {
            var table = MultiplexedFlowTable<TestFlow>()
            let ids = [7, 15, 23].map { id(slot: UInt64($0)) }
            for (offset, flowID) in ids.enumerated() {
                table.insert(TestFlow(value: offset), for: flowID)
            }
            XCTAssertEqual(removed(&table, ids[removedOffset]), removedOffset)
            for (offset, flowID) in ids.enumerated() where offset != removedOffset {
                XCTAssertEqual(value(&table, flowID), offset, "removed \(removedOffset)")
            }
        }
    }

    // MARK: Growth

    func testTableGrowsAndKeepsEveryFlow() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        for slot in 1...300 {
            table.insert(TestFlow(value: slot), for: id(slot: UInt64(slot)))
        }
        XCTAssertEqual(table.count, 300)
        for slot in 1...300 {
            XCTAssertEqual(value(&table, id(slot: UInt64(slot))), slot)
        }

        // Remove every other flow, then add more: freed entries are reused and nothing is lost
        for slot in stride(from: 2, through: 300, by: 2) {
            XCTAssertEqual(removed(&table, id(slot: UInt64(slot))), slot)
        }
        for slot in 301...400 {
            table.insert(TestFlow(value: slot), for: id(slot: UInt64(slot)))
        }
        XCTAssertEqual(table.count, 250)
        for slot in stride(from: 1, through: 300, by: 2) {
            XCTAssertEqual(value(&table, id(slot: UInt64(slot))), slot)
        }
        for slot in 301...400 {
            XCTAssertEqual(value(&table, id(slot: UInt64(slot))), slot)
        }
        for slot in stride(from: 2, through: 300, by: 2) {
            XCTAssertFalse(table.contains(id(slot: UInt64(slot))))
        }
    }

    func testGrowthKeepsFlowsThatShareAStartingPlace() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        // Slots that are all multiples of 64 start at the same place until the table is large
        let ids = (1...40).map { id(slot: UInt64($0) * 64) }
        for (offset, flowID) in ids.enumerated() {
            table.insert(TestFlow(value: offset), for: flowID)
        }
        for (offset, flowID) in ids.enumerated() {
            XCTAssertEqual(value(&table, flowID), offset)
        }
    }

    // MARK: Against a model

    // Inserts, removals and lookups of a mix of identifiers chosen to collide a lot (few slots, several
    // generations of each, and some very large slots), checked at every step against a dictionary.
    func testRandomOperationsAgreeWithADictionary() throws {
        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        var random = SplitMix64(state: 0x5EED)
        func randomIdentifier() -> MultiplexedFlowIdentifier {
            let slot: UInt64
            switch random.next() % 8 {
            case 0: slot = 0x1_0000 + random.next() % 4
            case 1: slot = 0xFFFF_FFF0 + random.next() % 8
            default: slot = 1 + random.next() % 48
            }
            return id(slot: slot, generation: 1 + random.next() % 4)
        }

        var table = MultiplexedFlowTable<TestFlow>()
        var model = [MultiplexedFlowIdentifier: Int]()
        var nextValue = 0

        for step in 0..<20_000 {
            switch random.next() % 3 {
            case 0:
                let flowID = randomIdentifier()
                guard model[flowID] == nil else { break }
                nextValue += 1
                table.insert(TestFlow(value: nextValue), for: flowID)
                model[flowID] = nextValue
            case 1:
                guard !model.isEmpty else { break }
                let flowID = Array(model.keys)[Int(random.next() % UInt64(model.count))]
                XCTAssertEqual(removed(&table, flowID), model[flowID], "step \(step)")
                model.removeValue(forKey: flowID)
            default:
                let flowID = randomIdentifier()
                XCTAssertEqual(value(&table, flowID), model[flowID], "step \(step)")
                XCTAssertEqual(table.contains(flowID), model[flowID] != nil, "step \(step)")
            }
            XCTAssertEqual(table.count, model.count, "step \(step)")

            if step % 500 == 0 {
                XCTAssertEqual(Set(table.flowIdentifiers), Set(model.keys), "step \(step)")
                var sum = 0
                table.forEachFlow { sum += $0.value }
                XCTAssertEqual(sum, model.values.reduce(0, +), "step \(step)")
            }
        }

        // Everything that is left is still reachable, and removing it empties the table
        for (flowID, expected) in model {
            XCTAssertEqual(removed(&table, flowID), expected)
        }
        XCTAssertTrue(table.isEmpty)
    }

    // The slots of removed flows are reused, so a table that churns flows keeps working and never
    // reports a removed flow.
    func testChurnReusesSlotsAndStaysConsistent() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        var live = [MultiplexedFlowIdentifier: Int]()
        var nextGeneration: UInt64 = 0

        for round in 0..<200 {
            // Keep a window of 8 concurrent flows
            nextGeneration += 1
            let flowID = id(slot: UInt64(round % 12) + 1, generation: nextGeneration)
            table.insert(TestFlow(value: round), for: flowID)
            live[flowID] = round

            if live.count > 8, let oldest = live.min(by: { $0.value < $1.value }) {
                XCTAssertEqual(removed(&table, oldest.key), oldest.value)
                live.removeValue(forKey: oldest.key)
                XCTAssertFalse(table.contains(oldest.key))
            }
            XCTAssertEqual(table.count, live.count)
        }
        for (flowID, expected) in live {
            XCTAssertEqual(value(&table, flowID), expected)
        }
    }

    func testForEachFlowVisitsEveryLiveFlowOnce() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        for slot in 1...6 {
            table.insert(TestFlow(value: slot), for: id(slot: UInt64(slot)))
        }
        // Leave gaps, then fill one of them
        _ = table.remove(id(slot: 2))
        _ = table.remove(id(slot: 5))
        table.insert(TestFlow(value: 100), for: id(slot: 50))

        var seen = [Int]()
        table.forEachFlow { (flow: inout TestFlow) in
            seen.append(flow.value)
            flow.value += 1000
        }
        XCTAssertEqual(seen.sorted(), [1, 3, 4, 6, 100])
        XCTAssertEqual(value(&table, id(slot: 1)), 1001)
        XCTAssertEqual(value(&table, id(slot: 50)), 1100)
    }

    func testFlowIdentifiersAreASnapshotOfLiveFlows() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let ids = (1...4).map { id(slot: UInt64($0)) }
        for (index, flowID) in ids.enumerated() {
            table.insert(TestFlow(value: index), for: flowID)
        }
        _ = table.remove(ids[1])

        let snapshot = table.flowIdentifiers
        XCTAssertEqual(Set(snapshot), Set([ids[0], ids[2], ids[3]]))
        XCTAssertEqual(snapshot.count, 3)

        // The snapshot is safe to walk while the table changes
        for flowID in snapshot {
            XCTAssertNotNil(removed(&table, flowID))
        }
        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(snapshot.count, 3)
    }

    func testFirstFlowIdentifierIsALiveFlow() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let ids = (1...3).map { id(slot: UInt64($0)) }
        for flowID in ids { table.insert(TestFlow(value: 0), for: flowID) }
        _ = table.remove(ids[0])

        let first = try XCTUnwrap(table.firstFlowIdentifier)
        XCTAssertTrue(table.contains(first))
        XCTAssertNotEqual(first, ids[0])
    }

    func testFirstFlowIdentifierWherePredicate() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        for slot in 1...5 {
            table.insert(TestFlow(value: slot * 10), for: id(slot: UInt64(slot)))
        }
        _ = table.remove(id(slot: 3))

        let match = table.firstFlowIdentifier { (flow: inout TestFlow) in flow.value == 40 }
        XCTAssertEqual(match, id(slot: 4))
        // A removed flow is never offered to the predicate
        var offered = [Int]()
        let none = table.firstFlowIdentifier { (flow: inout TestFlow) in
            offered.append(flow.value)
            return false
        }
        XCTAssertNil(none)
        XCTAssertEqual(offered.sorted(), [10, 20, 40, 50])
    }

    func testRemoveAllDestroysFlowsAndResetsTheTable() throws {
        let counter = DeinitCounter()
        var table = MultiplexedFlowTable<TestFlow>()
        for slot in 1...5 {
            table.insert(TestFlow(value: slot, counter: counter), for: id(slot: UInt64(slot)))
        }
        table.insert(TestFlow(value: 6, counter: counter), for: id(slot: 1 << 20))

        table.removeAll()
        XCTAssertEqual(counter.count, 6)
        XCTAssertTrue(table.isEmpty)
        XCTAssertEqual(table.count, 0)
        XCTAssertFalse(table.contains(id(slot: 1)))
        XCTAssertFalse(table.contains(id(slot: 1 << 20)))
        XCTAssertTrue(table.flowIdentifiers.isEmpty)

        // Usable again afterwards
        table.insert(TestFlow(value: 7), for: id(slot: 1))
        XCTAssertEqual(value(&table, id(slot: 1)), 7)
    }

    func testTableDestroysRemainingFlowsWhenItGoesAway() throws {
        let counter = DeinitCounter()
        do {
            var table = MultiplexedFlowTable<TestFlow>()
            table.insert(TestFlow(value: 1, counter: counter), for: id(slot: 1))
            table.insert(TestFlow(value: 2, counter: counter), for: id(slot: 2))
            _ = table.remove(id(slot: 1))  // destroyed immediately, the result is discarded
            XCTAssertEqual(counter.count, 1)
        }
        XCTAssertEqual(counter.count, 2)
    }
}
