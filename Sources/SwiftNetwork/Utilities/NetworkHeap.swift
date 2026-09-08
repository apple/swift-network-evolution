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

@available(Network 0.1.0, *)
internal struct NetworkHeap<Element: NetworkComparable & ~Copyable>: ~Copyable {
    internal var storage: NetworkUniqueArray<Element>

    init(_ storage: consuming NetworkUniqueArray<Element>) {
        self.storage = storage
    }

    internal init() {
        self.storage = .init()
    }

    @inlinable
    internal func comparator(_ lhs: borrowing Element, _ rhs: borrowing Element) -> Bool {
        // This heap is always a min-heap.
        lhs < rhs
    }

    // named `PARENT` in CLRS
    @inlinable
    internal func parentIndex(_ i: Int) -> Int {
        (i - 1) / 2
    }

    // named `LEFT` in CLRS
    @inlinable
    internal func leftIndex(_ i: Int) -> Int {
        2 * i + 1
    }

    // named `RIGHT` in CLRS
    @inlinable
    internal func rightIndex(_ i: Int) -> Int {
        2 * i + 2
    }

    // named `MAX-HEAPIFY` in CLRS
    mutating func _heapify(_ index: Int) {
        let left = self.leftIndex(index)
        let right = self.rightIndex(index)

        var root: Int
        if left <= (self.storage.count - 1) && self.comparator(storage[left], storage[index]) {
            root = left
        } else {
            root = index
        }

        if right <= (self.storage.count - 1) && self.comparator(storage[right], storage[root]) {
            root = right
        }

        if root != index {
            self.storage.swapAt(index, root)
            self._heapify(root)
        }
    }

    mutating func _heapRootify(index: Int, keyIdx: Int) {
        var index = index
        if self.comparator(storage[index], storage[keyIdx]) {
            fatalError("New key must be closer to the root than current key")
        }

        self.storage.swapAt(index, keyIdx)
        while index > 0 && self.comparator(self.storage[index], self.storage[self.parentIndex(index)]) {
            self.storage.swapAt(index, self.parentIndex(index))
            index = self.parentIndex(index)
        }
    }

    internal mutating func append(_ value: consuming Element) {
        var i = self.storage.count
        self.storage.append(value)
        while i > 0 && self.comparator(self.storage[i], self.storage[self.parentIndex(i)]) {
            self.storage.swapAt(i, self.parentIndex(i))
            i = self.parentIndex(i)
        }
    }

    @discardableResult
    internal mutating func removeRoot() -> Element? {
        self._remove(index: 0)
    }

    @discardableResult
    internal mutating func remove(value: borrowing Element) -> Bool {
        for idx in self.storage.indices {
            if self.storage[idx] == value {
                self._remove(index: idx)
                return true
            }
        }

        return false
    }

    @discardableResult
    internal mutating func removeFirst(where shouldBeRemoved: (borrowing Element) throws -> Bool) rethrows -> Element? {
        guard self.storage.count > 0 else {
            return nil
        }

        for idx in self.storage.indices {
            if try shouldBeRemoved(self.storage[idx]) {
                return self._remove(index: idx)
            }
        }

        return nil
    }

    @discardableResult
    mutating func _remove(index: Int) -> Element? {
        guard self.storage.count > 0 else {
            return nil
        }

        let element: Element?

        if self.storage.count == 1 || self.storage[index] == self.storage[self.storage.count - 1] {
            element = self.storage.removeLast()
        } else if !self.comparator(self.storage[index], self.storage[self.storage.count - 1]) {
            self._heapRootify(index: index, keyIdx: self.storage.count - 1)
            element = self.storage.removeLast()
        } else {
            self.storage.swapAt(index, self.storage.count - 1)
            element = self.storage.removeLast()
            self._heapify(index)
        }

        return element
    }
}

@available(Network 0.1.0, *)
extension NetworkHeap where Element: ~Copyable {
    var startIndex: Int {
        self.storage.startIndex
    }

    var endIndex: Int {
        self.storage.endIndex
    }

    var underestimatedCount: Int {
        self.storage.count
    }

    subscript(position: Int) -> Element {
        // FIXME: When you can use https://github.com/swiftlang/swift/pull/84180,
        // do so.
        unsafeAddress {
            storage.span.withUnsafeBufferPointer { $0.baseAddress! + position }
        }
        @inline(always)
        unsafeMutableAddress {
            var span = storage.mutableSpan
            return span.withUnsafeMutableBufferPointer { $0.baseAddress! + position }
        }
    }

    @inlinable
    func index(after i: Int) -> Int {
        i + 1
    }

    var count: Int {
        self.storage.count
    }
}

@available(Network 0.1.0, *)
extension NetworkHeap {
    func copy() -> NetworkHeap<Element> {
        NetworkHeap(self.storage.clone())
    }
}
@available(Network 0.1.0, *)
extension NetworkHeap: Sendable where Element: Sendable & ~Copyable {}
