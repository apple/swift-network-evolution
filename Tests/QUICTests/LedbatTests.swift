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
final class LedbatTests: XCTestCase {
    var rtt: RTT!
    let mss = Constants.initialMSS
    var ledbat: Ledbat!
    let defaultCongestionWindow = UInt64(2400)

    override func setUp() {
        let logPrefixer = LogPrefixer("[LedbatTests]")
        ledbat = Ledbat(mss: mss, logPrefixer: logPrefixer)
        rtt = RTT(logPrefixer: logPrefixer)
        rtt.baseRTT = .milliseconds(100)
    }

    func testLedbatMSS() {
        /* Test MSS > congestion window */
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        ledbat.mssChanged(mss: 65000)
        XCTAssertEqual(ledbat.availableCongestionWindow, 65000)
        ledbat.reset(mss: Constants.initialMSS)
        /* Test MSS < congestion window */
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        ledbat.mssChanged(mss: 10)
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        ledbat.reset(mss: Constants.initialMSS)
    }

    func testLedbatReset() {
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        /* SRTT = 100ms, Current RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)

        let time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2900)
        ledbat.reset(mss: Constants.initialMSS)
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
    }

    func testLedbatLostPackets() {
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        /* SRTT = 100ms, Current RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)

        let time = NetworkClock.Instant.testBase
        /* Send to increase cwnd */
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 4400)
        /* Send a packet and declare them lost */
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(ledbat.availableCongestionWindow, 2400)
        /* See if we can send another packet */
        XCTAssertTrue(ledbat.canSend(packetLength: 1000))
    }

    func testLedbatSlowStart() {
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        /* SRTT = 100ms, Current RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        /* Send some packets to increase cwnd */

        var time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 4900)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(ledbat.availableCongestionWindow, 2450)
        /* Additive increase during CA */
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2939)
        /* Mulitplicative decrease during CA */
        /* Current RTT = 180ms */
        rtt.adjustedRTT = .milliseconds(180)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2606)
    }

    func testLedbatECN() {
        /* SRTT = 100ms, Current RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)

        /* Lets increase the window first to go higher than MIN_CWND */
        var time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 5400)

        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.processECN(
            ceCount: 1,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2700)

        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(200))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* cwnd grows during congestion avoidance */
        XCTAssertEqual(ledbat.availableCongestionWindow, 2922)
    }

    func testLedbatECNEnterCWR() {
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        /* Lets increase the window first to go higher than MIN_CWND */
        var time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 5400)
        /* Test that CE counts will reduce cwnd, enter CWR and after that we don't decrease cwnd for 1RTT even we receive new CE counts */

        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.processECN(
            ceCount: 1,
            packetsAcked: 4,
            largestSentPN: 5,
            largestAckedPN: 3,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)

        /* allowed cwnd = cwnd - bytes_in_flight = 2700 - 2000 = 700 */
        XCTAssertEqual(ledbat.availableCongestionWindow, 700)

        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.processECN(
            ceCount: 2,
            packetsAcked: 6,
            largestSentPN: 5,
            largestAckedPN: 5,
            largestAckedSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* cwnd is same 2700, bytes in flight has reduced to 0 */
        XCTAssertEqual(ledbat.availableCongestionWindow, 2700)
    }

    func testLedbatAckDuringRecovery() {
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        /* "Send" some packets and declare one of them lost */
        var time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(100))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2650)
    }

    func testLedbatIdleTimeout() {
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        let time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 5400)
        ledbat.idleTimeout(mss: mss)
        XCTAssertEqual(ledbat.availableCongestionWindow, defaultCongestionWindow)
    }

    func testLedbatPersistentCongestion() {
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.persistentCongestion(mss: mss)
        XCTAssertEqual(ledbat.availableCongestionWindow, 0)
    }

    func testLedbatCongestionLimited() {
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        var time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(ledbat.availableCongestionWindow, 2400)
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(1000))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        time = NetworkClock.Instant.testBase.advanced(by: .microseconds(2000))
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        XCTAssertEqual(ledbat.availableCongestionWindow, 2400)
        XCTAssertFalse(ledbat.canSend(packetLength: 3000))
    }

    func testLedbatPacketDiscard() {
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetDiscarded(bytesSent: 1000)
        XCTAssertEqual(ledbat.bytesInFlight, 0)
    }

    func testLedbatSpuriousRetransmit() {
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        let time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2900)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.spuriousRetransmit()
        XCTAssertEqual(ledbat.availableCongestionWindow, 2900)
    }

    /* Tests that we can enter CA without any loss after idle period */
    func testLedbatCongestionAvoidance() {
        /* SRTT = 100ms, base RTT = 100ms network RTT = 120ms */
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        let time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.packetLost(
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: .microseconds(0),
            now: time
        )
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: true, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2400)
        ledbat.idleTimeout(mss: mss)
        XCTAssertEqual(ledbat.availableCongestionWindow, 2400)
        ledbat.packetSent(bytesSent: 1200)
        ledbat.packetSent(bytesSent: 1200)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1200, sentTime: time)
        ledbat.packetsAcked(bytesAcked: 1200, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        /* Enter CA */
        XCTAssertEqual(ledbat.availableCongestionWindow, 3000)
        for _ in 0..<3 {
            ledbat.packetSent(bytesSent: 1000)
        }
        ledbat.ackBegin()
        for _ in 0..<3 {
            ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        }
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)
        XCTAssertEqual(ledbat.availableCongestionWindow, 3600)

    }

    func testLedbatDataTransferSnapshot() {
        var dataTransferSnapshot = DataTransferSnapshot()
        XCTAssertEqual(dataTransferSnapshot.transportCongestionWindow, 0)
        XCTAssertEqual(dataTransferSnapshot.transportSlowStartThreshold, 0)
        ledbat.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)

        XCTAssertTrue(dataTransferSnapshot.transportCongestionWindow > 0)
        XCTAssertTrue(dataTransferSnapshot.transportSlowStartThreshold > 0)
        rtt.adjustedRTT = .milliseconds(120)
        rtt.smoothedRTT = .milliseconds(100)
        let time = NetworkClock.Instant.testBase
        ledbat.packetSent(bytesSent: 1000)
        ledbat.ackBegin()
        ledbat.packetsAcked(bytesAcked: 1000, sentTime: time)
        ledbat.ackEnd(rtt: rtt, mss: mss, packetsLost: false, now: time)

        ledbat.filloutDataTransferSnapshot(dataTransferSnapshot: &dataTransferSnapshot)
        XCTAssertEqual(dataTransferSnapshot.transportCongestionWindow, 2900)
    }
}

#endif
