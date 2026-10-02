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

/// Tests the `CongestionControl` container: dispatch to the active controller, switching
/// between controllers, and resetting. The controllers themselves are covered by
/// `CubicTests`, `LedbatTests` and `PragueTests`.
@available(Network 0.1.0, *)
final class CongestionControlTests: XCTestCase {
    let mss = Constants.initialMSS
    let logPrefixer = LogPrefixer("[CongestionControlTests]")
    var pacer = Pacer(enabled: false)
    var rtt: RTT!
    // These tests drive the controllers directly, with no path to pace.
    let noPath: QUICPath? = nil

    let cubicInitialWindow = UInt64(12000)
    let ledbatInitialWindow = UInt64(2400)
    let pragueInitialWindow = UInt64(12000)

    override func setUp() {
        rtt = RTT(logPrefixer: logPrefixer)
        rtt.smoothedRTT = .microseconds(0)
        rtt.adjustedRTT = .milliseconds(100)
        rtt.baseRTT = .milliseconds(100)
    }

    private func makeCubic() -> CongestionControl {
        CongestionControl(algorithm: .cubic, pacer: &pacer, mss: mss, logPrefixer: logPrefixer)
    }

    private func switchTo(_ algorithm: CongestionControl.Algorithm, _ cc: inout CongestionControl) {
        cc.switchTo(algorithm, pacer: &pacer, mss: mss, qlog: nil, logPrefixer: logPrefixer)
    }

    private func slowStartThreshold(_ cc: CongestionControl) -> UInt64 {
        var snapshot = DataTransferSnapshot()
        cc.filloutDataTransferSnapshot(dataTransferSnapshot: &snapshot)
        return snapshot.transportSlowStartThreshold
    }

    /// Grows the window by sending and acknowledging `count` packets in slow start.
    private func growWindow(_ cc: inout CongestionControl, packets count: Int) {
        let time = NetworkClock.Instant.testBase
        for _ in 0..<count {
            cc.packetSent(bytesSent: 1000)
        }
        cc.ackBegin()
        for _ in 0..<count {
            cc.packetsAcked(bytesAcked: 1000, sentTime: time)
        }
        cc.ackEnd(rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
    }

    func testStartsAsCubic() {
        let cc = makeCubic()
        XCTAssertEqual(cc.algorithm, .cubic)
        XCTAssertEqual(cc.name, "CUBIC")
        XCTAssertEqual(cc.congestionWindow, cubicInitialWindow)
        XCTAssertEqual(cc.availableCongestionWindow, cubicInitialWindow)
        XCTAssertEqual(cc.bytesInFlight, 0)
        XCTAssertTrue(cc.canSend(packetLength: 1200))
    }

    func testStartsAsRequestedAlgorithm() {
        let ledbat = CongestionControl(algorithm: .ledbat, pacer: &pacer, mss: mss, logPrefixer: logPrefixer)
        XCTAssertEqual(ledbat.algorithm, .ledbat)
        XCTAssertEqual(ledbat.name, "LEDBAT")
        XCTAssertEqual(ledbat.congestionWindow, ledbatInitialWindow)
        XCTAssertEqual(ledbat.bytesInFlight, 0)

        let prague = CongestionControl(algorithm: .prague, pacer: &pacer, mss: mss, logPrefixer: logPrefixer)
        XCTAssertEqual(prague.algorithm, .prague)
        XCTAssertEqual(prague.name, "PRAGUE")
        XCTAssertEqual(prague.congestionWindow, pragueInitialWindow)
        XCTAssertEqual(prague.bytesInFlight, 0)
    }

    /// Every operation on the container must land on the active controller exactly as if it
    /// had been applied to that controller directly.
    func testDispatchMatchesCubicDriven() {
        var cc = makeCubic()
        var directPacer = Pacer(enabled: false)
        var cubic = Cubic(pacer: &directPacer, mss: mss, logPrefixer: logPrefixer)

        func check(_ step: String, line: UInt = #line) {
            XCTAssertEqual(cc.congestionWindow, cubic.congestionWindow, step, line: line)
            XCTAssertEqual(cc.bytesInFlight, cubic.bytesInFlight, step, line: line)
            XCTAssertEqual(cc.availableCongestionWindow, cubic.availableCongestionWindow, step, line: line)
            XCTAssertEqual(slowStartThreshold(cc), cubic.slowStartThreshold, step, line: line)
            XCTAssertEqual(
                cc.canSend(packetLength: 1200),
                cubic.canSend(packetLength: 1200),
                step,
                line: line
            )
        }

        var time = NetworkClock.Instant.testBase
        for _ in 0..<6 {
            cc.packetSent(bytesSent: 1000)
            cubic.packetSent(bytesSent: 1000)
        }
        check("packetSent")

        cc.ackBegin()
        cubic.ackBegin()
        for _ in 0..<4 {
            cc.packetsAcked(bytesAcked: 1000, sentTime: time)
            cubic.packetsAcked(bytesAcked: 1000, sentTime: time)
        }
        cc.ackEnd(rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        cubic.ackEnd(rtt: rtt, path: noPath, mss: mss, packetsLost: false, now: time)
        check("ack")

        time = time.advanced(by: .milliseconds(1))
        cc.processECN(
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
        cubic.processECN(
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
        check("processECN")
        XCTAssertLessThan(cc.congestionWindow, cubicInitialWindow + 4000, "ECN must reduce the window")

        cc.packetDiscarded(bytesSent: 1000)
        cubic.packetDiscarded(bytesSent: 1000)
        check("packetDiscarded")

        time = time.advanced(by: .milliseconds(1))
        let ccReduced = cc.packetsLost(
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        let cubicReduced = cubic.packetLost(
            path: noPath,
            bytesLost: 1000,
            largestLostSentTime: time,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: time
        )
        XCTAssertEqual(ccReduced, cubicReduced)
        check("packetsLost")

        cc.spuriousRetransmit()
        cubic.spuriousRetransmit()
        check("spuriousRetransmit")

        cc.persistentCongestion(mss: mss)
        cubic.persistentCongestion(mss: mss)
        check("persistentCongestion")

        cc.mssChanged(mss: 65000)
        cubic.mssChanged(mss: 65000)
        check("mssChanged")

        cc.idleTimeout(mss: mss)
        cubic.idleTimeout(mss: mss)
        check("idleTimeout")
    }

    func testSwitchCubicToLedbatAndBack() {
        var cc = makeCubic()
        for _ in 0..<3 {
            cc.packetSent(bytesSent: 1000)
        }

        switchTo(.ledbat, &cc)
        XCTAssertEqual(cc.algorithm, .ledbat)
        XCTAssertEqual(cc.name, "LEDBAT")
        XCTAssertEqual(cc.bytesInFlight, 3000)
        // LEDBAT takes the lower of its own initial window and the outgoing one.
        XCTAssertEqual(cc.congestionWindow, ledbatInitialWindow)

        switchTo(.cubic, &cc)
        XCTAssertEqual(cc.algorithm, .cubic)
        XCTAssertEqual(cc.bytesInFlight, 3000)
        // CUBIC takes the higher of the outgoing window and its own initial window.
        XCTAssertEqual(cc.congestionWindow, cubicInitialWindow)

        cc.ackBegin()
        for _ in 0..<3 {
            cc.packetsAcked(bytesAcked: 1000, sentTime: .testBase)
        }
        XCTAssertEqual(cc.bytesInFlight, 0)
    }

    func testSwitchKeepsLargerWindowForCubicAndPrague() {
        var cc = makeCubic()
        growWindow(&cc, packets: 8)
        let grownWindow = cc.congestionWindow
        XCTAssertGreaterThan(grownWindow, cubicInitialWindow)
        cc.packetSent(bytesSent: 1000)

        switchTo(.prague, &cc)
        XCTAssertEqual(cc.algorithm, .prague)
        XCTAssertEqual(cc.name, "PRAGUE")
        XCTAssertEqual(cc.bytesInFlight, 1000)
        XCTAssertEqual(cc.congestionWindow, max(grownWindow, pragueInitialWindow))

        switchTo(.ledbat, &cc)
        XCTAssertEqual(cc.bytesInFlight, 1000)
        XCTAssertEqual(cc.congestionWindow, ledbatInitialWindow)

        switchTo(.prague, &cc)
        XCTAssertEqual(cc.bytesInFlight, 1000)
        XCTAssertEqual(cc.congestionWindow, pragueInitialWindow)

        switchTo(.cubic, &cc)
        XCTAssertEqual(cc.bytesInFlight, 1000)
        XCTAssertEqual(cc.congestionWindow, cubicInitialWindow)
    }

    func testSwitchToActiveAlgorithmIsNoOp() {
        var cc = makeCubic()
        growWindow(&cc, packets: 4)
        cc.packetSent(bytesSent: 1000)
        let window = cc.congestionWindow
        let threshold = slowStartThreshold(cc)

        switchTo(.cubic, &cc)
        XCTAssertEqual(cc.algorithm, .cubic)
        XCTAssertEqual(cc.congestionWindow, window)
        XCTAssertEqual(cc.bytesInFlight, 1000)
        XCTAssertEqual(slowStartThreshold(cc), threshold)
    }

    func testResetRebuildsActiveController() {
        var cc = makeCubic()
        growWindow(&cc, packets: 4)
        XCTAssertGreaterThan(cc.congestionWindow, cubicInitialWindow)
        cc.reset(pacer: &pacer, mss: mss, qlog: nil, logPrefixer: logPrefixer)
        XCTAssertEqual(cc.algorithm, .cubic)
        XCTAssertEqual(cc.congestionWindow, cubicInitialWindow)

        switchTo(.ledbat, &cc)
        cc.packetSent(bytesSent: 1000)
        cc.reset(pacer: &pacer, mss: mss, qlog: nil, logPrefixer: logPrefixer)
        XCTAssertEqual(cc.algorithm, .ledbat)
        XCTAssertEqual(cc.congestionWindow, ledbatInitialWindow)
        XCTAssertEqual(cc.bytesInFlight, 0)
    }

    /// The retired controller's state must not survive into a later switch back to it.
    func testRetiredControllerStateIsDropped() {
        var cc = makeCubic()
        growWindow(&cc, packets: 8)
        switchTo(.ledbat, &cc)
        // Back on CUBIC, the window comes from the hand-off rule, not the retired CUBIC state.
        switchTo(.cubic, &cc)
        XCTAssertEqual(cc.congestionWindow, cubicInitialWindow)
        XCTAssertEqual(slowStartThreshold(cc), UInt64.max)
    }
}

#endif
