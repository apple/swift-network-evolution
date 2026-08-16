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

@available(Network 0.1.0, *)
extension ReassemblyQueue {
    @discardableResult
    fileprivate mutating func append(
        buffer: [UInt8],
        offset: Int,
        fin: Bool
    ) -> Int {
        append(frame: .init(copyBuffer: buffer), offset: offset, fin: fin).sizeAdded
    }
}

@available(Network 0.1.0, *)
final class ReassemblyQueueTests: XCTestCase {
    var reassemblyQueue: ReassemblyQueue = ReassemblyQueue()

    override func setUp() {
        reassemblyQueue = ReassemblyQueue()
    }

    func testReassAppend() {
        let length = 512
        let buf = [UInt8](repeating: 0, count: length)
        XCTAssertNotEqual(
            reassemblyQueue.append(buffer: buf, offset: 0, fin: false),
            0
        )
    }

    func testReassSize() {
        let length = 412
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 412)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 412)
    }

    func testReassInorderOffset() {
        let length = 100
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 100)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 100)
        reassemblyQueue.append(buffer: buf, offset: 200, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 200)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 100)
        while var item = reassemblyQueue.dequeue() {
            item.frame.finalize(success: true)
        }
        XCTAssertEqual(reassemblyQueue.currentOffset, 100)
    }

    func testReassLastOffset() {
        let length = 100
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 100)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 100)
        reassemblyQueue.append(buffer: buf, offset: 50, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 150)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 150)
        reassemblyQueue.append(buffer: buf, offset: 150, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 250)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 250)
        XCTAssertEqual(reassemblyQueue.lastOffset, 249)
    }

    func testReassDequeue() {
        let length = 1024
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        let dequeueItem = reassemblyQueue.dequeue()
        guard var dequeueItem else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        XCTAssertEqual(reassemblyQueue.size, 0)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassDequeueBlocked() {
        let length = 1024
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: length, fin: false)
        let dequeueItem = reassemblyQueue.dequeue()
        guard dequeueItem == nil else {
            XCTFail()
            return
        }
        XCTAssertEqual(reassemblyQueue.size, length)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)
    }

    func testReassTwoDequeue() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 200, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 400)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassThreeDequeue() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 200, fin: false)
        let buf3 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf3, offset: 400, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 600)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassReorder1() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 400, fin: false)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        XCTAssertEqual(reassemblyQueue.size, 200)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 200, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 400)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)
        let buf3 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf3, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 600)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 600)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, length)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassReorder2() {
        let buf = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf, offset: 439, fin: false)
        let buf2 = [UInt8](repeating: 0, count: 608)
        reassemblyQueue.append(buffer: buf2, offset: 1659, fin: false)
        let buf3 = [UInt8](repeating: 0, count: 73)
        reassemblyQueue.append(buffer: buf3, offset: 0, fin: false)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 73)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf4 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf4, offset: 73, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1220)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 366)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 608)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassReorder3() {
        let buf4 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf4, offset: 538, fin: false)
        let buf3 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf3, offset: 1758, fin: false)
        let buf2 = [UInt8](repeating: 0, count: 1207)
        reassemblyQueue.append(buffer: buf2, offset: 0, fin: false)
        let buf = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf, offset: 1207, fin: false)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1207)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 551)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 669)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassReorder4() {
        let buf = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf, offset: 3654, fin: false)
        let buf2 = [UInt8](repeating: 0, count: 800)
        reassemblyQueue.append(buffer: buf2, offset: 5342, fin: false)
        let buf3 = [UInt8](repeating: 0, count: 1214)
        reassemblyQueue.append(buffer: buf3, offset: 6142, fin: false)
        let buf4 = [UInt8](repeating: 0, count: 462)
        reassemblyQueue.append(buffer: buf4, offset: 0, fin: false)
        let buf5 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf5, offset: 462, fin: false)
        let buf6 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf6, offset: 1682, fin: false)
        let buf7 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf7, offset: 2902, fin: false)
        let buf8 = [UInt8](repeating: 0, count: 1220)
        reassemblyQueue.append(buffer: buf8, offset: 4122, fin: false)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 462)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1220)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1220)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1220)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 752)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 468)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 800)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1214)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassReorder5() {
        let buf = [UInt8](repeating: 0, count: 1169)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1169)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf2 = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf2, offset: 1169, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1168)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf3 = [UInt8](repeating: 0, count: 1169)
        reassemblyQueue.append(buffer: buf3, offset: 0, fin: false)
        let buf4 = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf4, offset: 2337, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1168)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf5 = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf5, offset: 3505, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1168)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf6 = [UInt8](repeating: 0, count: 1162)
        reassemblyQueue.append(buffer: buf6, offset: 4673, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1162)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf7 = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf7, offset: 5835, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1168)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf8 = [UInt8](repeating: 0, count: 382)
        reassemblyQueue.append(buffer: buf8, offset: 7003, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 382)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf9 = [UInt8](repeating: 0, count: 1162)
        reassemblyQueue.append(buffer: buf9, offset: 7385, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1162)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf10 = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf10, offset: 8547, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1168)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf11 = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf11, offset: 9715, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1168)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf12 = [UInt8](repeating: 0, count: 554)
        reassemblyQueue.append(buffer: buf12, offset: 10883, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 554)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf13 = [UInt8](repeating: 0, count: 225)
        reassemblyQueue.append(buffer: buf13, offset: 14551, fin: false)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        let buf14 = [UInt8](repeating: 0, count: 60)
        reassemblyQueue.append(buffer: buf14, offset: 12599, fin: false)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        let buf15 = [UInt8](repeating: 0, count: 33)
        reassemblyQueue.append(buffer: buf15, offset: 12659, fin: false)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        let buf16 = [UInt8](repeating: 0, count: 697)
        reassemblyQueue.append(buffer: buf16, offset: 12692, fin: false)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        let buf17 = [UInt8](repeating: 0, count: 1162)
        reassemblyQueue.append(buffer: buf17, offset: 13389, fin: false)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        let buf18 = [UInt8](repeating: 0, count: 472)
        reassemblyQueue.append(buffer: buf18, offset: 14776, fin: false)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        let buf19 = [UInt8](repeating: 0, count: 971)
        reassemblyQueue.append(buffer: buf19, offset: 11437, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 971)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf20 = [UInt8](repeating: 0, count: 284)
        reassemblyQueue.append(buffer: buf20, offset: 12408, fin: false)
        let buf21 = [UInt8](repeating: 0, count: 472)
        reassemblyQueue.append(buffer: buf21, offset: 14776, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 284)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 697)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1162)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 225)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 472)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassAdjustOffset() {
        let buf = [UInt8](repeating: 0, count: 1160)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1160)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        let buf2 = [UInt8](repeating: 0, count: 412)
        reassemblyQueue.append(buffer: buf2, offset: 0, fin: false)
        let buf3 = [UInt8](repeating: 0, count: 576)
        reassemblyQueue.append(buffer: buf3, offset: 412, fin: false)
        let buf4 = [UInt8](repeating: 0, count: 1166)
        reassemblyQueue.append(buffer: buf4, offset: 988, fin: false)
        let buf5 = [UInt8](repeating: 0, count: 48)
        reassemblyQueue.append(buffer: buf5, offset: 2154, fin: false)
        let buf6 = [UInt8](repeating: 0, count: 1166)
        reassemblyQueue.append(buffer: buf6, offset: 2202, fin: false)
        let buf7 = [UInt8](repeating: 0, count: 1159)
        reassemblyQueue.append(buffer: buf7, offset: 3368, fin: false)
        let buf8 = [UInt8](repeating: 0, count: 1159)
        reassemblyQueue.append(buffer: buf8, offset: 4527, fin: false)
        let buf9 = [UInt8](repeating: 0, count: 1166)
        reassemblyQueue.append(buffer: buf9, offset: 5686, fin: false)
        let buf10 = [UInt8](repeating: 0, count: 1166)
        reassemblyQueue.append(buffer: buf10, offset: 6852, fin: false)
        let buf11 = [UInt8](repeating: 0, count: 1166)
        reassemblyQueue.append(buffer: buf11, offset: 8018, fin: false)
        let buf12 = [UInt8](repeating: 0, count: 1166)
        reassemblyQueue.append(buffer: buf12, offset: 9184, fin: false)
        let buf13 = [UInt8](repeating: 0, count: 34)
        reassemblyQueue.append(buffer: buf13, offset: 10350, fin: false)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 994)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 48)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1166)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1159)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1159)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1166)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1166)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1166)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 1166)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 34)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassOverlapBeforeFirst() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 100, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 300)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 100)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassFullOverlapBeforeFirst() {
        let buf = [UInt8](repeating: 0, count: 100)
        reassemblyQueue.append(buffer: buf, offset: 100, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)
        let buf2 = [UInt8](repeating: 0, count: 200)
        reassemblyQueue.append(buffer: buf2, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 0)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertEqual(dequeueItem.length, 0)
    }

    func testReassOverlapAfterFirst() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 100, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 300)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 100)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassOverlapMiddle() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 200, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 400)
        let buf3 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf3, offset: 100, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 400)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 100)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 100)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassOverlapEnd() {
        let length = 20
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 20)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 20, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 40)
        let buf3 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf3, offset: 30, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 50)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 20)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 20)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 10)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassOneDuplicate() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 0)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertEqual(dequeueItem.length, 0)
    }

    func testReassDuplicate() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 200, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 400)
        let buf3 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf3, offset: 400, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 600)
        let buf4 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf4, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 600)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard dequeueItemOptional == nil else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 0)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertEqual(dequeueItem.length, 0)
    }

    func testReassFullOverlap() {
        let buf = [UInt8](repeating: 0, count: 100)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 100)
        let buf2 = [UInt8](repeating: 0, count: 200)
        reassemblyQueue.append(buffer: buf2, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 100)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 100)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testTinyInsertionsAndOverlap1() {
        /* Inserts many 1-byte items with a gap and then inserts a large item that spans everything from offset 0 to 100 */
        for i in 0..<50 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        for i in 60..<100 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        let buf3 = [UInt8](repeating: 0, count: 100)
        reassemblyQueue.append(buffer: buf3, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 100)
        XCTAssertEqual(reassemblyQueue.size, 100)
    }

    func testTinyInsertionsAndOverlap2() {
        /* Inserts many 1-byte items with a gap and then inserts a large item that spans everything from offset 50 to 160. */
        for i in 0..<50 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        for i in 60..<100 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        let buf3 = [UInt8](repeating: 0, count: 110)
        reassemblyQueue.append(buffer: buf3, offset: 50, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 160)
        XCTAssertEqual(reassemblyQueue.size, 160)
    }

    func testReassFin() {
        let length = 200
        let buf = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 200)
        let buf2 = [UInt8](repeating: 0, count: length)
        reassemblyQueue.append(buffer: buf2, offset: 200, fin: true)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 400)
        var dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, false)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
        dequeueItemOptional = reassemblyQueue.dequeue()
        guard var dequeueItem = dequeueItemOptional else {
            XCTFail()
            return
        }
        XCTAssertEqual(dequeueItem.length, 200)
        XCTAssertEqual(dequeueItem.fin, true)
        XCTAssertGreaterThan(dequeueItem.length, 0)
        dequeueItem.frame.finalize(success: true)
    }

    func testReassMultipleFin() {
        let buf = [UInt8](repeating: 0, count: 1168)
        reassemblyQueue.append(buffer: buf, offset: 0, fin: false)
        let buf2 = [UInt8](repeating: 0, count: 1161)
        reassemblyQueue.append(buffer: buf2, offset: 1168, fin: false)
        let buf3 = [UInt8](repeating: 0, count: 1161)
        reassemblyQueue.append(buffer: buf3, offset: 2329, fin: false)
        let buf4 = [UInt8](repeating: 0, count: 1161)
        reassemblyQueue.append(buffer: buf4, offset: 3490, fin: false)
        let buf5 = [UInt8](repeating: 0, count: 737)
        reassemblyQueue.append(buffer: buf5, offset: 4651, fin: false)
        let buf6 = [UInt8](repeating: 0, count: 44)
        reassemblyQueue.append(buffer: buf6, offset: 5388, fin: false)
        let buf7 = [UInt8](repeating: 0, count: 134)
        reassemblyQueue.append(buffer: buf7, offset: 5738, fin: false)
        let buf8 = [UInt8](repeating: 0, count: 132)
        reassemblyQueue.append(buffer: buf8, offset: 5432, fin: false)
        let buf9 = [UInt8](repeating: 0, count: 308)
        reassemblyQueue.append(buffer: buf9, offset: 5564, fin: true)
        XCTAssertTrue(reassemblyQueue.hasFin)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 5872)
        XCTAssertEqual(reassemblyQueue.size, 5872)
        XCTAssertEqual(reassemblyQueue.finOffset, 5872)
    }

    func testBytesRemovedLogicWithPreviousOverlap() {
        // Insert items at offsets 0-49
        for i in 0..<50 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        // Insert items at offsets 60-99
        for i in 60..<100 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        // Verify size 90 bytes total
        XCTAssertEqual(reassemblyQueue.size, 90)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 50)

        // Insert 100-byte buffer at offset 0
        // Should overlap and test that (size += newItemLength - bytesRemoved) is being calculated properly
        let buf3 = [UInt8](repeating: 0, count: 100)
        reassemblyQueue.append(buffer: buf3, offset: 0, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 100, "Size should be 100 after accounting for overlaps and removals")
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 100)
    }

    func testBytesRemovedLogicWithPartialPreviousOverlap() {
        // Insert items at offsets 0-29
        for i in 0..<30 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        // Insert items at offsets 50-79
        for i in 50..<80 {
            let buf = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: buf, offset: i, fin: false)
        }
        // Verify size: 60 bytes total
        XCTAssertEqual(reassemblyQueue.size, 60)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 30)

        // Insert 60-byte buffer at offset 20
        // Should overlap and test that (size += newItemLength - bytesRemoved) is being calculated properly
        let buf3 = [UInt8](repeating: 0, count: 60)
        reassemblyQueue.append(buffer: buf3, offset: 20, fin: false)
        XCTAssertEqual(reassemblyQueue.size, 80, "Size should be 80 after partial overlap and removal")
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 80)
    }

    func testLimitItemCount() {
        // Imitate a flow control limit of 1000 bytes
        let limit = 1000
        let limit64 = UInt64(limit)
        let numChunks = 4
        let chunkSize = limit / numChunks

        // Validate that we start out allowed
        var canAppendResult = reassemblyQueue.canAppendItemsForByteLimit(limit64)
        XCTAssertTrue(canAppendResult.acceptable)

        for i in 0..<4 {
            canAppendResult = reassemblyQueue.canAppendItemsForByteLimit(limit64)
            XCTAssertTrue(canAppendResult.acceptable)

            let chunk = [UInt8](repeating: 0, count: chunkSize)
            reassemblyQueue.append(buffer: chunk, offset: chunkSize * i, fin: false)
        }

        // Validate size
        XCTAssertEqual(reassemblyQueue.size, 1000)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 1000)

        // Drain queue
        while var dequeueItem = reassemblyQueue.dequeue() {
            dequeueItem.frame.finalize(success: true)
        }

        // Validate size
        XCTAssertEqual(reassemblyQueue.size, 0)
        XCTAssertEqual(reassemblyQueue.availableToDequeue, 0)

        // Now add one byte at a time. Ensure this will hit the limit.
        var limitHit = false
        for i in 0..<limit {
            guard reassemblyQueue.canAppendItemsForByteLimit(limit64).acceptable else {
                limitHit = true
                break
            }
            let chunk = [UInt8](repeating: 0, count: 1)
            reassemblyQueue.append(buffer: chunk, offset: limit + i, fin: false)
        }

        XCTAssertTrue(limitHit)
    }
}

#endif
