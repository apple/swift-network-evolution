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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct PMTUDState: ~Copyable {
    static let minimumMTU = 1280
    static let maximumMTU = 9216

    // How long until we probe again after we concluded a round of probing.
    private static let defaultInterval: NetworkDuration = .seconds(600)

    // The number of probes lost before we stop probing.
    private static let maxProbeCount = 3

    // The number of PTOs that must occur before we reduce the MSS.
    private static let blackholeThreshold = 3

    // Packet number at the time of starting the current round of probing
    private var startPacketNumber: PacketNumber = 0

    // The maximum size we can send on the interface. This caps probing.
    private var maximumPathMTU = 0

    // The size of IP (v4 or v6) and UDP headers for the path.
    private var ipUDPHeaderSize = 0

    // The currently discovered PMTU for the path.
    private(set) var currentPathMTU = 0

    // The next largest size to probe.
    private var nextProbeMTU = 0

    // The most recent probe size sent.
    private var probedMTU = 0

    // The size of a probe that failed.
    private var packetTooBigMTU = 0

    private var failedProbeCount = 0

    private var interval = PMTUDState.defaultInterval

    var timerID: Timer.TimerID? = nil

    private var canProbe: Bool {
        get { flags.contains(.canProbe) }
        set {
            if newValue {
                flags.insert(.canProbe)
            } else {
                flags.remove(.canProbe)
            }
        }
    }

    var enabled: Bool {
        get { flags.contains(.enabled) }
        set {
            if newValue {
                flags.insert(.enabled)
            } else {
                flags.remove(.enabled)
            }
        }
    }

    private var searchCompleted: Bool {
        get { flags.contains(.searchCompleted) }
        set {
            if newValue {
                flags.insert(.searchCompleted)
            } else {
                flags.remove(.searchCompleted)
            }
        }
    }

    private var pendingTransmission: Bool {
        get { flags.contains(.pendingTransmission) }
        set {
            if newValue {
                flags.insert(.pendingTransmission)
            } else {
                flags.remove(.pendingTransmission)
            }
        }
    }

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let canProbe = Flags(rawValue: 1 << 0)
        static let enabled = Flags(rawValue: 1 << 1)
        static let searchCompleted = Flags(rawValue: 1 << 2)
        static let pendingTransmission = Flags(rawValue: 1 << 3)
    }
    private var flags = Flags()

    mutating func start(on path: QUICPath) {
        let connection = path.parentProtocol

        if timerID == nil {
            let pathID = path.identifier
            timerID = connection.timer.insert(description: "PMTUD") {
                let innerPath = connection.path(for: pathID)
                guard let innerPath else { return }
                innerPath.pmtudState.timerFired(timeNow: connection.now, path: innerPath)
            }
        }

        guard connection.allowPMTUD else { return }

        if let pmtudInterval = connection.pmtudInterval {
            self.interval = pmtudInterval
        }

        // Prefer interface MTU if set on path, otherwise get the general path MTU
        var interfaceMTU = path.interface?.mtu ?? 0
        if interfaceMTU == 0 {
            interfaceMTU = connection.pathPropertiesMTU
        }

        // Ensure the MTU is within bounds
        interfaceMTU = max(min(interfaceMTU, PMTUDState.maximumMTU), PMTUDState.minimumMTU)

        let isIPv4 = connection.initialAddressIsIPv4  // TODO: Handle preferred address migration

        self.enabled = true
        self.ipUDPHeaderSize =
            UDPProtocol.headerLength
            + (isIPv4 ? IPProtocol.ipv4HeaderLength : IPProtocol.ipv6HeaderLength)

        let maximumUDPPayloadSize = connection.remoteMaximumUDPPayloadSize
        self.maximumPathMTU = min(
            min(interfaceMTU, self.ipUDPHeaderSize + maximumUDPPayloadSize),
            PMTUDState.maximumMTU
        )
        self.currentPathMTU = path.mss + self.ipUDPHeaderSize

        self.startPacketNumber = connection.protector.getPacketNumber(for: .applicationData)

        searchCompleted = false

        let maximumPathMTU = self.maximumPathMTU
        let ipUDPHeaderSize = self.ipUDPHeaderSize
        let currentPathMTU = self.currentPathMTU
        path.log.debug(
            "PMTUD enabled, max PMTU: \(maximumPathMTU), IP/UDP header size: \(ipUDPHeaderSize), current PMTU: \(currentPathMTU)"
        )

        updateProbeSize(on: path)
        connection.recordSentPackets { sentPackets in
            sendProbe(on: path, sentPackets: &sentPackets)
        }
    }

    mutating func canSendProbe(on path: QUICPath) -> Bool {
        let connection = path.parentProtocol
        let hasPendingItems = connection.withPendingItemsForKeyState { pendingItems in
            pendingItems.hasPendingItems
        }
        return canSendProbe(on: path, hasPendingItems: hasPendingItems)
    }

    mutating func canSendProbe(on path: QUICPath, hasPendingItems: Bool) -> Bool {
        let connection = path.parentProtocol
        guard enabled, canProbe, !searchCompleted else {
            path.log.datapath("Not probing PMTUD, not in correct state")
            return false
        }

        guard connection.isHandshakeConfirmed else {
            path.log.datapath("Not probing PMTUD, handshake not confirmed yet")
            return false
        }

        guard connection.keyState.is1RTT else {
            path.log.datapath("Not probing PMTUD, wrong key state")
            return false
        }

        guard connection.protector.keysReady(for: connection.keyState) else {
            path.log.datapath("Not probing PMTUD, keys aren't ready")
            return false
        }

        guard !hasPendingItems else {
            path.log.datapath("Not probing PMTUD, already have pending items")
            return false
        }

        guard path.congestionControlCanSend(packetLength: nextProbeMTU - ipUDPHeaderSize) else {
            path.log.datapath("Not probing PMTUD, not allowed by congestion control")
            return false
        }

        guard path == connection.currentPath else {
            path.log.datapath("Not probing PMTUD, not the current path")
            return false
        }

        guard shouldProbe(on: path) else {
            path.log.datapath("Not probing PMTUD, high cost")
            return false
        }

        return true
    }

    mutating func packetTooBigReceived(on path: QUICPath, nextMTU: Int) {
        if !enabled {
            return
        }
        path.log.info("Received ICMP packet too big MTU: \(nextMTU)")
        if nextMTU < PMTUDState.minimumMTU {
            path.log.info("Ignore packet too big MTU < minimum MTU: \(PMTUDState.minimumMTU)")
        } else if nextMTU == currentPathMTU {
            path.log.info(
                "Finished searching: packet too big MTU == current MTU: \(currentPathMTU)"
            )
            searchComplete(on: path)
        } else if nextMTU > probedMTU {
            path.log.info("Ignore packet too big MTU > probed size: \(probedMTU)")
        } else if PMTUDState.minimumMTU <= nextMTU && nextMTU < currentPathMTU {
            path.log.info("Packet too big MTU < current path MTU \(currentPathMTU)")
            packetTooBigMTU = (packetTooBigMTU == 0) ? nextMTU : min(packetTooBigMTU, nextMTU)
            path.parentProtocol.recordSentPackets { sentPackets in
                enterBlackholeDetection(on: path, sentPackets: &sentPackets)
            }
        } else if currentPathMTU < nextMTU && nextMTU < probedMTU {
            path.log.info("Current path MTU < packet too big MTU size < probed MTU")
            packetTooBigMTU = (packetTooBigMTU == 0) ? nextMTU : min(packetTooBigMTU, nextMTU)
        }
    }

    mutating func probeAcked(on path: QUICPath, packetLen: Int, packetNumber: PacketNumber) {
        if packetNumber < startPacketNumber {
            let startPacketNumber = self.startPacketNumber
            path.log.debug(
                "Ignoring ACKed probe: pn \(packetNumber) < start pn \(startPacketNumber)"
            )
            return
        }

        let ackedMTU = packetLen + ipUDPHeaderSize
        guard enabled, !searchCompleted, ackedMTU >= probedMTU, ackedMTU >= currentPathMTU else {
            return
        }

        failedProbeCount = 0
        if ackedMTU >= PMTUDState.minimumMTU {
            currentPathMTU = ackedMTU
        }
        probedMTU = ackedMTU

        let connection = path.parentProtocol
        connection.setMSS(packetLen, on: path)
        path.log.info("Probe for MTU \(ackedMTU) acknowledged")

        // Ignore the previous packet-too-big if acked MTU is larger
        if ackedMTU > packetTooBigMTU {
            packetTooBigMTU = 0
        }

        if ackedMTU < maximumPathMTU {
            updateProbeSize(on: path)
        } else {
            path.log.debug("Finished searching, reached max MTU")
            searchComplete(on: path)
        }
    }

    mutating func probeLost(on path: QUICPath, packetLen: Int, packetNumber: PacketNumber) {
        if packetNumber < startPacketNumber {
            let startPacketNumber = self.startPacketNumber
            path.log.debug(
                "Ignoring lost probe: pn \(packetNumber) < start pn \(startPacketNumber)"
            )
            return
        }

        let lostMTU = packetLen + ipUDPHeaderSize
        guard lostMTU <= nextProbeMTU, !searchCompleted else {
            return
        }

        failedProbeCount += 1
        path.log.info("Lost probe for MTU \(lostMTU), probe count \(failedProbeCount)")
        if failedProbeCount == PMTUDState.maxProbeCount {
            path.log.info("Finished searching: reached maxProbeCount")
            searchComplete(on: path)
        } else {
            updateProbeSize(on: path)
        }
    }

    mutating func ptoEvent(
        on path: QUICPath,
        ptoCount: Int,
        sentPackets: inout NetworkUniqueDeque<SentPacketRecord>
    ) {
        guard !path.isFlowControlled,
            ptoCount > PMTUDState.blackholeThreshold,
            enabled
        else { return }
        enterBlackholeDetection(on: path, sentPackets: &sentPackets)
    }

    mutating func sendProbe(on path: QUICPath, sentPackets: inout NetworkUniqueDeque<SentPacketRecord>) {
        let connection = path.parentProtocol
        sendProbe(
            on: path,
            sentPackets: &sentPackets,
            initialPendingItems: &connection.initialPendingItems,
            handshakePendingItems: &connection.handshakePendingItems,
            applicationPendingItems: &connection.applicationPendingItems
        )
    }

    mutating func sendProbe(
        on path: QUICPath,
        sentPackets: inout NetworkUniqueDeque<SentPacketRecord>,
        initialPendingItems: inout PendingItems,
        handshakePendingItems: inout PendingItems,
        applicationPendingItems: inout PendingItems
    ) {
        pendingTransmission = false
        guard canSendProbe(on: path, hasPendingItems: applicationPendingItems.hasPendingItems) else {
            return
        }

        let connection = path.parentProtocol

        if packetTooBigMTU > 0 {
            updateProbeSize(on: path)
        }
        let probeMSS = (nextProbeMTU - ipUDPHeaderSize)

        applicationPendingItems.ping = true
        applicationPendingItems.pmtudProbeMSS = probeMSS
        applicationPendingItems.paddingApproach = .padToEnd

        // The probe is queued but not sent yet. A probe can be driven by the PMTUD
        // timer rather than by an application write, in which case nothing else
        // reports the connection active before the packet is transmitted.
        connection.checkConnectionIdle(unackedPacketCount: connection.ack.unackedPacketCount)

        var discardInitialRecoveryState = false
        let countBeforeSend = sentPackets.count
        connection.sendFramesFromRecovery(
            on: path,
            sentPackets: &sentPackets,
            initialPendingItems: &initialPendingItems,
            handshakePendingItems: &handshakePendingItems,
            applicationPendingItems: &applicationPendingItems,
            discardInitialRecoveryState: &discardInitialRecoveryState
        )
        guard sentPackets.count > countBeforeSend else {
            path.log.error("Failed to send PMTUD probe packet")
            return
        }

        path.log.info("Probe for MTU \(nextProbeMTU) sent")
        canProbe = false
        probedMTU = nextProbeMTU
    }

    mutating func stop(on path: QUICPath) {
        enabled = false
        if let timerID {
            path.parentProtocol.timer.remove(timerID)
            self.timerID = nil
        }
    }

    mutating func tryToSend(on path: QUICPath, sentPackets: inout NetworkUniqueDeque<SentPacketRecord>) {
        guard pendingTransmission else { return }
        sendProbe(on: path, sentPackets: &sentPackets)
    }

    mutating func timerFired(timeNow: NetworkClock.Instant, path: QUICPath) {
        path.log.debug("PMTUD timer fired")
        self.searchCompleted = false
        self.updateProbeSize(on: path)
        path.parentProtocol.recordSentPackets { sentPackets in
            sendProbe(on: path, sentPackets: &sentPackets)
        }
    }

    private mutating func enterBlackholeDetection(
        on path: QUICPath,
        sentPackets: inout NetworkUniqueDeque<SentPacketRecord>
    ) {
        guard enabled else { return }
        path.log.info("Entering blackhole detection, setting path MTU to \(PMTUDState.minimumMTU)")
        currentPathMTU = PMTUDState.minimumMTU
        searchCompleted = false
        failedProbeCount = 0

        let connection = path.parentProtocol
        let newMSS = PMTUDState.minimumMTU - ipUDPHeaderSize
        connection.setMSS(newMSS, on: path)

        // Turn off timer
        timerReschedule(.zero, connection: path.parentProtocol)

        // Reset probe size
        updateProbeSize(on: path)
        sendProbe(on: path, sentPackets: &sentPackets)
    }

    private func findNextMTU(mtu: Int, findLarger: Bool) -> Int {
        let mtuTable: [Int] = [
            9216, 1500, 1492, 1450, 1430, 1410,
            1390, 1370, 1350, 1300, 1280,
        ]

        let index = mtuTable.firstIndex { mtu >= $0 } ?? mtuTable.count

        if findLarger {
            if index == 0 {
                return 0
            } else {
                return mtuTable[index - 1]
            }
        } else {
            if index == mtuTable.count {
                return 0
            } else if mtu > mtuTable[index] {
                return mtuTable[index]
            } else {
                return mtuTable[index + 1]
            }
        }
    }

    private mutating func searchComplete(on path: QUICPath) {
        canProbe = false
        failedProbeCount = 0
        searchCompleted = true
        timerReschedule(self.interval, connection: path.parentProtocol)
        path.log.info("PMTUD completed, current MTU \(currentPathMTU)")
    }

    private mutating func shouldProbe(on path: QUICPath) -> Bool {
        let connection = path.parentProtocol
        if connection.pmtudIgnoreCost { return true }

        let checkLength = PMTUDState.maxProbeCount * (nextProbeMTU - ipUDPHeaderSize)
        guard path.congestionControlCanSend(packetLength: checkLength) else { return false }

        let sendQueueLength = Int(connection.flowControlState.pendingOutboundBytesToSend)
        let currentPacketsNeeded = sendQueueLength / currentPathMTU
        let nextPacketsNeeded = sendQueueLength / nextProbeMTU

        let tagSize = connection.protector.getTagSize(for: connection.keyState)
        let shortHeaderSize = Packet.shortHeaderBaseSize
        let totalHeaderSize =
            ipUDPHeaderSize + shortHeaderSize + Int(tagSize) + QUICConnectionID.maximumSize + 4

        // If the cost of sending the next probe can be amortized, probe
        if (currentPacketsNeeded - nextPacketsNeeded) * totalHeaderSize >= nextProbeMTU {
            return true
        }

        return false
    }

    private func timerReschedule(_ duration: NetworkDuration, connection: QUICConnection) {
        guard let timerID else { return }
        connection.timer.reschedule(
            identifier: timerID,
            fromNow: duration,
            timerNow: connection.now
        )
    }

    private mutating func updateProbeSize(on path: QUICPath) {
        if searchCompleted {
            Logger.proto.fault("Attempt to update probe size while search is completed")
            return
        }

        // If we have a unused ptb size use it as the next probe
        if packetTooBigMTU > 0 && packetTooBigMTU < probedMTU {
            path.log.info(
                "PMTUD: using ICMP packet too big MTU \(packetTooBigMTU) as next probe"
            )
            nextProbeMTU = packetTooBigMTU
            packetTooBigMTU = 0
        } else {
            // If last probe failed, try it again
            if failedProbeCount > 0 {
                path.log.info("Retry last PMTUD probe size \(nextProbeMTU)")
            } else {
                // Otherwise, probe for a larger size
                var nextProbeSize = findNextMTU(
                    mtu: currentPathMTU,
                    findLarger: true
                )
                if nextProbeSize > maximumPathMTU {
                    nextProbeSize = maximumPathMTU
                }
                nextProbeMTU = nextProbeSize
                path.log.info("Increase probe size to \(nextProbeMTU)")
            }
        }
        canProbe = true
        pendingTransmission = true
    }
}
#endif
