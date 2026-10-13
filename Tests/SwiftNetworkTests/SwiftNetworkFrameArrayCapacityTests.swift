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
}
