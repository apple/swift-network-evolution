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
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// MARK: - Sendable Items (Per-Frame Sending Logic)

@available(Network 0.1.0, *)
protocol SendableItem: ~Copyable {
    static var frameType: FrameType { get }
    static var isRepeatable: Bool { get }  // More than one of this frame can be in one packet
    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    )

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    )

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError)
}

@available(Network 0.1.0, *)
extension SendableItem where Self: ~Copyable {
    static var isRepeatable: Bool { false }  // Default to false for most frames

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        availableCongestionWindow: inout UInt64,
        stats: inout Statistics,
        transmittedItems: inout TransmittedItems,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> Bool {
        var wroteFrame = false
        do {
            repeat {
                guard isPresent(in: pendingItems) else { return wroteFrame }

                let availableRoom = frame.unclaimedLength
                let amountClaimedFromEndForCongestionWindow: Int
                if Self.frameType.traits.isInFlightEligible, availableCongestionWindow < availableRoom {
                    amountClaimedFromEndForCongestionWindow =
                        (availableRoom - Int(availableCongestionWindow))
                    _ = frame.claim(fromStart: 0, fromEnd: amountClaimedFromEndForCongestionWindow)
                } else {
                    amountClaimedFromEndForCongestionWindow = 0
                }
                defer {
                    // Ensure amount is unclaimed even if the write fails
                    if amountClaimedFromEndForCongestionWindow > 0 {
                        _ = frame.unclaim(
                            fromStart: 0,
                            fromEnd: amountClaimedFromEndForCongestionWindow
                        )
                    }
                }

                try write(
                    into: &frame,
                    pendingItems: &pendingItems,
                    connection: connection,
                    stats: &stats,
                    shorthandFrames: &shorthandFrames
                )

                // Update the available congestion window for other frames
                let availableRoomAfterWriting = frame.unclaimedLength
                let amountWritten = availableRoom - availableRoomAfterWriting
                if availableCongestionWindow > amountWritten {
                    availableCongestionWindow -= UInt64(amountWritten)
                } else {
                    availableCongestionWindow = 0
                }

                addToTransmittedItems(&transmittedItems, from: &pendingItems)
                // An item can drop what it had queued without writing a frame, such as a stream with
                // no flow control credit. That adds nothing to the packet's ack-eliciting accounting.
                if availableRoom - amountClaimedFromEndForCongestionWindow > availableRoomAfterWriting {
                    wroteFrame = true
                }
                if !isRepeatable { break }
                // With no room left the next write can only throw `smallBuffer`.
                // Stop here, with the same result and without the throw.
                if availableRoomAfterWriting == 0 { break }
            } while true
        } catch {
            if !wroteFrame {
                throw error
            } else if case .frameWrite(let writeError) = error,
                case .smallBuffer = writeError
            {
                // Common case, can't write
                return wroteFrame
            } else {
                // Real error, throw
                throw error
            }
        }
        return wroteFrame
    }
}

@available(Network 0.1.0, *)
extension FramePadding: SendableItem {
    static var frameType: FrameType { .padding }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        switch pendingItems.paddingApproach {
        case .fixedSize, .padToEnd: return true
        case .none: return false
        }
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        // Padding is not retransmissable, so is not added to sent items
        pendingItems.paddingApproach = .none
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        // Padding is not retransmitted
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let paddingSize: Int
        let paddingApproach = pendingItems.paddingApproach
        switch paddingApproach {
        case .padToEnd:
            paddingSize = frame.unclaimedLength  // Padding size is equal to remaining length
        case .fixedSize(let fixedSize):
            paddingSize = fixedSize
        case .none:
            paddingSize = 0
        }

        guard paddingSize > 0 else { return }  // Nothing to pad

        try write(frame: &frame, length: paddingSize)
        if case .padToEnd = paddingApproach {
            shorthandFrames?.append(toShorthandLogEntry(length: -1))
        } else {
            shorthandFrames?.append(toShorthandLogEntry(length: Int16(paddingSize)))
        }
    }
}

@available(Network 0.1.0, *)
extension FramePing: SendableItem {
    static var frameType: FrameType { .ping }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool { pendingItems.ping }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.ping = pendingItems.ping
        transmittedItems.pmtudProbeMSS = pendingItems.pmtudProbeMSS
        transmittedItems.isKeepalive = pendingItems.isKeepalive
        pendingItems.ping = false
        pendingItems.pmtudProbeMSS = nil
        pendingItems.isKeepalive = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.ping, transmittedItems.pmtudProbeMSS == nil {
            pendingItems.ping = true
            if transmittedItems.isKeepalive { pendingItems.isKeepalive = true }
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        try write(frame: &frame)
        shorthandFrames?.append(toShorthandLogEntry())
    }
}

@available(Network 0.1.0, *)
extension FrameAck: SendableItem {
    static var frameType: FrameType { .ack }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.ack
        precondition(flagValue == (pendingItems.ackFrame != nil))
        return flagValue
        #else
        return pendingItems.ack
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.ackFrame = .init(pendingItems.ackFrame.take())
        // Do not copy over the ACK flag for transmitted items, since it is not retransmissable
        transmittedItems.ack = false
        pendingItems.ack = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        // ACKs are not retransmitted
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard pendingItems.ackFrame != nil else {
            return
        }
        // Using explicit unwrap here is fine since nil was checked above
        try pendingItems.ackFrame!.write(frame: &frame)
        shorthandFrames?.append(
            toShorthandLogEntry(
                delay: pendingItems.ackFrame!.delay,
                largest: pendingItems.ackFrame!.largest,
                ranges: pendingItems.ackFrame!.ranges.toArray(),
                ecnCounter: pendingItems.ackFrame!.ecnCounter
            )
        )
    }
}

@available(Network 0.1.0, *)
extension FrameResetStream: SendableItem {
    static var frameType: FrameType { .resetStream }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.resetStream
        precondition(flagValue == !pendingItems.streamResets.isEmpty)
        return flagValue
        #else
        return pendingItems.resetStream
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        if let first = pendingItems.streamResets.popFirst() {
            if transmittedItems.streamResets == nil {
                transmittedItems.streamResets = Deque()
            }
            transmittedItems.streamResets!.append(first)
            transmittedItems.resetStream = true
        }
        pendingItems.resetStream = !pendingItems.streamResets.isEmpty
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if let streamResets = transmittedItems.streamResets {
            pendingItems.streamResets.append(contentsOf: streamResets)
            pendingItems.resetStream = !pendingItems.streamResets.isEmpty
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let resetState = pendingItems.streamResets.first else { return }

        try write(
            frame: &frame,
            id: resetState.streamID,
            code: resetState.code,
            finalSize: resetState.finalSize,
            stats: &stats
        )
        shorthandFrames?.append(
            toShorthandLogEntry(
                id: resetState.streamID,
                code: resetState.code,
                finalSize: resetState.finalSize
            )
        )
    }
}

@available(Network 0.1.0, *)
extension FrameStopSending: SendableItem {
    static var frameType: FrameType { .stopSending }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.stopSendingFlag
        precondition(flagValue == !pendingItems.streamStopSendings.isEmpty)
        return flagValue
        #else
        return pendingItems.stopSendingFlag
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        if let first = pendingItems.streamStopSendings.popFirst() {
            if transmittedItems.streamStopSendings == nil {
                transmittedItems.streamStopSendings = Deque()
            }
            transmittedItems.streamStopSendings!.append(first)
            transmittedItems.stopSendingFlag = true
        }
        pendingItems.stopSendingFlag = !pendingItems.streamStopSendings.isEmpty
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if let streamStopSendings = transmittedItems.streamStopSendings {
            pendingItems.streamStopSendings.append(contentsOf: streamStopSendings)
            pendingItems.stopSendingFlag = !pendingItems.streamStopSendings.isEmpty
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let stopSendingState = pendingItems.streamStopSendings.first else { return }

        try write(
            frame: &frame,
            id: stopSendingState.streamID,
            code: stopSendingState.code,
            stats: &stats
        )

        shorthandFrames?.append(
            toShorthandLogEntry(id: stopSendingState.streamID, code: stopSendingState.code)
        )
    }
}

@available(Network 0.1.0, *)
extension FrameCrypto: SendableItem {
    static var frameType: FrameType { .crypto }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        // During the start of a connection sendCrypto can be true but retransmitCrypto / transmittedCrypto can be empty
        pendingItems.sendCrypto || !pendingItems.retransmitCrypto.isEmpty
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.sendCrypto = pendingItems.sendCrypto
        while let sentCrypto = pendingItems.transmittedCrypto.popFirst() {
            transmittedItems.sentCrypto.append(sentCrypto)
        }
        pendingItems.transmittedCrypto.removeAll()
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        var index = 0
        while index < transmittedItems.sentCrypto.count {
            let sentCrypto = TransmittedItems.SentCrypto(
                offset: transmittedItems.sentCrypto[index].offset,
                length: transmittedItems.sentCrypto[index].length
            )

            // Check if this entry is already covered
            var shouldAdd = true
            let existingCount = pendingItems.retransmitCrypto.count
            for existingIndex in 0..<existingCount {
                if sentCrypto.matches(pendingItems.retransmitCrypto[existingIndex]) {
                    shouldAdd = false
                    break
                }
            }
            if shouldAdd {
                pendingItems.retransmitCrypto.append(sentCrypto)
            }
            index += 1
        }
        pendingItems.sendCrypto = !pendingItems.retransmitCrypto.isEmpty
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let packetNumberSpace = pendingItems.packetNumberSpace

        // Try to send exactly one crypto frame at a time, and clean up the sources
        var sentCrypto = false
        while !sentCrypto, !pendingItems.retransmitCrypto.isEmpty {
            let retransmitCryptoOffset = pendingItems.retransmitCrypto[0].offset
            let retransmitCryptoLength = pendingItems.retransmitCrypto[0].length
            guard connection.crypto.storageOutboundStartOffset(for: packetNumberSpace) <= retransmitCryptoOffset else {
                connection.log.datapath(
                    "Not retransmitting data for \(packetNumberSpace) at offset \(retransmitCryptoOffset), already acked"
                )
                _ = pendingItems.retransmitCrypto.popFirst()
                continue
            }

            let lengthWritten = try FrameCrypto.write(
                frame: &frame,
                stats: &stats,
                packetNumberSpace: packetNumberSpace,
                crypto: connection.crypto,
                offset: retransmitCryptoOffset,
                length: retransmitCryptoLength
            )
            let sentCryptoRecord = TransmittedItems.SentCrypto(
                offset: retransmitCryptoOffset,
                length: UInt64(lengthWritten)
            )
            pendingItems.transmittedCrypto.append(sentCryptoRecord)

            if lengthWritten < retransmitCryptoLength {
                // Incomplete write. Save what was transmitted, and record what is left.
                let writtenCrypto = TransmittedItems.SentCrypto(
                    offset: retransmitCryptoOffset,
                    length: UInt64(lengthWritten)
                )
                pendingItems.transmittedCrypto.append(writtenCrypto)

                let pendingCrypto = TransmittedItems.SentCrypto(
                    offset: retransmitCryptoOffset + UInt64(lengthWritten),
                    length: retransmitCryptoLength - UInt64(lengthWritten)
                )
                _ = pendingItems.retransmitCrypto.popFirst()
                pendingItems.retransmitCrypto.prepend(pendingCrypto)
                shorthandFrames?.append(
                    toShorthandLogEntry(
                        length: UInt64(lengthWritten),
                        offset: retransmitCryptoOffset
                    )
                )

            } else {
                // Complete write. Save it to transmitted items for a record.
                let writtenCrypto = pendingItems.retransmitCrypto.popFirst()!
                let writtenCryptoOffset = writtenCrypto.offset
                let writtenCryptoLength = writtenCrypto.length
                pendingItems.transmittedCrypto.append(writtenCrypto)
                shorthandFrames?.append(
                    toShorthandLogEntry(length: writtenCryptoLength, offset: writtenCryptoOffset)
                )
            }

            sentCrypto = true
        }

        guard !sentCrypto else {
            return
        }

        guard pendingItems.sendCrypto else {
            pendingItems.sendCrypto = false
            return
        }
        let (length, offset) = connection.crypto.remainingOutboundData(
            for: packetNumberSpace
        )
        guard length > 0 else {
            pendingItems.sendCrypto = false
            return
        }
        let lengthWritten = try FrameCrypto.write(
            frame: &frame,
            stats: &stats,
            packetNumberSpace: packetNumberSpace,
            crypto: connection.crypto,
            offset: offset,
            length: length
        )
        connection.crypto.incrementOutboundOffset(
            for: packetNumberSpace,
            by: UInt64(lengthWritten)
        )
        let sentCryptoRecord = TransmittedItems.SentCrypto(
            offset: offset,
            length: UInt64(lengthWritten)
        )
        pendingItems.transmittedCrypto.append(sentCryptoRecord)
        pendingItems.sendCrypto = (length > lengthWritten)  // Still send more if not everything was written
        shorthandFrames?.append(toShorthandLogEntry(length: UInt64(lengthWritten), offset: offset))
    }
}

@available(Network 0.1.0, *)
extension FrameNewToken: SendableItem {
    static var frameType: FrameType { .newToken }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.newToken
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.newToken = pendingItems.newToken
        pendingItems.newToken = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.newToken { pendingItems.newToken = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let token = connection.newToken else { return }
        try write(frame: &frame, token: token, stats: &stats)
        shorthandFrames?.append(toShorthandLogEntry(outgoing: true, length: token.count))
    }
}

@available(Network 0.1.0, *)
extension FrameStreamSendMetadata: SendableItem {
    static var frameType: FrameType { .stream() }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.stream
        precondition(
            flagValue
                == (!pendingItems.retransmitStreams.isEmpty
                    || !pendingItems.streamsToService.isEmpty)
        )
        return flagValue
        #else
        return pendingItems.stream
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        var recordedStream = false
        while let sentStream = pendingItems.transmittedStreams.popFirst() {
            transmittedItems.sentStreams.append(sentStream)
            recordedStream = true
        }
        // A write can drop everything queued without sending, and that packet carries no stream data
        if recordedStream {
            transmittedItems.stream = true
        }
        if pendingItems.streamsToService.isEmpty && pendingItems.retransmitStreams.isEmpty {
            pendingItems.stream = false
        }
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        var index = 0
        while index < transmittedItems.sentStreams.count {
            let sentStream = TransmittedItems.SentStream(
                flowID: transmittedItems.sentStreams[index].flowID,
                streamID: transmittedItems.sentStreams[index].streamID,
                offset: transmittedItems.sentStreams[index].offset,
                length: transmittedItems.sentStreams[index].length,
                isFinal: transmittedItems.sentStreams[index].isFinal
            )

            // Check if this entry is already covered
            var shouldAdd = true
            let existingCount = pendingItems.retransmitStreams.count
            for existingIndex in 0..<existingCount {
                if sentStream.matches(pendingItems.retransmitStreams[existingIndex]) {
                    shouldAdd = false
                    break
                }
            }
            if shouldAdd {
                pendingItems.retransmitStreams.append(sentStream)
            }
            pendingItems.stream = true
            index += 1
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        // Try to send exactly one stream frame at a time, and clean up the sources
        var sentStream = false

        // First try to send any pending retransmissions. These do not raise the highest offset sent,
        // so connection flow control does not hold them back: the peer may need this data before it
        // can read enough to send MAX_DATA.
        while !sentStream, !pendingItems.retransmitStreams.isEmpty {
            let retransmitStreamFlowID = pendingItems.retransmitStreams[0].flowID

            // The stream is borrowed from the connection's flow table while it is written
            let wroteRetransmission = try connection.withStreamBorrowed(retransmitStreamFlowID) {
                (stream: inout QUICStreamInstance) throws(QUICError) -> Bool in
                try writeRetransmission(
                    into: &frame,
                    pendingItems: &pendingItems,
                    connection: connection,
                    stats: &stats,
                    shorthandFrames: &shorthandFrames,
                    stream: &stream,
                    flowID: retransmitStreamFlowID
                )
            }
            guard let wroteRetransmission else {
                connection.log.error("Unable to access state for flow \(retransmitStreamFlowID)")
                _ = pendingItems.retransmitStreams.popFirst()
                continue
            }
            sentStream = wroteRetransmission
        }

        // Then, try to send new stream data. A stream with no flow control credit is taken off the
        // list here and queued again when the peer sends more.
        while !sentStream, !pendingItems.streamsToService.isEmpty {
            let streamToService = pendingItems.streamsToService.first!

            let wroteStreamData = try connection.withStreamBorrowed(streamToService) {
                (stream: inout QUICStreamInstance) throws(QUICError) -> Bool in
                try writeNewStreamData(
                    into: &frame,
                    pendingItems: &pendingItems,
                    connection: connection,
                    stats: &stats,
                    shorthandFrames: &shorthandFrames,
                    stream: &stream
                )
            }
            guard let wroteStreamData else {
                connection.log.error("Unable to access state for flow \(streamToService)")
                pendingItems.popServicedStream()
                continue
            }
            sentStream = wroteStreamData
        }
    }

    // Writes the first pending retransmission, which belongs to the borrowed stream. Returns
    // whether a STREAM frame was written; when it was not, the retransmission has been discarded.
    private static func writeRetransmission(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?,
        stream: inout QUICStreamInstance,
        flowID retransmitStreamFlowID: MultiplexedFlowIdentifier
    ) throws(QUICError) -> Bool {
        let retransmitStreamOffset = pendingItems.retransmitStreams[0].offset
        let retransmitStreamLength = pendingItems.retransmitStreams[0].length
        let retransmitStreamIsFinal = pendingItems.retransmitStreams[0].isFinal
        let retransmitStreamStreamID = pendingItems.retransmitStreams[0].streamID

        guard stream.isOpen else {
            connection.log.info(
                "Not retransmitting data for closed flow \(retransmitStreamFlowID)"
            )
            _ = pendingItems.retransmitStreams.popFirst()
            return false
        }

        guard stream.send.buffer.storageStartOffset <= retransmitStreamOffset else {
            connection.log.datapath(
                "Not retransmitting data at offset \(retransmitStreamOffset), already acked"
            )
            _ = pendingItems.retransmitStreams.popFirst()
            return false
        }

        // The sendBuffer may not still have this offset+length data because
        // the ACK/timer that drove us to retransmit could have been a
        // reordered event. It "should not" happen in current implementation
        // because recovery deletes the recovered packet when retransmitting
        // but a bug or implementation change could cause this to occur.
        // And if it does, we'd stuck in a loop trying to write here and
        // always throwing, so it is safer to guard against it.
        let lengthWritten = try write(
            into: &frame,
            stats: &stats,
            stream: &stream,
            offset: retransmitStreamOffset,
            length: retransmitStreamLength,
            isFinal: retransmitStreamIsFinal
        )
        if lengthWritten < retransmitStreamLength {
            // Incomplete write. Save what was transmitted, and record what is left.
            let writtenStream = TransmittedItems.SentStream(
                flowID: retransmitStreamFlowID,
                streamID: retransmitStreamStreamID,
                offset: retransmitStreamOffset,
                length: UInt64(lengthWritten),
                isFinal: false
            )
            pendingItems.transmittedStreams.append(writtenStream)
            shorthandFrames?.append(
                toShorthandLogEntry(
                    id: retransmitStreamStreamID.value,
                    fin: retransmitStreamIsFinal,
                    offset: retransmitStreamOffset,
                    length: retransmitStreamLength
                )
            )

            let pendingStream = TransmittedItems.SentStream(
                flowID: retransmitStreamFlowID,
                streamID: retransmitStreamStreamID,
                offset: retransmitStreamOffset + UInt64(lengthWritten),
                length: retransmitStreamLength - UInt64(lengthWritten),
                isFinal: retransmitStreamIsFinal
            )
            _ = pendingItems.retransmitStreams.popFirst()
            pendingItems.retransmitStreams.prepend(pendingStream)
        } else {
            // Complete write. Save it to transmitted items for a record.
            let streamItem = pendingItems.retransmitStreams.popFirst()!
            shorthandFrames?.append(
                toShorthandLogEntry(
                    id: streamItem.streamID.value,
                    fin: streamItem.isFinal,
                    offset: streamItem.offset,
                    length: streamItem.length
                )
            )
            pendingItems.transmittedStreams.append(streamItem)
        }
        return true
    }

    // Writes new data for the borrowed stream, which is the first one waiting to be serviced.
    // Returns whether a STREAM frame was written; when it was not, the stream has been taken off
    // the list of streams to service.
    private static func writeNewStreamData(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?,
        stream: inout QUICStreamInstance
    ) throws(QUICError) -> Bool {
        // Already completely written, ignore
        guard !stream.send.state.dataHasAlreadyBeenSent else {
            pendingItems.popServicedStream()
            stream.listMembership.remove(.sendable)
            return false
        }

        let (offset, remainingStreamLength, hasLast) = stream.availableSendData()
        let allowedFlowControlLength = stream.availableRemoteReceiveWindow(for: connection)
        let lengthToSend = min(remainingStreamLength, allowedFlowControlLength)
        let isFinal = hasLast && lengthToSend == remainingStreamLength

        let shouldSend = remainingStreamLength > 0 || isFinal
        guard shouldSend else {
            pendingItems.popServicedStream()
            stream.listMembership.remove(.sendable)
            return false
        }

        if lengthToSend == 0 && remainingStreamLength > 0 {
            // Has data to send, but cannot
            // Remove the stream for now
            pendingItems.popServicedStream()
            stream.listMembership.remove(.sendable)
            // And trigger sending blocked frames if necessary
            stream.recordStreamDataSending(
                writtenLength: 0,
                isFinal: false,
                hasMoreDataToService: true,
                pendingItems: &pendingItems,
                connection: connection
            )
            return false
        }

        let lengthWritten = try write(
            into: &frame,
            stats: &stats,
            stream: &stream,
            offset: offset,
            length: lengthToSend,
            isFinal: isFinal
        )
        let hasMoreDataToService = remainingStreamLength > UInt64(lengthWritten)

        let streamFlowIdentifier = stream.flowIdentifier
        let currentStreamID = stream.streamID!

        if lengthWritten < lengthToSend {
            // Incomplete write. Save what was transmitted, and record what is left.
            let writtenStream = TransmittedItems.SentStream(
                flowID: streamFlowIdentifier,
                streamID: currentStreamID,
                offset: offset,
                length: UInt64(lengthWritten),
                isFinal: false
            )
            shorthandFrames?.append(
                toShorthandLogEntry(
                    id: writtenStream.streamID.value,
                    fin: writtenStream.isFinal,
                    offset: writtenStream.offset,
                    length: writtenStream.length
                )
            )
            pendingItems.transmittedStreams.append(writtenStream)
            stream.recordStreamDataSending(
                writtenLength: UInt64(lengthWritten),
                isFinal: false,
                hasMoreDataToService: hasMoreDataToService,
                pendingItems: &pendingItems,
                connection: connection
            )
        } else {
            // Complete write. Save it to transmitted items for a record.
            let writtenStream = TransmittedItems.SentStream(
                flowID: streamFlowIdentifier,
                streamID: currentStreamID,
                offset: offset,
                length: UInt64(lengthWritten),
                isFinal: isFinal
            )
            shorthandFrames?.append(
                toShorthandLogEntry(
                    id: writtenStream.streamID.value,
                    fin: writtenStream.isFinal,
                    offset: writtenStream.offset,
                    length: writtenStream.length
                )
            )
            pendingItems.transmittedStreams.append(writtenStream)
            stream.recordStreamDataSending(
                writtenLength: UInt64(lengthWritten),
                isFinal: isFinal,
                hasMoreDataToService: hasMoreDataToService,
                pendingItems: &pendingItems,
                connection: connection
            )

            // Complete write, remove this stream from the list to service
            pendingItems.popServicedStream()
            stream.listMembership.remove(.sendable)
        }
        return true
    }
}

@available(Network 0.1.0, *)
extension FrameDataBlocked: SendableItem {
    static var frameType: FrameType { .dataBlocked }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.dataBlocked
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.dataBlocked = pendingItems.dataBlocked
        pendingItems.dataBlocked = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.dataBlocked { pendingItems.dataBlocked = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let limit = connection.sendOffset
        try write(frame: &frame, limit: limit, stats: &stats)
        shorthandFrames?.append(toShorthandLogEntry(limit: limit))
    }
}

@available(Network 0.1.0, *)
extension FrameStreamDataBlocked: SendableItem {
    static var frameType: FrameType { .streamDataBlocked }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.streamDataBlocked
        precondition(flagValue == !pendingItems.streamDataBlockedFlows.isEmpty)
        return flagValue
        #else
        return pendingItems.streamDataBlocked
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        if let first = pendingItems.streamDataBlockedFlows.popFirst() {
            if transmittedItems.streamDataBlockedFlows == nil {
                transmittedItems.streamDataBlockedFlows = Deque()
            }
            transmittedItems.streamDataBlockedFlows!.append(first)
            transmittedItems.streamDataBlocked = true
        }
        pendingItems.streamDataBlocked = !pendingItems.streamDataBlockedFlows.isEmpty
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if let streamDataBlockedFlows = transmittedItems.streamDataBlockedFlows {
            for flowID in streamDataBlockedFlows {
                if !pendingItems.streamDataBlockedFlows.contains(flowID) {
                    pendingItems.streamDataBlockedFlows.append(flowID)
                    pendingItems.streamDataBlocked = true
                }
            }
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let firstFlowID = pendingItems.streamDataBlockedFlows.first,
            let (streamIDValue, limit) = connection.withStreamBorrowed(
                firstFlowID,
                { (stream: inout QUICStreamInstance) -> (UInt64, UInt64)? in
                    guard let streamID = stream.streamID else { return nil }
                    return (streamID.value, stream.sendOffset)
                }
            ) ?? nil
        else { return }

        try write(frame: &frame, id: streamIDValue, limit: limit, stats: &stats)
        shorthandFrames?.append(toShorthandLogEntry(id: streamIDValue, limit: limit))
    }
}

@available(Network 0.1.0, *)
extension FrameStreamsBlockedBidirectional: SendableItem {
    static var frameType: FrameType { .streamsBlockedBidirectional }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.streamsBlockedBidirectional
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.streamsBlockedBidirectional = pendingItems.streamsBlockedBidirectional
        pendingItems.streamsBlockedBidirectional = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.streamsBlockedBidirectional {
            pendingItems.streamsBlockedBidirectional = true
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let limit = UInt64(connection.bidirectionalStreams.previousRemoteMaxStreams)
        try write(frame: &frame, limit: limit, stats: &stats)
        shorthandFrames?.append(toShorthandLogEntry(limit: limit))
    }
}

@available(Network 0.1.0, *)
extension FrameStreamsBlockedUnidirectional: SendableItem {
    static var frameType: FrameType { .streamsBlockedUnidirectional }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.streamsBlockedUnidirectional
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.streamsBlockedUnidirectional = pendingItems.streamsBlockedUnidirectional
        pendingItems.streamsBlockedUnidirectional = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.streamsBlockedUnidirectional {
            pendingItems.streamsBlockedUnidirectional = true
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let limit = UInt64(connection.unidirectionalStreams.previousRemoteMaxStreams)
        try write(frame: &frame, limit: limit, stats: &stats)
        shorthandFrames?.append(toShorthandLogEntry(limit: limit))
    }
}

@available(Network 0.1.0, *)
extension FrameMaxData: SendableItem {
    static var frameType: FrameType { .maxData }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool { pendingItems.maxData }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.maxData = pendingItems.maxData
        pendingItems.maxData = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.maxData { pendingItems.maxData = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let max = connection.flowControlState.inboundMaxData
        try write(frame: &frame, max: max)
        shorthandFrames?.append(toShorthandLogEntry(max: max))
    }
}

@available(Network 0.1.0, *)
extension FrameMaxStreamData: SendableItem {
    static var frameType: FrameType { .maxStreamData }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.maxStreamData
        precondition(flagValue == !pendingItems.maxStreamDataFlows.isEmpty)
        return flagValue
        #else
        return pendingItems.maxStreamData
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        if let first = pendingItems.maxStreamDataFlows.popFirst() {
            if transmittedItems.maxStreamDataFlows == nil {
                transmittedItems.maxStreamDataFlows = Deque()
            }
            transmittedItems.maxStreamDataFlows!.append(first)
            transmittedItems.maxStreamData = true
        }
        if pendingItems.maxStreamDataFlows.isEmpty {
            pendingItems.maxStreamData = false
        }
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if let maxStreamDataFlows = transmittedItems.maxStreamDataFlows {
            for flowID in maxStreamDataFlows {
                if !pendingItems.maxStreamDataFlows.contains(flowID) {
                    pendingItems.maxStreamDataFlows.append(flowID)
                    pendingItems.maxStreamData = true
                }
            }
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let firstFlowID = pendingItems.maxStreamDataFlows.first,
            let (streamIDValue, localMaxData) = connection.withStreamBorrowed(
                firstFlowID,
                { (stream: inout QUICStreamInstance) -> (UInt64, UInt64)? in
                    guard let streamID = stream.streamID else { return nil }
                    return (streamID.value, stream.flowControlState.inboundMaxData)
                }
            ) ?? nil
        else { return }

        try write(frame: &frame, id: streamIDValue, max: localMaxData)
        shorthandFrames?.append(toShorthandLogEntry(id: streamIDValue, max: localMaxData))
    }
}

@available(Network 0.1.0, *)
extension FrameMaxStreamsBidirectional: SendableItem {
    static var frameType: FrameType { .maxStreamsBidirectional }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.maxStreamsBidirectional
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.maxStreamsBidirectional = pendingItems.maxStreamsBidirectional
        pendingItems.maxStreamsBidirectional = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.maxStreamsBidirectional { pendingItems.maxStreamsBidirectional = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        var maxStreams: UInt64 = 0
        connection.withMutableQUICStreams(unidirectional: false) { mutableStreamsState in
            maxStreams = UInt64(mutableStreamsState.localMaxStreams)
        }
        try write(frame: &frame, max: maxStreams)
        shorthandFrames?.append(toShorthandLogEntry(max: maxStreams))
    }
}

@available(Network 0.1.0, *)
extension FrameMaxStreamsUnidirectional: SendableItem {
    static var frameType: FrameType { .maxStreamsUnidirectional }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.maxStreamsUnidirectional
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.maxStreamsUnidirectional = pendingItems.maxStreamsUnidirectional
        pendingItems.maxStreamsUnidirectional = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.maxStreamsUnidirectional {
            pendingItems.maxStreamsUnidirectional = true
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        var maxStreams: UInt64 = 0
        connection.withMutableQUICStreams(unidirectional: true) { mutableStreamsState in
            maxStreams = UInt64(mutableStreamsState.localMaxStreams)
        }
        try write(frame: &frame, max: maxStreams)
        shorthandFrames?.append(toShorthandLogEntry(max: maxStreams))
    }
}

@available(Network 0.1.0, *)
extension FrameNewConnectionID: SendableItem {
    static var frameType: FrameType { .newConnectionID }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.newConnectionID
        precondition(flagValue == !pendingItems.newConnectionIDs.isEmpty)
        return flagValue
        #else
        return pendingItems.newConnectionID
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        if let first = pendingItems.newConnectionIDs.popFirst() {
            if transmittedItems.newConnectionIDs == nil {
                transmittedItems.newConnectionIDs = Deque()
            }
            transmittedItems.newConnectionIDs!.append(first)
            transmittedItems.newConnectionID = true
        }
        if pendingItems.newConnectionIDs.isEmpty {
            pendingItems.newConnectionID = false
        }
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if let newConnectionIDs = transmittedItems.newConnectionIDs {
            pendingItems.newConnectionIDs.append(contentsOf: newConnectionIDs)
            pendingItems.newConnectionID = !pendingItems.newConnectionIDs.isEmpty
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let newConnectionID = pendingItems.newConnectionIDs.first else { return }
        try newConnectionID.write(frame: &frame)
        shorthandFrames?.append(
            toShorthandLogEntry(
                sequence: newConnectionID.sequence,
                retirePriorToSequence: newConnectionID.retirePriorToSequence,
                connectionID: newConnectionID.connectionID
            )
        )
    }
}

@available(Network 0.1.0, *)
extension FrameRetireConnectionID: SendableItem {
    static var frameType: FrameType { .retireConnectionID }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.retireConnectionID
        precondition(flagValue == !pendingItems.retireConnectionIDs.isEmpty)
        return flagValue
        #else
        return pendingItems.retireConnectionID
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        if let first = pendingItems.retireConnectionIDs.popFirst() {
            if transmittedItems.retireConnectionIDs == nil {
                transmittedItems.retireConnectionIDs = Deque()
            }
            transmittedItems.retireConnectionIDs!.append(first)
            transmittedItems.retireConnectionID = true
        }
        if pendingItems.retireConnectionIDs.isEmpty {
            pendingItems.retireConnectionID = false
        }
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if let retireConnectionIDs = transmittedItems.retireConnectionIDs {
            pendingItems.retireConnectionIDs.append(contentsOf: retireConnectionIDs)
            pendingItems.retireConnectionID = !pendingItems.retireConnectionIDs.isEmpty
        }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let retireConnectionID = pendingItems.retireConnectionIDs.first else { return }
        try retireConnectionID.write(frame: &frame)
        shorthandFrames?.append(toShorthandLogEntry(sequence: retireConnectionID.sequence))
    }
}

@available(Network 0.1.0, *)
extension FramePathChallenge: SendableItem {
    static var frameType: FrameType { .pathChallenge }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.pathChallenge
        precondition(flagValue == !pendingItems.pathChallenges.isEmpty)
        return flagValue
        #else
        return pendingItems.pathChallenge
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        pendingItems.pathChallenges.removeFirst()
        pendingItems.pathChallenge = !pendingItems.pathChallenges.isEmpty
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let pathChallenge = pendingItems.pathChallenges.first else { return }
        try pathChallenge.write(frame: &frame)
        shorthandFrames?.append(toShorthandLogEntry())
    }
}

@available(Network 0.1.0, *)
extension FramePathResponse: SendableItem {
    static var frameType: FrameType { .pathResponse }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.pathResponse
        precondition(flagValue == !pendingItems.pathResponses.isEmpty)
        return flagValue
        #else
        return pendingItems.pathResponse
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        // not retransmissible
        pendingItems.pathResponses.removeFirst()
        pendingItems.pathResponse = !pendingItems.pathResponses.isEmpty
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let pathResponse = pendingItems.pathResponses.first else { return }
        try pathResponse.write(frame: &frame)
        shorthandFrames?.append(toShorthandLogEntry())
    }
}

@available(Network 0.1.0, *)
extension FrameConnectionClose: SendableItem {
    static var frameType: FrameType { .connectionClose }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.connectionClose
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.connectionClose = pendingItems.connectionClose
        pendingItems.connectionClose = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.connectionClose { pendingItems.connectionClose = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        let errorAndType = connection.connectionCloseErrorToSend
        let errorCode = UInt64(errorAndType.0.code)
        let errorReason = errorAndType.0.reason
        let frameType = errorAndType.1
        try write(
            frame: &frame,
            stats: &stats,
            errorCode: errorCode,
            frameType: frameType,
            reason: errorReason
        )
        shorthandFrames?.append(
            toShorthandLogEntry(
                errorCode: errorCode,
                frameType: frameType?.rawValue ?? 0,
                reason: errorReason
            )
        )
    }
}

@available(Network 0.1.0, *)
extension FrameApplicationClose: SendableItem {
    static var frameType: FrameType { .applicationClose }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.applicationClose
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.applicationClose = pendingItems.applicationClose
        pendingItems.applicationClose = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.applicationClose { pendingItems.applicationClose = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        guard let error = connection.applicationCloseErrorToSend else {
            connection.log.fault(
                "Application close error unexpectedly nil, sending CONNECTION_CLOSE"
            )
            // If the application error was not present, send the connection close as a fallback
            // This will default to .noError which makes sense as a default error for CONNECTION_CLOSE
            pendingItems.applicationClose = false
            pendingItems.connectionClose = true
            try FrameConnectionClose.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                stats: &stats,
                shorthandFrames: &shorthandFrames
            )
            return
        }
        switch pendingItems.packetNumberSpace {
        case .initial, .handshake:
            // RFC 9000 §10.2.3: Initial and Handshake packets must not reveal application state, so
            // send a CONNECTION_CLOSE with APPLICATION_ERROR and no reason instead
            let errorCode = UInt64(QUICTransportError.QUICTransportErrorCode.applicationError.rawValue)
            try FrameConnectionClose.write(frame: &frame, stats: &stats, errorCode: errorCode, frameType: nil)
            shorthandFrames?.append(
                FrameConnectionClose.toShorthandLogEntry(errorCode: errorCode, frameType: nil, reason: "")
            )
        case .applicationData:
            let errorCode = UInt64(error.code)
            let errorReason = error.reason
            try write(
                frame: &frame,
                stats: &stats,
                errorCode: errorCode,
                reason: errorReason
            )
            shorthandFrames?.append(toShorthandLogEntry(errorCode: errorCode, reason: errorReason))
        }
    }
}

@available(Network 0.1.0, *)
extension FrameHandshakeDone: SendableItem {
    static var frameType: FrameType { .handshakeDone }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        pendingItems.handshakeDone
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        transmittedItems.handshakeDone = pendingItems.handshakeDone
        pendingItems.handshakeDone = false
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        if transmittedItems.handshakeDone { pendingItems.handshakeDone = true }
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        try write(frame: &frame)
        shorthandFrames?.append(toShorthandLogEntry())
    }
}

@available(Network 0.1.0, *)
extension FrameDatagram: SendableItem {
    static var frameType: FrameType { .datagram() }

    static var isRepeatable: Bool { true }

    static func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        #if DEBUG
        let flagValue = pendingItems.datagram
        precondition(flagValue == !pendingItems.datagramFlowsToService.isEmpty)
        return flagValue
        #else
        return pendingItems.datagram
        #endif
    }

    static func addToTransmittedItems(
        _ transmittedItems: inout TransmittedItems,
        from pendingItems: inout PendingItems
    ) {
        // Datagrams are not retransmitted, don't add to sent items
        pendingItems.datagram = !pendingItems.datagramFlowsToService.isEmpty
    }

    static func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        // Datagrams are not retransmitted, ignore
    }

    static func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        stats: inout Statistics,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) {
        // Try to send exactly one datagram, and clean up the flows to service once that flow is empty
        var sentDatagram = false
        while !pendingItems.datagramFlowsToService.isEmpty, !sentDatagram {
            let firstFlowID = pendingItems.datagramFlowsToService.first!

            var datagramsListIsEmpty = false
            // Thrown once the closure has returned, because `accessDatagramsToSend` takes a
            // non-throwing closure. It tells the packet builder that this packet is full.
            var writeError: QUICError? = nil
            // Frames the write is finished with. A frame's finalizer is a closure the sender supplied,
            // and it can do anything, so it must not run while the flow is borrowed from the table.
            // They are finalized once the borrow has ended.
            var oversizedFrames = FrameArray()
            var writtenFrame: Frame? = nil
            // The flow is borrowed from the secondary flow table for the whole write, so nothing
            // below may look the table up again.
            let accessed: Void? = connection.withSecondaryFlow(firstFlowID) {
                (datagramFlow: inout QUICDatagramFlow) in
                let datagramFlowID = datagramFlow.flowID
                let datagramContextID = datagramFlow.contextID
                let usableDatagramSize = datagramFlow.usableDatagramSize
                connection.accessDatagramsToSend(flow: &datagramFlow) { datagrams in
                    while !datagrams.isEmpty {
                        let dataLength = datagrams.peekFirstFrame { $0.unclaimedLength }
                        connection.log.datapath(
                            "Handle output datagram for flow \(firstFlowID.debugDescription) (size \(dataLength))"
                        )
                        guard dataLength <= usableDatagramSize else {
                            connection.log.error(
                                "Unable to send datagram frame, length \(dataLength) exceeds usable size \(usableDatagramSize)"
                            )
                            guard let oversized = datagrams.popFirst() else { break }
                            oversizedFrames.add(frame: oversized)
                            continue
                        }

                        // Write from the queue and remove it only once it is written, so a datagram
                        // that does not fit the rest of this packet stays queued for the next one.
                        let roomBeforeWriting = frame.unclaimedLength
                        writeError = datagrams.peekFirstFrame { datagramFrame in
                            do throws(QUICError) {
                                try FrameDatagram.write(
                                    frame: &frame,
                                    hasLength: true,
                                    flowID: datagramFlowID,
                                    contextID: datagramContextID,
                                    data: datagramFrame,
                                    stats: &stats
                                )
                                return nil
                            } catch {
                                return error
                            }
                        }
                        if let error = writeError {
                            if case .frameWrite(.smallBuffer) = error {
                                connection.log.datapath(
                                    "Datagram for flow \(firstFlowID.debugDescription) does not fit \(roomBeforeWriting) free bytes; requeueing"
                                )
                            } else {
                                connection.log.error(
                                    "Unable to write datagram for flow \(firstFlowID.debugDescription): "
                                        + "\(error.info.description), code \(error.info.code)"
                                )
                            }
                            break
                        }
                        sentDatagram = true
                        shorthandFrames?.append(
                            toShorthandLogEntry(
                                flowID: datagramFlowID,
                                length: UInt64(dataLength)
                            )
                        )
                        writtenFrame = datagrams.popFirst()
                        break
                    }
                    datagramsListIsEmpty = datagrams.isEmpty
                }
            }
            // The borrow has ended, so the frames' finalizers can run
            oversizedFrames.finalizeAllFramesAsFailed()
            if var written = writtenFrame.take() {
                written.finalize(success: true)
            }
            guard accessed != nil else {
                connection.log.error("Unable to access state for flow \(firstFlowID)")
                pendingItems.datagramFlowsToService.removeFirst()
                continue
            }
            if let writeError {
                // A write only fails before anything is dequeued, so nothing was written in this
                // call and the caller is free to treat this as "the packet is full".
                throw writeError
            }
            if datagramsListIsEmpty {
                // Nothing left to do on the first flow, remove it
                pendingItems.datagramFlowsToService.removeFirst()
            }
        }
    }
}

// MARK: - Prioritized List of Sendable Items

// This list is the priority order in which to send frames.
//
// The raw value of each case is the index by which `SimpleSendableItemsFlags` places
// each flag at the bit position. `PendingItems.write` uses this to find the next item to send
// from the flags alone.
@available(Network 0.1.0, *)
enum PrioritizedSendableItems: Int, CaseIterable {
    // IMPORTANT: the declaration order is the sending priority, and it must stay in step with the bit order of
    // `SimpleSendableItemsFlags`, which `PendingItems.write` uses to index `allCases`. Update both together.
    // Control frames come first so that they fit in the earliest outgoing frame
    case crypto
    case newToken
    case newConnectionID
    case retireConnectionID
    case pathChallenge
    case pathResponse
    case handshakeDone

    // ACKs are the next highest priority
    case ack

    // Pings are used for probing, etc.
    case ping

    // Datagrams (may consume rest of the outbound frame))
    case datagram

    // Flow control
    case dataBlocked
    case streamDataBlocked
    case streamsBlockedBidirectional
    case streamsBlockedUnidirectional
    case maxData
    case maxStreamData
    case maxStreamsBidirectional
    case maxStreamsUnidirectional

    // Stream data (may consume rest of the outbound frame)
    case stream

    // Send stream closing after pending data
    case resetStream
    case stopSending

    // Closing should to be after any pending data is sent
    case connectionClose
    case applicationClose

    // Padding should be last and may consume rest of the outbound frame
    case padding

    /// The bit that stands for this item in a mask of items, at the item's priority.
    var maskBit: UInt32 {
        UInt32(1) << UInt32(truncatingIfNeeded: rawValue)
    }

    /// The flag that says this item is pending, if it has one.
    ///
    /// There is deliberately no `default`, so the compiler requires every new item to be given a flag here.
    /// Crypto is also pending when there is some to retransmit, and padding has no flag as it is pending
    /// when `paddingApproach` is set. See `PendingItems.presentItemsMask`.
    var flag: SimpleSendableItemsFlags? {
        switch self {
        case .crypto: .sendCrypto
        case .newToken: .newToken
        case .newConnectionID: .newConnectionID
        case .retireConnectionID: .retireConnectionID
        case .pathChallenge: .pathChallenge
        case .pathResponse: .pathResponse
        case .handshakeDone: .handshakeDone
        case .ack: .ack
        case .ping: .ping
        case .datagram: .datagram
        case .dataBlocked: .dataBlocked
        case .streamDataBlocked: .streamDataBlocked
        case .streamsBlockedBidirectional: .streamsBlockedBidirectional
        case .streamsBlockedUnidirectional: .streamsBlockedUnidirectional
        case .maxData: .maxData
        case .maxStreamData: .maxStreamData
        case .maxStreamsBidirectional: .maxStreamsBidirectional
        case .maxStreamsUnidirectional: .maxStreamsUnidirectional
        case .stream: .stream
        case .resetStream: .resetStream
        case .stopSending: .stopSendingFlag
        case .connectionClose: .connectionClose
        case .applicationClose: .applicationClose
        case .padding: nil
        }
    }

    var frameType: FrameType {
        switch self {
        case .crypto: FrameCrypto.frameType
        case .newToken: FrameNewToken.frameType
        case .newConnectionID: FrameNewConnectionID.frameType
        case .retireConnectionID: FrameRetireConnectionID.frameType
        case .pathChallenge: FramePathChallenge.frameType
        case .pathResponse: FramePathResponse.frameType
        case .handshakeDone: FrameHandshakeDone.frameType
        case .ack: FrameAck.frameType
        case .ping: FramePing.frameType
        case .datagram: FrameDatagram.frameType
        case .dataBlocked: FrameDataBlocked.frameType
        case .streamDataBlocked: FrameStreamDataBlocked.frameType
        case .streamsBlockedBidirectional: FrameStreamsBlockedBidirectional.frameType
        case .streamsBlockedUnidirectional: FrameStreamsBlockedUnidirectional.frameType
        case .maxData: FrameMaxData.frameType
        case .maxStreamData: FrameMaxStreamData.frameType
        case .maxStreamsBidirectional: FrameMaxStreamsBidirectional.frameType
        case .maxStreamsUnidirectional: FrameMaxStreamsUnidirectional.frameType
        case .stream: FrameStreamSendMetadata.frameType
        case .resetStream: FrameResetStream.frameType
        case .stopSending: FrameStopSending.frameType
        case .connectionClose: FrameConnectionClose.frameType
        case .applicationClose: FrameApplicationClose.frameType
        case .padding: FramePadding.frameType
        }
    }

    // Inline for compilation with (-Osize)
    @inline(always)
    func isPresent(in pendingItems: borrowing PendingItems) -> Bool {
        switch self {
        case .datagram:
            return FrameDatagram.isPresent(in: pendingItems)
        case .crypto:
            return FrameCrypto.isPresent(in: pendingItems)
        case .newToken:
            return FrameNewToken.isPresent(in: pendingItems)
        case .newConnectionID:
            return FrameNewConnectionID.isPresent(in: pendingItems)
        case .retireConnectionID:
            return FrameRetireConnectionID.isPresent(in: pendingItems)
        case .pathChallenge:
            return FramePathChallenge.isPresent(in: pendingItems)
        case .pathResponse:
            return FramePathResponse.isPresent(in: pendingItems)
        case .handshakeDone:
            return FrameHandshakeDone.isPresent(in: pendingItems)
        case .ack:
            return FrameAck.isPresent(in: pendingItems)
        case .dataBlocked:
            return FrameDataBlocked.isPresent(in: pendingItems)
        case .streamDataBlocked:
            return FrameStreamDataBlocked.isPresent(in: pendingItems)
        case .streamsBlockedBidirectional:
            return FrameStreamsBlockedBidirectional.isPresent(in: pendingItems)
        case .streamsBlockedUnidirectional:
            return FrameStreamsBlockedUnidirectional.isPresent(in: pendingItems)
        case .maxData:
            return FrameMaxData.isPresent(in: pendingItems)
        case .maxStreamData:
            return FrameMaxStreamData.isPresent(in: pendingItems)
        case .maxStreamsBidirectional:
            return FrameMaxStreamsBidirectional.isPresent(in: pendingItems)
        case .maxStreamsUnidirectional:
            return FrameMaxStreamsUnidirectional.isPresent(in: pendingItems)
        case .ping:
            return FramePing.isPresent(in: pendingItems)
        case .stream:
            return FrameStreamSendMetadata.isPresent(in: pendingItems)
        case .resetStream:
            return FrameResetStream.isPresent(in: pendingItems)
        case .stopSending:
            return FrameStopSending.isPresent(in: pendingItems)
        case .connectionClose:
            return FrameConnectionClose.isPresent(in: pendingItems)
        case .applicationClose:
            return FrameApplicationClose.isPresent(in: pendingItems)
        case .padding:
            return FramePadding.isPresent(in: pendingItems)
        }
    }

    func write(
        into frame: inout Frame,
        pendingItems: inout PendingItems,
        connection: QUICConnection,
        availableCongestionWindow: inout UInt64,
        stats: inout Statistics,
        transmittedItems: inout TransmittedItems,
        shorthandFrames: inout [QUICShorthandFrame]?
    ) throws(QUICError) -> Bool {
        switch self {
        case .datagram:
            return try FrameDatagram.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .crypto:
            return try FrameCrypto.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .newToken:
            return try FrameNewToken.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .newConnectionID:
            return try FrameNewConnectionID.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .retireConnectionID:
            return try FrameRetireConnectionID.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .pathChallenge:
            return try FramePathChallenge.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .pathResponse:
            return try FramePathResponse.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .handshakeDone:
            return try FrameHandshakeDone.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .ack:
            return try FrameAck.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .dataBlocked:
            return try FrameDataBlocked.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .streamDataBlocked:
            return try FrameStreamDataBlocked.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .streamsBlockedBidirectional:
            return try FrameStreamsBlockedBidirectional.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .streamsBlockedUnidirectional:
            return try FrameStreamsBlockedUnidirectional.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .maxData:
            return try FrameMaxData.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .maxStreamData:
            return try FrameMaxStreamData.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .maxStreamsBidirectional:
            return try FrameMaxStreamsBidirectional.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .maxStreamsUnidirectional:
            return try FrameMaxStreamsUnidirectional.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .ping:
            return try FramePing.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .stream:
            return try FrameStreamSendMetadata.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .resetStream:
            return try FrameResetStream.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .stopSending:
            return try FrameStopSending.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .connectionClose:
            return try FrameConnectionClose.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .applicationClose:
            return try FrameApplicationClose.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        case .padding:
            return try FramePadding.write(
                into: &frame,
                pendingItems: &pendingItems,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        }
    }

    func addToPendingItems(
        _ pendingItems: inout PendingItems,
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        switch self {
        case .datagram:
            FrameDatagram.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .crypto:
            FrameCrypto.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .newToken:
            FrameNewToken.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .newConnectionID:
            FrameNewConnectionID.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .retireConnectionID:
            FrameRetireConnectionID.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .pathChallenge:
            FramePathChallenge.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .pathResponse:
            FramePathResponse.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .handshakeDone:
            FrameHandshakeDone.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .ack:
            FrameAck.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .dataBlocked:
            FrameDataBlocked.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .streamDataBlocked:
            FrameStreamDataBlocked.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .streamsBlockedBidirectional:
            FrameStreamsBlockedBidirectional.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .streamsBlockedUnidirectional:
            FrameStreamsBlockedUnidirectional.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .maxData:
            FrameMaxData.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .maxStreamData:
            FrameMaxStreamData.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .maxStreamsBidirectional:
            FrameMaxStreamsBidirectional.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .maxStreamsUnidirectional:
            FrameMaxStreamsUnidirectional.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .ping:
            FramePing.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .stream:
            FrameStreamSendMetadata.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .resetStream:
            FrameResetStream.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .stopSending:
            FrameStopSending.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .connectionClose:
            FrameConnectionClose.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .applicationClose:
            FrameApplicationClose.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        case .padding:
            FramePadding.addToPendingItems(
                &pendingItems,
                from: transmittedItems,
                connection: connection
            )
        }
    }

    var isAckEliciting: Bool { frameType.traits.isAckEliciting }
    var isInFlightEligible: Bool { frameType.traits.isInFlightEligible }
}

// MARK: - PendingItems (State for pending send)

@available(Network 0.1.0, *)
struct SimpleSendableItemsFlags: OptionSet {
    init(rawValue: Self.RawValue) {
        self.rawValue = rawValue
    }
    var rawValue: UInt32

    /// The flag for an item, at the bit that is the item's sending priority in `PrioritizedSendableItems`.
    /// That lets the packet writer find the next item to send from the flags alone (see `presentItemsMask`).
    init(_ item: PrioritizedSendableItems) {
        self.rawValue = item.maskBit
    }

    // The flags are built from `PrioritizedSendableItems`, never from a literal bit, so the order of that
    // list is the only order. `PrioritizedSendableItems.flag` is the other half: it requires every item to be
    // given a flag. Each flag here must be built from the item that `flag` maps back to it (checked by a test).
    static let sendCrypto = SimpleSendableItemsFlags(.crypto)
    static let newToken = SimpleSendableItemsFlags(.newToken)
    static let newConnectionID = SimpleSendableItemsFlags(.newConnectionID)
    static let retireConnectionID = SimpleSendableItemsFlags(.retireConnectionID)
    static let pathChallenge = SimpleSendableItemsFlags(.pathChallenge)
    static let pathResponse = SimpleSendableItemsFlags(.pathResponse)
    static let handshakeDone = SimpleSendableItemsFlags(.handshakeDone)
    static let ack = SimpleSendableItemsFlags(.ack)
    static let ping = SimpleSendableItemsFlags(.ping)
    static let datagram = SimpleSendableItemsFlags(.datagram)
    static let dataBlocked = SimpleSendableItemsFlags(.dataBlocked)
    static let streamDataBlocked = SimpleSendableItemsFlags(.streamDataBlocked)
    static let streamsBlockedBidirectional = SimpleSendableItemsFlags(.streamsBlockedBidirectional)
    static let streamsBlockedUnidirectional = SimpleSendableItemsFlags(.streamsBlockedUnidirectional)
    static let maxData = SimpleSendableItemsFlags(.maxData)
    static let maxStreamData = SimpleSendableItemsFlags(.maxStreamData)
    static let maxStreamsBidirectional = SimpleSendableItemsFlags(.maxStreamsBidirectional)
    static let maxStreamsUnidirectional = SimpleSendableItemsFlags(.maxStreamsUnidirectional)
    static let stream = SimpleSendableItemsFlags(.stream)
    static let resetStream = SimpleSendableItemsFlags(.resetStream)
    static let stopSendingFlag = SimpleSendableItemsFlags(.stopSending)
    static let connectionClose = SimpleSendableItemsFlags(.connectionClose)
    static let applicationClose = SimpleSendableItemsFlags(.applicationClose)
    // PADDING has no flag, so the bit after it is the first one that is not an item.
    static let isKeepalive = SimpleSendableItemsFlags(
        rawValue: PrioritizedSendableItems.padding.maskBit << 1
    )  // Flag to describe PING
    // The flags that stand for an item to send, which is all of them but `isKeepalive`.
    static let itemFlagsMask: UInt32 = PrioritizedSendableItems.padding.maskBit &- 1
}

@available(Network 0.1.0, *)
struct PendingItems: ~Copyable {
    let packetNumberSpace: PacketNumberSpace

    // MARK: State for sendable items

    // Flags specific to send items
    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt32
        static let triggerAllStreamsUnblocked = Flags(rawValue: 1 << 1)
    }
    private var flags = Flags()
    var triggerAllStreamsUnblocked: Bool {
        get { flags.contains(.triggerAllStreamsUnblocked) }
        set {
            if newValue {
                flags.insert(.triggerAllStreamsUnblocked)
            } else {
                flags.remove(.triggerAllStreamsUnblocked)
            }
        }
    }

    // Simple frame types that only need to store flags
    var simpleSendableItems = SimpleSendableItemsFlags(rawValue: 0)
    var ping: Bool {
        get { simpleSendableItems.contains(.ping) }
        set {
            if newValue {
                simpleSendableItems.insert(.ping)
            } else {
                simpleSendableItems.remove(.ping)
            }
        }
    }
    var maxData: Bool {
        get { simpleSendableItems.contains(.maxData) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxData)
            } else {
                simpleSendableItems.remove(.maxData)
            }
        }
    }
    var maxStreamsBidirectional: Bool {
        get { simpleSendableItems.contains(.maxStreamsBidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxStreamsBidirectional)
            } else {
                simpleSendableItems.remove(.maxStreamsBidirectional)
            }
        }
    }
    var maxStreamsUnidirectional: Bool {
        get { simpleSendableItems.contains(.maxStreamsUnidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxStreamsUnidirectional)
            } else {
                simpleSendableItems.remove(.maxStreamsUnidirectional)
            }
        }
    }
    var dataBlocked: Bool {
        get { simpleSendableItems.contains(.dataBlocked) }
        set {
            if newValue {
                simpleSendableItems.insert(.dataBlocked)
            } else {
                simpleSendableItems.remove(.dataBlocked)
            }
        }
    }
    var connectionClose: Bool {
        get { simpleSendableItems.contains(.connectionClose) }
        set {
            if newValue {
                simpleSendableItems.insert(.connectionClose)
            } else {
                simpleSendableItems.remove(.connectionClose)
            }
        }
    }
    var applicationClose: Bool {
        get { simpleSendableItems.contains(.applicationClose) }
        set {
            if newValue {
                simpleSendableItems.insert(.applicationClose)
            } else {
                simpleSendableItems.remove(.applicationClose)
            }
        }
    }
    var handshakeDone: Bool {
        get { simpleSendableItems.contains(.handshakeDone) }
        set {
            if newValue {
                simpleSendableItems.insert(.handshakeDone)
            } else {
                simpleSendableItems.remove(.handshakeDone)
            }
        }
    }
    var streamsBlockedBidirectional: Bool {
        get { simpleSendableItems.contains(.streamsBlockedBidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.streamsBlockedBidirectional)
            } else {
                simpleSendableItems.remove(.streamsBlockedBidirectional)
            }
        }
    }
    var streamsBlockedUnidirectional: Bool {
        get { simpleSendableItems.contains(.streamsBlockedUnidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.streamsBlockedUnidirectional)
            } else {
                simpleSendableItems.remove(.streamsBlockedUnidirectional)
            }
        }
    }
    var newToken: Bool {
        get { simpleSendableItems.contains(.newToken) }
        set {
            if newValue {
                simpleSendableItems.insert(.newToken)
            } else {
                simpleSendableItems.remove(.newToken)
            }
        }
    }
    var isKeepalive: Bool {
        get { simpleSendableItems.contains(.isKeepalive) }
        set {
            if newValue {
                simpleSendableItems.insert(.isKeepalive)
            } else {
                simpleSendableItems.remove(.isKeepalive)
            }
        }
    }
    var ack: Bool {
        get { simpleSendableItems.contains(.ack) }
        set {
            if newValue {
                simpleSendableItems.insert(.ack)
            } else {
                simpleSendableItems.remove(.ack)
            }
        }
    }
    var stream: Bool {
        get { simpleSendableItems.contains(.stream) }
        set {
            if newValue {
                simpleSendableItems.insert(.stream)
            } else {
                simpleSendableItems.remove(.stream)
            }
        }
    }
    var newConnectionID: Bool {
        get { simpleSendableItems.contains(.newConnectionID) }
        set {
            if newValue {
                simpleSendableItems.insert(.newConnectionID)
            } else {
                simpleSendableItems.remove(.newConnectionID)
            }
        }
    }
    var retireConnectionID: Bool {
        get { simpleSendableItems.contains(.retireConnectionID) }
        set {
            if newValue {
                simpleSendableItems.insert(.retireConnectionID)
            } else {
                simpleSendableItems.remove(.retireConnectionID)
            }
        }
    }
    var pathChallenge: Bool {
        get { simpleSendableItems.contains(.pathChallenge) }
        set {
            if newValue {
                simpleSendableItems.insert(.pathChallenge)
            } else {
                simpleSendableItems.remove(.pathChallenge)
            }
        }
    }
    var pathResponse: Bool {
        get { simpleSendableItems.contains(.pathResponse) }
        set {
            if newValue {
                simpleSendableItems.insert(.pathResponse)
            } else {
                simpleSendableItems.remove(.pathResponse)
            }
        }
    }
    var datagram: Bool {
        get { simpleSendableItems.contains(.datagram) }
        set {
            if newValue {
                simpleSendableItems.insert(.datagram)
            } else {
                simpleSendableItems.remove(.datagram)
            }
        }
    }
    var streamDataBlocked: Bool {
        get { simpleSendableItems.contains(.streamDataBlocked) }
        set {
            if newValue {
                simpleSendableItems.insert(.streamDataBlocked)
            } else {
                simpleSendableItems.remove(.streamDataBlocked)
            }
        }
    }
    var maxStreamData: Bool {
        get { simpleSendableItems.contains(.maxStreamData) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxStreamData)
            } else {
                simpleSendableItems.remove(.maxStreamData)
            }
        }
    }
    var resetStream: Bool {
        get { simpleSendableItems.contains(.resetStream) }
        set {
            if newValue {
                simpleSendableItems.insert(.resetStream)
            } else {
                simpleSendableItems.remove(.resetStream)
            }
        }
    }
    var stopSendingFlag: Bool {
        get { simpleSendableItems.contains(.stopSendingFlag) }
        set {
            if newValue {
                simpleSendableItems.insert(.stopSendingFlag)
            } else {
                simpleSendableItems.remove(.stopSendingFlag)
            }
        }
    }
    var sendCrypto: Bool {
        get { simpleSendableItems.contains(.sendCrypto) }
        set {
            if newValue {
                simpleSendableItems.insert(.sendCrypto)
            } else {
                simpleSendableItems.remove(.sendCrypto)
            }
        }
    }

    // Padding frame
    enum PaddingApproach: Equatable {
        case none
        case padToEnd
        case fixedSize(Int)
    }
    var paddingApproach = PaddingApproach.none

    var pmtudProbeMSS: Int?

    // Any retransmission of crypto
    var retransmitCrypto = NetworkUniqueDeque<TransmittedItems.SentCrypto>()
    // Temporary storage for written crypto
    var transmittedCrypto = NetworkUniqueDeque<TransmittedItems.SentCrypto>()

    // ACK frame, and potentially implicit PING frame. Note: Only one ACK frame!
    var ackFrame: FrameAck?
    @inline(always)
    mutating func setAckFrame(_ ackFrame: consuming QUICFrame, ping: Bool) {
        guard case .ack(let ackFrameInner) = ackFrame else {
            fatalError("setting non-ACK frame as ackFrame!")
        }

        self.ack = true
        self.ackFrame = consume ackFrameInner
        self.ping = self.ping || ping
    }
    var isAckSet: Bool { self.ack || FrameAck.isPresent(in: self) }
    var isAckOnly: Bool { self.simpleSendableItems == SimpleSendableItemsFlags.ack }
    var ackFrameLength: Int {
        switch ackFrame {
        case .some(let frame):
            return frame.writeLength
        case .none:
            return 0
        }
    }

    // Bookkeeping any Streams unblocked by reception of a new MAX_STREAM_DATA.
    // It should be filled when inboundStarting, and emptied upon inboundStopping.
    var unblockedSendStreams: QUICStreamList = QUICStreamList.unblockedSendStreamList()

    // STREAM frame(s)
    // Stream(s) that need to send STREAM frame(s)
    // The current served stream. Either from a new outbound application write,
    // or scheduling of continued sends, aka burst limit reschedule.

    // Streams that should be serviced for writing
    var streamsToService = Deque<MultiplexedFlowIdentifier>()
    // Any retransmission of streams
    var retransmitStreams = NetworkUniqueDeque<TransmittedItems.SentStream>()
    // Temporary storage for written streams
    var transmittedStreams = NetworkUniqueDeque<TransmittedItems.SentStream>()

    func canAddStreamToService(_ stream: borrowing QUICStreamInstance) -> Bool {
        canAddStreamToService(stream, connection: stream.parentProtocol)
    }

    // Callers that already hold the connection pass it in, which saves reading it back out of the
    // stream's parentProtocol.
    func canAddStreamToService(_ stream: borrowing QUICStreamInstance, connection: QUICConnection) -> Bool {
        !stream.send.state.dataHasAlreadyBeenSent
            && ((stream.hasMoreSendDataToService && stream.availableRemoteReceiveWindow(for: connection) > 0)
                || stream.send.buffer.hasLast)
    }

    mutating func rotateFirstStreamToService() {
        if let element = streamsToService.popFirst() {
            streamsToService.append(element)
        }
    }

    mutating func appendStreamToService(_ newStream: inout QUICStreamInstance) {
        appendStreamToService(&newStream, connection: newStream.parentProtocol)
    }

    mutating func appendStreamToService(_ newStream: inout QUICStreamInstance, connection: QUICConnection) {
        guard canAddStreamToService(newStream, connection: connection) else {
            // Nothing new to send
            return
        }
        guard !newStream.listMembership.contains(.sendable) else {
            // Already queued to be serviced
            return
        }
        newStream.listMembership.insert(.sendable)
        streamsToService.append(newStream.flowIdentifier)
        stream = true
    }

    mutating func prependStreamToService(_ newStream: inout QUICStreamInstance) {
        guard canAddStreamToService(newStream) else {
            // Nothing new to send
            return
        }
        guard !newStream.listMembership.contains(.sendable) else {
            // Already queued to be serviced
            return
        }
        newStream.listMembership.insert(.sendable)
        streamsToService.prepend(newStream.flowIdentifier)
        stream = true
    }

    @discardableResult
    mutating func popServicedStream() -> MultiplexedFlowIdentifier? {
        let element = streamsToService.popFirst()
        if streamsToService.isEmpty && retransmitStreams.isEmpty {
            stream = false
        }
        return element
    }

    // Streams for which to send MAX_STREAM_DATA frames
    var maxStreamDataFlows = Deque<MultiplexedFlowIdentifier>()
    mutating func appendMaxStreamDataFlow(_ flowID: MultiplexedFlowIdentifier) {
        if !maxStreamDataFlows.contains(flowID) {
            maxStreamDataFlows.append(flowID)
            maxStreamData = true
        }
    }

    // Streams for which to send STREAM_DATA_BLOCKED frames
    var streamDataBlockedFlows = Deque<MultiplexedFlowIdentifier>()
    mutating func appendStreamDataBlockedFlow(_ flowID: MultiplexedFlowIdentifier) {
        if !streamDataBlockedFlows.contains(flowID) {
            streamDataBlockedFlows.append(flowID)
            streamDataBlocked = true
        }
    }

    // Datagram flows that should be serviced for writing
    var datagramFlowsToService = Deque<MultiplexedFlowIdentifier>()

    mutating func prependDatagramFlowToService(_ flowID: MultiplexedFlowIdentifier) {
        if !datagramFlowsToService.contains(flowID) {
            datagramFlowsToService.prepend(flowID)
            datagram = true
        }
    }

    struct StreamReset {
        var streamID: UInt64
        var code: UInt64
        var finalSize: UInt64
    }
    var streamResets = Deque<StreamReset>()

    mutating func addStreamReset(streamID: UInt64, code: UInt64, finalSize: UInt64) {
        streamResets.append(StreamReset(streamID: streamID, code: code, finalSize: finalSize))
        resetStream = true
    }

    struct StreamStopSending {
        var streamID: UInt64
        var code: UInt64
    }
    var streamStopSendings = Deque<StreamStopSending>()

    mutating func addStreamStopSending(streamID: UInt64, code: UInt64) {
        streamStopSendings.append(StreamStopSending(streamID: streamID, code: code))
        stopSendingFlag = true
    }

    var newConnectionIDs = Deque<FrameNewConnectionID>()
    mutating func addNewConnectionID(_ frame: FrameNewConnectionID) {
        newConnectionIDs.append(frame)
        newConnectionID = true
    }

    var retireConnectionIDs = Deque<FrameRetireConnectionID>()
    mutating func addRetireConnectionID(_ frame: FrameRetireConnectionID) {
        retireConnectionIDs.append(frame)
        retireConnectionID = true
    }

    var pathChallenges = Deque<FramePathChallenge>()
    mutating func addPathChallenge(_ frame: FramePathChallenge) {
        pathChallenges.append(frame)
        pathChallenge = true
    }
    var pathResponses = Deque<FramePathResponse>()
    mutating func addPathResponse(_ frame: FramePathResponse) {
        pathResponses.append(frame)
        pathResponse = true
    }

    // End of sendable items

    // MARK: General methods

    mutating func flush() {
        self = PendingItems(packetNumberSpace: packetNumberSpace)
    }

    // Flush sendable streams for application space when the connection is flushed
    @discardableResult
    mutating func flushClearingQueuedStreams() -> Deque<MultiplexedFlowIdentifier> {
        let droppedStreams = streamsToService
        flush()
        return droppedStreams
    }

    init(packetNumberSpace: PacketNumberSpace) {
        self.packetNumberSpace = packetNumberSpace
    }

    var hasPendingItems: Bool {
        simpleSendableItems.rawValue > 0
    }

    var hasPadding: Bool {
        switch paddingApproach {
        case .none: return false
        default: return true
        }
    }

    /// The items present to send, one bit each at the item's `PrioritizedSendableItems` priority.
    ///
    /// Everything but crypto and padding is a flag. Crypto is present when there is also some to retransmit,
    /// and padding when `paddingApproach` asks for it.
    @inline(always)
    var presentItemsMask: UInt32 {
        var mask = simpleSendableItems.rawValue & SimpleSendableItemsFlags.itemFlagsMask
        if !retransmitCrypto.isEmpty {
            mask |= PrioritizedSendableItems.crypto.maskBit
        }
        if case .none = paddingApproach {
        } else {
            mask |= PrioritizedSendableItems.padding.maskBit
        }
        return mask
    }

    var hasAckElicitingPendingItems: Bool {
        for item in PrioritizedSendableItems.allCases {
            if item.isAckEliciting && item.isPresent(in: self) { return true }
        }
        return false
    }

    // Whether an Initial packet built from these items is padded to fill its datagram. A client pads
    // every datagram that carries an Initial packet, but a server only those carrying an ack-eliciting
    // one (RFC 9000 Section 14.1).
    func padsInitialPacket(isServer: Bool) -> Bool {
        !isServer || hasAckElicitingPendingItems
    }

    var hasNonInFlightEligiblePendingItems: Bool {
        for item in PrioritizedSendableItems.allCases {
            if !item.isInFlightEligible && item.isPresent(in: self) { return true }
        }
        return false
    }

    mutating func write(
        into frame: inout Frame,
        connection: QUICConnection,
        stats: inout Statistics,
        keyState: PacketKeyState,
        transmittedItems: inout TransmittedItems,
        availableCongestionWindow: UInt64,
        isAckEliciting: inout Bool,
        isInFlightEligible: inout Bool,
        maximumFrameCount: Int? = nil,
        shorthandFrames: inout [QUICShorthandFrame]?,
    ) throws(QUICError) {
        if keyState == .initial, padsInitialPacket(isServer: connection.isServer) {
            // Add PADDING in Initial key state, but only if there
            // are other send items.
            paddingApproach = .padToEnd
        }

        if !pathChallenges.isEmpty || !pathResponses.isEmpty {
            // Make sure to pad challenges to the end
            paddingApproach = .padToEnd
        }

        let originalAvailableLength = frame.unclaimedLength

        // Allow the congestion window calculations to be updated as we write
        var availableCongestionWindow = availableCongestionWindow

        // Add QUIC Frames in priority order
        var frameCount = 0
        let items = PrioritizedSendableItems.allCases
        var nextPriority = 0
        // Iterate through only the items to send in presentItemsMask. Bit `n` of the mask is the item with
        // raw value `n`, which is also its index in `PrioritizedSendableItems.allCases`.
        while true {
            let remaining = presentItemsMask & (UInt32.max &<< UInt32(truncatingIfNeeded: nextPriority))
            guard remaining != 0 else { break }
            let priority = remaining.trailingZeroBitCount
            nextPriority = priority &+ 1
            let item = items[priority]
            assert(item.isPresent(in: self), "\(item) is in the mask of present items but is not present")

            if case .padding = item, paddingApproach == .padToEnd {
                // Don't write padding to end if it is the only frame present
                let availableLength = frame.unclaimedLength
                let writtenPayloadLength = originalAvailableLength - availableLength
                guard writtenPayloadLength > 0 else {
                    continue
                }
            }

            do {
                if try item.write(
                    into: &frame,
                    pendingItems: &self,
                    connection: connection,
                    availableCongestionWindow: &availableCongestionWindow,
                    stats: &stats,
                    transmittedItems: &transmittedItems,
                    shorthandFrames: &shorthandFrames
                ) {
                    if item.isAckEliciting {
                        isAckEliciting = true
                    }
                    if item.isInFlightEligible {
                        isInFlightEligible = true
                    }
                    frameCount += 1
                }
            } catch {
                if case .frameWrite(let writeError) = error,
                    case .smallBuffer = writeError
                {
                    // Expected case, no more frames fit
                    break
                } else {
                    // True error case
                    throw error
                }
            }
            if let maximumFrameCount, frameCount >= maximumFrameCount {
                // PADDING does not count towards the limit, so a packet that must be padded, such as
                // an Initial, is still padded: skip to it, as it comes last.
                nextPriority = max(nextPriority, PrioritizedSendableItems.padding.rawValue)
            }
        }

        let finalAvailableLength = frame.unclaimedLength

        let payloadLength = originalAvailableLength - finalAvailableLength

        if payloadLength == 0 {
            // Nothing written, throw an error
            throw QUICError.packetBuilder(.noPayloadsWritten)
        }

        // Enable PADDING, if the payload is too small for the minimum
        if payloadLength < Constants.minimumPayloadLength {
            let extraPaddingSize = Constants.minimumPayloadLength - payloadLength
            paddingApproach = .fixedSize(extraPaddingSize)
            _ = try FramePadding.write(
                into: &frame,
                pendingItems: &self,
                connection: connection,
                availableCongestionWindow: &availableCongestionWindow,
                stats: &stats,
                transmittedItems: &transmittedItems,
                shorthandFrames: &shorthandFrames
            )
        }
    }

    mutating func copyForRetransmission(
        from transmittedItems: borrowing TransmittedItems,
        connection: QUICConnection
    ) {
        for item in PrioritizedSendableItems.allCases {
            item.addToPendingItems(
                &self,
                from: transmittedItems,
                connection: connection
            )
        }
    }
}

// MARK: - TransmittedItems (State for previous send)

@available(Network 0.1.0, *)
struct TransmittedItems: ~Copyable {
    var ping: Bool {
        get { simpleSendableItems.contains(.ping) }
        set {
            if newValue {
                simpleSendableItems.insert(.ping)
            } else {
                simpleSendableItems.remove(.ping)
            }
        }
    }
    var maxData: Bool {
        get { simpleSendableItems.contains(.maxData) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxData)
            } else {
                simpleSendableItems.remove(.maxData)
            }
        }
    }
    var maxStreamsBidirectional: Bool {
        get { simpleSendableItems.contains(.maxStreamsBidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxStreamsBidirectional)
            } else {
                simpleSendableItems.remove(.maxStreamsBidirectional)
            }
        }
    }
    var maxStreamsUnidirectional: Bool {
        get { simpleSendableItems.contains(.maxStreamsUnidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxStreamsUnidirectional)
            } else {
                simpleSendableItems.remove(.maxStreamsUnidirectional)
            }
        }
    }
    var dataBlocked: Bool {
        get { simpleSendableItems.contains(.dataBlocked) }
        set {
            if newValue {
                simpleSendableItems.insert(.dataBlocked)
            } else {
                simpleSendableItems.remove(.dataBlocked)
            }
        }
    }
    var connectionClose: Bool {
        get { simpleSendableItems.contains(.connectionClose) }
        set {
            if newValue {
                simpleSendableItems.insert(.connectionClose)
            } else {
                simpleSendableItems.remove(.connectionClose)
            }
        }
    }
    var applicationClose: Bool {
        get { simpleSendableItems.contains(.applicationClose) }
        set {
            if newValue {
                simpleSendableItems.insert(.applicationClose)
            } else {
                simpleSendableItems.remove(.applicationClose)
            }
        }
    }
    var handshakeDone: Bool {
        get { simpleSendableItems.contains(.handshakeDone) }
        set {
            if newValue {
                simpleSendableItems.insert(.handshakeDone)
            } else {
                simpleSendableItems.remove(.handshakeDone)
            }
        }
    }
    var streamsBlockedBidirectional: Bool {
        get { simpleSendableItems.contains(.streamsBlockedBidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.streamsBlockedBidirectional)
            } else {
                simpleSendableItems.remove(.streamsBlockedBidirectional)
            }
        }
    }
    var streamsBlockedUnidirectional: Bool {
        get { simpleSendableItems.contains(.streamsBlockedUnidirectional) }
        set {
            if newValue {
                simpleSendableItems.insert(.streamsBlockedUnidirectional)
            } else {
                simpleSendableItems.remove(.streamsBlockedUnidirectional)
            }
        }
    }
    var newToken: Bool {
        get { simpleSendableItems.contains(.newToken) }
        set {
            if newValue {
                simpleSendableItems.insert(.newToken)
            } else {
                simpleSendableItems.remove(.newToken)
            }
        }
    }
    var isKeepalive: Bool {
        get { simpleSendableItems.contains(.isKeepalive) }
        set {
            if newValue {
                simpleSendableItems.insert(.isKeepalive)
            } else {
                simpleSendableItems.remove(.isKeepalive)
            }
        }
    }
    var ack: Bool {
        get { simpleSendableItems.contains(.ack) }
        set {
            if newValue {
                simpleSendableItems.insert(.ack)
            } else {
                simpleSendableItems.remove(.ack)
            }
        }
    }
    var stream: Bool {
        get { simpleSendableItems.contains(.stream) }
        set {
            if newValue {
                simpleSendableItems.insert(.stream)
            } else {
                simpleSendableItems.remove(.stream)
            }
        }
    }
    var newConnectionID: Bool {
        get { simpleSendableItems.contains(.newConnectionID) }
        set {
            if newValue {
                simpleSendableItems.insert(.newConnectionID)
            } else {
                simpleSendableItems.remove(.newConnectionID)
            }
        }
    }
    var retireConnectionID: Bool {
        get { simpleSendableItems.contains(.retireConnectionID) }
        set {
            if newValue {
                simpleSendableItems.insert(.retireConnectionID)
            } else {
                simpleSendableItems.remove(.retireConnectionID)
            }
        }
    }
    var pathChallenge: Bool {
        get { simpleSendableItems.contains(.pathChallenge) }
        set {
            if newValue {
                simpleSendableItems.insert(.pathChallenge)
            } else {
                simpleSendableItems.remove(.pathChallenge)
            }
        }
    }
    var pathResponse: Bool {
        get { simpleSendableItems.contains(.pathResponse) }
        set {
            if newValue {
                simpleSendableItems.insert(.pathResponse)
            } else {
                simpleSendableItems.remove(.pathResponse)
            }
        }
    }
    var datagram: Bool {
        get { simpleSendableItems.contains(.datagram) }
        set {
            if newValue {
                simpleSendableItems.insert(.datagram)
            } else {
                simpleSendableItems.remove(.datagram)
            }
        }
    }
    var streamDataBlocked: Bool {
        get { simpleSendableItems.contains(.streamDataBlocked) }
        set {
            if newValue {
                simpleSendableItems.insert(.streamDataBlocked)
            } else {
                simpleSendableItems.remove(.streamDataBlocked)
            }
        }
    }
    var maxStreamData: Bool {
        get { simpleSendableItems.contains(.maxStreamData) }
        set {
            if newValue {
                simpleSendableItems.insert(.maxStreamData)
            } else {
                simpleSendableItems.remove(.maxStreamData)
            }
        }
    }
    var resetStream: Bool {
        get { simpleSendableItems.contains(.resetStream) }
        set {
            if newValue {
                simpleSendableItems.insert(.resetStream)
            } else {
                simpleSendableItems.remove(.resetStream)
            }
        }
    }
    var stopSendingFlag: Bool {
        get { simpleSendableItems.contains(.stopSendingFlag) }
        set {
            if newValue {
                simpleSendableItems.insert(.stopSendingFlag)
            } else {
                simpleSendableItems.remove(.stopSendingFlag)
            }
        }
    }
    var sendCrypto: Bool {
        get { simpleSendableItems.contains(.sendCrypto) }
        set {
            if newValue {
                simpleSendableItems.insert(.sendCrypto)
            } else {
                simpleSendableItems.remove(.sendCrypto)
            }
        }
    }

    struct SentCrypto: ~Copyable {
        let offset: UInt64
        let length: UInt64

        func matches(_ other: borrowing SentCrypto) -> Bool {
            offset == other.offset && length == other.length
        }
    }
    var sentCrypto = NetworkUniqueArray<SentCrypto>()

    // Minimal information about a send on a stream
    struct SentStream {
        let flowID: MultiplexedFlowIdentifier
        let streamID: QUICStreamID
        let offset: UInt64
        let length: UInt64
        let isFinal: Bool

        func matches(_ other: SentStream) -> Bool {
            flowID == other.flowID && streamID == other.streamID && offset == other.offset && length == other.length
                && isFinal == other.isFinal
        }
    }

    /// The stream sends a packet carried.
    ///
    /// A packet almost always carries a single stream, and every sent packet keeps its record until it is
    /// acknowledged or lost, so one send is held inline and only a second one allocates storage.
    struct SentStreams: ~Copyable {
        private enum Storage: ~Copyable {
            case empty
            case one(SentStream)
            case many(NetworkUniqueArray<SentStream>)
        }

        private var storage = Storage.empty

        var isEmpty: Bool {
            switch storage {
            case .empty: return true
            case .one: return false
            case .many(let sends): return sends.isEmpty
            }
        }

        var count: Int {
            switch storage {
            case .empty: return 0
            case .one: return 1
            case .many(let sends): return sends.count
            }
        }

        subscript(index: Int) -> SentStream {
            switch storage {
            case .empty:
                preconditionFailure("Index out of range")
            case .one(let send):
                precondition(index == 0, "Index out of range")
                return send
            case .many(let sends):
                return sends[index]
            }
        }

        mutating func append(_ sentStream: SentStream) {
            var taken = Storage.empty
            swap(&taken, &storage)
            switch consume taken {
            case .empty:
                storage = .one(sentStream)
            case .one(let first):
                var sends = NetworkUniqueArray<SentStream>(minimumCapacity: 2)
                sends.append(first)
                sends.append(sentStream)
                storage = .many(sends)
            case .many(var sends):
                sends.append(sentStream)
                storage = .many(sends)
            }
        }
    }

    struct TransmittedAckFrame: ~Copyable {
        var largest = PacketNumber.none
        var delay: UInt64 = 0
        var ranges: SmallArray<FrameAckRange>
        var pendingGap: PacketNumber?

        init?(_ ackFrame: consuming FrameAck?) {
            guard let ackFrame else { return nil }
            largest = ackFrame.largest
            delay = ackFrame.delay
            ranges = ackFrame.ranges
            pendingGap = ackFrame.pendingGap == .none ? nil : ackFrame.pendingGap
        }
    }
    // Fields are ordered in this manner to save padding
    var maxStreamDataFlows: Deque<MultiplexedFlowIdentifier>?
    var streamDataBlockedFlows: Deque<MultiplexedFlowIdentifier>?
    var streamResets: Deque<PendingItems.StreamReset>?
    var streamStopSendings: Deque<PendingItems.StreamStopSending>?
    var newConnectionIDs: Deque<FrameNewConnectionID>?
    var retireConnectionIDs: Deque<FrameRetireConnectionID>?
    var sentStreams = SentStreams()
    var simpleSendableItems = SimpleSendableItemsFlags(rawValue: 0)
    var ackFrame: TransmittedAckFrame?
    var pmtudProbeMSS: Int?

    // Add new Frame support here, unless it's covered by flags.
    // sentStreams and simpleSendableItems are checked first since they're the most common.
    // simpleSendableItems should cover any of the pending deque flags above
    var hasRetransmissibleItems: Bool {
        !sentStreams.isEmpty
            || simpleSendableItems.rawValue != 0
            || !sentCrypto.isEmpty
        // ackFrame is never retransmitted
    }

    func allAcknowledged(
        connection: QUICConnection,
        packetNumber: PacketNumber,
        packetNumberSpace: PacketNumberSpace,
        sentPath: QUICPath?,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch ackFrame {
        case .some(let frame):
            connection.acknowledgedAck(
                frame: frame,
                packetNumber: packetNumber,
                packetNumberSpace: packetNumberSpace,
                sentPath: sentPath
            )
        case .none:
            break
        }

        for i in 0..<sentStreams.count {
            connection.acknowledgedStream(
                flowID: sentStreams[i].flowID,
                offset: sentStreams[i].offset,
                length: sentStreams[i].length,
                isFinal: sentStreams[i].isFinal,
                in: &eventContext
            )
        }
        for i in 0..<sentCrypto.count {
            connection.crypto.acknowledged(
                offset: sentCrypto[i].offset,
                length: sentCrypto[i].length,
                for: packetNumberSpace
            )
        }

        if let streamResets {
            for streamReset in streamResets {
                connection.acknowledgedResetStream(id: streamReset.streamID, in: &eventContext)
            }
        }

        if let pmtudProbeMSS, let sentPath {
            connection.acknowledgedPMTUDProbe(
                on: sentPath,
                packetNumber: packetNumber,
                mss: pmtudProbeMSS,
                in: &eventContext
            )
        }

        if isKeepalive {
            connection.acknowledgedKeepalive()
        }
    }
}

#endif
