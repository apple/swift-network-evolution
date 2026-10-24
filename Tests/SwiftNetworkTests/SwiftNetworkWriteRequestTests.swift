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
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkWriteRequestTests: NetTestCase {
    private func order(of priorities: [Double]) -> [Double] {
        var queue = NetworkUniqueDeque<WriteRequest>()
        for priority in priorities {
            var request = WriteRequest(content: [1], isComplete: false, completion: nil)
            request.relativePriority = priority
            queue.appendOrderedByPriority(request)
        }
        var result: [Double] = []
        while var next = queue.popFirst() {
            result.append(next.relativePriority)
            next.frame.finalize(success: true)
        }
        return result
    }

    func testEqualPriorityIsFirstInFirstOut() {
        var queue = NetworkUniqueDeque<WriteRequest>()
        for byte in UInt8(0)..<4 {
            queue.appendOrderedByPriority(WriteRequest(content: [byte], isComplete: false, completion: nil))
        }
        XCTAssertEqual(queue.count, 4)
        while var next = queue.popFirst() {
            XCTAssertEqual(next.relativePriority, 0.5)
            next.frame.finalize(success: true)
        }
    }

    func testHigherPriorityGoesFirst() {
        XCTAssertEqual(order(of: [0.2, 0.5, 0.9, 0.5]), [0.9, 0.5, 0.5, 0.2])
    }

    func testLowerPriorityJoinsTheEnd() {
        XCTAssertEqual(order(of: [0.9, 0.5, 0.1]), [0.9, 0.5, 0.1])
    }

    func testCompleteRequestFlags() {
        var request = WriteRequest(content: [], isComplete: true, completion: nil)
        XCTAssertTrue(request.flags.contains(.isComplete))
        request.frame.finalize(success: true)
    }
}
