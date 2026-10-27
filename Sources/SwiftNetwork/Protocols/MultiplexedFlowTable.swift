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
    // The largest event state slot that is looked up through the array
    private static var maximumDirectKey: Int { 1 << 16 }

    // Flows by table slot. A slot with no flow holds `nil`
    private var elements = NetworkUniqueArray<Flow?>()
    // The identifier of the flow in each table slot, or `.allFlows` if the slot is free
    private var identifiers: [MultiplexedFlowIdentifier] = []
    // Table slots that are free to reuse
    private var freeSlots: [Int] = []
    // Table slot plus one, indexed by event state slot. Zero means no flow
    private var direct: [Int32] = []
    private var overflow: [MultiplexedFlowIdentifier: Int] = [:]
    private var liveCount = 0

    public init() {}

    public var count: Int { liveCount }

    public var isEmpty: Bool { liveCount == 0 }

    @inline(always)
    static private func key(of flowID: MultiplexedFlowIdentifier) -> Int {
        Int(truncatingIfNeeded: flowID.rawValue & 0xFFFF_FFFF)
    }

    @inline(always)
    private func slot(of flowID: MultiplexedFlowIdentifier) -> Int? {
        let key = Self.key(of: flowID)
        if key < direct.count {
            let entry = Int(direct[key]) - 1
            if entry >= 0, identifiers[entry] == flowID {
                return entry
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

    @_optimize(none)
    public mutating func insert(_ flow: consuming Flow, for flowID: MultiplexedFlowIdentifier) {
        assert(slot(of: flowID) == nil, "Flow \(flowID) is already in the table")
        let tableSlot: Int
        // Lookup a free slot, otherwise get the tableSlot by the last count of the elements
        if let free = freeSlots.popLast() {
            tableSlot = free
            elements[free] = consume flow
            identifiers[free] = flowID
        } else {
            tableSlot = elements.count
            elements.append(consume flow)
            identifiers.append(flowID)
        }
        // Get the key for the new flow based on low 32 bits for the flowID's rawValue
        let key = Self.key(of: flowID)
        if key < Self.maximumDirectKey {
            if key >= direct.count {
                // Grow if needed
                direct.append(contentsOf: repeatElement(0, count: key + 1 - direct.count))
            }
            if direct[key] == 0 {
                // Insert the slot index in an empty place
                // Note that you can use this tableSlot to look up
                // both the flow and the identifier.
                direct[key] = Int32(truncatingIfNeeded: tableSlot + 1)
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
        let key = Self.key(of: flowID)
        if key < direct.count, Int(direct[key]) - 1 == tableSlot {
            direct[key] = 0
        } else {
            overflow.removeValue(forKey: flowID)
        }
        identifiers[tableSlot] = .allFlows
        freeSlots.append(tableSlot)
        liveCount -= 1
        return elements[tableSlot].take()
    }

    // Lends out the flow with the given identifier, or returns `nil` if there is none.
    public mutating func withFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout Flow) throws(E) -> R
    ) throws(E) -> R? {
        guard let tableSlot = slot(of: flowID) else { return nil }
        return try body(&elements[tableSlot]!)
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
