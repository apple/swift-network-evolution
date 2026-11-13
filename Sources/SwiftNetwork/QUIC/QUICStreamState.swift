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

    // Valid transitions per RFC 9000, Figure 2.
    func canTransition(to newState: QUICSendStreamState) -> Bool {
        switch (self, newState) {
        // Sending.
        case (.invalid, .ready),  // stream created
            (.ready, .send),  // snd STREAM
            (.send, .dataSent),  // snd STREAM with FIN
            (.dataSent, .dataReceived):  // rcv all ACKs
            return true

        // Reset.
        case (.ready, .resetSent),  // snd RESET_STREAM
            (.send, .resetSent),  // snd RESET_STREAM
            (.dataSent, .resetSent),  // snd RESET_STREAM
            (.resetSent, .resetReceived):  // rcv ACK of RESET_STREAM
            return true

        // Not in Figure 2: a reset requested after all data was acknowledged.
        case (.dataReceived, .resetSent):
            return true

        default:
            return false
        }
    }

    var dataHasAlreadyBeenSent: Bool {
        switch self {
        case .dataSent, .resetSent, .dataReceived, .resetReceived:
            return true
        default:
            return false
        }
    }

    /// The send side has reached a terminal state (all data ACKed, or the reset ACKed).
    var isTerminal: Bool {
        switch self {
        case .dataReceived, .resetReceived:
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
    // Set through QUICStreamInstance.sendState, which logs the transition with the stream's log prefix.
    fileprivate(set) var state = QUICSendStreamState()

    /// Queues `frame` for sending. Returns true for the first write on the stream, which still
    /// has to move the state out of `.ready`
    mutating func enqueue(_ frame: consuming Frame, isLast: Bool) -> Bool {
        let isFirstWrite = state == .ready
        buffer.addSendData(frame, isLast: isLast)
        return isFirstWrite
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

    // Valid transitions per RFC 9000, Figure 3.
    func canTransition(to newState: QUICReceiveStreamState) -> Bool {
        switch (self, newState) {
        // Receiving.
        case (.invalid, .receive),  // stream created
            (.receive, .sizeKnown),  // rcv STREAM with FIN
            (.sizeKnown, .dataReceived),  // rcv all data
            (.dataReceived, .dataRead):  // app read all data
            return true

        // Reset.
        case (.receive, .resetReceived),  // rcv RESET_STREAM
            (.sizeKnown, .resetReceived),  // rcv RESET_STREAM
            (.dataReceived, .resetReceived),  // rcv RESET_STREAM
            (.resetReceived, .resetRead):  // app read reset
            return true

        // Not in Figure 3: the remaining data arrives after a RESET_STREAM.
        case (.resetReceived, .dataReceived):
            return true

        default:
            return false
        }
    }

    var dataHasAlreadyBeenReceived: Bool {
        switch self {
        case .dataReceived, .resetReceived, .dataRead, .resetRead:
            return true
        default:
            return false
        }
    }

    /// The receive side has reached a terminal state (all data read, or the reset received/read).
    var isTerminal: Bool {
        switch self {
        case .dataRead, .resetReceived, .resetRead:
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
    // Set through QUICStreamInstance.receiveState, which logs the transition with the stream's log
    // prefix.
    fileprivate(set) var state = QUICReceiveStreamState()

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

// The stream's send and receive states are set here rather than on QUICSendState and
// QUICReceiveState, which have no logger, so the transition logs carry the stream's log prefix.
@available(Network 0.1.0, *)
extension QUICStreamInstance {
    var sendState: QUICSendStreamState {
        get { send.state }
        set {
            let oldState = send.state
            log.debug("Send stream transition: \(oldState) -> \(newValue)")
            if !oldState.canTransition(to: newValue) {
                log.fault("Invalid send stream transition: \(oldState) -> \(newValue)")
            }
            send.state = newValue
        }
    }

    var receiveState: QUICReceiveStreamState {
        get { receive.state }
        set {
            let oldState = receive.state
            log.debug("Receive stream transition: \(oldState) -> \(newValue)")
            if !oldState.canTransition(to: newValue) {
                log.fault("Invalid receive stream transition: \(oldState) -> \(newValue)")
            }
            receive.state = newValue
        }
    }
}

#endif
