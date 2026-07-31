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
final class QUICLayoutTests: XCTestCase {

    func testLayoutPacket() {
        let packetSize = 156
        let packetRecordSize = 201
        XCTAssertEqual(packetSize, MemoryLayout<Packet>.size)
        XCTAssertEqual(packetRecordSize, MemoryLayout<SentPacketRecord>.size)
    }

}
#endif
