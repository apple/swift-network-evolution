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
final class PragueTests: XCTestCase {

    var rtt: RTT!
    let mss = Constants.initialMSS
    var prague: Prague!
    var pacer: Pacer = Pacer(enabled: true)
    let defaultCongestionWindow = UInt64(12000)

    override func setUp() {
        let logPrefixer = LogPrefixer("[PragueTests]")
        prague = Prague(pacer: &pacer, mss: mss, logPrefixer: logPrefixer)
        rtt = RTT(logPrefixer: logPrefixer)
    }

    func testPragueMSS() {
        /* Test MSS > congestion window */
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        prague.mssChanged(mss: 65000)
        XCTAssertEqual(prague.availableCongestionWindow, 65000)
        prague.reset(mss: Constants.initialMSS)
        /* Test MSS < congestion window */
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        prague.mssChanged(mss: 10)
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        prague.reset(mss: Constants.initialMSS)
    }

    func testPragueReset() {
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        let time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 13000)
        prague.reset(mss: Constants.initialMSS)
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
    }

    func testPragueLostPackets() {
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        /* "Send" some packets and declare them lost */
        let time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(prague.availableCongestionWindow, 8400)
        /* See if we can send another packet */
        XCTAssertTrue(prague.canSend(packetLength: 1000))
    }

    func testPragueSlowStart() {
        rtt.smoothedRTT = .microseconds(10)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(prague.availableCongestionWindow, 11900)
        /* Make sure that another successful packet doesn't cause us to continue slow start */
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 11953)
    }

    func testPragueECN() {
        rtt.smoothedRTT = .milliseconds(15)
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        /* Test that CE counts will reduce the congestion window immediately and move Prague to Congestion avoidance */
        var time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.processECN(
            ceCount: 1,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        // cwnd after reduction = 6313 and after AI increase for 5 unmarked packets = 6826
        XCTAssertEqual(prague.availableCongestionWindow, 6826)

        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* congestion window grows during congestion avoidance */
        XCTAssertEqual(prague.availableCongestionWindow, 6924)
    }

    func testPragueECNEnterCWR() {
        rtt.smoothedRTT = .milliseconds(15)
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        /* Test that CE counts will reduce congestion window, enter CWR and after that we don't decrease congestion window for 1RTT even we receive new CE counts */
        let time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.processECN(
            ceCount: 1,
            packetsAcked: 4,
            largestSentPN: 5,
            largestAckedPN: 3,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        // cwnd after decrease = 6282, after AI increase = 6582
        // allowed cwnd = cwnd - bytes_in_flight = 6582 - 2000 = 4582
        XCTAssertEqual(prague.availableCongestionWindow, 4582)

        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.processECN(
            ceCount: 2,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        // cwnd is 6664 after AI for 1 unmarked packet
        XCTAssertEqual(prague.availableCongestionWindow, 6664)
    }

    func testPragueAckDuringRecovery() {
        rtt.smoothedRTT = .microseconds(10)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 8400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 8475)
    }

    func testPragueIdleTimeout() {
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
        let time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 18000)
        prague.idleTimeout(mss: mss)
        XCTAssertEqual(prague.availableCongestionWindow, defaultCongestionWindow)
    }

    func testPraguePersistentCongestion() {
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.persistentCongestion(mss: mss)
        XCTAssertEqual(prague.availableCongestionWindow, 0)
    }

    func testPragueCongestionLimited() {
        // See `CubicTests.testCubicCongestionLimited`: `sentTime` is when the packets went
        // out, `detectedAt` when their loss was noticed. The old test pushed the send times
        // ahead of the system clock, so every loss re-entered recovery. RFC 9002
        // Section 7.3.2 allows one reduction per recovery period; three rounds of sending
        // give three reductions.
        var sentTime = NetworkClock.Instant.testBase
        var detectedAt = sentTime.advanced(by: .microseconds(100))
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        XCTAssertEqual(prague.availableCongestionWindow, 8400)
        sentTime = sentTime.advanced(by: .microseconds(1000))
        detectedAt = sentTime.advanced(by: .microseconds(100))
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        sentTime = sentTime.advanced(by: .microseconds(1000))
        detectedAt = sentTime.advanced(by: .microseconds(100))
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        // One reduction per round, three rounds: 12000 -> 8400 -> 5880 -> 4116, each step
        // `UInt64(Double(window) * Prague.beta)`. Written out rather than as `pow(beta, 3)`, which
        // is 0.34299999999999997 and truncates to 4115; the reductions compound one at a time.
        XCTAssertEqual(prague.availableCongestionWindow, 4116)
        XCTAssertFalse(prague.canSend(packetLength: 10000))
    }

    func testPraguePacketDiscard() {
        prague.packetSent(bytesSent: 1000)
        prague.packetDiscarded(bytesSent: 1000)
        XCTAssertEqual(prague.bytesInFlight, 0)
    }

    func testPragueSpuriousRetransmit() {
        let time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        prague.spuriousRetransmit()
        XCTAssertEqual(prague.availableCongestionWindow, 9000)
    }

    /* Tests that we can enter CA without any loss after idle period */
    func testPragueCongestionAvoidance() {
        var time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 8400)
        prague.idleTimeout(mss: mss)
        XCTAssertEqual(prague.availableCongestionWindow, 8400)
        time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1200)
        prague.packetSent(bytesSent: 1200)
        prague.packetSent(bytesSent: 1200)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1200, sentTime: time)
        prague.packetsAcked(bytesAcked: 1200, sentTime: time)
        prague.packetsAcked(bytesAcked: 1200, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* Enter CA */
        XCTAssertEqual(prague.availableCongestionWindow, 12000)
        for _ in 0..<12 {
            prague.packetSent(bytesSent: 1000)
        }
        prague.ackBegin()
        for _ in 0..<12 {
            prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        }
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(prague.availableCongestionWindow, 13200)
    }

    func testPragueDataTransferSnapshot() {
        var dataTransferSnapshot = DataTransferSnapshot()
        XCTAssertEqual(dataTransferSnapshot.transportCongestionWindow, 0)
        XCTAssertEqual(dataTransferSnapshot.transportSlowStartThreshold, 0)
        prague.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)

        XCTAssertTrue(dataTransferSnapshot.transportCongestionWindow > 0)
        XCTAssertTrue(dataTransferSnapshot.transportSlowStartThreshold > 0)
        let existingCongestionWindow = dataTransferSnapshot.transportCongestionWindow
        let time = NetworkClock.Instant.testBase
        prague.packetSent(bytesSent: 1000)
        prague.packetSent(bytesSent: 1000)
        prague.ackBegin()
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(bytesAcked: 1000, sentTime: time)
        prague.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)

        prague.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        XCTAssertEqual(
            dataTransferSnapshot.transportCongestionWindow,
            (existingCongestionWindow + 2000)
        )
    }

    func testPragueExercisingPacer() {
        // Path holds both Pacer and Prague, thats why its setup this way.
        let connection = QUICConnection(context: NetworkContext.implicitContext)
        let path = QUICPath(parent: connection)
        path.pacePackets = true
        path.set(interface: nil, priority: 1, isInitial: true)
        // startupRate is 10 Mbps, this will affect the pacing time
        path.pacer.setInitialState(10_000_000, 10000)
        path.pacer.reset()

        XCTAssertEqual(path.pacer.rate, 10_000_000)
        XCTAssertEqual(path.pacer.burstSize, 10000)

        XCTAssertEqual(path.congestionControlWindow, 12000)
        let time = NetworkClock.Instant.testBase
        for _ in 0..<10 {
            path.congestionControlPacketsSent(bytesSent: 1000)
        }
        path.congestionControlAckBegin()
        for _ in 0..<10 {
            path.congestionControlPacketsAcked(bytesAcked: 1000, sentTime: time)
        }
        path.congestionControlAckEnd(rtt: rtt, path: path, mss: path.mss, packetsLost: false)
        XCTAssertEqual(path.congestionControlWindow, 22000)
    }
}

#endif
