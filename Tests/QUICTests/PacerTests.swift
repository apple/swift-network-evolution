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
final class PacerTests: XCTestCase {

    var connection: QUICConnection!
    override func setUp() {
        connection = QUICConnection(context: NetworkContext.implicitContext)
    }

    override func tearDown() {
        // The connection was built directly rather than attached to a stack, so nothing else
        // hands its event state back.
        connection.context.onQueue { self.connection.destroyFromExternalTest() }
        connection = nil
    }

    func testGetSendTime() {
        var pacer = Pacer(enabled: true)
        pacer.rate = 1_000_000
        pacer.burstSize = 0

        let path = connection.context.onQueue {
            QUICTestPath.makeFromExternalTest(parent: self.connection)
        }
        defer { connection.context.onQueue { path.destroyFromExternalTest() } }

        let packetLength: UInt16 = 1000
        var sendTimeAbsolute = NetworkClock.Instant(nanoseconds: 0)
        var sendTimeContinuous = NetworkClock.Instant(nanoseconds: 0)

        let timeBefore = NetworkClock.Instant.systemNowAbsolute
        pacer.getSendTime(
            path: path,
            packetLength: packetLength,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )

        let timeAfter = NetworkClock.Instant.systemNowAbsolute

        XCTAssertGreaterThanOrEqual(
            pacer.packetSentTime,
            timeBefore,
            "packetSentTime should be greater than timerBefore"
        )
        XCTAssertLessThanOrEqual(
            pacer.packetSentTime,
            timeAfter,
            "packetSentTime should be less than timeAfter"
        )
        XCTAssertEqual(
            pacer.currentSize,
            UInt32(packetLength),
            "currentSize should be set to packet length"
        )
        XCTAssertEqual(
            sendTimeAbsolute,
            pacer.packetSentTime,
            "sendTimeAbsolute should match packetSentTime"
        )

        let previousPacketSentTime = pacer.packetSentTime
        let previousCurrentSize = pacer.currentSize
        pacer.setBurstSize(burstSize: 2000)
        pacer.getSendTime(
            path: path,
            packetLength: packetLength,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        XCTAssertEqual(
            pacer.currentSize,
            previousCurrentSize + UInt32(packetLength),
            "currentSize should get incremented"
        )
        XCTAssertEqual(
            pacer.packetSentTime,
            previousPacketSentTime,
            "packetSentTime should not change"
        )

        // Send again now that currentSize >= burstSize
        pacer.getSendTime(
            path: path,
            packetLength: packetLength,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        XCTAssertEqual(
            pacer.currentSize,
            UInt32(packetLength),
            "currentSize should equal packetLength"
        )
        XCTAssertGreaterThanOrEqual(
            pacer.packetSentTime,
            previousPacketSentTime,
            "packetSentTime should have a pacing interval"
        )
    }

    func testPacerBurstLimit() {

        let path = connection.context.onQueue {
            QUICTestPath.makeFromExternalTest(parent: self.connection)
        }
        defer { connection.context.onQueue { path.destroyFromExternalTest() } }
        path.pacePackets = true
        path.set(interface: nil, priority: 1, isInitial: true)
        // startupRate is 10 Mbps, this will affect the pacing time
        path.pacer.setInitialState(10_000_000, 10000)
        path.pacer.reset()
        var sendTimeAbsolute = NetworkClock.Instant(nanoseconds: 0)
        var sendTimeContinuous = NetworkClock.Instant(nanoseconds: 0)
        path.pacer.getSendTime(
            path: path,
            packetLength: 1500,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        let currentTime = NetworkClock.Instant.systemNow
        // First packet should be sent out almost immediately
        XCTAssertTrue(
            sendTimeAbsolute <= (currentTime + NetworkClock.Instant(nanoseconds: 1_000_000).time)
        )

        let previousAbsoluteTime = sendTimeAbsolute
        // Should not have reached the burst size yet, absolute times should match
        path.pacer.getSendTime(
            path: path,
            packetLength: 1500,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        XCTAssertEqual(sendTimeAbsolute, previousAbsoluteTime)
        // Invoke the burst behavior
        let initialBurstAbsoluteTime = sendTimeAbsolute
        for _ in 0..<6 {
            path.pacer.getSendTime(
                path: path,
                packetLength: 1500,
                sendTimeAbsolute: &sendTimeAbsolute,
                sendTimeContinuous: &sendTimeContinuous
            )
        }
        let timeDifference = sendTimeAbsolute - initialBurstAbsoluteTime
        // We should see a pacing time less than maxBurstIntervalKernelPacing (Should be around 1-2ms)
        XCTAssertTrue(
            timeDifference.milliseconds <= Constants.maxBurstIntervalKernelPacing.milliseconds
        )
    }
}

#endif
