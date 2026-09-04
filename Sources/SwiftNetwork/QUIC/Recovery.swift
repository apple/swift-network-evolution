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
struct PacketContainerEntry: ~Copyable, NetworkComparable {
    var packet: SentPacketRecord
    var sentTime: NetworkClock.Instant
    var lostTime: NetworkClock.Instant = .zero
    var reducedCongestionWindow: Bool = false

    init(_ packet: consuming SentPacketRecord, sentTime: NetworkClock.Instant) {
        self.packet = packet
        self.sentTime = sentTime
    }

    static func < (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.packet.number.value < rhs.packet.number.value
    }
    static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.packet.number.value == rhs.packet.number.value
    }
}

@available(Network 0.1.0, *)
struct Recovery: ~Copyable, PrefixedLoggable, NonCopyableTimerUser {
    struct InnerState: ~Copyable, PrefixedLoggable {
        var log: LogPrefixer
        var ackElicitingPacketsInFlight = 0
        var timeOfLastSentAckElicitingPacket = NetworkClock.Instant.zero
        var largestSentPacketNumber = PacketNumber.none
        var largestAckedPNSentTime = NetworkClock.Instant.zero
        var lossTime = NetworkClock.Instant.zero
        var currentAckBitstring = AckBitstring()
        var prevAckBitstring = AckBitstring()
        var largerPacketCount = 0

        // Persistent Congestion Detection Variables
        var largestLostPacketNumber = PacketNumber.none
        var largestLostSentTime = NetworkClock.Instant.zero
        var smallestLostSentTime = NetworkClock.Instant.maximum

        // Non-ack Eliciting Packets
        var oldestNonAckElicitingSentTime = NetworkClock.Instant.zero

        // Number of packets acked that were sent with ECT after validation
        var totalEctAcked = 0

        // Reordering Thresholds.
        var packetThreshold = Constants.packetReorderThreshold
        var timeThreshold = Constants.timeReorderThreshold

        // Entries are always added in order of packet number (larger numbers appended to the end)
        var outstandingPackets = NetworkUniqueDeque<PacketContainerEntry>(minimumCapacity: 10)

        var hasOutstandingPackets: Bool {
            !outstandingPackets.isEmpty
        }

        mutating func iterateSentPacketEntries(_ access: (inout PacketContainerEntry) -> Bool) {
            let count = outstandingPackets.count
            for i in 0..<count {
                let shouldContinue = access(&outstandingPackets[i])
                if !shouldContinue { break }
            }
        }

        mutating func insertSentPacket(_ packet: consuming SentPacketRecord, sentTime: NetworkClock.Instant) {
            log.datapath("Adding \(packet.number) in space \(packet.numberSpace)")
            if packet.largerPacket {
                largerPacketCount += 1
            }
            outstandingPackets.append(PacketContainerEntry(packet, sentTime: sentTime))
        }

        /// Finds the index of `packetNumber` in `outstandingPackets`, or `nil`.
        ///
        /// Entries are sorted by packet number but sparse — acknowledged and
        /// retransmitted packets are removed from the middle — so index and packet
        /// number drift apart. The strict ordering still means packet numbers rise
        /// by at least one per slot, which lets the first and last entries bound
        /// the search window arithmetically before probing anything else:
        ///
        /// - from the front: `index <= frontIndex + (target - frontNumber)`
        /// - from the back:  `index >= backIndex - (backNumber - target)`
        ///
        /// When no packets have been dropped between the two ends, those bounds
        /// meet on the answer and no binary search runs at all. That covers the
        /// dominant case of acknowledgements arriving in ascending order. Any gaps
        /// only widen the window, so the binary search below stays a fallback
        /// rather than the common path.
        @_optimize(speed)
        func indexOfPacketNumber(_ packetNumber: PacketNumber) -> Int? {
            let entryCount = outstandingPackets.count
            guard entryCount > 0 else { return nil }

            let target = packetNumber.value

            // Front entry: the overwhelmingly common lookup, since packets are
            // acknowledged oldest-first.
            let frontNumber = outstandingPackets[0].packet.number.value
            if frontNumber == target { return 0 }
            if frontNumber > target { return nil }

            var right = entryCount - 1
            let backNumber = outstandingPackets[right].packet.number.value
            if backNumber == target { return right }
            if backNumber < target { return nil }

            // Both ends are strictly inside the range now, so narrow the window
            // using the density bounds described above.
            var left = 1
            let fromFront = target - frontNumber
            if fromFront < Int64(right) {
                right = Int(fromFront)
            }
            let fromBack = backNumber - target
            if fromBack < Int64(entryCount - 1 - left) {
                left = entryCount - 1 - Int(fromBack)
            }

            while left <= right {
                let middle = left + (right - left) / 2
                let middleNumber = outstandingPackets[middle].packet.number.value
                if middleNumber == target {
                    return middle
                } else if middleNumber < target {
                    left = middle + 1
                } else {
                    right = middle - 1
                }
            }
            return nil
        }

        @_optimize(speed)
        mutating func removeSentPacket(_ packetNumber: PacketNumber) -> PacketContainerEntry? {
            if let index = indexOfPacketNumber(packetNumber) {
                // `remove(at:)` is O(count) and runs the full gap-closing analysis
                // even when there is nothing to shift. Acknowledgements arrive
                // oldest-first, so the front case dominates; `removeFirst()` is
                // documented O(1) and just advances the head slot.
                let removedEntry =
                    index == 0
                    ? outstandingPackets.removeFirst()
                    : outstandingPackets.remove(at: index)
                if removedEntry.packet.largerPacket, largerPacketCount > 0 {
                    largerPacketCount -= 1
                }
                return removedEntry
            }
            return nil
        }

        func findSentPacketEntry<R>(index: Int, access: (borrowing PacketContainerEntry) -> R) -> R {
            access(outstandingPackets[index])
        }

        @discardableResult
        func findSentPacketEntry(
            packetNumber: PacketNumber,
            access: (borrowing PacketContainerEntry) -> Void
        ) -> Bool {
            guard let index = indexOfPacketNumber(packetNumber) else { return false }
            access(outstandingPackets[index])
            return true
        }

        mutating func modifySentPacketEntry(
            packetNumber: PacketNumber,
            access: (inout PacketContainerEntry) -> Void
        ) {
            guard let index = indexOfPacketNumber(packetNumber) else { return }
            access(&outstandingPackets[index])
        }

        mutating func reset(connection: QUICConnection?) {
            iterateSentPacketEntries { entry in
                guard entry.packet.isInFlightEligible, entry.lostTime == .zero else {
                    return true
                }

                let pathID = entry.packet.sentPath
                guard let path = connection?.path(for: pathID) else {
                    return true
                }

                let sentLength = entry.packet.totalLength
                connection?.log.datapath("Discarding packet of length \(sentLength)")
                path.congestionControlPacketDiscarded(bytesSent: sentLength, qlog: connection?.qLog)
                return true
            }
            outstandingPackets.removeAll()
            ackElicitingPacketsInFlight = 0
            timeOfLastSentAckElicitingPacket = .zero
            largestSentPacketNumber = PacketNumber.none
            largestAckedPNSentTime = .zero
            lossTime = .zero
            currentAckBitstring = AckBitstring()
            prevAckBitstring = AckBitstring()
            largerPacketCount = 0

            // Persistent Congestion Detection Variables.
            largestLostPacketNumber = PacketNumber.none
            largestLostSentTime = .zero
            smallestLostSentTime = .maximum

            // Non-ack Eliciting Packets.
            oldestNonAckElicitingSentTime = .zero

            // Number of packets acked that were sent with ECT after validation.
            totalEctAcked = 0

            // Reorder Threshold.
            packetThreshold = Constants.packetReorderThreshold
            timeThreshold = Constants.timeReorderThreshold
        }

        func notifyLossToPath(
            packetNumber: PacketNumber,
            pathID: MultiplexingPathIdentifier,
            bytesLost: Int,
            connection: QUICConnection
        ) -> Bool {
            guard let path = connection.path(for: pathID) else {
                return false
            }
            var reducedCongestionWindow: Bool = false
            log.datapath(
                "In-flight bytes declared lost on path \(pathID), largest lost packet \(largestLostPacketNumber) was sent at \(largestLostSentTime)"
            )
            reducedCongestionWindow = path.congestionControlPacketsLost(
                bytesLost: bytesLost,
                largestLostSentTime: largestLostSentTime,
                mss: path.mss,
                smoothedRTT: path.rtt.smoothedRTT
            )
            if reducedCongestionWindow {
                log.datapath(
                    "\(packetNumber) detected lost on path \(pathID) and caused congestion window reduction"
                )
            }
            return reducedCongestionWindow
        }

        mutating func updateCongestionOnPath(
            _ pathID: MultiplexingPathIdentifier,
            connection: QUICConnection
        ) {
            guard let path = connection.path(for: pathID) else {
                return
            }

            //
            // Collapse congestion window if in persistent congestion.
            //
            // RFC 9002 says:
            // "Since network congestion is not affected by packet
            // number spaces, persistent congestion SHOULD consider
            // packets sent across packet number spaces. A sender that
            // does not have state for all packet number spaces or an
            // implementation that cannot compare send times across
            // packet number spaces MAY use state for just the packet
            // number space that was acknowledged. This might result in
            // erroneously declaring persistent congestion, but it will
            // not lead to a failure to detect persistent congestion."
            //
            // It's not clear why it will not lead to a failure to detect
            // persistent congestion but one assumption is that other
            // limits (lack of decryption keys and anti-amplification)
            // imply that it will be unlikely that limited number of
            // packets sent during handshake will cause persistent
            // congestion. Due to this and due to historical reasons we
            // opted to continue tracking persistent congestion per-PN
            // space.
            //

            if Recovery.inPersistentCongestion(
                rtt: path.rtt,
                largestTime: largestLostSentTime,
                smallestTime: smallestLostSentTime
            ) {
                log.datapath(
                    "Persistent congestion detected on path \(path.identifier), setting congestion window to minimum"
                )
                path.congestionControlPersistentCongestion(mss: path.mss, qlog: nil)
                log.datapath(
                    "Congestion window of path \(path.identifier) is now \(path.congestionControlWindow)"
                )
                if path.pacer.enabled {
                    path.resetPacer()
                }
                // Reset the smallest lost sent time.
                smallestLostSentTime = NetworkClock.Instant.maximum
                // Endpoints SHOULD set the minRTT to the newest RTT sample after persistent congestion is established.
                path.rtt.minRTT = path.rtt.latestRTT
            }
        }

        mutating func declarePacketLost(
            _ lostPackets: [PacketIdentifier],
            connection: QUICConnection
        ) {
            // We assume that the packets are in packet-number order. Verify that
            // the sent time of each packet is after that of the earlier packet.
            var totalLength: Int = 0
            let lostPacketCount = lostPackets.count
            for lostPacketIndex in 0..<lostPacketCount {
                let isLastPacket = (lostPacketIndex == (lostPacketCount - 1))
                let lostPacketIdentifier = lostPackets[lostPacketIndex]
                var reducedCongestionWindow = false
                var smallestLostSentTime = self.smallestLostSentTime
                var largestLostSentTime = self.largestLostSentTime
                var largestLostPacketNumber = self.largestLostPacketNumber
                var pathID: MultiplexingPathIdentifier = .none

                findSentPacketEntry(packetNumber: lostPacketIdentifier.number) { entry in
                    if entry.packet.isInFlightEligible {
                        totalLength += entry.packet.totalLength
                    }

                    if entry.packet.isECNValidationPacket, let path = connection.path(for: entry.packet.sentPath) {
                        path.ecnState?.validationPacketLost()
                    }

                    if largestLostPacketNumber + 1 != entry.packet.number {
                        // Not a continuous loss, reset sent times.
                        smallestLostSentTime = entry.sentTime
                    } else {
                        smallestLostSentTime = min(
                            smallestLostSentTime,
                            entry.sentTime
                        )
                    }

                    if _slowPath(largestLostSentTime > entry.sentTime) {
                        connection.log.fault("Later packets should always be sent later")
                    }
                    largestLostSentTime = entry.sentTime
                    largestLostPacketNumber = entry.packet.number

                    if _slowPath(largestLostSentTime < smallestLostSentTime) {
                        connection.log.fault("Later packets should have later sent time")
                    }
                    Recovery.logPacketLost(
                        packet: entry.packet,
                        trigger: .reordering,
                        connection: connection
                    )

                    if isLastPacket {
                        reducedCongestionWindow = notifyLossToPath(
                            packetNumber: entry.packet.number,
                            pathID: entry.packet.sentPath,
                            bytesLost: totalLength,
                            connection: connection
                        )
                        pathID = entry.packet.sentPath
                    }
                }

                self.smallestLostSentTime = smallestLostSentTime
                self.largestLostSentTime = largestLostSentTime
                self.largestLostPacketNumber = largestLostPacketNumber

                if reducedCongestionWindow, let lastPacketIdentifier = lostPackets.last {
                    modifySentPacketEntry(packetNumber: lastPacketIdentifier.number) { entry in
                        entry.reducedCongestionWindow = true
                    }
                }

                updateCongestionOnPath(pathID, connection: connection)
            }
        }

        mutating func packetAcked(
            sentPath: QUICPath,
            sentEntry: borrowing PacketContainerEntry,
            connection: QUICConnection
        ) {
            if sentEntry.lostTime == .zero && sentEntry.packet.isInFlightEligible {
                if sentEntry.packet.isAckEliciting {
                    if ackElicitingPacketsInFlight > 0 {
                        ackElicitingPacketsInFlight -= 1
                    } else {
                        log.fault("Cannot decrement ackElicitingPacketsInFlight below zero")
                    }
                    let number = sentEntry.packet.number
                    log.datapath(
                        "Ack eliciting packet \(number) acked, decrementing ackElicitingPacketsInFlight to: \(ackElicitingPacketsInFlight)"
                    )

                    Recovery.logAckElicitingPacketsInFlight(
                        packetCount: ackElicitingPacketsInFlight,
                        connection: connection
                    )
                } else {
                    let number = sentEntry.packet.number

                    log.datapath("Non-Ack eliciting packet \(number) acked")
                }
                sentPath.congestionControlPacketsAcked(
                    bytesAcked: sentEntry.packet.isInFlightEligible ? sentEntry.packet.totalLength : 0,
                    sentTime: sentEntry.sentTime
                )
            }

            // Acknowledge the data sent with the packet
            connection.acknowledged(
                sentEntry.packet,
                packetNumber: sentEntry.packet.number,
                packetNumberSpace: sentEntry.packet.numberSpace,
                sentPath: sentPath
            )
        }

        mutating func spuriousLoss(
            packetNumber: PacketNumber,
            packetNumberSpace: PacketNumberSpace,
            packetSentTime: NetworkClock.Instant,
            ackedTime: NetworkClock.Instant,
            sRTT: NetworkDuration,
            latestRTT: NetworkDuration,
            path: QUICPath,
            connection: QUICConnection
        ) {
            if Recovery.adaptiveTimeThreshold {
                let timeNeeded = packetSentTime.duration(to: ackedTime)
                let maxRTT = max(latestRTT, sRTT)
                while maxRTT + (maxRTT >> timeThreshold) < timeNeeded
                    && timeThreshold > 2
                {
                    // This will ensure that time resilience is RTT + 1/4 RTT.
                    timeThreshold -= 1
                    log.datapath(
                        "Updated reorder time threshold to \(timeThreshold)"
                    )
                }
            }
            if Recovery.adaptivePacketThreshold {
                let largestAckedPacketNumber = connection.largestAckedPacketNumber(
                    space: packetNumberSpace
                )
                let newThreshold =
                    (largestAckedPacketNumber - packetNumber) + Int64(1)
                if packetThreshold < newThreshold
                    && newThreshold < Recovery.maxPacketReorderThreshold
                {
                    // Less than 20
                    packetThreshold = max(packetThreshold, newThreshold)
                    log.datapath(
                        "Updated reorder packet threshold to \(packetThreshold)"
                    )
                }
            }
        }

        private mutating func findNewlyAckedPackets(
            ackFrame: FrameAck,
            path: QUICPath
        ) -> AckBitstringSequence {
            var oldestSentPacketNumber: PacketNumber? = nil
            if !outstandingPackets.isEmpty {
                oldestSentPacketNumber = outstandingPackets[0].packet.number
            }
            guard let oldestSentPacketNumber else {
                log.datapath(
                    "No outstanding packets for number space \(ackFrame.packetNumberSpace)"
                )
                return AckBitstringSequence.empty
            }
            if oldestSentPacketNumber > ackFrame.largest {
                log.datapath(
                    "Oldest sent \(oldestSentPacketNumber) after largest acked \(ackFrame.largest), stopping"
                )
                return AckBitstringSequence.empty
            }
            precondition(oldestSentPacketNumber.isValid())
            currentAckBitstring.reinit(
                frame: ackFrame,
                oldestPN: oldestSentPacketNumber
            )

            return prevAckBitstring.xor(
                other: &currentAckBitstring,
                firstPN: oldestSentPacketNumber,
                lastPN: ackFrame.largest
            )
        }

        @inline(__always)
        mutating func findNewlyAckedPackets(
            ackFrame: FrameAck,
            path: QUICPath,
            now: NetworkClock.Instant,
            connection: QUICConnection
        ) -> Bool {
            let packetNumberSpace = ackFrame.packetNumberSpace
            var newlyECTAcked: UInt64 = 0

            let newlyAckedPacketNumbers = findNewlyAckedPackets(ackFrame: ackFrame, path: path)

            for newlyAckedPacketNumber in newlyAckedPacketNumbers {
                let ackedEntry = removeSentPacket(newlyAckedPacketNumber)
                guard let ackedEntry else { continue }

                // We should count all newly acked packets that were originally
                // sent with either ECT(0) or ECT(1).
                // Non-ack eliciting packets (ACK, PADDING, CONNECTION_CLOSE)
                // are currently only checked for congestion marks on them for
                // L4S
                if ackedEntry.packet.ectMarked, ackedEntry.packet.sentPath != .none {
                    newlyECTAcked += 1
                }

                guard let sentPath = connection.path(for: ackedEntry.packet.sentPath) else {
                    continue
                }

                if ackedEntry.lostTime != .zero {
                    let sRTT = sentPath.rtt.smoothedRTT
                    let latestRTT = sentPath.rtt.latestRTT
                    spuriousLoss(
                        packetNumber: ackedEntry.packet.number,
                        packetNumberSpace: packetNumberSpace,
                        packetSentTime: ackedEntry.sentTime,
                        ackedTime: now,
                        sRTT: sRTT,
                        latestRTT: latestRTT,
                        path: path,
                        connection: connection
                    )
                    if ackedEntry.reducedCongestionWindow {
                        path.congestionControlSpuriousRetransmit(qlog: connection.qLog)
                    }
                }

                packetAcked(
                    sentPath: sentPath,
                    sentEntry: ackedEntry,
                    connection: connection
                )
            }

            // Process ECN after packet_acked.
            // Update the total acked packets that were sent with ECT
            // for application pns
            var previousLargestAcked = PacketNumber.none
            totalEctAcked = Int(newlyECTAcked)

            let largestAckedPacketNumber = connection.largestAckedPacketNumber(
                space: packetNumberSpace
            )
            if largestAckedPacketNumber.value >= 0 {
                previousLargestAcked = largestAckedPacketNumber
            }

            let ceCount =
                path.ecnState?.validateAck(
                    ecn: connection.ecn,
                    frame: ackFrame,
                    previousLargestAcked: previousLargestAcked,
                    newlyAckedECNPackets: newlyECTAcked
                ) ?? 0
            connection.stats.increment(
                .ecnCapablePacketsAcknowledged,
                by: Int(newlyECTAcked)
            )
            connection.stats.increment(.ecnCapablePacketsMarked, by: ceCount)
            // Process ECN only after we reach capable
            if path.ecnState?.state == .capable {
                if packetNumberSpace == .applicationData {
                    log.fault("We got validated before applicationData")
                }
                // Process ECN only if there are any newly ACKed ECT packets
                if newlyECTAcked > 0 {
                    let sRTT = path.rtt.smoothedRTT
                    path.congestionControlProcessECN(
                        ceCount: ceCount,
                        packetsAcked: totalEctAcked,
                        largestSentPN: largestSentPacketNumber.value,
                        largestAckedPN: largestAckedPacketNumber.value,
                        largestAckedSentTime: largestAckedPNSentTime,
                        mss: path.mss,
                        smoothedRTT: sRTT
                    )
                }
            }
            swap(&prevAckBitstring, &currentAckBitstring)
            return true
        }

        @_optimize(speed)
        mutating func sentPacket(
            _ sentPacket: consuming SentPacketRecord,
            time: NetworkClock.Instant,
            connection: QUICConnection
        ) {
            guard let sentPath = connection.path(for: sentPacket.sentPath) else {
                log.fault("Sent packet with no valid path")
                return
            }
            let packetNumberSpace = sentPacket.numberSpace
            let packetNumber = sentPacket.number
            log.datapath("Loss recovery: sent \(packetNumberSpace) \(packetNumber)")

            guard largestSentPacketNumber == .none || packetNumber >= largestSentPacketNumber else {
                log.fault(
                    "Should not send \(packetNumber) after \(largestSentPacketNumber)"
                )
                return
            }

            largestSentPacketNumber = packetNumber
            if sentPacket.totalLength > sentPath.minimumMSS,
                sentPacket.totalLength <= sentPath.mss
            {
                sentPacket.largerPacket = true
            }
            // Remove old non-ack eliciting packets. Currently, non-ack eliciting packets are added only for L4S.
            if connection.isL4SEnabled {
                removeStalePackets(
                    packetNumberSpace: packetNumberSpace,
                    path: sentPath,
                    time: time
                )
            }
            // Save this sent packet in our list of transmitted packets.
            let isInFlightEligible = sentPacket.isInFlightEligible
            let isAckEliciting = sentPacket.isAckEliciting
            let sentLength = sentPacket.totalLength

            // Tracking all in-flight-eligible packets in recovery so their bytes
            // are counted in bytesInFlight and properly decremented on ACK or loss.
            // Non-in-flight packets (e.g. ACK-only) are skipped since they don't consume
            // congestion window. For L4S, we also track non-in-flight packets.
            guard isInFlightEligible || connection.isL4SEnabled else {
                return
            }
            insertSentPacket(
                sentPacket,
                sentTime: time
            )

            // By definition, any packet containing crypto or ack-eliciting frames counts for bytes in flight.
            if isInFlightEligible {
                if isAckEliciting {
                    timeOfLastSentAckElicitingPacket = time
                    ackElicitingPacketsInFlight += 1

                    log.datapath(
                        "Ack eliciting packet \(packetNumber) sent, incrementing ackElicitingPacketsInFlight to: \(ackElicitingPacketsInFlight)"
                    )

                } else {
                    log.datapath("Non-Ack eliciting packet \(packetNumber) sent")

                }
                sentPath.congestionControlPacketsSent(bytesSent: sentLength, qlog: connection.qLog)
                Recovery.logAckElicitingPacketsInFlight(
                    packetCount: ackElicitingPacketsInFlight,
                    connection: connection
                )
            }
        }

        func removeStalePackets(
            packetNumberSpace: PacketNumberSpace,
            path: QUICPath?,
            time: NetworkClock.Instant
        ) {
            // To be handled for L4S
        }

        @discardableResult
        mutating func recordSentPackets(
            _ packets: consuming NetworkUniqueDeque<SentPacketRecord>,
            connection: QUICConnection
        ) -> Bool {
            if packets.isEmpty {
                return false
            }

            while let packet = packets.popFirst() {
                sentPacket(packet, time: connection.now, connection: connection)
            }

            return true
        }
    }

    struct PathState: ~Copyable {
        var PTOCount: Int = 0
        var PTOPeriod: NetworkDuration = .zero
        var lossDelay: NetworkDuration = .zero

        func getMaxPTODrainTime(idleTimeout: NetworkDuration) -> NetworkDuration {
            // The closing and draining connection states exist to ensure that connections close cleanly
            // and that delayed or reordered packets are properly discarded. These states SHOULD persist
            // for at least three times the current PTO interval
            let ptoDrainPeriod = PTOPeriod * 3
            if ptoDrainPeriod < idleTimeout {
                return NetworkDuration.milliseconds(ptoDrainPeriod.milliseconds)
            } else {
                return idleTimeout
            }
        }
    }

    var log: LogPrefixer
    var connection: QUICConnection?
    private var initialInnerState: InnerState
    private var handshakeInnerState: InnerState
    private var applicationDataInnerState: InnerState
    var timerID: Timer.TimerID?
    var receivedHandshakeAck: Bool = false
    var received1RTTAck: Bool = false
    private(set) var computedTimeout: NetworkDuration = .zero

    static let adaptiveTimeThreshold: Bool = true
    static let adaptivePacketThreshold: Bool = true
    static let maxPacketReorderThreshold: Int64 = 20
    static let timerGranularity: NetworkDuration = .milliseconds(2)

    static let lossRecoveryBuckets: Int = 199
    static func lossRecoveryHash(pn: Int) -> Int {
        pn % Recovery.lossRecoveryBuckets
    }

    enum EarliestTimeType {
        case lossTime
        case lastSentAckElicitingTime
    }

    init(connection: QUICConnection? = nil, timerID: Timer.TimerID? = nil, logPrefixer: LogPrefixer) {
        self.connection = connection
        self.timerID = timerID
        self.log = logPrefixer
        self.initialInnerState = InnerState(log: log)
        self.handshakeInnerState = InnerState(log: log)
        self.applicationDataInnerState = InnerState(log: log)
    }

    fileprivate mutating func sentPacket(
        _ sentPacket: consuming SentPacketRecord,
        time: NetworkClock.Instant,
        connection: QUICConnection
    ) {
        let packetNumberSpace = sentPacket.numberSpace
        withMutableInnerState(packetNumberSpace: packetNumberSpace, packet: sentPacket) {
            innerState,
            sentPacket in
            innerState.sentPacket(sentPacket, time: time, connection: connection)
        }
    }

    private var inBatch = false
    private var shouldResetTimer = false

    mutating func startBatch() {
        inBatch = true
        shouldResetTimer = false
    }
    mutating func endBatch(connection: QUICConnection) {
        inBatch = false
        if shouldResetTimer {
            shouldResetTimer = false
            resetTimer(connection: connection)
        }
    }

    // Note: drains 'sentPackets', leaving the caller's storage empty and reusable.
    mutating func recordSentPackets(
        _ sentPackets: inout NetworkUniqueDeque<SentPacketRecord>,
        connection: QUICConnection
    ) {
        while let packet = sentPackets.popFirst() {
            sentPacket(packet, time: connection.now, connection: connection)
        }
        if inBatch {
            shouldResetTimer = true
        } else {
            resetTimer(connection: connection)
        }
    }

    func applyToAllInnerStatesImmutable(
        closure: (borrowing InnerState, PacketNumberSpace) -> Void
    ) {
        closure(initialInnerState, .initial)
        closure(handshakeInnerState, .handshake)
        closure(applicationDataInnerState, .applicationData)
    }

    mutating func applyToAllInnerStatesMutable(
        closure: (inout InnerState, PacketNumberSpace) -> Void
    ) {
        closure(&initialInnerState, .initial)
        closure(&handshakeInnerState, .handshake)
        closure(&applicationDataInnerState, .applicationData)
    }

    @discardableResult
    mutating func withMutableInnerState<R>(
        packetNumberSpace: PacketNumberSpace,
        closure: (inout InnerState) -> R
    ) -> R {
        switch packetNumberSpace {
        case .initial: return closure(&initialInnerState)
        case .handshake: return closure(&handshakeInnerState)
        case .applicationData: return closure(&applicationDataInnerState)
        }
    }

    @discardableResult
    mutating func withMutableInnerState<R>(
        packetNumberSpace: PacketNumberSpace,
        packet: consuming SentPacketRecord,
        closure: (inout InnerState, consuming SentPacketRecord) -> R
    ) -> R {
        switch packetNumberSpace {
        case .initial: return closure(&initialInnerState, packet)
        case .handshake: return closure(&handshakeInnerState, packet)
        case .applicationData: return closure(&applicationDataInnerState, packet)
        }
    }

    @discardableResult
    func withImmutableInnerState<R>(
        packetNumberSpace: PacketNumberSpace,
        closure: (_: borrowing InnerState) -> R
    ) -> R {
        switch packetNumberSpace {
        case .initial: return closure(initialInnerState)
        case .handshake: return closure(handshakeInnerState)
        case .applicationData: return closure(applicationDataInnerState)
        }
    }

    func getLargestAckedPN(packetNumberSpace: PacketNumberSpace) -> PacketNumber {
        connection?.largestAckedPacketNumber(space: packetNumberSpace) ?? .none
    }

    mutating func getLargestSentPN(packetNumberSpace: PacketNumberSpace) -> PacketNumber {
        withMutableInnerState(packetNumberSpace: packetNumberSpace) { innerState in
            innerState.largestSentPacketNumber
        }
    }

    static func logAckElicitingPacketsInFlight(packetCount: Int, connection: QUICConnection) {
        #if QlogOutput
        if let qLog = connection.qLog {
            qLog.congestionControlUpdated(packetsInFlight: UInt64(packetCount))
        }
        #endif
    }

    static func logPacketLost(
        packet: borrowing SentPacketRecord,
        trigger: QLogPacketLostTrigger,
        connection: QUICConnection
    ) {
        #if QlogOutput
        if let qLog = connection.qLog {
            qLog.packetLost(
                packet,
                trigger: trigger
            )
        }
        #endif
    }

    mutating func findLostPacketInner(
        pnSpace: PacketNumberSpace,
        timeNow: NetworkClock.Instant,
        connection: QUICConnection
    ) -> Bool {
        connection.applyToAllPaths { path in
            let maxRTT = max(path.rtt.latestRTT, path.rtt.smoothedRTT)
            let lossDelay = withImmutableInnerState(packetNumberSpace: pnSpace) {
                max(Recovery.timerGranularity, maxRTT + (maxRTT >> $0.timeThreshold))
            }
            path.recoveryState.lossDelay = lossDelay
        }
        connection.stats.increment(.retransmitTimeOut)

        var lostPacket = false
        var lostPackets: [PacketIdentifier] = []
        withMutableInnerState(packetNumberSpace: pnSpace) { innerState in

            var ackElicitingPacketsInFlight = innerState.ackElicitingPacketsInFlight
            let largestAckedPacketNumber = connection.largestAckedPacketNumber(space: pnSpace)
            let packetThreshold = innerState.packetThreshold
            var lossTime = NetworkClock.Instant.zero

            innerState.iterateSentPacketEntries { entry in
                let pn = entry.packet.number
                guard entry.lostTime == .zero,
                    pn <= largestAckedPacketNumber,
                    entry.sentTime <= timeNow
                else {
                    // Returning true continues looping
                    return true
                }

                var lostPacketSentTime: NetworkClock.Instant
                var pathLossDelay: NetworkDuration
                if let path = connection.path(for: entry.packet.sentPath) {
                    pathLossDelay = path.recoveryState.lossDelay
                    lostPacketSentTime = timeNow - pathLossDelay
                } else {
                    // We lost the path where this packet was
                    // last sent, so assume this packet was lost.
                    lostPacketSentTime = .maximum
                    pathLossDelay = .zero
                }
                if entry.sentTime <= lostPacketSentTime
                    || (largestAckedPacketNumber != PacketNumber.none
                        && largestAckedPacketNumber >= pn
                            + packetThreshold)
                {
                    connection.log.datapath(
                        "Declaring packet lost \(pn) in \(entry.packet.numberSpace), sent time \(entry.sentTime) <= \(lostPacketSentTime), or sent packet number \(largestAckedPacketNumber) >= \(pn + packetThreshold)"
                    )
                    connection.stats.increment(.txLostPackets)
                    connection.stats.increment(.txLostBytes, by: entry.packet.totalLength)
                    if entry.packet.ectMarked {
                        connection.stats.increment(.ecnCapablePacketsLost)
                    }
                    // Defer removing from sent_packet up to 1 RTT
                    // and set the lost time.
                    entry.lostTime = timeNow
                    if entry.packet.isAckEliciting {
                        if ackElicitingPacketsInFlight > 0 {
                            ackElicitingPacketsInFlight -= 1
                        } else {
                            connection.log.fault("Cannot decrement ackElicitingPacketsInFlight below zero")
                        }
                    }
                    lostPackets.append(entry.packet.identifier)
                    Recovery.logAckElicitingPacketsInFlight(
                        packetCount: ackElicitingPacketsInFlight,
                        connection: connection
                    )
                } else if lossTime == .zero {
                    lossTime = entry.sentTime + pathLossDelay
                    connection.log.datapath("Reset lossTime to \(lossTime)")
                } else {
                    // Stop looping
                    return false
                }

                // Continue looping
                return true
            }
            innerState.ackElicitingPacketsInFlight = ackElicitingPacketsInFlight
            innerState.lossTime = lossTime
        }

        if !lostPackets.isEmpty {
            log.datapath("Found \(lostPackets.count) lost packets")
            withMutableInnerState(packetNumberSpace: pnSpace) { innerState in
                innerState.declarePacketLost(lostPackets, connection: connection)
            }
            retransmitPackets(lostPackets, connection: connection)
            lostPacket = true
        }
        return lostPacket
    }

    mutating func retransmitPackets(
        _ lostPackets: [PacketIdentifier],
        connection: QUICConnection
    ) {
        for identifier in lostPackets {
            var discardInitialRecoveryState = false
            withMutableInnerState(packetNumberSpace: identifier.space) {
                innerState in
                guard let entry = innerState.removeSentPacket(identifier.number) else {
                    return
                }
                let sentPackets = connection.retransmitPacket(
                    entry.packet,
                    discardInitialRecoveryState: &discardInitialRecoveryState
                )
                innerState.recordSentPackets(sentPackets, connection: connection)
            }
            if discardInitialRecoveryState {
                self.resetPNSpace(packetNumberSpace: .initial, connection: connection)
                connection.withCurrentPath {
                    self.resetPTOCount(path: $0)
                }
            }
        }

        // We may have lost a PMTUD probe, so check if we want to resend it
        connection.withCurrentPath { path in
            var sentPackets = NetworkUniqueDeque<SentPacketRecord>()
            path.pmtudState.tryToSend(on: path, sentPackets: &sentPackets)
            recordSentPackets(&sentPackets, connection: connection)
            return
        }
    }

    @discardableResult
    mutating func findLostPacket(
        pnSpace: PacketNumberSpace? = nil,
        path: QUICPath? = nil,
        timeNow: NetworkClock.Instant = NetworkClock.Instant.now,
        connection: QUICConnection
    ) -> Bool {
        var packetLost = false
        if let pnSpace {
            packetLost = findLostPacketInner(
                pnSpace: pnSpace,
                timeNow: timeNow,
                connection: connection
            )
        } else {
            if findLostPacketInner(
                pnSpace: .initial,
                timeNow: timeNow,
                connection: connection
            ) {
                packetLost = true
            }
            if findLostPacketInner(
                pnSpace: .handshake,
                timeNow: timeNow,
                connection: connection
            ) {
                packetLost = true
            }
            if findLostPacketInner(
                pnSpace: .applicationData,
                timeNow: timeNow,
                connection: connection
            ) {
                packetLost = true
            }
        }
        if packetLost {
            // We may have lost a PMTUD probe, so check if we
            // want to resend it.
            let path = path ?? connection.currentPath
            if let path {
                var sentPackets = NetworkUniqueDeque<SentPacketRecord>()
                path.pmtudState.tryToSend(on: path, sentPackets: &sentPackets)
                recordSentPackets(&sentPackets, connection: connection)
            }
            connection.sendAllEnqueuedOutboundDatagrams()
        }
        return packetLost
    }

    mutating func removeLostPackets(ackedPath: QUICPath, now: NetworkClock.Instant) {
        applyToAllInnerStatesMutable { innerState, pnSpace in
            var index = 0
            while index < innerState.outstandingPackets.count {
                let packetNumber = innerState.outstandingPackets[index].packet.number
                let lostTime = innerState.outstandingPackets[index].lostTime
                let connection = ackedPath.parentProtocol
                let largestAckedPacketNumber = connection.largestAckedPacketNumber(space: pnSpace)
                if lostTime != .zero, packetNumber > largestAckedPacketNumber {
                    let lostDuration = lostTime.duration(to: now)
                    if lostDuration > ackedPath.rtt.smoothedRTT {
                        // Remove packet and don't increment index (so the next loop looks at the new value in this index)
                        if index == 0 {
                            // O(1), unlike the general remove(at:).
                            innerState.outstandingPackets.removeFirst()
                        } else {
                            innerState.outstandingPackets.remove(at: index)
                        }
                        continue
                    }
                }
                index += 1
            }
        }
    }

    func peerCompletedValidation(connection: QUICConnection) -> Bool {
        connection.isServer || connection.isHandshakeConfirmed || receivedHandshakeAck
            || received1RTTAck
    }

    func updateEarliestTime(
        innerState: borrowing InnerState,
        innerPNSpace: PacketNumberSpace,
        earliestTimeType: EarliestTimeType,
        handshakeCompleted: Bool,
        currentEarliestTime: NetworkClock.Instant
    ) -> (NetworkClock.Instant, PacketNumberSpace)? {
        let timeVar =
            earliestTimeType == .lossTime
            ? innerState.lossTime : innerState.timeOfLastSentAckElicitingPacket
        if innerPNSpace == .initial {
            return (timeVar, innerPNSpace)
        } else {
            if innerPNSpace == .applicationData && !handshakeCompleted {
                return nil
            }
            if timeVar != .zero, currentEarliestTime == .zero || timeVar < currentEarliestTime {
                return (timeVar, innerPNSpace)
            }
        }
        return nil
    }

    func getEarliestTime(
        earliestTimeType: EarliestTimeType,
        connection: QUICConnection
    ) -> (NetworkClock.Instant, PacketNumberSpace) {
        var earliestTime: NetworkClock.Instant = .zero
        var pnSpace: PacketNumberSpace = .initial
        let handshakeCompleted = connection.state == .connected
        applyToAllInnerStatesImmutable { innerState, packetNumberSpace in
            (earliestTime, pnSpace) =
                updateEarliestTime(
                    innerState: innerState,
                    innerPNSpace: packetNumberSpace,
                    earliestTimeType: earliestTimeType,
                    handshakeCompleted: handshakeCompleted,
                    currentEarliestTime: earliestTime
                ) ?? (earliestTime, pnSpace)
        }
        return (earliestTime, pnSpace)
    }

    func setTimer(delay: NetworkDuration, connection: QUICConnection) {
        guard let timerID = timerID else {
            return
        }
        connection.timer.reschedule(
            identifier: timerID,
            fromNow: delay,
            timerNow: connection.now
        )
        log.datapath("Reset loss recovery timer [T\(timerID)] to \(delay)")
    }

    func resetPTOCount(path: QUICPath) {
        path.recoveryState.PTOCount = 0
        log.datapath("PTO count reset to 0")
    }

    mutating func sendPTO(connection: QUICConnection, path: QUICPath) {
        var sentPTO = false

        var discardInitialRecoveryState = false
        applyToAllInnerStatesMutable { innerState, packetNumberSpace in
            let ackElicitingPacketsInFlight = innerState.ackElicitingPacketsInFlight
            guard ackElicitingPacketsInFlight > 0 else {
                return
            }

            connection.log.datapath(
                "PTO \(path.recoveryState.PTOCount) (\(packetNumberSpace)) fired on path \(path.identifier) with \(ackElicitingPacketsInFlight) ack-eliciting packets in flight"
            )

            let hasAckEliciting = connection.withPendingItems(for: packetNumberSpace) {
                $0.hasAckElicitingPendingItems
            }

            if hasAckEliciting {
                connection.log.datapath("Sending next frames with new data as PTOs")
                let packets = connection.sendFramesFromRecovery(
                    on: path,
                    ignoreCongestionWindow: true,
                    discardInitialRecoveryState: &discardInitialRecoveryState
                )
                // Only a recorded packet counts as a probe; the pending items may write no payload.
                if innerState.recordSentPackets(packets, connection: connection) {
                    sentPTO = true
                } else {
                    connection.log.datapath(
                        "Unable to force send PTOs, likely flow-controlled or unavailable"
                    )
                }

            } else {
                connection.log.datapath("Retransmitting two tail-packets as PTO")

                var addedPackets = 0
                let packetCount = innerState.outstandingPackets.count
                for i in 0..<packetCount {
                    if addedPackets >= 2 {
                        break
                    }

                    var packets: NetworkUniqueDeque<SentPacketRecord>?
                    var packetIsAckEliciting: Bool?
                    innerState.findSentPacketEntry(index: i) { entry in
                        Recovery.logPacketLost(
                            packet: entry.packet,
                            trigger: .pto,
                            connection: connection
                        )
                        packetIsAckEliciting = entry.packet.isAckEliciting
                        guard entry.packet.isAckEliciting else {
                            return
                        }
                        packets = connection.retransmitOnePacketForced(
                            packet: entry.packet,
                            path: path,
                            discardInitialRecoveryState: &discardInitialRecoveryState
                        )
                    }

                    if let packets, innerState.recordSentPackets(packets, connection: connection) {
                        sentPTO = true
                        addedPackets += 1
                    } else {
                        if let packetIsAckEliciting, !packetIsAckEliciting {
                            connection.log.datapath("Could not send PTO packet, not ack eliciting, trying next")
                        } else {
                            connection.log.error("Could not send first PTO packet")
                        }
                    }
                }
            }
        }

        if !sentPTO {
            if totalAckElicitingPacketsInFlight == 0, peerCompletedValidation(connection: connection) {
                // Nothing is in flight to probe for, so the state must have changed between arming the
                // timer and it firing (e.g. the handshake completed and cleared the in-flight packets).
                // `resetTimer` cancels the timer for this state once we return.
                connection.log.fault("PTO fired after validation")
                return
            }

            // Send an ack-eliciting probe because either:
            // - packets are in flight, RFC 9002 Section 6.2.4 requires a probe
            // - nothing is in flight and the peer has not validated our address, RFC 9002 Section 6.2.2.1
            // requires an anti-deadlock packet to unblock the server.
            // The PING is padded when it goes out in an initial packet.
            connection.log.datapath("Sending a PING as PTO")
            let packetNumberSpace =
                !connection.receivedHandshakePacket
                ? PacketNumberSpace.initial : PacketNumberSpace.applicationData
            connection.withPendingItems(for: packetNumberSpace) { item in
                item.ping = true
            }

            sentPTO = true

            withMutableInnerState(packetNumberSpace: packetNumberSpace) { innerState in
                let packets = connection.sendFramesFromRecovery(
                    on: path,
                    ignoreCongestionWindow: true,
                    discardInitialRecoveryState: &discardInitialRecoveryState
                )
                if !innerState.recordSentPackets(packets, connection: connection) {
                    connection.log.datapath(
                        "Unable to force send PTOs, likely flow-controlled or unavailable"
                    )
                }
            }
        }

        if discardInitialRecoveryState {
            self.resetPNSpace(packetNumberSpace: .initial, connection: connection)
            connection.withCurrentPath {
                self.resetPTOCount(path: $0)
            }
        }
        guard sentPTO else {
            log.error("Could not send PTO")
            return
        }
        path.recoveryState.PTOCount += 1
        connection.stats.increment(.probeTimeOuts)

        #if QlogOutput
        if let qLog = connection.qLog {
            qLog.recoveryUpdated(
                ptoCount: UInt64(path.recoveryState.PTOCount),
                inRecovery: nil,
                timestamp: .now
            )
        }
        #endif

        let hasLargerPacketCount = withImmutableInnerState(packetNumberSpace: .applicationData) {
            innerState in
            innerState.largerPacketCount > 0
        }
        if hasLargerPacketCount {
            var sentPackets = NetworkUniqueDeque<SentPacketRecord>()
            path.pmtudState.ptoEvent(
                on: path,
                ptoCount: path.recoveryState.PTOCount,
                sentPackets: &sentPackets
            )
            recordSentPackets(&sentPackets, connection: connection)
        }
    }

    mutating func timerFired(timeNow: NetworkClock.Instant) {
        guard let connection = connection else {
            return
        }
        let (lossTime, _) = getEarliestTime(
            earliestTimeType: EarliestTimeType.lossTime,
            connection: connection
        )
        if lossTime != .zero {
            log.datapath("Recovery timer fired, finding lost packets")
            findLostPacket(connection: connection)
        } else {
            log.datapath("Recovery timer fired, PTO")
            connection.withCurrentPath { path in
                sendPTO(connection: connection, path: path)
            }
        }
        resetTimer(connection: connection)
    }

    static func PTOPeriod(
        sRTT: NetworkDuration,
        variance: NetworkDuration,
        ackDelay: NetworkDuration
    ) -> NetworkDuration {
        sRTT + max(4 * variance, Recovery.timerGranularity) + ackDelay
    }

    static func computedPTO(rtt: borrowing RTT) -> NetworkDuration {
        if rtt.hasInitialMeasurement {
            return PTOPeriod(
                sRTT: rtt.smoothedRTT,
                variance: rtt.RTTVariance,
                ackDelay: rtt.remoteMaxAckDelay
            )
        } else {
            let (sRTT, varRTT) = rtt.cachedRTT
            return PTOPeriod(sRTT: sRTT, variance: varRTT, ackDelay: rtt.remoteMaxAckDelay)
        }
    }

    static func inPersistentCongestion(
        rtt: borrowing RTT,
        largestTime: NetworkClock.Instant,
        smallestTime: NetworkClock.Instant
    ) -> Bool {
        //
        // RFC 9002: The persistent congestion period SHOULD NOT start
        // until there is at least one RTT sample. Before the first RTT
        // sample, a sender arms its PTO timer based on the initial RTT,
        // which could be substantially larger than the actual RTT.
        // Requiring a prior RTT sample prevents a sender from
        // establishing persistent congestion with potentially too few probes.
        //
        guard rtt.hasInitialMeasurement else {
            return false
        }
        let pto = self.computedPTO(rtt: rtt)
        return (largestTime >= smallestTime + pto * Constants.persistentCongestionThreshold)
    }

    mutating func resetTimer(connection: QUICConnection) {
        // if there are ack eliciting packets on any of the innerStates, the L4S error should not be emitted
        if totalAckElicitingPacketsInFlight == 0 && peerCompletedValidation(connection: connection) {
            log.datapath("No ack eliciting packets in flight, cancelling timer")
            setTimer(delay: .zero, connection: connection)
            connection.withCurrentPath { path in
                guard path.isValidated else { return }
                var bytesInFlight: UInt64 = 0
                bytesInFlight = path.congestionControlBytesInFlight

                // We process non-ack eliciting packets in loss_recovery for
                // L4S as we want to do CE processing and loss recovery on
                // them. This ends up adding inflight eligible packets (such
                // as those containing PADDING frames) to bytes_in_flight.
                if !connection.isL4SEnabled && bytesInFlight != 0 {
                    log.error(
                        "No ack eliciting outstanding packets, bytesInFlight on path \(path.identifier) is \(bytesInFlight), and not 0"
                    )
                }
            }
            return
        }
        var timeout: NetworkDuration = .zero
        let now = connection.now
        let (lossTime, _) = getEarliestTime(earliestTimeType: .lossTime, connection: connection)
        if lossTime != .zero {
            // Time threshold loss detection.
            if now < lossTime {
                timeout = now.duration(to: lossTime)
            } else {
                // lossTime has already passed
                timeout = .microseconds(1000)
            }
            setTimer(delay: timeout, connection: connection)
        } else {
            // Arm PTO
            let (sentTime, pnSpace) = getEarliestTime(
                earliestTimeType: .lastSentAckElicitingTime,
                connection: connection
            )
            // Consider arming the PTO on the current path
            connection.withCurrentPath { path in
                if pnSpace == .applicationData && !connection.isHandshakeConfirmed {
                    log.datapath("Handshake not confirmed, cancelling timer")
                    setTimer(delay: .zero, connection: connection)
                    path.recoveryState.PTOPeriod = .zero
                    return
                }
                timeout = Recovery.computedPTO(rtt: path.rtt)
                timeout = timeout << path.recoveryState.PTOCount
                path.recoveryState.PTOPeriod = timeout
                // Check if sentTime has already elapsed
                if sentTime + timeout > now {
                    computedTimeout = now.duration(to: sentTime + timeout)
                } else {
                    computedTimeout = timeout
                }
                log.datapath("Resetting recovery timer to \(computedTimeout)")
                setTimer(delay: computedTimeout, connection: connection)
            }
        }
    }

    mutating func resetAll() {
        let connection = connection
        applyToAllInnerStatesMutable { innerState, _ in
            innerState.reset(connection: connection)
        }

        // TODO: Later, instead use a timer on the many-to-many to delay teardown on close
        self.connection?.timer.stop()
        self.connection = nil
    }

    var hasOutstandingPackets: Bool {
        var hasOutstandingPackets = false
        applyToAllInnerStatesImmutable { innerState, _ in
            if innerState.hasOutstandingPackets {
                hasOutstandingPackets = true
            }
        }
        return hasOutstandingPackets
    }

    // The PTO timer is shared across packet number spaces, so decisions about whether there is
    // anything left to probe for consider every space.
    var totalAckElicitingPacketsInFlight: Int {
        var totalAckElicitingPacketsInFlight = 0
        applyToAllInnerStatesImmutable { innerState, _ in
            totalAckElicitingPacketsInFlight += innerState.ackElicitingPacketsInFlight
        }
        return totalAckElicitingPacketsInFlight
    }

    mutating func resetPNSpace(
        packetNumberSpace: PacketNumberSpace,
        connection: QUICConnection
    ) {
        withMutableInnerState(packetNumberSpace: packetNumberSpace) {
            innerState in
            innerState.reset(connection: connection)
            Recovery.logAckElicitingPacketsInFlight(
                packetCount: innerState.ackElicitingPacketsInFlight,
                connection: connection
            )
        }
    }

    mutating func receivedAck(
        ack: consuming FrameAck,
        ackedPath: QUICPath,
        connection: QUICConnection
    ) {
        let packetNumberSpace = ack.packetNumberSpace
        if packetNumberSpace == PacketNumberSpace.handshake {
            receivedHandshakeAck = true
        } else if packetNumberSpace == PacketNumberSpace.applicationData {
            received1RTTAck = true
        }
        ackedPath.congestionControlAckBegin()

        let timeNow = connection.now
        var foundNewlyAckedPackets = false
        withMutableInnerState(packetNumberSpace: packetNumberSpace) {
            innerState in
            let ackLargest = ack.largest
            var largestAckedPacketNumber = connection.largestAckedPacketNumber(
                space: packetNumberSpace
            )
            if largestAckedPacketNumber == .none {
                largestAckedPacketNumber = ackLargest
            } else {
                largestAckedPacketNumber = max(largestAckedPacketNumber, ackLargest)
            }
            connection.setLargestAckedPacketNumber(
                largestAckedPacketNumber,
                space: packetNumberSpace
            )

            // If this packet is newly acked (otherwise we wouldn't find it).
            var foundPacketSentTime: NetworkClock.Instant? = nil
            let found = innerState.findSentPacketEntry(
                packetNumber: largestAckedPacketNumber
            ) { largestAckedEntry in
                if largestAckedEntry.packet.isAckEliciting {
                    // Then we take a new RTT sample if it is valid
                    if let sentPath = connection.path(for: largestAckedEntry.packet.sentPath) {
                        if ack.packetNumberSpace != PacketNumberSpace.applicationData {
                            innerState.log.datapath("Using ack delay \(ack.delay)")
                            ack.setDelay(0)
                        }
                        sentPath.rtt.processNewSample(
                            ackDuration: largestAckedEntry.sentTime.duration(to: timeNow),
                            packetAckedTime: connection.now,
                            ackDelay: .microseconds(ack.delay)
                        )
                        #if QlogOutput
                        if let qLog = connection.qLog {
                            qLog.rttUpdated(
                                minRTT: sentPath.rtt.minRTT,
                                smoothedRTT: sentPath.rtt.smoothedRTT,
                                latestRTT: sentPath.rtt.latestRTT,
                                rttVariance: sentPath.rtt.RTTVariance
                            )
                        }
                        #endif
                    }
                } else {
                    innerState.log.datapath(
                        "Largest acked is newly acked but not ack-eliciting, not taking new RTT sample"
                    )
                }
                foundPacketSentTime = largestAckedEntry.sentTime
            }
            if let foundPacketSentTime {
                innerState.largestAckedPNSentTime = foundPacketSentTime
            }
            if !found {
                innerState.log.datapath(
                    "Largest acked is not newly acked (or unknown), not taking new RTT sample"
                )
            }

            foundNewlyAckedPackets = innerState.findNewlyAckedPackets(
                ackFrame: ack,
                path: ackedPath,
                now: timeNow,
                connection: connection
            )
        }

        // Find newly acked packets
        if !foundNewlyAckedPackets {
            log.datapath("No newly acked packets, returning")
            // Update the congestion window based on the previously saved per ACK receive state
            ackedPath.congestionControlAckEnd(
                rtt: ackedPath.rtt,
                path: ackedPath,
                mss: ackedPath.mss,
                packetsLost: false,
                qlog: connection.qLog
            )
            return
        }

        var oldestSentEntryPacketNumber: PacketNumber?
        let largestAckedPacketNumber = connection.largestAckedPacketNumber(space: packetNumberSpace)
        withImmutableInnerState(packetNumberSpace: packetNumberSpace) {
            innerState in
            if !innerState.outstandingPackets.isEmpty {
                oldestSentEntryPacketNumber = innerState.findSentPacketEntry(index: 0) {
                    $0.packet.number
                }
            }
        }

        // Don't detect lost packets when this ACK has no impact on the list of outstanding packets.
        var packetsLost = false
        if let oldestSentEntryPacketNumber,
            oldestSentEntryPacketNumber.value < largestAckedPacketNumber
        {
            packetsLost = findLostPacket(
                pnSpace: packetNumberSpace,
                path: ackedPath,
                timeNow: timeNow,
                connection: connection
            )
        }
        // Update the congestion window based on the previously saved per ACK received state
        ackedPath.congestionControlAckEnd(
            rtt: ackedPath.rtt,
            path: ackedPath,
            mss: ackedPath.mss,
            packetsLost: packetsLost,
            qlog: connection.qLog
        )
        removeLostPackets(ackedPath: ackedPath, now: timeNow)

        // Any work/frames to send triggered by receiving this ACK is scheduled
        // in pendingItems and will be sent as part after inboundStopping

        if peerCompletedValidation(connection: connection) {
            ackedPath.recoveryState.PTOCount = 0
        }

        if inBatch {
            shouldResetTimer = true
        } else {
            resetTimer(connection: connection)
        }

        // Now that we have deal with all the ACK'ed packets,
        // it's safe to ask PMTUD to send packets.
        connection.applicationPendingItems.triggerAllStreamsUnblocked = true
    }
}
#endif
