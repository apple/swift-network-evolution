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

#if !NETWORK_NO_SWIFT_QUIC && !NETWORK_EMBEDDED

import Testing

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

// Swift Testing does not allow `@available` on a suite or test, so each test checks it itself.
// Serialized, as several tests build a QUICConnection.
@Suite("Traffic analysis defenses", .serialized)
struct TrafficAnalysisDefensesTests {

    // MARK: - Options

    @Test("Padding and chaff are off by default")
    func offByDefault() {
        guard #available(Network 0.1.0, *) else { return }

        let options = QUICConnectionProtocol.Options()
        #expect(options.trafficAnalysisDefenses.padding == nil)
        #expect(options.trafficAnalysisDefenses.chaff == nil)
        #expect(!options.trafficAnalysisDefenses.isEnabled)
    }

    @Test("Padding sizes below one byte are normalized, through the initializer and the property")
    func paddingBelowOneByteIsNormalized() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Defenses = TrafficAnalysisDefenses

        #expect(Defenses(padding: .fixedSize(0)).padding == nil)
        #expect(Defenses(padding: .fixedSize(-1)).padding == nil)
        #expect(Defenses(padding: .roundUp(toMultipleOf: 0)).padding == nil)
        #expect(Defenses(padding: .randomSize(-5...3)).padding == .randomSize(1...3))
        #expect(Defenses(padding: .randomSize(-5...(-2))).padding == nil)

        var defenses = Defenses(padding: .fixedSize(1200))
        defenses.padding = .roundUp(toMultipleOf: -16)
        #expect(defenses.padding == nil)
        #expect(!defenses.isEnabled)
    }

    @Test("Valid padding is kept as given")
    func validPaddingIsKept() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Defenses = TrafficAnalysisDefenses

        #expect(Defenses(padding: .fixedSize(1200)).padding == .fixedSize(1200))
        #expect(Defenses(padding: .roundUp(toMultipleOf: 128)).padding == .roundUp(toMultipleOf: 128))
        #expect(Defenses(padding: .randomSize(600...1200)).padding == .randomSize(600...1200))
        #expect(Defenses(padding: .fixedSize(1200)).isEnabled)
    }

    @Test("The chaff interval is held between a millisecond and an hour")
    func chaffIntervalIsClamped() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Chaff = TrafficAnalysisDefenses.Chaff

        #expect(Chaff(interval: .zero, maximumConsecutiveChaff: 1).interval == .milliseconds(1))
        #expect(Chaff(interval: .milliseconds(-5), maximumConsecutiveChaff: 1).interval == .milliseconds(1))
        #expect(Chaff(interval: .hours(2), maximumConsecutiveChaff: 1).interval == .hours(1))
        #expect(Chaff(interval: .milliseconds(20), maximumConsecutiveChaff: 1).interval == .milliseconds(20))
    }

    @Test("Chaff jitter leaves every jittered interval at least a millisecond")
    func chaffJitterLeavesAtLeastAMillisecond() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Chaff = TrafficAnalysisDefenses.Chaff

        #expect(
            Chaff(interval: .milliseconds(20), jitter: .milliseconds(-3), maximumConsecutiveChaff: 1).jitter == .zero
        )

        let tooLarge = Chaff(interval: .milliseconds(20), jitter: .milliseconds(50), maximumConsecutiveChaff: 1)
        #expect(tooLarge.jitter == .milliseconds(19))
        #expect(tooLarge.interval - tooLarge.jitter >= .milliseconds(1))

        #expect(Chaff(interval: .zero, jitter: .milliseconds(5), maximumConsecutiveChaff: 1).jitter == .zero)
        let valid = Chaff(interval: .milliseconds(20), jitter: .milliseconds(5), maximumConsecutiveChaff: 1)
        #expect(valid.jitter == .milliseconds(5))
    }

    @Test("Chaff counts are at least 0 and 1")
    func chaffCountsAreClamped() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Chaff = TrafficAnalysisDefenses.Chaff

        let chaff = Chaff(interval: .milliseconds(20), maximumConsecutiveChaff: -1, roundTotalPacketsTo: 0)
        #expect(chaff.maximumConsecutiveChaff == 0)
        #expect(chaff.roundTotalPacketsTo == 1)
    }

    @Test("The delay before each chaff packet is the interval, give or take the jitter")
    func chaffDelayStaysWithinTheJitter() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Chaff = TrafficAnalysisDefenses.Chaff

        #expect(Chaff(interval: .milliseconds(20), maximumConsecutiveChaff: 1).nextDelay == .milliseconds(20))

        let jittered = Chaff(interval: .milliseconds(20), jitter: .milliseconds(5), maximumConsecutiveChaff: 1)
        for _ in 0..<100 {
            let delay = jittered.nextDelay
            #expect(delay >= .milliseconds(15) && delay <= .milliseconds(25))
        }

        // The largest jitter still leaves every delay at least a millisecond.
        let widest = Chaff(interval: .milliseconds(20), jitter: .hours(1), maximumConsecutiveChaff: 1)
        for _ in 0..<100 {
            #expect(widest.nextDelay >= .milliseconds(1))
        }
    }

    @Test("Chaff stops after at least the maximum in a row, on a multiple of the rounding")
    func chaffStopRule() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Chaff = TrafficAnalysisDefenses.Chaff

        let chaff = Chaff(interval: .milliseconds(20), maximumConsecutiveChaff: 5)
        #expect(!chaff.shouldStop(afterConsecutive: 4, totalPacketsSent: 40))
        #expect(chaff.shouldStop(afterConsecutive: 5, totalPacketsSent: 41))

        let rounded = Chaff(interval: .milliseconds(20), maximumConsecutiveChaff: 5, roundTotalPacketsTo: 10)
        #expect(!rounded.shouldStop(afterConsecutive: 5, totalPacketsSent: 41))
        #expect(!rounded.shouldStop(afterConsecutive: 8, totalPacketsSent: 49))
        #expect(rounded.shouldStop(afterConsecutive: 9, totalPacketsSent: 50))
        // The count is not reached on a multiple, so chaff keeps going.
        #expect(!rounded.shouldStop(afterConsecutive: 4, totalPacketsSent: 40))
        // A total that never lands on a multiple still stops, the rounding's worth after the maximum.
        #expect(!rounded.shouldStop(afterConsecutive: 14, totalPacketsSent: 69))
        #expect(rounded.shouldStop(afterConsecutive: 15, totalPacketsSent: 71))

        // With a maximum of zero, chaff only rounds up the total.
        let roundingOnly = Chaff(interval: .milliseconds(20), maximumConsecutiveChaff: 0, roundTotalPacketsTo: 10)
        #expect(roundingOnly.shouldStop(afterConsecutive: 0, totalPacketsSent: 30))
        #expect(!roundingOnly.shouldStop(afterConsecutive: 0, totalPacketsSent: 31))
        #expect(roundingOnly.shouldStop(afterConsecutive: 9, totalPacketsSent: 40))
    }

    @Test("Options differing only in their defenses are not equal")
    func defensesTakePartInEquality() {
        guard #available(Network 0.1.0, *) else { return }

        var padded = QUICConnectionProtocol.Options()
        padded.trafficAnalysisDefenses.padding = .fixedSize(1200)
        var plain = padded
        plain.trafficAnalysisDefenses.padding = nil
        #expect(plain != padded)

        var chaffed = plain
        chaffed.trafficAnalysisDefenses.chaff = .init(interval: .milliseconds(20), maximumConsecutiveChaff: 10)
        #expect(plain != chaffed)

        // Association ignores everything but the transport, as before.
        #expect(plain.isEqual(to: padded, for: .association))
    }

    @Test("A deep copy keeps the defenses")
    func copiesKeepTheDefenses() {
        guard #available(Network 0.1.0, *) else { return }

        var options = QUICConnectionProtocol.Options()
        options.trafficAnalysisDefenses = .init(
            padding: .roundUp(toMultipleOf: 64),
            chaff: .init(
                interval: .milliseconds(20),
                jitter: .milliseconds(5),
                maximumConsecutiveChaff: 10,
                roundTotalPacketsTo: 10
            )
        )
        #expect(options.deepCopy().trafficAnalysisDefenses == options.trafficAnalysisDefenses)
    }

    // MARK: - Padding

    @Test("Padded lengths for each mode")
    func paddedLengths() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Padding = TrafficAnalysisDefenses.Padding

        #expect(Padding.fixedSize(1000).paddedLength(for: 120) == 1000)
        // A packet already larger than the fixed size is left as it is.
        #expect(Padding.fixedSize(1000).paddedLength(for: 1300) == 1300)

        #expect(Padding.roundUp(toMultipleOf: 128).paddedLength(for: 129) == 256)
        // A packet already at a multiple is not grown by another block.
        #expect(Padding.roundUp(toMultipleOf: 128).paddedLength(for: 256) == 256)
        #expect(Padding.roundUp(toMultipleOf: 0).paddedLength(for: 77) == 77)

        for _ in 0..<100 {
            #expect((600...700).contains(Padding.randomSize(600...700).paddedLength(for: 100)))
        }
        #expect(Padding.randomSize(600...700).paddedLength(for: 900) == 900)
    }

    /// Writes into a 1200-byte frame. Returns the bytes written, whether the packet is in flight,
    /// and whether it has an ACK-eliciting frame other than PING.
    @available(Network 0.1.0, *)
    private func write(
        _ pendingItems: consuming PendingItems,
        padding: TrafficAnalysisDefenses.Padding?,
        headerAndTagLength: Int = 30,
        availableCongestionWindow: UInt64 = 10000
    ) -> (written: Int, isInFlightEligible: Bool, wroteNonPingAckElicitingFrame: Bool) {
        var frame = Frame(count: 1200)
        defer { frame.finalize(success: true) }
        let clock = TestClockContext("TrafficAnalysisDefensesTests")
        let connection = clock.onQueue {
            QUICConnection(context: clock.context)
        }
        defer { clock.onQueue { connection.destroyFromExternalTest() } }

        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false
        var shorthandFrames: [QUICShorthandFrame]? = nil
        pendingItems.trafficAnalysisPadding = padding
        pendingItems.headerAndTagLength = headerAndTagLength
        do {
            try pendingItems.write(
                into: &frame,
                connection: connection,
                stats: &connection.stats,
                keyState: .phase0,
                transmittedItems: &transmittedItems,
                availableCongestionWindow: availableCongestionWindow,
                isAckEliciting: &isAckEliciting,
                isInFlightEligible: &isInFlightEligible,
                shorthandFrames: &shorthandFrames
            )
        } catch {
            Issue.record("PendingItems.write threw \(error)")
        }
        return (1200 - frame.unclaimedLength, isInFlightEligible, pendingItems.wroteNonPingAckElicitingFrame)
    }

    /// The bytes written into a 1200-byte frame.
    @available(Network 0.1.0, *)
    private func writtenLength(
        _ pendingItems: consuming PendingItems,
        padding: TrafficAnalysisDefenses.Padding?,
        headerAndTagLength: Int = 30,
        availableCongestionWindow: UInt64 = 10000,
        isInFlightEligible: inout Bool
    ) -> Int {
        let result = write(
            pendingItems,
            padding: padding,
            headerAndTagLength: headerAndTagLength,
            availableCongestionWindow: availableCongestionWindow
        )
        isInFlightEligible = result.isInFlightEligible
        return result.written
    }

    @available(Network 0.1.0, *)
    private func pingOnly() -> PendingItems {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ping = true
        return pendingItems
    }

    @Test("Without padding, a PING packet carries only the minimum payload")
    func noPadding() {
        guard #available(Network 0.1.0, *) else { return }
        var inFlight = false
        let written = writtenLength(pingOnly(), padding: nil, isInFlightEligible: &inFlight)
        #expect(written == Constants.minimumPayloadLength)
    }

    @Test("A packet is padded to the fixed size, header and tag included")
    func fixedSize() {
        guard #available(Network 0.1.0, *) else { return }
        var inFlight = false
        let written = writtenLength(pingOnly(), padding: .fixedSize(1000), isInFlightEligible: &inFlight)
        #expect(written == 1000 - 30)
    }

    @Test("A packet is rounded up to the next multiple")
    func roundUp() {
        guard #available(Network 0.1.0, *) else { return }
        var inFlight = false
        let written = writtenLength(pingOnly(), padding: .roundUp(toMultipleOf: 128), isInFlightEligible: &inFlight)
        #expect(written + 30 == 128)
    }

    @Test("A random size stays in its range")
    func randomSize() {
        guard #available(Network 0.1.0, *) else { return }
        for _ in 0..<20 {
            var inFlight = false
            let written = writtenLength(pingOnly(), padding: .randomSize(600...700), isInFlightEligible: &inFlight)
            #expect((600...700).contains(written + 30))
        }
    }

    @Test("Padding stops at the end of the frame")
    func cappedByFrame() {
        guard #available(Network 0.1.0, *) else { return }
        var inFlight = false
        let written = writtenLength(pingOnly(), padding: .fixedSize(5000), isInFlightEligible: &inFlight)
        #expect(written == 1200)
    }

    @available(Network 0.1.0, *)
    private func ackAndPing() -> PendingItems {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ack = true
        pendingItems.ackFrame = FrameAck(packetNumberSpace: .applicationData, largest: 2000, delay: 42)
        pendingItems.ping = true
        return pendingItems
    }

    @Test("An in-flight packet's padding is held to the congestion window")
    func inFlightCappedByCongestionWindow() {
        guard #available(Network 0.1.0, *) else { return }

        // With room in the window, the packet reaches the full size...
        var roomyInFlight = false
        let roomy = writtenLength(
            ackAndPing(),
            padding: .fixedSize(1000),
            availableCongestionWindow: 10000,
            isInFlightEligible: &roomyInFlight
        )
        #expect(roomy == 1000 - 30)

        // ...but a window smaller than the frame leaves none for padding. The ACK and PING exceed
        // the minimum payload, so nothing else pads the packet.
        var unpaddedInFlight = false
        let unpadded = writtenLength(
            ackAndPing(),
            padding: nil,
            availableCongestionWindow: 200,
            isInFlightEligible: &unpaddedInFlight
        )
        var inFlight = false
        let written = writtenLength(
            ackAndPing(),
            padding: .fixedSize(1000),
            availableCongestionWindow: 200,
            isInFlightEligible: &inFlight
        )
        #expect(inFlight)
        #expect(unpadded > Constants.minimumPayloadLength)
        #expect(written == unpadded)
    }

    @Test("A path challenge padded to the end gets no extra padding")
    func pathChallengeAlreadyPaddedToEnd() {
        guard #available(Network 0.1.0, *) else { return }
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addPathChallenge(FramePathChallenge(data: 1))

        var inFlight = false
        let written = writtenLength(pendingItems, padding: .fixedSize(100), isInFlightEligible: &inFlight)
        #expect(written == 1200)
    }

    @Test("An ACK-only packet is not padded, as it is not ack-eliciting")
    func ackOnlyIsNotPadded() {
        guard #available(Network 0.1.0, *) else { return }
        func ackOnly() -> PendingItems {
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            pendingItems.ack = true
            pendingItems.ackFrame = FrameAck(packetNumberSpace: .applicationData, largest: 2000, delay: 42)
            return pendingItems
        }

        var unpaddedInFlight = false
        let unpadded = writtenLength(ackOnly(), padding: nil, isInFlightEligible: &unpaddedInFlight)
        var inFlight = false
        let written = writtenLength(ackOnly(), padding: .fixedSize(1000), isInFlightEligible: &inFlight)
        #expect(written == unpadded)
        #expect(!inFlight)
    }

    // MARK: - Chaff PING marking

    @Test("A chaff PING stays marked when it is sent")
    func chaffMarkFollowsThePing() {
        guard #available(Network 0.1.0, *) else { return }

        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ping = true
        pendingItems.isChaff = true

        // Sending moves the mark to the packet's record.
        var transmittedItems = TransmittedItems()
        FramePing.addToTransmittedItems(&transmittedItems, from: &pendingItems)
        // #expect cannot capture these non-copyable values, so read them out first.
        let sentIsChaff = transmittedItems.isChaff
        let sentIsKeepalive = transmittedItems.isKeepalive
        let pendingIsChaff = pendingItems.isChaff
        let pendingHasItems = pendingItems.hasPendingItems
        #expect(sentIsChaff)
        #expect(!sentIsKeepalive)
        #expect(!pendingIsChaff)
        #expect(!pendingHasItems)
    }

    @Test("A PING that is not chaff is retransmitted unmarked and unpadded")
    func plainPingStaysPlain() {
        guard #available(Network 0.1.0, *) else { return }

        let clock = TestClockContext("TrafficAnalysisDefensesTests")
        let connection = clock.onQueue {
            QUICConnection(context: clock.context)
        }
        defer { clock.onQueue { connection.destroyFromExternalTest() } }

        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ping = true
        var transmittedItems = TransmittedItems()
        FramePing.addToTransmittedItems(&transmittedItems, from: &pendingItems)
        let sentIsChaff = transmittedItems.isChaff
        #expect(!sentIsChaff)

        var retransmission = PendingItems(packetNumberSpace: .applicationData)
        FramePing.addToPendingItems(&retransmission, from: transmittedItems, connection: connection)
        let retransmitsPing = retransmission.ping
        let retransmitsChaff = retransmission.isChaff
        let retransmittedPadding = retransmission.paddingApproach
        #expect(retransmitsPing)
        #expect(!retransmitsChaff)
        #expect(retransmittedPadding == .none)
    }

    // MARK: - Serialization

    /// The defenses after a trip through the QUIC options' serialized form.
    @available(Network 0.1.0, *)
    private func roundTripped(
        _ defenses: TrafficAnalysisDefenses
    ) -> TrafficAnalysisDefenses? {
        let options = QUICStreamProtocol.QUICStreamOptions()
        options.modifyQUICConnectionOptions { $0.trafficAnalysisDefenses = defenses }
        guard let bytes = options.serialize() else { return nil }
        return QUICStreamProtocol.QUICStreamOptions(from: bytes)?.quicConnectionOptions.trafficAnalysisDefenses
    }

    @Test("Every padding mode, and none, survives serialization")
    func paddingSurvivesSerialization() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Defenses = TrafficAnalysisDefenses

        let paddings: [Defenses.Padding?] = [
            nil, .fixedSize(1200), .roundUp(toMultipleOf: 128), .randomSize(600...1200),
        ]
        for padding in paddings {
            let defenses = Defenses(padding: padding)
            #expect(roundTripped(defenses) == defenses)
        }
    }

    @Test("Chaff, and no chaff, survives serialization")
    func chaffSurvivesSerialization() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Defenses = TrafficAnalysisDefenses

        #expect(roundTripped(Defenses()) == Defenses())
        let both = Defenses(
            padding: .fixedSize(1100),
            chaff: .init(
                interval: .milliseconds(250),
                jitter: .milliseconds(50),
                maximumConsecutiveChaff: 5,
                roundTotalPacketsTo: 10
            )
        )
        #expect(roundTripped(both) == both)
    }

    @Test("The fields after the defenses still read back")
    func laterFieldsStillReadBack() {
        guard #available(Network 0.1.0, *) else { return }

        var options = QUICStreamProtocol.QUICStreamOptions()
        options.associatedStreamID = 42
        options.modifyQUICConnectionOptions {
            $0.pqtlsMode = 3
            $0.sourceConnectionID = [1, 2, 3, 4]
            $0.trafficAnalysisDefenses = .init(
                padding: .randomSize(600...1200),
                chaff: .init(interval: .milliseconds(250), maximumConsecutiveChaff: 5)
            )
        }
        guard let bytes = options.serialize(), let restored = QUICStreamProtocol.QUICStreamOptions(from: bytes) else {
            Issue.record("the options should serialize and read back")
            return
        }
        #expect(restored.associatedStreamID == 42)
        #expect(restored.quicConnectionOptions.pqtlsMode == 3)
        #expect(restored.quicConnectionOptions.sourceConnectionID == [1, 2, 3, 4])
    }

    @Test("The serialized form is as long as it says, and bytes that do not parse read as no defenses")
    func serializedLengthAndBadBytes() {
        guard #available(Network 0.1.0, *) else { return }
        typealias Defenses = TrafficAnalysisDefenses

        let defenses = Defenses(
            padding: .randomSize(600...1200),
            chaff: .init(interval: .milliseconds(250), maximumConsecutiveChaff: 5)
        )
        let bytes = defenses.serializedBytes
        #expect(bytes.count == Defenses.serializedLength)
        #expect(Defenses(serializedBytes: bytes) == defenses)

        // Too short to parse.
        #expect(Defenses(serializedBytes: Array(bytes.prefix(5))) == Defenses())
        // An unknown padding mode reads as no padding; the chaff after it still reads.
        var unknownMode = bytes
        unknownMode[0] = 9
        let read = Defenses(serializedBytes: unknownMode)
        #expect(read.padding == nil)
        #expect(read.chaff == defenses.chaff)
    }

    // MARK: - Real activity

    @Test("Only a packet with an ACK-eliciting frame other than PING is real activity")
    func realActivity() {
        guard #available(Network 0.1.0, *) else { return }

        // A PING alone: chaff, a keep-alive, or a loss probe.
        #expect(!write(pingOnly(), padding: nil).wroteNonPingAckElicitingFrame)

        // An ACK alone.
        var ackOnly = PendingItems(packetNumberSpace: .applicationData)
        ackOnly.ack = true
        ackOnly.ackFrame = FrameAck(packetNumberSpace: .applicationData, largest: 2000, delay: 42)
        #expect(!write(ackOnly, padding: nil).wroteNonPingAckElicitingFrame)

        // A real frame, alone or carried with a chaff PING left pending.
        var real = PendingItems(packetNumberSpace: .applicationData)
        real.handshakeDone = true
        #expect(write(real, padding: nil).wroteNonPingAckElicitingFrame)

        var realWithChaff = PendingItems(packetNumberSpace: .applicationData)
        realWithChaff.handshakeDone = true
        realWithChaff.ping = true
        realWithChaff.isChaff = true
        #expect(write(realWithChaff, padding: nil).wroteNonPingAckElicitingFrame)
    }

    // MARK: - Connection state

    /// A fixed instant to measure from; the state only compares instants.
    @available(Network 0.1.0, *)
    private var start: NetworkClock.Instant { NetworkClock.Instant.zero.advanced(by: .seconds(10)) }

    @available(Network 0.1.0, *)
    private func state(
        padding: TrafficAnalysisDefenses.Padding? = nil,
        chaff: TrafficAnalysisDefenses.Chaff? = nil
    ) -> TrafficAnalysisState {
        var state = TrafficAnalysisState()
        state.configure(.init(padding: padding, chaff: chaff))
        return state
    }

    @Test("Padding applies to application data only, and not to probes or an unvalidated server")
    func paddingSelection() {
        guard #available(Network 0.1.0, *) else { return }
        let padded = state(padding: .fixedSize(1100))

        // #expect cannot capture the non-copyable state, so each result is read out first.
        let applicationData = padded.padding(for: .applicationData, isPMTUDProbe: false, isUnvalidatedServer: false)
        let initial = padded.padding(for: .initial, isPMTUDProbe: false, isUnvalidatedServer: false)
        let handshake = padded.padding(for: .handshake, isPMTUDProbe: false, isUnvalidatedServer: false)
        let probe = padded.padding(for: .applicationData, isPMTUDProbe: true, isUnvalidatedServer: false)
        let unvalidated = padded.padding(for: .applicationData, isPMTUDProbe: false, isUnvalidatedServer: true)
        let unconfigured = state().padding(for: .applicationData, isPMTUDProbe: false, isUnvalidatedServer: false)
        #expect(applicationData == .fixedSize(1100))
        #expect(initial == nil)
        #expect(handshake == nil)
        #expect(probe == nil)
        #expect(unvalidated == nil)
        #expect(unconfigured == nil)
    }

    @Test("Chaff starts only when configured, a full interval after the start")
    func chaffStart() {
        guard #available(Network 0.1.0, *) else { return }

        var off = state()
        let offDelay = off.startChaff(now: start)
        let offEnabled = off.isChaffEnabled
        #expect(offDelay == nil)
        #expect(!offEnabled)

        var on = state(chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 3))
        let onDelay = on.startChaff(now: start)
        let onEnabled = on.isChaffEnabled
        #expect(onDelay == .milliseconds(100))
        #expect(onEnabled)
    }

    @Test("A packet sent while the timer was armed pushes chaff back by what is left of the delay")
    func chaffPushedBack() {
        guard #available(Network 0.1.0, *) else { return }
        var chaffing = state(chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 3))
        _ = chaffing.startChaff(now: start)

        // An ACK 60ms in: the timer fires 40ms after it, and waits the other 60ms.
        let ackTime = start.advanced(by: .milliseconds(60))
        let restart = chaffing.notePacketSent(isActivity: false, carriesChaff: false, now: ackTime)
        #expect(restart == nil)
        let action = chaffing.chaffTimerFired(
            now: start.advanced(by: .milliseconds(100)),
            isSendPending: false,
            totalPacketsSent: 10
        )
        guard case .reschedule(let delay) = action else {
            Issue.record("expected a reschedule, got \(action)")
            return
        }
        #expect(delay == .milliseconds(60))
    }

    @Test("Chaff waits a round while real data is waiting")
    func chaffWaitsForRealData() {
        guard #available(Network 0.1.0, *) else { return }
        var chaffing = state(chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 3))
        _ = chaffing.startChaff(now: start)

        let action = chaffing.chaffTimerFired(
            now: start.advanced(by: .milliseconds(100)),
            isSendPending: true,
            totalPacketsSent: 10
        )
        guard case .reschedule(let delay) = action else {
            Issue.record("expected a reschedule, got \(action)")
            return
        }
        let consecutive = chaffing.consecutiveChaffSent
        #expect(delay == .milliseconds(100))
        #expect(consecutive == 0)
    }

    @Test("Chaff is counted as it goes out, and stops at the maximum")
    func chaffSendsAndCounts() {
        guard #available(Network 0.1.0, *) else { return }
        var chaffing = state(chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 2))
        _ = chaffing.startChaff(now: start)
        var now = start.advanced(by: .milliseconds(100))

        guard case .send = chaffing.chaffTimerFired(now: now, isSendPending: false, totalPacketsSent: 10) else {
            Issue.record("expected a send")
            return
        }
        // A send that sent nothing leaves the count as it was...
        guard case .reschedule = chaffing.chaffSent(now: now, totalPacketsSent: 10) else {
            Issue.record("expected a reschedule")
            return
        }
        let consecutiveAfterNothingSent = chaffing.consecutiveChaffSent
        #expect(consecutiveAfterNothingSent == 0)

        // ...and the chaff PING counts when it goes out, with a later packet.
        _ = chaffing.notePacketSent(isActivity: false, carriesChaff: true, now: now)
        let consecutiveAfterLateChaff = chaffing.consecutiveChaffSent
        #expect(consecutiveAfterLateChaff == 1)

        // A packet without chaff, such as an ACK, does not count.
        _ = chaffing.notePacketSent(isActivity: false, carriesChaff: false, now: now)
        let consecutiveAfterAck = chaffing.consecutiveChaffSent
        #expect(consecutiveAfterAck == 1)

        // The second chaff reaches the maximum, and chaff stops.
        now = now.advanced(by: .milliseconds(100))
        _ = chaffing.notePacketSent(isActivity: false, carriesChaff: true, now: now)
        guard case .stop = chaffing.chaffSent(now: now, totalPacketsSent: 12) else {
            Issue.record("expected a stop")
            return
        }
        let consecutiveAtStop = chaffing.consecutiveChaffSent
        #expect(consecutiveAtStop == 2)
    }

    @Test("Chaff carried with real activity is not counted as chaff")
    func chaffWithRealActivity() {
        guard #available(Network 0.1.0, *) else { return }
        var chaffing = state(chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 3))
        _ = chaffing.startChaff(now: start)
        _ = chaffing.notePacketSent(isActivity: false, carriesChaff: true, now: start)
        _ = chaffing.notePacketSent(isActivity: true, carriesChaff: true, now: start)
        let consecutive = chaffing.consecutiveChaffSent
        #expect(consecutive == 0)
    }

    @Test("With a maximum of zero, chaff stops before sending when the total is already rounded")
    func chaffMaximumOfZero() {
        guard #available(Network 0.1.0, *) else { return }
        var chaffing = state(
            chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 0, roundTotalPacketsTo: 10)
        )
        _ = chaffing.startChaff(now: start)
        let action = chaffing.chaffTimerFired(
            now: start.advanced(by: .milliseconds(100)),
            isSendPending: false,
            totalPacketsSent: 30
        )
        guard case .stop = action else {
            Issue.record("expected a stop, got \(action)")
            return
        }
    }

    @Test("Only real activity restarts stopped chaff, from a count of zero")
    func chaffRestart() {
        guard #available(Network 0.1.0, *) else { return }
        var chaffing = state(chaff: .init(interval: .milliseconds(100), maximumConsecutiveChaff: 1))
        _ = chaffing.startChaff(now: start)
        var now = start.advanced(by: .milliseconds(100))
        _ = chaffing.chaffTimerFired(now: now, isSendPending: false, totalPacketsSent: 10)
        _ = chaffing.notePacketSent(isActivity: false, carriesChaff: true, now: now)
        guard case .stop = chaffing.chaffSent(now: now, totalPacketsSent: 11) else {
            Issue.record("expected a stop")
            return
        }

        // An ACK, or a PING, does not restart it...
        now = now.advanced(by: .seconds(1))
        let afterAck = chaffing.notePacketSent(isActivity: false, carriesChaff: false, now: now)
        #expect(afterAck == nil)
        // ...real activity does, a full interval later.
        let afterActivity = chaffing.notePacketSent(isActivity: true, carriesChaff: false, now: now)
        let consecutive = chaffing.consecutiveChaffSent
        #expect(afterActivity == .milliseconds(100))
        #expect(consecutive == 0)
        // And only once: chaff is running again.
        let afterMoreActivity = chaffing.notePacketSent(isActivity: true, carriesChaff: false, now: now)
        #expect(afterMoreActivity == nil)
    }

    @Test("Chaff is a PING marked as chaff, padded to the end only without the padding defense")
    func queuedChaff() {
        guard #available(Network 0.1.0, *) else { return }

        var unpadded = PendingItems(packetNumberSpace: .applicationData)
        state().queueChaff(into: &unpadded)
        let unpaddedPing = unpadded.ping
        let unpaddedIsChaff = unpadded.isChaff
        let unpaddedApproach = unpadded.paddingApproach
        #expect(unpaddedPing)
        #expect(unpaddedIsChaff)
        #expect(unpaddedApproach == .padToEnd)

        // With padding configured, it is padded like any other packet when it is written.
        var padded = PendingItems(packetNumberSpace: .applicationData)
        state(padding: .fixedSize(1100)).queueChaff(into: &padded)
        let paddedIsChaff = padded.isChaff
        let paddedApproach = padded.paddingApproach
        #expect(paddedIsChaff)
        #expect(paddedApproach == .none)
    }
}

#endif
