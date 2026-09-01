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
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkFrameArrayTests: NetTestCase {
    func testEmptyFrameArray() {
        let array = FrameArray()
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
    }

    func testSingleFrameArray() {
        var array = FrameArray(frame: Frame(count: 10))
        XCTAssertFalse(array.isEmpty)
        XCTAssertEqual(array.count, 1)
        var removedFrame = array.popFirst()!
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
        removedFrame.finalize(success: true)
    }

    func testManyFrameArray() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))
        array.add(frame: Frame(count: 40))
        array.add(frame: Frame(count: 50))
        array.add(frame: Frame(count: 60))
        array.add(frame: Frame(count: 70))
        XCTAssertFalse(array.isEmpty)
        XCTAssertEqual(array.count, 7)
        while var removedFrame = array.popFirst() {
            removedFrame.finalize(success: true)
        }
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
    }

    func testPeekFrameArray() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))
        array.add(frame: Frame(count: 40))
        array.add(frame: Frame(count: 50))
        array.add(frame: Frame(count: 60))
        array.add(frame: Frame(count: 70))
        XCTAssertFalse(array.isEmpty)
        XCTAssertEqual(array.count, 7)
        for index in 0..<7 {
            array.peekFirstFrame { frame in
                XCTAssertEqual(frame.unclaimedLength, (index + 1) * 10)
            }
            var removedFrame = array.popFirst()!
            removedFrame.finalize(success: true)
        }
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
    }

    // MARK: - Immutable iteration

    func testIterateImmutableFramesVisitsAll() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        var lengths: [Int] = []
        array.iterateImmutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            return true
        }
        XCTAssertEqual(lengths, [10, 20, 30])

        // Array should be unchanged
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 60)
        array.finalizeAllFramesAsFailed()
    }

    func testIterateImmutableFramesStopsEarly() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        var lengths: [Int] = []
        array.iterateImmutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            // Stop after visiting the second frame
            return frame.unclaimedLength != 20
        }
        XCTAssertEqual(lengths, [10, 20])

        // Array should be unchanged
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 60)
        array.finalizeAllFramesAsFailed()
    }

    func testIterateImmutableFramesOnEmpty() {
        let array = FrameArray()
        var visited = false
        array.iterateImmutableFrames { _ in
            visited = true
            return true
        }
        XCTAssertFalse(visited)
        XCTAssertTrue(array.isEmpty)
    }

    // MARK: - Mutable iteration (Bool return)

    func testIterateMutableFramesBoolVisitsAll() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        var lengths: [Int] = []
        array.iterateMutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            return true
        }
        XCTAssertEqual(lengths, [10, 20, 30])
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 60)
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesBoolStopsEarly() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        var lengths: [Int] = []
        array.iterateMutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            return frame.unclaimedLength != 20
        }
        XCTAssertEqual(lengths, [10, 20])
        XCTAssertEqual(array.count, 3)
        array.finalizeAllFramesAsFailed()
    }

    // MARK: - Mutable iteration (FrameIterationResult return)

    func testIterateMutableFramesContinueAll() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        var lengths: [Int] = []
        array.iterateMutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            return .continueIterating
        }
        XCTAssertEqual(lengths, [10, 20, 30])
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 60)
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesStopIterating() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        var lengths: [Int] = []
        array.iterateMutableFrames { frame in
            lengths.append(frame.unclaimedLength)
            if frame.unclaimedLength == 20 {
                return .stopIterating
            }
            return .continueIterating
        }
        XCTAssertEqual(lengths, [10, 20])

        // All three frames should still be present
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 60)
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesRemoveMiddle() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))
        array.add(frame: Frame(count: 40))

        // Remove the frame with length 20
        array.iterateMutableFrames { frame in
            if frame.unclaimedLength == 20 {
                frame.finalize(success: true)
                return .removeFrameAndContinue
            }
            return .continueIterating
        }

        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 80)  // 10 + 30 + 40

        // Verify remaining frame order
        var remaining: [Int] = []
        array.iterateImmutableFrames { frame in
            remaining.append(frame.unclaimedLength)
            return true
        }
        XCTAssertEqual(remaining, [10, 30, 40])
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesRemoveFirst() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        // Remove the first frame
        array.iterateMutableFrames { frame in
            if frame.unclaimedLength == 10 {
                frame.finalize(success: true)
                return .removeFrameAndContinue
            }
            return .continueIterating
        }

        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 50)  // 20 + 30

        var remaining: [Int] = []
        array.iterateImmutableFrames { frame in
            remaining.append(frame.unclaimedLength)
            return true
        }
        XCTAssertEqual(remaining, [20, 30])
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesRemoveLast() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        // Remove the last frame
        array.iterateMutableFrames { frame in
            if frame.unclaimedLength == 30 {
                frame.finalize(success: true)
                return .removeFrameAndContinue
            }
            return .continueIterating
        }

        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 30)  // 10 + 20

        var remaining: [Int] = []
        array.iterateImmutableFrames { frame in
            remaining.append(frame.unclaimedLength)
            return true
        }
        XCTAssertEqual(remaining, [10, 20])
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesRemoveMultiple() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))
        array.add(frame: Frame(count: 40))
        array.add(frame: Frame(count: 50))

        // Remove all even-tens frames (20, 40)
        array.iterateMutableFrames { frame in
            if frame.unclaimedLength % 20 == 0 {
                frame.finalize(success: true)
                return .removeFrameAndContinue
            }
            return .continueIterating
        }

        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 90)  // 10 + 30 + 50

        var remaining: [Int] = []
        array.iterateImmutableFrames { frame in
            remaining.append(frame.unclaimedLength)
            return true
        }
        XCTAssertEqual(remaining, [10, 30, 50])
        array.finalizeAllFramesAsFailed()
    }

    func testIterateMutableFramesRemoveAll() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        array.iterateMutableFrames { frame in
            frame.finalize(success: true)
            return .removeFrameAndContinue
        }

        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
        XCTAssertEqual(array.unclaimedLength, 0)
    }

    func testIterateMutableFramesRemoveThenStop() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))
        array.add(frame: Frame(count: 40))

        // Remove frame with length 20, then stop at 30
        var visited: [Int] = []
        array.iterateMutableFrames { frame in
            visited.append(frame.unclaimedLength)
            if frame.unclaimedLength == 20 {
                frame.finalize(success: true)
                return .removeFrameAndContinue
            }
            if frame.unclaimedLength == 30 {
                return .stopIterating
            }
            return .continueIterating
        }

        // Should have visited 10, 20 (removed), then 30 (stopped)
        XCTAssertEqual(visited, [10, 20, 30])
        XCTAssertEqual(array.count, 3)  // 10, 30, 40 remain
        XCTAssertEqual(array.unclaimedLength, 80)
        array.finalizeAllFramesAsFailed()
    }

    // MARK: - Claim

    func testClaimPartialFirstFrame() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        let result = array.claim(fromStart: 5, removeClaimedFrames: false)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 55)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimExactFirstFrame() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        let result = array.claim(fromStart: 10, removeClaimedFrames: false)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 50)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimExactFirstFrameWithRemove() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        let result = array.claim(fromStart: 10, removeClaimedFrames: true)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 50)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimAcrossMultipleFramesWithRemove() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        // Claim 25 bytes: fully claims first (10) and partially claims second (15 of 20)
        let result = array.claim(fromStart: 25, removeClaimedFrames: true)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 35)  // 5 remaining in second + 30
        array.finalizeAllFramesAsFailed()
    }

    func testClaimAcrossMultipleFramesWithoutRemove() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        let result = array.claim(fromStart: 25, removeClaimedFrames: false)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 35)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimAllBytesWithRemove() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        let result = array.claim(fromStart: 60, removeClaimedFrames: true)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 0)
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.unclaimedLength, 0)
    }

    func testClaimAllBytesWithoutRemove() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        let result = array.claim(fromStart: 60, removeClaimedFrames: false)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.unclaimedLength, 0)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimMoreThanAvailableFails() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))

        let result = array.claim(fromStart: 50, removeClaimedFrames: false)
        XCTAssertFalse(result)
        // Array should be unchanged
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 30)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimZeroBytes() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))

        let result = array.claim(fromStart: 0, removeClaimedFrames: true)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 30)
        array.finalizeAllFramesAsFailed()
    }

    func testClaimExactlyTwoFramesWithRemove() {
        var array = FrameArray(frame: Frame(count: 10))
        array.add(frame: Frame(count: 20))
        array.add(frame: Frame(count: 30))

        // Claim exactly the first two frames
        let result = array.claim(fromStart: 30, removeClaimedFrames: true)
        XCTAssertTrue(result)
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 30)
        array.finalizeAllFramesAsFailed()
    }

    // MARK: - Drain array by byte count

    /// Collect all unclaimed bytes from a FrameArray into a flat [UInt8] for content validation.
    private func collectBytes(_ array: borrowing FrameArray) -> [UInt8] {
        var result: [UInt8] = []
        array.iterateImmutableFrames { frame in
            if let span = frame.span {
                for i in 0..<span.count {
                    result.append(span[i])
                }
            }
            return true
        }
        return result
    }

    func testDrainByteCountAllFramesConsumed() {
        // When maximumByteCount >= total bytes, all frames move to the new array
        var array = FrameArray(frame: Frame(copyBuffer: [1, 2, 3]))
        array.add(frame: Frame(copyBuffer: [4, 5]))
        array.add(frame: Frame(copyBuffer: [6, 7, 8, 9]))

        var drained = array.drainArray(maximumByteCount: 9)
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
        XCTAssertEqual(array.unclaimedLength, 0)
        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual(drained.unclaimedLength, 9)
        XCTAssertEqual(collectBytes(drained), [1, 2, 3, 4, 5, 6, 7, 8, 9])
        drained.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountMoreThanAvailable() {
        // When maximumByteCount > total bytes, all frames move to the new array
        var array = FrameArray(frame: Frame(copyBuffer: [10, 20, 30]))
        array.add(frame: Frame(copyBuffer: [40, 50]))

        var drained = array.drainArray(maximumByteCount: 100)
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(array.count, 0)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained.unclaimedLength, 5)
        XCTAssertEqual(collectBytes(drained), [10, 20, 30, 40, 50])
        drained.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountWholeFramesOnly() {
        // Drain exactly aligns on frame boundaries: no splitting needed
        var array = FrameArray(frame: Frame(copyBuffer: [1, 2]))
        array.add(frame: Frame(copyBuffer: [3, 4, 5]))
        array.add(frame: Frame(copyBuffer: [6, 7, 8]))
        array.add(frame: Frame(copyBuffer: [9, 10, 11, 12]))

        // Drain 5 bytes = first two frames (2 + 3)
        var drained = array.drainArray(maximumByteCount: 5)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained.unclaimedLength, 5)
        XCTAssertEqual(collectBytes(drained), [1, 2, 3, 4, 5])
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 7)
        XCTAssertEqual(collectBytes(array), [6, 7, 8, 9, 10, 11, 12])
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountPartialSingleFrame() {
        // Only one frame, and we drain fewer bytes than it contains: frame is split
        let bytes: [UInt8] = Array(0..<20)
        var array = FrameArray(frame: Frame(copyBuffer: bytes))

        var drained = array.drainArray(maximumByteCount: 8)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.unclaimedLength, 8)
        XCTAssertEqual(collectBytes(drained), Array(0..<8))
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 12)
        XCTAssertEqual(collectBytes(array), Array(8..<20))
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountSplitMajorityKeptInOriginal() {
        // Split where the majority of the split frame's bytes stay in the original array
        // First frame fully consumed, then only 2 of 20 bytes taken from second frame
        var array = FrameArray(frame: Frame(copyBuffer: [1, 2, 3]))
        let secondFrameBytes: [UInt8] = Array(10..<30)  // 20 bytes
        array.add(frame: Frame(copyBuffer: secondFrameBytes))

        // Drain 5 bytes: fully consumes first frame (3), splits 2 from second (20)
        var drained = array.drainArray(maximumByteCount: 5)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained.unclaimedLength, 5)
        XCTAssertEqual(collectBytes(drained), [1, 2, 3, 10, 11])
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 18)
        XCTAssertEqual(collectBytes(array), Array(12..<30))
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testMarkEndOfStreamOnlyMarksTheFinalFrame() {
        var array = FrameArray(frame: Frame(copyBuffer: Array(repeating: 1, count: 100)))
        array.add(frame: Frame(copyBuffer: Array(repeating: 2, count: 100)))
        array.add(frame: Frame(copyBuffer: Array(repeating: 3, count: 100)))
        array.markEndOfStream()

        var first = array.drainArray(maximumByteCount: 100)
        XCTAssertEqual(first.unclaimedLength, 100)
        XCTAssertFalse(first.connectionComplete, "end of stream reported with 200 bytes still queued")

        var second = array.drainArray(maximumByteCount: 100)
        XCTAssertEqual(second.unclaimedLength, 100)
        XCTAssertFalse(second.connectionComplete, "end of stream reported with 100 bytes still queued")

        var third = array.drainArray(maximumByteCount: 100)
        XCTAssertEqual(third.unclaimedLength, 100)
        XCTAssertTrue(third.connectionComplete, "end of stream not reported with the last bytes")

        first.finalizeAllFramesAsFailed()
        second.finalizeAllFramesAsFailed()
        third.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountSplitLeavesEndOfStreamWithTheTrailingBytes() {
        var frame = Frame(copyBuffer: Array(0..<20))
        frame.connectionComplete = true
        var array = FrameArray(frame: frame)

        var drained = array.drainArray(maximumByteCount: 12)
        XCTAssertEqual(drained.unclaimedLength, 12)
        XCTAssertFalse(drained.connectionComplete, "end of stream reported before the last byte")
        XCTAssertEqual(array.unclaimedLength, 8)
        XCTAssertTrue(array.connectionComplete, "end of stream lost from the remaining bytes")

        var rest = array.drainArray(maximumByteCount: 8)
        XCTAssertTrue(rest.connectionComplete)
        drained.finalizeAllFramesAsFailed()
        rest.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountSplitMajoritySentToNewArray() {
        // Split where the majority of the split frame's bytes go to the new array
        // Drain 18 of 20 bytes from a single frame
        let bytes: [UInt8] = Array(0..<20)
        var array = FrameArray(frame: Frame(copyBuffer: bytes))

        var drained = array.drainArray(maximumByteCount: 18)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.unclaimedLength, 18)
        XCTAssertEqual(collectBytes(drained), Array(0..<18))
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 2)
        XCTAssertEqual(collectBytes(array), [18, 19])
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountSplitEvenHalves() {
        // Split a frame evenly: half the bytes go to each array
        let bytes: [UInt8] = Array(0..<10)
        var array = FrameArray(frame: Frame(copyBuffer: bytes))

        var drained = array.drainArray(maximumByteCount: 5)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.unclaimedLength, 5)
        XCTAssertEqual(collectBytes(drained), [0, 1, 2, 3, 4])
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 5)
        XCTAssertEqual(collectBytes(array), [5, 6, 7, 8, 9])
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountWholeAndPartialFrames() {
        // Some frames fully consumed, one partially consumed, some unconsumed
        var array = FrameArray(frame: Frame(copyBuffer: [1, 2]))
        array.add(frame: Frame(copyBuffer: [3, 4, 5]))
        array.add(frame: Frame(copyBuffer: Array(10..<20)))  // 10 bytes
        array.add(frame: Frame(copyBuffer: [20, 21, 22, 23]))
        array.add(frame: Frame(copyBuffer: [30, 31]))

        // Drain 9 bytes: fully consumes frame 1 (2) + frame 2 (3) = 5, then splits 4 from frame 3 (10)
        var drained = array.drainArray(maximumByteCount: 9)
        XCTAssertEqual(drained.count, 3)  // two whole frames + one split piece
        XCTAssertEqual(drained.unclaimedLength, 9)
        XCTAssertEqual(collectBytes(drained), [1, 2, 3, 4, 5, 10, 11, 12, 13])
        XCTAssertEqual(array.count, 3)  // remainder of split frame + two unconsumed
        XCTAssertEqual(array.unclaimedLength, 12)  // 6 + 4 + 2
        XCTAssertEqual(collectBytes(array), [14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 30, 31])
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountSplitSmallSliceFromLargeFrame() {
        // Drain a tiny piece from a large frame
        var array = FrameArray(frame: Frame(copyBuffer: [1, 2, 3]))
        let largeBytes: [UInt8] = Array(0..<100)
        array.add(frame: Frame(copyBuffer: largeBytes))

        // Drain 4 bytes: fully consumes first frame (3), splits 1 from the 100-byte frame
        var drained = array.drainArray(maximumByteCount: 4)
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained.unclaimedLength, 4)
        XCTAssertEqual(collectBytes(drained), [1, 2, 3, 0])
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 99)
        XCTAssertEqual(collectBytes(array), Array(1..<100))
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testDrainByteCountSplitLargeSliceFromLargeFrame() {
        // Drain most of a large frame
        let bytes: [UInt8] = Array(0..<100)
        var array = FrameArray(frame: Frame(copyBuffer: bytes))

        var drained = array.drainArray(maximumByteCount: 99)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.unclaimedLength, 99)
        XCTAssertEqual(collectBytes(drained), Array(0..<99))
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array.unclaimedLength, 1)
        XCTAssertEqual(collectBytes(array), [99])
        drained.finalizeAllFramesAsFailed()
        array.finalizeAllFramesAsFailed()
    }

    func testPrepend() {
        var array = FrameArray(frame: Frame(copyBuffer: [1, 2, 3]))
        array.prepend(frame: Frame(copyBuffer: [4, 5, 6]))
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array.unclaimedLength, 6)
        XCTAssertEqual(collectBytes(array), [4, 5, 6, 1, 2, 3])
        array.finalizeAllFramesAsFailed()
    }
    func testConnectionCompleteIsAboutTheFinalFrame() {
        var head = Frame(copyBuffer: [1, 2, 3] as [UInt8])
        head.connectionComplete = true
        var array = FrameArray(frame: head)
        XCTAssertTrue(array.connectionComplete)

        array.add(frame: Frame(copyBuffer: [4, 5, 6] as [UInt8]))
        XCTAssertFalse(array.connectionComplete, "bytes follow the marked frame, so the stream has not ended")

        var tail = Frame(copyBuffer: [7, 8, 9] as [UInt8])
        tail.connectionComplete = true
        array.add(frame: tail)
        XCTAssertTrue(array.connectionComplete)

        array.finalizeAllFramesAsFailed()
    }

    func testConnectionCompleteIsFalseWhenEmpty() {
        var array = FrameArray()
        XCTAssertFalse(array.connectionComplete)
        array.finalizeAllFramesAsFailed()
    }
}
