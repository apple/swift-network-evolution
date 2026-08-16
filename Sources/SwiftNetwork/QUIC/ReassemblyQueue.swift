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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct ReassemblyQueueItem: ~Copyable {
    var offset: Int
    var frame: Frame
    var length: Int { frame.unclaimedLength }
    var fin: Bool = false

    init(offset: Int, frame: consuming Frame) {
        self.offset = offset
        self.frame = frame
    }

    static let itemSize = MemoryLayout<ReassemblyQueueItem>.size
}

@available(Network 0.1.0, *)
struct ReassemblyQueue: ~Copyable {
    var log: NetworkLoggerState
    #if QUIC_REASSQ_TRACE
    private(set) var traceBuffer: String = ""
    #endif
    private(set) var currentOffset = 0  // in-order offset; next expected byte to be dequeued
    private(set) var lastOffset = 0  // out-of-order last offset
    private(set) var availableToDequeue = 0  // number of bytes that can be dequeued
    private(set) var size = 0  // reassq size
    private(set) var finOffset = Int.max  // one higher than largest byte offset sent on stream
    private(set) var headOfLineBlocked = false
    private(set) var items = NetworkUniqueDeque<ReassemblyQueueItem>()
    var hasFin: Bool {
        finOffset != Int.max
    }

    init() {
        self.log = NetworkLoggerState()
    }

    init(logPrefix: String) {
        self.init()
        self.log = NetworkLoggerState(logPrefix)
    }

    mutating func dequeueAll() {
        while !items.isEmpty {
            var item = items.removeFirst()
            item.frame.finalize(success: false)
        }
    }

    private func traceDump() {
        #if QUIC_REASSQ_TRACE
        log.error(self.traceBuffer)
        #endif
    }

    @inline(__always)
    private func traceAppend(_ newTrace: @autoclosure () -> String) {
        #if QUIC_REASSQ_TRACE
        let newTraceMessage = newTrace()
        traceBuffer.append(newTraceMessage)
        #endif
    }

    struct AppendResult {
        var sizeAdded: Int
        var lastOffset: Int
        var hasFin: Bool
        var finOffset: Int
        var currentOffset: Int
        var availableToDequeue: Int
    }

    @inline(always)
    private func appendResult(sizeAdded: Int) -> AppendResult {
        AppendResult(
            sizeAdded: sizeAdded,
            lastOffset: lastOffset,
            hasFin: hasFin,
            finOffset: finOffset,
            currentOffset: currentOffset,
            availableToDequeue: availableToDequeue
        )
    }

    @discardableResult
    mutating func append(
        frame: consuming Frame,
        offset: Int,
        fin: Bool
    ) -> AppendResult {
        var frame = frame
        var offset = offset
        let originalBufferLength = frame.unclaimedLength
        var bufferStartPoint = 0
        traceAppend("i \(offset) \(fin) \(originalBufferLength)")
        if fin {
            guard !_slowPath(finOffset != Int.max && finOffset != offset + originalBufferLength)
            else {
                traceDump()
                log.error(
                    "FIN offset already set, old \(finOffset), new \(offset + originalBufferLength)"
                )
                frame.finalize(success: false)
                return appendResult(sizeAdded: 0)
            }
            finOffset = offset + originalBufferLength
            log.datapath("FIN offset set to \(finOffset)")
        }
        if originalBufferLength == 0 && size != 0 {
            // We already set FIN offset, so we don't need to create a fake item to handle the FIN bit
            frame.finalize(success: false)
            return appendResult(sizeAdded: 0)
        }

        let oldSize = size
        var newItem: ReassemblyQueueItem
        if offset < currentOffset {
            if offset &+ originalBufferLength > currentOffset {
                let startingPoint = currentOffset - offset
                log.datapath(
                    "ignoring duplicate bytes [\(offset), \(offset + startingPoint)]"
                )
                offset &+= startingPoint
                bufferStartPoint &+= startingPoint

                // Use a truncated buffer
                _ = frame.claim(fromStart: bufferStartPoint)
                newItem = ReassemblyQueueItem(
                    offset: offset,
                    frame: frame
                )
            } else {
                frame.finalize(success: false)
                log.datapath(
                    "dropping duplicate buffer [\(offset), \(offset + originalBufferLength)]"
                )
                return appendResult(sizeAdded: 0)
            }
        } else {
            // Use the whole buffer
            newItem = ReassemblyQueueItem(offset: offset, frame: frame)
        }
        lastOffset =
            (offset == 0 && newItem.length == 0) ? 0 : max(lastOffset, offset &+ newItem.length - 1)
        traceDump()
        log.datapath("appending to reassq: offset \(newItem.offset) len \(newItem.length)")
        // Case 0: empty reassembly queue
        if items.isEmpty {
            let newItemOffset = newItem.offset
            let newItemLength = newItem.length
            items.append(newItem)
            size = newItemLength
            if currentOffset == newItemOffset {
                availableToDequeue = newItemLength
            } else {
                availableToDequeue = 0
            }
            return appendResult(sizeAdded: size)
        }
        // Case 1: append to the reassembly queue when in-order
        let itemCount = items.count
        let lastItemOffset = items[itemCount &- 1].offset
        let lastItemLength = items[itemCount &- 1].length
        if newItem.offset == lastItemOffset &+ lastItemLength {
            let newItemLength = newItem.length
            items.append(newItem)
            // When everything is in order, we can dequeue this item
            if availableToDequeue == size {
                availableToDequeue &+= newItemLength
            }
            size &+= newItemLength
            return appendResult(sizeAdded: newItemLength)
        }
        // Case 2: insert somewhere else while handling overlapping data
        // This algorithm is the same used in the TCP stack
        var prevItemOffset: Int? = nil
        var prevItemLength: Int? = nil
        var prevIndex: Int? = nil
        var iterIndex = 0
        var trailingIndex = 0
        var foundInsertionPoint = false
        let contiguousEnd = currentOffset + availableToDequeue
        var bytesRemoved = 0
        let newItemLength = newItem.length
        let newItemOffset = newItem.offset

        for index in 0..<itemCount {
            let itemOffset = items[index].offset
            let itemLength = items[index].length
            iterIndex = index
            if itemOffset > newItem.offset {
                foundInsertionPoint = true
                break
            }
            prevItemOffset = itemOffset
            prevItemLength = itemLength
            prevIndex = index
        }

        if let prevItemOffset, let prevItemLength {
            let overlappedLength = prevItemOffset &+ prevItemLength &- newItem.offset
            if overlappedLength > 0 {
                if overlappedLength >= newItem.length {
                    // The existing item already covers the same data as the new item
                    newItem.frame.finalize(success: false)
                    return appendResult(sizeAdded: 0)
                }
                // Advance the new entry when it overlaps with the existing one
                bufferStartPoint &+= overlappedLength
                newItem.offset &+= overlappedLength
                _ = newItem.frame.claim(fromStart: overlappedLength)
                // Add the overlapped adjustment
                bytesRemoved += overlappedLength
            }
        }
        // Iterate over the existing entries trying while taking care of overlaps and entries that are completely covered by the new entry
        iterIndex = foundInsertionPoint ? iterIndex : iterIndex &+ 1
        while iterIndex < items.count {
            let overlapLength = newItem.offset &+ newItem.length &- items[iterIndex].offset
            if overlapLength <= 0 {
                // Terminate once we cannot adjust nor remove any more entries.
                break
            }
            let existingLength = items[iterIndex].length
            if overlapLength < existingLength {
                // Adjust the current entry since it overlaps with the existing one.
                bytesRemoved &+= overlapLength
                items[iterIndex].offset &+= overlapLength
                _ = items[iterIndex].frame.claim(fromStart: overlapLength)
                break
            }
            // The new entry completely covers the existing one. Give preference to the new entry.
            var oldEntry = items.remove(at: iterIndex)
            oldEntry.frame.finalize(success: false)
            bytesRemoved &+= existingLength
        }
        if let prevIndex {
            trailingIndex = prevIndex &+ 2
            items.insert(newItem, at: prevIndex + 1)
        } else {
            trailingIndex = 1
            items.insert(newItem, at: 0)
        }
        size += newItemLength &- bytesRemoved
        let newEnd = newItemOffset &+ newItemLength
        // Iterate through the remaining items from the new insertion index to calculate available dequeue items
        if newItemOffset <= contiguousEnd && newEnd > contiguousEnd {
            availableToDequeue += (newEnd &- contiguousEnd)
            if trailingIndex < items.count {
                for i in trailingIndex..<items.count {
                    if items[i].offset == currentOffset &+ availableToDequeue {
                        availableToDequeue &+= items[i].length
                    }
                }
            }
        }

        if _slowPath(size < oldSize) {
            traceDump()
            log.fault("Reassq length went backwards \(size) < \(oldSize)")
            return appendResult(sizeAdded: 0)
        }
        return appendResult(sizeAdded: size - oldSize)
    }

    // Dequeue an item from the reassembly queue
    mutating func dequeue() -> ReassemblyQueueItem? {
        guard !items.isEmpty else {
            return nil
        }
        let firstItemOffset = items[0].offset
        if currentOffset == firstItemOffset {
            var dequeueItem = items.remove(at: 0)
            currentOffset += dequeueItem.length
            dequeueItem.fin = (currentOffset == finOffset)

            traceAppend("d \(dequeueItem.offset) \(dequeueItem.fin) \(dequeueItem.length)")
            size -= dequeueItem.length
            availableToDequeue -= dequeueItem.length
            log.datapath(
                "advanced \(dequeueItem.length), current offset \(currentOffset)"
            )
            if headOfLineBlocked {
                log.debug("No longer head of line blocked")
            }
            headOfLineBlocked = false
            return dequeueItem
        } else if _slowPath(currentOffset > firstItemOffset) {
            traceDump()
            log.fault("Current offset \(currentOffset) > \(firstItemOffset)")
            return nil
        } else {
            log.debug(
                "Head of line blocked, bytes missing: [\(currentOffset),\(firstItemOffset)) (\(firstItemOffset - currentOffset) bytes)"
            )
            headOfLineBlocked = true
            traceDump()
            return nil
        }
    }

    // Pass a limit of the flow control limit (or CRYPTO buffer) limit to determine
    // if the reassembly queue allows adding more items.
    enum CanAppendResult {
        case allowed  // OK to add more
        case warning  // Halfway full, flag for concern
        case notAllowed  // Do not add more

        var acceptable: Bool {
            self != .notAllowed
        }
    }

    static func canAppendItemsForByteLimit(itemCount: Int, byteLimit limit: UInt64) -> CanAppendResult {
        // Ensure that the memory size of reassembly queue items doesn't exceed
        // twice the overall memory limit. This prevents cases where large amounts
        // of memory are spent storing metadata for tiny pieces of data.
        let memoryFootprint = itemCount * ReassemblyQueueItem.itemSize
        if memoryFootprint <= limit {
            return .allowed
        } else if memoryFootprint <= limit * 2 {
            return .warning
        } else {
            return .notAllowed
        }
    }

    func canAppendItemsForByteLimit(_ limit: UInt64) -> CanAppendResult {
        ReassemblyQueue.canAppendItemsForByteLimit(itemCount: items.count, byteLimit: limit)
    }
}
#endif
