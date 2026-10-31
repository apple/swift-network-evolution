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

/// An array that stores up to two elements inline, falling back to a
/// heap-allocated array only when it holds more than that.
@available(Network 0.1.0, *)
struct SmallArray<Element>: ~Copyable {
    private enum Storage: ~Copyable {
        case empty
        case one(Element)
        case two(Element, Element)
        case many([Element])
    }

    private var storage: Storage

    init() {
        storage = .empty
    }

    /// Wraps the contents of `array`. Intended for interop with test helpers and logging code
    /// that still deal in plain arrays.
    init(_ array: [Element]) {
        switch array.count {
        case 0: storage = .empty
        case 1: storage = .one(array[0])
        case 2: storage = .two(array[0], array[1])
        default: storage = .many(array)
        }
    }

    var isEmpty: Bool {
        switch storage {
        case .empty: return true
        case .one: return false
        case .two: return false
        case .many: return false
        }
    }

    @inline(always)
    var count: Int {
        switch storage {
        case .empty: return 0
        case .one: return 1
        case .two: return 2
        case .many(let elements): return elements.count
        }
    }

    @inline(always)
    subscript(index: Int) -> Element {
        get {
            switch storage {
            case .empty:
                preconditionFailure("Index out of range")
            case .one(let element):
                precondition(index == 0, "Index out of range")
                return element
            case .two(let first, let second):
                switch index {
                case 0: return first
                case 1: return second
                default: preconditionFailure("Index out of range")
                }
            case .many(let elements):
                return elements[index]
            }
        }
        set {
            var taken = Storage.empty
            swap(&taken, &storage)
            switch consume taken {
            case .empty:
                preconditionFailure("Index out of range")
            case .one:
                precondition(index == 0, "Index out of range")
                storage = .one(newValue)
            case .two(let first, let second):
                switch index {
                case 0: storage = .two(newValue, second)
                case 1: storage = .two(first, newValue)
                default: preconditionFailure("Index out of range")
                }
            case .many(var elements):
                elements[index] = newValue
                storage = .many(elements)
            }
        }
    }

    @inline(always)
    mutating func append(_ element: Element) {
        var taken = Storage.empty
        swap(&taken, &storage)
        switch consume taken {
        case .empty:
            storage = .one(element)
        case .one(let first):
            storage = .two(first, element)
        case .two(let first, let second):
            storage = .many([first, second, element])
        case .many(var elements):
            elements.append(element)
            storage = .many(elements)
        }
    }

    /// Removes and returns the element at `index`, demoting back to inline storage if the
    /// remaining count drops to two or fewer.
    @discardableResult
    @inline(always)
    mutating func remove(at index: Int) -> Element {
        var taken = Storage.empty
        swap(&taken, &storage)
        switch consume taken {
        case .empty:
            preconditionFailure("Index out of range")
        case .one(let element):
            precondition(index == 0, "Index out of range")
            storage = .empty
            return element
        case .two(let first, let second):
            switch index {
            case 0:
                storage = .one(second)
                return first
            case 1:
                storage = .one(first)
                return second
            default:
                preconditionFailure("Index out of range")
            }
        case .many(var elements):
            let removed = elements.remove(at: index)
            switch elements.count {
            case 0: storage = .empty
            case 1: storage = .one(elements[0])
            case 2: storage = .two(elements[0], elements[1])
            default: storage = .many(elements)
            }
            return removed
        }
    }

    /// Returns an independent array holding a copy of every element, in order.
    ///
    /// Only for unit tests and shorthand/log formatting
    func toArray() -> [Element] {
        switch storage {
        case .empty: return []
        case .one(let element): return [element]
        case .two(let first, let second): return [first, second]
        case .many(let elements): return elements
        }
    }
}
