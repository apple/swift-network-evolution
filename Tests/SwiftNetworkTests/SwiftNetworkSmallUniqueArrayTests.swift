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

/// Element conformances for the primitive types used by these tests. The library
/// declares its own for `Frame` and `PendingEvent`.
@available(Network 0.1.0, *)
extension UInt8: NetworkInlineStorable {
    public typealias InlineSlot = InlineArray<1, UInt64>
}

@available(Network 0.1.0, *)
extension UInt64: NetworkInlineStorable {
    public typealias InlineSlot = InlineArray<1, UInt64>
}

/// A reference-counted element used to verify that dropping a partially filled
/// array releases exactly the live elements.
@available(Network 0.1.0, *)
final class DeinitCounter: NetworkInlineStorable {
    typealias InlineSlot = InlineArray<1, UInt64>

    nonisolated(unsafe) static var live = 0
    init() { DeinitCounter.live += 1 }
    deinit { DeinitCounter.live -= 1 }
}

/// Identifies a `PendingEvent`'s case from the test target. The library's own
/// `isConnected`/`isDisconnected` helpers are `fileprivate`.
@available(Network 0.1.0, *)
extension ProtocolEventManagerState.PendingEvent {
    enum TestCase: Equatable {
        case connected
        case disconnected
        case other
    }

    var testCase: TestCase {
        switch self {
        case .connected: return .connected
        case .disconnected: return .disconnected
        default: return .other
        }
    }
}

@available(Network 0.1.0, *)
final class SwiftNetworkSmallUniqueArrayTests: NetTestCase {

    /// Four `UInt8`s inline, so the overflow path is easy to reach in tests.
    typealias SmallBytes = NetworkSmallUniqueArray<UInt8, 4>

    /// Capacity is stated in elements, so it reads back exactly as written.
    func testInlineCapacityIsInElements() {
        XCTAssertEqual(NetworkSmallUniqueArray<UInt8, 4>.inlineCapacity, 4)
        XCTAssertEqual(NetworkSmallUniqueArray<UInt64, 1>.inlineCapacity, 1)
        XCTAssertEqual(NetworkSmallUniqueArray<UInt64, 7>.inlineCapacity, 7)
    }

    func testEmptyArray() {
        let elements = SmallBytes()
        XCTAssertEqual(elements.count, 0)
        XCTAssertTrue(elements.isEmpty)
    }

    func testArrayAppend() {
        var elements = SmallBytes()
        XCTAssertEqual(elements.count, 0)
        for i in 0..<12 {
            elements.append(UInt8(i))
            XCTAssertEqual(elements.count, i + 1)
        }
        XCTAssertEqual(elements.count, 12)
        XCTAssertFalse(elements.isEmpty)
    }

    /// Appending past the inline capacity and draining must preserve order.
    func testArrayRemove() {
        var elements = SmallBytes()
        XCTAssertEqual(elements.count, 0)
        for i in 0..<12 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.count, 12)
        for i in 0..<12 {
            let value = elements.remove(at: 0)
            XCTAssertEqual(value, UInt8(i))
        }
        XCTAssertEqual(elements.count, 0)
        XCTAssertTrue(elements.isEmpty)
    }

    func testRemoveFirst() {
        var elements = SmallBytes()
        for i in 0..<10 {
            elements.append(UInt8(i))
        }
        for i in 0..<10 {
            XCTAssertEqual(elements.removeFirst(), UInt8(i))
        }
        XCTAssertTrue(elements.isEmpty)
    }

    /// Elements entirely within inline storage never touch the heap.
    func testStaysInlineBelowCapacity() {
        var elements = SmallBytes()
        elements.append(1)
        elements.append(2)
        XCTAssertEqual(elements.count, 2)
        XCTAssertTrue(elements._overflowStorage.isEmpty)
        XCTAssertEqual(elements.withElement(at: 0) { $0 }, 1)
        XCTAssertEqual(elements.withElement(at: 1) { $0 }, 2)
    }

    /// Past the inline capacity, the excess lands in overflow storage.
    func testSpillsToOverflowAboveCapacity() {
        var elements = SmallBytes()
        for i in 0..<10 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.count, 10)
        XCTAssertEqual(elements._overflowStorage.count, 10 - SmallBytes.inlineCapacity)
    }

    /// Removing an inline element promotes an overflow element up, so inline
    /// storage stays densely packed.
    func testRemovePromotesOverflowElement() {
        var elements = SmallBytes()
        for i in 0..<10 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements._overflowStorage.count, 10 - SmallBytes.inlineCapacity)

        elements.remove(at: 0)
        // One promoted into the vacated inline slot.
        XCTAssertEqual(elements.count, 9)
        XCTAssertEqual(elements._overflowStorage.count, 10 - SmallBytes.inlineCapacity - 1)
        // Order is still intact after the promotion.
        for i in 0..<9 {
            XCTAssertEqual(elements.withElement(at: i) { $0 }, UInt8(i + 1))
        }
    }

    func testRemoveFromMiddle() {
        var elements = SmallBytes()
        for i in 0..<6 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.remove(at: 2), 2)
        XCTAssertEqual(elements.count, 5)
        XCTAssertEqual(Array(0..<5).map { i in elements.withElement(at: i) { $0 } }, [0, 1, 3, 4, 5])
    }

    /// Removing an index that lives purely in overflow storage.
    func testRemoveFromOverflowRange() {
        var elements = SmallBytes()
        for i in 0..<11 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.remove(at: 9), 9)
        XCTAssertEqual(elements.count, 10)
        XCTAssertEqual(
            Array(0..<10).map { i in elements.withElement(at: i) { $0 } },
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 10]
        )
    }

    func testElementRead() {
        var elements = SmallBytes()
        for i in 0..<12 {
            elements.append(UInt8(i * 2))
        }
        for i in 0..<12 {
            XCTAssertEqual(elements.withElement(at: i) { $0 }, UInt8(i * 2))
        }
    }

    func testElementMutate() {
        var elements = SmallBytes()
        for i in 0..<12 {
            elements.append(UInt8(i))
        }
        for i in 0..<12 {
            elements.withMutableElement(at: i) { $0 += 100 }
        }
        for i in 0..<12 {
            XCTAssertEqual(elements.withElement(at: i) { $0 }, UInt8(i + 100))
        }
    }

    /// Interleaved appends and removals, checked against a plain `Array`.
    func testInterleavedOperationsMatchReferenceArray() {
        var elements = SmallBytes()
        var reference: [UInt8] = []
        var next: UInt8 = 0
        var seed: UInt64 = 0x5DEE_CE66_D000_0001

        func random(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        for _ in 0..<400 {
            if reference.isEmpty || random(2) == 0 {
                elements.append(next)
                reference.append(next)
                next &+= 1
            } else {
                let index = random(reference.count)
                XCTAssertEqual(elements.remove(at: index), reference.remove(at: index))
            }
            XCTAssertEqual(elements.count, reference.count)
            for i in 0..<reference.count {
                XCTAssertEqual(elements.withElement(at: i) { $0 }, reference[i])
            }
        }
    }

    /// A partially filled array must destroy exactly its live elements when it
    /// goes out of scope — checked here with a class element that counts
    /// deinits, at every fill level around the inline/overflow boundary.
    func testDropDestroysLiveElementsOnly() {
        for fill in 0..<12 {
            DeinitCounter.live = 0
            do {
                var elements = NetworkSmallUniqueArray<DeinitCounter, 4>()
                for _ in 0..<fill {
                    elements.append(DeinitCounter())
                }
                XCTAssertEqual(DeinitCounter.live, fill)
                XCTAssertEqual(elements.count, fill)
            }
            XCTAssertEqual(DeinitCounter.live, 0, "leaked or over-released at fill \(fill)")
        }
    }
}

/// Exercises `NetworkSmallUniqueArray` with the two noncopyable element types
/// it is intended for: `Frame` (as used by `FrameArray`) and `PendingEvent`.
///
/// Both are large — `Frame` is 136 bytes and `PendingEvent` is ~328 — and both
/// normally appear in arrays of one or two elements, which is the case this
/// container is tuned for.
@available(Network 0.1.0, *)
final class SwiftNetworkSmallUniqueArrayElementTests: NetTestCase {

    // MARK: - Frame

    /// Two frames inline — stated in elements.
    typealias SmallFrames = NetworkSmallUniqueArray<Frame, 2>

    func testFrameInlineCapacity() {
        XCTAssertEqual(SmallFrames.inlineCapacity, 2)
    }

    /// `Frame.InlineSlot` is a hand-written word count, so pin it to the real
    /// layout. If `Frame` grows past its slot this fails here, rather than
    /// tripping the runtime precondition on first use.
    func testFrameInlineSlotFitsFrame() {
        XCTAssertGreaterThanOrEqual(
            MemoryLayout<Frame.InlineSlot>.stride,
            MemoryLayout<Frame>.stride,
            "Frame grew past its InlineSlot — widen Frame.InlineSlot"
        )
        XCTAssertGreaterThanOrEqual(
            MemoryLayout<Frame.InlineSlot>.alignment,
            MemoryLayout<Frame>.alignment
        )
        // Also flag a slot that has become needlessly large.
        XCTAssertLessThan(
            MemoryLayout<Frame.InlineSlot>.stride - MemoryLayout<Frame>.stride,
            MemoryLayout<UInt64>.stride,
            "Frame.InlineSlot is more than a word larger than Frame — shrink it"
        )
    }

    /// The overwhelmingly common case: a single frame, held entirely inline.
    func testSingleFrameStaysInline() {
        var frames = SmallFrames()
        frames.append(Frame(count: 10))
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames._overflowStorage.isEmpty, "a single frame must not allocate")

        var removed = frames.removeFirst()
        XCTAssertEqual(removed.unclaimedLength, 10)
        XCTAssertTrue(frames.isEmpty)
        removed.finalize(success: true)
    }

    /// Two frames still fit inline.
    func testTwoFramesStayInline() {
        var frames = SmallFrames()
        frames.append(Frame(count: 10))
        frames.append(Frame(count: 20))
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames._overflowStorage.isEmpty, "two frames must not allocate")

        XCTAssertEqual(frames.withElement(at: 0) { $0.unclaimedLength }, 10)
        XCTAssertEqual(frames.withElement(at: 1) { $0.unclaimedLength }, 20)

        var first = frames.removeFirst()
        var second = frames.removeFirst()
        XCTAssertEqual(first.unclaimedLength, 10)
        XCTAssertEqual(second.unclaimedLength, 20)
        first.finalize(success: true)
        second.finalize(success: true)
    }

    /// Growing past two frames spills to the heap but keeps FIFO order.
    func testManyFramesSpillAndPreserveOrder() {
        var frames = SmallFrames()
        for i in 1...7 {
            frames.append(Frame(count: i * 10))
        }
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames._overflowStorage.count, 7 - SmallFrames.inlineCapacity)

        for i in 1...7 {
            var removed = frames.removeFirst()
            XCTAssertEqual(removed.unclaimedLength, i * 10)
            removed.finalize(success: true)
        }
        XCTAssertTrue(frames.isEmpty)
    }

    /// Frames can be mutated in place, both inline and in overflow storage,
    /// without being copied out.
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
        while !frames.isEmpty {
            var removed = frames.removeFirst()
            removed.finalize(success: true)
        }
    }

    /// Frames own heap buffers, so a partially filled array must hand back
    /// exactly the live frames at every fill level around the inline/overflow
    /// boundary. `Frame` traps if it is released without being finalized, which
    /// makes this a direct check that the deinit accounts for every element.
    func testDrainingFramesAtEveryFillLevel() {
        for fill in 0..<6 {
            var frames = SmallFrames()
            for i in 0..<fill {
                frames.append(Frame(count: (i + 1) * 8))
            }
            XCTAssertEqual(frames.count, fill)
            var drained = 0
            while !frames.isEmpty {
                var frame = frames.removeFirst()
                drained += 1
                frame.finalize(success: true)
            }
            XCTAssertEqual(drained, fill)
        }
    }

    /// A `FrameArray`-style drain loop, the access pattern this replaces.
    func testFrameArrayStyleDrain() {
        var frames = SmallFrames()
        var expectedTotal = 0
        for i in 1...5 {
            frames.append(Frame(count: i * 16))
            expectedTotal += i * 16
        }

        var total = 0
        for i in 0..<frames.count {
            total += frames.withElement(at: i) { $0.unclaimedLength }
        }
        XCTAssertEqual(total, expectedTotal)

        var drained = 0
        while !frames.isEmpty {
            var frame = frames.removeFirst()
            drained += frame.unclaimedLength
            frame.finalize(success: true)
        }
        XCTAssertEqual(drained, expectedTotal)
    }

    // MARK: - PendingEvent

    typealias PendingEvent = ProtocolEventManagerState.PendingEvent
    /// Two events inline — stated in elements.
    typealias SmallEvents = NetworkSmallUniqueArray<PendingEvent, 2>

    func testPendingEventInlineCapacity() {
        XCTAssertEqual(SmallEvents.inlineCapacity, 2)
    }

    /// As with `Frame`, pin the hand-written slot size to the real layout.
    func testPendingEventInlineSlotFitsEvent() {
        XCTAssertGreaterThanOrEqual(
            MemoryLayout<PendingEvent.InlineSlot>.stride,
            MemoryLayout<PendingEvent>.stride,
            "PendingEvent grew past its InlineSlot — widen its InlineSlot"
        )
        XCTAssertGreaterThanOrEqual(
            MemoryLayout<PendingEvent.InlineSlot>.alignment,
            MemoryLayout<PendingEvent>.alignment
        )
        XCTAssertLessThan(
            MemoryLayout<PendingEvent.InlineSlot>.stride - MemoryLayout<PendingEvent>.stride,
            MemoryLayout<UInt64>.stride,
            "PendingEvent.InlineSlot is more than a word larger than the event — shrink it"
        )
    }

    /// A single queued event — the common case for the event queues.
    func testSinglePendingEventStaysInline() {
        var events = SmallEvents()
        events.append(.connected(ProtocolInstanceReference(), ProtocolInstanceReference()))
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events._overflowStorage.isEmpty, "a single event must not allocate")

        let removed = events.removeFirst()
        XCTAssertEqual(removed.testCase, .connected)
        XCTAssertTrue(events.isEmpty)
    }

    /// Events drain in FIFO order across the inline/overflow boundary, with the
    /// case of each event preserved.
    func testPendingEventOrderAcrossOverflow() {
        var events = SmallEvents()
        let none = ProtocolInstanceReference()
        // Alternate connected/disconnected so we can identify each position.
        for i in 0..<6 {
            if i.isMultiple(of: 2) {
                events.append(.connected(none, none))
            } else {
                events.append(.disconnected(none, none, error: nil))
            }
        }
        XCTAssertEqual(events.count, 6)
        XCTAssertFalse(events._overflowStorage.isEmpty)

        for i in 0..<6 {
            let event = events.removeFirst()
            if i.isMultiple(of: 2) {
                XCTAssertEqual(event.testCase, .connected, "event \(i) should be connected")
            } else {
                XCTAssertEqual(event.testCase, .disconnected, "event \(i) should be disconnected")
            }
        }
        XCTAssertTrue(events.isEmpty)
    }

    /// Dropping a queue of undelivered events at every fill level, mirroring
    /// `discardPendingEventsForUpperProtocol()`.
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
