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

import Testing

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#endif

// Swift Testing rejects `@available` on a suite or a test function, so each test narrows
// availability in its own body instead.
@Suite("FrameArray capacity")
struct SwiftNetworkFrameArrayCapacityTests {
    /// A send queue drained through `drainArrayKeepingCapacity` must keep the storage it was
    /// left with; if `add(frames:)` adopts the incoming buffer instead, every batch reallocates.
    @Test("A drained array keeps its capacity when frames are added")
    func drainedArrayKeepsCapacityWhenAddingFrames() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        for _ in 0..<8 {
            queue.add(frame: Frame(count: 16))
        }
        var drained = queue.drainArrayKeepingCapacity()
        drained.finalizeAllFramesAsFailed()

        let retainedCapacity = queue.capacity
        #expect(retainedCapacity >= 8)

        var incoming = FrameArray(capacity: 1)
        incoming.add(frame: Frame(count: 16))
        queue.add(frames: incoming)

        #expect(queue.capacity == retainedCapacity)
        #expect(queue.count == 1)
        queue.finalizeAllFramesAsFailed()
    }

    /// An array with no room must still take the incoming storage rather than grow its own,
    /// which is what keeps the first hand-off of a batch free of an allocation.
    @Test("An empty array with no capacity adopts the incoming storage")
    func emptyArrayWithoutCapacityAdoptsIncomingStorage() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        #expect(queue.capacity == 0)

        var incoming = FrameArray(capacity: 8)
        for _ in 0..<8 {
            incoming.add(frame: Frame(count: 16))
        }
        let incomingCapacity = incoming.capacity
        queue.add(frames: incoming)

        #expect(queue.capacity == incomingCapacity)
        #expect(queue.count == 8)
        queue.finalizeAllFramesAsFailed()
    }

    /// Frames already held must stay ahead of the ones being added, whichever buffer survives.
    @Test("Adding frames preserves order")
    func addingFramesPreservesOrder() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        queue.add(frame: Frame(count: 10))
        queue.add(frame: Frame(count: 20))

        var incoming = FrameArray()
        incoming.add(frame: Frame(count: 30))
        incoming.add(frame: Frame(count: 40))
        queue.add(frames: incoming)

        var lengths: [Int] = []
        queue.iterateImmutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            return true
        }
        #expect(lengths == [10, 20, 30, 40])
        queue.finalizeAllFramesAsFailed()
    }

    /// Draining into a spare's storage must hand over every frame in order and leave the queue with the spare's
    /// room; otherwise each batch allocates a replacement.
    @Test("Draining adopts the spare's storage")
    func drainingAdoptsSpareStorage() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        queue.add(frame: Frame(count: 10))
        queue.add(frame: Frame(count: 20))
        var spare = FrameArray(capacity: 16)
        let spareCapacity = spare.capacity

        var drained = queue.drainArray(adoptingStorageOf: &spare)

        let queueIsEmpty = queue.isEmpty
        #expect(queueIsEmpty)
        #expect(queue.capacity == spareCapacity)
        #expect(spare.capacity == 0)
        var lengths: [Int] = []
        drained.iterateImmutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            return true
        }
        #expect(lengths == [10, 20])
        drained.finalizeAllFramesAsFailed()
    }

    /// A spare too small for the drained frames must not become the queue's storage; the next drain of that size would
    /// grow it, which the storage the drain would have allocated avoids.
    @Test("Draining does not adopt a spare that is too small")
    func drainingDoesNotAdoptTooSmallSpare() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        for _ in 0..<8 {
            queue.add(frame: Frame(count: 16))
        }
        var spare = FrameArray(capacity: 2)
        let spareCapacity = spare.capacity

        var drained = queue.drainArray(adoptingStorageOf: &spare)
        drained.finalizeAllFramesAsFailed()

        #expect(queue.capacity >= 8)
        #expect(spare.capacity == spareCapacity)
    }

    /// A spare that still holds frames must not become the queue's storage; adopting it would drop those frames
    /// unfinalized, and the send path can hand over a batch the burst loop did not finish.
    @Test("Draining does not adopt a spare that holds frames")
    func drainingDoesNotAdoptNonEmptySpare() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        queue.add(frame: Frame(count: 10))
        var spare = FrameArray(capacity: 16)
        spare.add(frame: Frame(count: 5))

        var drained = queue.drainArray(adoptingStorageOf: &spare)

        #expect(drained.count == 1)
        #expect(spare.count == 1)
        drained.finalizeAllFramesAsFailed()
        spare.finalizeAllFramesAsFailed()
    }

    /// A spare with no room has nothing to hand on, so the drain must still leave the queue able to take the next
    /// frames without growing from nothing.
    @Test("Draining with a spare that has no storage keeps the capacity")
    func drainingWithEmptySpareKeepsCapacity() {
        guard #available(Network 0.1.0, *) else { return }

        var queue = FrameArray()
        for _ in 0..<8 {
            queue.add(frame: Frame(count: 16))
        }
        var spare = FrameArray()

        var drained = queue.drainArray(adoptingStorageOf: &spare)
        drained.finalizeAllFramesAsFailed()

        #expect(queue.capacity >= 8)
    }

    /// Storage may only be taken from an array that is empty and big enough; taking it from one that still holds
    /// frames would lose them, and taking too little would make the caller grow it.
    @Test("Taking empty storage")
    func takingEmptyStorage() {
        guard #available(Network 0.1.0, *) else { return }

        var source = FrameArray(capacity: 16)
        let sourceCapacity = source.capacity
        let taken = source.takeEmptyStorage(minimumCapacity: 8)
        #expect(taken.capacity == sourceCapacity)
        #expect(source.capacity == 0)

        var tooSmall = FrameArray(capacity: 2)
        let allocated = tooSmall.takeEmptyStorage(minimumCapacity: 8)
        #expect(allocated.capacity >= 8)
        #expect(tooSmall.capacity >= 2)

        var occupied = FrameArray(capacity: 16)
        occupied.add(frame: Frame(count: 10))
        let separate = occupied.takeEmptyStorage(minimumCapacity: 8)
        let separateIsEmpty = separate.isEmpty
        #expect(separateIsEmpty)
        #expect(occupied.count == 1)
        occupied.finalizeAllFramesAsFailed()
    }
}
