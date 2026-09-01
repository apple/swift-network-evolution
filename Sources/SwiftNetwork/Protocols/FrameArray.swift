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
    private var frames: NetworkUniqueDeque<Frame>

    public init(frame: consuming Frame) {
        self.frames = NetworkUniqueDeque<Frame>(minimumCapacity: 1)
        self.frames.append(frame)
    }

    public var isEmpty: Bool {
        self.frames.isEmpty
    }

    init(frames: consuming NetworkUniqueDeque<Frame>) {
        self.frames = frames
    }

    public init() {
        self.frames = NetworkUniqueDeque<Frame>()
    }

    public init(capacity: Int) {
        self.frames = NetworkUniqueDeque<Frame>(minimumCapacity: capacity)
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
    @_lifetime(borrow self)
    func bytes(at index: Int) -> RawSpan? {
        frames[index].bytes
    }
    #endif

    @_optimize(speed)
    public mutating func popFirst() -> Frame? {
        frames.popFirst()
    }

    public func peekFirstFrame<R>(_ access: (borrowing Frame) -> R) -> R {
        access(frames[0])

    }

    public mutating func mutablePeekFirstFrame<R>(_ access: (inout Frame) -> R) -> R {
        access(&frames[0])
    }

    @_optimize(speed)
    public mutating func iterateMutableFrames(_ enumerator: (inout Frame) -> Bool) {
        let count = frames.count
        for index in 0..<count {
            if !enumerator(&frames[index]) {
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
            let result = enumerator(&frames[index])
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
            if !enumerator(frames[index]) {
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
            let firstFrameLength = frames[0].unclaimedLength

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
                    let bytesCopied = frames[0].copyInto(&splitFrame, length: partialBytesToReturn)
                    precondition(bytesCopied == partialBytesToReturn)

                    // Claim from the start of the original frame
                    let claimed = frames[0].claim(fromStart: partialBytesToReturn)
                    precondition(claimed)

                    // Return the new frame
                    returnArray.add(frame: splitFrame)
                } else {
                    // In this case, the new split frame is the one we keep
                    var splitFrame = Frame(count: partialBytesToKeep)
                    let bytesCopied = frames[0].copyInto(
                        &splitFrame,
                        fromOffset: partialBytesToReturn,
                        length: partialBytesToKeep
                    )
                    precondition(bytesCopied == partialBytesToKeep)

                    // Claim from the end of the original frame
                    let claimed = frames[0].claim(fromStart: 0, fromEnd: partialBytesToKeep)
                    precondition(claimed)

                    // The flag belongs with the last byte, which is the tail being kept. `swap`
                    // exchanges whole frame values, so it would carry the flag out with the prefix
                    // instead. Move it first, while each name still refers to what it says.
                    if frames[0].connectionComplete {
                        frames[0].connectionComplete = false
                        splitFrame.connectionComplete = true
                    }

                    // Swap the new frame with the original frame
                    swap(&splitFrame, &frames[0])

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
            frames[index].finalize(success: false)
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

    /// Marks the end of the stream, on the last frame only.
    public mutating func markEndOfStream() {
        if frames.isEmpty { return }
        frames[frames.count - 1].connectionComplete = true
    }

    /// Whether this array ends the stream, which is a question about its final frame.
    public var connectionComplete: Bool {
        if frames.isEmpty { return false }
        return frames[frames.count - 1].connectionComplete
    }
}
