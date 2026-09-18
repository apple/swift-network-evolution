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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkUniqueArrayTests: NetTestCase {

    func testArrayCapacity() {
        var elements = NetworkUniqueArray<UInt8>(minimumCapacity: 10)
        XCTAssertEqual(elements.count, 0)
        XCTAssertEqual(elements.capacity, 10)
        for i in 0..<12 {
            elements.append(UInt8(i))
        }
        XCTAssertEqual(elements.count, 12)
    }
}
#endif
