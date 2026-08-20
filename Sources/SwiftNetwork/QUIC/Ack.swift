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
typealias AckBlock = (start: PacketNumber, end: PacketNumber)

// ACK state per packet number space.
@available(Network 0.1.0, *)
struct AckSpace: ~Copyable, PrefixedLoggable {
    var log: LogPrefixer
    var blocks: [AckBlock] = []
    var largestTimestamp: NetworkClock.Instant = .zero
    var delay = UInt64(0)
    var lastCECount = 0
    var lastGenerationCountUpdate = 0  // Last time we updated the gen count.
    var largestAckElicitingPNReceived: PacketNumber = .none
    var largestPNReceived: PacketNumber = .none
    var generationCount = 0
    // Do we need to send this ACK?  If we just added a non
    // ACK-eliciting packet to the list, then we don't need to send an
    // ACK.
    var needsTransmission = true

    init(logPrefixer: LogPrefixer) {
        self.log = logPrefixer
    }

    mutating func coalesce() {
        var index = 1
        while index < blocks.count {
            let current = blocks[index]
            if blocks[index - 1].end == current.start - 1 {
                blocks[index - 1].end = current.end
                blocks.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    mutating func append(
        _ packetNumber: PacketNumber,
        packetNumberSpace: PacketNumberSpace,
        now: NetworkClock.Instant
    ) {
        log.datapath(
            "appending pn \(packetNumber) for space \(packetNumberSpace)"
        )

        var oldLargest: PacketNumber
        if let last = blocks.last {
            oldLargest = last.end
        } else {
            oldLargest = PacketNumber.max
            largestTimestamp = now
        }
        // Case 0: empty list.
        // N.B.: we return early in this case.
        if blocks.isEmpty {
            let block = AckBlock(packetNumber, packetNumber)
            blocks.append(block)
            largestTimestamp = now
            evaluateCompression(packetNumber: packetNumber, oldLargest: oldLargest)
            // N.B.: no need to call coalesce()
            return
        }
        // Case 1: extends an existing block
        // N.B.: we walk the array backwards because it's likely that we'll
        // find a matching block at the end of the array.
        var coalesceLater = true
        var handled = false
        for index in blocks.indices.reversed() {
            if packetNumber >= blocks[index].start && packetNumber <= blocks[index].end {
                // Duplicate packet number, ignore and don't call coalesce().
                handled = true
                coalesceLater = false
                break
            }
            if blocks[index].start != 0 && packetNumber == blocks[index].start - Int64(1) {
                blocks[index].start -= 1
                handled = true
                break
            }

            if blocks[index].end != PacketNumber.max
                && packetNumber == blocks[index].end + Int64(1)
            {
                blocks[index].end += 1
                handled = true
                break
            }
            if packetNumber > blocks[index].end {
                // Since the blocks are in order, we can stop
                // iterating here as the next blocks are not
                // going to match.
                break
            }
        }
        if !handled {
            // Case 2: insert a new ACK block in the list.
            let block = AckBlock(packetNumber, packetNumber)
            var candidateBlockIndex = 0
            for index in blocks.indices.reversed() {
                if blocks[index].end < packetNumber {
                    candidateBlockIndex = index + 1
                    break
                }
            }
            blocks.insert(block, at: candidateBlockIndex)
            coalesceLater = false
        }
        if coalesceLater {
            coalesce()
        }
        if packetNumber > oldLargest {
            largestTimestamp = now
        }
        evaluateCompression(packetNumber: packetNumber, oldLargest: oldLargest)
    }

    // Received an ACK for our ACK.
    mutating func acknowledged(between startPN: PacketNumber, and endPN: PacketNumber) {
        let index = blocks.firstIndex(where: { $0.start == startPN && $0.end == endPN })
        if let index {
            log.datapath(
                "removing ACK block \(startPN.value)-\(endPN.value) at index \(index), current block count: \(blocks.count)"
            )
            blocks.remove(at: index)
            // The next ACK must not be compressed.
            generationCount += 1
        }
        // N.B.: don't set needsTransmission to true because we
        // are removing a packet number and we are sure the
        // peer received our ACK (this is the ACK-of-an-ACK
        // routine after all).
    }

    mutating func evaluateCompression(
        packetNumber: PacketNumber,
        oldLargest: PacketNumber
    ) {
        if oldLargest == PacketNumber.max {
            // We haven't yet sent an ACK or we have no
            // existing blocks so don't compress.
            generationCount += 1
        } else if packetNumber == oldLargest {
            // Already processed.
            return
        } else if packetNumber.value != oldLargest.value + 1 {
            // We're only allowed to compress ACKs that
            // increment the `largest` field.
            // Since this ACK changes a range, we shouldn't
            // compress it.
            generationCount += 1
        } else if _slowPath(packetNumber < oldLargest) {
            log.fault("packetNumber \(packetNumber) < oldest \(oldLargest)")
        }
    }

    fileprivate func consistencyCheck() -> Bool {
        for (index, block) in blocks.enumerated() {
            if block.start > block.end {
                return false
            }
            var next: AckBlock? = nil
            if index < blocks.count - 1 {
                next = blocks[index + 1]
            }
            if let next = next, block.end >= next.start {
                return false
            }
        }
        return true
    }

    mutating func updateLargestAckElicitingPacketNumber(_ packetNumber: PacketNumber) {
        if packetNumber > largestAckElicitingPNReceived {
            largestAckElicitingPNReceived = packetNumber
        }
    }

    mutating func updateLargestPacketNumber(_ packetNumber: PacketNumber) {
        if packetNumber > largestPNReceived {
            largestPNReceived = packetNumber
        }
    }

    mutating func build(
        packetNumberSpace: PacketNumberSpace,
        delayExponent: Int,
        delaySize: Int = 0,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecnCounter: ECNCounter?,
        now: NetworkClock.Instant
    ) -> Int {
        guard blocks.first != nil && needsTransmission == true, let lastBlock = blocks.last else {
            log.datapath(
                "no ACKs to send for \(packetNumberSpace) (needsTransmission \(needsTransmission))"
            )
            return 0
        }
        guard _slowPath(largestTimestamp != .zero) else {
            log.debug("Largest PN receive time can't be 0 (\(packetNumberSpace))")
            return 0
        }
        let largest = lastBlock.end
        log.datapath("processing ACKs for \(packetNumberSpace)")
        // Calculate ack_delay if assemble() is called
        // without calling size().
        switch packetNumberSpace {
        case .initial, .handshake:
            delay = 0
        case .applicationData:
            if delay == 0 {
                delay = UInt64(largestTimestamp.duration(to: now).microseconds) >> delayExponent
            }

        }
        var ackFrame: FrameAck? = nil
        var len = FrameType.ack.rawValue.variableLengthSize
        if delaySize > 0 {
            len += UInt64(largest.value).variableLengthSize + delaySize
        } else {
            len += UInt64(largest.value).variableLengthSize
            len += UInt64(delay).variableLengthSize
            var ack = FrameAck(
                packetNumberSpace: packetNumberSpace,
                largest: largest,
                delay: UInt64(delay)
            )
            if let ecnCounter {
                ack.ecnCounter = ecnCounter
            }
            ackFrame = ack
        }
        var blockCount = 0
        for index in blocks.indices.reversed() {
            let currentBlock = blocks[index]
            let blockSpan = currentBlock.end - currentBlock.start
            len += blockSpan.value.variableLengthSize
            blockCount += 1
            // N.B.: we're reversing the list
            if index > 0 {
                let prevBlock = blocks[index - 1]
                let gap = currentBlock.start - prevBlock.end - 2
                len += gap.value.variableLengthSize
                ackFrame?.addRange(gap: gap, range: blockSpan)
            } else {
                ackFrame?
                    .addRange(
                        gap: PacketNumber.initial,
                        range: blockSpan
                    )
            }
        }
        len += UInt64(blockCount).variableLengthSize
        if let ecnCounter {
            let ackECN = ecnCounter.ce > 0 || ecnCounter.ect0 > 0 || ecnCounter.ect1 > 0
            if ackECN {
                len += UInt64(ecnCounter.ect0).variableLengthSize
                len += UInt64(ecnCounter.ect1).variableLengthSize
                len += UInt64(ecnCounter.ce).variableLengthSize
                if lastCECount != ecnCounter.ce {
                    // Increase the generation count when the CE
                    // marking changes.
                    generationCount += 1
                }
                lastCECount = ecnCounter.ce
            }
        }
        var frame: QUICFrame? = nil
        if let ackFrame {
            frame = .ack(frame: ackFrame)
        }
        if let frame {
            setAckFrame(packetNumberSpace, frame, (blockCount > Ack.pingThreshold))
        }
        if blockCount > Ack.maxAckBlocks {
            blocks.removeFirst()
            generationCount += 1
        }

        return len
    }

    func packetsMissingBetween(
        packetNumberLow: PacketNumber,
        packetNumberHigh: PacketNumber
    ) -> Bool {
        // TODO: While this algorithm is O(1), which is great, it does not
        // correctly handle the case where the both packetNumberLow and packetNumberHigh
        // are earlier than all of the packets in the largestBlock.
        // As a consequence it will return true in some case where it should
        // not. We should evaluate the tradeoff between making this code
        // slower but detecting gaps correctly.
        guard packetNumberLow < packetNumberHigh else {
            return false
        }
        guard let largestBlock = self.blocks.last else {
            // No packets have been received.
            return false
        }
        guard packetNumberHigh <= largestBlock.end + Int64(1) else {
            // There is a gap between the previously highest received
            // packet and packetNumberHigh.
            return true
        }
        guard packetNumberLow < largestBlock.end else {
            // No packets have been received which have higher numbers
            // than packetNumberLow, so there can not be a gap.
            return false
        }
        guard largestBlock.start > packetNumberLow + Int64(1) else {
            // All packets with higher numbers than packetNumberLow are in the last
            // block and have been received, or packetNumberLow is covered by the
            // last block.
            return false
        }
        return true
    }
}

@available(Network 0.1.0, *)
struct AckBlockIterator: IteratorProtocol {
    typealias Element = AckBlock

    var index = 0
    var largest: PacketNumber
    let oldestPacketNumber: PacketNumber
    let ranges: ArraySlice<FrameAckRange>

    @inlinable
    @inline(__always)
    init(_ sequence: AckBlockSequence) {
        self.ranges = sequence.ranges[...]
        self.largest = sequence.largest
        self.oldestPacketNumber = sequence.oldestPacketNumber
    }

    @inlinable
    @inline(__always)
    mutating func next() -> AckBlock? {
        while true {
            guard index < ranges.count else {
                return nil
            }
            let range = ranges[index].range
            guard range <= largest else {
                // Guard against underflow
                return nil
            }
            let smallest = largest - range
            let savedLargest = largest
            // Only recompute `largest' if we are iterating again.
            // Otherwise, we might end up with an integer underflow.
            if index + 1 != ranges.count {
                guard smallest >= 2 else {
                    // Guard against underflow
                    return nil
                }
                let gap = ranges[index + 1].gap
                guard gap <= smallest - 2 else {
                    // Guard against underflow
                    return nil
                }
                largest = smallest - gap - 2
            }
            index += 1
            if savedLargest < oldestPacketNumber {
                continue
            } else {
                return (start: smallest, end: savedLargest)
            }
        }
    }
}

@available(Network 0.1.0, *)
struct AckBlockSequence: Sequence {
    let largest: PacketNumber
    let oldestPacketNumber: PacketNumber
    let ranges: [FrameAckRange]

    @inlinable
    @inline(__always)
    init(largest: PacketNumber, ranges: [FrameAckRange], oldestPacketNumber: PacketNumber) {
        self.largest = largest
        self.ranges = ranges
        self.oldestPacketNumber = oldestPacketNumber
    }

    @inlinable
    @inline(__always)
    func makeIterator() -> AckBlockIterator {
        AckBlockIterator(self)
    }
}

@available(Network 0.1.0, *)
final class Ack: PrefixedLoggable, TimerUser {
    var log: LogPrefixer

    // When an outgoing ACK reports more than this many blocks (i.e. this many gaps
    // in the packet numbers we've received), we piggyback a PING frame. An ACK
    // frame is not ack-eliciting on its own, so the peer is not obliged to
    // acknowledge it; the PING makes the packet ack-eliciting, forcing the peer to
    // ACK it. That ack-of-ack lets us confirm the peer saw our gap report and prune
    // the corresponding ACK blocks, keeping the list from growing.
    static let pingThreshold = 5

    // Upper bound on the number of ACK blocks (ranges) we track per packet number
    // space. A peer that sends highly fragmented or persistently reordered traffic
    // would otherwise grow this list without bound, inflating both memory use and
    // the size of the ACK frames we emit. When the count exceeds this limit we drop
    // the oldest (lowest-PN) block as each ACK is built, trimming the list back
    // toward the cap.
    static let maxAckBlocks = 256

    // Number of consecutive packets to ACK immediately (bypassing the ACK delay
    // timer) after entering aggressive-ACK mode via ackAgressively(). The
    // counter is seeded with this value and decremented on each ACK sent; while it
    // is non-zero we send ACKs without waiting, which speeds up loss recovery and
    // RTT sampling during sensitive phases.
    static let immediateAcks = 8

    static let defaultPacketThreshold = 128
    static let defaultDelayExponent = 3 /* 2 ** 3 */

    static let defaultMaxDelay: NetworkDuration = .milliseconds(25)

    static let maxDelayExponent = 20  // Values above 20 are invalid
    static let maxDelayMilliseconds = (1 << 14) * System.Time.USEC_PER_MSEC  // Values above 2^14ms are invalid

    private var initialAckSpace: AckSpace
    private var handshakeAckSpace: AckSpace
    private var applicationAckSpace: AckSpace

    var localDelayExponent = Ack.defaultDelayExponent
    var remoteDelayExponent = Ack.defaultDelayExponent

    var unackedPacketCount = 0
    var lastSentTime: NetworkClock.Instant = .zero
    var timerID: Timer.TimerID? = nil
    var connection: QUICConnection?
    var disableAckCompression: Bool = false

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let timerScheduled = Flags(rawValue: 1 << 0)
    }
    var flags: Flags = Flags()
    var timerScheduled: Bool {
        get { flags.contains(.timerScheduled) }
        set { if newValue { flags.insert(.timerScheduled) } else { flags.remove(.timerScheduled) } }
    }

    // Fixed size used for ack delay.
    // MUST be used only for testing
    var delaySize = 0

    var immediateAcks = 0
    var packetThreshold = Ack.defaultPacketThreshold
    var sentFrequencyThreshold = 0
    // Our max ACK delay. (microseconds)
    var maxDelay = Ack.defaultMaxDelay
    // Timestamp when last ACK_FREQUENCY frame was sent.
    var sentFrequencyTimestamp = UInt64(0)
    // Next ACK_FREQUENCY sequence number to send.
    var nextFrequencySequence = 0
    // Sequence number of the last received ACK_FREQUENCY frame.
    var receivedFrequencySequence = 0

    init(connection: QUICConnection? = nil, timerID: Timer.TimerID? = 0, logPrefixer: LogPrefixer) {
        self.connection = connection
        self.timerID = timerID
        self.log = logPrefixer
        self.initialAckSpace = AckSpace(logPrefixer: logPrefixer)
        self.handshakeAckSpace = AckSpace(logPrefixer: logPrefixer)
        self.applicationAckSpace = AckSpace(logPrefixer: logPrefixer)
    }

    func reset() {
        connection?.timer.stop()
        connection = nil
    }

    deinit {
        if let timerID = timerID {
            connection?.timer.remove(timerID)
        }
    }

    func timerFired(timeNow: NetworkClock.Instant) {
        log.datapath("delayed ACK timer fired")
        if let connection = connection {
            if sendPending(
                isAckSet: connection.isAckSet,
                setAckFrame: connection.scheduleAckFrame,
                ecn: connection.ecn
            ) {
                connection.sendFrames(delayedACK: true)

                // An ACK-only packet is not ack-eliciting, so once it is sent
                // there is nothing left in pending items or in recovery to
                // observe. This is the only place that can return the
                // connection to idle after a delayed ACK.
                connection.checkConnectionIdle()
            }
        }

    }

    @discardableResult
    func withAckSpace(
        packetNumberSpace: PacketNumberSpace,
        closure: (_: inout AckSpace) -> Bool
    ) -> Bool {
        switch packetNumberSpace {
        case .applicationData:
            return closure(&applicationAckSpace)
        case .handshake:
            return closure(&handshakeAckSpace)
        case .initial:
            return closure(&initialAckSpace)
        }
    }

    func append(
        packetNumberSpace: PacketNumberSpace,
        packetNumber: PacketNumber,
        now: NetworkClock.Instant
    ) {
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            ackSpace.append(packetNumber, packetNumberSpace: packetNumberSpace, now: now)
            return true
        }
    }

    func packetsMissingBetween(
        packetNumberSpace: PacketNumberSpace,
        packetNumberLow: PacketNumber,
        packetNumberHigh: PacketNumber
    ) -> Bool {
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            ackSpace.packetsMissingBetween(
                packetNumberLow: packetNumberLow,
                packetNumberHigh: packetNumberHigh
            )
        }
    }

    func ackRequiresAssembly(
        packetNumberSpace: PacketNumberSpace
    ) -> Bool {
        switch packetNumberSpace {
        case .applicationData:
            return (applicationAckSpace.needsTransmission && applicationAckSpace.blocks.count > 0)
        case .handshake:
            return (handshakeAckSpace.needsTransmission && handshakeAckSpace.blocks.count > 0)
        case .initial:
            return (initialAckSpace.needsTransmission && initialAckSpace.blocks.count > 0)
        }
    }

    func assemble(
        for packetNumberSpace: PacketNumberSpace,
        isAckSet: Bool,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecnCounter: ECNCounter?,
        now: NetworkClock.Instant
    ) -> Bool {
        var shouldSend = false
        if isAckSet {
            log.datapath("ACK frame already in the builder")
            shouldSend = true
        } else {
            withAckSpace(packetNumberSpace: packetNumberSpace) {
                ackSpace in
                // We may be bundling an ACK, so set this to false to avoid sending
                // another ACK when the delayed ACK timer fires.
                let ackSize = ackSpace.build(
                    packetNumberSpace: packetNumberSpace,
                    delayExponent: localDelayExponent,
                    setAckFrame: setAckFrame,
                    ecnCounter: ecnCounter,
                    now: now
                )
                shouldSend = ackSize > 0
                ackSpace.needsTransmission = false
                return true
            }
        }
        return shouldSend
    }

    func assemble(
        for path: QUICPath,
        delayExponent: Int,
        isAckSet: (PacketNumberSpace) -> Bool,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecn: borrowing ECN
    ) -> Bool {
        var shouldSend = false
        for packetNumberSpace in PacketNumberSpace.allCases {
            // if ACK is already set, would we want to replace it?
            if isAckSet(packetNumberSpace) {
                log.datapath("ACK frame already in the builder")
                shouldSend = true
            } else {
                withAckSpace(packetNumberSpace: packetNumberSpace) {
                    ackSpace in
                    if ackSpace.needsTransmission {
                        var ecnCounter: ECNCounter? = nil
                        path.withECNState { ecnState in
                            let ecnCounters = ecnState.ecnCounters(
                                ecn: ecn,
                                packetNumberSpace: packetNumberSpace
                            )
                            if !ecnCounters.rxECNPackets.isEmpty {
                                ecnCounter = ecnCounters.rxECNPackets
                            }
                        }
                        let ackSize = ackSpace.build(
                            packetNumberSpace: packetNumberSpace,
                            delayExponent: delayExponent,
                            setAckFrame: setAckFrame,
                            ecnCounter: ecnCounter,
                            now: path.parentProtocol.now
                        )
                        shouldSend = shouldSend || ackSize > 0
                        ackSpace.needsTransmission = false
                    }
                    return true
                }
            }
        }
        return shouldSend
    }

    func sent(_ sentTime: NetworkClock.Instant) {
        unackedPacketCount = 0
        lastSentTime = sentTime
        if immediateAcks > 0 {
            immediateAcks -= 1
        }
    }

    private func schedulePending(
        on path: QUICPath,
        isAckSet: (PacketNumberSpace) -> Bool,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecn: borrowing ECN
    ) -> Bool {
        let shouldSend = assemble(
            for: path,
            delayExponent: localDelayExponent,
            isAckSet: isAckSet,
            setAckFrame: setAckFrame,
            ecn: ecn
        )
        if shouldSend {
            sent(path.parentProtocol.now)
        }
        log.datapath("\(shouldSend)")
        return shouldSend
    }

    func sendPending(
        isAckSet: (PacketNumberSpace) -> Bool,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecn: borrowing ECN
    ) -> Bool {
        guard let connection else {
            return false
        }
        let shouldSend = connection.withCurrentPath { path in
            schedulePending(
                on: path,
                isAckSet: isAckSet,
                setAckFrame: setAckFrame,
                ecn: ecn
            )
        }
        if timerScheduled, let timerID = timerID {
            connection.timer.reschedule(
                identifier: timerID,
                fromNow: .zero,
                timerNow: connection.now
            )
            timerScheduled = false
        }
        return shouldSend
    }

    static func blockSequence(
        frame: FrameAck,
        oldestPacketNumber: PacketNumber = .initial
    ) -> AckBlockSequence {
        AckBlockSequence(
            largest: frame.largest,
            ranges: frame.ranges,
            oldestPacketNumber: oldestPacketNumber
        )
    }

    static func blockSequence(
        frame: TransmittedItems.TransmittedAckFrame,
        oldestPacketNumber: PacketNumber = .initial
    ) -> AckBlockSequence {
        AckBlockSequence(
            largest: frame.largest,
            ranges: frame.ranges,
            oldestPacketNumber: oldestPacketNumber
        )
    }

    static func blockSequence(
        shorthandFrame: ShorthandFrameAck,
        oldestPacketNumber: PacketNumber = .initial
    ) -> AckBlockSequence {
        AckBlockSequence(
            largest: shorthandFrame.largest,
            ranges: shorthandFrame.ranges,
            oldestPacketNumber: oldestPacketNumber
        )
    }

    func scheduleDelayedAck() {
        // ACK timer is already scheduled
        if timerScheduled {
            return
        }
        timerScheduled = true
        log.datapath("scheduling delayed ACK in \(maxDelay)")
        if let timerID = timerID {
            if let connection {
                connection.timer.reschedule(
                    identifier: timerID,
                    fromNow: maxDelay,
                    timerNow: connection.now
                )
            }
        }
    }

    private func processPending(
        on path: QUICPath,
        connectionWindow: Int,
        isAckSet: (PacketNumberSpace) -> Bool,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecn: borrowing ECN
    ) -> Bool {
        // If the peer asked us to, delay the ACK.
        // Otherwise, delay the ACK if we are not forcing ACKs immediately
        // and either a or b is true. a. Only one unacked packet (if only a.
        // is true, ACK every other packet.) b. All of the below are true:
        // 1. Receive window has grown more than 2 * conn initial recvspace
        // 2. Most recent BDP is more than 1/2 initial stream recvspace
        // (64K), i.e. the sender might already be past slow-start, whether
        // he was idle, app-limited etc.
        // 3. We have less than N (packet tolerance) unacked packets
        // 4. We haven't waited for 1/2 RTT (time tolerance)
        let delayedTime = min(maxDelay, path.rtt.smoothedRTT / 2)
        let now = path.parentProtocol.now
        if immediateAcks == 0
            && (unackedPacketCount == 1
                || connectionWindow > 2 * FlowControlGlobals.shared.initialConnectionReceiveSpace
                    && path.bdp.currentBDP > FlowControlGlobals.shared.initialStreamReceiveSpace
                        >> 1
                    && unackedPacketCount < packetThreshold
                    && now < lastSentTime.advanced(by: delayedTime))
        {
            scheduleDelayedAck()
            return false
        } else {
            log.datapath("sending ACKs immediately")
            return schedulePending(
                on: path,
                isAckSet: isAckSet,
                setAckFrame: setAckFrame,
                ecn: ecn
            )
        }
    }

    func processPending(
        connectionWindow: Int,
        isAckSet: (PacketNumberSpace) -> Bool,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecn: borrowing ECN
    ) -> Bool {
        if unackedPacketCount < 1 {
            // If there are no unacked packets, do nothing
            return false
        }
        guard let connection else { return false }
        return connection.withCurrentPath { path in
            processPending(
                on: path,
                connectionWindow: connectionWindow,
                isAckSet: isAckSet,
                setAckFrame: setAckFrame,
                ecn: ecn
            )
        }
    }

    func acknowledged(
        packetNumberSpace: PacketNumberSpace,
        between startPN: PacketNumber,
        and endPN: PacketNumber
    ) {
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            ackSpace.acknowledged(between: startPN, and: endPN)
            return true
        }
    }

    func ackAgressively() {
        immediateAcks = Ack.immediateAcks
    }

    func ackImmediately() {
        if immediateAcks == 0 {
            immediateAcks = 1
        }
    }

    func shouldTransmit(packetNumberSpace: PacketNumberSpace) {
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            ackSpace.needsTransmission = true
            return true
        }
    }

    func flush(for packetNumberSpace: PacketNumberSpace) {
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            log.debug("Flushing all PN for \(packetNumberSpace)")
            ackSpace.blocks = []
            ackSpace.needsTransmission = false
            return true
        }
    }

    func getGenerationCount(
        for packetNumberSpace: PacketNumberSpace,
        now: Int
    ) -> Int {
        guard QUICPreferences.shared.ackCompressionEnabled && !disableAckCompression else {
            return 0
        }
        guard packetNumberSpace == .applicationData else {
            // Don't compress ACKs during the handshake.
            return 0
        }
        var generationCount = 0
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            // The generation counter needs to be updated at
            // least every 5 ms.
            let updateInterval = Int(5 * System.Time.USEC_PER_MSEC)
            if ackSpace.lastGenerationCountUpdate != 0
                && now >= ackSpace.lastGenerationCountUpdate + updateInterval
            {
                ackSpace.generationCount += 1
                generationCount = ackSpace.generationCount
                ackSpace.lastGenerationCountUpdate = now
            } else if ackSpace.lastGenerationCountUpdate == 0 {
                ackSpace.lastGenerationCountUpdate = now
            }
            generationCount = ackSpace.generationCount
            return true
        }
        return generationCount
    }

    internal func consistencyCheck() -> Bool {
        guard initialAckSpace.consistencyCheck() else {
            return false
        }
        guard handshakeAckSpace.consistencyCheck() else {
            return false
        }
        guard applicationAckSpace.consistencyCheck() else {
            return false
        }
        return true
    }

    func updateLargestAckElicitingPacketNumber(
        packetNumber: PacketNumber,
        packetNumberSpace: PacketNumberSpace,
    ) {
        withAckSpace(packetNumberSpace: packetNumberSpace) {
            ackSpace in
            ackSpace.updateLargestAckElicitingPacketNumber(packetNumber)
            return true
        }
    }

    func updateLargestPacketNumber(
        packetNumber: PacketNumber,
        packetNumberSpace: PacketNumberSpace
    ) {
        withAckSpace(packetNumberSpace: packetNumberSpace) {
            ackSpace in
            ackSpace.updateLargestPacketNumber(packetNumber)
            return true
        }
    }

    func getLargestReceivedPacketNumber(
        packetNumberSpace: PacketNumberSpace
    ) -> PacketNumber? {
        var largestReceivedPacketNumber: PacketNumber? = nil
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            largestReceivedPacketNumber = ackSpace.largestPNReceived
            return true
        }
        return largestReceivedPacketNumber
    }

    func getLargestAckElicitingPacketNumber(
        packetNumberSpace: PacketNumberSpace
    ) -> PacketNumber {
        var largestAckElicitingPacketNumber: PacketNumber = .none
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            largestAckElicitingPacketNumber = ackSpace.largestAckElicitingPNReceived
            return true
        }
        return largestAckElicitingPacketNumber
    }

    func blocksForPacketNumberSpace(
        packetNumberSpace: PacketNumberSpace
    ) -> Int {
        var blocks = 0
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            blocks = ackSpace.blocks.count
            return true
        }
        return blocks
    }
}

extension UInt64 {
    @inline(__always)
    // Just like ffs().
    var indexOfFirstSetBit: UInt64 {
        self != 0 ? (UInt64(self.trailingZeroBitCount) &+ 1) : 0
    }
}

// This is a C bitstring.h inspired ACK bitstring, useful for finding out
// which packets are newly acked.
@available(Network 0.1.0, *)
struct AckBitstring: ~Copyable {
    private(set) var initialWord: UInt64 = 0
    // Store up to 512 packets
    private(set) var bitstring: NetworkUniqueArray<UInt64> = .init(repeating: 0, count: 64)
    var size: Int { bitstring.count }

    init() {}

    init(frame: FrameAck, oldestPN: PacketNumber) {
        reinit(frame: frame, oldestPN: oldestPN)
    }

    // Same as init, but does not zero out bitstring[]
    mutating func reinit(frame: FrameAck, oldestPN: PacketNumber) {
        for block in Ack.blockSequence(frame: frame, oldestPacketNumber: oldestPN) {
            let start = max(block.start, oldestPN)
            nset(start: start, stop: block.end)
        }
    }

    // In this context, a word is 64 bit.
    private static func word(_ bits: PacketNumber) -> UInt64 {
        UInt64(bits.value >> 6)
    }

    private func validateInitial(start: PacketNumber, stop: PacketNumber) -> Bool {
        let startWord = AckBitstring.word(start)
        let stopWord = AckBitstring.word(stop)

        // The connection will stall if these two conditions occur.
        let initialWord = initialWord
        if _slowPath(startWord < initialWord) {
            Logger.proto.fault(
                "Initial word \(initialWord) is lower than start \(startWord) (pn \(start))"
            )
            return false
        }
        if _slowPath(stopWord < initialWord) {
            Logger.proto.fault(
                "Initial word \(initialWord) is lower than stop \(stopWord) (pn \(stop))"
            )
            return false
        }
        return true
    }

    // Validates the size of the bitstring.
    private func validate(start: PacketNumber, stop: PacketNumber) -> Bool {
        if !validateInitial(start: start, stop: stop) {
            return false
        }

        let startWord = AckBitstring.word(start)
        let stopWord = AckBitstring.word(stop)

        let bitstringCount = UInt64(bitstring.count)
        let initialWord = initialWord
        if _slowPath(startWord > initialWord + bitstringCount) {
            Logger.proto.fault(
                "Size \(bitstringCount + initialWord) is lower than start \(startWord) (pn \(start))"
            )
            return false
        }
        if _slowPath(stopWord > initialWord + bitstringCount) {
            Logger.proto.fault(
                "Size \(bitstringCount + initialWord) is lower than start \(stopWord) (pn \(stop))"
            )
            return false
        }
        return true
    }

    mutating func nset(start: PacketNumber, stop: PacketNumber) {
        if !validateInitial(start: start, stop: stop) {
            return
        }

        // N.B.: note the subtraction
        let startWord = AckBitstring.word(start) - initialWord
        let stopWord = AckBitstring.word(stop) - initialWord

        if stopWord >= size {
            guard _slowPath(stopWord < UInt32.max / 2) else {
                Logger.proto.info("Refusing to grow bitstring further")
                return
            }
            let targetSize = Int(stopWord) + 1
            let newSize =
                targetSize <= size
                ? size : (1 << (Int.bitWidth - targetSize.leadingZeroBitCount))
            resize(to: newSize)
        }
        if startWord == stopWord {
            bitstring[Int(startWord)] |=
                (UInt64.max << (start.value & 0x3f)) & (UInt64.max >> (63 - (stop.value & 0x3f)))
        } else {
            bitstring[Int(startWord)] |= UInt64.max << (start.value & 0x3f)
            var w = Int(startWord + 1)
            while w < stopWord {
                bitstring[w] = UInt64.max
                w &+= 1
            }
            bitstring[Int(stopWord)] |= UInt64.max >> (63 - (stop.value & 0x3f))
        }
    }

    mutating func trim() {
        let size = self.size
        let middle = size / 2
        bitstring.removeSubrange(0..<middle)
        initialWord += UInt64(middle)
    }

    mutating func resize(to newSize: Int) {
        let size = self.size
        for _ in size..<newSize {
            bitstring.append(0)
        }
    }

    // XOR two ACK bitstrings and return a sequence of packet numbers.
    mutating func xor(
        other: inout AckBitstring,
        firstPN: PacketNumber,
        lastPN: PacketNumber
    ) -> AckBitstringSequence {
        guard initialWord == other.initialWord else {
            let initialWord = self.initialWord
            let otherInitialWord = other.initialWord
            Logger.proto.fault("Bitstring initial mismatch \(initialWord) != \(otherInitialWord)")
            return AckBitstringSequence.empty
        }
        if size > other.size {
            other.resize(to: size)
        } else if size < other.size {
            resize(to: other.size)
        }
        // We only need to validate one bitstring since they should be
        // the same size by now.
        guard validate(start: firstPN, stop: lastPN) else {
            return AckBitstringSequence.empty
        }

        let startingWord = AckBitstring.word(firstPN) - initialWord
        let endingWord = AckBitstring.word(lastPN) - initialWord

        let sequence = AckBitstringSequence(
            initialWord: initialWord,
            startingWord: startingWord,
            endingWord: endingWord,
            bitstring: self.bitstring,
            otherBitstring: other.bitstring
        )

        if startingWord > 0 && startingWord - 1 > size / 2 {
            trim()
            other.trim()
        }

        return sequence
    }
}

@available(Network 0.1.0, *)
struct AckBitstringIterator: IteratorProtocol {
    typealias Element = PacketNumber

    var currentWord: UInt64
    let size: Int
    let startingWord: UInt64
    let initialWord: UInt64
    var bitstringXored: ArraySlice<UInt64>

    @inlinable
    @inline(__always)
    init(_ sequence: AckBitstringSequence) {
        self.bitstringXored = sequence.bitstringXored[...]
        self.currentWord = 0
        self.size = sequence.size
        self.startingWord = sequence.startingWord
        self.initialWord = sequence.initialWord
    }

    @inlinable
    @inline(__always)
    mutating func next() -> PacketNumber? {
        var index: UInt64 = 0
        while currentWord < size {
            let result = bitstringXored[Int(currentWord)]
            // N.B.: safe because packet numbers are only 62-bit.
            index = result.indexOfFirstSetBit
            if index <= 0 {
                currentWord += 1
            } else {
                break
            }
        }
        if currentWord >= size {
            return nil
        }
        bitstringXored[Int(currentWord)] &= ~(1 << (index - 1))
        var packetNumber = index - 1 + ((startingWord + currentWord) * 64)
        packetNumber += initialWord * 64

        return PacketNumber(packetNumber)
    }
}

@available(Network 0.1.0, *)
struct AckBitstringSequence: Sequence {
    let initialWord: UInt64
    let startingWord: UInt64
    let size: Int
    var bitstringXored = [UInt64]()

    static let empty = AckBitstringSequence(
        initialWord: 0,
        startingWord: 0,
        endingWord: 0,
        bitstring: NetworkUniqueArray<UInt64>(repeating: 0, count: 1),
        otherBitstring: NetworkUniqueArray<UInt64>(repeating: 0, count: 1)
    )

    @inlinable
    @inline(__always)
    init(
        initialWord: UInt64,
        startingWord: UInt64,
        endingWord: UInt64,
        bitstring: borrowing NetworkUniqueArray<UInt64>,
        otherBitstring: borrowing NetworkUniqueArray<UInt64>
    ) {
        self.initialWord = initialWord
        self.startingWord = startingWord
        self.size = Int(endingWord - startingWord + 1)
        self.bitstringXored.reserveCapacity(size)
        // We are converting to base 0 indexing and copying only the necessary words.
        var index = Int(startingWord)
        while index <= endingWord {
            self.bitstringXored.append(bitstring[index] ^ otherBitstring[index])
            index &+= 1
        }
    }

    @inlinable
    @inline(__always)
    func makeIterator() -> AckBitstringIterator {
        AckBitstringIterator(self)
    }
}

// MARK: - Testing interface

@available(Network 0.1.0, *)
extension Ack {
    // Builds the ACK frame and inserts it in the packetBuilder, otherwise just calculates the size.
    // This function is only used in testing
    func buildForTesting(
        for packetNumberSpace: PacketNumberSpace,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecnCounter: ECNCounter? = nil,
        now: NetworkClock.Instant
    ) -> Int {
        var size = 0
        withAckSpace(packetNumberSpace: packetNumberSpace) { ackSpace in
            size = ackSpace.build(
                packetNumberSpace: packetNumberSpace,
                delayExponent: localDelayExponent,
                delaySize: delaySize,
                setAckFrame: setAckFrame,
                ecnCounter: ecnCounter,
                now: now
            )
            return true
        }
        return size
    }
}
#endif
