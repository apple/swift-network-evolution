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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkSmallArrayTests: NetTestCase {
    func testEmpty() {
        let array = SmallArray<FrameAckRange>()
        XCTAssertEqual(array.count, 0)
        XCTAssertTrue(array.isEmpty)
        XCTAssertTrue(array.toArray().isEmpty)
    }

    func testOneAndTwoUseInlineStorage() {
        var array = SmallArray<FrameAckRange>()
        array.append(FrameAckRange(gap: 0, range: 1))
        XCTAssertEqual(array.count, 1)
        XCTAssertFalse(array.isEmpty)
        XCTAssertEqual(array[0].range, 1)

        array.append(FrameAckRange(gap: 2, range: 3))
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0].range, 1)
        XCTAssertEqual(array[1].gap, 2)
        XCTAssertEqual(array[1].range, 3)
    }

    func testThreeOrMoreFallBackToHeapStorage() {
        var array = SmallArray<FrameAckRange>()
        for i in 0..<5 {
            array.append(FrameAckRange(gap: 0, range: PacketNumber(Int64(i))))
        }
        XCTAssertEqual(array.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(array[i].range, PacketNumber(Int64(i)))
        }
        XCTAssertEqual(array.toArray().count, 5)
    }

    func testSubscriptSetMutatesInPlace() {
        var array = SmallArray<FrameAckRange>()
        array.append(FrameAckRange(gap: 0, range: 1))
        array.append(FrameAckRange(gap: 0, range: 2))
        array.append(FrameAckRange(gap: 0, range: 3))

        array[1] = FrameAckRange(gap: 9, range: 99)

        XCTAssertEqual(array[0].range, 1)
        XCTAssertEqual(array[1].gap, 9)
        XCTAssertEqual(array[1].range, 99)
        XCTAssertEqual(array[2].range, 3)
    }

    func testRemoveDemotesToInlineStorage() {
        var array = SmallArray<FrameAckRange>()
        for i in 0..<4 {
            array.append(FrameAckRange(gap: 0, range: PacketNumber(Int64(i))))
        }
        XCTAssertEqual(array.count, 4)

        // many -> many
        let removedAtTwo = array.remove(at: 2)
        XCTAssertEqual(removedAtTwo.range, 2)
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array.toArray().map(\.range), [0, 1, 3])

        // many -> two
        let removedAtZero = array.remove(at: 0)
        XCTAssertEqual(removedAtZero.range, 0)
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0].range, 1)
        XCTAssertEqual(array[1].range, 3)

        // two -> one
        let removedThird = array.remove(at: 1)
        XCTAssertEqual(removedThird.range, 3)
        XCTAssertEqual(array.count, 1)
        XCTAssertEqual(array[0].range, 1)

        // one -> empty
        let removedLast = array.remove(at: 0)
        XCTAssertEqual(removedLast.range, 1)
        XCTAssertEqual(array.count, 0)
        XCTAssertTrue(array.isEmpty)
    }

    func testGenericOverElementType() {
        var strings = SmallArray<String>()
        strings.append("a")
        strings.append("b")
        strings.append("c")
        XCTAssertEqual(strings.count, 3)
        XCTAssertEqual(strings.toArray(), ["a", "b", "c"])
    }
}
#endif
