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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct FrameArray: ~Copyable {
    /// Frames are held two-deep inline, spilling to the heap beyond that.
    ///
    /// A frame array almost always holds one or two frames, and at that size this
    /// performs no allocation at all — an append/pop round trip measures ~1 ns
    /// versus ~11 ns for a heap-allocating deque. `prepend` stays O(1), which is
    /// why this is a deque rather than ``NetworkSmallUniqueArray``.
    private var frames: NetworkSmallUniqueDeque<Frame, 2>

    public init(frame: consuming Frame) {
        self.frames = .init()
        self.frames.append(frame)
    }

    public var isEmpty: Bool {
        self.frames.isEmpty
    }

    init(frames: consuming NetworkSmallUniqueDeque<Frame, 2>) {
        self.frames = frames
    }

    public init() {
        self.frames = .init()
    }

    /// - Parameter capacity: Advisory only. The first two frames are stored
    ///   inline and the overflow storage grows on demand, so no capacity is
    ///   reserved up front.
    public init(capacity: Int) {
        self.frames = .init()
    }

    public mutating func add(frame: consuming Frame) {
        self.frames.append(frame)
    }

    public mutating func add(frames: consuming FrameArray) {
        if self.frames.isEmpty {
            self.frames = frames.frames
        } else {
            while let first = frames.frames.popFirst() {
                self.frames.append(first)
            }
        }
    }

    public mutating func prepend(frame: consuming Frame) {
        self.frames.prepend(frame)
    }

    public var count: Int {
        frames.count
    }

    #if !NETWORK_EMBEDDED
    @_lifetime(&self)
    mutating func bytes(at index: Int) -> RawSpan? {
        // `RawSpan` is non-escapable, so it cannot be returned out of any closure
        // accessor — not even the stdlib's `withUnsafePointer`. Take the element's
        // address instead, which requires mutable access: only the mutable span
        // reliably addresses the real inline storage.
        _overrideLifetime(frames.elementAddress(at: index).pointee.bytes, mutating: &self)
    }
    #endif

    @_optimize(speed)
    public mutating func popFirst() -> Frame? {
        frames.popFirst()
    }

    public func peekFirstFrame<R>(_ access: (borrowing Frame) -> R) -> R {
        frames.borrowingWithElement(at: 0, access)
    }

    public mutating func mutablePeekFirstFrame<R>(_ access: (inout Frame) -> R) -> R {
        frames.withMutableElement(at: 0, access)
    }

    @_optimize(speed)
    public mutating func iterateMutableFrames(_ enumerator: (inout Frame) -> Bool) {
        let count = frames.count
        for index in 0..<count {
            if !frames.withMutableElement(at: index, enumerator) {
                return
            }
        }
    }

    public enum FrameIterationResult: ~Copyable {
        case continueIterating
        case stopIterating
        case removeFrameAndContinue
        case replaceWithFramesAndContinue(FrameArray)
    }

    @_optimize(speed)
    public mutating func iterateMutableFrames(_ enumerator: (inout Frame) -> FrameIterationResult) {
        var count = frames.count
        var index = 0
        while index < count {
            let result = frames.withMutableElement(at: index, enumerator)
            switch consume result {
            case .continueIterating:
                index += 1
                continue
            case .stopIterating:
                return
            case .removeFrameAndContinue:
                frames.remove(at: index)
                count -= 1
            // Don't increment index
            case .replaceWithFramesAndContinue(var newFrames):
                frames.remove(at: index)
                count -= 1
                let insertCount = newFrames.count
                var insertIndex = index
                while let newFrame = newFrames.popFirst() {
                    frames.insert(newFrame, at: insertIndex)
                    insertIndex += 1
                }
                index += insertCount
                count += insertCount
            }
        }
    }

    public func iterateImmutableFrames(_ enumerator: (borrowing Frame) -> Bool) {
        let count = frames.count
        for index in 0..<count {
            if !frames.borrowingWithElement(at: index, enumerator) {
                return
            }
        }
    }

    public mutating func drainArray(maximumFrameCount: Int? = nil) -> FrameArray {
        if let maximumFrameCount, self.count > maximumFrameCount {
            var returnArray = FrameArray()
            while returnArray.count < maximumFrameCount, let frame = self.popFirst() {
                returnArray.add(frame: frame)
            }
            return returnArray
        } else {
            let returnArray = self
            self = FrameArray()
            return returnArray
        }
    }

    mutating func _claim(fromStart: Int, existingLength: Int, removeClaimedFrames: Bool) -> Bool {
        let availableBytes = existingLength
        var bytesToClaim = fromStart
        guard bytesToClaim <= availableBytes else {
            return false
        }

        iterateMutableFrames { frame in
            let availableBytesInFrame = frame.unclaimedLength
            if bytesToClaim >= availableBytesInFrame {
                // Claim full frame
                _ = frame.claim(fromStart: availableBytesInFrame)
                bytesToClaim -= availableBytesInFrame
                if removeClaimedFrames {
                    frame.finalize(success: true)
                    return .removeFrameAndContinue
                }
                return .continueIterating
            } else {
                _ = frame.claim(fromStart: bytesToClaim)
                bytesToClaim = 0
                return .stopIterating
            }
        }
        return true
    }

    public mutating func claim(fromStart: Int, removeClaimedFrames: Bool) -> Bool {
        _claim(fromStart: fromStart, existingLength: self.unclaimedLength, removeClaimedFrames: removeClaimedFrames)
    }

    public mutating func drainArray(maximumByteCount: Int) -> FrameArray {
        guard unclaimedLength > maximumByteCount else {
            // Handle case where the entire array is consumed
            let returnArray = self
            self = FrameArray()
            return returnArray
        }

        var returnArray = FrameArray()
        var returnByteCount = 0

        while returnByteCount < maximumByteCount, !isEmpty {
            let firstFrameLength = frames.borrowingWithElement(at: 0) { $0.unclaimedLength }

            if returnByteCount + firstFrameLength <= maximumByteCount {
                returnByteCount += firstFrameLength
                let firstFrame = frames.remove(at: 0)
                returnArray.add(frame: firstFrame)
            } else {
                // Split the frame
                let partialBytesToReturn = maximumByteCount - returnByteCount
                let partialBytesToKeep = firstFrameLength - partialBytesToReturn

                // The new split frame should allocate the smaller of the two sizes to avoid large allocations
                if partialBytesToReturn < partialBytesToKeep {
                    // In this case, the new split frame is the one we return
                    var splitFrame = Frame(count: partialBytesToReturn)
                    frames.withMutableElement(at: 0) { first in
                        let bytesCopied = first.copyInto(&splitFrame, length: partialBytesToReturn)
                        precondition(bytesCopied == partialBytesToReturn)

                        // Claim from the start of the original frame
                        let claimed = first.claim(fromStart: partialBytesToReturn)
                        precondition(claimed)
                    }

                    // Return the new frame
                    returnArray.add(frame: splitFrame)
                } else {
                    // In this case, the new split frame is the one we keep
                    var splitFrame = Frame(count: partialBytesToKeep)
                    frames.withMutableElement(at: 0) { first in
                        let bytesCopied = first.copyInto(
                            &splitFrame,
                            fromOffset: partialBytesToReturn,
                            length: partialBytesToKeep
                        )
                        precondition(bytesCopied == partialBytesToKeep)

                        // Claim from the end of the original frame
                        let claimed = first.claim(fromStart: 0, fromEnd: partialBytesToKeep)
                        precondition(claimed)

                        // Swap the new frame with the original frame
                        swap(&splitFrame, &first)
                    }

                    // Return the split frame (which is really the original frame now)
                    returnArray.add(frame: splitFrame)
                }
                break
            }
        }
        return returnArray
    }

    public mutating func finalizeAllFramesAsFailed() {
        let count = frames.count
        for index in 0..<count {
            frames.withMutableElement(at: index) { $0.finalize(success: false) }
        }
        frames = .init()
    }

    public var unclaimedLength: Int {
        var length = 0
        iterateImmutableFrames { frame in
            length += frame.unclaimedLength
            return true
        }
        return length
    }

    public var connectionComplete: Bool {
        var connectionComplete = false
        iterateImmutableFrames { frame in
            if frame.connectionComplete {
                connectionComplete = true
                return false
            }
            return true
        }
        return connectionComplete
    }
}
