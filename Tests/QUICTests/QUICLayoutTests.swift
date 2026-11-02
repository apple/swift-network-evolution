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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class QUICLayoutTests: XCTestCase {

    var connection = NetworkContext.implicitContext.onQueue {
        QUICConnection(context: NetworkContext.implicitContext)
    }

    override func tearDown() {
        // The connection was built outside a protocol stack, so nothing else hands its event state back.
        connection.context.onQueue {
            self.connection.destroyFromExternalTest()
        }
    }

    func testLayoutPacket() {
        let packetSize = 156
        let packetRecordSize = 209
        XCTAssertEqual(packetSize, MemoryLayout<Packet>.size)
        XCTAssertEqual(packetRecordSize, MemoryLayout<SentPacketRecord>.size)
    }

    func testlayoutFrameAck() {
        let frameAckSize = 56
        XCTAssertEqual(frameAckSize, MemoryLayout<FrameAck>.size)
    }

    func testStreamLayout() {
        // Note that stream size can have a major impact memory usage in server use cases
        // Streams are stored inline in the connection's flow table rather than allocated one by one,
        // so the size of the type is what each stream costs.
        XCTAssertLessThanOrEqual(
            MemoryLayout<QUICStreamInstance>.stride,
            496,
            "QUICStreamInstance's size regressed past 496"
        )
        XCTAssertEqual(MemoryLayout<QUICSendState>.size, 81)
        XCTAssertEqual(MemoryLayout<QUICReceiveState>.size, 90)
        XCTAssertEqual(MemoryLayout<StreamSendBuffer>.size, 80)
        XCTAssertEqual(MemoryLayout<StreamSendBuffer.Cursor>.size, 21)
        XCTAssertEqual(MemoryLayout<ReassemblyQueue>.size, 89)
        XCTAssertEqual(MemoryLayout<FlowControlState>.size, 72)
        XCTAssertEqual(MemoryLayout<FlowControlStreamState>.size, 24)
    }

}
#endif
