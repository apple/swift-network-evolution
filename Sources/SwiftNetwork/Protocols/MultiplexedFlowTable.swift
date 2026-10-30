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

#if canImport(BasicContainers)
import BasicContainers
#endif

// A flow and its identifier. A free entry has no flow, the identifier `.allFlows`, and holds in
// `nextFree` the position of the next free entry, or -1 if it is the last.
@available(Network 0.1.0, *)
struct MultiplexedFlowTableEntry<Flow: ~Copyable>: ~Copyable {
    var identifier: MultiplexedFlowIdentifier
    var nextFree: Int32
    var flow: Flow?
}

// A table of the flows a many-to-many protocol multiplexes, keyed by flow identifier.
//
// The flows live in `entries`, each next to its identifier. A free entry is not wasted: it holds
// the position of the next free entry, so the free entries form a list that needs no storage of
// its own.
//
// `index` finds the entry for an identifier. A flow identifier carries the slot of the flow's event
// state in its low 32 bits. The size of `index` follows the number of flows, not the largest event
// state slot there has been. Two identifiers that start at the same place, such as two generations
// of one event state slot, just sit next to each other.
//
// Flows are only ever reached by borrowing: `withFlow` lends out the stored flow for the
// duration of a closure.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public struct MultiplexedFlowTable<Flow: ~Copyable>: ~Copyable {
    private var entries = NetworkUniqueArray<MultiplexedFlowTableEntry<Flow>>()
    // The position of the first free entry, or -1 if there is none
    private var firstFree: Int32 = -1

    // Open addressed by `startPosition(of:)`. Zero means empty; anything else is the position of an
    // entry plus one. The size is a power of two, and at most half of it is used, so a search for an
    // identifier ends after a short run, or after the first look when there is no collision.
    private var index: [Int32] = []

    private var liveCount = 0

    public init() {}

    var count: Int { liveCount }

    public var isEmpty: Bool { liveCount == 0 }

    // Where a search for `flowID` starts in `index`
    @inline(always)
    private func startPosition(of flowID: MultiplexedFlowIdentifier) -> Int {
        Int(truncatingIfNeeded: flowID.rawValue & 0xFFFF_FFFF) & (index.count &- 1)
    }

    // The position of `flowID` in `index` and the position of its entry, if it is in the table. The
    // whole identifier is compared, so the identifier of a flow that has gone, whose event state slot
    // has been reused, is not found.
    //
    // Time: average O(1), worst case O(n).
    @inline(always)
    private func find(_ flowID: MultiplexedFlowIdentifier) -> (inIndex: Int, entry: Int)? {
        guard !index.isEmpty else { return nil }
        let mask = index.count &- 1
        var position = startPosition(of: flowID)
        while true {
            let stored = index[position]
            if stored == 0 { return nil }
            let entry = Int(stored) &- 1
            if entries[entry].identifier == flowID { return (position, entry) }
            position = (position &+ 1) & mask
        }
    }

    // Time: average O(1), worst case O(n).
    public func contains(_ flowID: MultiplexedFlowIdentifier) -> Bool {
        find(flowID) != nil
    }

    // An arbitrary flow identifier, if there is one.
    public var firstFlowIdentifier: MultiplexedFlowIdentifier? {
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            return entries[position].identifier
        }
        return nil
    }

    // The identifier of the first flow at or after `position` in the table, moving `position` just past
    // it. Start with 0 and call again until it returns `nil` to visit every flow without making a
    // list of them. Only a position is kept between calls, so the table can be changed between them
    // (by whatever is done with each identifier): a flow removed before it is reached is not visited,
    // and no flow is visited twice. A flow added meanwhile is visited if it lands after `position`.
    //
    // Time: O(g) for a call that skips g free entries, so O(m) for a walk of the whole table.
    public func nextFlowIdentifier(from position: inout Int) -> MultiplexedFlowIdentifier? {
        while position < entries.count {
            let entryIdentifier = entries[position].identifier
            position += 1
            if entryIdentifier != .allFlows { return entryIdentifier }
        }
        return nil
    }

    // A snapshot of every identifier, safe to iterate while the table is modified.
    public var flowIdentifiers: [MultiplexedFlowIdentifier] {
        var identifiers: [MultiplexedFlowIdentifier] = []
        identifiers.reserveCapacity(liveCount)
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            identifiers.append(entries[position].identifier)
        }
        return identifiers
    }

    // Makes `index` big enough for one more flow, rebuilding it if it has to grow. Only positions are
    // moved; the flows stay where they are.
    //
    // Time: O(1) when `index` has room. When it has to grow, O(m) to rebuild it, but it doubles each
    // time, so across a run of inserts that is amortized O(1) for each one.
    private mutating func makeRoomInIndex() {
        guard (liveCount + 1) &* 2 > index.count else { return }
        var capacity = max(8, index.count)
        while (liveCount + 1) &* 2 > capacity { capacity &*= 2 }
        index = [Int32](repeating: 0, count: capacity)
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            placeInIndex(entry: position, for: entries[position].identifier)
        }
    }

    // Time: average O(1), worst case O(n).
    @inline(always)
    private mutating func placeInIndex(entry: Int, for flowID: MultiplexedFlowIdentifier) {
        let mask = index.count &- 1
        var position = startPosition(of: flowID)
        while index[position] != 0 {
            position = (position &+ 1) & mask
        }
        index[position] = Int32(truncatingIfNeeded: entry &+ 1)
    }

    // Time: average amortized O(1). Reusing a free entry, or adding one to `entries`, is O(1) (amortized
    // for the add); placing it in `index` is average O(1); and `makeRoomInIndex` is amortized O(1). A
    // single insert that makes `index` grow takes O(m).
    public mutating func insert(_ flow: consuming Flow, for flowID: MultiplexedFlowIdentifier) {
        assert(flowID != .allFlows, "A flow cannot have the identifier that means all flows")
        assert(find(flowID) == nil, "Flow \(flowID) is already in the table")
        makeRoomInIndex()
        let entry: Int
        if firstFree >= 0 {
            // Reuse a free entry base on firstFree
            entry = Int(firstFree)
            firstFree = entries[entry].nextFree
            entries[entry].identifier = flowID
            entries[entry].flow = consume flow
        } else {
            entry = entries.count
            entries.append(MultiplexedFlowTableEntry(identifier: flowID, nextFree: -1, flow: consume flow))
        }
        placeInIndex(entry: entry, for: flowID)
        liveCount += 1
    }

    // Removes the flow and hands it to the caller.
    //
    // Time: average O(1), worst case O(n). Finding the flow, closing the gap it leaves in `index`, and
    // putting its entry on the free list each take no more than that. Nothing is given back, so `m` and
    // the size of `index` stay as they are.
    public mutating func remove(_ flowID: MultiplexedFlowIdentifier) -> Flow? {
        guard let (inIndex, entry) = find(flowID) else { return nil }
        removeFromIndex(at: inIndex)
        entries[entry].identifier = .allFlows
        entries[entry].nextFree = firstFree
        // Update firstFree so any future inserts are handled correctly
        firstFree = Int32(truncatingIfNeeded: entry)
        liveCount -= 1
        return entries[entry].flow.take()
    }

    // Takes the position at `hole` out of `index` without leaving a gap that would end a search early.
    // The entries after it that could have been placed at or before it move back to fill it.
    //
    // Time: proportional to the run of occupied places that follows the hole, so expected O(1) and worst
    // case O(n). Only the positions in `index` move, not the flows.
    private mutating func removeFromIndex(at start: Int) {
        let mask = index.count &- 1
        var hole = start
        var position = start
        while true {
            position = (position &+ 1) & mask
            let stored = index[position]
            if stored == 0 { break }
            let home = startPosition(of: entries[Int(stored) &- 1].identifier)
            // The entry can fill the hole if the hole is on the way from where its search starts to where it is
            if (hole &- home) & mask <= (position &- home) & mask {
                index[hole] = stored
                hole = position
            }
        }
        index[hole] = 0
    }

    // Lends out the flow with the given identifier, or returns `nil` if there is none.
    //
    // Time: expected O(1), worst case O(n), plus whatever `body` takes.
    public mutating func withFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout Flow) throws(E) -> R
    ) throws(E) -> R? {
        guard let (_, entry) = find(flowID) else { return nil }
        return try body(&entries[entry].flow!)
    }

    // Lends out every flow in turn.
    //
    // Time: O(m), plus whatever `body` takes for each flow. That counts the free entries too, which are
    // skipped.
    public mutating func forEachFlow(_ body: (inout Flow) -> Void) {
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            body(&entries[position].flow!)
        }
    }

    // The identifier of the first flow `predicate` accepts, or `nil` if it accepts none.
    //
    // Time: O(m) in the worst case, plus whatever `predicate` takes for each flow it is asked about. It
    // stops at the first flow it accepts.
    public mutating func firstFlowIdentifier(where predicate: (inout Flow) -> Bool) -> MultiplexedFlowIdentifier? {
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            if predicate(&entries[position].flow!) {
                return entries[position].identifier
            }
        }
        return nil
    }

    // Destroys every flow as it is, without any cleanup of its own. A flow that holds frames which must be
    // finalized first (a QUIC stream's `releaseResources()`) has to be released before this is called.
    public mutating func removeAll() {
        entries = NetworkUniqueArray<MultiplexedFlowTableEntry<Flow>>()
        firstFree = -1
        index = []
        liveCount = 0
    }
}
