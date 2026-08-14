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
final class SwiftNetworkTransportParametersTests: XCTestCase {
    func testParameterTypesHaveContiguousIndices() {
        // Each value should contribute a unique index, the order doesn't matter. Check
        // against 'allCases' as that's guaranteed to have one unique index per element.
        let indices = TransportParameterTypes.allCases.map { $0.index }.sorted()
        XCTAssertEqual(Array(TransportParameterTypes.allCases.indices), indices)
    }
}
