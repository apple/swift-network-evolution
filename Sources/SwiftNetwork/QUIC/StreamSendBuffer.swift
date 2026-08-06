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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// These MUST be able to hold Int and UInt values on all platforms.
// It is assumed that FrameArray.unclaimedLength is never negative.
typealias StreamOffset = UInt64
typealias StreamLength = UInt64

@available(Network 0.1.0, *)
struct StreamSendBuffer: ~Copyable {
    private var storage = FrameArrayQueue()
    private(set) var storageStartOffset: StreamOffset = 0
    private(set) var hasLast = false

    mutating func addSendData(_ data: consuming Frame, isLast: Bool) {
        if isLast {
            hasLast = isLast
        }
        storage.add(frame: data)
    }

    mutating func addSendData(_ data: consuming FrameArray, isLast: Bool) {
        if isLast {
            hasLast = isLast
        }
        storage.add(data)
    }

    mutating func markStreamFinished() {
        hasLast = true
    }

    mutating func empty() {
        storage.finalizeAllFramesAsFailed()
    }

    // If we've sent all the stored data out once.
    func hasMoreSendDataToService(currentSendOffset: StreamOffset) -> Bool {
        storageStartOffset + StreamLength(storage.unclaimedLength) > currentSendOffset
    }

    // How much remains to be serviced == has not yet been sent out once.
    func remainingDataLengthToService(currentSendOffset: StreamOffset) -> StreamLength {
        let offsetPastLastByte = storageStartOffset + StreamLength(storage.unclaimedLength)
        guard currentSendOffset < offsetPastLastByte else {
            return 0
        }
        guard currentSendOffset >= storageStartOffset else {
            // currentSendOffset is at bytes we no longer have, they're already ACKd?
            // Could be re-ordering problem?
            let _storageStartOffset = storageStartOffset
            #if !DisableErrorLogging
            Logger.proto.error(
                "currentSendOffset \(currentSendOffset) is out of date, storageStartOffset \(_storageStartOffset)"
            )
            #endif
            return 0
        }
        return offsetPastLastByte - currentSendOffset
    }

    // Data waits in storage so it can be retransmitted, until it's been ACKed.
    // UnACKed length == the total length in storage.
    func remainingUnAckedLength() -> StreamLength {
        StreamLength(storage.unclaimedLength)
    }

    // Returns the length of data it was able to copy out to the destination frame
    func copyOutSendData(
        offset requestedOffset: StreamOffset,
        length maxRequestedLength: StreamLength,
        into destination: inout Frame,
        log: borrowing NetworkLoggerState
    ) -> StreamLength {
        log.datapath(
            "FROM requestedOffset \(requestedOffset), maxRequestedLength \(maxRequestedLength) INTO frame start \(destination.startOffset)"
        )

        guard storageStartOffset <= requestedOffset else {
            // Requesting already acknowledged data that we therefore no longer have
            // Possibly some ACKs could have been re-ordered and we can't be sure
            // that another module is handling that correctly.
            let _storageStartOffset = storageStartOffset
            log.error(
                "Request for data that we no longer have: \(requestedOffset), storage at \(_storageStartOffset)"
            )
            return 0
        }

        // Since sendDataStorage.unclaimedLength iterates the array, avoid taking
        // the CPU to calculate it here, since we will iterate the array anyway.
        // If we run out of sendDataStorage to copy, we will simply go to the end of the
        // iteration, copying as much as we can from storage, before stopping.
        let requestedLength = min(maxRequestedLength, StreamLength(destination.unclaimedLength))

        // This can use FrameArray.iterateImmutableFrames() because it does NOT alter
        // the frame array while iterating.
        var currentFrameOffset: StreamOffset = storageStartOffset
        var destinationOffset: StreamOffset = 0
        var totalLengthCopied: StreamLength = 0
        storage.iterateImmutableFrames { frame in
            // 1. Step past frames that don't include the requested offset
            let currentFrameLength = StreamLength(frame.unclaimedLength)
            if currentFrameOffset + currentFrameLength <= requestedOffset + totalLengthCopied {
                currentFrameOffset += currentFrameLength
                return true
            }
            // Optimization idea for the above skip-past step:
            // add a way to "continue where we left off last time", if the caller
            // calls us with offset matching where last call's copy ended:
            // Ie. first call:  offset: A, length: L
            // and second call: offset: A + L
            // Save an iterator context, so we can continue at same offset,
            // instead of having to skip past looking for the right Frame in the
            // array again!

            // 2. Offset is within this frame, copy out, up to requestedLength
            let offsetWithinFrame = requestedOffset + totalLengthCopied - currentFrameOffset
            // Just go ahead, copyInto() will check and return what length it could copy
            let lengthCopied = frame.copyInto(
                &destination,
                atOffset: Int(destinationOffset),
                fromOffset: Int(offsetWithinFrame),
                length: Int(requestedLength - totalLengthCopied)
            )
            // Must be positive and should have been able to copy "something"!
            precondition(lengthCopied > 0)
            precondition(lengthCopied <= currentFrameLength)
            if lengthCopied > 0 {  // Report correctly even if precondition(s) fail
                // If we fail to copy the expected length, the caller will error handle
                currentFrameOffset += StreamOffset(currentFrameLength)
                destinationOffset += StreamOffset(lengthCopied)
                totalLengthCopied += StreamLength(lengthCopied)
            }
            guard lengthCopied > 0 && lengthCopied <= requestedLength
            else {
                return false  // violated precondition, abort iteration!
            }

            // 3. Stop the iteration if we've copied the requestedLength
            if totalLengthCopied == requestedLength {
                return false
            }
            return true
        }
        return totalLengthCopied
    }

    var acknowledgedDataRanges = RangeSet<StreamOffset>()

    mutating private func acknowledgedSendDataInner(
        offset acknowledgedOffset: StreamOffset,
        length acknowledgedLength: StreamLength,
        log: borrowing NetworkLoggerState
    ) {
        guard acknowledgedLength > 0 else {
            // Nothing acked, ignore
            return
        }

        var acknowledgedOffset = acknowledgedOffset
        let totalAcknowledgedOffset = acknowledgedOffset + acknowledgedLength
        log.datapath(
            "ACK of: \(acknowledgedOffset) + length \(acknowledgedLength)=\(totalAcknowledgedOffset) have from offset: \(storageStartOffset)"
        )

        guard totalAcknowledgedOffset > storageStartOffset else {
            // Ack is redundant, ignore
            return
        }

        if acknowledgedOffset < storageStartOffset {
            // If the newly acked range starts before the current offset, reset it to
            // the current offset. In practice, this is unlikely to happen because
            // the acked ranges represent sent STREAM frames, but this is a defensive
            // check.
            acknowledgedOffset = storageStartOffset
        }

        // ACK is contiguous with storageStartOffset and in-order
        if acknowledgedOffset == storageStartOffset {
            var newStartOffset = totalAcknowledgedOffset
            var consumed = 0
            while consumed < acknowledgedDataRanges.ranges.count
                && acknowledgedDataRanges.ranges[consumed].lowerBound <= newStartOffset
            {
                newStartOffset = max(newStartOffset, acknowledgedDataRanges.ranges[consumed].upperBound)
                consumed += 1
            }
            // Remove the consumed in one shot
            if consumed > 0 {
                acknowledgedDataRanges.remove(contentsOf: 0..<UInt64(consumed))
            }
            let difference = newStartOffset - storageStartOffset
            storageStartOffset = newStartOffset
            if !storage.isEmpty {
                guard storage.claim(fromStart: Int(difference)) else {
                    log.fault(
                        "Failed to claim \(difference) bytes from start of stream send buffer storage"
                    )
                    return
                }
            }
            return
        }

        // Out of order ACK. The gap will be consumed when the in-order
        // path above processes an ACK that fits this range.
        acknowledgedDataRanges.insert(contentsOf: acknowledgedOffset..<totalAcknowledgedOffset)
    }

    // Returns true if it acknowledged to the end of the data now, i.e. end of stream.
    mutating func acknowledgedSendData(
        offset acknowledgedOffset: StreamOffset,
        length acknowledgedLength: StreamLength,
        log: borrowing NetworkLoggerState
    ) -> Bool {
        acknowledgedSendDataInner(offset: acknowledgedOffset, length: acknowledgedLength, log: log)

        let allDataAcknowledged = (storage.isEmpty && hasLast)
        log.datapath("All data acknowleged: \(allDataAcknowledged)")
        return allDataAcknowledged
    }
}

// Special case of frame array that keeps track of the total unclaimed length
@available(Network 0.1.0, *)
struct FrameArrayQueue: ~Copyable {
    private var frames = FrameArray()
    private var cachedUnclaimedLength = 0

    var unclaimedLength: Int {
        cachedUnclaimedLength
    }

    var isEmpty: Bool {
        frames.isEmpty
    }

    mutating func add(frame: consuming Frame) {
        cachedUnclaimedLength += frame.unclaimedLength
        frames.add(frame: frame)
    }

    mutating func add(_ newFrames: consuming FrameArray) {
        cachedUnclaimedLength += newFrames.unclaimedLength
        frames.add(frames: newFrames)
    }

    mutating func finalizeAllFramesAsFailed() {
        cachedUnclaimedLength = 0
        frames.finalizeAllFramesAsFailed()
    }

    func iterateImmutableFrames(_ enumerator: (borrowing Frame) -> Bool) {
        frames.iterateImmutableFrames(enumerator)
    }

    mutating func claim(fromStart: Int) -> Bool {
        guard frames._claim(fromStart: fromStart, existingLength: cachedUnclaimedLength, removeClaimedFrames: true)
        else {
            return false
        }
        cachedUnclaimedLength -= fromStart
        return true
    }
}
