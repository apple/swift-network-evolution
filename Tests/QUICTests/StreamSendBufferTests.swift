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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

@available(Network 0.1.0, *)
extension Frame {
    var bytesCopy: [UInt8]? {
        guard let span = self.span else { return nil }
        return [UInt8](copying: span, maxCount: span.count)
    }
}

@available(Network 0.1.0, *)
final class StreamSendBufferTests: XCTestCase {
    var sendBuf = StreamSendBuffer()
    let log = NetworkLoggerState("[StreamSendBufferTests]")

    func testEmpty() {
        sendBuf.empty()
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
        XCTAssertEqual(sendBuf.hasMoreSendDataToService(currentSendOffset: 0), false)
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 0), 0)
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 1), 0)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
        XCTAssertEqual(sendBuf.acknowledgedSendData(offset: 0, length: 0, log: log), false)
        XCTAssertTrue(sendBuf.acknowledgedDataRanges.isEmpty)
    }

    func testHasMoreSendDataToService() {
        XCTAssertFalse(sendBuf.hasMoreSendDataToService(currentSendOffset: 0))

        let emptyFrame = Frame(copyBuffer: [])
        sendBuf.addSendData(emptyFrame, isLast: false)
        XCTAssertFalse(sendBuf.hasMoreSendDataToService(currentSendOffset: 0))
        XCTAssertFalse(sendBuf.hasMoreSendDataToService(currentSendOffset: 1))

        let oneByteFrame = Frame(copyBuffer: [1])
        sendBuf.addSendData(oneByteFrame, isLast: true)
        XCTAssertTrue(sendBuf.hasMoreSendDataToService(currentSendOffset: 0))
        XCTAssertFalse(sendBuf.hasMoreSendDataToService(currentSendOffset: 1))

        XCTAssertTrue(sendBuf.acknowledgedSendData(offset: 0, length: 1, log: log))
        XCTAssertTrue(sendBuf.hasMoreSendDataToService(currentSendOffset: 0))
        XCTAssertFalse(sendBuf.hasMoreSendDataToService(currentSendOffset: 1))
    }

    func testRemainingUnAckedLength() {
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)

        let emptyFrame = Frame(copyBuffer: [])
        sendBuf.addSendData(emptyFrame, isLast: false)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)

        let oneByteFrame = Frame(copyBuffer: [1])
        sendBuf.addSendData(oneByteFrame, isLast: true)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 1)

        XCTAssertTrue(sendBuf.acknowledgedSendData(offset: 0, length: 1, log: log))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
    }

    func testRemainingDataLengthToService() {
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 0), 0)
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 1), 0)

        let emptyFrame = Frame(copyBuffer: [])
        sendBuf.addSendData(emptyFrame, isLast: false)
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 0), 0)

        let oneByteFrame = Frame(copyBuffer: [1])
        sendBuf.addSendData(oneByteFrame, isLast: true)
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 0), 1)
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 1), 0)

        XCTAssertTrue(sendBuf.acknowledgedSendData(offset: 0, length: 1, log: log))
        XCTAssertEqual(sendBuf.remainingDataLengthToService(currentSendOffset: 0), 0)
    }

    func testCopyOutEmptySendBuf() {
        var outFrame = Frame(count: 1024)
        defer {
            outFrame.finalize(success: false)
        }
        let size = sendBuf.copyOutSendData(offset: 0, length: 1024, into: &outFrame, log: log)
        XCTAssertEqual(size, 0)

        let inFrame = Frame(copyBuffer: [])
        sendBuf.addSendData(inFrame, isLast: false)
        let size2 = sendBuf.copyOutSendData(offset: 0, length: 1024, into: &outFrame, log: log)
        XCTAssertEqual(size2, 0)

        sendBuf.empty()
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
    }

    func testCopyOutOne() {
        let data = Array(repeating: UInt8(0xab), count: 1024)
        let inFrame = Frame(copyBuffer: data)
        sendBuf.addSendData(inFrame, isLast: false)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 1024)

        var outFrame = Frame(count: 1024)
        defer {
            outFrame.finalize(success: false)
        }
        let size = sendBuf.copyOutSendData(offset: 0, length: 1024, into: &outFrame, log: log)
        XCTAssertEqual(size, 1024)
        // Note well: the outFrame's unclaimedLength is not controlled by copyOutSendData()
        XCTAssertEqual(data, Array(outFrame.bytesCopy!))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 1024)

        let end = sendBuf.acknowledgedSendData(offset: 0, length: 1024, log: log)
        XCTAssertFalse(end)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)

        // ACK past first byte
        XCTAssertFalse(sendBuf.acknowledgedSendData(offset: 0, length: 1, log: log))
        var sentinelFrame = Frame(copyBuffer: [1])
        defer {
            sentinelFrame.finalize(success: false)
        }
        // Try copy the ACK'd byte
        let size2 = sendBuf.copyOutSendData(offset: 0, length: 1, into: &sentinelFrame, log: log)
        XCTAssertEqual(size2, 0)
        // sentinelFrame should have been untouched!
        XCTAssertEqual([1], Array(sentinelFrame.bytesCopy!))

        sendBuf.empty()
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
    }

    func testCopyOutTwo() {
        let data1 = Array(repeating: UInt8(0xab), count: 100)
        let inFrame1 = Frame(copyBuffer: data1)
        sendBuf.addSendData(inFrame1, isLast: false)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 100)

        let data2 = Array(repeating: UInt8(0xcd), count: 200)
        let inFrame2 = Frame(copyBuffer: data2)
        sendBuf.addSendData(inFrame2, isLast: true)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 300)

        var outFrame1 = Frame(count: 50)
        defer {
            outFrame1.finalize(success: false)
        }
        let size1 = sendBuf.copyOutSendData(offset: 0, length: 400, into: &outFrame1, log: log)
        XCTAssertEqual(size1, 50)
        // Note well: the outFrame's unclaimedLength is not controlled by copyOutSendData()
        XCTAssertEqual(Array(data1[0..<50]), Array(outFrame1.bytesCopy![0..<50]))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 300)

        // copy across sendBuf frames
        var outFrame2 = Frame(count: 400)
        defer {
            outFrame2.finalize(success: false)
        }
        let size2 = sendBuf.copyOutSendData(offset: 50, length: 100, into: &outFrame2, log: log)
        XCTAssertEqual(size2, 100)
        // compare first 50 bytes in outFrame2
        XCTAssertEqual(Array(data1[50..<100]), Array(outFrame2.bytesCopy![0..<50]))
        // compare the next 50 bytes
        XCTAssertEqual(Array(data2[0..<50]), Array(outFrame2.bytesCopy![50..<100]))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 300)

        let size3 = sendBuf.copyOutSendData(offset: 100, length: 1000, into: &outFrame2, log: log)
        XCTAssertEqual(size3, 200)
        XCTAssertEqual(Array(data2), Array(outFrame2.bytesCopy![0..<200]))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 300)

        let end2 = sendBuf.acknowledgedSendData(offset: 0, length: 300, log: log)
        XCTAssertTrue(end2)

        sendBuf.empty()
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
    }

    func testCopyOutTwoAcked() {
        let data1 = Array(repeating: UInt8(0xab), count: 100)
        let inFrame1 = Frame(copyBuffer: data1)
        sendBuf.addSendData(inFrame1, isLast: false)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 100)

        let data2 = Array(repeating: UInt8(0xcd), count: 200)
        let inFrame2 = Frame(copyBuffer: data2)
        sendBuf.addSendData(inFrame2, isLast: true)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 300)

        var outFrame1 = Frame(count: 50)
        defer {
            outFrame1.finalize(success: false)
        }
        let size1 = sendBuf.copyOutSendData(offset: 0, length: 400, into: &outFrame1, log: log)
        XCTAssertEqual(size1, 50)
        // Note well: the outFrame's unclaimedLength is not controlled by copyOutSendData()
        XCTAssertEqual(Array(data1[0..<50]), Array(outFrame1.bytesCopy![0..<50]))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 300)

        let end1 = sendBuf.acknowledgedSendData(offset: 0, length: 50, log: log)
        XCTAssertFalse(end1)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 250)

        // copy across sendBuf frames
        var outFrame2 = Frame(count: 400)
        defer {
            outFrame2.finalize(success: false)
        }
        let size2 = sendBuf.copyOutSendData(offset: 50, length: 100, into: &outFrame2, log: log)
        XCTAssertEqual(size2, 100)
        // compare first 50 bytes in outFrame2
        XCTAssertEqual(Array(data1[50..<100]), Array(outFrame2.bytesCopy![0..<50]))
        // compare the next 50 bytes
        XCTAssertEqual(Array(data2[0..<50]), Array(outFrame2.bytesCopy![50..<100]))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 250)

        let size3 = sendBuf.copyOutSendData(offset: 100, length: 1000, into: &outFrame2, log: log)
        XCTAssertEqual(size3, 200)
        XCTAssertEqual(Array(data2), Array(outFrame2.bytesCopy![0..<200]))
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 250)

        let end2 = sendBuf.acknowledgedSendData(offset: 50, length: 250, log: log)
        XCTAssertTrue(end2)

        sendBuf.empty()
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
    }

    func testAckGap() {
        let data1 = Array(repeating: UInt8(0xab), count: 100)
        let inFrame1 = Frame(copyBuffer: data1)
        sendBuf.addSendData(inFrame1, isLast: false)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 100)

        let data2 = Array(repeating: UInt8(0xcd), count: 300)
        let inFrame2 = Frame(copyBuffer: data2)
        sendBuf.addSendData(inFrame2, isLast: true)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 400)

        // ACK for the second frame first
        let end1 = sendBuf.acknowledgedSendData(offset: 100, length: 100, log: log)
        XCTAssertFalse(end1)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 400)
        let end2 = sendBuf.acknowledgedSendData(offset: 300, length: 100, log: log)
        XCTAssertFalse(end2)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 400)
        let end3 = sendBuf.acknowledgedSendData(offset: 150, length: 100, log: log)
        XCTAssertFalse(end3)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 400)
        // [100,200)[200,250) [300,400)

        // Now, ACK the first frame, it should close the gap
        let end4 = sendBuf.acknowledgedSendData(offset: 0, length: 100, log: log)
        XCTAssertFalse(end4)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 150)
        // close the last gap
        let end5 = sendBuf.acknowledgedSendData(offset: 250, length: 100, log: log)
        XCTAssertTrue(end5)
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)

        sendBuf.empty()
        XCTAssertEqual(sendBuf.remainingUnAckedLength(), 0)
    }

    func testAckBeyondEnd() {
        XCTAssertFalse(sendBuf.acknowledgedSendData(offset: 0, length: 1, log: log))
    }

    func testCopyOutEdges() {
        // Since we copy out to frames of size 3 they will all be aligned like
        // the below to hit edge cases.
        let data: [[UInt8]] = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]]
        // out frames         [ 1, 2, 3][4,   5, 6][7, 8 ,  9][10, 11, 12]
        for d in data {
            let inFrame = Frame(copyBuffer: d)
            // Make the last frame isLast: true
            let last = d[3] == 12 ? true : false
            sendBuf.addSendData(inFrame, isLast: last)
        }

        var outFrames = FrameArray()
        for idx in 0...3 {
            var outFrame = Frame(count: 3)
            let size = sendBuf.copyOutSendData(
                offset: StreamOffset(idx * 3),
                length: 3,
                into: &outFrame,
                log: log
            )
            outFrames.add(frame: outFrame)
            XCTAssertEqual(size, 3)
        }

        var byteCount: UInt8 = 1
        outFrames.iterateImmutableFrames { frame in
            let expectedData = [byteCount, byteCount + 1, byteCount + 2]
            XCTAssertEqual(Array(frame.bytesCopy!), expectedData)
            byteCount += 3
            return true
        }
        XCTAssertEqual(byteCount, 13)

        outFrames.finalizeAllFramesAsFailed()
        let _ = outFrames.drainArray()
    }

    func testAckedDataRangeCoalescing() {
        var sendBuf = StreamSendBuffer()
        sendBuf.addSendData(Frame(count: 16), isLast: false)

        // Seed three disjoint OOO entries: [2,3) [4,5) [6,7)
        for off: StreamOffset in [2, 4, 6] {
            _ = sendBuf.acknowledgedSendData(offset: off, length: 1, log: log)
        }
        XCTAssertEqual(sendBuf.acknowledgedDataRanges.ranges.count, 3)

        // Fill the gap at offset 3 → entry[0] becomes [2,4), adjacent to [4,5).
        _ = sendBuf.acknowledgedSendData(offset: 3, length: 1, log: log)

        let entries = sendBuf.acknowledgedDataRanges.ranges

        // Ensure that the ranges coalesced into 2
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].lowerBound, 2)
        XCTAssertEqual(entries[0].upperBound - entries[0].lowerBound, 3)
        XCTAssertEqual(entries[1].lowerBound, 6)
        XCTAssertEqual(sendBuf.storageStartOffset, 0)
        sendBuf.empty()
    }

    func testAckedDataOverlapWithStart() {
        var sendBuf = StreamSendBuffer()
        sendBuf.addSendData(Frame(count: 16), isLast: false)

        // Acknowledge the first 4 bytes
        _ = sendBuf.acknowledgedSendData(offset: 0, length: 4, log: log)

        XCTAssertEqual(sendBuf.acknowledgedDataRanges.ranges.count, 0)
        XCTAssertEqual(sendBuf.storageStartOffset, 4)

        // Acknowledge bytes 2..<6. The start should move to 6.
        _ = sendBuf.acknowledgedSendData(offset: 2, length: 4, log: log)

        XCTAssertEqual(sendBuf.acknowledgedDataRanges.ranges.count, 0)
        XCTAssertEqual(sendBuf.storageStartOffset, 6)

        sendBuf.empty()
    }

    #if NETWORK_PERF_TESTS
    func testPerformanceHasMoreSendDataToService() {
        let iterations = 100_000  //1000
        for _ in 0..<iterations {
            let frame = Frame(count: 1)
            sendBuf.addSendData(frame, isLast: false)
        }
        let lastFrame = Frame(count: 1)
        sendBuf.addSendData(lastFrame, isLast: true)

        measure {
            for index in 0..<iterations {
                _ = sendBuf.hasMoreSendDataToService(currentSendOffset: StreamOffset(index))
            }
        }
        XCTAssertTrue(sendBuf.hasMoreSendDataToService(currentSendOffset: StreamOffset(1000)))
        XCTAssertFalse(
            sendBuf.hasMoreSendDataToService(currentSendOffset: StreamOffset(iterations + 1))
        )
    }
    #endif
}

@available(Network 0.1.0, *)
final class FrameArrayQueueTests: XCTestCase {
    var frameQueue = FrameArrayQueue()

    func testEmpty() {
        XCTAssertTrue(frameQueue.isEmpty)
        XCTAssertEqual(frameQueue.unclaimedLength, 0)
    }

    func testOneFrame() {
        XCTAssertTrue(frameQueue.isEmpty)
        let frameLength = 10
        let frame = Frame(count: frameLength)
        frameQueue.add(frame: frame)
        XCTAssertFalse(frameQueue.isEmpty)
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength)
        let claimLength = 5
        let success = frameQueue.claim(fromStart: claimLength)
        XCTAssertTrue(success)
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength - claimLength)
        frameQueue.finalizeAllFramesAsFailed()
        XCTAssertTrue(frameQueue.isEmpty)
        XCTAssertEqual(frameQueue.unclaimedLength, 0)
    }

    func testTwoFrames() {
        XCTAssertTrue(frameQueue.isEmpty)
        let frameLength1 = 10
        let frame1 = Frame(count: frameLength1)
        frameQueue.add(frame: frame1)
        XCTAssertFalse(frameQueue.isEmpty)
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength1)

        let frameLength2 = 20
        let frame2 = Frame(count: frameLength2)
        frameQueue.add(frame: frame2)
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength1 + frameLength2)

        var success = frameQueue.claim(fromStart: frameLength1)
        XCTAssertTrue(success)

        // Only frame2 is left in queue
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength2)

        let frameLength3 = 30
        let frame3 = Frame(count: frameLength3)
        frameQueue.add(frame: frame3)
        // Now frame2 and frame3 are in the queue
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength2 + frameLength3)
        XCTAssertFalse(frameQueue.isEmpty)

        let claimLength = 5
        success = frameQueue.claim(fromStart: claimLength)
        XCTAssertTrue(success)
        XCTAssertEqual(frameQueue.unclaimedLength, frameLength2 + frameLength3 - claimLength)

        frameQueue.finalizeAllFramesAsFailed()
        XCTAssertTrue(frameQueue.isEmpty)
        XCTAssertEqual(frameQueue.unclaimedLength, 0)
    }
}

#endif
