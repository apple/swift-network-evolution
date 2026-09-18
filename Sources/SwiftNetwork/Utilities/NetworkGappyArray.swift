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
internal import DequeModule
#endif

// This index is used to refer to a location (as in NetworkGappyArray) without
// exposing numeric properties. It also contains a generation to detect invalid
// reuse of indices.
//
// The all-zeros value is reserved for `.none`, so this type needs no `Optional` wrapper — an
// `Optional` would otherwise add a whole word of padding to every aggregate holding one.
// `NetworkGappyArray` never issues generation zero, which is what keeps `.none` distinct from
// every index it hands out.
@available(Network 0.1.0, *)
struct NetworkStateIndex: Hashable {
    fileprivate let index: UInt32
    fileprivate let generation: UInt32

    fileprivate init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    fileprivate init() {
        self.index = 0
        self.generation = 0
    }

    fileprivate func indexWithGeneration(_ generation: UInt32) -> Self {
        .init(index: index, generation: generation)
    }

    // The position this index refers to, for use as a `NetworkGappyArray` offset.
    fileprivate var slot: Int { Int(index) }

    // The absence of an index. Never equal to an index issued by a `NetworkGappyArray`.
    static let none = NetworkStateIndex()

    var isNone: Bool { self == .none }

    // The whole index as one opaque word, for callers that persist a slot's identity beyond the
    // element's lifetime: it carries the generation, so a reused slot is not mistaken for the
    // original. `.none` is zero, so zero remains available as a caller-side sentinel.
    var rawValue: UInt64 {
        UInt64(index) | (UInt64(generation) << 32)
    }

    // Hashing the halves as one word rather than combining them separately; this makes hashing
    // as cheap as it would be for a single stored `UInt64`.
    func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

// A "gappy array" is an array of non-copyable elements where the index of
// an element does not change once it is added. The index will remain until
// the element is removed. When the element is removed, this can create a
// "gap" in the array which can be re-used by new elements.
//
// This type does not convey any particular order, but is used to be a condensed
// way of holding elements that have fast lookup. This is similar to how
// interface indices (if_index) is used in kernel networking stacks.
//
// The array holds at most `maximumCount` elements, so that a position always fits in the 32
// bits `NetworkStateIndex` gives it.
@available(Network 0.1.0, *)
struct NetworkGappyArray<Element: ~Copyable>: ~Copyable {

    // The most elements this array can hold. One below `UInt32.max` so that the top position
    // stays available as a sentinel for future use.
    static var maximumCount: Int { Int(UInt32.max) - 1 }

    // Array of elements, which may have gaps
    fileprivate var elements = NetworkUniqueArray<Element?>()

    // Free indices in elements array
    fileprivate var gaps = NetworkPriorityQueue<GapRecord>()

    // Increments once for every element that is added, wrapping around on overflow and skipping
    // zero: generation zero is reserved for `NetworkStateIndex.none`. Wrapping means a generation
    // repeats after 2^32 insertions, so two indices for the same slot collide only if one
    // outlives four billion intervening insertions.
    private var generation: UInt32 = 0

    @inlinable
    subscript(position: NetworkStateIndex) -> Element {
        _modify {
            yield &elements[position.slot]!
        }
        mutating _read {
            yield elements[position.slot]!
        }
    }

    // Moves an element out of the array, leaving its slot temporarily empty. Pair every
    // `take` with a `restore` for the same index.
    //
    // This exists so a caller can hold the element and the enclosing storage as two
    // independent borrows: reaching an element via `subscript` holds an exclusive access to
    // the whole array, which would conflict with also passing that storage along.
    @inlinable
    mutating func take(index: NetworkStateIndex) -> Element {
        elements[index.slot].take()!
    }

    // Puts an element back into a slot previously emptied by `take`.
    @inlinable
    mutating func restore(index: NetworkStateIndex, _ element: consuming Element) {
        elements[index.slot] = consume element
    }

    var count: Int { elements.count - gaps.count }

    var isEmpty: Bool { count == 0 }

    internal struct GapRecord: ~Copyable, NetworkComparable {
        let index: NetworkStateIndex
        init(_ index: NetworkStateIndex) {
            self.index = index
        }

        static func < (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
            lhs.index.slot < rhs.index.slot
        }
        static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
            (lhs.index.slot == rhs.index.slot)
        }
    }

    // Advances to the next generation, skipping zero so that no issued index can equal
    // `NetworkStateIndex.none`.
    private mutating func nextGeneration() -> UInt32 {
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
        return generation
    }

    // Positions the generation counter so the next insertion crosses the wrap boundary. Exists so
    // a test can reach that boundary without performing 2^32 insertions.
    internal mutating func setGenerationForTesting(_ generation: UInt32) {
        self.generation = generation
    }

    mutating func insert(_ element: consuming Element) -> NetworkStateIndex {
        let generation = nextGeneration()
        if let gap = gaps.pop() {
            let gapIndex = gap.index.indexWithGeneration(generation)
            elements[gapIndex.slot] = consume element
            return gapIndex
        }
        let newIndex = elements.count
        precondition(newIndex < Self.maximumCount, "NetworkGappyArray exceeded its maximum count")
        elements.append(element)
        return NetworkStateIndex(index: UInt32(newIndex), generation: generation)
    }

    internal mutating func cleanupGapsIfNecessary() {
        let count = elements.count
        guard count > 0, elements[count - 1] == nil else {
            // Cannot cleanup gaps at the end
            return
        }

        guard gaps.count * 10 > elements.count else {
            // Only cleanup gaps if they represent more than 10% of the total elements
            return
        }

        // Walk elements from end, removing any that are nil, and remove
        // the corresponding gap record
        while true {
            let count = elements.count
            guard count > 0 else { break }  // Array must be non-empty
            guard elements[count - 1] == nil else { break }  // Value must be nil
            gaps.removeFirst { $0.index.slot == count - 1 }
            elements.removeLast()
        }
    }

    mutating func remove(index: NetworkStateIndex) {
        defer { cleanupGapsIfNecessary() }
        if index.slot == elements.count - 1 {
            // Removing last element
            elements.removeLast()
            return
        }

        // Clear element and record the gap
        elements[index.slot] = nil
        gaps.push(GapRecord(index))
    }
}
