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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
import XCTest

@available(anyAppleOS 27, *)
final class SwiftNetworkFrameTests: XCTestCase {
    func testFrameLayout() {
        XCTAssertEqual(MemoryLayout<Frame>.size, 136)
        XCTAssertEqual(MemoryLayout<Frame>.stride, 136)
    }
}
