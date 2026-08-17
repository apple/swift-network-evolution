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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// MARK: FlowControlGlobals

// FlowControlGlobals assumes that it is only setting a static collection of constants.
@available(Network 0.1.0, *)
struct FlowControlGlobals: ~Copyable {

    // Flow Control Constants
    static let sendQueueFactor: UInt64 = 10
    #if NETWORK_EMBEDDED
    static private let highWaterMarkMax = 50 * 1024  // 50KB
    static private let initialReceiveSpace = 50 * 1024  // 50KB
    #else
    static private let highWaterMarkMax = 4 * 1024 * 1024  // 4MB
    static private let initialReceiveSpace = 2 * 1024 * 1024  // 2MB
    #endif

    // N.B.: values are different for systems with less than 4GB of RAM.
    static private let defaultMaxStreams = 8
    static private let defaultMaxConcurrentStreams = defaultMaxStreams
    static private let defaultMaxBidirectionalStreams = defaultMaxStreams
    static private let defaultMaxUnidirectionalStreams = defaultMaxStreams

    // Flow Control Globals
    static let shared = FlowControlGlobals()

    let initialMaxBidirectionalStreamLocalData: Int
    let initialMaxBidirectionalStreamRemoteData: Int
    let initialMaxUnidirectionalStreamData: Int
    let initialMaxData: Int

    let maxConcurrentStreams: Int
    let streamReceiveHighWaterMarkMax: Int
    let streamSendHighWaterMarkMax: Int
    let initialStreamReceiveSpace: Int
    let initialStreamSendSpace: Int

    let connectionReceiveHighWaterMarkMax: Int
    let connectionSendHighWaterMarkMax: Int
    let initialConnectionReceiveSpace: Int
    let initialConnectionSendSpace: Int

    private init() {
        let isHighMemorySystem = System.isHighMemory()

        // maximum concurrent streams
        if let maxConcurrentStreams = QUICPreferences.shared.maxConcurrentStreams {
            self.maxConcurrentStreams = maxConcurrentStreams
        } else if isHighMemorySystem {
            maxConcurrentStreams = FlowControlGlobals.defaultMaxConcurrentStreams
        } else {
            maxConcurrentStreams = FlowControlGlobals.defaultMaxConcurrentStreams / 2
        }

        // stream receive & send high water mark max
        if let highWaterMarkMax = QUICPreferences.shared.streamMaxReceiveWindow {
            streamReceiveHighWaterMarkMax = highWaterMarkMax
            streamSendHighWaterMarkMax = highWaterMarkMax
        } else if isHighMemorySystem {
            streamReceiveHighWaterMarkMax = FlowControlGlobals.highWaterMarkMax
            streamSendHighWaterMarkMax = FlowControlGlobals.highWaterMarkMax
        } else {
            streamReceiveHighWaterMarkMax = FlowControlGlobals.highWaterMarkMax / 2
            streamSendHighWaterMarkMax = FlowControlGlobals.highWaterMarkMax / 2
        }

        // connection receive & send high water mark max
        connectionReceiveHighWaterMarkMax = streamReceiveHighWaterMarkMax * maxConcurrentStreams
        connectionSendHighWaterMarkMax = streamSendHighWaterMarkMax * maxConcurrentStreams

        // initial max data
        if let initialMaxData = QUICPreferences.shared.initialMaxData {
            self.initialMaxData = initialMaxData
        } else {
            initialMaxData = FlowControlGlobals.initialReceiveSpace * maxConcurrentStreams
        }

        // initial stream receive space
        if let initialStreamReceiveSpace = QUICPreferences.shared.initialStreamReceiveSpace {
            self.initialStreamReceiveSpace = initialStreamReceiveSpace
        } else {
            initialStreamReceiveSpace = FlowControlGlobals.initialReceiveSpace
        }

        // initial connection receive & send space
        initialStreamSendSpace = Int(FlowControlGlobals.sendQueueFactor) * Constants.initialMSS
        initialConnectionSendSpace = initialStreamSendSpace * maxConcurrentStreams
        if let initialConnectionReceiveSpace = QUICPreferences.shared.initialConnectionReceiveSpace {
            self.initialConnectionReceiveSpace = initialConnectionReceiveSpace
        } else {
            initialConnectionReceiveSpace = initialStreamReceiveSpace
        }

        // initial max bidirectional stream local data
        if let initialMaxBidirectionalStreamLocalData = QUICPreferences.shared
            .initialMaxStreamBidirectionalLocalData
        {
            self.initialMaxBidirectionalStreamLocalData = initialMaxBidirectionalStreamLocalData
        } else {
            initialMaxBidirectionalStreamLocalData = FlowControlGlobals.initialReceiveSpace
        }

        initialMaxBidirectionalStreamRemoteData = FlowControlGlobals.initialReceiveSpace
        initialMaxUnidirectionalStreamData = FlowControlGlobals.initialReceiveSpace
    }
}

// MARK: FlowControl

// Storage for flow control state
// For streams, these values are per-stream byte counts.
// For connections, these values are summed across all streams.
@available(Network 0.1.0, *)
struct FlowControlState: ~Copyable {

    // Inbound values (receiving):

    // Maximum number of bytes allowed to be sent by the peer,
    // as advertised in MAX_DATA / MAX_STREAM_DATA
    fileprivate(set) var inboundMaxData: UInt64 = 0

    // Number of bytes beyond those already delivered
    // that that are allowed to be sent by the peer.
    // This value is a policy that is used to determine
    // the value of `inboundMaxData`. This value automatically
    // can adjust based on feedback.
    fileprivate(set) var maximumUnreadInboundBytesAllowed: UInt64

    // Number of bytes that have been read in-order
    // from the peer. This is the total number of bytes
    // eligible to be delivered.
    // This value is updated by the reassembly queues.
    fileprivate(set) var totalInOrderInboundBytesRead: UInt64 = 0

    // Number of bytes delivered to the application.
    fileprivate var totalInboundBytesDelivered: UInt64 = 0

    // The largest inbound byte offset sent by the peer; this can
    // be larger than the in-order amounts when there are gaps.
    fileprivate var largestInboundByteOffsetReceived: UInt64 = 0

    // Number of bytes delivered since the last
    // flow control update.
    fileprivate var inboundBytesDeliveredSinceLastUpdate: UInt64 = 0

    // Number of bytes available to deliver that have
    // not yet been delivered
    fileprivate var availableInboundBytesToDeliver: UInt64 {
        precondition(totalInOrderInboundBytesRead >= totalInboundBytesDelivered)
        return totalInOrderInboundBytesRead - totalInboundBytesDelivered
    }

    // Number of bytes that the peer can send before the maximum is reached.
    fileprivate var remainingInboundBytesAllowed: UInt64 {
        let unreadBytes = availableInboundBytesToDeliver
        guard maximumUnreadInboundBytesAllowed > unreadBytes else {
            return 0
        }
        return maximumUnreadInboundBytesAllowed - unreadBytes
    }

    fileprivate func shouldSendInboundFlowControlCredit(hasSentMaxData: Bool) -> Bool {
        // For efficiency, send a FC update only when the peer
        // has used 50% of the available space.
        // If we have never advertised MAX_DATA, we use half the advertised max data.
        // Once we've advertised MAX_DATA at least once, use half the receive window.
        let threshold: UInt64
        if hasSentMaxData {
            threshold = remainingInboundBytesAllowed / 2
        } else {
            threshold = inboundMaxData / 2
        }

        return inboundBytesDeliveredSinceLastUpdate > threshold
    }

    // Returns true if changed
    @inline(always)
    fileprivate mutating func recalculateInboundMaxData() -> Bool {
        // The new inbound max data is equal the number of bytes already delivered
        // to the application, plus the number of bytes we are willing to add
        let newInboundMaxData = totalInboundBytesDelivered + maximumUnreadInboundBytesAllowed

        guard newInboundMaxData > inboundMaxData else {
            // Not increased, nothing to do
            return false
        }

        inboundBytesDeliveredSinceLastUpdate = 0
        inboundMaxData = newInboundMaxData
        return true
    }

    // Outbound values (sending):

    // Maximum number of bytes allowed to be sent to the peer, as
    // received in MAX_DATA / MAX_STREAM_DATA
    fileprivate(set) var outboundMaxData: UInt64 = 0

    // Number of bytes that have been sent to the peer.
    fileprivate var totalOutboundBytesSent: UInt64 = 0

    // Number of bytes enqueued that have not yet been sent to the peer.
    fileprivate(set) var pendingOutboundBytesToSend: UInt64 = 0

    // Number of bytes that can be sent to the peer before the maximum is reached.
    fileprivate var remainingOutboundBytesAllowed: UInt64 {
        guard outboundMaxData > totalOutboundBytesSent else {
            return 0
        }
        return outboundMaxData - totalOutboundBytesSent
    }

    mutating func resetSentBytes() {
        totalOutboundBytesSent = 0
        pendingOutboundBytesToSend = 0
    }

    // Pass false for connection-wide values
    init(isStream: Bool) {
        if isStream {
            maximumUnreadInboundBytesAllowed = UInt64(
                FlowControlGlobals.shared.initialStreamReceiveSpace
            )
        } else {
            maximumUnreadInboundBytesAllowed = UInt64(
                FlowControlGlobals.shared.initialConnectionReceiveSpace
            )
        }
    }

    mutating func initializeMaxDataValues(
        remoteMaxData: UInt64,
        localMaxData: UInt64
    ) {
        outboundMaxData = remoteMaxData
        inboundMaxData = localMaxData
    }
}

@available(Network 0.1.0, *)
extension QUICConnection {

    // Offset in the stream from which to next send bytes
    var sendOffset: UInt64 {
        flowControlState.totalOutboundBytesSent
    }

    var lastReceivedOffset: UInt64 {
        flowControlState.largestInboundByteOffsetReceived
    }

    func reportDataBlockedIfNecessary(on pendingItems: inout PendingItems) {
        if flowControlState.totalOutboundBytesSent >= flowControlState.outboundMaxData {
            if !self.hasSentDataBlocked {
                self.hasSentDataBlocked = true
                pendingItems.dataBlocked = true
            }
        }
    }

    var availableRemoteReceiveWindow: UInt64 {
        flowControlState.remainingOutboundBytesAllowed
    }

    func updateOutboundMaxData(to newValue: UInt64) -> Bool {
        guard newValue >= flowControlState.outboundMaxData else {
            log.debug(
                "Remote max data \(newValue) is not greater than \(self.flowControlState.outboundMaxData), ignoring"
            )
            return false
        }
        flowControlState.outboundMaxData = newValue
        return true
    }

    var shouldSendInboundFlowControlCredit: Bool {
        if state != .connected {
            return false
        }

        return flowControlState.shouldSendInboundFlowControlCredit(
            hasSentMaxData: self.hasAdvertisedMaxData
        )
    }

    @inline(always)
    func sendInboundFlowControlCredit() {
        guard !state.isTerminal else {
            return
        }
        if self.flowControlState.recalculateInboundMaxData() {
            log.datapath("Updating MAX_DATA to \(self.flowControlState.inboundMaxData)")
            self.applicationPendingItems.maxData = true
            self.hasAdvertisedMaxData = true
        }
    }

    @inline(always)
    fileprivate func updateMaximumUnreadInboundBytesAllowed(increment: UInt64) {
        let oldValue = flowControlState.maximumUnreadInboundBytesAllowed
        flowControlState.maximumUnreadInboundBytesAllowed = min(
            oldValue + increment,
            UInt64(FlowControlGlobals.shared.connectionReceiveHighWaterMarkMax)
        )
    }

    func updateFlowControlWithFinalSizeForZombieStream(finalSize: UInt64, lastSize: UInt64) {
        guard lastSize < finalSize else { return }
        let delta = finalSize - (lastSize + 1)
        let oldTotalInbound = flowControlState.totalInOrderInboundBytesRead
        let (newValue, overflow) = flowControlState.totalInOrderInboundBytesRead.addingReportingOverflow(delta)
        if overflow {
            log.error("Value overflowed when adding to connection total for zombie stream")
        } else {
            flowControlState.totalInOrderInboundBytesRead = newValue
            log.datapath(
                "Zombie adjusted in-order inbound bytes changed from \(oldTotalInbound) to \(newValue))"
            )
        }
    }

    func updateLastReceivedOffsetForZombie(lastOffsetDelta: UInt64) {
        let connectionMaxData = flowControlState.inboundMaxData
        let connectionCurrentLargestData = flowControlState.largestInboundByteOffsetReceived
        guard connectionMaxData >= connectionCurrentLargestData,
            (connectionMaxData - connectionCurrentLargestData) >= lastOffsetDelta
        else {
            log.error(
                "Received final size adjustment \(lastOffsetDelta) which had exceeds connection flow control limits"
            )
            close(with: .flowControlError, "exceeded flow control limits")
            return
        }
        // This cannot overflow, since the value has been just checked
        flowControlState.largestInboundByteOffsetReceived += lastOffsetDelta
    }
}

@available(Network 0.1.0, *)
struct FlowControlStreamState: ~Copyable {
    // time when the measurement period started
    fileprivate var receiveHighWaterMarkTime: NetworkClock.Instant = .zero
    // number of bytes received since the measurement period started
    fileprivate var receiveHighWaterMarkCount: UInt64 = 0
    // number of bytes received in the previous measurement period
    fileprivate var receiveHighWaterMarkPreviousCount: UInt64 = 0
}

@available(Network 0.1.0, *)
extension QUICStreamInstance {

    // Offset in the stream from which to next send bytes
    @inline(__always)
    var sendOffset: UInt64 {
        flowControlState.totalOutboundBytesSent
    }

    var lastReceivedOffset: UInt64 {
        flowControlState.largestInboundByteOffsetReceived
    }

    func updateFlowControlWithEnqueuedBytesToSend(_ bytes: UInt64, connection: QUICConnection) {
        flowControlState.pendingOutboundBytesToSend += bytes
        connection.flowControlState.pendingOutboundBytesToSend += bytes
    }

    func updateFlowControlWithSentBytes(_ bytes: UInt64, connection: QUICConnection) {
        precondition(bytes <= flowControlState.pendingOutboundBytesToSend)
        precondition(bytes <= connection.flowControlState.pendingOutboundBytesToSend)

        flowControlState.pendingOutboundBytesToSend -= bytes
        flowControlState.totalOutboundBytesSent += bytes
        connection.flowControlState.pendingOutboundBytesToSend -= bytes
        connection.flowControlState.totalOutboundBytesSent += bytes
    }

    func removePendingOutboundBytesFromFlowControl(connection: QUICConnection) {
        let pendingBytes = flowControlState.pendingOutboundBytesToSend
        flowControlState.pendingOutboundBytesToSend = 0

        precondition(pendingBytes <= connection.flowControlState.pendingOutboundBytesToSend)
        connection.flowControlState.pendingOutboundBytesToSend -= pendingBytes
    }

    func reportDataBlockedIfNecessary(on pendingItems: inout PendingItems) {
        if flowControlState.totalOutboundBytesSent >= flowControlState.outboundMaxData {
            if !self.hasSentDataBlocked {
                self.hasSentDataBlocked = true
                pendingItems.appendStreamDataBlockedFlow(self.identifier)
            }
        }
    }

    func updateFlowControlWithInboundBytesDelivered(_ bytes: UInt64, connection: QUICConnection) {
        flowControlState.totalInboundBytesDelivered += bytes
        flowControlState.inboundBytesDeliveredSinceLastUpdate += bytes
        connection.flowControlState.totalInboundBytesDelivered += bytes
        connection.flowControlState.inboundBytesDeliveredSinceLastUpdate += bytes

        log.datapath(
            "Total inbound bytes delivered is \(flowControlState.totalInboundBytesDelivered) (connection-wide total is \(connection.flowControlState.totalInboundBytesDelivered))"
        )
    }

    func updateFlowControlWithTotalInOrderInboundBytesRead(
        _ newTotalInbound: UInt64,
        connection: QUICConnection,
        updateStream: Bool = true,
        updateConnection: Bool = true
    ) {
        let oldTotalInbound = flowControlState.totalInOrderInboundBytesRead
        guard newTotalInbound >= oldTotalInbound else { return }
        precondition(newTotalInbound >= oldTotalInbound)

        if updateStream {
            flowControlState.totalInOrderInboundBytesRead = newTotalInbound
        }
        if updateConnection {
            let connectionTotal = connection.flowControlState.totalInOrderInboundBytesRead
            let (newValue, overflow) = connectionTotal.addingReportingOverflow(newTotalInbound - oldTotalInbound)
            if overflow {
                log.error("Value overflowed when adding to connection total")
            } else {
                connection.flowControlState.totalInOrderInboundBytesRead = newValue
            }
        }

        log.datapath(
            "Total in-order inbound bytes changed from \(oldTotalInbound) to \(newTotalInbound) (new connection-wide total is \(connection.flowControlState.totalInOrderInboundBytesRead))"
        )
    }

    var shouldSendInboundFlowControlCredit: Bool {
        // We only need to send flow control updates before we receive
        // the FIN bit and before we receive a RESET_STREAM.
        guard self.receiveState == .receive else {
            return false
        }

        return flowControlState.shouldSendInboundFlowControlCredit(
            hasSentMaxData: self.hasAdvertisedMaxStreamData
        )
    }

    func sendInboundFlowControlCreditIfNeeded(connection: QUICConnection) {
        if shouldSendInboundFlowControlCredit {
            // If we should send stream credit, send both stream and connection credit
            sendInboundFlowControlCredit(
                connection: connection,
                sendStreamCredit: true,
                sendConnectionCredit: true
            )
        } else if connection.shouldSendInboundFlowControlCredit {
            sendInboundFlowControlCredit(
                connection: connection,
                sendStreamCredit: false,
                sendConnectionCredit: true
            )
        }
    }

    func sendInboundFlowControlCreditForStreamDataBlocked(connection: QUICConnection) {
        // Ignore STREAM_DATA_BLOCKED once we have received a FIN
        // or a RESET_STREAM.
        guard !receiveState.isSizeKnown else {
            return
        }

        sendInboundFlowControlCredit(
            connection: connection,
            sendStreamCredit: true,
            sendConnectionCredit: true
        )
    }

    @inline(always)
    fileprivate func sendInboundFlowControlCredit(
        connection: QUICConnection,
        sendStreamCredit: Bool,
        sendConnectionCredit: Bool
    ) {
        var sendConnectionCredit = sendConnectionCredit
        if sendStreamCredit {
            if flowControlState.recalculateInboundMaxData() {
                log.datapath(
                    "Updating MAX_STREAM_DATA for \(streamID!.value) to \(flowControlState.inboundMaxData)"
                )
                connection.applicationPendingItems.appendMaxStreamDataFlow(self.identifier)
                hasAdvertisedMaxStreamData = true
                sendConnectionCredit = true
            }
        }
        if sendConnectionCredit {
            connection.sendInboundFlowControlCredit()
        }
    }

    func availableRemoteReceiveWindow(for connection: QUICConnection) -> UInt64 {
        let connectionFlowControl = connection.flowControlState.remainingOutboundBytesAllowed
        let streamFlowControl = self.flowControlState.remainingOutboundBytesAllowed
        return min(connectionFlowControl, streamFlowControl)
    }

    var availableRemoteReceiveWindow: UInt64 {
        availableRemoteReceiveWindow(for: parentProtocol)
    }

    func updateOutboundMaxData(to newValue: UInt64) -> Bool {
        guard newValue >= flowControlState.outboundMaxData else {
            log.debug(
                "Remote max data \(newValue) is not greater than \(self.flowControlState.outboundMaxData), ignoring"
            )
            return false
        }
        flowControlState.outboundMaxData = newValue
        return true
    }

    func updateOutboundFlowControlCredit(connection: QUICConnection) {
        let credit: Int
        if receivedStopSending {
            credit = 0
        } else {
            guard let calculatedCredit = maximumUnreadOutboundBytesAllowed(connection: connection)
            else {
                return
            }
            credit = Int(calculatedCredit)
        }
        log.datapath("Updating the send limit to \(credit)")
        self.maximumStreamDataSize = Int(credit)
    }

    fileprivate func maximumUnreadOutboundBytesAllowed(connection: QUICConnection) -> UInt64? {
        guard
            connection.flowControlState.outboundMaxData
                >= connection.flowControlState.totalOutboundBytesSent
        else {
            return nil
        }

        guard flowControlState.outboundMaxData >= flowControlState.totalOutboundBytesSent else {
            return nil
        }

        var minMSS: UInt64 = UInt64(Constants.initialMSS)
        var allowedCCWindow: UInt64 = 0
        connection.withCurrentPath { path in
            let pathMSS = path.mss
            if pathMSS < minMSS {
                minMSS = UInt64(pathMSS)
            }

            allowedCCWindow += path.congestionControlAvailableCongestionWindow
            return
        }

        let maxPendingBytes = FlowControlGlobals.sendQueueFactor * minMSS
        guard connection.flowControlState.pendingOutboundBytesToSend < maxPendingBytes,
            flowControlState.pendingOutboundBytesToSend < maxPendingBytes
        else {
            return 0
        }

        // Avoid trickling of data by using these values
        let connectionMin = maxPendingBytes - connection.flowControlState.pendingOutboundBytesToSend
        let streamMin = maxPendingBytes - flowControlState.pendingOutboundBytesToSend

        let connectionMax = min(
            connection.flowControlState.outboundMaxData
                - connection.flowControlState.totalOutboundBytesSent,
            allowedCCWindow
        )
        let connectionCredit = max(connectionMax, connectionMin)

        let streamCredit = max(
            flowControlState.outboundMaxData - flowControlState.totalOutboundBytesSent,
            streamMin
        )

        return min(connectionCredit, streamCredit)
    }

    @inline(always)
    func updateLastReceivedOffset(
        to newLastReceivedOffset: UInt64,
        connection: QUICConnection
    ) -> UInt64? {
        let currentValue = flowControlState.largestInboundByteOffsetReceived
        guard newLastReceivedOffset >= currentValue else { return nil }
        let delta: UInt64 = newLastReceivedOffset - currentValue

        flowControlState.largestInboundByteOffsetReceived = newLastReceivedOffset
        guard flowControlState.largestInboundByteOffsetReceived <= flowControlState.inboundMaxData
        else {
            log.error(
                "Received final size \(newLastReceivedOffset) which had exceeds stream flow control limits"
            )
            connection.close(with: .flowControlError, "exceeded stream flow control limits")
            return nil
        }

        let connectionMaxData = connection.flowControlState.inboundMaxData
        let connectionCurrentLargestData = connection.flowControlState
            .largestInboundByteOffsetReceived
        guard connectionMaxData >= connectionCurrentLargestData,
            (connectionMaxData - connectionCurrentLargestData) >= delta
        else {
            log.error(
                "Received final size \(newLastReceivedOffset) which had exceeds connection flow control limits"
            )
            connection.close(with: .flowControlError, "exceeded flow control limits")
            return nil
        }
        // This cannot overflow, since the value has been just checked
        connection.flowControlState.largestInboundByteOffsetReceived += delta
        return delta
    }

    @inline(always)
    func startTrackingInboundFlowControlInterval(connection: QUICConnection) {
        // Start of a new measurement interval
        if flowControlStreamState.receiveHighWaterMarkTime == .zero {
            flowControlStreamState.receiveHighWaterMarkTime = connection.now
        }
    }

    // Updates inbound flow control credit, and recalculates
    // `maximumUnreadInboundBytesAllowed` values.
    @inline(always)
    func updateInboundFlowControlCredit(
        dataLengthAdded: UInt64,
        connection: QUICConnection,
        connectionOnly: Bool
    ) {

        if !updateMaximumUnreadInboundBytesAllowed(
            dataLengthAdded: dataLengthAdded,
            connection: connection
        ) {
            // The maximum isn't updated, don't send flow control credit
            return
        }

        // Determine whether the stream flow control can be omitted for efficiency.
        var connectionOnly = connectionOnly
        if !connectionOnly {
            // Check for the conditions in which stream flow control can be skipped
            if self.receiveState.isSizeKnown {
                connectionOnly = true
            }
        }

        // If `connectionOnly` is set, suppress sending MAX_STREAM_DATA.
        // This is done to allow proper accounting of the flow control credits upon
        // reception of RESET_STREAM frame. Depending on the value of the final
        // stream offset in RESET_STREAM, additional connection-level credits
        // may be sent.
        sendInboundFlowControlCredit(
            connection: connection,
            sendStreamCredit: !connectionOnly,
            sendConnectionCredit: true
        )
    }

    // Auto-tune the receive high watermark
    // Grow the receive buffer based on 2*BDP to ensure
    // that sender can send at full rate.
    // Returns true if maximum was updated.
    @inline(always)
    fileprivate func updateMaximumUnreadInboundBytesAllowed(
        dataLengthAdded: UInt64,
        connection: QUICConnection
    ) -> Bool {
        guard dataLengthAdded > 0 else { return false }

        // Do not grow the receive buffer if
        // - the high water mark already reached the maximum
        // - TODO: reassembly queue gaps
        if flowControlState.maximumUnreadInboundBytesAllowed
            >= FlowControlGlobals.shared.streamReceiveHighWaterMarkMax
        {
            log.datapath("Already at maximum inbound bytes allowed")
            return false
        }

        if connection.flowControlState.maximumUnreadInboundBytesAllowed
            > FlowControlGlobals.shared.connectionReceiveHighWaterMarkMax
        {
            log.datapath("Connection already at maximum inbound bytes allowed")
            return false
        }

        let increment = computeReceiveHighWaterMarkIncrease(
            dataLength: dataLengthAdded,
            connection: connection,
            now: connection.now
        )

        if increment > 0 {
            self.updateMaximumUnreadInboundBytesAllowed(increment: increment)
            connection.updateMaximumUnreadInboundBytesAllowed(increment: increment)
            log.datapath(
                "increased the receive high watermark to \(flowControlState.maximumUnreadInboundBytesAllowed)"
            )
            return true
        }
        return false
    }

    @inline(always)
    fileprivate func updateMaximumUnreadInboundBytesAllowed(increment: UInt64) {
        let oldValue = flowControlState.maximumUnreadInboundBytesAllowed
        flowControlState.maximumUnreadInboundBytesAllowed = min(
            oldValue + increment,
            UInt64(FlowControlGlobals.shared.streamReceiveHighWaterMarkMax)
        )
    }

    @inline(always)
    fileprivate func computeReceiveHighWaterMarkIncrease(
        dataLength: UInt64,
        connection: QUICConnection,
        now: NetworkClock.Instant
    ) -> UInt64 {
        let receiveHighWaterMarkTime = flowControlStreamState.receiveHighWaterMarkTime
        if receiveHighWaterMarkTime > now {
            log.fault("Timestamp should be greater than now")
            return 0
        }

        var increment: UInt64 = 0
        let receiveHighWaterMarkCount = flowControlStreamState.receiveHighWaterMarkCount + dataLength

        // If one RTT has elapsed, we can stop counting the bytes.
        // Here, we estimate if the bandwidth measured in this RTT
        // is more than a certain value of the bandwidth measured
        // in the previous RTT.
        let rtt = connection.currentPath?.smoothedRTT ?? .zero
        if now >= receiveHighWaterMarkTime.advanced(by: rtt) {
            let receiveHighWaterMarkPreviousCount = flowControlStreamState.receiveHighWaterMarkPreviousCount
            var newPreviousCount = receiveHighWaterMarkPreviousCount
            if receiveHighWaterMarkCount > receiveHighWaterMarkPreviousCount {
                let mss = UInt64(connection.currentPath?.mss ?? 0)
                let shift: Int
                if receiveHighWaterMarkCount
                    > (receiveHighWaterMarkPreviousCount + (receiveHighWaterMarkPreviousCount >> 1))
                {

                    // If we received more than 1.5 times
                    // than last time, set rcvbuf to 4*BDP
                    shift = 2
                } else {
                    shift = 1
                }
                log.datapath(
                    "Estimated BDP \(receiveHighWaterMarkCount)B, current RTT \(rtt)us, estimated bandwidth 8 * \(receiveHighWaterMarkCount) / \(rtt) Mbps"
                )

                let (incr, overflow) = (receiveHighWaterMarkCount << shift)
                    .subtractingReportingOverflow(flowControlState.maximumUnreadInboundBytesAllowed)
                if !overflow {
                    newPreviousCount = receiveHighWaterMarkCount
                    // Align the increase to whole segments. Increases of a fraction of an MSS isn't useful as it won't fill a whole packet.
                    if mss != 0 {
                        increment = (incr / mss) * mss
                    }
                }
            }

            // Reset the measurement
            flowControlStreamState.receiveHighWaterMarkPreviousCount = newPreviousCount
            flowControlStreamState.receiveHighWaterMarkCount = 0
            flowControlStreamState.receiveHighWaterMarkTime = .zero
        } else {
            flowControlStreamState.receiveHighWaterMarkCount = receiveHighWaterMarkCount
        }

        return increment
    }
}

#endif
