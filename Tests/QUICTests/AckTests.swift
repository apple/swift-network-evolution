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
func setAckFrame(_: PacketNumberSpace, _: consuming QUICFrame, _: Bool) {
}

/// Test-only conveniences that supply a fixed time.
///
/// The production signatures deliberately require a time, so that datapath code cannot
/// silently reach for the real clock. Most ACK tests are about packet-number bookkeeping
/// and not about time at all, so restating `now:` several hundred times would be noise.
/// The default here is a *fixed* instant, so those tests stay deterministic. A test
/// whose premise is timing calls the full form and passes its own instant.
@available(Network 0.1.0, *)
extension Ack {
    // only required by the test currently
    mutating func size(
        for packetNumberSpace: PacketNumberSpace,
        ecnCounter: ECNCounter? = nil
    ) -> Int {
        buildForTesting(
            for: packetNumberSpace,
            setAckFrame: setAckFrame,
            ecnCounter: ecnCounter
        )
    }

    mutating func append(packetNumberSpace: PacketNumberSpace, packetNumber: PacketNumber) {
        self.append(
            packetNumberSpace: packetNumberSpace,
            packetNumber: packetNumber,
            now: .testBase
        )
    }

    mutating func buildForTesting(
        for packetNumberSpace: PacketNumberSpace,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecnCounter: ECNCounter? = nil
    ) -> Int {
        self.buildForTesting(
            for: packetNumberSpace,
            setAckFrame: setAckFrame,
            ecnCounter: ecnCounter,
            now: .testBase
        )
    }
}

@available(Network 0.1.0, *)
let ackTestsLogPrefixer: LogPrefixer = LogPrefixer("[AckTests]")

@available(Network 0.1.0, *)
final class AckTests: XCTestCase {
    var ack = Ack(logPrefixer: ackTestsLogPrefixer)

    override func setUp() {
        ack.delaySize = 2
    }
    override func tearDown() {
        XCTAssertTrue(ack.consistencyCheck())
    }

    func testAckInsertInitial() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 2)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .handshake), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 0)
    }

    func testAckInsertHandshake() {
        ack.append(packetNumberSpace: .handshake, packetNumber: 0)
        ack.append(packetNumberSpace: .handshake, packetNumber: 1)
        ack.append(packetNumberSpace: .handshake, packetNumber: 2)
        ack.append(packetNumberSpace: .handshake, packetNumber: 3)
        ack.append(packetNumberSpace: .handshake, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .handshake), 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 0)
    }

    func testAckInsertApplicationData() {
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 3)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .handshake), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
    }

    func testAckInsertAllPNSpaces() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .handshake, packetNumber: 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .handshake), 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
    }

    func testAckInsertDuplicates() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .handshake, packetNumber: 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .handshake, packetNumber: 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .handshake), 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
    }

    func testAckInsertExtension() {
        // block_end extension
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)

        // block_start extension
        ack.append(packetNumberSpace: .initial, packetNumber: 5)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 2)
    }

    func testAckInsertBlockBefore() {
        ack.append(packetNumberSpace: .initial, packetNumber: 5)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 2)
    }

    func testAckInsertBlocks2() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)

        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        ack.append(packetNumberSpace: .initial, packetNumber: 5)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 2)
    }

    func testAckInsertBlocks3() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        ack.append(packetNumberSpace: .initial, packetNumber: 5)
        ack.append(packetNumberSpace: .initial, packetNumber: 7)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 3)
    }

    func testAckInsertBlocks5() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        ack.append(packetNumberSpace: .initial, packetNumber: 5)
        ack.append(packetNumberSpace: .initial, packetNumber: 10)
        ack.append(packetNumberSpace: .initial, packetNumber: 11)
        ack.append(packetNumberSpace: .initial, packetNumber: 20)
        ack.append(packetNumberSpace: .initial, packetNumber: 30)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 5)

    }

    func testAckInsertBlocks11() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        ack.append(packetNumberSpace: .initial, packetNumber: 6)
        ack.append(packetNumberSpace: .initial, packetNumber: 7)
        ack.append(packetNumberSpace: .initial, packetNumber: 9)
        ack.append(packetNumberSpace: .initial, packetNumber: 10)
        ack.append(packetNumberSpace: .initial, packetNumber: 12)
        ack.append(packetNumberSpace: .initial, packetNumber: 13)
        ack.append(packetNumberSpace: .initial, packetNumber: 15)
        ack.append(packetNumberSpace: .initial, packetNumber: 16)
        ack.append(packetNumberSpace: .initial, packetNumber: 18)
        ack.append(packetNumberSpace: .initial, packetNumber: 19)
        ack.append(packetNumberSpace: .initial, packetNumber: 21)
        ack.append(packetNumberSpace: .initial, packetNumber: 22)
        ack.append(packetNumberSpace: .initial, packetNumber: 24)
        ack.append(packetNumberSpace: .initial, packetNumber: 25)
        ack.append(packetNumberSpace: .initial, packetNumber: 27)
        ack.append(packetNumberSpace: .initial, packetNumber: 28)
        ack.append(packetNumberSpace: .initial, packetNumber: 30)
        ack.append(packetNumberSpace: .initial, packetNumber: 31)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 11)
    }

    func testAckPacketsMissingBetween() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 2)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        // Gap [4,6]
        ack.append(packetNumberSpace: .initial, packetNumber: 7)
        ack.append(packetNumberSpace: .initial, packetNumber: 8)
        ack.append(packetNumberSpace: .initial, packetNumber: 9)

        // New packet creates a gap from the previous largest received.
        XCTAssertTrue(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 9,
                packetNumberHigh: 12
            )
        )
        // Newly received packet has the next packet number.
        XCTAssertFalse(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 9,
                packetNumberHigh: 10
            )
        )
        XCTAssertFalse(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 8,
                packetNumberHigh: 10
            )
        )
        XCTAssertFalse(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 7,
                packetNumberHigh: 10
            )
        )
        XCTAssertTrue(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 3,
                packetNumberHigh: 10
            )
        )
        XCTAssertTrue(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 2,
                packetNumberHigh: 10
            )
        )
        XCTAssertTrue(
            ack.packetsMissingBetween(
                packetNumberSpace: .initial,
                packetNumberLow: 1,
                packetNumberHigh: 10
            )
        )
    }

    func testInsertBlockOutOfOrder1() {
        for i in 10...20 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
        for i in 30...40 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 7)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 3)
    }

    func testInsertBlockOutOfOrder2() {
        for i in 10...20 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
        for i in 30...40 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 27)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 3)
    }

    func testAckCoalescing2() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 2)
        ack.append(packetNumberSpace: .initial, packetNumber: 2)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
    }

    func testAckCoalescing3() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 2)
        ack.append(packetNumberSpace: .initial, packetNumber: 6)
        ack.append(packetNumberSpace: .initial, packetNumber: 7)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 2)
        ack.append(packetNumberSpace: .initial, packetNumber: 5)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
    }

    func testAckOfAck() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        ack.append(packetNumberSpace: .initial, packetNumber: 6)
        ack.append(packetNumberSpace: .initial, packetNumber: 7)
        ack.append(packetNumberSpace: .initial, packetNumber: 9)
        ack.append(packetNumberSpace: .initial, packetNumber: 10)
        ack.append(packetNumberSpace: .initial, packetNumber: 12)
        ack.append(packetNumberSpace: .initial, packetNumber: 13)
        ack.append(packetNumberSpace: .initial, packetNumber: 15)
        ack.append(packetNumberSpace: .initial, packetNumber: 16)
        ack.append(packetNumberSpace: .initial, packetNumber: 18)
        ack.append(packetNumberSpace: .initial, packetNumber: 19)
        ack.append(packetNumberSpace: .initial, packetNumber: 21)
        ack.append(packetNumberSpace: .initial, packetNumber: 22)
        ack.append(packetNumberSpace: .initial, packetNumber: 24)
        ack.append(packetNumberSpace: .initial, packetNumber: 25)
        ack.append(packetNumberSpace: .initial, packetNumber: 27)
        ack.append(packetNumberSpace: .initial, packetNumber: 28)
        ack.append(packetNumberSpace: .initial, packetNumber: 30)
        ack.append(packetNumberSpace: .initial, packetNumber: 31)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 11)
        ack.acknowledged(packetNumberSpace: .initial, between: 0, and: 1)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 10)
        ack.acknowledged(packetNumberSpace: .initial, between: 3, and: 3)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 10)
        ack.acknowledged(packetNumberSpace: .initial, between: 3, and: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 9)
        ack.acknowledged(packetNumberSpace: .initial, between: 6, and: 7)
        ack.acknowledged(packetNumberSpace: .initial, between: 9, and: 10)
        ack.acknowledged(packetNumberSpace: .initial, between: 12, and: 13)
        ack.acknowledged(packetNumberSpace: .initial, between: 15, and: 16)
        ack.acknowledged(packetNumberSpace: .initial, between: 18, and: 19)
        ack.acknowledged(packetNumberSpace: .initial, between: 21, and: 22)
        ack.acknowledged(packetNumberSpace: .initial, between: 24, and: 25)
        ack.acknowledged(packetNumberSpace: .initial, between: 27, and: 28)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 1)
        ack.acknowledged(packetNumberSpace: .initial, between: 30, and: 31)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 0)
    }

    func testAckOfAckWithReorder() {
        for i in 10...20 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
        for i in 30...40 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 2)
        for i in 25...28 {
            ack.append(
                packetNumberSpace: .applicationData,
                packetNumber: PacketNumber(
                    Int64(i)
                )
            )
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 3)
        ack.acknowledged(packetNumberSpace: .applicationData, between: 10, and: 20)
        ack.acknowledged(packetNumberSpace: .applicationData, between: 30, and: 40)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 1)
        ack.acknowledged(packetNumberSpace: .applicationData, between: 25, and: 28)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 0)
    }

    func testAckProcessLargest() {
        let frame = FrameAck(
            packetNumberSpace: .initial,
            largest: 100,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 0)]
        )
        for block in Ack.blockSequence(frame: frame) {
            XCTAssertEqual(block.start, 100)
            XCTAssertEqual(block.end, 100)
        }
    }

    func testAckProcessBlock1() {
        let frame = FrameAck(
            packetNumberSpace: .initial,
            largest: 10,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10)]
        )

        for block in Ack.blockSequence(frame: frame) {
            XCTAssertEqual(block.start, 0)
            XCTAssertEqual(block.end, 10)
        }
    }

    func testAckProcessGap1() {
        let frame = FrameAck(
            packetNumberSpace: .initial,
            largest: 7,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 2), FrameAckRange(gap: 0, range: 2)]
        )
        var blockNumber = 0

        for block in Ack.blockSequence(frame: frame) {
            if blockNumber == 0 {
                XCTAssertEqual(block.start, 5)
                XCTAssertEqual(block.end, 7)
            } else if blockNumber == 1 {
                XCTAssertEqual(block.start, 1)
                XCTAssertEqual(block.end, 3)
            } else {
                XCTAssertFalse(true)
            }
            blockNumber += 1
        }
    }
    func testAckSizeBlock0() {
        XCTAssertEqual(ack.size(for: .initial), 0)
    }

    func testAckSizeBlock1() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        XCTAssertEqual(ack.size(for: .initial), 6)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        XCTAssertEqual(ack.size(for: .initial), 6)
    }

    func testAckSizeBlock2() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        XCTAssertEqual(ack.size(for: .initial), 8)
    }

    func testAckSizeBlock5() {
        ack.append(packetNumberSpace: .initial, packetNumber: 100000)
        ack.append(packetNumberSpace: .initial, packetNumber: 100001)
        ack.append(packetNumberSpace: .initial, packetNumber: 100003)
        ack.append(packetNumberSpace: .initial, packetNumber: 100004)
        ack.append(packetNumberSpace: .initial, packetNumber: 100006)
        ack.append(packetNumberSpace: .initial, packetNumber: 100007)
        ack.append(packetNumberSpace: .initial, packetNumber: 100009)
        ack.append(packetNumberSpace: .initial, packetNumber: 100010)
        ack.append(packetNumberSpace: .initial, packetNumber: 100012)
        ack.append(packetNumberSpace: .initial, packetNumber: 100013)
        XCTAssertEqual(ack.size(for: .initial), 17)
    }

    func testAckSizeBlockWithECN() {
        ack.append(packetNumberSpace: .initial, packetNumber: 100000)
        ack.append(packetNumberSpace: .initial, packetNumber: 100001)
        ack.append(packetNumberSpace: .initial, packetNumber: 100003)
        ack.append(packetNumberSpace: .initial, packetNumber: 100004)
        ack.append(packetNumberSpace: .initial, packetNumber: 100006)
        ack.append(packetNumberSpace: .initial, packetNumber: 100007)
        ack.append(packetNumberSpace: .initial, packetNumber: 100009)
        ack.append(packetNumberSpace: .initial, packetNumber: 100010)
        ack.append(packetNumberSpace: .initial, packetNumber: 100012)
        ack.append(packetNumberSpace: .initial, packetNumber: 100013)
        let ecnCounter = ECNCounter(ect0: 64, ect1: 128, ce: 2)
        // size would be 17 without the ACK_ECN frame.
        XCTAssertEqual(ack.size(for: .initial, ecnCounter: ecnCounter), 22)
    }

    func testAckFlush() {
        ack.append(packetNumberSpace: .initial, packetNumber: 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        ack.append(packetNumberSpace: .initial, packetNumber: 3)
        ack.append(packetNumberSpace: .initial, packetNumber: 4)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 2)
        ack.flush(for: .initial)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .initial), 0)
    }

    func testAckBitstringBasic() {
        let frame1 = FrameAck(
            packetNumberSpace: .initial,
            largest: 10,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10)]
        )
        let frame2 = FrameAck(
            packetNumberSpace: .initial,
            largest: 12,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 12)]
        )

        var bitstring1 = AckBitstring(frame: frame1, oldestPN: 0)
        var bitstring2 = AckBitstring(frame: frame2, oldestPN: 0)
        var numPackets = 0
        for packetNumber in bitstring1.xor(other: &bitstring2, firstPN: 0, lastPN: frame2.largest) {
            XCTAssert(packetNumber >= 11 && packetNumber <= 12)
            numPackets += 1
        }
        XCTAssertEqual(numPackets, 2)
    }

    func testAckBitstringExpansion() {
        let frame1 = FrameAck(
            packetNumberSpace: .initial,
            largest: 10000,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10000)]
        )
        let frame2 = FrameAck(
            packetNumberSpace: .initial,
            largest: 10002,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10002)]
        )

        var bitstring1 = AckBitstring(frame: frame1, oldestPN: 0)
        var bitstring2 = AckBitstring(frame: frame2, oldestPN: 0)
        var numPackets = 0
        for packetNumber in bitstring1.xor(other: &bitstring2, firstPN: 0, lastPN: frame2.largest) {
            XCTAssert(packetNumber >= 10000 && packetNumber <= 10002)
            numPackets += 1
        }
        XCTAssertEqual(numPackets, 2)
    }

    func testAckBitstringWordBoundary() {
        let frame1 = FrameAck(
            packetNumberSpace: .initial,
            largest: 63,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 63)]
        )
        let frame2 = FrameAck(
            packetNumberSpace: .initial,
            largest: 64,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 64)]
        )

        var bitstring1 = AckBitstring(frame: frame1, oldestPN: 0)
        var bitstring2 = AckBitstring(frame: frame2, oldestPN: 0)
        var numPackets = 0
        for packetNumber in bitstring1.xor(other: &bitstring2, firstPN: 0, lastPN: frame2.largest) {
            XCTAssert(packetNumber == 64)
            numPackets += 1
        }

        XCTAssertEqual(numPackets, 1)

    }

    func testAckBitstringSeparateWords() {
        let frame1 = FrameAck(
            packetNumberSpace: .initial,
            largest: 20,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 20)]
        )
        let frame2 = FrameAck(
            packetNumberSpace: .initial,
            largest: 100,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 100)]
        )

        var bitstring1 = AckBitstring(frame: frame1, oldestPN: 0)
        var bitstring2 = AckBitstring(frame: frame2, oldestPN: 0)
        var numPackets = 0
        for packetNumber in bitstring1.xor(other: &bitstring2, firstPN: 0, lastPN: frame2.largest) {
            XCTAssert(packetNumber > 20 && packetNumber <= 100)
            numPackets += 1
        }
        XCTAssertEqual(numPackets, 80)
    }

    func testAckBitstringTrimming() {
        let frame1 = FrameAck(
            packetNumberSpace: .initial,
            largest: 10000,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10000)]
        )
        let frame2 = FrameAck(
            packetNumberSpace: .initial,
            largest: 10002,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10002)]
        )

        var bitstring1 = AckBitstring(frame: frame1, oldestPN: 0)
        var bitstring2 = AckBitstring(frame: frame2, oldestPN: 0)
        var numPackets = 0
        for packetNumber in bitstring1.xor(other: &bitstring2, firstPN: 0, lastPN: frame2.largest) {
            XCTAssert(packetNumber >= 10000 && packetNumber <= 10002)
            numPackets += 1
        }
        XCTAssertEqual(numPackets, 2)
        // Bitstrings were trimmed at this point.  Check again.
        swap(&bitstring1, &bitstring2)
        let frame3 = FrameAck(
            packetNumberSpace: .initial,
            largest: 10004,
            delay: 0,
            ranges: [FrameAckRange(gap: 0, range: 10004)]
        )
        numPackets = 0
        for packetNumber in bitstring1.xor(
            other: &bitstring2,
            firstPN: 1024,
            lastPN: frame3.largest
        ) {
            XCTAssert(packetNumber >= 10000 && packetNumber <= 10004)
            numPackets += 1
        }

        XCTAssertEqual(numPackets, 2)
    }

    func testAckBitstringStress() {
        var oldestPN = PacketNumber(0)
        var bitstring1 = AckBitstring()
        var bitstring2 = AckBitstring()

        for packetNumber in stride(from: 1, through: 100_000, by: 2) {
            let frame = FrameAck(
                packetNumberSpace: .initial,
                largest: PacketNumber(Int64(packetNumber)),
                delay: 0,
                ranges: [FrameAckRange(gap: 0, range: PacketNumber(Int64(packetNumber)))]
            )
            bitstring2.reinit(frame: frame, oldestPN: oldestPN)
            var numPackets = 0
            for innerPacketNumber in bitstring1.xor(
                other: &bitstring2,
                firstPN: oldestPN,
                lastPN: frame.largest
            ) {
                XCTAssert(
                    innerPacketNumber >= PacketNumber(Int64(packetNumber - 1))
                        && innerPacketNumber < PacketNumber(Int64(packetNumber + 2))
                )
                numPackets += 1
            }

            XCTAssertEqual(numPackets, 2)
            swap(&bitstring1, &bitstring2)

            // Move oldestPN forward to emulate a real connection.
            if oldestPN == 0 && packetNumber > 1000 {
                oldestPN = 1000
            }
            if oldestPN == 1000 && packetNumber > 5000 {
                oldestPN = 5000
            }
            if oldestPN == 5000 && packetNumber > 10000 {
                oldestPN = 10000
            }
        }
    }

    // Initial values for ACK gen count
    func testAckGenCountInitial() {
        XCTAssertEqual(ack.getGenerationCount(for: .initial, now: 0), 0)
        XCTAssertEqual(ack.getGenerationCount(for: .handshake, now: 0), 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
    }

    // ACK gen count is always 0 during the handshake
    func testAckGenCountHandshake() {
        ack.append(packetNumberSpace: .initial, packetNumber: 1)
        XCTAssertEqual(ack.getGenerationCount(for: .initial, now: 0), 0)
        ack.append(packetNumberSpace: .initial, packetNumber: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .initial, now: 0), 0)
        XCTAssertEqual(ack.getGenerationCount(for: .handshake, now: 0), 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
    }

    func testAckGenCountTrivial() {
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 3)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
    }

    // Tests the generation count with a single gap
    func testAckGenCountGap() {
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 6)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
    }

    // Tests the generation count after adding another ACK block
    func testAckGenCountMultiGap() {
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 7)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 3)
    }

    // Tests the generation count after removing an ACK block
    func testAckGenCountGapRemoved() {
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 7)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 3)
        ack.acknowledged(packetNumberSpace: .applicationData, between: 0, and: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 4)
    }

    // Tests the generation count after removing all ACK blocks
    func testAckGenCountEmptyBlock() {
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
        ack.acknowledged(packetNumberSpace: .applicationData, between: 0, and: 2)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 3)
        ack.acknowledged(packetNumberSpace: .applicationData, between: 4, and: 5)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 4)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 7)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 5)
    }
    // Tests that we increment the generation count every 5ms
    func testAckGenCount5ms() {
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(5 * System.Time.USEC_PER_MSEC)),
            0
        )
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(5 * System.Time.USEC_PER_MSEC)),
            1
        )
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(5 * System.Time.USEC_PER_MSEC)),
            1
        )
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(5 * System.Time.USEC_PER_MSEC)),
            1
        )
        ack.append(packetNumberSpace: .applicationData, packetNumber: 3)
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(10 * System.Time.USEC_PER_MSEC)),
            2
        )
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(13 * System.Time.USEC_PER_MSEC)),
            2
        )
        XCTAssertEqual(
            ack.getGenerationCount(for: .applicationData, now: Int(20 * System.Time.USEC_PER_MSEC)),
            3
        )
    }

    // Tests that we increment the generation count when sending a CE marked ACK.
    func testAckGenCountCE() {
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 3)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 6)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 7)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 1)
        let ecnCounter = ECNCounter(ect0: 0, ect1: 0, ce: 1)
        let _ = ack.size(for: .applicationData, ecnCounter: ecnCounter)
        XCTAssertEqual(ack.getGenerationCount(for: .applicationData, now: 0), 2)
    }

    #if NETWORK_PERF_TESTS
    func testAckBuildPerformance() {
        for pn in stride(from: 1, to: 1_000_000, by: 2) {
            ack.append(packetNumberSpace: .applicationData, packetNumber: PacketNumber(Int64(pn)))
        }
        var size: Int?
        measure {
            size = ack.buildForTesting(for: .applicationData, setAckFrame: setAckFrame)
        }
        XCTAssertEqual(size, 1_000_010)
    }
    #endif

    func testAckPingThresholdTriggered() {
        // Create blocks to exceed the ping threshold
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 2)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 4)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 6)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 8)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 10)

        // Verify we have more than 5 blocks
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 6)
        XCTAssertGreaterThan(
            ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData),
            Ack.pingThreshold
        )

        let pingExpectation = XCTestExpectation(description: "Wait for ping callback")
        var pingFrameRequested = false
        let testSetAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void = {
            _,
            _,
            shouldPing in
            pingFrameRequested = shouldPing
            pingExpectation.fulfill()
        }
        let _ = ack.assemble(
            for: .applicationData,
            isAckSet: false,
            setAckFrame: testSetAckFrame,
            ecnCounter: nil,
            now: .testBase
        )
        wait(for: [pingExpectation], timeout: 2.0)
        XCTAssertTrue(
            pingFrameRequested,
            "PING frame should be requested when block count exceeds ping threshold"
        )
    }

    func testAckPingThresholdNotTriggered() {
        // Do not exceed the ping threshold
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 1)  // No gap
        ack.append(packetNumberSpace: .applicationData, packetNumber: 3)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 5)
        ack.append(packetNumberSpace: .applicationData, packetNumber: 7)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 4)
        XCTAssertLessThanOrEqual(
            ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData),
            Ack.pingThreshold
        )

        // Since the ping threshold was not hit here pingFrameRequested should be false
        let pingExpectation = XCTestExpectation(description: "Wait for ping callback")
        var pingFrameRequested = false
        let testSetAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void = {
            _,
            _,
            shouldPing in
            pingFrameRequested = shouldPing
            pingExpectation.fulfill()
        }
        let _ = ack.assemble(
            for: .applicationData,
            isAckSet: false,
            setAckFrame: testSetAckFrame,
            ecnCounter: nil,
            now: .testBase
        )
        wait(for: [pingExpectation], timeout: 2.0)
        // Verify that a PING frame was NOT requested
        XCTAssertFalse(
            pingFrameRequested,
            "PING frame should NOT be requested when block count is at or below ping threshold"
        )
    }

    func testBitstringGrowth() {
        var bitstring = AckBitstring()
        XCTAssertTrue(bitstring.size == 64, "Bitstring should have an initial size of 64")
        // Exceed past 64 * 64
        bitstring.nset(start: 0, stop: 4480)
        // The count should now be doubled from the start
        XCTAssertTrue(bitstring.size == 128, "Bitstring should have an initial size of 128")
        // Exceed again past 128 * 64
        bitstring.nset(start: 0, stop: 13000)
        XCTAssertTrue(bitstring.size == 256, "Bitstring should have an initial size of 256")

        // This should not resize
        let maxStopWord = PacketNumber.max
        bitstring.nset(start: 0, stop: maxStopWord)
        XCTAssertTrue(bitstring.size == 256, "Bitstring should have an initial size of 256")
    }

    func testAckFrameWithManyRanges() {
        var ranges: [FrameAckRange] = []
        for i in 0..<100 {
            ranges.append(FrameAckRange(gap: 0, range: PacketNumber(Int64(i))))
        }
        let frame = FrameAck(
            packetNumberSpace: .initial,
            largest: 10,
            delay: 0,
            ranges: ranges
        )
        XCTAssertTrue(frame.ranges.count == 100)
    }

    func testAckBlockIterator() {
        let frame = FrameAck(
            packetNumberSpace: .initial,
            largest: 10,
            delay: 0,
            ranges: [
                FrameAckRange(gap: 0, range: 4),
                FrameAckRange(gap: 1, range: 2),
            ]
        )

        let seq = Ack.blockSequence(frame: frame)

        var emittedBlocks = 0
        for block in seq {
            if emittedBlocks == 0 {
                XCTAssertEqual(block.start, 6)
                XCTAssertEqual(block.end, 10)
            } else {
                XCTAssertEqual(block.start, 1)
                XCTAssertEqual(block.end, 3)
            }
            emittedBlocks += 1
        }
        XCTAssertEqual(emittedBlocks, 2)
    }

    func testAckBlockIteratorInvalidUnderflow() {
        // Generate a FrameAck with invalid gaps that could create underflow
        let frame = FrameAck(
            packetNumberSpace: .initial,
            largest: 0,
            delay: 0,
            ranges: [
                FrameAckRange(gap: 0, range: PacketNumber.max),
                FrameAckRange(gap: PacketNumber.max, range: 1),
            ]
        )

        let seq = Ack.blockSequence(frame: frame)

        var emittedBlocks = 0
        for _ in seq {
            emittedBlocks += 1
        }
        XCTAssertEqual(emittedBlocks, 0)
    }

    // Appending more than Ack.maxAckBlocks (256) separate blocks must cause the
    // oldest (lowest-PN) block to be dropped when the ACK is sized/assembled, and
    // the block count must converge to 256.
    func testAckMaxBlocksCap() {
        // PNs spaced by 2 leave a one-packet gap between each, so no two blocks
        // coalesce: 257 appends -> 257 separate blocks.
        for i in 0...256 {
            ack.append(packetNumberSpace: .applicationData, packetNumber: PacketNumber(Int64(i * 2)))
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 257)

        // Sizing the ACK drives AckSpace.build(), which trims one block because the
        // count (257) exceeds Ack.maxAckBlocks.
        XCTAssertGreaterThan(ack.size(for: .applicationData), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 256)

        // The dropped block must be the oldest one (the block covering PN 0).
        // Re-appending PN 0 proves it: if PN 0 is no longer covered the append
        // creates a fresh block (count -> 257); had any other block been dropped,
        // PN 0 would still be covered and the append would be a no-op duplicate.
        ack.append(packetNumberSpace: .applicationData, packetNumber: 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 257)
        // Clean up that probe block so the cap-stability check below starts at 256.
        ack.acknowledged(packetNumberSpace: .applicationData, between: 0, and: 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 256)

        // The cap is stable: 256 is not > Ack.maxAckBlocks, so a second sizing
        // removes nothing.
        XCTAssertGreaterThan(ack.size(for: .applicationData), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 256)
    }

    // Exactly Ack.maxAckBlocks (256) blocks must not trigger trimming: the guard
    // is "> 256", not ">= 256".
    func testAckMaxBlocksBoundary() {
        for i in 0..<256 {
            ack.append(packetNumberSpace: .applicationData, packetNumber: PacketNumber(Int64(i * 2)))
        }
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 256)

        XCTAssertGreaterThan(ack.size(for: .applicationData), 0)
        XCTAssertEqual(ack.blocksForPacketNumberSpace(packetNumberSpace: .applicationData), 256)
    }

}

#endif
