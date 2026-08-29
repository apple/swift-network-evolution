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

/// A double-ended queue of potentially noncopyable elements that stores a small
/// number of elements inline and spills to heap storage only when it has to.
///
/// This is the deque counterpart to ``NetworkSmallUniqueArray``, for callers that
/// need a cheap `prepend` or `popFirst` as well as a cheap `append` — `FrameArray`
/// and the `PendingEvent` queues both do. It uses the same inline-storage
/// representation, so the one- and two-element cases cost close to nothing, and
/// the same ``NetworkInlineStorable`` protocol, so element types that already
/// conform need no further declarations.
///
/// | Operation (2 inline, `Frame` elements) | This type | `NetworkUniqueDeque` |
/// | --- | --- | --- |
/// | `append` + `popFirst` | 1.0 ns/op | 11.1 ns/op |
/// | 2× `prepend` + 2× `popFirst` | 10.1 ns/op | 17.9 ns/op |
/// | empty construction | no allocation | allocates |
///
/// ## Representation
///
/// Inline storage is a *trivial* `InlineArray` of `Element.InlineSlot` used as a
/// ring buffer, and `_count` records how many elements are live. As with
/// ``NetworkSmallUniqueArray``, nothing reads the raw storage until `_count` says
/// it is live, so the optimizer deletes the storage initialization outright and
/// creating an empty deque writes nothing. Adding the ring's head index does not
/// change that.
///
/// Three invariants hold at all times, and every operation is written to preserve
/// them:
///
/// 1. Logical index `i` lives in slot `(_head + i) % InlineCapacity`. Only
///    `min(_count, InlineCapacity)` slots hold initialized elements.
/// 2. Inline storage holds the **front** of the deque; overflow holds the tail,
///    in order. So logical index `i >= InlineCapacity` is
///    `_overflowStorage[i - InlineCapacity]`.
/// 3. Inline storage stays **densely packed from the front**: overflow is
///    non-empty only when inline storage is completely full.
///
/// Invariant 3 is what makes the boundary between the two storage areas work, and
/// it is why removing from the front has to pull an element back from overflow.
///
/// ## Capacity
///
/// `InlineCapacity` is a number of elements. Size it for the number you actually
/// expect to be common: inline storage is part of the containing value, so a large
/// capacity times a large `Element` makes every move of the enclosing type more
/// expensive.
@usableFromInline
@available(Network 0.1.0, *)
struct NetworkSmallUniqueDeque<
    Element: NetworkInlineStorable & ~Copyable,
    let InlineCapacity: Int
>: ~Copyable {
    /// Trivial raw backing store, used as a ring buffer.
    var _inlineStorage: InlineArray<InlineCapacity, Element.InlineSlot>

    /// Slot holding logical index 0.
    var _head: Int

    /// The total number of elements, inline plus overflow.
    var _count: Int

    /// Elements past `InlineCapacity`, in order. Allocates nothing while empty.
    var _overflowStorage: NetworkUniqueDeque<Element>

    /// The number of elements that fit inline.
    @inline(__always)
    static var inlineCapacity: Int { InlineCapacity }

    @inline(__always)
    init() {
        NetworkSmallUniqueArray<Element, InlineCapacity>._checkInlineSlot()
        // Never read before `_count` marks a slot live, so this initialization is
        // dead and the optimizer removes it.
        _inlineStorage = .init({ _ in .zero })
        _head = 0
        _count = 0
        _overflowStorage = .init(minimumCapacity: 0)
    }

    /// The total number of elements.
    @inline(__always)
    var count: Int { _count }

    @inline(__always)
    var isEmpty: Bool { _count == 0 }

    /// The number of elements currently held in inline storage.
    @inline(__always)
    var _inlineCount: Int {
        Swift.min(_count, InlineCapacity)
    }

    // MARK: - Ring addressing

    /// The slot holding logical index `index`.
    ///
    /// A compare-and-subtract rather than `%`: the modulus would emit a division.
    @inline(__always)
    func _slot(_ index: Int) -> Int {
        let raw = _head &+ index
        return raw >= InlineCapacity ? raw &- InlineCapacity : raw
    }

    /// The slot one position before `slot`, wrapping.
    @inline(__always)
    func _slotBefore(_ slot: Int) -> Int {
        slot == 0 ? InlineCapacity &- 1 : slot &- 1
    }

    /// The address of inline slot 0.
    ///
    /// See ``NetworkSmallUniqueArray/_inlineBase()`` for why the address must come
    /// from `mutableSpan`, and why the pointer is extracted into a typed `let`
    /// rather than used inside the closure.
    @inline(__always)
    mutating func _inlineBase() -> UnsafeMutablePointer<Element> {
        var span = _inlineStorage.mutableSpan
        let base: UnsafeMutablePointer<Element> = span.withUnsafeMutableBufferPointer { buffer in
            UnsafeMutableRawPointer(buffer.baseAddress.unsafelyUnwrapped)
                .assumingMemoryBound(to: Element.self)
        }
        return base
    }

    // MARK: - Adding elements

    /// Appends an element to the back.
    ///
    /// - Complexity: O(1)
    @inline(__always)
    mutating func append(_ element: consuming Element) {
        if _fastPath(_count < InlineCapacity) {
            let slot = _slot(_count)
            // An Optional shuttle is how a consumed value crosses into the
            // pointer store; a closure cannot consume a capture.
            var shuttle: Element? = consume element
            _inlineBase().advanced(by: slot).initialize(to: shuttle.take()!)
        } else {
            _appendToOverflow(element)
        }
        _count &+= 1
    }

    @inline(never)
    mutating func _appendToOverflow(_ element: consuming Element) {
        _overflowStorage.append(element)
    }

    /// Prepends an element to the front.
    ///
    /// - Complexity: O(1)
    @inline(__always)
    mutating func prepend(_ element: consuming Element) {
        if _fastPath(_count < InlineCapacity) {
            let slot = _slotBefore(_head)
            var shuttle: Element? = consume element
            _inlineBase().advanced(by: slot).initialize(to: shuttle.take()!)
            _head = slot
        } else {
            _prependWhenInlineFull(element)
        }
        _count &+= 1
    }

    /// Inline storage is full, so evict its last element to the *front* of
    /// overflow — preserving invariant 2 — and take the slot that frees up.
    @inline(never)
    mutating func _prependWhenInlineFull(_ element: consuming Element) {
        let lastSlot = _slot(InlineCapacity &- 1)
        var evicted: Element? = _inlineBase().advanced(by: lastSlot).move()
        _overflowStorage.prepend(evicted.take()!)
        let slot = _slotBefore(_head)
        var shuttle: Element? = consume element
        _inlineBase().advanced(by: slot).initialize(to: shuttle.take()!)
        _head = slot
    }

    // MARK: - Removing elements

    /// Removes and returns the first element, or `nil` if the deque is empty.
    ///
    /// - Complexity: O(1)
    @inline(__always)
    mutating func popFirst() -> Element? {
        if _count == 0 { return nil }
        let taken = _inlineBase().advanced(by: _head).move()
        _head = _head &+ 1 == InlineCapacity ? 0 : _head &+ 1
        _count &-= 1
        if _slowPath(!_overflowStorage.isEmpty) {
            _refillTailFromOverflow()
        }
        return taken
    }

    /// Removes and returns the last element, or `nil` if the deque is empty.
    ///
    /// - Complexity: O(1)
    @inline(__always)
    mutating func popLast() -> Element? {
        if _count == 0 { return nil }
        if _slowPath(_count > InlineCapacity) {
            // By invariant 2 the tail lives in overflow.
            _count &-= 1
            return _overflowStorage.popLast()
        }
        let slot = _slot(_count &- 1)
        _count &-= 1
        return _inlineBase().advanced(by: slot).move()
    }

    /// Removes and returns the first element.
    ///
    /// - Precondition: The deque is not empty.
    /// - Complexity: O(1)
    @inline(__always)
    mutating func removeFirst() -> Element {
        precondition(_count > 0, "Can't remove first element from an empty deque")
        var popped = popFirst()
        return popped.take()!
    }

    /// Pulls the first overflow element into the inline slot that just opened at
    /// the tail, restoring invariant 3.
    ///
    /// `_count` has already been decremented by the caller, so the vacant logical
    /// index is `_inlineCount - 1`. Using `_inlineCount` here instead is an
    /// off-by-one that only shows up once overflow is non-empty.
    @inline(never)
    mutating func _refillTailFromOverflow() {
        var shuttle: Element? = _overflowStorage.popFirst()
        let slot = _slot(_inlineCount &- 1)
        _inlineBase().advanced(by: slot).initialize(to: shuttle.take()!)
    }

    /// Removes and returns the element at `index`.
    ///
    /// - Precondition: `index` is a valid index of the deque.
    /// - Complexity: O(`InlineCapacity`) for an inline index, plus the cost of
    ///   removing from the overflow deque otherwise.
    @discardableResult
    mutating func remove(at index: Int) -> Element {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            // Entirely within overflow; nothing inline has to move.
            let removed = _overflowStorage.remove(at: index &- InlineCapacity)
            _count &-= 1
            return removed
        }

        let inlineCount = _inlineCount
        let base = _inlineBase()
        let removed = base.advanced(by: _slot(index)).move()

        // Close the gap from whichever side is shorter. Shifting the front up
        // lets us just advance `_head`.
        if index <= inlineCount &- 1 &- index {
            var i = index
            while i > 0 {
                base.advanced(by: _slot(i)).initialize(to: base.advanced(by: _slot(i &- 1)).move())
                i &-= 1
            }
            _head = _head &+ 1 == InlineCapacity ? 0 : _head &+ 1
        } else {
            var i = index
            while i < inlineCount &- 1 {
                base.advanced(by: _slot(i)).initialize(to: base.advanced(by: _slot(i &+ 1)).move())
                i &+= 1
            }
        }

        _count &-= 1
        if _slowPath(!_overflowStorage.isEmpty) {
            _refillTailFromOverflow()
        }
        return removed
    }

    // MARK: - Inserting elements

    /// Inserts an element at `index`.
    ///
    /// Unlike the ends, a mid-deque insert cannot be O(1) with a ring buffer: it
    /// shifts the inline elements after `index` and, when inline storage is full,
    /// pushes its last element into overflow.
    ///
    /// - Precondition: `index` is a valid insertion index of the deque.
    /// - Complexity: O(*n*)
    mutating func insert(_ element: consuming Element, at index: Int) {
        precondition(index >= 0 && index <= _count, "Index out of range")
        if index >= InlineCapacity {
            _overflowStorage.insert(element, at: index &- InlineCapacity)
            _count &+= 1
            return
        }

        // Make room inline, spilling the last inline element if there is none.
        if _count >= InlineCapacity {
            let lastSlot = _slot(InlineCapacity &- 1)
            var evicted: Element? = _inlineBase().advanced(by: lastSlot).move()
            _overflowStorage.prepend(evicted.take()!)
        }

        let inlineCount = Swift.min(_count &+ 1, InlineCapacity)
        let base = _inlineBase()
        // Shift `[index, inlineCount - 1)` back one position, walking from the
        // end so no element is overwritten before it moves.
        var i = inlineCount &- 1
        while i > index {
            base.advanced(by: _slot(i)).initialize(to: base.advanced(by: _slot(i &- 1)).move())
            i &-= 1
        }
        var shuttle: Element? = consume element
        base.advanced(by: _slot(index)).initialize(to: shuttle.take()!)
        _count &+= 1
    }

    // MARK: - Accessing elements

    /// Calls `body` with the element at `index`, borrowed in place.
    ///
    /// Elements are reached through scoped closures rather than a subscript for
    /// the same reason as ``NetworkSmallUniqueArray``: a subscript's read accessor
    /// would have to derive an address from a *borrow* of the inline storage, and
    /// such an address does not reliably point at the real storage.
    ///
    /// - Precondition: `index` is a valid index of the deque.
    @inline(__always)
    mutating func withElement<R: ~Copyable>(
        at index: Int,
        _ body: (borrowing Element) -> R
    ) -> R {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            return body(_overflowStorage[index &- InlineCapacity])
        }
        return body(_inlineBase().advanced(by: _slot(index)).pointee)
    }

    /// Calls `body` with the element at `index`, available for mutation in place.
    /// The element is never copied or moved.
    ///
    /// - Precondition: `index` is a valid index of the deque.
    @inline(__always)
    mutating func withMutableElement<R: ~Copyable>(
        at index: Int,
        _ body: (inout Element) -> R
    ) -> R {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            return body(&_overflowStorage[index &- InlineCapacity])
        }
        return body(&_inlineBase().advanced(by: _slot(index)).pointee)
    }

    /// Calls `body` with the element at `index`, borrowed in place, without
    /// requiring mutable access to the deque.
    ///
    /// Prefer ``withElement(at:_:)`` where a mutable borrow is available. This
    /// variant exists for non-`mutating` contexts. The address is derived inside
    /// the span's scope and never escapes it — an *escaping* address taken from a
    /// borrow of the inline storage may point into a temporary copy.
    ///
    /// - Precondition: `index` is a valid index of the deque.
    @inline(__always)
    borrowing func borrowingWithElement<R: ~Copyable>(
        at index: Int,
        _ body: (borrowing Element) -> R
    ) -> R {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            return body(_overflowStorage[index &- InlineCapacity])
        }
        let span = _inlineStorage.span
        return span.withUnsafeBufferPointer { buffer in
            body(
                UnsafeRawPointer(buffer.baseAddress.unsafelyUnwrapped)
                    .advanced(by: _slot(index) &* MemoryLayout<Element>.stride)
                    .assumingMemoryBound(to: Element.self)
                    .pointee
            )
        }
    }

    /// The address of the element at `index`.
    ///
    /// This exists for callers that need an element *address* rather than a
    /// borrow — to build a `Span` into the element's own storage, say, which a
    /// closure accessor cannot return because non-escapable values cannot cross a
    /// closure boundary.
    ///
    /// It is `mutating` because only the *mutable* span reliably addresses the
    /// real inline storage; an address derived from a borrow may point into a
    /// temporary copy of the trivial storage and silently read garbage.
    ///
    /// - Warning: The address is invalidated by any subsequent append, prepend,
    ///   removal, or insertion.
    /// - Precondition: `index` is a valid index of the deque.
    @inline(__always)
    mutating func elementAddress(at index: Int) -> UnsafeMutablePointer<Element> {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            // The overflow deque is a non-contiguous ring, so there is no span to
            // take an address from; use its own mutable addressor.
            return withUnsafeMutablePointer(to: &_overflowStorage[index &- InlineCapacity]) { $0 }
        }
        return _inlineBase().advanced(by: _slot(index))
    }

    deinit {
        let inlineCount = _inlineCount
        if inlineCount > 0 {
            let head = _head
            // `span` is unavailable here (it would escape a borrow of a value
            // being destroyed), so address the storage directly. This only has to
            // *read* the elements out to destroy them.
            withUnsafePointer(to: _inlineStorage) { storage in
                let base = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(storage))
                    .assumingMemoryBound(to: Element.self)
                // Walk the ring; the live region may wrap past slot 0.
                for i in 0..<inlineCount {
                    let raw = head &+ i
                    let slot = raw >= InlineCapacity ? raw &- InlineCapacity : raw
                    base.advanced(by: slot).deinitialize(count: 1)
                }
            }
        }
        // `_overflowStorage` destroys its own elements.
    }
}

#endif
