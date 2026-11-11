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
final class SendItemsTests: XCTestCase {

    /// `PendingItems.write` finds the next item to send from the flags, so each flag has to sit at the
    /// bit that is its item's sending priority. The flags are built from `PrioritizedSendableItems`, so this
    /// checks that each one was built from the right item.
    func testPresentItemsMaskFollowsSendingPriority() {
        let setters: [(PrioritizedSendableItems, (inout PendingItems) -> Void)] = [
            (.crypto, { $0.sendCrypto = true }),
            (.newToken, { $0.newToken = true }),
            (.newConnectionID, { $0.newConnectionID = true }),
            (.retireConnectionID, { $0.retireConnectionID = true }),
            (.pathChallenge, { $0.pathChallenge = true }),
            (.pathResponse, { $0.pathResponse = true }),
            (.handshakeDone, { $0.handshakeDone = true }),
            (.ack, { $0.ack = true }),
            (.ping, { $0.ping = true }),
            (.datagram, { $0.datagram = true }),
            (.dataBlocked, { $0.dataBlocked = true }),
            (.streamDataBlocked, { $0.streamDataBlocked = true }),
            (.streamsBlockedBidirectional, { $0.streamsBlockedBidirectional = true }),
            (.streamsBlockedUnidirectional, { $0.streamsBlockedUnidirectional = true }),
            (.maxData, { $0.maxData = true }),
            (.maxStreamData, { $0.maxStreamData = true }),
            (.maxStreamsBidirectional, { $0.maxStreamsBidirectional = true }),
            (.maxStreamsUnidirectional, { $0.maxStreamsUnidirectional = true }),
            (.stream, { $0.stream = true }),
            (.resetStream, { $0.resetStream = true }),
            (.stopSending, { $0.stopSendingFlag = true }),
            (.connectionClose, { $0.connectionClose = true }),
            (.applicationClose, { $0.applicationClose = true }),
            (.padding, { $0.paddingApproach = .padToEnd }),
        ]
        XCTAssertEqual(setters.count, PrioritizedSendableItems.allCases.count)
        for (item, set) in setters {
            let priority = PrioritizedSendableItems.allCases.firstIndex(of: item)!
            XCTAssertEqual(item.rawValue, priority, "\(item)")
            XCTAssertEqual(item.flag?.rawValue ?? item.maskBit, item.maskBit, "\(item)")
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            XCTAssertEqual(pendingItems.presentItemsMask, 0)
            set(&pendingItems)
            XCTAssertEqual(pendingItems.presentItemsMask, UInt32(1) << UInt32(priority), "\(item)")
        }

        // The keepalive marker is not an item
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.isKeepalive = true
        XCTAssertEqual(pendingItems.presentItemsMask, 0)
    }

    func testHasFrames() {
        var pendingItems = PendingItems(packetNumberSpace: .initial)
        XCTAssertFalse(pendingItems.hasPendingItems)

        pendingItems.ping = true
        XCTAssertTrue(pendingItems.hasPendingItems)
    }

    func testHasAckElicitingFrame() {
        var pendingItems = PendingItems(packetNumberSpace: .initial)
        XCTAssertFalse(pendingItems.hasAckElicitingPendingItems)

        // all ack, padding, app close and connection close packets are not ack eliciting
        let ackFrame = FrameAck(packetNumberSpace: .initial, largest: 128, delay: 10)
        pendingItems.setAckFrame(.ack(frame: ackFrame), ping: false)
        XCTAssertFalse(pendingItems.hasAckElicitingPendingItems)

        pendingItems.paddingApproach = .fixedSize(1)
        XCTAssertFalse(pendingItems.hasAckElicitingPendingItems)

        // ping is ack eliciting
        pendingItems.ping = true
        XCTAssertTrue(pendingItems.hasAckElicitingPendingItems)
    }

    func runPendingItemsTest(
        _ pendingItems: consuming PendingItems,
        transmittedItems: inout TransmittedItems,
        isAckEliciting: inout Bool,
        isInFlightEligible: inout Bool
    ) {
        var frame = Frame(count: 1200)
        defer { frame.finalize(success: true) }
        let clock = TestClockContext("SendItemsTests")
        let connection = clock.onQueue {
            QUICConnection(context: clock.context)
        }
        defer { clock.onQueue { connection.destroyFromExternalTest() } }
        var shorthandFrames: [QUICShorthandFrame]? = nil
        XCTAssertNoThrow(
            try pendingItems.write(
                into: &frame,
                connection: connection,
                stats: &connection.stats,
                keyState: .phase0,
                transmittedItems: &transmittedItems,
                availableCongestionWindow: 10000,
                isAckEliciting: &isAckEliciting,
                isInFlightEligible: &isInFlightEligible,
                shorthandFrames: &shorthandFrames
            )
        )

    }

    func testPendingItems_ACK() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ack = true
        pendingItems.ackFrame = FrameAck(
            packetNumberSpace: .applicationData,
            largest: 2000,
            delay: 42
        )
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false

        runPendingItemsTest(
            pendingItems,
            transmittedItems: &transmittedItems,
            isAckEliciting: &isAckEliciting,
            isInFlightEligible: &isInFlightEligible
        )

        XCTAssertFalse(isAckEliciting)
        XCTAssertFalse(isInFlightEligible)

        XCTAssertTrue(transmittedItems.ackFrame != nil)
        let largest = transmittedItems.ackFrame?.largest
        let delay = transmittedItems.ackFrame?.delay
        XCTAssertEqual(largest, 2000)
        XCTAssertEqual(delay, 42)
    }

    func testPendingItems_PADDING() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.paddingApproach = .fixedSize(100)
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false

        runPendingItemsTest(
            pendingItems,
            transmittedItems: &transmittedItems,
            isAckEliciting: &isAckEliciting,
            isInFlightEligible: &isInFlightEligible
        )

        XCTAssertFalse(isAckEliciting)
        XCTAssertTrue(isInFlightEligible)
    }

    func testPendingItems_PING() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.ping = true
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false

        runPendingItemsTest(
            pendingItems,
            transmittedItems: &transmittedItems,
            isAckEliciting: &isAckEliciting,
            isInFlightEligible: &isInFlightEligible
        )

        XCTAssertTrue(isAckEliciting)
        XCTAssertTrue(isInFlightEligible)

        XCTAssertTrue(transmittedItems.ping)
    }

    func testRetireConnectionID_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addRetireConnectionID(FrameRetireConnectionID(sequence: 0))
        pendingItems.addRetireConnectionID(FrameRetireConnectionID(sequence: 1))

        var transmittedItems = TransmittedItems()
        FrameRetireConnectionID.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.retireConnectionIDs.count, 1)
        XCTAssertEqual(transmittedItems.retireConnectionIDs?.count ?? 0, 1)
        XCTAssertEqual(
            pendingItems.retireConnectionID,
            !pendingItems.retireConnectionIDs.isEmpty,
            "PendingItems.retireConnectionID flag must mirror retireConnectionIDs deque emptiness"
        )
    }

    func testPathChallenge_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addPathChallenge(FramePathChallenge(data: 1))
        pendingItems.addPathChallenge(FramePathChallenge(data: 2))

        var transmittedItems = TransmittedItems()
        FramePathChallenge.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.pathChallenges.count, 1)
        XCTAssertEqual(
            pendingItems.pathChallenge,
            !pendingItems.pathChallenges.isEmpty,
            "PendingItems.pathChallenge flag must mirror pathChallenges deque emptiness"
        )
    }

    func testPathResponse_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addPathResponse(FramePathResponse(data: 1))
        pendingItems.addPathResponse(FramePathResponse(data: 2))

        var transmittedItems = TransmittedItems()
        FramePathResponse.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.pathResponses.count, 1)
        XCTAssertEqual(
            pendingItems.pathResponse,
            !pendingItems.pathResponses.isEmpty,
            "PendingItems.pathResponse flag must mirror pathResponses deque emptiness"
        )
    }

    func testStreamReset_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addStreamReset(streamID: 0, code: 0, finalSize: 1000)
        pendingItems.addStreamReset(streamID: 4, code: 0, finalSize: 1000)

        var transmittedItems = TransmittedItems()
        FrameResetStream.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.streamResets.count, 1)
        XCTAssertEqual(transmittedItems.streamResets?.count ?? 0, 1)
        XCTAssertEqual(
            pendingItems.resetStream,
            !pendingItems.streamResets.isEmpty,
            "PendingItems.resetStream flag must mirror streamResets deque emptiness"
        )
    }

    func testStopSending_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.addStreamStopSending(streamID: 0, code: 0)
        pendingItems.addStreamStopSending(streamID: 4, code: 0)

        var transmittedItems = TransmittedItems()
        FrameStopSending.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.streamStopSendings.count, 1)
        XCTAssertEqual(transmittedItems.streamStopSendings?.count ?? 0, 1)
        XCTAssertEqual(
            pendingItems.stopSendingFlag,
            !pendingItems.streamStopSendings.isEmpty,
            "PendingItems.stopSendingFlag must mirror streamStopSendings deque emptiness"
        )
    }

    func testStreamDataBlocked_pendingFlagMirrorsDequeAfterPartialDequeue() {
        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.appendStreamDataBlockedFlow(MultiplexedFlowIdentifier(testValue: 1))
        pendingItems.appendStreamDataBlockedFlow(MultiplexedFlowIdentifier(testValue: 2))

        var transmittedItems = TransmittedItems()
        FrameStreamDataBlocked.addToTransmittedItems(
            &transmittedItems,
            from: &pendingItems
        )

        XCTAssertEqual(pendingItems.streamDataBlockedFlows.count, 1)
        XCTAssertEqual(transmittedItems.streamDataBlockedFlows?.count ?? 0, 1)
        XCTAssertEqual(
            pendingItems.streamDataBlocked,
            !pendingItems.streamDataBlockedFlows.isEmpty,
            "PendingItems.streamDataBlocked flag must mirror streamDataBlockedFlows deque emptiness"
        )
    }

    struct DatagramWriteOutcome {
        var thrownError: QUICError?
        var wroteFrame = false
        var stillQueued = 0
        var flowsToService = 0
        var datagramsWritten = 0
        var bytesWritten = 0
        var framedSize = 0
    }

    // Queues `queued` identical datagrams on a fresh flow, then writes into a packet sized
    // to hold exactly `roomFor` of them and fall one byte short of the next — what a
    // co-resident frame such as an ACK does to an otherwise exactly-sized datagram.
    // `usableDatagramSize` is a maximum payload and excludes the DATAGRAM frame header, so
    // every queued payload is sendable as far as the flow is concerned, except the one at
    // `oversizedAtIndex`, which is a byte beyond it.
    //
    // With `onFinalize`, each queued datagram is a frame whose finalizer runs it, which is how a
    // sender-supplied finalizer behaves.
    func writeDatagrams(
        queued: Int,
        roomFor: Int,
        oversizedAtIndex: Int? = nil,
        onFinalize: ((QUICConnection, MultiplexedFlowIdentifier) -> Void)? = nil
    ) -> DatagramWriteOutcome {
        let clock = TestClockContext("SendItemsTests")
        let connection = clock.onQueue {
            QUICConnection(context: clock.context)
        }
        let flowID: UInt64 = 4
        let contextID: UInt64 = 0
        let flowIdentifier = clock.onQueue { () -> MultiplexedFlowIdentifier in
            var flow = QUICDatagramFlow(parent: connection, inbound: true)
            flow.setup(datagramFlowID: flowID, contextID: contextID, logPrefixer: LogPrefixer())
            let flowIdentifier = flow.flowIdentifier
            connection.insertSecondaryFlow(flow, for: flowIdentifier)
            return flowIdentifier
        }
        defer {
            clock.onQueue {
                connection.fromExternal { eventContext in
                    if var flow = connection.removeSecondaryFlow(flowIdentifier) {
                        flow.upperSendQueue.finalizeAllFramesAsFailed()
                        flow.unregisterEventManager(in: &eventContext)
                    }
                }
                connection.destroyFromExternalTest()
            }
        }

        let payload = [UInt8](repeating: 0xAB, count: 256)
        connection.withSecondaryFlow(flowIdentifier) { (flow: inout QUICDatagramFlow) in
            flow.usableDatagramSize = payload.count
            for index in 0..<queued {
                let count = index == oversizedAtIndex ? payload.count + 1 : payload.count
                if let onFinalize {
                    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
                    buffer.initializeMemory(as: UInt8.self, repeating: 0xAB)
                    flow.upperSendQueue.add(
                        frame: Frame(
                            buffer: buffer,
                            finalizer: { buffer in
                                buffer.deallocate()
                                onFinalize(connection, flowIdentifier)
                            }
                        )
                    )
                } else {
                    flow.upperSendQueue.add(frame: Frame(copyBuffer: [UInt8](repeating: 0xAB, count: count)))
                }
            }
        }

        // The length field already covers the flow and context IDs alongside the payload.
        let length = FrameDatagram.length(
            dataLength: UInt64(payload.count),
            flowID: flowID,
            contextID: contextID
        )
        let framedSize =
            FrameType.datagram(hasLength: true).rawValue.variableLengthSize
            + length.variableLengthSize
            + Int(length)

        var packet = Frame(count: (roomFor + 1) * framedSize - 1)
        defer { packet.finalize(success: true) }
        let roomBeforeWriting = packet.unclaimedLength

        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        pendingItems.prependDatagramFlowToService(flowIdentifier)
        var transmittedItems = TransmittedItems()
        var availableCongestionWindow: UInt64 = 10000
        var shorthandFrames: [QUICShorthandFrame]? = nil

        var outcome = DatagramWriteOutcome()
        do {
            outcome.wroteFrame = try FrameDatagram.write(
                into: &packet,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &connection.stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        } catch {
            outcome.thrownError = error
        }

        connection.accessDatagramsToSend(flow: flowIdentifier) { outcome.stillQueued = $0.count }
        outcome.flowsToService = pendingItems.datagramFlowsToService.count
        outcome.datagramsWritten = connection.stats[.txDatagramFrameWithLength]
        outcome.bytesWritten = roomBeforeWriting - packet.unclaimedLength
        outcome.framedSize = framedSize
        return outcome
    }

    // A frame's finalizer is a closure the sender supplied. The write must not run it while the flow is
    // borrowed from the secondary flow table, or a finalizer that looks at the table overlaps the
    // borrow. Both ways a datagram is finished are covered: dropped for being too large, and written.
    func testDatagram_finalizersRunAfterTheFlowBorrowEnds() {
        final class Observations: @unchecked Sendable {
            var flowWasVisible = [Bool]()
        }
        let observations = Observations()

        let outcome = writeDatagrams(
            queued: 2,
            roomFor: 1,
            oversizedAtIndex: 0,
            onFinalize: { connection, flowIdentifier in
                // Looking a flow up is an access to the table that the write would be holding
                observations.flowWasVisible.append(connection.hasSecondaryFlow(flowIdentifier))
            }
        )

        XCTAssertNil(outcome.thrownError)
        XCTAssertTrue(outcome.wroteFrame)
        XCTAssertEqual(outcome.datagramsWritten, 1)
        // One finalizer for the datagram that was too large, one for the datagram that was written,
        // and each found the flow still in the table
        XCTAssertEqual(observations.flowWasVisible, [true, true])
    }

    func testDatagram_requeuedAndReportedFullWhenItDoesNotFit() {
        let outcome = writeDatagrams(queued: 1, roomFor: 0)

        guard case .frameWrite(.smallBuffer)? = outcome.thrownError else {
            return XCTFail(
                "A datagram that does not fit must report a full packet so the caller flushes it, "
                    + "got \(String(describing: outcome.thrownError))"
            )
        }
        // DATAGRAM frames are never retransmitted, so finalizing one as sent without
        // writing it to the wire loses it outright.
        XCTAssertEqual(outcome.stillQueued, 1, "The datagram that did not fit must stay queued")
        XCTAssertEqual(
            outcome.flowsToService,
            1,
            "The flow must stay scheduled so the requeued datagram is serviced again"
        )
    }

    func testDatagram_writtenDatagramIsReportedWhenALaterOneDoesNotFit() {
        let outcome = writeDatagrams(queued: 2, roomFor: 1)

        // The caller reads a throw as "no frame written", so a datagram that did fit has to
        // be reported by returning: throwing would leave it out of the packet's
        // ack-eliciting and in-flight-eligible accounting.
        XCTAssertNil(outcome.thrownError, "A datagram that fits must not report a full packet")
        XCTAssertTrue(outcome.wroteFrame, "The first datagram fits and must be reported as written")
        XCTAssertEqual(outcome.stillQueued, 1, "The datagram that did not fit must stay queued")
    }

    func testDatagram_oversizedDatagramIsDroppedWithoutBlockingLaterDatagrams() {
        // Three queued with room for all three, the middle one a byte over the flow's
        // maximum payload.
        let outcome = writeDatagrams(queued: 3, roomFor: 3, oversizedAtIndex: 1)

        // A datagram too large to ever fit is dropped rather than requeued, so it cannot
        // head-of-line block the flow: the datagram queued behind it is still written, and
        // the flow drains.
        XCTAssertNil(outcome.thrownError, "Dropping an oversized datagram is not a full packet")
        XCTAssertTrue(outcome.wroteFrame)
        XCTAssertEqual(outcome.datagramsWritten, 2, "Only the two sendable datagrams are written")
        XCTAssertEqual(
            outcome.bytesWritten,
            2 * outcome.framedSize,
            "The oversized datagram must contribute no bytes to the packet"
        )
        XCTAssertEqual(outcome.stillQueued, 0, "Nothing may be left queued behind the drop")
        XCTAssertEqual(outcome.flowsToService, 0, "The drained flow must be descheduled")
    }

    // MARK: - Connection-level flow control

    // Registers a stream holding `bytes` of unsent data, then writes `pendingItems` into one packet
    // while the connection has used up the peer's MAX_DATA. `configure` queues items once the stream
    // exists; `inspect` sees what the packet carried.
    func writeWhileDataBlocked(
        bytes: Int,
        configure: (inout PendingItems, MultiplexedFlowIdentifier) -> Void,
        inspect: (borrowing TransmittedItems, _ isAckEliciting: Bool) -> Void
    ) -> QUICError? {
        let clock = TestClockContext("SendItemsTests")
        let connection = clock.onQueue {
            QUICConnection(context: clock.context)
        }
        let flowID = clock.onQueue { () -> MultiplexedFlowIdentifier in
            var stream = QUICStreamInstance(parent: connection, inbound: false)
            stream.setup(streamID: QUICStreamID(0), logPrefixer: LogPrefixer())
            stream.outboundStreamReady()
            stream.send.buffer.addSendData(
                Frame(copyBuffer: [UInt8](repeating: 0xAB, count: bytes)),
                isLast: false
            )
            let flowID = stream.flowIdentifier
            // The connection owns the stream from here on
            stream.destroyFromExternalTest()
            connection.insertFlow(stream, for: flowID)
            return flowID
        }
        defer {
            clock.onQueue {
                if var stream = connection.removeFlow(flowID) {
                    stream.send.buffer.empty()
                }
                connection.destroyFromExternalTest()
            }
        }

        // Everything the peer allowed has been sent and DATA_BLOCKED has gone out
        XCTAssertEqual(connection.flowControlState.remainingOutboundBytesAllowed, 0)
        connection.hasSentDataBlocked = true

        var pendingItems = PendingItems(packetNumberSpace: .applicationData)
        configure(&pendingItems, flowID)

        var frame = Frame(count: 1200)
        defer { frame.finalize(success: true) }
        var transmittedItems = TransmittedItems()
        var isAckEliciting = false
        var isInFlightEligible = false
        var shorthandFrames: [QUICShorthandFrame]? = nil
        var thrownError: QUICError?
        // The packet builder borrows streams, which only the send path may do
        let wasActive = connection.deferredWork.claimSendPath()
        defer { connection.deferredWork.releaseSendPath(wasActive: wasActive) }
        do {
            try pendingItems.write(
                into: &frame,
                connection: connection,
                stats: &connection.stats,
                keyState: .phase0,
                transmittedItems: &transmittedItems,
                availableCongestionWindow: 10000,
                isAckEliciting: &isAckEliciting,
                isInFlightEligible: &isInFlightEligible,
                shorthandFrames: &shorthandFrames
            )
        } catch {
            thrownError = error
        }
        inspect(transmittedItems, isAckEliciting)
        return thrownError
    }

    // A stream that cannot send because of connection flow control must not keep the frames queued
    // after STREAM out of the packet. Otherwise RESET_STREAM waits for a MAX_DATA that a peer which
    // is not reading may never send.
    func testDataBlockedStreamDoesNotHoldBackResetStream() {
        var streamResets = 0
        let error = writeWhileDataBlocked(
            bytes: 100,
            configure: { pendingItems, flowID in
                pendingItems.streamsToService.append(flowID)
                pendingItems.stream = true
                pendingItems.addStreamReset(streamID: 4, code: 0, finalSize: 0)
            },
            inspect: { transmittedItems, _ in
                streamResets = transmittedItems.streamResets?.count ?? 0
            }
        )
        XCTAssertNil(error, "RESET_STREAM fits, so the packet is not empty")
        XCTAssertEqual(streamResets, 1, "RESET_STREAM must be sent while the connection is data-blocked")
    }

    // Flow control limits the highest offset sent, which a retransmission does not raise. Holding
    // retransmissions back while blocked can deadlock: the peer cannot read past the lost data, so it
    // never consumes enough to send the MAX_DATA that would unblock us.
    func testDataBlockedConnectionStillRetransmitsStreamData() {
        var retransmittedLength: UInt64 = 0
        let error = writeWhileDataBlocked(
            bytes: 100,
            configure: { pendingItems, flowID in
                pendingItems.retransmitStreams.append(
                    TransmittedItems.SentStream(
                        flowID: flowID,
                        streamID: QUICStreamID(0),
                        offset: 0,
                        length: 100,
                        isFinal: false
                    )
                )
                pendingItems.stream = true
            },
            inspect: { transmittedItems, _ in
                for index in 0..<transmittedItems.sentStreams.count {
                    retransmittedLength += transmittedItems.sentStreams[index].length
                }
            }
        )
        XCTAssertNil(error)
        XCTAssertEqual(retransmittedLength, 100, "Lost stream data must be retransmitted while data-blocked")
    }

    // A stream that is dropped for lack of credit writes nothing, so a packet that otherwise only
    // carries an ACK must stay out of ack-eliciting and retransmission accounting.
    func testDataBlockedStreamAddsNothingToAnAckOnlyPacket() {
        var isAckEliciting = true
        var carriesStream = true
        var retransmissible = true
        let error = writeWhileDataBlocked(
            bytes: 100,
            configure: { pendingItems, flowID in
                pendingItems.setAckFrame(
                    .ack(frame: FrameAck(packetNumberSpace: .applicationData, largest: 10, delay: 0)),
                    ping: false
                )
                pendingItems.streamsToService.append(flowID)
                pendingItems.stream = true
            },
            inspect: { transmittedItems, ackEliciting in
                isAckEliciting = ackEliciting
                carriesStream = transmittedItems.stream
                retransmissible = transmittedItems.hasRetransmissibleItems
            }
        )
        XCTAssertNil(error)
        XCTAssertFalse(isAckEliciting, "A packet with only an ACK is not ack-eliciting")
        XCTAssertFalse(carriesStream)
        XCTAssertFalse(retransmissible)
    }

}

#endif
