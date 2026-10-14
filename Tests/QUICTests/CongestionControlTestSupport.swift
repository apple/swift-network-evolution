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

/// Helpers that drive a congestion controller directly, with no path to pace.
@available(Network 0.1.0, *)
extension CongestionControlProtocol {
    /// Sends `packets` 1000-byte packets and acknowledges all of them in one ACK.
    mutating func exchange(
        state: inout CongestionControlState,
        rtt: borrowing RTT,
        mss: Int,
        packets: Int,
        sentTime: NetworkClock.Instant,
        ackTime: NetworkClock.Instant
    ) {
        for _ in 0..<packets {
            packetSent(state: &state, bytesSent: 1000)
        }
        ackBegin(state: &state)
        for _ in 0..<packets {
            packetsAcked(state: &state, bytesAcked: 1000, sentTime: sentTime)
        }
        ackEnd(state: &state, rtt: rtt, path: nil, mss: mss, packetsLost: false, now: ackTime, qlog: nil)
    }

    /// Sends one 1000-byte packet, declares it lost, and then undoes the loss as spurious.
    ///
    /// Fails the calling test if the loss doesn't reduce the congestion window.
    mutating func spuriousLoss(
        state: inout CongestionControlState,
        rtt: borrowing RTT,
        mss: Int,
        sentTime: NetworkClock.Instant,
        now: NetworkClock.Instant,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        packetSent(state: &state, bytesSent: 1000)
        let window = state.congestionWindow
        ackBegin(state: &state)
        let reduced = packetLost(
            state: &state,
            path: nil,
            bytesLost: 1000,
            largestLostSentTime: sentTime,
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            now: now,
            qlog: nil
        )
        XCTAssertTrue(reduced, "the loss should open a recovery period", file: file, line: line)
        ackEnd(state: &state, rtt: rtt, path: nil, mss: mss, packetsLost: true, now: now, qlog: nil)
        XCTAssertLessThan(state.congestionWindow, window, file: file, line: line)
        spuriousRetransmit(state: &state, qlog: nil)
    }
}

#endif
