//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNetwork project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !NETWORK_NO_SWIFT_QUIC

/// A connection's values (its flows) by stream ID.
///
/// The streams of one kind (initiator and direction: the low two bits of the ID) are numbered four
/// apart, are created in order, and mostly close soon after, so the live ones of a kind sit in a
/// short window of the ID space. This keeps a window per kind as an array, so a lookup, an insert
/// and a removal hash nothing. A stream far outside its kind's window, or below it, goes to a
/// dictionary, so any ID works and the windows stay small.
@available(Network 0.1.0, *)
struct QUICStreamIDIndex<Value> {
    private struct Window {
        var base: UInt64 = 0
        var head = 0
        var items = ContiguousArray<Value?>()

        @inline(always)
        func get(_ sequence: UInt64) -> Value? {
            guard sequence >= base else { return nil }
            let index = Int(truncatingIfNeeded: sequence &- base)
            guard index >= head, index < items.count else { return nil }
            return items[index]
        }

        /// Whether the stream was stored in the window.
        mutating func insert(_ flow: Value, _ sequence: UInt64) -> Bool {
            if head >= items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
                base = sequence
            }
            guard sequence >= base else { return false }
            let offset = sequence &- base
            // A stream this far ahead of the oldest one is not a window's worth: keep it aside.
            guard offset < QUICStreamIDIndexLimits.maximumWindow else { return false }
            let index = Int(truncatingIfNeeded: offset)
            guard index >= head else { return false }
            while items.count <= index { items.append(nil) }
            items[index] = flow
            return true
        }

        mutating func remove(_ sequence: UInt64) -> Value? {
            guard sequence >= base else { return nil }
            let index = Int(truncatingIfNeeded: sequence &- base)
            guard index >= head, index < items.count else { return nil }
            let flow = items[index]
            items[index] = nil
            while head < items.count, items[head] == nil { head += 1 }
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 1024, head * 2 >= items.count {
                items.removeFirst(head)
                base &+= UInt64(head)
                head = 0
            }
            return flow
        }
    }

    private var windows = [Window](repeating: Window(), count: 4)
    private var overflow: [QUICStreamID: Value] = [:]

    subscript(_ id: QUICStreamID) -> Value? {
        get {
            let kind = Int(truncatingIfNeeded: id.value & 3)
            if let flow = windows[kind].get(id.value >> 2) { return flow }
            return overflow.isEmpty ? nil : overflow[id]
        }
        set {
            if let newValue {
                let kind = Int(truncatingIfNeeded: id.value & 3)
                if !overflow.isEmpty { overflow.removeValue(forKey: id) }
                if !windows[kind].insert(newValue, id.value >> 2) {
                    overflow[id] = newValue
                }
            } else {
                _ = removeValue(forKey: id)
            }
        }
    }

    @discardableResult
    mutating func removeValue(forKey id: QUICStreamID) -> Value? {
        let kind = Int(truncatingIfNeeded: id.value & 3)
        if let flow = windows[kind].remove(id.value >> 2) { return flow }
        return overflow.isEmpty ? nil : overflow.removeValue(forKey: id)
    }

    mutating func removeAll() {
        windows = [Window](repeating: Window(), count: 4)
        overflow.removeAll()
    }
}

/// How far ahead of the oldest stream of its kind a stream may be and still sit in the window.
enum QUICStreamIDIndexLimits {
    static let maximumWindow: UInt64 = 1 << 14
}

/// The flows of a connection by stream ID.
@available(Network 0.1.0, *)
typealias QUICStreamFlowIndex = QUICStreamIDIndex<MultiplexedFlowIdentifier>

#endif
