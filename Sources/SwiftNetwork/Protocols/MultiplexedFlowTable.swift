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
//
// This is internal and not nested in the table on purpose. With the compiler in use, a generic
// noncopyable type that holds the flow produces invalid code (the build stops with "Broken module
// found") when it is private, whether it is nested in the table or at file scope.
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
// state in its low 32 bits, and those slots are small and dense, so they are used as they are:
// the identifier's low bits, masked to the size of `index`, say where to start looking. No hash
// function is involved. The size of `index` follows the number of flows, not the largest event
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

    public var count: Int { liveCount }

    public var isEmpty: Bool { liveCount == 0 }

    // Where a search for `flowID` starts in `index`
    @inline(always)
    private func startPosition(of flowID: MultiplexedFlowIdentifier) -> Int {
        Int(truncatingIfNeeded: flowID.rawValue & 0xFFFF_FFFF) & (index.count &- 1)
    }

    // The position of `flowID` in `index` and the position of its entry, if it is in the table. The
    // whole identifier is compared, so the identifier of a flow that has gone, whose event state slot
    // has been reused, is not found.
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
    private mutating func makeRoomInIndex() {
        guard (liveCount + 1) &* 2 > index.count else { return }
        var capacity = Swift.max(8, index.count)
        while (liveCount + 1) &* 2 > capacity { capacity &*= 2 }
        index = [Int32](repeating: 0, count: capacity)
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            placeInIndex(entry: position, for: entries[position].identifier)
        }
    }

    @inline(always)
    private mutating func placeInIndex(entry: Int, for flowID: MultiplexedFlowIdentifier) {
        let mask = index.count &- 1
        var position = startPosition(of: flowID)
        while index[position] != 0 {
            position = (position &+ 1) & mask
        }
        index[position] = Int32(truncatingIfNeeded: entry &+ 1)
    }

    public mutating func insert(_ flow: consuming Flow, for flowID: MultiplexedFlowIdentifier) {
        assert(flowID != .allFlows, "A flow cannot have the identifier that means all flows")
        assert(find(flowID) == nil, "Flow \(flowID) is already in the table")
        makeRoomInIndex()
        let entry: Int
        if firstFree >= 0 {
            // Reuse a free entry
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
    public mutating func remove(_ flowID: MultiplexedFlowIdentifier) -> Flow? {
        guard let (inIndex, entry) = find(flowID) else { return nil }
        removeFromIndex(at: inIndex)
        entries[entry].identifier = .allFlows
        entries[entry].nextFree = firstFree
        firstFree = Int32(truncatingIfNeeded: entry)
        liveCount -= 1
        return entries[entry].flow.take()
    }

    // Takes the position at `hole` out of `index` without leaving a gap that would end a search early:
    // the entries after it that could have been placed at or before it move back to fill it.
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
    public mutating func withFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout Flow) throws(E) -> R
    ) throws(E) -> R? {
        guard let (_, entry) = find(flowID) else { return nil }
        return try body(&entries[entry].flow!)
    }

    // Lends out every flow in turn.
    public mutating func forEachFlow(_ body: (inout Flow) -> Void) {
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            body(&entries[position].flow!)
        }
    }

    // The identifier of the first flow `predicate` accepts, or `nil` if it accepts none.
    public mutating func firstFlowIdentifier(where predicate: (inout Flow) -> Bool) -> MultiplexedFlowIdentifier? {
        for position in 0..<entries.count where entries[position].identifier != .allFlows {
            if predicate(&entries[position].flow!) {
                return entries[position].identifier
            }
        }
        return nil
    }

    public mutating func removeAll() {
        entries = NetworkUniqueArray<MultiplexedFlowTableEntry<Flow>>()
        firstFree = -1
        index = []
        liveCount = 0
    }
}
