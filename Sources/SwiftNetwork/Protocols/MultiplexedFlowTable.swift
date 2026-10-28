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

// The part of a flow identifier that indexes the table's lookup array (direct).
@available(Network 0.1.0, *)
private struct DirectKey {
    // Keys below this are looked up through the array; the rest go to the dictionary. A computed
    // property so that it is always a constant, never lazily initialized.
    static var limit: Int { 1 << 16 }

    let rawValue: Int

    @inline(always)
    init(_ flowID: MultiplexedFlowIdentifier) {
        rawValue = Int(truncatingIfNeeded: flowID.rawValue & 0xFFFF_FFFF)
    }

    // Whether the array can hold this key at all.
    @inline(always)
    var isDirectlyIndexable: Bool { rawValue < Self.limit }
}

// A index to the `elements` and `identifiers` storage, used by DirectEntry and freeSlots.
@available(Network 0.1.0, *)
private struct TableSlot {
    let rawValue: Int

    @inline(always)
    init(_ rawValue: Int) { self.rawValue = rawValue }
}

// DirectEntry is holding the free or new index available to lookup a Flow.
// This storage index should allow you to look up the indentifier also
@available(Network 0.1.0, *)
private struct DirectEntry {
    private let storage: Int32

    @inline(always)
    private init(storage: Int32) { self.storage = storage }

    @inline(always)
    init(_ slot: TableSlot) { storage = Int32(truncatingIfNeeded: slot.rawValue + 1) }

    // No flow owns the key.
    @inline(always)
    static var none: DirectEntry { DirectEntry(storage: 0) }

    @inline(always)
    var isEmpty: Bool { storage == 0 }

    // The slot of the flow that owns the key, if there is one.
    @inline(always)
    var tableSlot: TableSlot? { storage == 0 ? nil : TableSlot(Int(storage) - 1) }

    // Whether `slot` is the flow that owns the key.
    @inline(always)
    func isOwned(by slot: TableSlot) -> Bool { Int(storage) - 1 == slot.rawValue }
}

// A table of the flows a many-to-many protocol multiplexes, keyed by flow identifier.
//
// A flow identifier carries the slot of the flow's event state in its low 32 bits. Those slots are
// small and dense, so they index a lookup array directly and no hashing is needed. The rare
// identifier that cannot use the array is kept in a dictionary instead.
//
// Flows are only ever reached by borrowing: `withFlow` lends out the stored flow for the
// duration of a closure.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public struct MultiplexedFlowTable<Flow: ~Copyable>: ~Copyable {
    // Flows by table slot. A slot with no flow holds `nil`
    private var elements = NetworkUniqueArray<Flow?>()
    // The identifier of the flow in each table slot, or `.allFlows` if the slot is free
    private var identifiers: [MultiplexedFlowIdentifier] = []
    // Table slots that are free to reuse
    private var freeSlots: [TableSlot] = []
    // The owner of each event state slot (a `DirectKey`), if any
    private var direct: [DirectEntry] = []
    private var overflow: [MultiplexedFlowIdentifier: TableSlot] = [:]
    private var liveCount = 0

    public init() {}

    public var count: Int { liveCount }

    public var isEmpty: Bool { liveCount == 0 }

    @inline(always)
    private func slot(of flowID: MultiplexedFlowIdentifier) -> TableSlot? {
        let key = DirectKey(flowID)
        if key.rawValue < direct.count {
            if let slot = direct[key.rawValue].tableSlot, identifiers[slot.rawValue] == flowID {
                return slot
            }
        }
        if !overflow.isEmpty {
            return overflow[flowID]
        }
        return nil
    }

    public func contains(_ flowID: MultiplexedFlowIdentifier) -> Bool {
        slot(of: flowID) != nil
    }

    // An arbitrary flow identifier, if there is one.
    public var firstFlowIdentifier: MultiplexedFlowIdentifier? {
        identifiers.first(where: { $0 != .allFlows })
    }

    // A snapshot of every identifier, safe to iterate while the table is modified.
    public var flowIdentifiers: [MultiplexedFlowIdentifier] {
        identifiers.filter { $0 != .allFlows }
    }

    public mutating func insert(_ flow: consuming Flow, for flowID: MultiplexedFlowIdentifier) {
        assert(slot(of: flowID) == nil, "Flow \(flowID) is already in the table")
        let tableSlot: TableSlot
        // Lookup a free slot, otherwise get the tableSlot by the last count of the elements
        if let free = freeSlots.popLast() {
            tableSlot = free
            elements[free.rawValue] = consume flow
            identifiers[free.rawValue] = flowID
        } else {
            tableSlot = TableSlot(elements.count)
            elements.append(consume flow)
            identifiers.append(flowID)
        }
        // Get the key for the new flow based on low 32 bits for the flowID's rawValue
        let key = DirectKey(flowID)
        if key.isDirectlyIndexable {
            if key.rawValue >= direct.count {
                // Grow if needed
                direct.append(contentsOf: repeatElement(.none, count: key.rawValue + 1 - direct.count))
            }
            if direct[key.rawValue].isEmpty {
                // Insert the slot index in an empty place
                // Note that you can use this tableSlot to look up
                // both the flow and the identifier.
                direct[key.rawValue] = DirectEntry(tableSlot)
            } else {
                overflow[flowID] = tableSlot
            }
        } else {
            // Add to overflow if we have exceeded our limit
            overflow[flowID] = tableSlot
        }
        liveCount += 1
    }

    // Removes the flow and hands it to the caller.
    public mutating func remove(_ flowID: MultiplexedFlowIdentifier) -> Flow? {
        guard let tableSlot = slot(of: flowID) else { return nil }
        let key = DirectKey(flowID)
        if key.rawValue < direct.count, direct[key.rawValue].isOwned(by: tableSlot) {
            direct[key.rawValue] = .none
        } else {
            overflow.removeValue(forKey: flowID)
        }
        identifiers[tableSlot.rawValue] = .allFlows
        freeSlots.append(tableSlot)
        liveCount -= 1
        return elements[tableSlot.rawValue].take()
    }

    // Lends out the flow with the given identifier, or returns `nil` if there is none.
    public mutating func withFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout Flow) throws(E) -> R
    ) throws(E) -> R? {
        guard let tableSlot = slot(of: flowID) else { return nil }
        return try body(&elements[tableSlot.rawValue]!)
    }

    // Lends out every flow in turn.
    public mutating func forEachFlow(_ body: (inout Flow) -> Void) {
        for tableSlot in 0..<elements.count where identifiers[tableSlot] != .allFlows {
            body(&elements[tableSlot]!)
        }
    }

    // The identifier of the first flow `predicate` accepts, or `nil` if it accepts none.
    public mutating func firstFlowIdentifier(where predicate: (inout Flow) -> Bool) -> MultiplexedFlowIdentifier? {
        for tableSlot in 0..<elements.count where identifiers[tableSlot] != .allFlows {
            if predicate(&elements[tableSlot]!) {
                return identifiers[tableSlot]
            }
        }
        return nil
    }

    public mutating func removeAll() {
        elements = NetworkUniqueArray<Flow?>()
        identifiers.removeAll()
        freeSlots.removeAll()
        direct.removeAll()
        overflow.removeAll()
        liveCount = 0
    }
}
