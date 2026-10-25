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

    // Two live flows can share an event state slot (different generations). The second cannot use
    // the direct array and must still be reachable, and removing either must leave the other alone.
    func testFlowsSharingAnEventStateSlotAreBothReachable() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let first = id(slot: 9, generation: 1)
        let second = id(slot: 9, generation: 2)

        table.insert(TestFlow(value: 1), for: first)
        table.insert(TestFlow(value: 2), for: second)
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(value(&table, first), 1)
        XCTAssertEqual(value(&table, second), 2)

        // Removing the one in the direct array leaves the other findable
        XCTAssertEqual(removed(&table, first), 1)
        XCTAssertFalse(table.contains(first))
        XCTAssertEqual(value(&table, second), 2)

        XCTAssertEqual(removed(&table, second), 2)
        XCTAssertTrue(table.isEmpty)
    }

    func testRemovingTheOverflowFlowLeavesTheDirectFlow() throws {
        var table = MultiplexedFlowTable<TestFlow>()
        let first = id(slot: 9, generation: 1)
        let second = id(slot: 9, generation: 2)

        table.insert(TestFlow(value: 1), for: first)
        table.insert(TestFlow(value: 2), for: second)

        XCTAssertEqual(removed(&table, second), 2)
        XCTAssertFalse(table.contains(second))
        XCTAssertEqual(value(&table, first), 1)
    }

    // Slots beyond the direct array's range are still stored and found.
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
