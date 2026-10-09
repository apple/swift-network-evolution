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
final class PragueTests: XCTestCase {

    var rtt: RTT!
    let mss = Constants.initialMSS
    var prague: Prague!
    var state = CongestionControlState()
    // These tests drive the algorithm directly, with no path to pace.
    let noPath: QUICPath? = nil
    var pacer: Pacer = Pacer(enabled: true)
    let defaultCongestionWindow = UInt64(12000)

    override func setUp() {
        let logPrefixer = LogPrefixer("[PragueTests]")
        state = CongestionControlState()
        prague = Prague(state: &state, pacer: &pacer, mss: mss, logPrefixer: logPrefixer)
        rtt = RTT(logPrefixer: logPrefixer)
    }

    func testPragueMSS() {
        /* Test MSS > congestion window */
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        prague.mssChanged(state: &state, mss: 65000)
        XCTAssertEqual(state.availableCongestionWindow, 65000)
        prague.reset(state: &state, mss: Constants.initialMSS)
        /* Test MSS < congestion window */
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        prague.mssChanged(state: &state, mss: 10)
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        prague.reset(state: &state, mss: Constants.initialMSS)
    }

    func testPragueReset() {
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        let time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 13000)
        prague.reset(state: &state, mss: Constants.initialMSS)
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
    }

    func testPragueLostPackets() {
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        /* "Send" some packets and declare them lost */
        let time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(state.availableCongestionWindow, 8400)
        /* See if we can send another packet */
        XCTAssertTrue(prague.canSend(state: state, packetLength: 1000))
    }

    func testPragueSlowStart() {
        rtt.smoothedRTT = .microseconds(10)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(state.availableCongestionWindow, 11900)
        /* Make sure that another successful packet doesn't cause us to continue slow start */
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 11953)
    }

    func testPragueECN() {
        rtt.smoothedRTT = .milliseconds(15)
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        /* Test that CE counts will reduce the congestion window immediately and move Prague to Congestion avoidance */
        var time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.processECN(
            state: &state,
            path: noPath,
            ceCount: 1,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        // cwnd after reduction = 6313 and after AI increase for 5 unmarked packets = 6826
        XCTAssertEqual(state.availableCongestionWindow, 6826)

        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        /* congestion window grows during congestion avoidance */
        XCTAssertEqual(state.availableCongestionWindow, 6924)
    }

    func testPragueECNEnterCWR() {
        rtt.smoothedRTT = .milliseconds(15)
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        /* Test that CE counts will reduce congestion window, enter CWR and after that we don't decrease congestion window for 1RTT even we receive new CE counts */
        let time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.processECN(
            state: &state,
            path: noPath,
            ceCount: 1,
            packetsAcked: 4,
            largestSentPN: 5,
            largestAckedPN: 3,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        // cwnd after decrease = 6282, after AI increase = 6582
        // allowed cwnd = cwnd - bytes_in_flight = 6582 - 2000 = 4582
        XCTAssertEqual(state.availableCongestionWindow, 4582)

        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.processECN(
            state: &state,
            path: noPath,
            ceCount: 2,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        // cwnd is 6664 after AI for 1 unmarked packet
        XCTAssertEqual(state.availableCongestionWindow, 6664)
    }

    func testPragueAckDuringRecovery() {
        rtt.smoothedRTT = .microseconds(10)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 8400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 8475)
    }

    func testPragueIdleTimeout() {
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
        let time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 18000)
        prague.idleTimeout(state: &state, mss: mss)
        XCTAssertEqual(state.availableCongestionWindow, defaultCongestionWindow)
    }

    func testPraguePersistentCongestion() {
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.persistentCongestion(state: &state, mss: mss)
        XCTAssertEqual(state.availableCongestionWindow, 0)
    }

    func testPragueCongestionLimited() {
        // `sentTime` is when the packets went out, `detectedAt` when their loss was noticed.
        // RFC 9002 Section 7.3.2 allows one reduction per recovery period, so three rounds of
        // sending give three reductions.
        var sentTime = NetworkClock.Instant.testBase
        var detectedAt = sentTime.advanced(by: .microseconds(100))
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: sentTime)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: sentTime)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        XCTAssertEqual(state.availableCongestionWindow, 8400)
        sentTime = sentTime.advanced(by: .microseconds(1000))
        detectedAt = sentTime.advanced(by: .microseconds(100))
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        sentTime = sentTime.advanced(by: .microseconds(1000))
        detectedAt = sentTime.advanced(by: .microseconds(100))
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        // One reduction per round, three rounds: 12000 -> 8400 -> 5880 -> 4116, each step
        // `UInt64(Double(window) * Prague.beta)`. Written out rather than as `pow(beta, 3)`, which
        // is 0.34299999999999997 and truncates to 4115; the reductions compound one at a time.
        XCTAssertEqual(state.availableCongestionWindow, 4116)
        XCTAssertFalse(prague.canSend(state: state, packetLength: 10000))
    }

    func testPraguePacketDiscard() {
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetDiscarded(state: &state, bytesSent: 1000)
        XCTAssertEqual(state.bytesInFlight, 0)
    }

    func testPragueSpuriousRetransmit() {
        let time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        prague.spuriousRetransmit(state: &state)
        XCTAssertEqual(state.availableCongestionWindow, 9000)
    }

    /* Tests that we can enter CA without any loss after idle period */
    func testPragueCongestionAvoidance() {
        var time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetLost(
            state: &state,
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 8400)
        prague.idleTimeout(state: &state, mss: mss)
        XCTAssertEqual(state.availableCongestionWindow, 8400)
        time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1200)
        prague.packetSent(state: &state, bytesSent: 1200)
        prague.packetSent(state: &state, bytesSent: 1200)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1200, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1200, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1200, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        /* Enter CA */
        XCTAssertEqual(state.availableCongestionWindow, 12000)
        for _ in 0..<12 {
            prague.packetSent(state: &state, bytesSent: 1000)
        }
        prague.ackBegin(state: &state)
        for _ in 0..<12 {
            prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        }
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(state.availableCongestionWindow, 13200)
    }

    func testPragueDataTransferSnapshot() {
        var dataTransferSnapshot = DataTransferSnapshot()
        XCTAssertEqual(dataTransferSnapshot.transportCongestionWindow, 0)
        XCTAssertEqual(dataTransferSnapshot.transportSlowStartThreshold, 0)
        prague.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)

        XCTAssertTrue(dataTransferSnapshot.transportCongestionWindow > 0)
        XCTAssertTrue(dataTransferSnapshot.transportSlowStartThreshold > 0)
        let existingCongestionWindow = dataTransferSnapshot.transportCongestionWindow
        let time = NetworkClock.Instant.testBase
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.packetSent(state: &state, bytesSent: 1000)
        prague.ackBegin(state: &state)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.packetsAcked(state: &state, bytesAcked: 1000, sentTime: time)
        prague.ackEnd(state: &state, rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)

        prague.filloutDataTransferSnapshot(state: state, dataTransferSnapshot: &dataTransferSnapshot)
        XCTAssertEqual(
            dataTransferSnapshot.transportCongestionWindow,
            (existingCongestionWindow + 2000)
        )
    }

    func testPragueExercisingPacer() {
        // Path holds both Pacer and Prague, thats why its setup this way.
        let connection = QUICConnection(context: NetworkContext.implicitContext)
        defer { connection.context.onQueue { connection.destroyFromExternalTest() } }
        let path = connection.context.onQueue {
            QUICPath.makeFromExternalTest(parent: connection)
        }
        defer { connection.context.onQueue { path.destroyFromExternalTest() } }
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
