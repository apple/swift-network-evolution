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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkMarkedDequeTests: NetTestCase {
    private func drain(_ queue: inout NetworkUniqueMarkedDeque<Int>) -> [Int] {
        var result: [Int] = []
        while let next = queue.popFirst() {
            result.append(next)
        }
        return result
    }

    private func drainPriorities(_ queue: inout NetworkUniqueMarkedDeque<WriteRequest>) -> [Double] {
        var result: [Double] = []
        while var next = queue.popFirst() {
            result.append(next.relativePriority)
            next.frame.finalize(success: true)
        }
        return result
    }

    private func append(_ priority: Double, to queue: inout NetworkUniqueMarkedDeque<WriteRequest>) {
        var request = WriteRequest(content: [1], isComplete: false, completion: nil)
        request.relativePriority = priority
        queue.appendOrderedByPriority(request)
    }

    func testAppendAndPopAreFirstInFirstOut() {
        var queue = NetworkUniqueMarkedDeque<Int>()
        queue.append(1)
        queue.append(2)
        queue.append(3)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(drain(&queue), [1, 2, 3])
        XCTAssertTrue(queue.isEmpty)
    }

    func testMarkCoversEverythingQueuedSoFar() {
        var queue = NetworkUniqueMarkedDeque<Int>()
        queue.append(1)
        queue.append(2)
        XCTAssertEqual(queue.markedCount, 0)
        queue.mark()
        queue.append(3)
        XCTAssertEqual(queue.markedCount, 2)
        XCTAssertEqual(queue.unmarkedCount, 1)
    }

    func testPoppingShrinksTheMarkAndStopsAtZero() {
        var queue = NetworkUniqueMarkedDeque<Int>()
        queue.append(1)
        queue.mark()
        queue.append(2)
        XCTAssertEqual(queue.popFirst(), 1)
        XCTAssertEqual(queue.markedCount, 0)
        XCTAssertEqual(queue.popFirst(), 2)
        XCTAssertEqual(queue.markedCount, 0)
        XCTAssertNil(queue.popFirst())
    }

    func testRemoveMarkLeavesTheElementsQueued() {
        var queue = NetworkUniqueMarkedDeque<Int>()
        queue.append(1)
        queue.append(2)
        queue.mark()
        queue.removeMark()
        XCTAssertEqual(queue.markedCount, 0)
        XCTAssertEqual(queue.count, 2)
    }

    func testInsertGoesAheadOfTheMatchingTrailingElements() {
        var queue = NetworkUniqueMarkedDeque<Int>()
        for value in [10, 20, 30] {
            queue.append(value)
        }
        queue.insert(25, aheadOfTrailing: { $0 > 25 })
        XCTAssertEqual(drain(&queue), [10, 20, 25, 30])
    }

    func testInsertNeverPassesTheMark() {
        var queue = NetworkUniqueMarkedDeque<Int>()
        for value in [10, 20] {
            queue.append(value)
        }
        queue.mark()
        queue.append(30)
        queue.insert(5, aheadOfTrailing: { _ in true })
        XCTAssertEqual(drain(&queue), [10, 20, 5, 30])
    }

    func testPriorityInsertionStopsAtTheMark() {
        var queue = NetworkUniqueMarkedDeque<WriteRequest>()
        append(0.2, to: &queue)
        queue.mark()
        append(0.5, to: &queue)
        append(0.9, to: &queue)
        append(0.5, to: &queue)
        XCTAssertEqual(drainPriorities(&queue), [0.2, 0.9, 0.5, 0.5])
    }

    func testPriorityInsertionWithoutAMarkOrdersEverything() {
        var queue = NetworkUniqueMarkedDeque<WriteRequest>()
        for priority in [0.2, 0.5, 0.9, 0.5] {
            append(priority, to: &queue)
        }
        XCTAssertEqual(drainPriorities(&queue), [0.9, 0.5, 0.5, 0.2])
    }
}
