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
extension Frame {
    var allBytesCopy: [UInt8]? {
        guard let allBytes = self.allBytes else { return nil }
        return allBytes.withUnsafeBytes { buffer in
            [UInt8](buffer)
        }
    }
}

@available(Network 0.1.0, *)
extension FrameCrypto {
    fileprivate var data: [UInt8] {
        guard let span = frame.span else { return [] }
        return .init(copying: span, maxCount: span.count)
    }
}

@available(Network 0.1.0, *)
extension FrameStreamReceived {
    fileprivate var data: [UInt8] {
        guard let span = frame.span else { return [] }
        return .init(copying: span, maxCount: span.count)
    }
}

@available(Network 0.1.0, *)
extension FrameDatagram {
    fileprivate var data: [UInt8] {
        guard let span = frame.span else { return [] }
        return .init(copying: span, maxCount: span.count)
    }
}

@available(Network 0.1.0, *)
class QUICFrameTests: XCTestCase {

    var stats: Statistics!
    var connection: QUICConnection!

    override func setUp() {
        connection = QUICConnection(context: NetworkContext.implicitContext)
        stats = Statistics()
    }

    // MARK: Padding (0x00)

    func testPaddingInit() throws {
        // sentinel value of 0xff to make sure padding works correctly
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xff,
        ]
        var frame = Frame(copyBuffer: bytes)
        let paddingFrame = try FramePadding(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(paddingFrame.extraPadding, 39)
        frame.finalize(success: true)
    }

    func testPaddingInitOneByte() throws {
        // sentinel value of 0xff to make sure padding works correctly
        let bytes: [UInt8] = [0x00, 0xff]
        var frame = Frame(copyBuffer: bytes)
        let paddingFrame = try FramePadding(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(paddingFrame.extraPadding, 0)
        frame.finalize(success: true)
    }

    func testPaddingInitStopsAtFirstNonZeroByte() throws {
        // Offset 0 is the frame type byte, so start at 1
        for sentinelOffset in 1..<23 {
            var bytes = [UInt8](repeating: 0x00, count: 23)
            bytes[sentinelOffset] = 0xff

            var frame = Frame(copyBuffer: bytes)
            let paddingFrame = try FramePadding(frame: &frame, packetNumberSpace: .applicationData)
            XCTAssertEqual(paddingFrame.extraPadding, sentinelOffset - 1)
            frame.finalize(success: true)
        }
    }

    func testPaddingInitAllZeroes() throws {
        let bytes = [UInt8](repeating: 0x00, count: 23)
        var frame = Frame(copyBuffer: bytes)
        let paddingFrame = try FramePadding(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(paddingFrame.extraPadding, 22)
        frame.finalize(success: true)
    }

    func testPaddingWritingOneByte() throws {
        let expectedBytes: [UInt8] = [0x00]
        var frame = Frame(count: expectedBytes.count)
        try FramePadding.write(frame: &frame, length: expectedBytes.count)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testPaddingWritingFixed() throws {
        let expectedBytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FramePadding.write(frame: &frame, length: expectedBytes.count)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testPaddingShortBuffer() throws {
        var frame = Frame(count: 39)
        XCTAssertThrowsError(try FramePadding.write(frame: &frame, length: 40))
        frame.finalize(success: true)
    }

    // MARK: Ping (0x01)

    func testPingInit() throws {
        let bytes: [UInt8] = [0x01]
        var frame = Frame(copyBuffer: bytes)
        let pingFrame = try FramePing(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(pingFrame.packetNumberSpace, .applicationData)
        frame.finalize(success: true)
    }

    func testPingWriting() throws {
        let expectedBytes: [UInt8] = [0x01]
        var frame = Frame(count: expectedBytes.count)
        try FramePing.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    // MARK: Ack (0x02)

    func testAckInitSingleRange() throws {
        let bytes: [UInt8] = [0x02, 0x2c, 0x21, 0x00, 0x21]
        var frame = Frame(copyBuffer: bytes)
        let ackFrame = try FrameAck(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(ackFrame.packetNumberSpace, .applicationData)
        XCTAssertEqual(ackFrame.largest, 44)
        XCTAssertEqual(ackFrame.delay, 33)
        XCTAssertEqual(ackFrame.ranges.count, 1)
        XCTAssertEqual(ackFrame.ranges[0].gap, 0)
        XCTAssertEqual(ackFrame.ranges[0].range, 33)
        frame.finalize(success: true)
    }

    func testAckInitMultiRange() throws {
        let bytes: [UInt8] = [0x02, 0x2c, 0x21, 0x02, 0x21, 0x0a, 0x0a, 0x03, 0x05]
        var frame = Frame(copyBuffer: bytes)
        let ackFrame = try FrameAck(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(ackFrame.packetNumberSpace, .applicationData)
        XCTAssertEqual(ackFrame.largest, 44)
        XCTAssertEqual(ackFrame.delay, 33)
        XCTAssertEqual(ackFrame.ranges.count, 3)
        XCTAssertEqual(ackFrame.ranges[0].gap, 0)
        XCTAssertEqual(ackFrame.ranges[0].range, 33)
        XCTAssertEqual(ackFrame.ranges[1].gap, 10)
        XCTAssertEqual(ackFrame.ranges[1].range, 10)
        XCTAssertEqual(ackFrame.ranges[2].gap, 3)
        XCTAssertEqual(ackFrame.ranges[2].range, 5)

        frame.finalize(success: true)
    }

    func testAckWritingSingleRange() throws {
        let expectedBytes: [UInt8] = [0x02, 0x21, 0x2c, 0x00, 0x21]
        var ackFrame = FrameAck(
            packetNumberSpace: PacketNumberSpace.applicationData,
            largest: 33,
            delay: 44
        )
        ackFrame.addRange(range: 33)
        var frame = Frame(count: expectedBytes.count)
        try ackFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testAckWritingMultiRange() throws {
        let expectedBytes: [UInt8] = [0x02, 0x20, 0x0b, 0x01, 0x0a, 0x0a, 0x03]
        var ackFrame = FrameAck(
            packetNumberSpace: PacketNumberSpace.applicationData,
            largest: 32,
            delay: 11
        )
        ackFrame.addRange(gap: 10, range: 10)
        ackFrame.addRange(gap: 5, range: 3)

        var frame = Frame(count: expectedBytes.count)
        try ackFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testAckWritingSingleRangeEmptyECN() throws {
        let expectedBytes: [UInt8] = [0x02, 0x21, 0x2c, 0x00, 0x21]
        var ackFrame = FrameAck(
            packetNumberSpace: PacketNumberSpace.applicationData,
            largest: 33,
            delay: 44
        )
        ackFrame.addRange(range: 33)
        ackFrame.ecnCounter = ECNCounter(ect0: 0, ect1: 0, ce: 0)

        var frame = Frame(count: expectedBytes.count)
        try ackFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testAckLargeDelay() throws {
        let bytes: [UInt8] = [0x02, 0x2c, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x21]
        var frame = Frame(copyBuffer: bytes)
        let ackFrame = try FrameAck(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(ackFrame.packetNumberSpace, .applicationData)
        XCTAssertEqual(ackFrame.largest, 44)

        // The giant delay value is capped at UInt32.max
        XCTAssertEqual(ackFrame.delay, UInt64(UInt32.max))

        // Ensure that converting to duration works
        let delayDuration = NetworkDuration.microseconds(ackFrame.delay)
        XCTAssertEqual(ackFrame.delay, UInt64(delayDuration.microseconds))

        XCTAssertEqual(ackFrame.ranges.count, 1)
        XCTAssertEqual(ackFrame.ranges[0].gap, 0)
        XCTAssertEqual(ackFrame.ranges[0].range, 33)
        frame.finalize(success: true)
    }

    // MARK: Ack ECN (0x03)

    func testAckECNInitSingleRange() throws {
        let bytes: [UInt8] = [0x03, 0x2c, 0x21, 0x00, 0x21, 0x03, 0x02, 0x06]
        var frame = Frame(copyBuffer: bytes)
        let ackFrame = try FrameAck(frame: &frame, packetNumberSpace: .applicationData)

        XCTAssertEqual(ackFrame.packetNumberSpace, .applicationData)
        XCTAssertEqual(ackFrame.largest, 44)
        XCTAssertEqual(ackFrame.delay, 33)
        XCTAssertEqual(ackFrame.ranges.count, 1)
        XCTAssertEqual(ackFrame.ranges[0].gap, 0)
        XCTAssertEqual(ackFrame.ranges[0].range, 33)
        XCTAssertEqual(ackFrame.ecnCounter?.ect0, 3)
        XCTAssertEqual(ackFrame.ecnCounter?.ect1, 2)
        XCTAssertEqual(ackFrame.ecnCounter?.ce, 6)
        frame.finalize(success: true)
    }

    func testAckECNInitMultiRange() throws {
        let bytes: [UInt8] = [
            0x03, 0x2c, 0x21, 0x02, 0x21, 0x0a, 0x0a, 0x03, 0x05, 0x03, 0x02, 0x06,
        ]
        var frame = Frame(copyBuffer: bytes)
        let ackFrame = try FrameAck(frame: &frame, packetNumberSpace: .applicationData)
        XCTAssertEqual(ackFrame.packetNumberSpace, .applicationData)
        XCTAssertEqual(ackFrame.largest, 44)
        XCTAssertEqual(ackFrame.delay, 33)
        XCTAssertEqual(ackFrame.ranges.count, 3)
        XCTAssertEqual(ackFrame.ranges[0].gap, 0)
        XCTAssertEqual(ackFrame.ranges[0].range, 33)
        XCTAssertEqual(ackFrame.ranges[1].gap, 10)
        XCTAssertEqual(ackFrame.ranges[1].range, 10)
        XCTAssertEqual(ackFrame.ranges[2].gap, 3)
        XCTAssertEqual(ackFrame.ranges[2].range, 5)
        XCTAssertEqual(ackFrame.ecnCounter?.ect0, 3)
        XCTAssertEqual(ackFrame.ecnCounter?.ect1, 2)
        XCTAssertEqual(ackFrame.ecnCounter?.ce, 6)
        frame.finalize(success: true)
    }

    func testAckECNWritingSingleRange() throws {
        let expectedBytes: [UInt8] = [0x03, 0x21, 0x2c, 0x00, 0x21, 0x03, 0x02, 0x06]
        var ackFrame = FrameAck(
            packetNumberSpace: PacketNumberSpace.applicationData,
            largest: 33,
            delay: 44
        )
        ackFrame.addRange(range: 33)
        ackFrame.ecnCounter = ECNCounter(ect0: 3, ect1: 2, ce: 6)

        var frame = Frame(count: expectedBytes.count)
        try ackFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testAckECNWritingMultiRange() throws {

        // ACK ECN Frame
        let expectedBytesECN: [UInt8] = [
            0x03, 0x20, 0x0b, 0x02, 0x21, 0x0, 0x0a, 0x0a, 0x05, 0x06, 0x03, 0x09,
        ]
        var ackFrameECN = FrameAck(
            packetNumberSpace: PacketNumberSpace.applicationData,
            largest: 32,
            delay: 11
        )
        ackFrameECN.addRange(range: 33)
        ackFrameECN.addRange(gap: 10, range: 10)
        ackFrameECN.addRange(gap: 3, range: 5)
        ackFrameECN.ecnCounter = ECNCounter(ect0: 6, ect1: 3, ce: 9)

        var frameECN = Frame(count: expectedBytesECN.count)
        try ackFrameECN.write(frame: &frameECN)
        XCTAssertTrue(frameECN.allBytesCopy!.elementsEqual(expectedBytesECN))
        frameECN.finalize(success: true)

        // ACK Frame now
        let expectedBytesACK: [UInt8] = [
            0x02, 0x20, 0x0b, 0x02, 0x21, 0x0, 0x0a, 0x0a, 0x05,
        ]
        var ackFrame = FrameAck(
            packetNumberSpace: PacketNumberSpace.applicationData,
            largest: 32,
            delay: 11
        )
        ackFrame.addRange(range: 33)
        ackFrame.addRange(gap: 10, range: 10)
        ackFrame.addRange(gap: 3, range: 5)

        var frameACK = Frame(count: expectedBytesACK.count)
        try ackFrame.write(frame: &frameACK)
        XCTAssertTrue(frameACK.allBytesCopy!.elementsEqual(expectedBytesACK))
        frameACK.finalize(success: true)
    }

    // MARK: Reset Stream (0x04)

    func testResetStreamInit() throws {
        let bytes: [UInt8] = [
            0x04,
            0x37,
            0x29,
            0x80, 0x00, 0x82, 0x40,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameResetStream(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 55)
        XCTAssertEqual(quicFrame.code, 41)
        XCTAssertEqual(quicFrame.finalSize, 33344)
        frame.finalize(success: true)
    }

    func testResetStreamTruncated() throws {
        let bytes: [UInt8] = [
            0x04,
            0x37,
            0x29,
            0x80, 0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameResetStream(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testResetStreamWriting() throws {
        let expectedBytes: [UInt8] = [
            0x04,
            0x37,
            0x29,
            0x80, 0x00, 0x82, 0x40,
        ]
        var frame = Frame(count: 7)
        try FrameResetStream.write(frame: &frame, id: 55, code: 41, finalSize: 33344, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testResetStreamShortBuffer() throws {
        var frame = Frame(count: 6)
        XCTAssertThrowsError(
            try FrameResetStream.write(
                frame: &frame,
                id: 55,
                code: 41,
                finalSize: 33344,
                stats: &stats
            )
        )
        frame.finalize(success: true)
    }

    // MARK: Stop Sending (0x05)

    func testStopSendingInit() throws {
        let bytes: [UInt8] = [
            0x05,
            0x40,
            0x5c, 0x6b, 0x67,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameStopSending(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 92)
        XCTAssertEqual(quicFrame.code, 11111)
        frame.finalize(success: true)
    }

    func testStopSendingTruncated() throws {
        let bytes: [UInt8] = [
            0x05,
            0x40,
            0x5c, 0x6b,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStopSending(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStopSendingWriting() throws {
        let expectedBytes: [UInt8] = [
            0x05,
            0x40,
            0x5c, 0x6b, 0x67,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FrameStopSending.write(frame: &frame, id: 92, code: 11111, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testStopSendingShortBuffer() throws {
        var frame = Frame(count: 4)
        XCTAssertThrowsError(
            try FrameStopSending.write(frame: &frame, id: 92, code: 11111, stats: &stats)
        )
        frame.finalize(success: true)
    }

    // MARK: Crypto (0x06)

    func testCryptoInit() throws {
        let bytes: [UInt8] = [
            0x06,
            0x03,
            0x03,
            0xab, 0xba, 0x11,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameCrypto(
            frame: &frame,
            packetNumberSpace: .applicationData,
            stats: &stats
        )
        XCTAssertEqual(quicFrame.offset, 3)
        XCTAssertEqual(quicFrame.length, 3)
        XCTAssertEqual(quicFrame.data, [0xab, 0xba, 0x11])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testCryptoTruncated() throws {
        let bytes: [UInt8] = [
            0x06,
            0x03,
            0x03,
            0xab, 0xba,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameCrypto(frame: &frame, packetNumberSpace: .applicationData, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testCryptoWriting() throws {
        let expectedBytes: [UInt8] = [
            0x06,
            0x03,
            0x03,
            0xab, 0xba, 0x11,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FrameCrypto.write(
            frame: &frame,
            stats: &stats,
            packetNumberSpace: .applicationData,
            offset: 3,
            data: [0xab, 0xba, 0x11]
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testCryptoShortBuffer() throws {
        var frame = Frame(count: 5)
        XCTAssertThrowsError(
            try FrameCrypto.write(
                frame: &frame,
                stats: &stats,
                packetNumberSpace: .applicationData,
                offset: 3,
                data: [0xab, 0xba, 0x11]
            )
        )
        frame.finalize(success: true)
    }

    // MARK: New Token (0x07)

    func testNewTokenInit() throws {
        let bytes: [UInt8] = [
            0x07,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameNewToken(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.token.count, 4)
        XCTAssertEqual(quicFrame.token, [0xaa, 0xbb, 0xcc, 0x44])
        frame.finalize(success: true)
    }

    func testNewTokenTruncated() throws {
        let bytes: [UInt8] = [
            0x07,
            0x04,
            0xaa, 0xbb,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameNewToken(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testNewTokenWriting() throws {
        let token: [UInt8] = [0xaa, 0xbb, 0xcc, 0x44]
        let expectedBytes: [UInt8] = [
            0x07,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        let _ = FrameNewToken(token: token)
        var frame = Frame(count: expectedBytes.count)
        try FrameNewToken.write(frame: &frame, token: token, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testNewTokenShortBuffer() throws {
        let token: [UInt8] = [0xaa, 0xbb, 0xcc, 0x44]
        let _ = FrameNewToken(token: [0xaa, 0xbb, 0xcc, 0x44])
        var frame = Frame(count: 5)
        XCTAssertThrowsError(try FrameNewToken.write(frame: &frame, token: token, stats: &stats))
        frame.finalize(success: true)
    }

    // MARK: Stream (0x08)

    func testStreamInit() throws {
        let bytes: [UInt8] = [
            0x08,
            0x06,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        XCTAssertEqual(quicFrame.isFinal, false)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamEmptyInit() throws {
        let bytes: [UInt8] = [
            0x08,
            0x04,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.isFinal, false)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamTruncated() throws {
        let bytes: [UInt8] = [
            0x08
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    // We always encode the length so don't write stream frames with type 0x08

    // MARK: Stream, Final (0x09)

    func testStreamFinalInit() throws {
        let bytes: [UInt8] = [
            0x09,
            0x06,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        XCTAssertEqual(quicFrame.isFinal, true)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamFinalEmptyInit() throws {
        let bytes: [UInt8] = [
            0x09,
            0x04,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.isFinal, true)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamFinalTruncated() throws {
        let bytes: [UInt8] = [
            0x09
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    // We always encode the length so don't write stream frames with type 0x09

    // MARK: Stream, Length (0x0a)

    func testStreamLengthInit() throws {
        let bytes: [UInt8] = [
            0x0a,
            0x06,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        XCTAssertEqual(quicFrame.isFinal, false)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamLengthEmptyInit() throws {
        let bytes: [UInt8] = [
            0x0a,
            0x04,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.isFinal, false)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamLengthTruncated() throws {
        let bytes: [UInt8] = [
            0x0a,
            0x04,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamLengthWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0a,
            0x06,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 0,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamLengthEmptyWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0a,
            0x04,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 0,
            length: 0,
            isFinal: false
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamLengthWritingFailure() throws {
        let expectedBytes: [UInt8] = [
            0x0a,
            0x06,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        XCTAssertEqual(frame.unclaimedLength, 7)

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(4)

        XCTAssertThrowsError(
            try FrameStreamSendMetadata.write(
                into: &frame,
                stats: &stats,
                stream: stream,
                offset: 0,
                length: lengthToWrite,
                isFinal: false
            )
        )

        // Ensure no bytes were claimed
        XCTAssertEqual(frame.unclaimedLength, 7)
    }

    func testStreamLengthShortBuffer() throws {
        var frame = Frame(count: 2)
        // TODO: it should fit Type+StreamID, no offset/length/data is needed!
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let lengthToWrite = UInt64(0)
        XCTAssertThrowsError(
            try FrameStreamSendMetadata.write(
                into: &frame,
                stats: &stats,
                stream: stream,
                offset: 0,
                length: lengthToWrite,
                isFinal: false
            )
        )
    }

    // MARK: Stream, Length+Final (0x0b)

    func testStreamLengthFinalInit() throws {
        let bytes: [UInt8] = [
            0x0b,
            0x06,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        XCTAssertEqual(quicFrame.isFinal, true)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamLengthFinalEmptyInit() throws {
        let bytes: [UInt8] = [
            0x0b,
            0x04,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 0)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.isFinal, true)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamLengthFinalTruncated() throws {
        let bytes: [UInt8] = [
            0x0b,
            0x04,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamLengthFinalWriting() throws {

        let expectedBytes: [UInt8] = [
            0x0b,
            0x06,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendData, isLast: true)
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 0,
            length: lengthToWrite,
            isFinal: true
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamLengthFinalEmptyWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0b,
            0x04,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 0,
            length: 0,
            isFinal: true
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamLengthFinalEmptyWritingExtraSpace() throws {
        let expectedBytes: [UInt8] = [
            0x0b,
            0x04,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count + 1)  // Add extra byte space
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 0,
            length: 0,
            isFinal: true
        )
        XCTAssertEqual(length, 0)
        var frameBytes: [UInt8] = frame.allBytesCopy!
        frameBytes.removeLast()  // Remove extra byte space
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamFinalShortBuffer() throws {
        // frame must have room for Type and Stream ID, but offset and length
        // won't be written unless necessary. So with only 1byte it throws.
        var frame = Frame(count: 1)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        XCTAssertThrowsError(
            try FrameStreamSendMetadata.write(
                into: &frame,
                stats: &stats,
                stream: stream,
                offset: 0,
                length: 0,
                isFinal: true
            )
        )
    }

    func testStreamFinalEmptyWriting() throws {
        let expectedBytes: [UInt8] = [
            0x09,
            0x04,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 0,
            length: 0,
            isFinal: true
        )
        XCTAssertEqual(length, 0)
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    // MARK: Stream, Offset (0x0c)

    func testStreamOffsetInit() throws {
        let bytes: [UInt8] = [
            0x0c,
            0x06,
            0x0a,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 10)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        XCTAssertEqual(quicFrame.isFinal, false)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetEmptyInit() throws {
        let bytes: [UInt8] = [
            0x0c,
            0x04,
            0x0a,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 10)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.isFinal, false)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetTruncated() throws {
        let bytes: [UInt8] = [
            0x0c,
            0x06,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    // We always encode the length so don't write stream frames with type 0x0c

    // MARK: Stream, Offset+Final (0x0d)

    func testStreamOffsetFinalInit() throws {
        let bytes: [UInt8] = [
            0x0d,
            0x06,
            0x0a,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 10)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        XCTAssertEqual(quicFrame.isFinal, true)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetFinalEmptyInit() throws {
        let bytes: [UInt8] = [
            0x0d,
            0x04,
            0x0a,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 10)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.isFinal, true)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetFinalTruncated() throws {
        let bytes: [UInt8] = [
            0x0d,
            0x06,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    // We always encode the length so don't write stream frames with type 0x0d

    // MARK: Stream, Offset+Length (0x0e)

    func testStreamOffsetLengthInit() throws {
        let bytes: [UInt8] = [
            0x0e,
            0x06,
            0x0a,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 10)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetLengthEmptyInit() throws {
        let bytes: [UInt8] = [
            0x0e,
            0x04,
            0x01,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 1)
        XCTAssertEqual(quicFrame.length, 0)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetLengthTruncated() throws {
        let bytes: [UInt8] = [
            0x0e,
            0x06,
            0x0a,
            0x04,
            0xaa, 0xbb,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamOffsetLengthWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0e,
            0x06,
            0x0a,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamNotEnoughSendBuffer() throws {
        var frame = Frame(count: 8)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        // We just have 4 bytes sendBuffer at offset 0, nothing at offset 10
        XCTAssertThrowsError(
            try FrameStreamSendMetadata.write(
                into: &frame,
                stats: &stats,
                stream: stream,
                offset: 10,
                length: lengthToWrite,
                isFinal: false
            )
        )
    }

    func testStreamOffsetLengthEmptyWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0e,
            0x04,
            0x01,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))

        // Add data to sendBuffer, it won't be sent because write is for 0 length
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            stream.sendBuffer.empty()
        }
        stream.sendBuffer.addSendData(sendData, isLast: false)

        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 1,
            length: 0,
            isFinal: false
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamOffsetNoLengthShortBuffer() throws {
        var frame = Frame(count: 3)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)

        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)

        XCTAssertThrowsError(
            try FrameStreamSendMetadata.write(
                into: &frame,
                stats: &stats,
                stream: stream,
                offset: 10,
                length: lengthToWrite,
                isFinal: false
            )
        )
    }

    func testStreamOffsetNoLengthMinimalBuffer() throws {
        // If we don't need to write length, it can actually fit one byte
        let expectedBytes: [UInt8] = [
            0x0c,
            0x04,
            0x0a,
            0xaa,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)

        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)

        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertEqual(length, 1)
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamNoLengthLargeData() throws {
        let expectedBytes: [UInt8] =
            [
                0x0c,
                0x06,
                0x0a,
                0xaa,
            ] + Array(repeating: 0xbb, count: 65_536) + [0x44]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(
            copyBuffer: [0xaa] + Array(repeating: 0xbb, count: 65_536) + [0x44]
        )
        let sendDataBeforeOffset10 = Frame(
            copyBuffer: Array(repeating: UInt8(0), count: 10)
        )
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertEqual(length, Int(lengthToWrite))
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamLengthLargeDataCannotFit() throws {
        // A very large stream data, yielding a large VLE encoded Length field
        let streamData: [UInt8] = [0xaa] + Array(repeating: 0xbb, count: 65_536) + [0x44]
        let expectedBytes: [UInt8] =
            [
                0x0e,
                0x06,
                0x0a,
                0x80, 0x01, 0x00, 0x01,  // 65537 in VLE!
            ] + streamData
        // Not enough space, but enough that Length field will be needed
        var frame = Frame(count: expectedBytes.count - 1)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: streamData)
        let sendDataBeforeOffset10 = Frame(
            copyBuffer: Array(repeating: UInt8(0), count: 10)
        )
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertEqual(length, Int(lengthToWrite) - 1)  // Subtract the byte that cannot fit
        var expectedBytesActuallyWritten = expectedBytes
        expectedBytesActuallyWritten.removeLast()  // Remove the byte that cannot fit
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytesActuallyWritten, frameBytes)
    }

    func testStreamLengthLargeData() throws {
        // A very large stream data, yielding a large VLE encoded Length field
        let streamData: [UInt8] = [0xaa] + Array(repeating: 0xbb, count: 65_536) + [0x44]
        let expectedBytes: [UInt8] =
            [
                0x0e,
                0x06,
                0x0a,
                0x80, 0x01, 0x00, 0x02,  // 65538 in VLE!
            ] + streamData
        // Data fits exactly with Length field
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: streamData)
        let sendDataBeforeOffset10 = Frame(
            copyBuffer: Array(repeating: UInt8(0), count: 10)
        )
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertEqual(length, Int(lengthToWrite))
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamLengthLargeDataExtraSpace() throws {
        // A very large stream data, yielding a large VLE encoded Length field
        let streamData: [UInt8] = [0xaa] + Array(repeating: 0xbb, count: 65_536) + [0x44]
        let expectedBytes: [UInt8] =
            [
                0x0e,
                0x06,
                0x0a,
                0x80, 0x01, 0x00, 0x02,  // 65538 in VLE!
            ] + streamData
        // Bit of extra space, but not so much that Length field isn't necessary
        var frame = Frame(count: expectedBytes.count + 1)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: streamData)
        let sendDataBeforeOffset10 = Frame(
            copyBuffer: Array(repeating: UInt8(0), count: 10)
        )
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: false
        )
        XCTAssertEqual(length, Int(lengthToWrite))
        var frameBytes: [UInt8] = frame.allBytesCopy!
        frameBytes.removeLast(1)  // Remove the extra space
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamLengthVLEBreakingPoint() throws {
        // Case of 1 byte VLE vs 2 byte VLE requested
        // 64 byte stream data, but only 63 will fit!
        let streamData: [UInt8] = [0xaa] + Array(repeating: 0xbb, count: 62) + [0x44]
        var expectedBytes: [UInt8] =
            [
                0x0e,
                0x06,
                0x0a,
                0x3f,  // 63 in VLE encoding (1 byte)
            ] + streamData
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: streamData)
        let sendDataBeforeOffset10 = Frame(
            copyBuffer: Array(repeating: UInt8(0), count: 10)
        )
        defer {
            stream.sendBuffer.empty()
        }
        let requestedLengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: false)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: requestedLengthToWrite,
            isFinal: false
        )
        XCTAssertEqual(length, Int(requestedLengthToWrite) - 1)  // Subtract byte that won't fit
        var frameBytes: [UInt8] = frame.allBytesCopy!
        frameBytes.removeLast(1)  // Remove the extra unused byte
        expectedBytes.removeLast(1)  // Remove the byte that won't fit
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    // MARK: Stream, Offset+Length+Final (0x0f)

    func testStreamOffsetLengthFinalInit() throws {
        let bytes: [UInt8] = [
            0x0f,
            0x06,
            0x0a,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 6)
        XCTAssertEqual(quicFrame.offset, 10)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetLengthFinalEmptyInit() throws {
        let bytes: [UInt8] = [
            0x0f,
            0x04,
            0x01,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameStreamReceived(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 4)
        XCTAssertEqual(quicFrame.offset, 1)
        XCTAssertEqual(quicFrame.length, 0)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testStreamOffsetLengthFinalTruncated() throws {
        let bytes: [UInt8] = [
            0x0f,
            0x06,
            0x0a,
            0x04,
            0xaa, 0xbb,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamReceived(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamOffsetLengthFinalWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0f,
            0x06,
            0x0a,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: true)
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: true
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamOffsetLengthFinalEmptyWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0f,
            0x04,
            0x01,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(4), logPrefixer: .init("Test"))
        _ = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 1,
            length: 0,
            isFinal: true
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testStreamOffsetFinalWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0d,
            0x06,
            0x0a,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: true)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: true
        )
        XCTAssertEqual(length, Int(lengthToWrite))
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamOffsetFinalWriteShort() throws {
        let expectedBytes: [UInt8] = [
            0x0c,
            0x06,
            0x0a,
            0xaa,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: true)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: lengthToWrite,
            isFinal: true
        )
        XCTAssertEqual(length, 1)
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamOffsetFinalEmptyWriting() throws {
        let expectedBytes: [UInt8] = [
            0x0d,
            0x06,
            0x0a,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        // Putting data in stream's send buffer, even though it should not be used,
        // just to check if that affects the test outcome
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: true)
        let length = try FrameStreamSendMetadata.write(
            into: &frame,
            stats: &stats,
            stream: stream,
            offset: 10,
            length: 0,
            isFinal: true
        )
        XCTAssertEqual(length, 0)
        let frameBytes: [UInt8] = frame.allBytesCopy!
        XCTAssertEqual(expectedBytes, frameBytes)
    }

    func testStreamOffsetFinalShortBuffer() throws {
        var frame = Frame(count: 3)
        defer {
            frame.finalize(success: true)
        }

        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(6), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        let sendDataBeforeOffset10 = Frame(copyBuffer: Array(repeating: UInt8(0), count: 10))
        defer {
            stream.sendBuffer.empty()
        }
        let lengthToWrite = UInt64(sendData.unclaimedLength)
        stream.sendBuffer.addSendData(sendDataBeforeOffset10, isLast: false)
        stream.sendBuffer.addSendData(sendData, isLast: true)
        XCTAssertThrowsError(
            try FrameStreamSendMetadata.write(
                into: &frame,
                stats: &stats,
                stream: stream,
                offset: 10,
                length: lengthToWrite,
                isFinal: true
            )
        )
    }

    #if NETWORK_PERF_TESTS
    func testStreamHeaderSizePerformance() {
        let stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(streamID: QUICStreamID(1), logPrefixer: .init("Test"))
        let sendData = Frame(copyBuffer: [UInt8](repeating: 0xab, count: 1400))
        stream.sendBuffer.addSendData(sendData, isLast: false)

        measure {
            for _ in 0..<100_000_000 {
                _ = FrameStreamSendMetadata.headerSizeForAvailableSize(
                    streamID: QUICStreamID(1),
                    offset: 10,
                    availableSize: 1200
                )
            }
        }
        let headerSize = FrameStreamSendMetadata.headerSizeForAvailableSize(
            streamID: QUICStreamID(1),
            offset: 10,
            availableSize: 1200
        )
        XCTAssertEqual(headerSize, 5)
    }

    func testStreamHeaderWritePerformance() {
        var frame = Frame(count: 1400)
        defer {
            frame.finalize(success: false)
        }
        var streams: [QUICStreamInstance] = []
        for idx in 0..<1_000 {
            let stream = QUICStreamInstance(parent: connection, inbound: false)
            stream.setup(
                streamID: QUICStreamID(UInt64(idx))!,
                logPrefixer: .init("Test")
            )
            streams.append(stream)
        }

        measure {
            for idx in 0..<10_000 {
                for stream in streams {
                    _ = try! FrameStreamSendMetadata.write(
                        into: &frame,
                        stats: &stats,
                        stream: stream,
                        offset: UInt64(idx),
                        length: 0,
                        isFinal: false
                    )
                    frame.startOffset = 0
                }
            }
        }
    }
    #endif

    // MARK: Max Data (0x10)

    func testMaxDataInit() throws {
        let bytes: [UInt8] = [0x10, 0x80, 0x45, 0xb2, 0x66]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameMaxData(frame: &frame)
        XCTAssertEqual(quicFrame.max, 4_567_654)
        frame.finalize(success: true)
    }

    func testMaxDataTruncated() throws {
        let bytes: [UInt8] = [0x10, 0x80, 0x45, 0xb2]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameMaxData(frame: &frame)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testMaxDataWriting() throws {
        let expectedBytes: [UInt8] = [0x10, 0x80, 0x45, 0xb2, 0x66]
        var frame = Frame(count: expectedBytes.count)
        try FrameMaxData.write(frame: &frame, max: 4_567_654)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testMaxDataShortBuffer() throws {
        var frame = Frame(count: 4)
        XCTAssertThrowsError(try FrameMaxData.write(frame: &frame, max: 4_567_654))
        frame.finalize(success: true)
    }

    // MARK: Max Stream Data (0x11)

    func testMaxStreamDataInit() throws {
        let bytes: [UInt8] = [
            0x11,
            0x41, 0x4d,
            0x80, 0x1e, 0x53, 0xf5,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameMaxStreamData(frame: &frame)
        XCTAssertEqual(quicFrame.id, 333)
        XCTAssertEqual(quicFrame.max, 1_987_573)
        frame.finalize(success: true)
    }

    func testMaxStreamDataTruncated() throws {
        let bytes: [UInt8] = [
            0x11,
            0x41, 0x4d,
            0x80, 0x1e,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameMaxStreamData(frame: &frame)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testMaxStreamDataWriting() throws {
        let expectedBytes: [UInt8] = [
            0x11,
            0x41, 0x4d,
            0x80, 0x1e, 0x53, 0xf5,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FrameMaxStreamData.write(frame: &frame, id: 333, max: 1_987_573)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testMaxStreamDataShortBuffer() throws {
        var frame = Frame(count: 6)
        XCTAssertThrowsError(try FrameMaxStreamData.write(frame: &frame, id: 333, max: 1_987_573))
        frame.finalize(success: true)
    }

    // MARK: Max Stream Bidirectional (0x12)

    func testMaxStreamBidirectionalInit() throws {
        let bytes: [UInt8] = [0x12, 0x67, 0x0f]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameMaxStreamsBidirectional(frame: &frame)
        XCTAssertEqual(quicFrame.max, 9999)
        frame.finalize(success: true)
    }

    func testMaxStreamBidirectionalTruncated() throws {
        let bytes: [UInt8] = [0x12, 0x67]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameMaxStreamsBidirectional(frame: &frame)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testMaxStreamBidirectionalWriting() throws {
        let expectedBytes: [UInt8] = [0x12, 0x67, 0x0f]
        var frame = Frame(count: expectedBytes.count)
        try FrameMaxStreamsBidirectional.write(frame: &frame, max: 9999)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testMaxStreamBidirectionalShortBuffer() throws {
        var frame = Frame(count: 2)
        XCTAssertThrowsError(try FrameMaxStreamsBidirectional.write(frame: &frame, max: 9999))
        frame.finalize(success: true)
    }

    // MARK: Max Stream Unidirectional (0x13)

    func testMaxStreamUnidirectionalInit() throws {
        let bytes: [UInt8] = [0x13, 0x40, 0xe8]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameMaxStreamsUnidirectional(frame: &frame)
        XCTAssertEqual(quicFrame.max, 232)
        frame.finalize(success: true)
    }

    func testMaxStreamUnidirectionalTruncated() throws {
        let bytes: [UInt8] = [0x13, 0x40]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameMaxStreamsUnidirectional(frame: &frame)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testMaxStreamUnidirectionalWriting() throws {
        let expectedBytes: [UInt8] = [0x13, 0x40, 0xe8]
        var frame = Frame(count: expectedBytes.count)
        try FrameMaxStreamsUnidirectional.write(frame: &frame, max: 232)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testMaxStreamUnidirectionalShortBuffer() throws {
        var frame = Frame(count: 2)
        XCTAssertThrowsError(try FrameMaxStreamsUnidirectional.write(frame: &frame, max: 232))
        frame.finalize(success: true)
    }

    // MARK: Data Blocked (0x14)

    func testDataBlockedInit() throws {
        let bytes: [UInt8] = [0x14, 0x89, 0xd0, 0xb9, 0x60]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameDataBlocked(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.limit, 164_673_888)
        frame.finalize(success: true)
    }

    func testDataBlockedTruncated() throws {
        let bytes: [UInt8] = [0x14, 0x89, 0xd0]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameDataBlocked(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testDataBlockedWriting() throws {
        let expectedBytes: [UInt8] = [0x14, 0x89, 0xd0, 0xb9, 0x60]
        var frame = Frame(count: expectedBytes.count)
        try FrameDataBlocked.write(frame: &frame, limit: 164_673_888, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testDataBlockedShortBuffer() throws {
        var frame = Frame(count: 4)
        XCTAssertThrowsError(
            try FrameDataBlocked.write(frame: &frame, limit: 164_673_888, stats: &stats)
        )
        frame.finalize(success: true)
    }

    // MARK: Stream Data Blocked (0x15)

    func testStreamDataBlockedInit() throws {
        let bytes: [UInt8] = [
            0x15,
            0x40, 0x5c,
            0x80, 0x87, 0x8e, 0xab,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameStreamDataBlocked(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.id, 92)
        XCTAssertEqual(quicFrame.limit, 8_883_883)
        frame.finalize(success: true)
    }

    func testStreamDataBlockedTruncated() throws {
        let bytes: [UInt8] = [
            0x15,
            0x40, 0x5c,
            0x80, 0x87,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamDataBlocked(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamDataBlockedWriting() throws {
        let expectedBytes: [UInt8] = [
            0x15,
            0x40, 0x5c,
            0x80, 0x87, 0x8e, 0xab,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FrameStreamDataBlocked.write(frame: &frame, id: 92, limit: 8_883_883, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testStreamDataBlockedShortBuffer() throws {
        var frame = Frame(count: 6)
        XCTAssertThrowsError(
            try FrameStreamDataBlocked.write(frame: &frame, id: 92, limit: 8_883_883, stats: &stats)
        )
        frame.finalize(success: true)
    }

    // MARK: Streams Blocked Bidirectional (0x16)

    func testStreamsBlockedBidirectionalInit() throws {
        let bytes: [UInt8] = [0x16, 0x43, 0xa5]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameStreamsBlockedBidirectional(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.limit, 933)
        frame.finalize(success: true)
    }

    func testStreamsBlockedBidirectionalTruncated() throws {
        let bytes: [UInt8] = [0x16, 0x43]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamsBlockedBidirectional(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamsBlockedBidirectionalWriting() throws {
        let expectedBytes: [UInt8] = [0x16, 0x43, 0xa5]
        var frame = Frame(count: expectedBytes.count)
        try FrameStreamsBlockedBidirectional.write(frame: &frame, limit: 933, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testStreamsBlockedBidirectionalShortBuffer() throws {
        var frame = Frame(count: 2)
        XCTAssertThrowsError(
            try FrameStreamsBlockedUnidirectional.write(frame: &frame, limit: 933, stats: &stats)
        )
        frame.finalize(success: true)
    }

    // MARK: Streams Blocked Unidirectional (0x17)

    func testStreamsBlockedUnidirectionalInit() throws {
        let bytes: [UInt8] = [0x17, 0x09]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameStreamsBlockedUnidirectional(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.limit, 9)
        frame.finalize(success: true)
    }

    func testStreamsBlockedUnidirectionalTruncated() throws {
        let bytes: [UInt8] = [0x17]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameStreamsBlockedUnidirectional(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testStreamsBlockedUnidirectionalWriting() throws {
        let expectedBytes: [UInt8] = [0x17, 0x09]
        var frame = Frame(count: expectedBytes.count)
        try FrameStreamsBlockedUnidirectional.write(frame: &frame, limit: 9, stats: &stats)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testStreamsBlockedUnidirectionalShortBuffer() throws {
        var frame = Frame(count: 1)
        XCTAssertThrowsError(
            try FrameStreamsBlockedBidirectional.write(frame: &frame, limit: 9, stats: &stats)
        )
        frame.finalize(success: true)
    }

    // MARK: New Connection ID (0x18)

    func testNewConnectionIDParsing() throws {
        let bytes: [UInt8] = [
            0x18,
            0x07,
            0x0a,
            0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20, 0xaa, 0xbb,
            0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameNewConnectionID(frame: &frame)
        XCTAssertEqual(quicFrame.sequence, 7)
        XCTAssertEqual(quicFrame.retirePriorToSequence, 10)
        XCTAssertEqual(
            quicFrame.connectionID,
            QUICConnectionID([1, 2, 3, 4, 5, 6, 7, 8])
        )
        XCTAssertEqual(
            quicFrame.statelessResetToken,
            QUICStatelessResetToken([
                0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20, 0xaa, 0xbb,
                0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20,
            ])
        )
        frame.finalize(success: true)
    }

    func testNewConnectionIDTruncated() {
        let bytes: [UInt8] = [
            0x18,
            0x07,
            0x0a,
            0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x07, 0x08, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x20, 0xaa, 0xbb,
        ]
        var frame = Frame(copyBuffer: bytes)
        XCTAssertThrowsError(try FrameNewConnectionID(frame: &frame))
        frame.finalize(success: true)
    }

    func testNewConnectionIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x18,
            0x03,
            0x0b,
            0x04,
            0xfa, 0x16, 0x33, 0x31,
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        ]
        let quicFrame = FrameNewConnectionID(
            sequence: 3,
            retirePriorToSequence: 11,
            connectionID: QUICConnectionID([0xfa, 0x16, 0x33, 0x31])!,
            statelessResetToken: QUICStatelessResetToken([
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            ])!
        )
        var frame = Frame(count: expectedBytes.count)
        try quicFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testNewConnectionIDShortBuffer() throws {
        let quicFrame = FrameNewConnectionID(
            sequence: 3,
            retirePriorToSequence: 11,
            connectionID: QUICConnectionID([0xfa, 0x16, 0x33, 0x31])!,
            statelessResetToken: QUICStatelessResetToken([
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            ])!
        )
        var frame = Frame(count: 23)
        XCTAssertThrowsError(try quicFrame.write(frame: &frame))
        frame.finalize(success: true)
    }

    // MARK: Retire Connection ID (0x19)

    func testRetireIDInit() throws {
        let bytes: [UInt8] = [0x19, 0x21]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameRetireConnectionID(frame: &frame)
        XCTAssertEqual(quicFrame.sequence, 33)
        frame.finalize(success: true)
    }

    func testRetireConnectionIDTruncated() {
        let bytes: [UInt8] = [0x19]
        var frame = Frame(copyBuffer: bytes)
        XCTAssertThrowsError(try FrameRetireConnectionID(frame: &frame))
        frame.finalize(success: true)
    }

    func testRetireConnectionIDWriting() throws {
        let expectedBytes: [UInt8] = [0x19, 0x21]
        let quicFrame = FrameRetireConnectionID(sequence: 33)
        var frame = Frame(count: expectedBytes.count)
        try quicFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testRetireConnectionIDShortBuffer() throws {
        let quicFrame = FrameRetireConnectionID(sequence: 33)
        var frame = Frame(count: 1)
        XCTAssertThrowsError(try quicFrame.write(frame: &frame))
        frame.finalize(success: true)
    }

    // MARK: Path Challenge (0x1a)

    func testPathChallengeInit() throws {
        let bytes: [UInt8] = [
            0x1a,
            0x93, 0x4a, 0x11, 0xff, 0xfa, 0x37, 0xa9, 0xf6,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FramePathChallenge(
            frame: &frame,
            destinationConnectionID: QUICConnectionID(0)
        )
        XCTAssertEqual(quicFrame.data, 0xf6a9_37fa_ff11_4a93)
        frame.finalize(success: true)
    }

    func testPathChallengeTruncated() {
        let bytes: [UInt8] = [
            0x1a,
            0x93, 0x4a, 0x11, 0xff, 0xfa, 0x37, 0xa9,
        ]
        var frame = Frame(copyBuffer: bytes)
        XCTAssertThrowsError(
            try FramePathChallenge(frame: &frame, destinationConnectionID: QUICConnectionID(0))
        )
        frame.finalize(success: true)
    }

    func testPathChallengeWriting() throws {
        let expectedBytes: [UInt8] = [
            0x1a,
            0x93, 0x4a, 0x11, 0xff, 0xfa, 0x37, 0xa9, 0xf6,
        ]
        let challenge: UInt64 = 0xf6a9_37fa_ff11_4a93
        let quicFrame = FramePathChallenge(data: challenge)
        var frame = Frame(count: expectedBytes.count)
        try quicFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testPathChallengeShortBuffer() throws {
        let challenge: UInt64 = 0xf6a9_37fa_ff11_4a93
        let quicFrame = FramePathChallenge(data: challenge)
        var frame = Frame(count: 8)
        XCTAssertThrowsError(try quicFrame.write(frame: &frame))
        frame.finalize(success: true)
    }

    // MARK: Path Response (0x1b)

    func testPathResponseInit() throws {
        let bytes: [UInt8] = [
            0x1b,
            0x93, 0x4a, 0x11, 0xff, 0xfa, 0x37, 0xa9, 0xf6,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FramePathResponse(
            frame: &frame,
            destinationConnectionID: QUICConnectionID(0)
        )
        XCTAssertEqual(quicFrame.data, 0xf6a9_37fa_ff11_4a93)
        frame.finalize(success: true)
    }

    func testPathResponseTruncated() {
        let bytes: [UInt8] = [
            0x1b,
            0x93, 0x4a, 0x11, 0xff, 0xfa, 0x37, 0xa9,
        ]
        var frame = Frame(copyBuffer: bytes)
        XCTAssertThrowsError(
            try FramePathResponse(frame: &frame, destinationConnectionID: QUICConnectionID(0))
        )
        frame.finalize(success: true)
    }

    func testPathResponseWriting() throws {
        let expectedBytes: [UInt8] = [
            0x1b,
            0x93, 0x4a, 0x11, 0xff, 0xfa, 0x37, 0xa9, 0xf6,
        ]
        let challenge: UInt64 = 0xf6a9_37fa_ff11_4a93
        let quicFrame = FramePathResponse(data: challenge)
        var frame = Frame(count: expectedBytes.count)
        try quicFrame.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testPathResponseShortBuffer() throws {
        let challenge: UInt64 = 0xf6a9_37fa_ff11_4a93
        let quicFrame = FramePathResponse(data: challenge)
        var frame = Frame(count: 8)
        XCTAssertThrowsError(try quicFrame.write(frame: &frame))
        frame.finalize(success: true)
    }

    // MARK: Connection Close (0x1c)

    func testConnectionCloseInit() throws {
        let bytes: [UInt8] = [
            0x1c,
            0x01,
            0x04,
            0x07,
            0x72, 0x65, 0x61, 0x73, 0x6f, 0x6e, 0x73,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameConnectionClose(frame: &frame, stats: &stats)
        XCTAssertEqual(
            quicFrame.errorCode,
            UInt64(QUICTransportError.QUICTransportErrorCode.internalError.rawValue)
        )
        XCTAssertEqual(quicFrame.frameType, .resetStream)
        XCTAssertEqual(quicFrame.reason.count, 7)
        XCTAssertEqual(quicFrame.reason, "reasons")
        frame.finalize(success: true)
    }

    func testConnectionCloseNoReasonInit() throws {
        let bytes: [UInt8] = [
            0x1c,
            0x01,
            0x04,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameConnectionClose(frame: &frame, stats: &stats)
        XCTAssertEqual(
            quicFrame.errorCode,
            UInt64(QUICTransportError.QUICTransportErrorCode.internalError.rawValue)
        )
        XCTAssertEqual(quicFrame.frameType, .resetStream)
        XCTAssertEqual(quicFrame.reason.count, 0)
        XCTAssertEqual(quicFrame.reason, "")
        frame.finalize(success: true)
    }

    func testConnectionCloseTruncated() {
        let bytes: [UInt8] = [
            0x1c,
            0x01,
            0x04,
            0x07,
            0x72, 0x65, 0x61, 0x73, 0x6f, 0x6e,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameConnectionClose(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testConnectionCloseWriting() throws {
        let expectedBytes: [UInt8] = [
            0x1c,
            0x01,
            0x04,
            0x07,
            0x72, 0x65, 0x61, 0x73, 0x6f, 0x6e, 0x73,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FrameConnectionClose.write(
            frame: &frame,
            stats: &stats,
            errorCode: UInt64(QUICTransportError.QUICTransportErrorCode.internalError.rawValue),
            frameType: .resetStream,
            reason: "reasons"
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testConnectionCloseNoReasonWriting() throws {
        let expectedBytes: [UInt8] = [
            0x1c,
            0x10,
            0x0b,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        try FrameConnectionClose.write(
            frame: &frame,
            stats: &stats,
            errorCode: UInt64(QUICTransportError.QUICTransportErrorCode.noViablePath.rawValue),
            frameType: .stream(flag: 0x03),
            reason: ""
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testConnectionCloseShortBuffer() throws {
        var frame = Frame(count: 10)
        XCTAssertThrowsError(
            try FrameConnectionClose.write(
                frame: &frame,
                stats: &stats,
                errorCode: UInt64(QUICTransportError.QUICTransportErrorCode.internalError.rawValue),
                frameType: .resetStream,
                reason: "reasons"
            )
        )
        frame.finalize(success: true)
    }

    // MARK: Application Close (0x1d)

    func testApplicationCloseInit() throws {
        let bytes: [UInt8] = [
            0x1d,
            0x40, 0x81,
            0x0c,
            0x6d, 0x6f, 0x72, 0x65, 0x20, 0x72, 0x65, 0x61, 0x73, 0x6f, 0x6e, 0x73,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameApplicationClose(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.errorCode, 129)
        XCTAssertEqual(quicFrame.reason.count, 12)
        XCTAssertEqual(quicFrame.reason, "more reasons")
        frame.finalize(success: true)
    }

    func testApplicationCloseNoReasonInit() throws {
        let bytes: [UInt8] = [
            0x1d,
            0x01,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        let quicFrame = try FrameApplicationClose(frame: &frame, stats: &stats)
        XCTAssertEqual(quicFrame.errorCode, 1)
        XCTAssertEqual(quicFrame.reason.count, 0)
        XCTAssertEqual(quicFrame.reason, "")
        frame.finalize(success: true)
    }

    func testApplicationCloseTruncated() {
        let bytes: [UInt8] = [
            0x1d,
            0x41, 0xc6,
            0x0c,
            0x6d, 0x6f, 0x72, 0x65, 0x20, 0x72, 0x65, 0x61,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameApplicationClose(frame: &frame, stats: &stats)
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testApplicationCloseWriting() throws {
        let expectedBytes: [UInt8] = [
            0x1d,
            0x40, 0x68,
            0x0c,
            0x6d, 0x6f, 0x72, 0x65, 0x20, 0x72, 0x65, 0x61, 0x73, 0x6f, 0x6e, 0x73,
        ]
        let quicFrame = FrameApplicationClose(
            errorCode: 104,
            reason: "more reasons"
        )
        var frame = Frame(count: expectedBytes.count)
        try quicFrame.write(frame: &frame, stats: &stats)
        // write always claims!
        _ = frame.unclaim(fromStart: frame.bufferLength)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    func testApplicationCloseShortBuffer() throws {
        let quicFrame = FrameApplicationClose(
            errorCode: 454,
            reason: "more reasons"
        )
        var frame = Frame(count: 15)
        XCTAssertThrowsError(try quicFrame.write(frame: &frame, stats: &stats))
        frame.finalize(success: true)
    }

    // MARK: Handshake Done (0x1e)

    func testHandshakeDoneInit() throws {
        let bytes: [UInt8] = [0x1e]
        var frame = Frame(copyBuffer: bytes)
        _ = try FrameHandshakeDone(frame: &frame)
        frame.finalize(success: true)
    }

    func testHandshakeDoneWriting() throws {
        let expectedBytes: [UInt8] = [0x1e]
        var frame = Frame(count: expectedBytes.count)
        try FrameHandshakeDone.write(frame: &frame)
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
    }

    // MARK: Datagram (0x30)

    func testDatagramInit() throws {
        let bytes: [UInt8] = [
            0x30,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramInitEmpty() throws {
        let bytes: [UInt8] = [
            0x30
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramFlowIDInit() throws {
        let bytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramFlowIDInitEmpty() throws {
        let bytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramContextIDInit() throws {
        let bytes: [UInt8] = [
            0x30,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramContextIDInitEmpty() throws {
        let bytes: [UInt8] = [
            0x30,
            0x0d,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramFlowIDContextIDInit() throws {
        let bytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramFlowIDContextIDInitEmpty() throws {
        let bytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
            0x0d,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramFlowIDContextIDInitTruncated() throws {
        let bytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameDatagram(
                frame: &frame,
                useFlowID: true,
                useContextID: true,
                connection: connection
            )
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testDatagramWriting() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: nil,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x30
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: nil,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramFlowIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: 77,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramFlowIDWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: 77,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramContextIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: nil,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
        frame.finalize(success: true)
        sendData.finalize(success: true)
    }

    func testDatagramContextIDWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0x0d,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: nil,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramFlowIDContextIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: 77,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramFlowIDContextIDWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x30,
            0x40, 0x4d,
            0x0d,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: false,
            flowID: 77,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramShortBuffer() throws {
        var frame = Frame(count: 4)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        XCTAssertThrowsError(
            try FrameDatagram.write(
                frame: &frame,
                hasLength: false,
                flowID: nil,
                contextID: nil,
                data: sendData,
                stats: &stats
            )
        )
    }

    // MARK: DatagramWithLength (0x30)

    func testDatagramLengthInit() throws {
        let bytes: [UInt8] = [
            0x31,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthInitEmpty() throws {
        let bytes: [UInt8] = [
            0x31,
            0x00,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthFlowIDInit() throws {
        let bytes: [UInt8] = [
            0x31,
            0x06,
            0x40, 0x4d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthFlowIDInitEmpty() throws {
        let bytes: [UInt8] = [
            0x31,
            0x02,
            0x40, 0x4d,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: false,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, nil)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthContextIDInit() throws {
        let bytes: [UInt8] = [
            0x31,
            0x05,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthContextIDInitEmpty() throws {
        let bytes: [UInt8] = [
            0x31,
            0x01,
            0x0d,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: false,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, nil)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthFlowIDContextIDInit() throws {
        let bytes: [UInt8] = [
            0x31,
            0x07,
            0x40, 0x4d,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 4)
        XCTAssertEqual(quicFrame.data, [0xaa, 0xbb, 0xcc, 0x44])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthFlowIDContextIDInitEmpty() throws {
        let bytes: [UInt8] = [
            0x31,
            0x03,
            0x40, 0x4d,
            0x0d,
        ]
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: true,
            connection: connection
        )
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.length, 0)
        XCTAssertEqual(quicFrame.data, [])
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramLengthFlowIDContextIDInitTruncated() throws {
        let bytes: [UInt8] = [
            0x31,
            0x03,
            0x40, 0x4d,
        ]
        var frame = Frame(copyBuffer: bytes)
        do {
            _ = try FrameDatagram(
                frame: &frame,
                useFlowID: true,
                useContextID: true,
                connection: connection
            )
            XCTFail("Should have thrown error for frame creation")
        } catch {
            // Expect error
        }
        frame.finalize(success: true)
    }

    func testDatagramLengthWriting() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x04,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: nil,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x00,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: nil,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthFlowIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x06,
            0x40, 0x4d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: 77,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthFlowIDWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x02,
            0x40, 0x4d,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: 77,
            contextID: nil,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthContextIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x05,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: nil,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthContextIDWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x01,
            0x0d,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: nil,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthFlowIDContextIDWriting() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x07,
            0x40, 0x4d,
            0x0d,
            0xaa, 0xbb, 0xcc, 0x44,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: 77,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthFlowIDContextIDWritingEmpty() throws {
        let expectedBytes: [UInt8] = [
            0x31,
            0x03,
            0x40, 0x4d,
            0x0d,
        ]
        var frame = Frame(count: expectedBytes.count)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(count: 0)
        defer {
            sendData.finalize(success: true)
        }
        try FrameDatagram.write(
            frame: &frame,
            hasLength: true,
            flowID: 77,
            contextID: 13,
            data: sendData,
            stats: &stats
        )
        XCTAssertTrue(frame.allBytesCopy!.elementsEqual(expectedBytes))
    }

    func testDatagramLengthShortBuffer() throws {
        var frame = Frame(count: 5)
        defer {
            frame.finalize(success: true)
        }
        var sendData = Frame(copyBuffer: [0xaa, 0xbb, 0xcc, 0x44])
        defer {
            sendData.finalize(success: true)
        }
        XCTAssertThrowsError(
            try FrameDatagram.write(
                frame: &frame,
                hasLength: true,
                flowID: nil,
                contextID: nil,
                data: sendData,
                stats: &stats
            )
        )
    }

    func testDatagramNoLengthParsing() throws {
        // Test parsing a datagram frame without length
        let data: [UInt8] = [0xaa, 0xbb, 0xcc, 0x44, 0xde, 0xad, 0xbe, 0xef]
        var bytes: [UInt8] = [
            0x30,  // Datagram frame type (no length field)
            0x40, 0x4d,
            0x0d,
        ]
        // Add the data to the end
        for byte in data {
            bytes.append(byte)
        }
        var frame = Frame(copyBuffer: bytes)
        var quicFrame = try FrameDatagram(
            frame: &frame,
            useFlowID: true,
            useContextID: true,
            connection: connection
        )

        XCTAssertEqual(quicFrame.flowID, 77)
        XCTAssertEqual(quicFrame.contextID, 13)
        XCTAssertEqual(quicFrame.length, 8)
        XCTAssertEqual(quicFrame.data, data)
        quicFrame.frame.finalize(success: true)
        frame.finalize(success: true)
    }

    func testDatagramBadLengthParsing() throws {
        let connection = QUICConnection(context: NetworkContext.implicitContext)

        let bytes: [UInt8] = [
            0x31,  // type: DATAGRAM with length
            0x00,  // Length VLE = 0  → rawLength = 0
            0x00,  // flowID VLE = 0  → headerOverhead = 1
            0x00, 0x00,  // remainingBytes = 2
        ]
        var frame = Frame(copyBuffer: bytes)
        defer {
            frame.finalize(success: true)
        }
        var threwError = false
        do {
            // Ask to parse flow ID and context ID, even though the length doesn't allow for them
            var quicFrame = try FrameDatagram(
                frame: &frame,
                useFlowID: true,
                useContextID: false,
                connection: connection
            )

            quicFrame.frame.finalize(success: true)
        } catch {
            threwError = true
        }

        XCTAssertTrue(threwError, "Expected thrown error")
    }

    func testIsAckEliciting() throws {
        // padding, acks and close frames are not ack eliciting
        XCTAssertFalse(
            QUICFrame.isAckEliciting(
                frame: QUICFrame.padding(
                    frame: FramePadding(
                        packetNumberSpace: PacketNumberSpace.initial,
                        padding: 0
                    )
                )
            )
        )

        XCTAssertFalse(
            QUICFrame
                .isAckEliciting(
                    frame:
                        QUICFrame
                        .ack(
                            frame: FrameAck(
                                packetNumberSpace: .initial,
                                largest: 1024,
                                delay: 0
                            )
                        )
                )
        )

        XCTAssertFalse(
            QUICFrame
                .isAckEliciting(
                    frame:
                        QUICFrame
                        .ack(
                            frame: FrameAck(
                                packetNumberSpace: .initial,
                                largest: 1024,
                                delay: 0
                            )
                        )
                )
        )

        XCTAssertFalse(
            QUICFrame
                .isAckEliciting(
                    frame: QUICFrame.ack(
                        frame: FrameAck(packetNumberSpace: .initial, largest: 2048, delay: 1)
                    )
                )
        )

        XCTAssertFalse(
            QUICFrame
                .isAckEliciting(
                    frame:
                        QUICFrame
                        .applicationClose(
                            frame: FrameApplicationClose(
                                errorCode: 0
                            )
                        )
                )
        )

        XCTAssertFalse(
            QUICFrame
                .isAckEliciting(
                    frame:
                        QUICFrame
                        .connectionClose(
                            frame: FrameConnectionClose(
                                errorCode: 0,
                                frameType: .ack
                            )
                        )
                )
        )

        // All other frame types are are eliciting
        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        QUICFrame
                        .ping(
                            frame: FramePing(
                                packetNumberSpace: .initial
                            )
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: QUICFrame.resetStream(
                        frame: FrameResetStream(id: 1, code: 2, finalSize: 3)
                    )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        QUICFrame
                        .stopSending(frame: FrameStopSending(id: 1, code: 2))
                )
        )
        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .crypto(
                        frame: FrameCrypto(
                            packetNumberSpace: .initial,
                            offset: 0,
                            data: []
                        )
                    )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .newToken(frame: FrameNewToken(token: [0]))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .stream(frame: FrameStreamReceived(id: 0, offset: 0, data: []))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .maxData(frame: FrameMaxData(max: 1024))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .maxStreamData(
                            frame: FrameMaxStreamData(id: 42, max: 4200)
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .maxStreamsBidirectional(
                            frame: FrameMaxStreamsBidirectional(max: 2048)
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .maxStreamsUnidirectional(
                            frame: FrameMaxStreamsUnidirectional(max: 1024)
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .dataBlocked(frame: FrameDataBlocked(limit: 10000))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .streamDataBlocked(
                            frame: FrameStreamDataBlocked(id: 0, limit: 20000)
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .streamsBlockedBidirectional(
                            frame: FrameStreamsBlockedBidirectional(limit: 22222)
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .streamsBlockedUnidirectional(
                            frame: FrameStreamsBlockedUnidirectional(
                                limit: 40000
                            )
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .newToken(frame: FrameNewToken(token: [1]))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame:
                        .retireConnectionID(
                            frame: FrameRetireConnectionID(sequence: 33333)
                        )
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .pathChallenge(frame: FramePathChallenge(data: 1234))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .pathResponse(frame: FramePathResponse(data: 1234))
                )
        )

        XCTAssertTrue(
            QUICFrame
                .isAckEliciting(
                    frame: .handshakeDone(frame: FrameHandshakeDone())
                )
        )
    }
}

#endif
