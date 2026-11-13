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

// Swift QUIC's padding and chaff. The settings are in TrafficAnalysisDefenses.swift.

#if !NETWORK_NO_SWIFT_QUIC && !NETWORK_EMBEDDED

// MARK: - Connection state

/// Padding and chaff state for one connection.
///
/// Padding applies to ack-eliciting application data packets, except PMTUD probes. Sizes are of
/// the whole QUIC packet.
///
/// Chaff is a PING, padded like other packets, or to full size if no padding is specified. It is sent after
/// an idle interval, while nothing else is waiting to be sent.
///
/// This type only decides; `QUICConnection` acts, which avoids exclusive-access violations.
@available(Network 0.1.0, *)
struct TrafficAnalysisState: ~Copyable {
    enum ChaffAction {
        case reschedule(NetworkDuration)
        case send
        case stop
    }

    private(set) var padding: TrafficAnalysisDefenses.Padding? = nil
    private(set) var chaff: TrafficAnalysisDefenses.Chaff? = nil
    var chaffTimerID: Timer.TimerID?
    // When the last application data packet was sent, or the connection connected.
    private var lastPacketSentTimestamp: NetworkClock.Instant = .zero
    private var chaffDelay: NetworkDuration = .zero
    private(set) var consecutiveChaffSent = 0
    // Chaff stopped after its maximum; the next real packet starts it again.
    private var isChaffStopped = false

    // Stored, so that the send path checks a flag for each packet.
    private(set) var isPaddingEnabled = false
    private(set) var isChaffEnabled = false

    mutating func configure(_ defenses: TrafficAnalysisDefenses) {
        padding = defenses.padding
        chaff = defenses.chaff
        isPaddingEnabled = padding != nil
        isChaffEnabled = chaff != nil
    }

    // MARK: Padding

    /// The padding for one packet. None for PMTUD probes, or for a server before it has validated
    /// the client's address.
    func padding(
        for packetNumberSpace: PacketNumberSpace,
        isPMTUDProbe: Bool,
        isUnvalidatedServer: Bool
    ) -> TrafficAnalysisDefenses.Padding? {
        guard packetNumberSpace == .applicationData, !isPMTUDProbe, !isUnvalidatedServer else { return nil }
        return padding
    }

    // MARK: Chaff

    /// Called once connected. Returns the delay before the first chaff, or nil without chaff.
    mutating func startChaff(now: NetworkClock.Instant) -> NetworkDuration? {
        guard let chaff else { return nil }
        lastPacketSentTimestamp = now
        chaffDelay = chaff.nextDelay
        return chaffDelay
    }

    /// Records an application data packet being sent. Returns a timer delay if real activity
    /// restarts stopped chaff.
    ///
    /// Real activity is a packet with an ACK-eliciting frame other than PING. ACKs are not, or ACKs
    /// of the peer's chaff would keep chaff going on both ends.
    ///
    /// Chaff is counted here, when it is sent, as a deferred send leaves the PING pending.
    mutating func notePacketSent(isActivity: Bool, carriesChaff: Bool, now: NetworkClock.Instant) -> NetworkDuration? {
        lastPacketSentTimestamp = now
        guard isActivity else {
            if carriesChaff {
                consecutiveChaffSent += 1
            }
            return nil
        }
        consecutiveChaffSent = 0
        guard _slowPath(isChaffStopped), let chaff else { return nil }
        isChaffStopped = false
        chaffDelay = chaff.nextDelay
        return chaffDelay
    }

    mutating func chaffTimerFired(
        now: NetworkClock.Instant,
        isSendPending: Bool,
        totalPacketsSent: Int
    ) -> ChaffAction {
        guard let chaff else { return .stop }

        // A packet sent since the timer was armed pushes chaff back. Allow 1 ms, as timers fire early.
        let quiet = now > lastPacketSentTimestamp ? lastPacketSentTimestamp.duration(to: now) : .zero
        if quiet + .milliseconds(1) < chaffDelay {
            return .reschedule(chaffDelay - quiet)
        }

        // Wait while anything is pending, such as a chaff PING held by the congestion window.
        // It goes out once the window has room.
        if isSendPending {
            chaffDelay = chaff.nextDelay
            return .reschedule(chaffDelay)
        }

        if chaff.shouldStop(afterConsecutive: consecutiveChaffSent, totalPacketsSent: totalPacketsSent) {
            isChaffStopped = true
            return .stop
        }
        return .send
    }

    /// Queues a PING marked as chaff. Without the padding defense, the packet is padded to full size.
    func queueChaff(into pendingItems: inout PendingItems) {
        pendingItems.ping = true
        pendingItems.isChaff = true
        if padding == nil {
            pendingItems.paddingApproach = .padToEnd
        }
    }

    /// Called after trying to send chaff. Returns `.reschedule` or `.stop`.
    mutating func chaffSent(now: NetworkClock.Instant, totalPacketsSent: Int) -> ChaffAction {
        guard let chaff else { return .stop }
        lastPacketSentTimestamp = now
        if chaff.shouldStop(afterConsecutive: consecutiveChaffSent, totalPacketsSent: totalPacketsSent) {
            isChaffStopped = true
            return .stop
        }
        chaffDelay = chaff.nextDelay
        return .reschedule(chaffDelay)
    }
}

// MARK: - Chaff timer

@available(Network 0.1.0, *)
extension QUICConnection {
    /// Starts the chaff timer, if chaff is configured.
    func chaffStart(in eventContext: inout NetworkContext.EventContext) {
        guard trafficAnalysis.chaffTimerID == nil, let delay = trafficAnalysis.startChaff(now: self.now) else { return }
        trafficAnalysis.chaffTimerID = timer.insert(
            description: "chaff",
            fromNow: delay,
            timerNow: self.now,
            in: &eventContext
        ) { firedAt, timerState in
            self.chaffHandler(firedAt: firedAt, in: &timerState)
        }
        log.notice("Started chaff timer")
    }

    func chaffHandler(firedAt now: NetworkClock.Instant, in eventContext: inout NetworkContext.EventContext) {
        guard let chaffTimerID = trafficAnalysis.chaffTimerID, state == .connected else { return }
        let isSendPending = applicationPendingItems.hasPendingItems && !applicationPendingItems.isAckOnly
        var action = trafficAnalysis.chaffTimerFired(
            now: now,
            isSendPending: isSendPending,
            totalPacketsSent: stats[.txPackets]
        )
        if case .send = action {
            withPendingItems(for: .applicationData) { trafficAnalysis.queueChaff(into: &$0) }
            sendFrames(in: &eventContext)
            action = trafficAnalysis.chaffSent(now: now, totalPacketsSent: stats[.txPackets])
        }
        switch action {
        case .reschedule(let delay):
            timer.reschedule(identifier: chaffTimerID, fromNow: delay, timerNow: now, in: &eventContext)
        case .stop:
            // The timer is already disarmed, as it just fired.
            log.debug(
                "Chaff stopped: \(trafficAnalysis.consecutiveChaffSent) in a row, \(stats[.txPackets]) packets sent"
            )
        case .send:
            break
        }
    }
}

// MARK: - Send items

@available(Network 0.1.0, *)
extension PendingItems {
    /// Pads a packet of `packetLength` bytes toward the target, within the frame and the congestion window.
    mutating func writeTrafficAnalysisPadding(
        _ padding: TrafficAnalysisDefenses.Padding,
        into frame: inout Frame,
        packetLength: Int,
        availableCongestionWindow: UInt64,
        connection: QUICConnection,
        stats: inout Statistics,
        transmittedItems: inout TransmittedItems,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        var paddingCongestionWindow = availableCongestionWindow
        let paddingSize = min(
            padding.paddedLength(for: packetLength) - packetLength,
            frame.unclaimedLength,
            Int(clamping: paddingCongestionWindow)
        )
        guard paddingSize > 0 else { return }
        paddingApproach = .fixedSize(paddingSize)
        _ = try FramePadding.write(
            into: &frame,
            pendingItems: &self,
            connection: connection,
            availableCongestionWindow: &paddingCongestionWindow,
            stats: &stats,
            transmittedItems: &transmittedItems,
            shorthandFrames: &shorthandFrames
        )
    }
}

#endif
