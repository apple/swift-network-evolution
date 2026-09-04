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
final class CubicTests: XCTestCase {

    var rtt: RTT!
    let mss = Constants.initialMSS
    var cubic: Cubic!
    var pacer: Pacer = Pacer(enabled: true)
    let defaultCongestionWindow = UInt64(12000)

    override func setUp() {
        let logPrefixer = LogPrefixer("[CubicTests]")
        cubic = Cubic(pacer: &pacer, mss: mss, logPrefixer: logPrefixer)
        rtt = RTT(logPrefixer: logPrefixer)
    }

    func testCubicMSS() {
        /* Test MSS > congestion window */
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        cubic.mssChanged(mss: 65000)
        XCTAssertEqual(cubic.availableCongestionWindow, 65000)
        cubic.reset(mss: Constants.initialMSS)
        /* Test MSS < congestion window */
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        cubic.mssChanged(mss: 10)
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        cubic.reset(mss: Constants.initialMSS)
    }

    func testCubicReset() {
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        let time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 13000)
        cubic.reset(mss: Constants.initialMSS)
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
    }

    func testCubicLostPackets() {
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        /* "Send" some packets and declare them lost */
        let time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
        /* See if we can send another packet */
        XCTAssertTrue(cubic.canSend(packetLength: 1000))
    }

    func testCubicSlowStart() {
        rtt.smoothedRTT = .microseconds(0)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(cubic.availableCongestionWindow, 11900)
        /* Make sure that another successful packet doesn't cause us to continue slow start */
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 11953)
    }

    func testCubicECN() {
        rtt.smoothedRTT = .microseconds(0)
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        /* Test that CE counts will reduce the congestion window immediately and move CUBIC to Congestion avoidance */
        var time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.processECN(
            ceCount: 1,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* congestion window grows during congestion avoidance */
        XCTAssertEqual(cubic.availableCongestionWindow, 8475)
    }

    func testCubicECNEnterCWR() {
        rtt.smoothedRTT = .microseconds(0)
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        /* Test that CE counts will reduce congestion window, enter congestion window recovery and after that we don't decrease congestion window for 1RTT even we receive new CE counts */
        var time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.processECN(
            ceCount: 1,
            packetsAcked: 4,
            largestSentPN: 5,
            largestAckedPN: 3,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        /* availableCongestionWindow = congestionWindow - bytesInFlight = 8400 - 2000 = 6400 */
        XCTAssertEqual(cubic.availableCongestionWindow, 6400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.processECN(
            ceCount: 2,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* congestion window is the same 8400, bytes in flight has reduced to 0 */
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
    }

    func testCubicAckDuringRecovery() {
        rtt.smoothedRTT = .microseconds(0)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 8475)
    }

    func testCubicIdleTimeout() {
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
        let time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 18000)
        cubic.idleTimeout(mss: mss)
        XCTAssertEqual(cubic.availableCongestionWindow, defaultCongestionWindow)
    }

    func testCubicPersistentCongestion() {
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.persistentCongestion(mss: mss)
        XCTAssertEqual(cubic.availableCongestionWindow, 0)
    }

    func testCubicCongestionLimited() {
        // `sentTime` is when the packets went out; `detectedAt` is when their loss was noticed,
        // which is necessarily later. Dating a send after the recovery period it is compared
        // against re-enters recovery on every loss instead of once per round.
        //
        // RFC 9002 Section 7.3.2 allows one reduction per recovery period, and Appendix B opens a
        // new period only for a packet sent after the current one started. Three rounds of sending
        // therefore give three reductions.
        var sentTime = NetworkClock.Instant.testBase
        var detectedAt = sentTime.advanced(by: .microseconds(100))
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: sentTime)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
        sentTime = sentTime.advanced(by: .microseconds(1000))
        detectedAt = sentTime.advanced(by: .microseconds(100))
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        sentTime = sentTime.advanced(by: .microseconds(1000))
        detectedAt = sentTime.advanced(by: .microseconds(100))
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: detectedAt
        )
        // One reduction per round, three rounds: 12000 -> 8400 -> 5880 -> 4116, each step
        // `UInt64(Double(window) * Cubic.beta)`. Written out rather than as `pow(beta, 3)`, which
        // is 0.34299999999999997 and truncates to 4115; the reductions compound one at a time.
        XCTAssertEqual(cubic.availableCongestionWindow, 4116)
        XCTAssertFalse(cubic.canSend(packetLength: 10000))
    }

    func testCubicPacketDiscard() {
        cubic.packetSent(bytesSent: 1000)
        cubic.packetDiscarded(bytesSent: 1000)
        XCTAssertEqual(cubic.bytesInFlight, 0)
    }

    func testCubicSpuriousRetransmit() {
        let time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        cubic.spuriousRetransmit()
        XCTAssertEqual(cubic.availableCongestionWindow, 9000)
    }

    /* Tests that we can enter CA without any loss after idle period */
    func testCubicCongestionAvoidance() {
        let time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
        cubic.idleTimeout(mss: mss)
        XCTAssertEqual(cubic.availableCongestionWindow, 8400)
        cubic.packetSent(bytesSent: 1200)
        cubic.packetSent(bytesSent: 1200)
        cubic.packetSent(bytesSent: 1200)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1200, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1200, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1200, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* Enter CA */
        XCTAssertEqual(cubic.availableCongestionWindow, 12000)
        for _ in 0..<12 {
            cubic.packetSent(bytesSent: 1000)
        }
        cubic.ackBegin()
        for _ in 0..<12 {
            cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        }
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(cubic.availableCongestionWindow, 13200)

    }

    func testCubicDataTransferSnapshot() {
        var dataTransferSnapshot = DataTransferSnapshot()
        XCTAssertEqual(dataTransferSnapshot.transportCongestionWindow, 0)
        XCTAssertEqual(dataTransferSnapshot.transportSlowStartThreshold, 0)
        cubic.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)

        XCTAssertTrue(dataTransferSnapshot.transportCongestionWindow > 0)
        XCTAssertTrue(dataTransferSnapshot.transportSlowStartThreshold > 0)
        let existingCongestionWindow = dataTransferSnapshot.transportCongestionWindow
        let time = NetworkClock.Instant.testBase
        cubic.packetSent(bytesSent: 1000)
        cubic.packetSent(bytesSent: 1000)
        cubic.ackBegin()
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        cubic.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)

        cubic.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        XCTAssertEqual(
            dataTransferSnapshot.transportCongestionWindow,
            (existingCongestionWindow + 2000)
        )
    }

    func testCubicExercisingPacer() {
        // Path holds both Pacer and Cubic, thats why its setup this way.
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
        let time = NetworkClock.Instant.now
        for _ in 0..<10 {
            path.congestionControlPacketsSent(bytesSent: 1000)
        }
        path.congestionControlAckBegin()
        for _ in 0..<10 {
            path.congestionControlPacketsAcked(bytesAcked: 1000, sentTime: time)
        }
        path.congestionControlAckEnd(rtt: rtt, path: path, mss: path.mss, packetsLost: false)
        XCTAssertEqual(path.congestionControlWindow, 22000)
        XCTAssertEqual(path.pacer.rate, 132132)

        var sendTimeAbsolute = NetworkClock.Instant(nanoseconds: 0)
        var sendTimeContinuous = NetworkClock.Instant(nanoseconds: 0)
        path.pacer.getSendTime(
            path: path,
            packetLength: 1500,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        let currentTime = NetworkClock.Instant.now
        // First packet should be sent out almost immediately
        XCTAssertTrue(
            sendTimeAbsolute
                <= (currentTime + NetworkClock.Instant(nanoseconds: 1_000_000).time)
        )
        // Next packet should be greater than the burst size because cubic has it set to 0
        let initialBurstAbsoluteTime = sendTimeAbsolute
        path.pacer.getSendTime(
            path: path,
            packetLength: 1500,
            sendTimeAbsolute: &sendTimeAbsolute,
            sendTimeContinuous: &sendTimeContinuous
        )
        let timeDifference = sendTimeAbsolute - initialBurstAbsoluteTime
        // This packet should get the default pacing rate of 10ms because the rate is low
        XCTAssertTrue(
            timeDifference.time.milliseconds
                == Constants.maxBurstIntervalKernelPacing.milliseconds
        )
    }

    /// A smoothed RTT that rounds to zero microseconds must not reach the pacing-rate division; it
    /// traps there.
    func testCubicPacerSurvivesASubMicrosecondSmoothedRTT() {
        let connection = QUICConnection(context: NetworkContext.implicitContext)
        let path = QUICPath(parent: connection)
        path.pacePackets = true
        path.set(interface: nil, priority: 1, isInitial: true)
        path.pacer.setInitialState(10_000_000, 10000)
        path.pacer.reset()

        rtt.smoothedRTT = .nanoseconds(400)

        // double-check that the rounding happens as expected
        XCTAssertEqual(rtt.smoothedRTT.microseconds, 0, "smoothedRTT is expected to round to zero microseconds")

        let time = NetworkClock.Instant.now
        path.congestionControlPacketsSent(bytesSent: 1000)
        path.congestionControlAckBegin()
        path.congestionControlPacketsAcked(bytesAcked: 1000, sentTime: time)
        path.congestionControlAckEnd(rtt: rtt, path: path, mss: path.mss, packetsLost: false)

        // Now that we haven't trapped, assert the rate is as expected. One packet
        // acked takes the window to 13000, slow start doubles it, and the 100ms fallback divides.
        XCTAssertEqual(path.pacer.rate, 26000 * System.Time.USEC_PER_SEC / 100_000)
    }
}

#endif
