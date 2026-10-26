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

#if canImport(CollectionsInternal)
internal import CollectionsInternal
#elseif canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

/// A first-in, first-out queue in which the elements at the front can be marked.
///
/// Marking records that the elements currently in the queue have been committed to leave in their
/// present order: later insertions can be placed anywhere behind the mark, but never ahead of it.
/// Popping an element shrinks the mark, so it always covers a prefix of the queue.
@available(Network 0.1.0, *)
struct NetworkUniqueMarkedDeque<Element: ~Copyable>: ~Copyable {
    private var storage = NetworkUniqueDeque<Element>()

    /// The number of elements at the front of the queue that are marked.
    private(set) var markedCount = 0

    init() {}

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    /// The number of elements behind the mark.
    var unmarkedCount: Int {
        storage.count - markedCount
    }

    subscript(position: Int) -> Element {
        _read {
            yield storage[position]
        }
    }

    /// Adds `element` to the back of the queue, behind the mark.
    mutating func append(_ element: consuming Element) {
        storage.append(element)
    }

    /// Inserts `element` ahead of the trailing run of elements for which `isBehindElement` is
    /// true, without passing the mark.
    mutating func insert(
        _ element: consuming Element,
        aheadOfTrailing isBehindElement: (borrowing Element) -> Bool
    ) {
        var index = storage.count
        while index > markedCount && isBehindElement(storage[index - 1]) {
            index -= 1
        }
        storage.insert(element, at: index)
    }

    /// Marks every element currently in the queue.
    mutating func mark() {
        markedCount = storage.count
    }

    /// Removes the mark, leaving every element free to be passed by later insertions.
    mutating func removeMark() {
        markedCount = 0
    }

    mutating func popFirst() -> Element? {
        guard let element = storage.popFirst() else {
            return nil
        }
        if markedCount > 0 {
            markedCount -= 1
        }
        return element
    }
}
