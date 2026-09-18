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
class ManagedConnectionIDTests: XCTestCase {
    func testInit() {
        let managedConnectionID = ManagedConnectionID(
            sequenceNumber: 1,
            connectionID: QUICConnectionID(5),
            token: QUICStatelessResetToken()
        )
        XCTAssertEqual(managedConnectionID.sequenceNumber, 1)
        XCTAssertEqual(managedConnectionID.connectionID.length, 5)
        XCTAssertFalse(managedConnectionID.used)
        XCTAssertFalse(managedConnectionID.preferredAddress)
    }
}

#endif
