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

// MARK: PADDING
@available(Network 0.1.0, *)
extension FramePadding {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.padding(ShorthandFramePadding(outgoing: outgoing, frame: self))
    }
    static func toShorthandLogEntry(outgoing: Bool = true, length: Int16) -> QUICShorthandFrame {
        QUICShorthandFrame.padding(ShorthandFramePadding(outgoing: outgoing, length: length))
    }
}

@available(Network 0.1.0, *)
struct ShorthandFramePadding: ShorthandLogEntry {
    var outgoing: Bool
    let type = FrameType.padding
    let length: Int16

    init(outgoing: Bool, frame: borrowing FramePadding) {
        self.outgoing = outgoing
        var padding: Int16
        if let framePadding = frame.extraPadding {
            padding = Int16(framePadding)
        } else {
            padding = -1
        }
        length = padding
    }

    init(outgoing: Bool, length: Int16) {
        self.outgoing = outgoing
        self.length = length
    }

    var description: String {
        "PADDING[\(length)]"
    }
}

// MARK: RESET_STREAM
@available(Network 0.1.0, *)
extension FrameResetStream {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.resetStream(
            ShorthandFrameResetStream(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        id: UInt64,
        code: UInt64,
        finalSize: UInt64
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.resetStream(
            ShorthandFrameResetStream(
                outgoing: outgoing,
                id: id,
                code: code,
                finalSize: finalSize
            )
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameResetStream: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.resetStream
    let id: UInt64
    let code: UInt64
    let finalSize: UInt64

    init(outgoing: Bool, frame: borrowing FrameResetStream) {
        self.outgoing = outgoing
        id = frame.id
        code = frame.code
        finalSize = frame.finalSize
    }

    init(outgoing: Bool, id: UInt64, code: UInt64, finalSize: UInt64) {
        self.outgoing = outgoing
        self.id = id
        self.code = code
        self.finalSize = finalSize
    }

    var description: String {
        type.description()
            + "[id=\(id), code=\(code), fs=\(finalSize)]"
    }
}

// MARK: STOP_SENDING
@available(Network 0.1.0, *)
extension FrameStopSending {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.stopSending(
            ShorthandFrameStopSending(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        id: UInt64,
        code: UInt64
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.stopSending(
            ShorthandFrameStopSending(outgoing: outgoing, id: id, code: code)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameStopSending: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.stopSending
    let code: UInt64
    let id: UInt64

    init(outgoing: Bool, frame: borrowing FrameStopSending) {
        self.outgoing = outgoing
        code = frame.code
        id = frame.id
    }

    init(outgoing: Bool, id: UInt64, code: UInt64) {
        self.outgoing = outgoing
        self.id = id
        self.code = code
    }

    var description: String {
        type.description() + "[\(id), code=\(code)]"
    }
}

// MARK: CRYPTO
@available(Network 0.1.0, *)
extension FrameCrypto {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.crypto(ShorthandFrameCrypto(outgoing: outgoing, frame: self))
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        length: UInt64,
        offset: UInt64
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.crypto(
            ShorthandFrameCrypto(outgoing: outgoing, length: length, offset: offset)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameCrypto: ShorthandLogEntry {
    let type = FrameType.crypto
    let outgoing: Bool
    let length: UInt64
    let offset: UInt64

    init(outgoing: Bool, frame: borrowing FrameCrypto) {
        self.outgoing = outgoing
        length = UInt64(frame.length)
        offset = frame.offset
    }

    init(outgoing: Bool, length: UInt64, offset: UInt64) {
        self.outgoing = outgoing
        self.length = length
        self.offset = offset
    }

    var description: String {
        "CRYPTO[" + String(offset) + ";"
            + String(length + offset) + "]"
    }
}

@available(Network 0.1.0, *)
extension FrameAck {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.ack(ShorthandFrameAck(outgoing: outgoing, frame: self))
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        delay: UInt64,
        largest: PacketNumber,
        ranges: [FrameAckRange],
        ecnCounter: ECNCounter?
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.ack(
            ShorthandFrameAck(
                outgoing: outgoing,
                delay: delay,
                largest: largest,
                ranges: ranges,
                ecnCounter: ecnCounter
            )
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameAck: ShorthandLogEntry {
    let type: FrameType
    let delay: UInt64
    let largest: PacketNumber
    let ranges: [FrameAckRange]
    let ecnCounter: ECNCounter?
    let outgoing: Bool

    init(outgoing: Bool, frame: borrowing FrameAck) {
        largest = frame.largest
        ranges = frame.ranges
        ecnCounter = frame.ecnCounter
        self.outgoing = outgoing
        self.delay = frame.delay
        type = frame.type
    }

    init(
        outgoing: Bool,
        delay: UInt64,
        largest: PacketNumber,
        ranges: [FrameAckRange],
        ecnCounter: ECNCounter?
    ) {
        type = ecnCounter == nil ? FrameType.ack : FrameType.ackECN
        self.largest = largest
        self.ranges = ranges
        self.ecnCounter = ecnCounter
        self.outgoing = outgoing
        self.delay = delay
    }

    func buildAckRanges() -> [[Int64]] {
        if self.ranges.count == 0 {
            return [[largest.value]]
        } else {
            var ranges: [[Int64]] = []
            for block in Ack.blockSequence(shorthandFrame: self) {
                var innerRange = [Int64]()
                let start = block.start.value
                let end = block.end.value
                if start == end {
                    innerRange.append(start)
                } else {
                    innerRange.append(start)
                    innerRange.append(end)
                }
                ranges.append(innerRange)
            }
            return ranges.reversed()
        }
    }

    var description: String {
        var ackString = "\(type.description())["
        let ackRange = buildAckRanges()
        for range in ackRange {
            if range.count == 1 {
                ackString += "[\(String(range[0]))]"
            } else if range.count == 2 {
                ackString += "[\(String(range[0]))-\(String(range[1]))]"
            }
        }
        return ackString + "]"
    }
}

// MARK: MAX_DATA
@available(Network 0.1.0, *)
extension FrameMaxData {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.maxData(ShorthandFrameMaxData(outgoing: outgoing, frame: self))
    }
    static func toShorthandLogEntry(outgoing: Bool = true, max: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.maxData(ShorthandFrameMaxData(outgoing: outgoing, max: max))
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameMaxData: ShorthandLogEntry {
    var outgoing: Bool
    var type = FrameType.maxData
    var max: UInt64

    init(outgoing: Bool, frame: borrowing FrameMaxData) {
        self.outgoing = outgoing
        max = frame.max
    }

    init(outgoing: Bool, max: UInt64) {
        self.outgoing = outgoing
        self.max = max
    }

    var description: String {
        type.description() + "[\(max)]"
    }
}

// MARK: MAX_STREAM_DATA
@available(Network 0.1.0, *)
extension FrameMaxStreamData {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.maxStreamData(
            ShorthandFrameMaxStreamData(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        id: UInt64,
        max: UInt64
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.maxStreamData(
            ShorthandFrameMaxStreamData(outgoing: outgoing, id: id, max: max)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameMaxStreamData: ShorthandLogEntry {
    var type = FrameType.maxStreamData
    var outgoing: Bool
    var id: UInt64
    var max: UInt64

    init(outgoing: Bool, frame: borrowing FrameMaxStreamData) {
        self.outgoing = outgoing
        type = frame.type
        max = frame.max
        id = frame.id
    }

    init(outgoing: Bool, id: UInt64, max: UInt64) {
        self.outgoing = outgoing
        self.max = max
        self.id = id
    }

    var description: String {
        type.description() + "[id=\(id), \(max)]"
    }
}

// MARK: MAX_STREAMS_BIDI
@available(Network 0.1.0, *)
extension FrameMaxStreamsBidirectional {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.maxStreamsBidirectional(
            ShorthandFrameMaxStreamsBidirectional(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true, max: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.maxStreamsBidirectional(
            ShorthandFrameMaxStreamsBidirectional(outgoing: outgoing, max: max)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameMaxStreamsBidirectional: ShorthandLogEntry {
    let type = FrameType.maxStreamsBidirectional
    let outgoing: Bool
    let max: UInt64

    init(outgoing: Bool, frame: borrowing FrameMaxStreamsBidirectional) {
        self.outgoing = outgoing
        max = frame.max
    }

    init(outgoing: Bool, max: UInt64) {
        self.outgoing = outgoing
        self.max = max
    }

    var description: String {
        type.description() + "[\(max)]"
    }
}

// MARK: MAX_STREAMS_UNI
@available(Network 0.1.0, *)
extension FrameMaxStreamsUnidirectional {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.maxStreamsUnidirectional(
            ShorthandFrameMaxStreamsUnidirectional(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true, max: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.maxStreamsUnidirectional(
            ShorthandFrameMaxStreamsUnidirectional(outgoing: outgoing, max: max)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameMaxStreamsUnidirectional: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.maxStreamsUnidirectional
    let max: UInt64

    init(outgoing: Bool, frame: borrowing FrameMaxStreamsUnidirectional) {
        self.outgoing = outgoing
        max = frame.max
    }

    init(outgoing: Bool, max: UInt64) {
        self.outgoing = outgoing
        self.max = max
    }

    var description: String {
        type.description() + "[\(max)]"
    }
}

// MARK: DATA_BLOCKED
@available(Network 0.1.0, *)
extension FrameDataBlocked {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.dataBlocked(
            ShorthandFrameDataBlocked(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true, limit: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.dataBlocked(
            ShorthandFrameDataBlocked(outgoing: outgoing, limit: limit)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameDataBlocked: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.dataBlocked
    let limit: UInt64

    init(outgoing: Bool, frame: borrowing FrameDataBlocked) {
        self.outgoing = outgoing
        limit = frame.limit
    }

    init(outgoing: Bool, limit: UInt64) {
        self.outgoing = outgoing
        self.limit = limit
    }

    var description: String {
        type.description() + "[\(limit)]"
    }
}

// MARK: STREAM_DATA_BLOCKED
@available(Network 0.1.0, *)
extension FrameStreamDataBlocked {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.streamDataBlocked(
            ShorthandFrameStreamDataBlocked(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        id: UInt64,
        limit: UInt64
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.streamDataBlocked(
            ShorthandFrameStreamDataBlocked(outgoing: outgoing, id: id, limit: limit)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameStreamDataBlocked: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.streamDataBlocked
    let id: UInt64
    let limit: UInt64

    init(outgoing: Bool, frame: borrowing FrameStreamDataBlocked) {
        self.outgoing = outgoing
        id = frame.id
        limit = frame.limit
    }

    init(outgoing: Bool, id: UInt64, limit: UInt64) {
        self.outgoing = outgoing
        self.id = id
        self.limit = limit
    }

    var description: String {
        type.description() + "[id=\(id), \(limit)]"
    }
}

// MARK: STREAMS_BLOCKED_BIDI
@available(Network 0.1.0, *)
extension FrameStreamsBlockedBidirectional {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.streamsBlockedBidirectional(
            ShorthandFrameStreamsBlockedBidirectional(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true, limit: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.streamsBlockedBidirectional(
            ShorthandFrameStreamsBlockedBidirectional(outgoing: outgoing, limit: limit)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameStreamsBlockedBidirectional: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.streamsBlockedBidirectional
    let limit: UInt64

    init(outgoing: Bool, frame: borrowing FrameStreamsBlockedBidirectional) {
        self.outgoing = outgoing
        limit = frame.limit
    }

    init(outgoing: Bool, limit: UInt64) {
        self.outgoing = outgoing
        self.limit = limit
    }

    var description: String {
        type.description() + "[\(limit)]"
    }
}

// MARK: STREAMS_BLOCKED_UNI
@available(Network 0.1.0, *)
extension FrameStreamsBlockedUnidirectional {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.streamsBlockedUnidirectional(
            ShorthandFrameStreamsBlockedUnidirectional(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true, limit: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.streamsBlockedUnidirectional(
            ShorthandFrameStreamsBlockedUnidirectional(outgoing: outgoing, limit: limit)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameStreamsBlockedUnidirectional: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.streamsBlockedUnidirectional
    let limit: UInt64

    init(outgoing: Bool, frame: borrowing FrameStreamsBlockedUnidirectional) {
        self.outgoing = outgoing
        limit = frame.limit
    }

    init(outgoing: Bool, limit: UInt64) {
        self.outgoing = outgoing
        self.limit = limit
    }

    var description: String {
        type.description() + "[\(limit)]"
    }
}

@available(Network 0.1.0, *)
extension FrameNewConnectionID {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.newConnectionID(
            ShorthandFrameNewConnectionID(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        sequence: UInt64,
        retirePriorToSequence: UInt64,
        connectionID: QUICConnectionID
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.newConnectionID(
            ShorthandFrameNewConnectionID(
                outgoing: outgoing,
                sequence: sequence,
                retirePriorToSequence: retirePriorToSequence,
                connectionID: connectionID
            )
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameNewConnectionID: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.newConnectionID
    let sequence: UInt64
    let retirePriorToSequence: UInt64
    let connectionID: QUICConnectionID

    init(outgoing: Bool, frame: FrameNewConnectionID) {
        self.outgoing = outgoing
        sequence = UInt64(frame.sequence)
        retirePriorToSequence = frame.retirePriorToSequence
        connectionID = frame.connectionID
    }

    init(
        outgoing: Bool,
        sequence: UInt64,
        retirePriorToSequence: UInt64,
        connectionID: QUICConnectionID
    ) {
        self.outgoing = outgoing
        self.sequence = sequence
        self.retirePriorToSequence = retirePriorToSequence
        self.connectionID = connectionID
    }

    var description: String {
        type.description() + "[seq=\(sequence), retire=\(retirePriorToSequence)]"
    }
}

// MARK: RETIRE_CONNECTION_ID
@available(Network 0.1.0, *)
extension FrameRetireConnectionID {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.retireConnectionID(
            ShorthandFrameRetireConnectionID(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true, sequence: UInt64) -> QUICShorthandFrame {
        QUICShorthandFrame.retireConnectionID(
            ShorthandFrameRetireConnectionID(outgoing: outgoing, sequence: sequence)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameRetireConnectionID: ShorthandLogEntry {
    let outgoing: Bool
    let type = FrameType.retireConnectionID
    let sequence: UInt64

    init(outgoing: Bool, frame: FrameRetireConnectionID) {
        self.outgoing = outgoing
        sequence = frame.sequence
    }

    init(outgoing: Bool, sequence: UInt64) {
        self.outgoing = outgoing
        self.sequence = sequence
    }

    var description: String {
        type.description() + "[\(sequence)]"
    }
}

// MARK: CONNECTION_CLOSE
@available(Network 0.1.0, *)
extension FrameConnectionClose {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.connectionClose(
            ShorthandFrameConnectionClose(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        errorCode: UInt64,
        frameType: UInt64?,
        reason: String?
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.connectionClose(
            ShorthandFrameConnectionClose(
                outgoing: outgoing,
                errorCode: errorCode,
                frameType: frameType,
                reason: reason
            )
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameConnectionClose: ShorthandLogEntry {
    let outgoing: Bool
    let errorCode: UInt64
    let frameType: UInt64
    let reason: String
    let type = FrameType.connectionClose

    init(outgoing: Bool, frame: borrowing FrameConnectionClose) {
        self.outgoing = outgoing
        errorCode = frame.errorCode
        frameType = frame.frameType.rawValue
        reason = frame.reason
    }

    init(outgoing: Bool, errorCode: UInt64, frameType: UInt64?, reason: String?) {
        self.outgoing = outgoing
        self.errorCode = errorCode
        if let frameType {
            self.frameType = frameType
        } else {
            self.frameType = 0
        }
        self.reason = reason ?? ""
    }

    var description: String {
        type.description() + "[code=\(errorCode), type=\(frameType)]"
    }
}

// MARK: APPLICATION_CLOSE
@available(Network 0.1.0, *)
extension FrameApplicationClose {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.applicationClose(
            ShorthandFrameApplicationClose(outgoing: outgoing, frame: self)
        )
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        errorCode: UInt64,
        reason: String?
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.applicationClose(
            ShorthandFrameApplicationClose(outgoing: outgoing, errorCode: errorCode, reason: reason)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameApplicationClose: ShorthandLogEntry {
    let outgoing: Bool
    let errorCode: UInt64
    let reason: String
    let type = FrameType.applicationClose

    init(outgoing: Bool, frame: borrowing FrameApplicationClose) {
        self.outgoing = outgoing
        errorCode = frame.errorCode
        reason = frame.reason
    }

    init(outgoing: Bool, errorCode: UInt64, reason: String?) {
        self.outgoing = outgoing
        self.errorCode = errorCode
        self.reason = reason ?? ""
    }

    var description: String {
        type.description() + "[code=\(errorCode)]"
    }
}

// MARK: DATAGRAM
// MARK: DATAGRAM_LEN
@available(Network 0.1.0, *)
extension FrameDatagram {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.datagram(ShorthandFrameDatagram(outgoing: outgoing, frame: self))
    }
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        flowID: UInt64?,
        length: UInt64
    ) -> QUICShorthandFrame {
        QUICShorthandFrame.datagram(
            ShorthandFrameDatagram(outgoing: outgoing, flowID: flowID, length: length)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameDatagram: ShorthandLogEntry {
    let outgoing: Bool
    let type: FrameType
    let flowID: UInt64?
    let length: UInt64

    init(outgoing: Bool, frame: borrowing FrameDatagram) {
        self.outgoing = outgoing
        type = frame.type
        flowID = frame.flowID
        length = UInt64(frame.length)
    }

    init(outgoing: Bool, flowID: UInt64?, length: UInt64) {
        self.outgoing = outgoing
        type = FrameType.datagram(hasLength: true)
        self.flowID = flowID
        self.length = length
    }

    var description: String {
        if let flowID {
            return "D\(flowID)[\(length)]"
        } else {
            return "D[\(length)]"
        }
    }
}

//STREAM_FIRST, ..., STREAM_LAST:
// MARK: STREAM
@available(Network 0.1.0, *)
extension FrameStreamReceived {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        precondition(!outgoing)
        return QUICShorthandFrame.stream(ShorthandFrameStream(outgoing: outgoing, frame: self))
    }
}

@available(Network 0.1.0, *)
extension FrameStreamSendMetadata {
    static func toShorthandLogEntry(
        outgoing: Bool = true,
        id: UInt64,
        fin: Bool,
        offset: UInt64,
        length: UInt64
    ) -> QUICShorthandFrame {
        precondition(outgoing)
        return QUICShorthandFrame.stream(
            ShorthandFrameStream(
                outgoing: outgoing,
                id: id,
                fin: fin,
                offset: offset,
                length: length
            )
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameStream: ShorthandLogEntry {
    let outgoing: Bool
    let type: FrameType
    let id: UInt64
    let fin: Bool
    let offset: UInt64
    let length: UInt64

    init(outgoing: Bool, frame: borrowing FrameStreamReceived) {
        self.outgoing = outgoing
        type = frame.type
        fin = frame.isFinal
        id = frame.id
        offset = frame.offset
        length = UInt64(frame.length)
    }
    init(outgoing: Bool, id: UInt64, fin: Bool, offset: UInt64, length: UInt64) {
        self.outgoing = outgoing
        self.fin = fin
        self.id = id
        self.offset = offset
        self.length = length

        let flag = FrameStreamFlag.fromFields(
            hasOffset: offset > 0,
            hasLength: length > 0,
            hasFinal: fin
        )
        type = FrameType.stream(flag: flag)
    }

    var description: String {
        var description =
            "S\(id)[\(offset);\(offset + length)]"
        description += (fin) ? " FIN" : ""
        return description
    }
}

// The following shorthand types are logged only as their frame type.description.
// Emit all as ShorthandFrameGeneric() entries.
// MARK: HANDSHAKE_DONE
@available(Network 0.1.0, *)
extension FrameHandshakeDone {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.handshakeDone(
            ShorthandFrameGeneric(outgoing: outgoing, type: type)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true) -> QUICShorthandFrame {
        QUICShorthandFrame.handshakeDone(
            ShorthandFrameGeneric(outgoing: outgoing, type: FrameType.handshakeDone)
        )
    }
}
// MARK: PING
@available(Network 0.1.0, *)
extension FramePing {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.ping(ShorthandFrameGeneric(outgoing: outgoing, type: type))
    }
    static func toShorthandLogEntry(outgoing: Bool = true) -> QUICShorthandFrame {
        QUICShorthandFrame.ping(
            ShorthandFrameGeneric(outgoing: outgoing, type: FrameType.ping)
        )
    }
}

// MARK: NEW_TOKEN
@available(Network 0.1.0, *)
extension FrameNewToken {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.newToken(ShorthandFrameNewToken(outgoing: outgoing, frame: self))
    }
    static func toShorthandLogEntry(outgoing: Bool = true, length: Int) -> QUICShorthandFrame {
        QUICShorthandFrame.newToken(
            ShorthandFrameNewToken(outgoing: outgoing, length: length)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameNewToken: ShorthandLogEntry {
    let outgoing: Bool
    let length: Int
    let type = FrameType.newToken

    init(outgoing: Bool, frame: borrowing FrameNewToken) {
        self.outgoing = outgoing
        length = frame.token.count
    }

    init(outgoing: Bool, length: Int) {
        self.outgoing = outgoing
        self.length = length
    }

    var description: String {
        type.description() + "[\(length)]"
    }
}

// MARK: PATH_CHALLENGE
@available(Network 0.1.0, *)
extension FramePathChallenge {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.pathChallenge(
            ShorthandFrameGeneric(outgoing: outgoing, type: type)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true) -> QUICShorthandFrame {
        QUICShorthandFrame.pathChallenge(
            ShorthandFrameGeneric(outgoing: outgoing, type: FrameType.pathChallenge)
        )
    }
}

// MARK: PATH_RESPONSE
@available(Network 0.1.0, *)
extension FramePathResponse {
    func toShorthandLogEntry(outgoing: Bool) -> QUICShorthandFrame {
        QUICShorthandFrame.pathResponse(
            ShorthandFrameGeneric(outgoing: outgoing, type: type)
        )
    }
    static func toShorthandLogEntry(outgoing: Bool = true) -> QUICShorthandFrame {
        QUICShorthandFrame.pathResponse(
            ShorthandFrameGeneric(outgoing: outgoing, type: FrameType.pathResponse)
        )
    }
}

@available(Network 0.1.0, *)
struct ShorthandFrameGeneric: ShorthandLogEntry {
    let outgoing: Bool
    private(set) var type: FrameType
    init(outgoing: Bool, type: FrameType) {
        self.outgoing = outgoing
        self.type = type
    }

    init() {
        outgoing = false
        type = .ping
    }

    var description: String {
        type.description()
    }
}
#endif
