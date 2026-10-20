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

    var stream: QUICStreamInstance!
    var connection = QUICConnection(context: NetworkContext.implicitContext)

    override func setUp() {
        stream = QUICStreamInstance(parent: connection, inbound: false)
        stream.setup(
            streamID: QUICStreamID(0),
            logPrefixer: quicStreamTestsLogPrefixer
        )
    }

    override func tearDown() {
        // The stream and the connection were both built outside a protocol stack, so nothing
        // else hands their event states back. The stream's `deinit` is an external entry point
        // that acquires the event context, so release it on the queue too.
        connection.context.onQueue {
            self.stream.destroyFromExternalTest()
            self.stream = nil
            self.connection.destroyFromExternalTest()
        }
    }

    func testLayoutPacket() {
        let packetSize = 156
        let packetRecordSize = 232
        XCTAssertEqual(packetSize, MemoryLayout<Packet>.size)
        XCTAssertEqual(packetRecordSize, MemoryLayout<SentPacketRecord>.size)
    }

    func testlayoutFrameAck() {
        let frameAckSize = 88
        XCTAssertEqual(frameAckSize, MemoryLayout<FrameAck>.size)
    }

    func testStreamLayout() {
        // Note that stream size can have a major impact memory usage in server use cases
        #if !os(Android) && !os(Linux)
        let streamSize = malloc_size(Unmanaged.passUnretained(stream as AnyObject).toOpaque())
        XCTAssertEqual(streamSize, 512, "QUICStreamInstance's allocated size regressed back 512")
        #endif
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
