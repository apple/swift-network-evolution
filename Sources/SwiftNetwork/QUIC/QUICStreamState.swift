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

// Note: This is CaseIterable only so that tests can ensure it checks all states
@available(Network 0.1.0, *)
enum QUICSendStreamState: UInt8, CaseIterable, CustomStringConvertible {
    case invalid
    case ready
    case send
    case dataSent
    case resetSent
    case dataReceived
    case resetReceived

    init(state: QUICSendStreamState = .invalid) {
        self = state
    }

    var description: String {
        switch self {
        case .invalid: return "invalid"
        case .ready: return "ready"
        case .send: return "send"
        case .dataSent: return "dataSent"
        case .resetSent: return "resetSent"
        case .dataReceived: return "dataReceived"
        case .resetReceived: return "resetReceived"
        }
    }

    func isValidStateChange(logIDString: String, to newState: QUICSendStreamState) -> Bool {
        switch (self, newState) {
        case (.invalid, .ready),
            (.ready, .send),
            (.ready, .resetSent),
            (.send, .dataSent),
            (.send, .resetSent),
            (.dataSent, .resetSent),
            (.dataSent, .dataReceived),
            (.resetSent, .resetReceived),
            (.dataReceived, .resetSent):
            return true
        default:
            Logger.proto.fault(
                "\(logIDString) Invalid send stream transition : \(self) -> \(newState)"
            )
            return false
        }
    }

    mutating func change(logIDString: String, to newState: QUICSendStreamState) {
        #if !DisableDebugLogging
        let loggableSelf = self
        Logger.proto.debug("\(logIDString) send stream transition: \(loggableSelf) -> \(newState)")
        #endif
        _ = isValidStateChange(logIDString: logIDString, to: newState)
        self = newState
    }

    var dataHasAlreadyBeenSent: Bool {
        switch self {
        case .dataSent, .resetSent, .dataReceived, .resetReceived:
            return true
        default:
            return false
        }
    }
}

// Bundles the streams outbound send buffer and send-state enum into a single stored
// property on QUICStreamInstance, so operations that touch both take one dynamic access
// instead of two.
@available(Network 0.1.0, *)
struct QUICSendState: ~Copyable {
    var buffer = StreamSendBuffer()
    var state = QUICSendStreamState()

    /// Queues `frame` for sending. Returns true for the first write on the stream, which still
    /// has to move the state out of `.ready` with `startSending(logIDString:)`
    mutating func enqueue(_ frame: consuming Frame, isLast: Bool) -> Bool {
        let isFirstWrite = state == .ready
        buffer.addSendData(frame, isLast: isLast)
        return isFirstWrite
    }

    mutating func startSending(logIDString: String) {
        state.change(logIDString: logIDString, to: .send)
    }

    mutating func recordSent(isFinal: Bool, logPrefix: String) {
        if isFinal, state == .send {
            state.change(logIDString: logPrefix, to: .dataSent)
        }
    }

    // To be called when 0-RTT sending is rejected.
    mutating func reset() {
        state = .ready
        buffer.empty()
        buffer = StreamSendBuffer()
    }
}

// Note: It is CaseIterable only so that tests can ensure it checks all states
@available(Network 0.1.0, *)
enum QUICReceiveStreamState: CaseIterable, CustomStringConvertible {
    case invalid
    case receive
    case sizeKnown
    case dataReceived
    case resetReceived
    case dataRead
    case resetRead  // Not used, but part of RFC 9000.

    init(state: QUICReceiveStreamState = .invalid) {
        self = state
    }

    var description: String {
        switch self {
        case .invalid: return "invalid"
        case .receive: return "receive"
        case .sizeKnown: return "sizeKnown"
        case .dataReceived: return "dataReceived"
        case .resetReceived: return "resetReceived"
        case .dataRead: return "dataRead"
        case .resetRead: return "resetRead"
        }
    }

    func isValidStateChange(logIDString: String, to newState: QUICReceiveStreamState) -> Bool {
        switch (self, newState) {
        case (.invalid, .receive),
            (.receive, .sizeKnown),
            (.receive, .resetReceived),
            (.sizeKnown, .dataReceived),
            (.sizeKnown, .resetReceived),
            (.dataReceived, .dataRead),
            (.dataReceived, .resetReceived),
            (.resetReceived, .dataReceived),
            (.resetReceived, .resetRead):
            return true
        default:
            Logger.proto.fault(
                "\(logIDString) Invalid receive stream transition : \(self) -> \(newState)"
            )
            return false
        }
    }

    mutating func change(logIDString: String, to newState: QUICReceiveStreamState) {
        #if !DisableDebugLogging
        let loggableSelf = self
        Logger.proto.debug(
            "\(logIDString) receive stream transition: \(loggableSelf) -> \(newState)"
        )
        #endif
        _ = isValidStateChange(logIDString: logIDString, to: newState)
        self = newState
    }

    var dataHasAlreadyBeenReceived: Bool {
        switch self {
        case .dataReceived, .resetReceived, .dataRead, .resetRead:
            return true
        default:
            return false
        }
    }

    var isReceivingData: Bool {
        switch self {
        case .receive, .sizeKnown:
            return true
        default:
            return false
        }
    }

    var isSizeKnown: Bool {
        switch self {
        case .invalid, .receive:
            return false
        default:
            return true
        }
    }
}

// Bundles the streams reassembly queue and receive-state tracking into a single stored
// property on QUICStreamInstance, so operations that touch several of them take one dynamic
// access instead of many.
@available(Network 0.1.0, *)
struct QUICReceiveState: ~Copyable {
    var reassemblyQueue = ReassemblyQueue()
    var state = QUICReceiveStreamState()

    mutating func tryAppend(
        frame: consuming Frame,
        offset: Int,
        fin: Bool,
        maximumUnreadInboundBytesAllowed: UInt64
    ) -> ReassemblyQueue.AppendResult? {
        guard reassemblyQueue.canAppendItemsForByteLimit(maximumUnreadInboundBytesAllowed).acceptable else {
            var frame = frame
            frame.finalize(success: false)
            return nil
        }
        return reassemblyQueue.append(frame: frame, offset: offset, fin: fin)
    }

    mutating func markSizeKnownIfNeeded(logPrefix: String) {
        if state != .sizeKnown {
            state.change(logIDString: logPrefix, to: .sizeKnown)
        }
    }

    // Returns true if newOffset is past finOffset, a protocol violation the caller must close on.
    mutating func markDataReceivedIfReached(newOffset: Int, finOffset: Int, logPrefix: String) -> Bool {
        if newOffset == finOffset {
            state.change(logIDString: logPrefix, to: .dataReceived)
        }
        return newOffset > finOffset
    }

    mutating func dequeueReassembled(
        markedFIN: inout Bool,
        log: borrowing NetworkLoggerState
    ) -> FrameArray? {
        let totalLength = reassemblyQueue.availableToDequeue
        log.datapath("Total available reassembled data \(totalLength)")
        guard totalLength >= 0 else {
            log.error("Reassembled data length cannot be negative")
            return nil
        }
        if totalLength == 0 {
            guard reassemblyQueue.finOffset == self.reassemblyQueue.currentOffset && state != .dataRead
            else {
                return nil
            }
        }
        var frameArray = FrameArray(capacity: reassemblyQueue.items.count)
        var writtenCount: Int = 0
        while let item = reassemblyQueue.dequeue() {
            if writtenCount + item.length > totalLength {
                // This is a ReassemblyQueue bug, hopefully retransmission will recover
                // Therefore `deliveredInboundBytes` is called below, so all the accounting is
                // kept correct.
                log.error("Reassembled dequeued data length > available length, dropping data")
                break
            }

            let itemLength = item.length
            writtenCount += itemLength
            log.datapath("Dequeued length \(itemLength)")

            var frame = item.frame

            // When we receive the FIN bit in a separate frame
            // and the reassembly queue is empty, we create a
            // zero-length entry in the reassembly queue.
            // Later on, we may fill the gap in the reassembly
            // queue and deliver the FIN bit along with the data
            // but the "fake" item in the reassembly queue still
            // needs to be dequeued and that's the reason why
            // we check that we're in the right state before
            // delivering the FIN bit.
            if item.fin && !markedFIN {
                log.datapath("Marking FIN on received frame")
                markedFIN = true
                frame.metadataComplete = true
                frame.connectionComplete = true
            }

            frameArray.add(frame: frame)
        }
        if writtenCount < totalLength {
            // This is a ReassemblyQueue bug, but should be recoverable
            log.error(
                "Reassembled dequeued data length \(writtenCount) < available length \(totalLength)"
            )
        }

        return frameArray
    }
}
#endif
