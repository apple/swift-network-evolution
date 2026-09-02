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

// MARK: QUIC StreamID state
// Keeps track of the QUICStreamID state for local and remote uni/bidi streams
@available(Network 0.1.0, *)
struct QUICStreamIDState: ~Copyable {
    let logContext: String
    let streamType: QUICStreamType
    var remoteMaxStreams: Int = 0
    var previousRemoteMaxStreams: Int = 0
    var localMaxStreams: Int = 0
    var allocatedStreamCount: Int = 0
    var largestOutboundStreamID: QUICStreamID?
    var nextInboundStreamID: QUICStreamID?
    var remoteMaxStreamID: QUICStreamID?
    var localMaxStreamID: QUICStreamID?
    private(set) var activeStreams: Int = 0
    private(set) var pendingStartStreams: [QUICStreamInstance] = []

    init(_ type: QUICStreamType) {
        self.streamType = type
        self.logContext = streamType == .unidirectional ? "unidirectional" : "bidirectional"
    }

    mutating func incrementActiveStreams() {
        activeStreams += 1
    }

    mutating func decrementActiveStreams() {
        activeStreams = activeStreams > 0 ? activeStreams - 1 : 0
    }

    func activeStreamsRemaining() -> Int {
        activeStreams
    }

    mutating func addPending(_ stream: QUICStreamInstance) {
        guard !stream.pendingStart else {
            stream.log.error("Stream is already marked pendingStart \(logContext)")
            return
        }
        // streamID's will be nil if pending so check by identifier
        guard !pendingStartStreams.contains(where: { $0.identifier == stream.identifier }) else {
            stream.log.error("Stream is already on pending list \(logContext)")
            return
        }
        pendingStartStreams.append(stream)
        stream.pendingStart = true
        let logContext = self.logContext
        stream.log.debug("Is pending \(logContext)")
    }

    mutating func removePending(_ stream: QUICStreamInstance) {
        guard stream.pendingStart else {
            stream.log.error("Stream is not marked pendingStart \(logContext)")
            return
        }
        guard let index = pendingStartStreams.firstIndex(where: { $0.identifier == stream.identifier })
        else {
            stream.log.error("Stream is not on pending list \(logContext)")
            return
        }
        pendingStartStreams.remove(at: index)
        stream.pendingStart = false
        let logContext = self.logContext
        stream.log.debug("Is no longer pending \(logContext)")
    }

    mutating func removeAllPending() {
        while !pendingStartStreams.isEmpty {
            let stream = pendingStartStreams.popLast()!
            guard stream.pendingStart else {
                stream.log.error(
                    "Stream is not marked pendingStart \(logContext)"
                )
                return
            }
            stream.pendingStart = false
        }
    }

    mutating func allocateNewOutboundStreamID(
        isServer: Bool,
        logIDString: String,
        isUnidirectional: Bool
    ) -> QUICStreamID? {
        let newStreamID = QUICStreamID.nextAvailableStreamID(
            allocatedStreamCount: allocatedStreamCount,
            remoteMaxStreams: remoteMaxStreams,
            remoteMaxStreamID: remoteMaxStreamID,
            server: isServer,
            logIDString: logIDString,
            isUnidirectional: isUnidirectional
        )
        guard let newStreamID else {
            return nil
        }

        let (newValue, overflow) = self.allocatedStreamCount.addingReportingOverflow(1)
        guard !overflow else {
            return nil
        }
        self.allocatedStreamCount = newValue

        self.largestOutboundStreamID = newStreamID
        #if !DisableDebugLogging
        let logContext = self.logContext
        Logger.proto.debug(
            "\(logIDString) \(logContext) allocated new stream ID \(newStreamID)"
        )
        #endif
        return newStreamID
    }

    func checkInboundStreamID(
        _ streamID: QUICStreamID,
        server isServer: Bool,
        connection: QUICConnection
    ) -> (valid: Bool, checkZombie: Bool) {

        guard let nextInboundStreamID else {
            connection.log.fault("nextInboundStreamID is invalid")
            connection.close(with: .internalError, "inconsistent next inbound stream ID")
            return (valid: false, checkZombie: false)
        }

        if streamID.isInitiatedBy(server: isServer) {
            // We're handling a new inbound stream, but it's not a Stream ID that
            // the peer should have opened. Check if it's a stream we already closed?
            if let largestOutboundStreamID = self.largestOutboundStreamID,
                streamID <= largestOutboundStreamID
            {
                connection.log.info(
                    "[S\(streamID)] already closed (last \(logContext) \(largestOutboundStreamID))"
                )
                return (valid: false, checkZombie: true)
            } else {
                connection.log.error(
                    "Peer is attempting to open an invalid stream (\(streamID)); our role is \(isServer ? "server" : "client") (last \(logContext) \(largestOutboundStreamID?.description ?? "nil"))"
                )
                connection.close(with: .streamStateError, "invalid stream ID")

                return (valid: false, checkZombie: false)
            }
        }

        if newStreamIDsAreBlocked(streamID) {
            connection.log.error(
                "Stream ID \(streamID) exceeded the maximum allowed"
            )
            connection.close(with: .streamLimitError, "exceeded maximum stream ID")

            return (valid: false, checkZombie: false)
        }

        // Check if the stream is already closed.  If we got here, it was
        // because the lookup failed.  Don't re-create streams that are
        // already closed.
        if streamID < nextInboundStreamID {
            connection.log.info(
                "Not recreating closed stream (next \(logContext) \(nextInboundStreamID))"
            )
            return (valid: false, checkZombie: true)
        }
        return (valid: true, checkZombie: false)
    }

    // Set window to a non-zero value to check if there are room for N more streamIDs
    func newStreamIDsAreBlocked(
        _ streamID: QUICStreamID,
        server: Bool = false,
        window: Int = 0
    ) -> Bool {
        if localMaxStreams == 0 {
            return true
        }

        let compareMaxStreamID: QUICStreamID
        if window == 0 {
            guard let localMaxStreamID else {
                // The local Max Stream ID is yet to be determined, so new IDs are blocked
                return true
            }
            compareMaxStreamID = localMaxStreamID
        } else {
            guard localMaxStreams > window else {
                // Local max streams is less than the entire window, so new IDs are blocked
                return true
            }

            let adjustedMaxStreams = localMaxStreams - window

            let adjustedMaxStreamID: QUICStreamID?
            if streamType == .unidirectional {
                adjustedMaxStreamID = QUICStreamID.computeRemoteMaxStreamIDUnidirectional(
                    server: server,
                    streams: UInt64(adjustedMaxStreams)
                )
            } else {
                adjustedMaxStreamID = QUICStreamID.computeRemoteMaxStreamIDBidirectional(
                    server: server,
                    streams: UInt64(adjustedMaxStreams)
                )
            }

            guard let adjustedMaxStreamID else {
                return true
            }
            compareMaxStreamID = adjustedMaxStreamID
        }

        if streamID >= compareMaxStreamID {
            return true
        }

        return false
    }

    mutating func resetStreamsState(
        nextInboundStreamID: QUICStreamID,
        largestOutboundStreamID: QUICStreamID
    ) {
        self.allocatedStreamCount = 0
        self.nextInboundStreamID = nextInboundStreamID
        if self.largestOutboundStreamID == nil {
            self.largestOutboundStreamID = largestOutboundStreamID
        }
    }

    mutating func updateRemoteMaxStreams(server: Bool, newMaxStreams: Int, logIDString: String) {
        remoteMaxStreams = newMaxStreams
        if streamType == .unidirectional {
            remoteMaxStreamID = QUICStreamID.computeRemoteMaxStreamIDUnidirectional(
                server: server,
                streams: UInt64(newMaxStreams)
            )
        } else {
            remoteMaxStreamID = QUICStreamID.computeRemoteMaxStreamIDBidirectional(
                server: server,
                streams: UInt64(newMaxStreams)
            )
        }
        #if !DisableDebugLogging
        let logContext = self.logContext
        let remoteMaxStreamID = self.remoteMaxStreamID
        Logger.proto.debug(
            "\(logIDString) \(logContext) got newMaxStreams=\(newMaxStreams) which gives remoteMaxStreamID=\(remoteMaxStreamID?.description ?? "unknown")"
        )
        #endif
    }

    mutating func updateLocalMaxStreams(server: Bool, newMaxStreams: Int, logIDString: String) {
        localMaxStreams = newMaxStreams
        if streamType == .unidirectional {
            localMaxStreamID = QUICStreamID.computeRemoteMaxStreamIDUnidirectional(
                server: server,
                streams: UInt64(newMaxStreams)
            )
        } else {
            localMaxStreamID = QUICStreamID.computeRemoteMaxStreamIDBidirectional(
                server: server,
                streams: UInt64(newMaxStreams)
            )
        }
        #if !DisableDebugLogging
        let logContext = self.logContext
        let localMaxStreamID = self.localMaxStreamID
        Logger.proto.debug(
            "\(logIDString) \(logContext) got newMaxStreams=\(newMaxStreams) which gives localMaxStreamID=\(localMaxStreamID?.description ?? "unknown")"
        )
        #endif
    }
}

struct StreamListMembership: OptionSet {
    init(rawValue: Self.RawValue) {
        self.rawValue = rawValue
    }
    let rawValue: UInt8
    static let none = StreamListMembership(rawValue: 1 << 0)
    static let pendingReassemblyDequeue = StreamListMembership(rawValue: 1 << 1)
    static let sendable = StreamListMembership(rawValue: 1 << 2)
    static let unblockedSend = StreamListMembership(rawValue: 1 << 3)

    var description: String {
        switch self {
        case .none: return "none"
        case .pendingReassemblyDequeue: return "pendingReassemblyDequeue"
        case .unblockedSend: return "unblockedSend"
        default: return "none"
        }
    }
}

// QUICStreamList is designed to hold a list of flow identifiers that fit different list types.
// For example, pendingReassemblyDequeue, sendable, and unblockedSend lists.
// Note that QUICStreamList only holds the flow identifiers that are used to lookup
// the actual streams held in the multiplexedFlows dictionary already.
// Also note that a flow identifier can exist in multiple lists at one time.
@available(Network 0.1.0, *)
struct QUICStreamList: ~Copyable {
    private var list = Deque<MultiplexedFlowIdentifier>(minimumCapacity: 4)
    private let name: StaticString
    private let listType: StreamListMembership

    static func pendingReassemblyDequeueList() -> QUICStreamList {
        QUICStreamList(
            listType: .pendingReassemblyDequeue,
            name: #function
        )
    }
    static func unblockedSendStreamList() -> QUICStreamList {
        QUICStreamList(
            listType: .unblockedSend,
            name: #function
        )
    }

    private init(listType: StreamListMembership, name: StaticString) {
        self.listType = listType
        self.name = name
    }

    var isEmpty: Bool {
        list.isEmpty
    }

    var count: Int {
        list.count
    }

    mutating func append(_ stream: QUICStreamInstance) {
        guard !stream.listMembership.contains(listType) else {
            return
        }
        list.append(stream.identifier)
        stream.listMembership.insert(listType)
    }

    mutating func removeFirst(connection: QUICConnection) -> QUICStreamInstance? {
        guard !list.isEmpty else {
            return nil
        }
        let streamIdentifier = list.removeFirst()
        guard let stream = connection.flow(for: streamIdentifier) else {
            return nil
        }
        stream.listMembership.remove(listType)
        return stream
    }

    mutating func remove(_ stream: QUICStreamInstance) {
        let name = self.name
        guard stream.listMembership.contains(listType) else {
            stream.log.error(
                "Stream is not in \(name), currently in: \(stream.listMembership.description)"
            )
            return
        }

        let identifier = stream.identifier
        guard let index = list.firstIndex(of: identifier) else {
            stream.log.error("Stream is not on \(name)")
            return
        }
        list.remove(at: index)
        stream.listMembership.remove(listType)
        stream.log.debug("Removed from \(name)")
    }

    mutating func removeAll(connection: QUICConnection) {
        while !list.isEmpty {
            guard let identifier = list.popLast() else {
                break
            }
            if let stream = connection.flow(for: identifier) {
                guard stream.listMembership.contains(listType) else {
                    let name = self.name
                    connection.log.error("Stream is not marked in \(name)")
                    return
                }
                stream.listMembership.remove(listType)
            }
        }
    }
}

// MARK: QUIC Stream

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICStreamInstance: MultiplexedStreamFlow<QUICConnection>,
    UnidirectionalAbortingStreamFlow, EarlyDataStreamFlow
{
    private(set) var streamID: QUICStreamID?
    var logPrefix: String = ""
    var streamMetadata = ProtocolMetadata<QUICStreamProtocol>(
        protocolIdentifier: QUICStreamProtocol.identifier,
        perProtocolMetadata: QUICStreamProtocol.QUICStreamMetadata(),
        messageIdentifier: SystemUUID(insecure: true)
    )

    @_optimize(speed)
    override public var reference: ProtocolInstanceReference {
        var reference = ProtocolInstanceReference(quicStream: self)
        reference.parentReference = parentProtocol.reference
        return reference
    }

    var flowControlState = FlowControlState(isStream: true)
    var flowControlStreamState = FlowControlStreamState()

    var finalSize: UInt64?
    // Bytes dequeued and delivered to the application
    private var bytesDequeued: UInt64 = 0

    var sendBuffer = StreamSendBuffer()
    var reassemblyQueue = ReassemblyQueue()
    var listMembership: StreamListMembership = .none

    var sendState = QUICSendStreamState()
    var receiveState = QUICReceiveStreamState()

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt16
        static let hasSentDataBlocked = Flags(rawValue: 1 << 0)
        static let updatingCredit = Flags(rawValue: 1 << 1)
        static let stopSendRequested = Flags(rawValue: 1 << 2)
        static let pendingStart = Flags(rawValue: 1 << 3)  // on the pending list
        static let closed = Flags(rawValue: 1 << 4)  // stream is closed by handle_stop or report_done
        static let writeClosed = Flags(rawValue: 1 << 5)
        static let readClosed = Flags(rawValue: 1 << 6)
        static let pendingReportReady = Flags(rawValue: 1 << 7)
        static let receivedStopSending = Flags(rawValue: 1 << 8)
        static let unidirectional = Flags(rawValue: 1 << 9)
        static let resetSent = Flags(rawValue: 1 << 10)
        static let resetReceived = Flags(rawValue: 1 << 11)
        static let hasAdvertisedMaxStreamData = Flags(rawValue: 1 << 12)
        static let peerAcknowledgedFIN = Flags(rawValue: 1 << 13)
        static let markedInboundFINOnFrame = Flags(rawValue: 1 << 14)
        static let applicationMarkedIdle = Flags(rawValue: 1 << 15)
    }
    private var flags = Flags()

    // Have sent DATA_BLOCKED for the stream without an increase
    var hasSentDataBlocked: Bool {
        get { flags.contains(.hasSentDataBlocked) }
        set {
            if newValue {
                flags.insert(.hasSentDataBlocked)
            } else {
                flags.remove(.hasSentDataBlocked)
            }
        }
    }
    fileprivate(set) var pendingStart: Bool {
        get { flags.contains(.pendingStart) }
        set { if newValue { flags.insert(.pendingStart) } else { flags.remove(.pendingStart) } }
    }
    var readClosed: Bool {
        get { flags.contains(.readClosed) }
        set { if newValue { flags.insert(.readClosed) } else { flags.remove(.readClosed) } }
    }
    var writeClosed: Bool {
        get { flags.contains(.writeClosed) }
        set { if newValue { flags.insert(.writeClosed) } else { flags.remove(.writeClosed) } }
    }
    var closed: Bool {
        get { flags.contains(.closed) }
        set { if newValue { flags.insert(.closed) } else { flags.remove(.closed) } }
    }
    var unidirectional: Bool {
        get { flags.contains(.unidirectional) }
        set { if newValue { flags.insert(.unidirectional) } else { flags.remove(.unidirectional) } }
    }
    var stopSendRequested: Bool {
        get { flags.contains(.stopSendRequested) }
        set {
            if newValue {
                flags.insert(.stopSendRequested)
            } else {
                flags.remove(.stopSendRequested)
            }
        }
    }
    var resetSent: Bool {
        get { flags.contains(.resetSent) }
        set {
            if newValue {
                flags.insert(.resetSent)
            }
            // This is a trap door value: once set, it can't be unset
        }
    }

    var pendingReportReady: Bool { flags.contains(.pendingReportReady) }
    var receivedStopSending: Bool {
        get { flags.contains(.receivedStopSending) }
        set {
            if newValue {
                flags.insert(.receivedStopSending)
            }
            // This is a trap door value: once set, it can't be unset
        }
    }
    var resetReceived: Bool {
        get { flags.contains(.resetReceived) }
        set {
            if newValue {
                flags.insert(.resetReceived)
            }
            // This is a trap door value: once set, it can't be unset
        }
    }
    var hasAdvertisedMaxStreamData: Bool {
        get { flags.contains(.hasAdvertisedMaxStreamData) }
        set {
            if newValue {
                flags.insert(.hasAdvertisedMaxStreamData)
            }
            // This is a trap door value: once set, it can't be unset
        }
    }
    var peerAcknowledgedFIN: Bool {
        get { flags.contains(.peerAcknowledgedFIN) }
        set {
            if newValue {
                flags.insert(.peerAcknowledgedFIN)
            }
            // This is a trap door value: once set, it can't be unset
        }
    }
    var markedInboundFINOnFrame: Bool {
        get { flags.contains(.markedInboundFINOnFrame) }
        set {
            if newValue {
                flags.insert(.markedInboundFINOnFrame)
            }
            // This is a trap door value: once set, it can't be unset
        }
    }
    var applicationMarkedIdle: Bool {
        get { flags.contains(.applicationMarkedIdle) }
        set { if newValue { flags.insert(.applicationMarkedIdle) } else { flags.remove(.applicationMarkedIdle) } }
    }

    func setup(
        streamID: QUICStreamID?,
        logPrefixer: LogPrefixer
    ) {
        self.streamID = streamID
        #if !DisableDebugLogging
        let streamIDString = if let streamID { streamID.description } else { "?" }
        self.logPrefix = "[S\(streamIDString)]"
        #endif
        if let _streamID = self.streamID {
            self.streamMetadata.streamID = _streamID.value
            self.streamMetadata.streamType = _streamID.quicStreamType
        }
        self.reassemblyQueue.log = NetworkLoggerState(logPrefixer.logIDString)
    }

    func resetStreamID(streamID: QUICStreamID) {
        self.streamID = streamID
        self.logPrefix = "[S\(streamID.description)]"

        if streamID.isUnidirectional {
            self.unidirectional = true
        }

        self.streamMetadata.streamID = streamID.value
        self.streamMetadata.streamType = streamID.quicStreamType
    }

    deinit {
        if let streamID = streamID {
            log.debug("Deallocating unassigned stream \(streamID.value)")
        } else {
            log.debug("Deallocating unassigned stream")
        }
        reassemblyQueue.dequeueAll()
        // If handleStreamClose has already been called just return
        guard !self.closed else {
            return
        }
        self.sendBuffer.empty()
        parentProtocol.handleStreamClose(stream: self, error: nil)
    }

    func close(errorCode: NetworkError?) {
        self.sendBuffer.empty()
        parentProtocol.handleStreamClose(stream: self, error: errorCode)
    }

    /// The application error code for the inbound (receive) direction.
    ///
    /// Used for the `STOP_SENDING` frame.
    var inboundApplicationError: UInt64?
    /// The application error code for the outbound (send) direction.
    ///
    /// Used for the `RESET_STREAM` frame.
    var outboundApplicationError: UInt64?

    public func abortOutbound(error: NetworkError?) {
        self.outboundApplicationError = UInt64(error?.quicApplicationError ?? 0)
        _ = parentProtocol.handleStopWrite(for: self)
        parentProtocol.sendFrames()  // Send frames since this is an "external" call
    }

    public func abortInbound(error: NetworkError?) {
        self.inboundApplicationError = UInt64(error?.quicApplicationError ?? 0)
        parentProtocol.handleStopRead(for: self)
        parentProtocol.sendFrames()  // Send frames since this is an "external" call
    }

    func emptyPendingData(connection: QUICConnection) {
        removePendingOutboundBytesFromFlowControl(connection: connection)
        sendBuffer.empty()
    }

    // This processes an incoming STREAM frame belonging to a QUICStream
    func processIncomingStream(
        connection: QUICConnection,
        frame: consuming FrameStreamReceived
    ) -> Bool {
        log.datapath("processing")
        if self.pendingReportReady {
            self.flags.remove(.pendingReportReady)
        }

        // Ignore STREAM frame when all data has already been received
        if self.receiveState.dataHasAlreadyBeenReceived {
            frame.frame.finalize(success: true)
            return true
        }

        var result = true
        if self.receiveState.isReceivingData {
            result = processIncomingStreamData(connection: connection, frame: frame)
        } else {
            frame.frame.finalize(success: false)
        }
        log.datapath("received bytes up to \(self.flowControlState.totalInOrderInboundBytesRead)")
        return result
    }

    private func processIncomingStreamData(
        connection: QUICConnection,
        frame: consuming FrameStreamReceived
    ) -> Bool {
        startTrackingInboundFlowControlInterval(connection: connection)

        let maximumUnreadInboundBytesAllowed = flowControlState.maximumUnreadInboundBytesAllowed
        // NOTE: This won't work with retransmissions if we don't
        // have enough space to take the stream data
        if frame.length > maximumUnreadInboundBytesAllowed {
            log.error(
                "Not enough receive buffer space \(frame.length) > \(maximumUnreadInboundBytesAllowed)"
            )
            frame.frame.finalize(success: false)
            return false
        }

        let canAppendResult = reassemblyQueue.canAppendItemsForByteLimit(
            maximumUnreadInboundBytesAllowed
        )
        guard canAppendResult.acceptable else {
            connection.log.error(
                "Stream reassembly queue has too many items, closing"
            )
            frame.frame.finalize(success: false)
            connection.close(with: .internalError, "exceeded stream reassembly queue limits")
            return false
        }

        // Offset is from a VLE so should not be bigger than a 62bit value
        // so does not represent a problem in 64bit systems.
        let appendResult = reassemblyQueue.append(
            frame: frame.frame,
            offset: Int(frame.offset),
            fin: frame.isFinal
        )
        let dataAdded = appendResult.sizeAdded != 0

        let frameFinalSize = frame.isFinal ? frame.offset &+ UInt64(frame.length) : nil

        guard
            let _ = self.updateLastOffset(
                connection: connection,
                newLastOffset: UInt64(appendResult.lastOffset),
                newFinalSize: frameFinalSize
            )
        else {
            log.error("final_size invariants violated")
            connection.close(with: .internalError, "final_size invariants violated")
            return false
        }

        if let _ = frameFinalSize, receiveState != .sizeKnown {
            self.receiveState.change(logIDString: logPrefix, to: .sizeKnown)
        }

        if dataAdded || appendResult.hasFin {
            #if SignpostOutput
            if let streamID {
                QUICSignpost.dataReceived(
                    id: connection.signpostID,
                    streamID: streamID.value,
                    nbytes: appendResult.sizeAdded
                )
            }
            #endif

            updateInboundFlowControlCredit(
                dataLengthAdded: UInt64(appendResult.sizeAdded),
                connection: connection,
                connectionOnly: false
            )
            let finOffset = appendResult.finOffset

            let newOffset = appendResult.currentOffset &+ appendResult.availableToDequeue
            if newOffset == finOffset {
                receiveState.change(logIDString: logPrefix, to: .dataReceived)
            }
            if newOffset > finOffset {
                log.error(
                    "Bytes received \(newOffset) > fin offset \(finOffset)"
                )
                connection.close(with: .internalError, "bytes received larger than FIN offset")
                return false
            }

            if !self.listMembership.contains(.pendingReassemblyDequeue) {
                connection.pendingReassemblyDequeue.append(self)
            }
        }
        return true
    }

    var isOpen: Bool {

        !(self.pendingStart || self.closed
            || (self.sendState == .invalid && self.receiveState == .invalid))
    }

    var streamType: QUICStreamType? { self.streamID?.quicStreamType }

    // Advance the lastOffset and finalSize and check
    // for possible protocol violations (see RFC9000 Section 20.1).
    //
    //  FINAL_SIZE_ERROR (0x06):
    //    (1) An endpoint received a STREAM frame containing data
    //        that exceeded the previously established final size,
    //    (2) An endpoint received a STREAM frame or a RESET_STREAM
    //        frame containing a final size that was lower than
    //        the size of stream data that was already received,
    //    (3) An endpoint received a STREAM frame or a RESET_STREAM frame
    //        containing a different final size to the one
    //        already established.
    //
    //  FLOW_CONTROL_ERROR (0x03):
    //    An endpoint received more data than it permitted in
    //    its advertised data limits; see Section 4.
    //
    // If advancing lastOffset or finalSize
    // causes any of the above protocol violations, the connection
    // is closed with the appropriate error code and error message,
    // and this function will return STREAM_OFFSET_INVALID.
    //
    // Otherwise, the function will return the amount by which
    // the `lastOffset` was incremented.
    @_optimize(speed)
    func updateLastOffset(
        connection: QUICConnection,
        newLastOffset: UInt64,
        newFinalSize: UInt64?
    ) -> UInt64? {

        // (1) Endpoint received data that exceeds the value of previously
        // established final size.
        if let finalSize, newFinalSize == nil, finalSize < newLastOffset {
            log.error(
                "[true:\(self.receiveState)] endpoint received stream offset \(newLastOffset) that exceeds final size \(finalSize)"
            )
            connection.close(with: .finalSizeError, "stream offset exceeded its final size")
            return nil
        }

        // (2) Endpoint received data with final size that's lower
        // than the size of the stream data that was already established
        if finalSize == nil, newFinalSize != nil, newLastOffset < self.lastReceivedOffset {
            log.error(
                "[false:\(self.receiveState)] endpoint received size \(newLastOffset) that's lower than size of the stream \(self.lastReceivedOffset)"
            )
            connection.close(
                with:
                    .finalSizeError,
                "received final size lower than already received size"
            )
            return nil
        }

        // (3) Endpoint received frame containing a different final size
        // to the one already established
        if let finalSize, let newFinalSize, finalSize != newFinalSize {
            log.error(
                "[true:\(self.receiveState)] endpoint received final size \(newFinalSize) different from already established \(finalSize)"
            )
            connection.close(
                with:
                    .finalSizeError,
                "received final size different to already established final size"
            )
            return nil
        }

        if self.finalSize == nil, let newFinalSize {
            self.finalSize = newFinalSize
            log.datapath("final size set to \(newFinalSize)")
        }

        let lastOffsetDelta = updateLastReceivedOffset(to: newLastOffset, connection: connection)
        if lastOffsetDelta != nil {
            log.datapath(
                "[\(self.finalSize != nil ? "true" : "false"):\(self.receiveState)] adjusted last offset (conn \(connection.lastReceivedOffset), stream \(self.lastReceivedOffset))"
            )
        }

        return lastOffsetDelta
    }

    // Called when read data has left stream and being delivered to application
    func deliveredInboundBytes(consumedLength: Int, connection: QUICConnection) {
        updateFlowControlWithInboundBytesDelivered(UInt64(consumedLength), connection: connection)

        // If a RESET_STREAM has been received, the flow control state
        // has already been updated
        if !resetReceived {
            // Update flow control state for total in-order bytes received
            let reassemblyQueueInOrderOffset = UInt64(reassemblyQueue.currentOffset)
            updateFlowControlWithTotalInOrderInboundBytesRead(
                reassemblyQueueInOrderOffset,
                connection: connection
            )
        }

        self.sendInboundFlowControlCreditIfNeeded(connection: connection)
    }

    @_optimize(speed)
    func dequeueReassembledData(connection: QUICConnection) -> FrameArray? {
        let totalLength = reassemblyQueue.availableToDequeue
        log.datapath("total available reassembled data \(totalLength)")
        guard totalLength >= 0 else {
            log.error("Reassembled data length cannot be negative")
            return nil
        }
        if totalLength == 0 {
            // If there are no bytes, but the FIN has been reached,
            // deliver a 0-length Frame with the FIN bit set.
            // Otherwise, return no frame
            guard reassemblyQueue.finOffset == self.bytesDequeued && receiveState != .dataRead
            else {
                return nil
            }
        }
        var frameArray = FrameArray()
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
            log.datapath("dequeued length \(itemLength)")

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
            if item.fin && !markedInboundFINOnFrame {
                log.datapath("Marking FIN on received frame")
                markedInboundFINOnFrame = true
                frame.metadataComplete = true
                frame.connectionComplete = true
            }

            frameArray.add(frame: frame)

            self.bytesDequeued += UInt64(itemLength)
        }
        if writtenCount < totalLength {
            // This is a ReassemblyQueue bug, but should be recoverable
            log.error(
                "Reassembled dequeued data length \(writtenCount) < available length \(totalLength)"
            )
        }

        return frameArray
    }

    override public func upperReceiveQueueDrainedBytes(_ bytes: Int) {

        // Record with flow control that bytes have been delivered, and update flow credits.
        deliveredInboundBytes(consumedLength: bytes, connection: parentProtocol)

        if let streamID {
            QUICSignpost.dataDelivered(id: parentProtocol.signpostID, streamID: streamID.value, nbytes: bytes)
        }

        // If all data has now been read, move to the data read state
        if receiveState != .dataRead, upperReceiveQueue.isEmpty, markedInboundFINOnFrame {
            receiveState.change(logIDString: logPrefix, to: .dataRead)
            if !self.closed, self.sendState == .dataReceived {
                // If both directions are closed, and all data is read, close the stream
                self.close(errorCode: nil)
            }
        }
    }

    static func quicSafeUnsignedDecrement(
        value: Int,
        decrement: Int,
        newValueInCaseOfOverflow: Int?,
        function: StaticString = #function
    ) -> Int? {
        let (newValue, overflow) = value.subtractingReportingOverflow(decrement)
        // In C, this is done with UINT64 math, but the subtraction with Int can be negative w/o underflow
        if overflow || newValue < 0 {
            Logger.proto.fault(
                "UNDERFLOW: \(value) decrement \(decrement) result \(newValueInCaseOfOverflow?.description ?? "nil")"
            )
            return newValueInCaseOfOverflow
        }
        return newValue
    }

    static func quicSafeIncrement(
        value: Int,
        increment: Int,
        newValueInCaseOfOverflow: Int?,
        function: StaticString = #function
    ) -> Int? {
        // In C, this is done with UINT64 math, but it makes no difference for our calculations
        let (newValue, overflow) = value.addingReportingOverflow(increment)
        if overflow {
            Logger.proto.fault(
                "OVERFLOW: \(value) increment \(increment) result \(newValueInCaseOfOverflow?.description ?? "nil")"
            )
            return newValueInCaseOfOverflow
        }
        return newValue
    }

    func inboundStreamReady() {
        receiveState.change(logIDString: logPrefix, to: .receive)
        if !unidirectional {
            sendState.change(logIDString: logPrefix, to: .ready)
        }
    }

    func outboundStreamReady() {
        if !self.unidirectional {
            self.receiveState.change(logIDString: logPrefix, to: .receive)
        }
        self.sendState.change(logIDString: logPrefix, to: .ready)
    }

    func outboundStreamPending(connected: Bool, connection: QUICConnection) {
        if connected {
            if self.unidirectional {
                if connection.unidirectionalStreams.remoteMaxStreams == 0 {
                    return
                }
                if connection.unidirectionalStreams.previousRemoteMaxStreams != 0
                    && connection.unidirectionalStreams.remoteMaxStreams
                        <= connection.unidirectionalStreams.previousRemoteMaxStreams
                {
                    return
                }
                log.notice(
                    "Reached unidirectional stream limit (STREAMS_BLOCKED): \(connection.unidirectionalStreams.remoteMaxStreams)"
                )
                connection.unidirectionalStreams.previousRemoteMaxStreams =
                    connection.unidirectionalStreams.remoteMaxStreams
                connection.sendStreamsBlockedUnidirectional()
            } else {
                if connection.bidirectionalStreams.remoteMaxStreams == 0 {
                    return
                }
                if connection.bidirectionalStreams.previousRemoteMaxStreams != 0
                    && connection.bidirectionalStreams.remoteMaxStreams
                        <= connection.bidirectionalStreams.previousRemoteMaxStreams
                {
                    return
                }
                log.notice(
                    "Reached bidirectional stream limit (STREAMS_BLOCKED): \(connection.bidirectionalStreams.remoteMaxStreams)"
                )
                connection.bidirectionalStreams.previousRemoteMaxStreams =
                    connection.bidirectionalStreams.remoteMaxStreams
                connection.sendStreamsBlockedBidirectional()
                connection.sendFrames()
            }
        }
        // Don't send this frame during 0-RTT as we'll revisit once connected.
    }

    func addStreamData(frame: consuming Frame, isLast: Bool, connection: QUICConnection) {
        if sendState == .ready {
            sendState.change(logIDString: logPrefix, to: .send)
        }

        let dataLength = UInt64(frame.unclaimedLength)
        updateFlowControlWithEnqueuedBytesToSend(dataLength, connection: connection)
        sendBuffer.addSendData(frame, isLast: isLast)
    }

    // To be called when 0-RTT sending is rejected
    func resetSendStreamData() {
        sendState = .ready
        flowControlState.resetSentBytes()
        sendBuffer.empty()
        sendBuffer = StreamSendBuffer()
    }

    var hasMoreSendDataToService: Bool {
        sendBuffer.hasMoreSendDataToService(currentSendOffset: sendOffset)
    }

    @inline(__always)
    var remainingSendDataToService: UInt64 {
        sendBuffer.remainingDataLengthToService(currentSendOffset: sendOffset)
    }

    func recordStreamDataSending(
        writtenLength: UInt64,
        isFinal: Bool,
        pendingItems: inout PendingItems,
        connection: QUICConnection
    ) {
        if isFinal {
            if self.sendState == .send {
                self.sendState.change(logIDString: logPrefix, to: .dataSent)
            }
        }

        updateFlowControlWithSentBytes(writtenLength, connection: connection)

        if hasMoreSendDataToService {
            self.reportDataBlockedIfNecessary(on: &pendingItems)
            connection.reportDataBlockedIfNecessary(on: &pendingItems)
        }
    }
}

// MARK: Utility on Stream

@available(Network 0.1.0, *)
extension QUICStreamInstance {
    static func isValid(isServer: Bool, streamID: QUICStreamID) -> Bool {
        if !isServer && streamID.isClientInitiated {
            // Note that this is client reasoning about a peer streamID
            return false
        } else if isServer && streamID.isServerInitiated {
            // Note that this is server reasoning about a peer streamID
            return false
        }
        return true
    }
}

// MARK: Flow Control - Limits

@available(Network 0.1.0, *)
extension QUICStreamInstance {

    func setupMaxStreamData(
        isServer: Bool,
        remoteTransportParameters: TransportParameters?,
        localTransportParameters: TransportParameters
    ) {
        let remoteMaxStreamData = QUICStreamID.computeRemoteMaxStreamData(
            isServer: isServer,
            remoteTransportParameters: remoteTransportParameters,
            streamID: streamID!
        )

        let localMaxStreamData = QUICStreamID.computeLocalMaxStreamData(
            isServer: isServer,
            localTransportParameters: localTransportParameters,
            streamID: streamID!
        )

        flowControlState.initializeMaxDataValues(
            remoteMaxData: UInt64(remoteMaxStreamData),
            localMaxData: UInt64(localMaxStreamData)
        )

        updateOutboundFlowControlCredit(connection: parentProtocol)
    }

    func processIncomingMaxStreamData(remoteMaxStreamData: UInt64) {
        log.datapath("process MAX_STREAM_DATA")

        // Ignore MAX_STREAM_DATA when all stream data has been sent
        if sendState.dataHasAlreadyBeenSent {
            return
        }

        let previousRemoteMaxData = flowControlState.outboundMaxData
        guard updateOutboundMaxData(to: remoteMaxStreamData) else {
            return
        }

        log.datapath("new maxStreamData \(remoteMaxStreamData), was \(previousRemoteMaxData)")

        guard flowControlState.outboundMaxData > self.sendOffset else {
            // If the new value is smaller, error. Otherwise just return since it didn't increase
            if flowControlState.outboundMaxData < self.sendOffset {
                log.error(
                    "Remote max data \(remoteMaxStreamData) is less than the send offset \(self.sendOffset)"
                )
                parentProtocol.close(with: .internalError, "Invalid remote max stream data")
            }
            return
        }

        if hasSentDataBlocked {
            log.datapath("unblocked")
            hasSentDataBlocked = false
        }
    }
}
#endif
