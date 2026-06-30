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
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

@available(Network 0.1.0, *)
final class SwiftNetworkMutexTests: NetTestCase {
    func testMutexWithoutStorage() throws {
        let context = NetworkContext.implicitContext

        nonisolated(unsafe) var protectedFlag = false
        nonisolated(unsafe) var protectedValue = 0

        let mutex = NetworkMutex(())

        context.async {
            for _ in 0..<100 {
                mutex.withLock { _ in
                    XCTAssertTrue((protectedFlag && protectedValue == 1) || (!protectedFlag && protectedValue == 0))
                    protectedFlag = false
                    protectedValue = 0
                }
            }
        }

        for _ in 0..<100 {
            mutex.withLock { _ in
                XCTAssertTrue((protectedFlag && protectedValue == 1) || (!protectedFlag && protectedValue == 0))
                protectedFlag = true
                protectedValue = 1
            }
        }

        XCTAssertTrue((protectedFlag && protectedValue == 1) || (!protectedFlag && protectedValue == 0))
    }

    func testMutexWithStorage() throws {
        let context = NetworkContext.implicitContext

        struct Protected {
            var flag = false
            var value = 0
        }

        let protected = NetworkMutex<Protected>(.init())

        context.async {
            for _ in 0..<100 {
                protected.withLock { protected in
                    XCTAssertTrue((protected.flag && protected.value == 1) || (!protected.flag && protected.value == 0))
                    protected.flag = false
                    protected.value = 0
                }
            }
        }

        for _ in 0..<100 {
            protected.withLock { protected in
                XCTAssertTrue((protected.flag && protected.value == 1) || (!protected.flag && protected.value == 0))
                protected.flag = true
                protected.value = 1
            }
        }

        protected.withLock { protected in
            XCTAssertTrue((protected.flag && protected.value == 1) || (!protected.flag && protected.value == 0))
        }
    }
}
