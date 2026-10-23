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
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) -> (valid: Bool, checkZombie: Bool) {

        guard let nextInboundStreamID else {
            connection.log.fault("nextInboundStreamID is invalid")
            connection.close(with: .internalError, "inconsistent next inbound stream ID", in: &eventContext)
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
                connection.close(with: .streamStateError, "invalid stream ID", in: &eventContext)

                return (valid: false, checkZombie: false)
            }
        }

        if newStreamIDsAreBlocked(streamID) {
            connection.log.error(
                "Stream ID \(streamID) exceeded the maximum allowed"
            )
            connection.close(with: .streamLimitError, "exceeded maximum stream ID", in: &eventContext)

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
            "\(logIDString) \(logContext) Got newMaxStreams=\(newMaxStreams) which gives remoteMaxStreamID=\(remoteMaxStreamID?.description ?? "unknown")"
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
            "\(logIDString) \(logContext) Got newMaxStreams=\(newMaxStreams) which gives localMaxStreamID=\(localMaxStreamID?.description ?? "unknown")"
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
        case .sendable: return "sendable"
        case .unblockedSend: return "unblockedSend"
        default: return "none"
        }
    }
}

// MARK: QUIC Stream

// QUICStreamList is designed to hold a list of flow identifiers that fit different list types.
// For example, pendingReassemblyDequeue, sendable, and unblockedSend lists.
// Note that QUICStreamList only holds the flow identifiers that are used to lookup
// the actual streams held in the multiplexedFlows dictionary already.
// Also note that a flow identifier can exist in multiple lists at one time.
//
// Because the list stores only identifiers, it does not depend on the connection's linkage
// families; the operations that need to resolve an identifier back to a stream are generic
// over the families instead.
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
        list.append(stream.flowIdentifier)
        stream.listMembership.insert(listType)
    }

    mutating func removeFirst(
        connection: QUICConnection
    ) -> QUICStreamInstance? {
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

        let identifier = stream.flowIdentifier
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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICStreamInstance: MultiplexedStreamFlow<QUICConnection, BaseInboundStreamLinkage>,
    UnidirectionalAbortingStreamFlow, EarlyDataStreamFlow
{
    // Field ordering for QUICStreamInstance is important because it makes sure we are not taking
    // extra hits for padding.
    var listMembership: StreamListMembership = .none

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

    var streamMetadata = QUICStreamProtocol.QUICStreamMetadata()

    var flowControlState = FlowControlState(isStream: true)
    var flowControlStreamState = FlowControlStreamState()

    var receive = QUICReceiveState()

    // Using optional values here throws the padding off so use .max and vend back optional values
    private var finalSizeStorage: UInt64 = .max
    private var inboundApplicationErrorStorage: UInt64 = .max
    private var outboundApplicationErrorStorage: UInt64 = .max
    // QUICStreamID.maxValid is 2^62-1 and will reject anything above it so we use this to denote nil
    private var streamIDStorage: UInt64 = .max
    @inline(always)
    var finalSize: UInt64? {
        get { finalSizeStorage == .max ? nil : finalSizeStorage }
        set { finalSizeStorage = newValue ?? .max }
    }

    /// The application error code for the inbound (receive) direction.
    ///
    /// Used for the `STOP_SENDING` frame.
    @inline(always)
    var inboundApplicationError: UInt64? {
        get { inboundApplicationErrorStorage == .max ? nil : inboundApplicationErrorStorage }
        set { inboundApplicationErrorStorage = newValue ?? .max }
    }
    /// The application error code for the outbound (send) direction.
    ///
    /// Used for the `RESET_STREAM` frame.
    @inline(always)
    var outboundApplicationError: UInt64? {
        get { outboundApplicationErrorStorage == .max ? nil : outboundApplicationErrorStorage }
        set { outboundApplicationErrorStorage = newValue ?? .max }
    }
    @inline(always)
    private(set) var streamID: QUICStreamID? {
        get { streamIDStorage == .max ? nil : QUICStreamID(streamIDStorage)! }
        set { streamIDStorage = newValue?.value ?? .max }
    }

    var send = QUICSendState()

    override public func asLowerLinkage() -> UpperProtocol.PairedLowerLinkage {
        BaseOutboundStreamLinkage(quicStream: self)
    }

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
        self.log.logPrefix = "[S\(streamIDString)]"
        #endif
        if let _streamID = self.streamID {
            self.streamMetadata.streamID = _streamID.value
            self.streamMetadata.streamType = _streamID.quicStreamType
        }
        self.receive.reassemblyQueue.log = NetworkLoggerState(logPrefixer.logIDString)
    }

    func resetStreamID(streamID: QUICStreamID) {
        self.streamID = streamID
        #if !DisableDebugLogging
        self.log.logPrefix = "[S\(streamID.description)]"
        #endif
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
        receive.reassemblyQueue.dequeueAll()
        self.send.buffer.empty()
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        receive.reassemblyQueue.dequeueAll()
        guard !self.closed else { return }
        self.send.buffer.empty()
        parentProtocol.handleStreamClose(stream: self, error: nil, in: &eventContext)
    }

    func close(errorCode: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        self.send.buffer.empty()
        parentProtocol.handleStreamClose(stream: self, error: errorCode, in: &eventContext)
    }

    /// Releases this stream's event state from outside the protocol stack, for tests only.
    func destroyFromExternalTest() {
        fromExternal { eventContext in
            unregisterEventManager(in: &eventContext)
        }
    }

    public func abortOutbound(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        self.outboundApplicationError = UInt64(error?.quicApplicationError ?? 0)
        let parent = parentProtocol
        _ = parent.handleStopWrite(for: self)
        parent.sendFrames(in: &eventContext)
    }

    public func abortInbound(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        self.inboundApplicationError = UInt64(error?.quicApplicationError ?? 0)
        let parent = parentProtocol
        parent.handleStopRead(for: self)
        parent.sendFrames(in: &eventContext)
    }

    func emptyPendingData(connection: QUICConnection) {
        removePendingOutboundBytesFromFlowControl(connection: connection)
        send.buffer.empty()
    }

    // This processes an incoming STREAM frame belonging to a QUICStream
    func processIncomingStream(
        connection: QUICConnection,
        frame: consuming FrameStreamReceived,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        if self.pendingReportReady {
            self.flags.remove(.pendingReportReady)
        }

        // Ignore STREAM frame when all data has already been received
        if self.receive.state.dataHasAlreadyBeenReceived {
            frame.frame.finalize(success: true)
            return true
        }

        var result = true
        if self.receive.state.isReceivingData {
            result = processIncomingStreamData(connection: connection, frame: frame, in: &eventContext)
        } else {
            frame.frame.finalize(success: false)
        }
        log.datapath("Received bytes up to \(self.flowControlState.totalInOrderInboundBytesRead)")
        return result
    }

    private func processIncomingStreamData(
        connection: QUICConnection,
        frame: consuming FrameStreamReceived,
        in eventContext: inout NetworkContext.EventContext
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

        var closeReason: String?

        processing: repeat {
            // Offset is from a VLE so should not be bigger than a 62bit value
            // so does not represent a problem in 64bit systems.
            guard
                let appendResult = receive.tryAppend(
                    frame: frame.frame,
                    offset: Int(frame.offset),
                    fin: frame.isFinal,
                    maximumUnreadInboundBytesAllowed: maximumUnreadInboundBytesAllowed
                )
            else {
                connection.log.error(
                    "Stream reassembly queue has too many items, closing"
                )
                closeReason = "exceeded stream reassembly queue limits"
                break processing
            }
            let dataAdded = appendResult.sizeAdded != 0

            let frameFinalSize = frame.isFinal ? frame.offset &+ UInt64(frame.length) : nil

            guard
                let _ = self.updateLastOffset(
                    connection: connection,
                    newLastOffset: UInt64(appendResult.lastOffset),
                    newFinalSize: frameFinalSize,
                    in: &eventContext
                )
            else {
                log.error("final_size invariants violated")
                closeReason = "final_size invariants violated"
                break processing
            }

            if frameFinalSize != nil {
                receive.markSizeKnownIfNeeded(logPrefix: log.logPrefix)
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

                if receive.markDataReceivedIfReached(
                    newOffset: newOffset,
                    finOffset: finOffset,
                    logPrefix: log.logPrefix
                ) {
                    log.error(
                        "Bytes received \(newOffset) > fin offset \(finOffset)"
                    )
                    closeReason = "bytes received larger than FIN offset"
                    break processing
                }

                if !self.listMembership.contains(.pendingReassemblyDequeue) {
                    connection.pendingReassemblyDequeue.append(self)
                }
            }
        } while false

        if let closeReason {
            connection.close(with: .internalError, closeReason, in: &eventContext)
            return false
        }
        return true
    }

    var isOpen: Bool {

        !(self.pendingStart || self.closed
            || (self.send.state == .invalid && self.receive.state == .invalid))
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
        newFinalSize: UInt64?,
        in eventContext: inout NetworkContext.EventContext
    ) -> UInt64? {
        var closeReason: String?

        validation: repeat {
            // (1) Endpoint received data that exceeds the value of previously
            // established final size.
            if let finalSize = self.finalSize, newFinalSize == nil, finalSize < newLastOffset {
                log.error(
                    "[true:\(self.receive.state)] endpoint received stream offset \(newLastOffset) that exceeds final size \(finalSize)"
                )
                closeReason = "stream offset exceeded its final size"
                break validation
            }

            // (2) Endpoint received data with final size that's lower
            // than the size of the stream data that was already established
            if self.finalSize == nil, newFinalSize != nil, newLastOffset < self.lastReceivedOffset {
                log.error(
                    "[false:\(self.receive.state)] endpoint received size \(newLastOffset) that's lower than size of the stream \(self.lastReceivedOffset)"
                )
                closeReason = "received final size lower than already received size"
                break validation
            }

            // (3) Endpoint received frame containing a different final size
            // to the one already established
            if let finalSize = self.finalSize, let newFinalSize, finalSize != newFinalSize {
                log.error(
                    "[true:\(self.receive.state)] Endpoint received final size \(newFinalSize) different from already established \(finalSize)"
                )
                closeReason = "received final size different to already established final size"
                break validation
            }
        } while false

        if let closeReason {
            connection.close(with: .finalSizeError, closeReason, in: &eventContext)
            return nil
        }

        if self.finalSize == nil, let newFinalSize {
            self.finalSize = newFinalSize
            log.datapath("Final size set to \(newFinalSize)")
        }

        let lastOffsetDelta = updateLastReceivedOffset(
            to: newLastOffset,
            connection: connection,
            in: &eventContext
        )
        if lastOffsetDelta != nil {
            log.datapath(
                "[\(self.finalSize != nil ? "true" : "false"):\(self.receive.state)] Adjusted last offset (conn \(connection.lastReceivedOffset), stream \(self.lastReceivedOffset))"
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
            let reassemblyQueueInOrderOffset = UInt64(receive.reassemblyQueue.currentOffset)
            updateFlowControlWithTotalInOrderInboundBytesRead(
                reassemblyQueueInOrderOffset,
                connection: connection
            )
        }

        self.sendInboundFlowControlCreditIfNeeded(connection: connection)
    }

    // Discards every inbound byte still buffered for this stream and returns the
    // flow control credit those bytes consumed.
    //
    // Called when the stream is closed with data the application never read,
    // either still sitting in the reassembly queue or already dequeued into the
    // upper receive queue awaiting a read. Those bytes counted against the
    // connection's receive window when they arrived; without this the credit is
    // never given back and the usable window shrinks permanently.
    func discardUnreadInboundBytes(connection: QUICConnection) {
        // Bytes handed to the upper layer but not yet read by the application.
        // Dequeuing already advanced the reassembly queue's `currentOffset` past
        // these, but flow control only counts them once the application reads,
        // so they are still missing from the in-order total.
        let pendingDelivery = UInt64(upperReceiveQueue.unclaimedLength)
        // Contiguous bytes reassembled but not yet dequeued.
        let pendingDequeue = UInt64(max(receive.reassemblyQueue.availableToDequeue, 0))

        // Anything the reassembly queue holds beyond the contiguous run is not
        // yet part of the in-order total, so it has no credit to return here;
        // the RESET_STREAM and zombie final-size paths cover those gaps.
        let discardedBytes = pendingDelivery + pendingDequeue
        guard discardedBytes > 0 else { return }

        log.datapath(
            "Discarding \(discardedBytes) unread inbound bytes on close "
                + "(\(pendingDelivery) awaiting read, \(pendingDequeue) awaiting dequeue)"
        )

        // Release the frames themselves before crediting, so the buffers are
        // freed even if the connection is already tearing down.
        upperReceiveQueue.finalizeAllFramesAsFailed()

        // Advance the in-order total to cover everything the queue holds
        // contiguously, which is what the application could have read. This adds
        // the same delta to the connection-wide total.
        let newInOrderTotal = UInt64(receive.reassemblyQueue.currentOffset) + pendingDequeue
        receive.reassemblyQueue.dequeueAll()
        updateFlowControlWithTotalInOrderInboundBytesRead(
            newInOrderTotal,
            connection: connection
        )

        // Both components are now part of the in-order total, so credit them as
        // consumed to move the MAX_DATA anchor past them.
        connection.creditDiscardedInboundBytes(discardedBytes)
    }

    @_optimize(speed)
    func dequeueReassembledData(connection: QUICConnection) -> FrameArray? {
        var markedFIN = markedInboundFINOnFrame
        let result = receive.dequeueReassembled(markedFIN: &markedFIN, log: log)
        if markedFIN {
            markedInboundFINOnFrame = true
        }
        return result
    }

    override public func upperReceiveQueueDrainedBytes(_ bytes: Int, in eventContext: inout NetworkContext.EventContext)
    {

        let parent = parentProtocol

        // Record with flow control that bytes have been delivered, and update flow credits.
        deliveredInboundBytes(consumedLength: bytes, connection: parent)

        // This notification is delivered from the application's read, which runs after the
        // inbound batch has already been serviced and flushed. If the read opened up the
        // receive window, we should send the credit here.
        if parent.applicationPendingItems.maxData
            || parent.applicationPendingItems.maxStreamData
        {
            parent.sendFrames(in: &eventContext)
        }

        if let streamID {
            QUICSignpost.dataDelivered(id: parent.signpostID, streamID: streamID.value, nbytes: bytes)
        }

        // If all data has now been read, move to the data read state
        if receive.state != .dataRead, upperReceiveQueue.isEmpty, markedInboundFINOnFrame {
            receive.state.change(logIDString: log.logPrefix, to: .dataRead)
            if !self.closed, self.send.state == .dataReceived {
                // If both directions are closed, and all data is read, close the stream
                self.close(errorCode: nil, in: &eventContext)
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
        let logPrefix = log.logPrefix
        receive.state.change(logIDString: logPrefix, to: .receive)
        if !unidirectional {
            send.state.change(logIDString: logPrefix, to: .ready)
        }
    }

    func outboundStreamReady() {
        let logPrefix = log.logPrefix
        if !self.unidirectional {
            self.receive.state.change(logIDString: logPrefix, to: .receive)
        }
        self.send.state.change(logIDString: logPrefix, to: .ready)
    }

    func outboundStreamPending(
        connected: Bool,
        connection: QUICConnection,
        in eventContext: inout NetworkContext.EventContext
    ) {
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
                connection.sendFrames(in: &eventContext)
            }
        }
        // Don't send this frame during 0-RTT as we'll revisit once connected.
    }

    func addStreamData(frame: consuming Frame, isLast: Bool, connection: QUICConnection) {
        let dataLength = UInt64(frame.unclaimedLength)
        updateFlowControlWithEnqueuedBytesToSend(dataLength, connection: connection)
        if send.enqueue(frame, isLast: isLast) {
            startSending()
        }
    }

    // Only the first write on a stream gets here. It is kept out of line so reading the log prefix
    // does not become part of every addStreamData call.
    @inline(never)
    private func startSending() {
        send.startSending(logIDString: log.logPrefix)
    }

    // To be called when 0-RTT sending is rejected
    func resetSendStreamData() {
        send.reset()
        flowControlState.resetSentBytes()
    }

    var hasMoreSendDataToService: Bool {
        send.buffer.hasMoreSendDataToService(currentSendOffset: sendOffset)
    }

    // Available view into the send buffer for building outbound stream frames
    func availableSendData() -> (offset: UInt64, remaining: UInt64, hasLast: Bool) {
        let offset = sendOffset
        let (remaining, hasLast) = send.buffer.sendServiceState(currentSendOffset: offset)
        return (offset, remaining, hasLast)
    }

    // NOTE: hasMoreDataToService is a signal that the send buffer contains the `hasLast` already
    // so no need to determine if data is blocked.
    func recordStreamDataSending(
        writtenLength: UInt64,
        isFinal: Bool,
        hasMoreDataToService: Bool,
        pendingItems: inout PendingItems,
        connection: QUICConnection
    ) {
        send.recordSent(isFinal: isFinal, logPrefix: log.logPrefix)

        updateFlowControlWithSentBytes(writtenLength, connection: connection)

        if hasMoreDataToService {
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

    func processIncomingMaxStreamData(
        remoteMaxStreamData: UInt64,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.datapath("Process MAX_STREAM_DATA")

        // Ignore MAX_STREAM_DATA when all stream data has been sent
        if send.state.dataHasAlreadyBeenSent {
            return
        }

        let previousRemoteMaxData = flowControlState.outboundMaxData
        guard updateOutboundMaxData(to: remoteMaxStreamData) else {
            return
        }

        log.datapath("New maxStreamData \(remoteMaxStreamData), was \(previousRemoteMaxData)")

        guard flowControlState.outboundMaxData > self.sendOffset else {
            // If the new value is smaller, error. Otherwise just return since it didn't increase
            if flowControlState.outboundMaxData < self.sendOffset {
                log.error(
                    "Remote max data \(remoteMaxStreamData) is less than the send offset \(self.sendOffset)"
                )
                parentProtocol.close(with: .internalError, "Invalid remote max stream data", in: &eventContext)
            }
            return
        }

        if hasSentDataBlocked {
            log.datapath("Unblocked")
            hasSentDataBlocked = false
        }
    }
}
#endif
