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

/// A trivial blob of memory used as raw inline storage for one element.
///
/// Conformers must be bitwise-copyable and have no meaningful value of their
/// own: ``NetworkSmallUniqueArray`` reinterprets them as element storage.
@usableFromInline
@available(Network 0.1.0, *)
protocol NetworkInlineStorageSlot: BitwiseCopyable, Sendable {
    /// An all-zero instance, used to bring the raw storage into existence.
    static var zero: Self { get }
}

@available(Network 0.1.0, *)
extension InlineArray: NetworkInlineStorageSlot where Element == UInt64 {
    @usableFromInline
    static var zero: Self { .init(repeating: 0) }
}

/// An element type that ``NetworkSmallUniqueArray`` can store inline.
///
/// Conformers declare a slot large enough to hold one element. Stating it once
/// here, next to the element type, is what lets `NetworkSmallUniqueArray` take
/// its capacity as a count of *elements* rather than a count of machine words:
///
/// ```swift
/// extension Frame: NetworkInlineStorable {
///     // Frame is 136 bytes.
///     typealias InlineSlot = InlineArray<17, UInt64>
/// }
///
/// var frames = NetworkSmallUniqueArray<Frame, 2>()
/// ```
///
/// Swift's value generics cannot yet perform arithmetic or read `MemoryLayout`,
/// so the slot's word count has to be written out. It only has to be written
/// once, and ``NetworkSmallUniqueArray`` checks it on construction, so growing
/// the element type past its slot traps with a clear message instead of
/// corrupting memory. A test asserting the element's `stride` will catch it even
/// earlier.
@usableFromInline
@available(Network 0.1.0, *)
protocol NetworkInlineStorable: ~Copyable {
    /// Raw storage at least `MemoryLayout<Self>.stride` bytes wide, and at least
    /// as aligned as `Self`.
    associatedtype InlineSlot: NetworkInlineStorageSlot
}

/// An array of potentially noncopyable elements that stores a small number of
/// elements inline and spills to heap storage only when it has to.
///
/// This is tuned for the shape of traffic seen by `FrameArray` and the
/// `PendingEvent` queues: almost always one or two elements, occasionally many.
/// The design goal is that the common cases cost as close to nothing as
/// possible.
///
/// ## Representation
///
/// The inline storage is a *trivial* `InlineArray` of `Element.InlineSlot`, and
/// `_count` alone records which slots hold live elements. Two properties follow
/// from that, and they are the whole reason this type is fast:
///
/// - **Creating an empty array writes nothing.** There are no per-slot
///   `Optional` tags to set to `nil`. Because nothing reads the raw storage
///   until `_count` says it is live, the optimizer deletes the storage
///   initialization outright.
/// - **No per-element tag traffic.** Appending writes only the element and the
///   count; removing reads only the count. A tagged representation must also
///   write a discriminator on every append and test it on every access and on
///   every deinit.
///
/// Two tagged alternatives were measured against a 136-byte `Frame` and both are
/// dramatically worse, for the same underlying reason — the tag is load-bearing
/// on the destroy path, so it cannot be optimized away:
///
/// | Inline storage | append + remove | empty array |
/// | --- | --- | --- |
/// | `InlineArray<N, Element.InlineSlot>` (this type) | 1.0 ns/op | 18 instr |
/// | `InlineArray<N, Element?>` | 28.0 ns/op | 56 instr |
/// | `Optional<InlineArray<N, Element>>` | 12.1 ns/op | 19 instr |
///
/// The third row is worth calling out because it looks ideal: the compiler sizes
/// the storage exactly, so no slot declaration is needed at all. It is 12× slower.
///
/// Elements beyond `InlineCapacity` spill into a `NetworkUniqueArray`, which
/// performs no allocation while it is empty, so the overflow path costs nothing
/// until it is used.
///
/// ## Capacity
///
/// `InlineCapacity` is a number of elements. Size it for the number you actually
/// expect to be common: inline storage is part of the containing value, so a
/// large capacity times a large `Element` makes every move of the enclosing type
/// more expensive.
@usableFromInline
@available(Network 0.1.0, *)
struct NetworkSmallUniqueArray<
    Element: NetworkInlineStorable & ~Copyable,
    let InlineCapacity: Int
>: ~Copyable {
    /// Trivial raw backing store for the inline elements.
    ///
    /// Only the first `min(_count, InlineCapacity)` element-strides hold
    /// initialized elements; the rest is uninitialized garbage.
    var _inlineStorage: InlineArray<InlineCapacity, Element.InlineSlot>

    /// The total number of elements, inline plus overflow.
    ///
    /// This doubles as the tag: it is the only thing that says which inline
    /// slots are live.
    var _count: Int

    /// Elements past `InlineCapacity`. Allocates nothing while empty.
    var _overflowStorage: NetworkUniqueArray<Element>

    /// The number of elements that fit inline.
    @inline(always)
    static var inlineCapacity: Int { InlineCapacity }

    /// Traps if `Element.InlineSlot` cannot hold an `Element`.
    ///
    /// This is the one invariant a slot declaration has to satisfy. Swift has no
    /// static assertion, so it is checked on construction instead; the check
    /// folds away entirely when it holds.
    @inline(always)
    static func _checkInlineSlot() {
        precondition(
            MemoryLayout<Element.InlineSlot>.stride >= MemoryLayout<Element>.stride,
            "InlineSlot is too small to hold Element"
        )
        precondition(
            MemoryLayout<Element.InlineSlot>.alignment >= MemoryLayout<Element>.alignment,
            "InlineSlot is less aligned than Element"
        )
    }

    @inline(always)
    init() {
        Self._checkInlineSlot()
        // Never read before `_count` marks a slot live, so this initialization
        // is dead and the optimizer removes it.
        _inlineStorage = .init({ _ in .zero })
        _count = 0
        _overflowStorage = .init(minimumCapacity: 0)
    }

    /// The total number of elements.
    @inline(always)
    var count: Int { _count }

    @inline(always)
    var isEmpty: Bool { _count == 0 }

    /// The number of elements currently held in inline storage.
    @inline(always)
    var _inlineCount: Int {
        Swift.min(_count, InlineCapacity)
    }

    // MARK: - Adding elements

    /// Appends an element, spilling to heap storage past the inline capacity.
    @inline(always)
    mutating func append(_ element: consuming Element) {
        if _fastPath(_count < InlineCapacity) {
            let index = _count
            // An Optional shuttle is how a consumed value crosses into the
            // pointer store; a closure cannot consume a capture.
            var shuttle: Element? = consume element
            _inlineBase().advanced(by: index).initialize(to: shuttle.take()!)
        } else {
            _appendToOverflow(element)
        }
        _count &+= 1
    }

    /// Out-of-line slow path, kept separate so it does not bloat `append`.
    @inline(never)
    mutating func _appendToOverflow(_ element: consuming Element) {
        _overflowStorage.append(element)
    }

    /// Reserves enough overflow storage to hold `n` elements beyond
    /// `InlineCapacity` without reallocating.
    ///
    /// Inline capacity is fixed at compile time, so this only affects the
    /// overflow storage.
    @inline(always)
    mutating func reserveCapacity(_ n: Int) {
        let overflowCount = max(0, n &- InlineCapacity)
        _overflowStorage.reserveCapacity(overflowCount)
    }

    // MARK: - Removing elements

    /// Removes and returns the first element.
    ///
    /// - Precondition: The array is not empty.
    @inline(always)
    mutating func removeFirst() -> Element {
        precondition(_count > 0, "Can't remove first element from an empty array")
        return _removeInline(at: 0)
    }

    /// Removes and returns the element at `index`.
    ///
    /// - Precondition: `index` is a valid index of the array.
    @discardableResult
    mutating func remove(at index: Int) -> Element {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            // Entirely within overflow storage; nothing inline has to move.
            let removed = _overflowStorage.remove(at: index &- InlineCapacity)
            _count &-= 1
            return removed
        }
        return _removeInline(at: index)
    }

    /// Removes an element held in inline storage, closing the gap it leaves.
    @inline(always)
    mutating func _removeInline(at index: Int) -> Element {
        let inlineCount = _inlineCount
        let base = _inlineBase()
        let removed = base.advanced(by: index).move()
        // Slide the surviving inline elements down over the hole.
        var source = index &+ 1
        while source < inlineCount {
            base.advanced(by: source &- 1).initialize(to: base.advanced(by: source).move())
            source &+= 1
        }
        // Promote the first overflow element into the slot that just opened up,
        // keeping inline storage densely packed.
        if _slowPath(!_overflowStorage.isEmpty) {
            _promoteFirstOverflowElement(to: inlineCount &- 1)
        }
        _count &-= 1
        return removed
    }

    /// Moves the first overflow element into the given inline slot.
    @inline(never)
    mutating func _promoteFirstOverflowElement(to index: Int) {
        var shuttle: Element? = _overflowStorage.remove(at: 0)
        _inlineBase().advanced(by: index).initialize(to: shuttle.take()!)
    }

    // MARK: - Accessing elements

    /// Calls `body` with the element at `index`, borrowed in place.
    ///
    /// Elements are reached through scoped closures rather than a subscript
    /// because a subscript's read accessor would have to derive an address from
    /// a *borrow* of the inline storage, and such an address does not reliably
    /// point at the real storage.
    ///
    /// - Precondition: `index` is a valid index of the array.
    @inline(always)
    mutating func withElement<R: ~Copyable>(
        at index: Int,
        _ body: (borrowing Element) -> R
    ) -> R {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            return body(_overflowStorage[index &- InlineCapacity])
        }
        return body(_inlineBase().advanced(by: index).pointee)
    }

    /// Calls `body` with the element at `index`, available for mutation in
    /// place. The element is never copied or moved.
    ///
    /// - Precondition: `index` is a valid index of the array.
    @inline(always)
    mutating func withMutableElement<R: ~Copyable>(
        at index: Int,
        _ body: (inout Element) -> R
    ) -> R {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            return body(&_overflowStorage[index &- InlineCapacity])
        }
        return body(&_inlineBase().advanced(by: index).pointee)
    }

    // MARK: - Raw storage addressing

    /// The address of inline element 0.
    ///
    /// The address has to come from the storage's `mutableSpan`:
    /// `withUnsafeMutablePointer(to: &_inlineStorage)` may hand back a pointer
    /// into a *temporary copy* of the trivial storage, so writes through it are
    /// silently lost once the array also holds overflow elements.
    ///
    /// Extracting the pointer into a typed `let` and returning it — rather than
    /// doing the work inside `withUnsafeMutableBufferPointer` — is what keeps
    /// this allocation-free. Performing the element store inside that closure
    /// makes the `Optional` shuttle escape into a heap box, which measured four
    /// `swift_slowDealloc` calls and 132 instructions on the hot path versus 27
    /// here.
    @inline(always)
    mutating func _inlineBase() -> UnsafeMutablePointer<Element> {
        var span = _inlineStorage.mutableSpan
        let base: UnsafeMutablePointer<Element> = span.withUnsafeMutableBufferPointer { buffer in
            UnsafeMutableRawPointer(buffer.baseAddress.unsafelyUnwrapped)
                .assumingMemoryBound(to: Element.self)
        }
        return base
    }

    deinit {
        let inlineCount = _inlineCount
        if inlineCount > 0 {
            // `span` is unavailable here (it would escape a borrow of a value
            // being destroyed), so address the storage directly. Unlike the
            // mutating paths this only has to *read* the elements out to
            // destroy them, and `withUnsafePointer` guarantees the copy it may
            // make holds the same element values.
            let _ = withUnsafePointer(to: _inlineStorage) { storage in
                UnsafeMutableRawPointer(mutating: UnsafeRawPointer(storage))
                    .assumingMemoryBound(to: Element.self)
                    .deinitialize(count: inlineCount)
            }
        }
        // `_overflowStorage` destroys its own elements.
    }
}

// MARK: - Copyable element convenience

@available(Network 0.1.0, *)
extension NetworkSmallUniqueArray where Element: Copyable {
    /// Reads the element at `index` by copy, without requiring mutating access.
    ///
    /// - Precondition: `index` is a valid index of the array.
    @inline(always)
    func _copyElement(at index: Int) -> Element {
        precondition(index >= 0 && index < _count, "Index out of range")
        if index >= InlineCapacity {
            return _overflowStorage[index &- InlineCapacity]
        }
        return withUnsafePointer(to: _inlineStorage) { storage in
            UnsafeRawPointer(storage)
                .assumingMemoryBound(to: Element.self)[index]
        }
    }

    /// Accesses the element at `index` by copy.
    ///
    /// Only available for `Copyable` elements: a subscript's read accessor
    /// would otherwise have to derive an address from a borrow of the inline
    /// storage, which does not reliably point at the real storage. See
    /// ``withElement(at:_:)`` and ``withMutableElement(at:_:)`` for the
    /// noncopyable-safe access pattern this bypasses.
    @inline(always)
    subscript(index: Int) -> Element {
        get { _copyElement(at: index) }
        set { withMutableElement(at: index) { $0 = newValue } }
    }

    /// Creates an array holding the elements of `sequence`, in order.
    @inline(always)
    init<S: Sequence>(_ sequence: S) where S.Element == Element {
        self.init()
        for element in sequence {
            append(element)
        }
    }

    /// Creates an array with `count` copies of `element`.
    @inline(always)
    init(repeating element: Element, count: Int) {
        self.init()
        for _ in 0..<count {
            append(element)
        }
    }

    /// Returns an independent `Array` holding a copy of every element, in order.
    func toArray() -> [Element] {
        var result = [Element]()
        result.reserveCapacity(_count)
        let inlineCount = _inlineCount
        if inlineCount > 0 {
            withUnsafePointer(to: _inlineStorage) { storage in
                let base = UnsafeRawPointer(storage).assumingMemoryBound(to: Element.self)
                for i in 0..<inlineCount {
                    result.append(base[i])
                }
            }
        }
        for i in 0..<(_count &- inlineCount) {
            result.append(_overflowStorage[i])
        }
        return result
    }
}

// MARK: - Element conformances

// Slot sizes are asserted against the real layouts by
// `SwiftNetworkSmallUniqueArrayElementTests`, so a type growing past its slot is
// caught at test time rather than on first use.

/// `Frame` is 136 bytes.
@available(Network 0.1.0, *)
extension Frame: NetworkInlineStorable {
    @usableFromInline
    typealias InlineSlot = InlineArray<17, UInt64>
}

/// `ProtocolEventManagerState.PendingEvent` is 328 bytes (326 rounded to stride).
@available(Network 0.1.0, *)
extension ProtocolEventManagerState.PendingEvent: NetworkInlineStorable {
    @usableFromInline
    typealias InlineSlot = InlineArray<41, UInt64>
}

/// `FrameAckRange` is 16 bytes (two `PacketNumber`, each a wrapped `Int64`).
@available(Network 0.1.0, *)
extension FrameAckRange: NetworkInlineStorable {
    @usableFromInline
    typealias InlineSlot = InlineArray<2, UInt64>
}

#endif
