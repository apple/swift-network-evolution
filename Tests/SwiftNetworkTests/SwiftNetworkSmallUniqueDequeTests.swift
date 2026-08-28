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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkSmallUniqueDequeTests: NetTestCase {

    /// Four `UInt8`s inline, so the overflow boundary is easy to reach.
    typealias SmallBytes = NetworkSmallUniqueDeque<UInt8, 4>

    /// Capacity two, where the ring wraps quickly and the boundary logic is most
    /// exposed.
    typealias TinyBytes = NetworkSmallUniqueDeque<UInt8, 2>

    /// Reads every element by index, for comparing against a reference array.
    private func contents<let N: Int>(
        _ deque: inout NetworkSmallUniqueDeque<UInt8, N>
    ) -> [UInt8] {
        (0..<deque.count).map { i in deque.withElement(at: i) { $0 } }
    }

    // MARK: - Basics

    func testInlineCapacityIsInElements() {
        XCTAssertEqual(NetworkSmallUniqueDeque<UInt8, 4>.inlineCapacity, 4)
        XCTAssertEqual(NetworkSmallUniqueDeque<UInt64, 7>.inlineCapacity, 7)
    }

    func testEmptyDeque() {
        var elements = SmallBytes()
        XCTAssertEqual(elements.count, 0)
        XCTAssertTrue(elements.isEmpty)
        XCTAssertNil(elements.popFirst())
        XCTAssertNil(elements.popLast())
    }

    func testAppendAndPopFirstIsFIFO() {
        var elements = SmallBytes()
        for i in 0..<12 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.count, 12)
        for i in 0..<12 {
            XCTAssertEqual(elements.popFirst(), UInt8(i))
        }
        XCTAssertTrue(elements.isEmpty)
    }

    func testAppendAndPopLastIsLIFO() {
        var elements = SmallBytes()
        for i in 0..<12 {
            elements.append(UInt8(i))
        }
        for i in (0..<12).reversed() {
            XCTAssertEqual(elements.popLast(), UInt8(i))
        }
        XCTAssertTrue(elements.isEmpty)
    }

    func testPrependReversesOrder() {
        var elements = SmallBytes()
        for i in 0..<12 {
            elements.prepend(UInt8(i))
        }
        XCTAssertEqual(elements.count, 12)
        for i in (0..<12).reversed() {
            XCTAssertEqual(elements.popFirst(), UInt8(i))
        }
        XCTAssertTrue(elements.isEmpty)
    }

    func testRemoveFirst() {
        var elements = SmallBytes()
        for i in 0..<6 {
            elements.append(UInt8(i))
        }
        for i in 0..<6 {
            XCTAssertEqual(elements.removeFirst(), UInt8(i))
        }
        XCTAssertTrue(elements.isEmpty)
    }

    // MARK: - No allocation below capacity

    /// Inline storage must absorb everything up to the capacity, whichever end
    /// the elements arrive at.
    func testStaysInlineBelowCapacity() {
        for fill in 0...SmallBytes.inlineCapacity {
            var appended = SmallBytes()
            var prepended = SmallBytes()
            for i in 0..<fill {
                appended.append(UInt8(i))
                prepended.prepend(UInt8(i))
            }
            XCTAssertTrue(
                appended._overflowStorage.isEmpty,
                "append allocated at fill \(fill)"
            )
            XCTAssertTrue(
                prepended._overflowStorage.isEmpty,
                "prepend allocated at fill \(fill)"
            )
        }
    }

    func testSpillsToOverflowAboveCapacity() {
        var elements = SmallBytes()
        for i in 0..<10 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(
            elements._overflowStorage.count,
            10 - SmallBytes.inlineCapacity
        )
    }

    // MARK: - Ring wraparound

    /// Interleaving `popFirst` and `append` walks the head around the ring, so the
    /// live region ends up straddling slot 0.
    func testRingWrapsAround() {
        var elements = TinyBytes()
        elements.append(0)
        elements.append(1)
        // Each pop/append pair advances the head by one.
        for i in 2..<10 {
            XCTAssertEqual(elements.popFirst(), UInt8(i - 2))
            elements.append(UInt8(i))
            XCTAssertEqual(elements.count, 2)
        }
        XCTAssertEqual(elements.popFirst(), 8)
        XCTAssertEqual(elements.popFirst(), 9)
        XCTAssertTrue(elements.isEmpty)
    }

    /// Mixing both ends keeps the head moving in both directions.
    func testAlternatingEndsPreserveOrder() {
        var elements = TinyBytes()
        elements.append(10)
        elements.prepend(9)
        elements.append(11)
        elements.prepend(8)
        XCTAssertEqual(contents(&elements), [8, 9, 10, 11])
        XCTAssertEqual(elements.popFirst(), 8)
        XCTAssertEqual(elements.popLast(), 11)
        XCTAssertEqual(contents(&elements), [9, 10])
    }

    // MARK: - Boundary cases

    /// `popFirst` must pull an element back from overflow into the slot that just
    /// opened at the tail. Getting the index wrong here duplicates or skips
    /// elements, and only once overflow is non-empty.
    func testPopFirstRefillsFromOverflow() {
        var elements = TinyBytes()
        for i in 0..<4 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements._overflowStorage.count, 2)

        XCTAssertEqual(elements.popFirst(), 0)
        // One element promoted, so inline is full again and overflow shrank.
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements._overflowStorage.count, 1)
        XCTAssertEqual(contents(&elements), [1, 2, 3])
    }

    /// Prepending onto a full inline region must push the evicted element onto the
    /// *front* of overflow, not the back.
    func testPrependWhenInlineFullPreservesOrder() {
        var elements = TinyBytes()
        elements.append(2)
        elements.append(3)
        XCTAssertTrue(elements._overflowStorage.isEmpty)

        elements.prepend(1)
        XCTAssertEqual(elements._overflowStorage.count, 1)
        XCTAssertEqual(contents(&elements), [1, 2, 3])

        elements.prepend(0)
        XCTAssertEqual(contents(&elements), [0, 1, 2, 3])
    }

    /// With overflow non-empty the tail lives in overflow, so `popLast` must come
    /// from there rather than from inline storage.
    func testPopLastComesFromOverflow() {
        var elements = TinyBytes()
        for i in 0..<5 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.popLast(), 4)
        XCTAssertEqual(elements.popLast(), 3)
        XCTAssertEqual(elements.popLast(), 2)
        // Now down to inline storage only.
        XCTAssertTrue(elements._overflowStorage.isEmpty)
        XCTAssertEqual(elements.popLast(), 1)
        XCTAssertEqual(elements.popLast(), 0)
        XCTAssertNil(elements.popLast())
    }

    // MARK: - remove(at:)

    func testRemoveFromFront() {
        var elements = SmallBytes()
        for i in 0..<6 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.remove(at: 0), 0)
        XCTAssertEqual(contents(&elements), [1, 2, 3, 4, 5])
    }

    func testRemoveFromMiddleOfInline() {
        var elements = SmallBytes()
        for i in 0..<6 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.remove(at: 2), 2)
        XCTAssertEqual(contents(&elements), [0, 1, 3, 4, 5])
    }

    /// An index past the inline capacity is handled entirely by overflow.
    func testRemoveFromOverflowRange() {
        var elements = SmallBytes()
        for i in 0..<8 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.remove(at: 6), 6)
        XCTAssertEqual(contents(&elements), [0, 1, 2, 3, 4, 5, 7])
    }

    /// Removal while the ring is rotated exercises the wrapping shift.
    func testRemoveWhileRotated() {
        var elements = SmallBytes()
        for i in 0..<4 {
            elements.append(UInt8(i))
        }
        // Rotate: drop the front two, add two more at the back.
        XCTAssertEqual(elements.popFirst(), 0)
        XCTAssertEqual(elements.popFirst(), 1)
        elements.append(4)
        elements.append(5)
        XCTAssertEqual(contents(&elements), [2, 3, 4, 5])

        XCTAssertEqual(elements.remove(at: 1), 3)
        XCTAssertEqual(contents(&elements), [2, 4, 5])
    }

    // MARK: - insert(at:)

    func testInsertAtFront() {
        var elements = SmallBytes()
        elements.append(1)
        elements.append(2)
        elements.insert(0, at: 0)
        XCTAssertEqual(contents(&elements), [0, 1, 2])
    }

    func testInsertInMiddle() {
        var elements = SmallBytes()
        for i in [0, 1, 3, 4] {
            elements.append(UInt8(i))
        }
        elements.insert(2, at: 2)
        XCTAssertEqual(contents(&elements), [0, 1, 2, 3, 4])
    }

    func testInsertAtEnd() {
        var elements = SmallBytes()
        elements.append(0)
        elements.insert(1, at: 1)
        XCTAssertEqual(contents(&elements), [0, 1])
    }

    /// Inserting into full inline storage spills its last element to overflow.
    func testInsertWhenInlineFull() {
        var elements = TinyBytes()
        elements.append(0)
        elements.append(2)
        elements.insert(1, at: 1)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(contents(&elements), [0, 1, 2])
    }

    /// The `FrameArray.iterateMutableFrames` pattern: remove one element and
    /// insert several in its place.
    func testReplaceOneElementWithSeveral() {
        var elements = SmallBytes()
        for i in [0, 9, 4] {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.remove(at: 1), 9)
        var insertIndex = 1
        for value in [1, 2, 3] {
            elements.insert(UInt8(value), at: insertIndex)
            insertIndex += 1
        }
        XCTAssertEqual(contents(&elements), [0, 1, 2, 3, 4])
    }

    // MARK: - Element access

    func testElementMutate() {
        var elements = SmallBytes()
        for i in 0..<10 {
            elements.append(UInt8(i))
        }
        for i in 0..<10 {
            elements.withMutableElement(at: i) { $0 += 100 }
        }
        XCTAssertEqual(contents(&elements), (0..<10).map { UInt8($0 + 100) })
    }

    // MARK: - Reference model

    /// Random operations across all ends, checked against a plain `Array` after
    /// every step. This is what catches boundary mistakes the targeted tests miss.
    func testRandomOperationsMatchReferenceArray() {
        var elements = TinyBytes()
        var reference: [UInt8] = []
        var next: UInt8 = 0
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D

        func random(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        for _ in 0..<600 {
            switch random(6) {
            case 0:
                elements.append(next)
                reference.append(next)
                next &+= 1
            case 1:
                elements.prepend(next)
                reference.insert(next, at: 0)
                next &+= 1
            case 2:
                XCTAssertEqual(
                    elements.popFirst(),
                    reference.isEmpty ? nil : reference.removeFirst()
                )
            case 3:
                XCTAssertEqual(
                    elements.popLast(),
                    reference.isEmpty ? nil : reference.removeLast()
                )
            case 4:
                if !reference.isEmpty {
                    let index = random(reference.count)
                    XCTAssertEqual(elements.remove(at: index), reference.remove(at: index))
                }
            default:
                let index = random(reference.count + 1)
                elements.insert(next, at: index)
                reference.insert(next, at: index)
                next &+= 1
            }
            XCTAssertEqual(elements.count, reference.count)
            XCTAssertEqual(contents(&elements), reference)
        }
    }

    // MARK: - Destruction

    /// A partially filled deque must destroy exactly its live elements, including
    /// when the ring is rotated so the live region wraps past slot 0.
    func testDropDestroysLiveElementsOnly() {
        for rotation in 0..<4 {
            for fill in 0..<10 {
                DeinitCounter.live = 0
                do {
                    var elements = NetworkSmallUniqueDeque<DeinitCounter, 4>()
                    // Rotate the ring before filling.
                    for _ in 0..<rotation {
                        elements.append(DeinitCounter())
                        _ = elements.popFirst()
                    }
                    XCTAssertEqual(DeinitCounter.live, 0)
                    for _ in 0..<fill {
                        elements.append(DeinitCounter())
                    }
                    XCTAssertEqual(DeinitCounter.live, fill)
                }
                XCTAssertEqual(
                    DeinitCounter.live,
                    0,
                    "leaked or over-released at fill \(fill), rotation \(rotation)"
                )
            }
        }
    }
}

/// Exercises the deque with the noncopyable element types it exists for.
@available(Network 0.1.0, *)
final class SwiftNetworkSmallUniqueDequeElementTests: NetTestCase {

    /// Two frames inline — the shape `FrameArray` would adopt.
    typealias SmallFrames = NetworkSmallUniqueDeque<Frame, 2>

    func testSingleFrameStaysInline() {
        var frames = SmallFrames()
        frames.append(Frame(count: 10))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames._overflowStorage.isEmpty, "a single frame must not allocate")

        var removed = frames.popFirst()!
        XCTAssertEqual(removed.unclaimedLength, 10)
        XCTAssertTrue(frames.isEmpty)
        removed.finalize(success: true)
    }

    /// Prepending is the reason this type exists: a lower protocol handing bytes
    /// back pushes onto the front.
    func testPrependedFrameComesOutFirst() {
        var frames = SmallFrames()
        frames.append(Frame(count: 20))
        frames.prepend(Frame(count: 10))
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames._overflowStorage.isEmpty, "two frames must not allocate")

        var first = frames.popFirst()!
        var second = frames.popFirst()!
        XCTAssertEqual(first.unclaimedLength, 10)
        XCTAssertEqual(second.unclaimedLength, 20)
        first.finalize(success: true)
        second.finalize(success: true)
    }

    func testManyFramesSpillAndPreserveOrder() {
        var frames = SmallFrames()
        for i in 1...7 {
            frames.append(Frame(count: i * 10))
        }
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames._overflowStorage.count, 7 - SmallFrames.inlineCapacity)

        for i in 1...7 {
            var removed = frames.popFirst()!
            XCTAssertEqual(removed.unclaimedLength, i * 10)
            removed.finalize(success: true)
        }
        XCTAssertTrue(frames.isEmpty)
    }

    func testFrameMutationInPlace() {
        var frames = SmallFrames()
        for _ in 0..<4 {
            frames.append(Frame(count: 100))
        }
        for i in 0..<4 {
            XCTAssertTrue(frames.withMutableElement(at: i) { $0.claim(fromStart: 10) })
        }
        for i in 0..<4 {
            XCTAssertEqual(frames.withElement(at: i) { $0.unclaimedLength }, 90)
        }
        while let frame = frames.popFirst() {
            var frame = frame
            frame.finalize(success: true)
        }
    }

    /// `Frame` traps if released without being finalized, so draining at every
    /// fill level and rotation checks that the deque accounts for every element.
    func testDrainingFramesAtEveryFillAndRotation() {
        for rotation in 0..<3 {
            for fill in 0..<6 {
                var frames = SmallFrames()
                for _ in 0..<rotation {
                    frames.append(Frame(count: 8))
                    var rotated = frames.popFirst()!
                    rotated.finalize(success: true)
                }
                for i in 0..<fill {
                    frames.append(Frame(count: (i + 1) * 8))
                }
                XCTAssertEqual(frames.count, fill)

                var drained = 0
                while let frame = frames.popFirst() {
                    var frame = frame
                    drained += 1
                    frame.finalize(success: true)
                }
                XCTAssertEqual(drained, fill)
            }
        }
    }

    // MARK: - PendingEvent

    typealias PendingEvent = ProtocolEventManagerState.PendingEvent
    typealias SmallEvents = NetworkSmallUniqueDeque<PendingEvent, 2>

    /// The event queues are FIFO: `append` then `popFirst`.
    func testPendingEventQueueIsFIFO() {
        var events = SmallEvents()
        let none = ProtocolInstanceReference()
        for i in 0..<6 {
            if i.isMultiple(of: 2) {
                events.append(.connected(none, none))
            } else {
                events.append(.disconnected(none, none, error: nil))
            }
        }
        XCTAssertEqual(events.count, 6)

        for i in 0..<6 {
            let event = events.popFirst()!
            if i.isMultiple(of: 2) {
                XCTAssertEqual(event.testCase, .connected, "event \(i)")
            } else {
                XCTAssertEqual(event.testCase, .disconnected, "event \(i)")
            }
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testSinglePendingEventStaysInline() {
        var events = SmallEvents()
        events.append(.connected(ProtocolInstanceReference(), ProtocolInstanceReference()))
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events._overflowStorage.isEmpty, "a single event must not allocate")
        XCTAssertEqual(events.popFirst()!.testCase, .connected)
    }

    /// Mirrors `discardPendingEventsForUpperProtocol()`: drop a queue of
    /// undelivered events.
    func testDroppingPendingEventsAtEveryFillLevel() {
        let none = ProtocolInstanceReference()
        for fill in 0..<5 {
            var events = SmallEvents()
            for _ in 0..<fill {
                events.append(.connected(none, none))
            }
            XCTAssertEqual(events.count, fill)
            // Deliberately drop without draining.
        }
    }
}
#endif
