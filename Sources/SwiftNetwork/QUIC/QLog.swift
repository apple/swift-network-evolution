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
#if !NETWORK_STANDALONE && canImport(Foundation)
// Needed for writing the qlog file
import struct Foundation.Data
import class Foundation.FileManager
import class Foundation.JSONSerialization
#endif  // !NETWORK_EMBEDDED

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct QLogConfiguration: CustomStringConvertible, Sendable {
    public var logTitle: String?
    public var logDescription: String?
    public var logPath: String
    public var description: String {

        "title: \(logTitle ?? ""), description: \(logDescription ?? ""), path: \(logPath)"
    }
    public init(logTitle: String? = nil, logDescription: String? = nil, logPath: String) {
        self.logTitle = logTitle
        self.logDescription = logDescription
        self.logPath = logPath
    }
}

enum QLogCongestionState: String {
    case slowStart = "slow_start"
    case congestionAvoidance = "congestion_avoidance"
    case applicationLimited = "application_limited"
    case recovery
    case cwr = "congestion_window_reduced"
}

enum QLogCongestionTrigger: String {
    case persistentCongestion = "persistent_congestion"
    case ecn
}

enum QLogPacketLostTrigger: String {
    case reordering = "reordering_threshold"
    case time = "time_threshold"
    case pto = "pto_expired"
}

enum QLogFlowType: String {
    case client
    case server
}

enum QLogOwner: String {
    case local
    case remote
}

#if QlogOutput

enum QLogPacketSentReceivedTrigger: String {
    case retransmitReordered = "reordering_threshold"
    case retransmitTimeout = "time_threshold"
    case ptoProbe = "pto_expired"
    case retransmitCrypto = "retransmit_crypto"
    case congestionControlBandwidthProbe = "bandwidth_probe"
    case unknown = "unknown"
}

enum QLogStreamSide: String {
    case sending
    case receiving
}

enum QLogStreamState: Int {
    case idle = 0
    case open
    case halfClosedLocal
    case halfClosedRemote
    case closed

    case ready
    case send
    case dataSent
    case resetSent
    case resetReceived

    case receive
    case sizeKnown
    case dataRead
    case resetRead

    case dataReceived

    case destroyed
    case unknown
}

protocol EventProtocol {
    func dumpData() -> [String: Any]
}

@available(Network 0.1.0, *)
struct StreamEvent: EventProtocol {
    let streamID: QUICStreamID
    let streamType: QUICStreamType
    let oldStreamState: QLogStreamState
    let newStreamState: QLogStreamState
    let streamSide: QLogStreamSide?

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["stream_id"] = QLog.wrapUInt64IfNotMax(streamID.value)
        data["stream_type"] = streamType.description
        data["old"] = oldStreamState.rawValue == 0 ? nil : oldStreamState.rawValue
        data["new"] = newStreamState.rawValue == 0 ? nil : newStreamState.rawValue
        data["stream_side"] = streamSide?.rawValue
        return data
    }
}

@available(Network 0.1.0, *)
struct StreamTypeSetEvent: EventProtocol {
    let streamID: QUICStreamID
    let owner: QLogOwner?
    let oldStreamType: QUICStreamType
    let newStreamType: QUICStreamType

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["stream_id"] = QLog.wrapUInt64IfNotMax(streamID.value)
        data["owner"] = owner?.rawValue
        data["old"] = oldStreamType.description
        data["new"] = newStreamType.description
        return data
    }
}

@available(Network 0.1.0, *)
struct EventParametersSet: EventProtocol {
    let owner: QLogOwner?
    let resumptionAllowed: Bool?
    let earlyDataEnabled: Bool?
    let tlsCipher: String
    let originalDCID: QUICConnectionID?
    let initialSCID: QUICConnectionID?
    let retrySCID: QUICConnectionID?
    let disableActiveMigration: Bool?
    let maxIdleTimeout: Int?
    let maxUDPPayloadSize: Int?
    let ackDelayExponent: Int?
    let maxAckDelay: Int?
    let activeConnectionIDLimit: Int?
    let initialMaxData: Int?
    let initialMaxStreamDataBidirectionalRemote: Int?
    let initialMaxStreamDataBidirectionalLocal: Int?
    let initialMaxStreamDataUnidirectional: Int?
    let initialMaxStreamsBidirectional: Int?
    let initialMaxStreamsUnidirectional: Int?
    let preferredAddress: PreferredAddress?

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["owner"] = owner?.rawValue
        data["resumption_allowed"] = resumptionAllowed?.description
        data["early_data_enabled"] = earlyDataEnabled?.description
        data["tls_cipher"] = tlsCipher
        data["original_destination_connection_id"] = originalDCID?.description
        data["retry_source_connection_id"] = retrySCID?.description
        data["initial_source_connection_id"] = initialSCID?.description
        data["disable_active_migration"] = disableActiveMigration?.description
        data["max_idle_timeout"] = maxIdleTimeout
        data["max_udp_payload_size"] = maxUDPPayloadSize
        data["ack_delay_exponent"] = ackDelayExponent
        data["max_ack_delay"] = maxAckDelay
        data["active_connection_id_limit"] = activeConnectionIDLimit
        data["initial_max_data"] = initialMaxData
        data["initial_max_stream_data_bidi_local"] = initialMaxStreamDataBidirectionalLocal
        data["initial_max_stream_data_bidi_remote"] = initialMaxStreamDataBidirectionalRemote
        data["initial_max_stream_data_uni"] = initialMaxStreamDataUnidirectional
        data["initial_max_streams_bidi"] = initialMaxStreamsBidirectional
        data["initial_max_streams_uni"] = initialMaxStreamsUnidirectional
        data["preferred_address"] = preferredAddress
        if let preferredAddress {
            data["ip_v4"] = preferredAddress.ipv4Address.description
            data["ip_v6"] = preferredAddress.ipv6Address.description
            data["port_v4"] = preferredAddress.ipv4Port.description
            data["port_v6"] = preferredAddress.ipv6Port.description
            data["connection_id"] = preferredAddress.connectionID.description
            data["stateless_reset_token"] = preferredAddress.statelessResetToken.description
        }
        return data
    }
}

@available(Network 0.1.0, *)
struct EventPacket {
    let packetType: PacketType
    let packetHeader: PacketHeader
    let frameList: EventFrames
    let isCoalesced: Bool?
    enum Trigger {
        case sentReceivedTrigger(QLogPacketSentReceivedTrigger?)
        case lostTrigger(QLogPacketLostTrigger?)
    }
    let trigger: Trigger
}

@available(Network 0.1.0, *)
struct PacketHeader {
    let packetNumber: PacketNumber
    let packetSize: UInt64
    let payloadLength: UInt64
    var version: QUICVersion = .v1
    var scil: Int = 0
    var dcil: Int = 0
    var scid: String = ""
    var dcid: String = ""

    init(packet: borrowing SentPacketRecord) {
        self.packetNumber = packet.number
        self.packetSize = UInt64(packet.totalLength)
        self.payloadLength = 0
    }

    init(packet: borrowing Packet) {
        self.packetNumber = packet.number
        self.packetSize = UInt64(packet.totalLength)
        self.payloadLength = UInt64(packet.payloadLength)
        if let scid = packet.sourceConnectionID {
            self.scil = scid.length
            self.scid = scid.description
        }
        if let dcid = packet.destinationConnectionID {
            self.dcil = dcid.length
            self.dcid = dcid.description
        }
    }

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["packet_number"] = String(packetNumber.value)
        data["packet_size"] = QLog.wrapUInt64IfNotMax(packetSize)
        data["length"] = QLog.wrapUInt64IfNotMax(payloadLength)
        data["version"] = version.rawValue
        if scil != 0 {
            data["scil"] = scil
            data["scid"] = scid
        }
        if dcil != 0 {
            data["dcil"] = dcil
            data["dcid"] = dcid
        }
        return data
    }
}

@available(Network 0.1.0, *)
enum Event {
    case parametersSet(EventParametersSet, timestamp: NetworkDuration)
    case packetSent(EventPacket, timestamp: NetworkDuration)
    case packetReceived(EventPacket, timestamp: NetworkDuration)
    case streamStateUpdated(StreamEvent, timestamp: NetworkDuration)
    case metricsUpdated(EventMetrics, timestamp: NetworkDuration)
    case congestionStateUpdated(
        EventCongestionStateUpdated,
        timestamp: NetworkDuration
    )
    case packetLost(EventPacket, timestamp: NetworkDuration)
    case streamTypeSet(StreamTypeSetEvent, timestamp: NetworkDuration)

    func commonEventData(timestamp: NetworkDuration) -> [Any] {
        // All timestamps and time-related values (e.g., offsets) in qlog are logged as
        // float64 in the millisecond resolution
        [timestamp.milliseconds, self.category(), self.description()]
    }

    func eventData() -> [Any] {
        switch self {
        case .packetReceived(let eventPacket, let timestamp),
            .packetSent(let eventPacket, let timestamp),
            .packetLost(let eventPacket, let timestamp):

            var content: [Any] = self.commonEventData(timestamp: timestamp)
            var dataContent: [String: Any] = [:]
            dataContent["packet_type"] = eventPacket.packetType.rawValue

            dataContent["header"] = eventPacket.packetHeader.dumpData()

            dataContent["frames"] = eventPacket.frameList.dumpData()

            if let coalesced = eventPacket.isCoalesced?.description {
                dataContent["is_coalesced"] = coalesced
            }

            switch eventPacket.trigger {
            case .sentReceivedTrigger(let trigger):
                dataContent["trigger"] = trigger?.rawValue
            case .lostTrigger(let trigger):
                dataContent["trigger"] = trigger?.rawValue
            }
            content.append(dataContent)
            return content

        case .parametersSet(let event as any EventProtocol, let timestamp),
            .streamStateUpdated(let event as any EventProtocol, let timestamp),
            .metricsUpdated(let event as any EventProtocol, let timestamp),
            .congestionStateUpdated(let event as any EventProtocol, let timestamp),
            .streamTypeSet(let event as any EventProtocol, let timestamp):
            var content: [Any] = self.commonEventData(timestamp: timestamp)
            let dataContent: [String: Any] = event.dumpData()
            content.append(dataContent)
            return content
        }
    }

    func category() -> String {
        switch self {
        case .parametersSet, .packetSent,
            .packetReceived, .streamStateUpdated:
            return "TRANSPORT"
        case .metricsUpdated, .congestionStateUpdated,
            .packetLost:
            return "RECOVERY"
        case .streamTypeSet:
            return "http"
        }
    }

    func description() -> String {
        switch self {
        case .parametersSet:
            return "PARAMETERS_SET"
        case .packetSent:
            return "PACKET_SENT"
        case .packetReceived:
            return "PACKET_RECEIVED"
        case .streamStateUpdated:
            return "STREAM_STATE_UPDATED"
        case .metricsUpdated:
            return "METRICS_UPDATED"
        case .congestionStateUpdated:
            return "CONGESTION_STATE_UPDATED"
        case .packetLost:
            return "PACKET_LOST"
        case .streamTypeSet:
            return "STREAM_TYPE_SET"
        }
    }
}

@available(Network 0.1.0, *)
struct EventFrame {
    var frame: QUICShorthandFrame
    init(frame: QUICShorthandFrame) {
        self.frame = frame
    }

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        switch self.frame {
        case .padding(let frame):
            data["frame_type"] = "padding"
            data["payload_length"] = frame.length
        case .ping(_):
            data["frame_type"] = "ping"
        case .ack(let frame):
            data["frame_type"] = "ack"
            data["ack_delay"] = frame.delay
            if let ecnCounter = frame.ecnCounter {
                data["ect0"] = ecnCounter.ect0
                data["ect1"] = ecnCounter.ect1
                data["ce"] = ecnCounter.ce
            }
            data["acked_ranges"] = frame.buildAckRanges()
        case .resetStream(let frame):
            data["frame_type"] = "reset_stream"
            data["stream_id"] = frame.id
            data["final_size"] = frame.finalSize
            data["error_code"] = frame.code
        case .stopSending(let frame):
            data["frame_type"] = "stop_sending"
            data["stream_id"] = frame.id
            data["error_code"] = frame.code
        case .crypto(let frame):
            data["frame_type"] = "crypto"
            data["offset"] = frame.offset
            data["length"] = frame.length
        case .newToken(let frame):
            data["frame_type"] = "new_token"
            data["length"] = frame.length
        case .stream(let frame):
            data["frame_type"] = "stream"
            data["offset"] = frame.offset
            data["stream_id"] = frame.id
            data["length"] = frame.length
        case .maxData(let frame):
            data["frame_type"] = "max_data"
            data["maximum"] = frame.max
        case .maxStreamData(let frame):
            data["frame_type"] = "max_stream_data"
            data["stream_id"] = frame.id
            data["maximum"] = frame.max
        case .maxStreamsBidirectional(let frame):
            data["frame_type"] = "max_streams"
            data["stream_type"] = "bidirectional"
            data["maximum"] = frame.max
        case .maxStreamsUnidirectional(let frame):
            data["frame_type"] = "max_streams"
            data["stream_type"] = "unidirectional"
            data["maximum"] = frame.max
        case .dataBlocked(let frame):
            data["frame_type"] = "data_blocked"
            data["limit"] = frame.limit
        case .streamDataBlocked(let frame):
            data["frame_type"] = "stream_data_blocked"
            data["stream_id"] = frame.id
            data["limit"] = frame.limit
        case .streamsBlockedBidirectional(let frame):
            data["frame_type"] = "streams_blocked"
            data["stream_type"] = "bidirectional"
            data["limit"] = frame.limit
        case .streamsBlockedUnidirectional(let frame):
            data["frame_type"] = "streams_blocked"
            data["stream_type"] = "unidirectional"
            data["limit"] = frame.limit
        case .newConnectionID(let frame):
            data["frame_type"] = "new_connection_id"
            data["sequence_number"] = frame.sequence
            data["retire_prior_to"] = frame.retirePriorToSequence
            data["length"] = frame.connectionID.length
            data["connection_id"] = frame.connectionID.description
        case .retireConnectionID(let frame):
            data["frame_type"] = "retire_connection_id"
            data["sequence_number"] = frame.sequence
        case .pathChallenge:
            data["frame_type"] = "path_challenge"
        case .pathResponse:
            data["frame_type"] = "path_response"
        case .connectionClose(let frame):
            data["frame_type"] = "connection_close"
            data["error_space"] = "transport"
            data["raw_error_code"] = frame.errorCode
            data["reason"] = frame.reason
        case .applicationClose(let frame):
            data["frame_type"] = "connection_close"
            data["error_space"] = "application"
            data["raw_error_code"] = frame.errorCode
            data["reason"] = frame.reason
        case .handshakeDone(_):
            data["frame_type"] = "handshake_done"
        case .datagram(let frame):
            data["frame_type"] = "datagram"
            data["length"] = frame.length
            data["flow_id"] = frame.flowID
        }
        return data
    }
}

@available(Network 0.1.0, *)
struct EventFrames {
    var frames: [EventFrame] = []

    init() {}
    init(packet: borrowing Packet) {
        if let shorthandFrames = packet.shorthandFrames {
            for shorthandFrame in shorthandFrames {
                self.frames.append(.init(frame: shorthandFrame))
            }
        }
    }
    func dumpData() -> [Any] {
        var data: [Any] = []
        for frame in frames {
            data.append(frame.dumpData())
        }
        return data
    }
}

enum PacketType: String {
    case unknown = "unknown"
    case initial = "initial"
    case handshake = "handshake"
    case zeroRTT = "0RTT"
    case oneRTT = "1RTT"
    case retry = "retry"
    case versionNegotiation = "version_negotiation"

    @available(Network 0.1.0, *)
    init(packet: borrowing SentPacketRecord) {
        switch packet.identifier.space {
        case .initial:
            self = .initial
        case .handshake:
            self = .handshake
        case .applicationData:
            self = .oneRTT
        }
    }

    @available(Network 0.1.0, *)
    init(packet: borrowing Packet) {
        if packet.versionNegotiation {
            self = .versionNegotiation
        } else if packet.keyState == .initial {
            self = .initial
        } else if packet.keyState == .handshake {
            self = .handshake
        } else if packet.keyState == .earlyData {
            self = .zeroRTT
        } else if packet.keyState == .phase0 || packet.keyState == .phase1 {
            self = .oneRTT
        } else if packet.retry {
            self = .retry
        } else {
            self = .unknown
        }
    }
}

@available(Network 0.1.0, *)
struct EventMetrics: EventProtocol {
    let minRTT: NetworkDuration
    let smoothedRTT: NetworkDuration
    let latestRTT: NetworkDuration
    let rttVariance: NetworkDuration
    let ptoCount: UInt64
    let congestionWindow: UInt64
    let bytesInFlight: UInt64
    let slowStartThresh: UInt64
    let packetsInFlight: UInt64
    let inRecovery: Bool?

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["min_rtt"] = QLog.wrapInt64IfZero(minRTT.milliseconds)
        data["smoothed_rtt"] = QLog.wrapInt64IfZero(smoothedRTT.milliseconds)
        data["latest_rtt"] = QLog.wrapInt64IfZero(latestRTT.milliseconds)
        data["rtt_variance"] = QLog.wrapInt64IfZero(rttVariance.milliseconds)
        data["pto_count"] = QLog.wrapUInt64IfNotMax(ptoCount)
        data["congestion_window"] = QLog.wrapUInt64IfNotMax(congestionWindow)
        data["bytes_in_flight"] = QLog.wrapUInt64IfNotMax(bytesInFlight)
        data["ssthresh"] = QLog.wrapUInt64IfNotMax(slowStartThresh)
        data["packets_in_flight"] = QLog.wrapUInt64IfNotMax(packetsInFlight)
        data["in_recovery"] = inRecovery?.description
        return data
    }
}

struct EventCongestionStateUpdated: EventProtocol {
    let oldCongestionState: QLogCongestionState?
    let newCongestionState: QLogCongestionState?
    let congestionStateTrigger: QLogCongestionTrigger?

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["old"] = oldCongestionState?.rawValue
        data["new"] = newCongestionState?.rawValue
        data["trigger"] = congestionStateTrigger?.rawValue
        return data
    }
}

@available(Network 0.1.0, *)
final class QLog {
    private var eventsList: [Event]
    private var topLevelObject: [String: Any]
    private var disableTimestamps: Bool = false
    private let startTime = NetworkClock.Instant.now
    var configuration: QLogConfiguration?

    public init(configuration: QLogConfiguration? = nil) {
        self.configuration = configuration
        self.eventsList = []
        self.topLevelObject = [:]
        self.topLevelObject["qlog_version"] = "draft-01"
        if let title = configuration?.logTitle {
            self.topLevelObject["title"] = title
        }
        if let description = configuration?.description {
            self.topLevelObject["description"] = description
        }
    }

    static func wrapUInt64InStringIfNotMax(_ value: UInt64) -> String? {
        if value == UInt64.max {
            return nil
        }
        return String(value)
    }

    static func wrapInt64IfZero(_ value: Int64) -> Int64? {
        if value == 0 {
            return nil
        }
        return value
    }

    static func wrapUInt64IfNotMax(_ value: UInt64) -> UInt64? {
        if value == UInt64.max {
            return nil
        }
        return value
    }

    private func calculateTimestamp(_ timestamp: NetworkClock.Instant) -> NetworkDuration {
        if disableTimestamps || timestamp == .zero {
            return .zero
        } else {
            return startTime.duration(to: timestamp)
        }
    }

    func packetSent(_ packet: borrowing Packet, timestamp: NetworkClock.Instant) {
        let packetType = PacketType(packet: packet)
        let packetHeader = PacketHeader(packet: packet)
        let frameList = EventFrames(packet: packet)
        let packetEvent = EventPacket(
            packetType: packetType,
            packetHeader: packetHeader,
            frameList: frameList,
            isCoalesced: nil,
            trigger: .sentReceivedTrigger(.unknown)
        )
        let event = Event.packetSent(packetEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    func packetReceived(
        _ packet: borrowing Packet,
        coalesced isCoalesced: Bool,
        timestamp: NetworkClock.Instant
    ) {
        let packetEvent = EventPacket(
            packetType: PacketType(packet: packet),
            packetHeader: PacketHeader(packet: packet),
            frameList: EventFrames(packet: packet),
            isCoalesced: isCoalesced,
            trigger: .sentReceivedTrigger(.unknown)
        )
        let event = Event.packetReceived(packetEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    func packetLost(
        _ packet: borrowing SentPacketRecord,
        trigger: QLogPacketLostTrigger?,
        timestamp: NetworkClock.Instant
    ) {
        let packetEvent = EventPacket(
            packetType: PacketType(packet: packet),
            packetHeader: PacketHeader(packet: packet),
            frameList: .init(),
            isCoalesced: nil,
            trigger: .lostTrigger(trigger)
        )
        let event = Event.packetLost(packetEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    func metricsUpdated(
        minRTT: NetworkDuration,
        smoothedRTT: NetworkDuration,
        latestRTT: NetworkDuration,
        rttVariance: NetworkDuration,
        ptoCount: UInt64 = UInt64.max,
        congestionWindow: UInt64 = UInt64.max,
        bytesInFlight: UInt64 = UInt64.max,
        slowStartThresh: UInt64 = UInt64.max,
        packetsInFlight: UInt64 = UInt64.max,
        inRecovery: Bool?,
        timestamp: NetworkClock.Instant
    ) {
        let metricEvent = EventMetrics(
            minRTT: minRTT,
            smoothedRTT: smoothedRTT,
            latestRTT: latestRTT,
            rttVariance: rttVariance,
            ptoCount: ptoCount,
            congestionWindow: congestionWindow,
            bytesInFlight: bytesInFlight,
            slowStartThresh: slowStartThresh,
            packetsInFlight: packetsInFlight,
            inRecovery: inRecovery
        )
        let event = Event.metricsUpdated(metricEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    public func recoveryUpdated(
        ptoCount: UInt64,
        inRecovery: Bool?,
        timestamp: NetworkClock.Instant
    ) {
        metricsUpdated(
            minRTT: .zero,
            smoothedRTT: .zero,
            latestRTT: .zero,
            rttVariance: .zero,
            ptoCount: ptoCount,
            congestionWindow: UInt64.max,
            bytesInFlight: UInt64.max,
            slowStartThresh: UInt64.max,
            packetsInFlight: UInt64.max,
            inRecovery: inRecovery,
            timestamp: timestamp
        )
    }

    public func congestionControlUpdated(
        congestionWindow: UInt64 = UInt64.max,
        bytesInFlight: UInt64 = UInt64.max,
        slowStartThresh: UInt64 = UInt64.max,
        packetsInFlight: UInt64 = UInt64.max,
        timestamp: NetworkClock.Instant = .now
    ) {
        metricsUpdated(
            minRTT: .zero,
            smoothedRTT: .zero,
            latestRTT: .zero,
            rttVariance: .zero,
            ptoCount: UInt64.max,
            congestionWindow: congestionWindow,
            bytesInFlight: bytesInFlight,
            slowStartThresh: slowStartThresh,
            packetsInFlight: packetsInFlight,
            inRecovery: nil,
            timestamp: timestamp
        )
    }

    func rttUpdated(
        minRTT: NetworkDuration,
        smoothedRTT: NetworkDuration,
        latestRTT: NetworkDuration,
        rttVariance: NetworkDuration,
        timestamp: NetworkClock.Instant
    ) {
        metricsUpdated(
            minRTT: minRTT,
            smoothedRTT: smoothedRTT,
            latestRTT: latestRTT,
            rttVariance: rttVariance,
            ptoCount: UInt64.max,
            congestionWindow: UInt64.max,
            bytesInFlight: UInt64.max,
            slowStartThresh: UInt64.max,
            packetsInFlight: UInt64.max,
            inRecovery: nil,
            timestamp: timestamp
        )
    }

    func streamStateUpdated(
        stream: QUICStreamInstance,
        oldStreamState: QLogStreamState,
        newStreamState: QLogStreamState,
        streamSide: QLogStreamSide?,
        timestamp: NetworkClock.Instant
    ) {
        if let streamID = stream.streamID, let streamType = stream.streamType {
            let streamEvent = StreamEvent(
                streamID: streamID,
                streamType: streamType,
                oldStreamState: oldStreamState,
                newStreamState: newStreamState,
                streamSide: streamSide
            )
            let event = Event.streamStateUpdated(
                streamEvent,
                timestamp: calculateTimestamp(timestamp)
            )
            eventsList.append(event)
        }
    }

    public func logCongestionStateUpdated(
        oldState: QLogCongestionState?,
        newState: QLogCongestionState?,
        trigger: QLogCongestionTrigger?,
        timestamp: NetworkClock.Instant = .now
    ) {
        let congestionEvent = EventCongestionStateUpdated(
            oldCongestionState: oldState,
            newCongestionState: newState,
            congestionStateTrigger: trigger
        )
        let event = Event.congestionStateUpdated(
            congestionEvent,
            timestamp: calculateTimestamp(timestamp)
        )
        eventsList.append(event)
    }

    func logStreamTypeSet(
        streamID: QUICStreamID,
        owner: QLogOwner?,
        oldStreamType: QUICStreamType,
        newStreamType: QUICStreamType,
        timestamp: NetworkClock.Instant
    ) {
        let streamTypeSetEvent = StreamTypeSetEvent(
            streamID: streamID,
            owner: owner,
            oldStreamType: oldStreamType,
            newStreamType: newStreamType
        )
        let event = Event.streamTypeSet(
            streamTypeSetEvent,
            timestamp: calculateTimestamp(timestamp)
        )
        eventsList.append(event)
    }

    public func parametersSet(
        owner: QLogOwner?,
        resumptionAllowed: Bool?,
        earlyDataEnabled: Bool?,
        tlsCipher: String,
        originalDCID: QUICConnectionID?,
        initialSCID: QUICConnectionID?,
        retrySCID: QUICConnectionID?,
        disableActiveMigration: Bool?,
        maxIdleTimeout: Int?,
        maxUDPPayloadSize: Int?,
        ackDelayExponent: Int?,
        maxAckDelay: Int?,
        activeConnectionIDLimit: Int?,
        initialMaxData: Int?,
        initialMaxStreamDataBidirectionalRemote: Int?,
        initialMaxStreamDataBidirectionalLocal: Int?,
        initialMaxStreamDataUnidirectional: Int?,
        initialMaxStreamsBidirectional: Int?,
        initialMaxStreamsUnidirectional: Int?,
        preferredAddress: PreferredAddress?,
        timestamp: NetworkClock.Instant
    ) {
        let parametersEvent = EventParametersSet(
            owner: owner,
            resumptionAllowed: resumptionAllowed,
            earlyDataEnabled: earlyDataEnabled,
            tlsCipher: tlsCipher,
            originalDCID: originalDCID,
            initialSCID: initialSCID,
            retrySCID: retrySCID,
            disableActiveMigration: disableActiveMigration,
            maxIdleTimeout: maxIdleTimeout,
            maxUDPPayloadSize: maxUDPPayloadSize,
            ackDelayExponent: ackDelayExponent,
            maxAckDelay: maxAckDelay,
            activeConnectionIDLimit: activeConnectionIDLimit,
            initialMaxData: initialMaxData,
            initialMaxStreamDataBidirectionalRemote: initialMaxStreamDataBidirectionalRemote,
            initialMaxStreamDataBidirectionalLocal: initialMaxStreamDataBidirectionalLocal,
            initialMaxStreamDataUnidirectional: initialMaxStreamDataUnidirectional,
            initialMaxStreamsBidirectional: initialMaxStreamsBidirectional,
            initialMaxStreamsUnidirectional: initialMaxStreamsUnidirectional,
            preferredAddress: preferredAddress
        )
        let event = Event.parametersSet(parametersEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    public func parametersSet(
        owner: QLogOwner?,
        transportParameters: TransportParameters,
        timestamp: NetworkClock.Instant
    ) {
        parametersSet(
            owner: owner,
            resumptionAllowed: nil,
            earlyDataEnabled: nil,
            tlsCipher: "",
            originalDCID: transportParameters[TransportParameterTypes.originalDCID]?.connectionID,
            initialSCID: transportParameters[TransportParameterTypes.initialSCID]?.connectionID,
            retrySCID: transportParameters[TransportParameterTypes.retrySCID]?.connectionID,
            disableActiveMigration: transportParameters[
                TransportParameterTypes.disableActiveMigration
            ] != nil ? true : false,
            maxIdleTimeout: transportParameters[TransportParameterTypes.maxIdleTimeout]?.value,
            maxUDPPayloadSize: transportParameters[TransportParameterTypes.maxUDPPayloadSize]?
                .value,
            ackDelayExponent: transportParameters[TransportParameterTypes.ackDelayExponent]?.value,
            maxAckDelay: transportParameters[TransportParameterTypes.maxAckDelay]?.value,
            activeConnectionIDLimit: transportParameters[
                TransportParameterTypes.activeConnectionIDLimit
            ]?.value,
            initialMaxData: transportParameters[TransportParameterTypes.initialMaxData]?.value,
            initialMaxStreamDataBidirectionalRemote: transportParameters[
                TransportParameterTypes.initialMaxStreamDataBidirectionalRemote
            ]?.value,
            initialMaxStreamDataBidirectionalLocal: transportParameters[
                TransportParameterTypes.initialMaxStreamDataBidirectionalLocal
            ]?.value,
            initialMaxStreamDataUnidirectional: transportParameters[
                TransportParameterTypes.initialMaxStreamDataUnidirectional
            ]?.value,
            initialMaxStreamsBidirectional: transportParameters[
                TransportParameterTypes.initialMaxStreamsBidirectional
            ]?.value,
            initialMaxStreamsUnidirectional: transportParameters[
                TransportParameterTypes.initialMaxStreamsUnidirectional
            ]?.value,
            preferredAddress: transportParameters[TransportParameterTypes.preferredAddress]?
                .preferredAddress,
            timestamp: timestamp
        )
    }

    public func setTopLevelObjectEntry(_ key: String, to value: String) {
        self.topLevelObject[key] = value
    }

    func disableTimestamps(disableTimestamps: Bool) {
        self.disableTimestamps = disableTimestamps
    }

    func dumpData(forFlowType flowType: QLogFlowType?) -> Data? {
        let vantagePointObject = [
            "type": "network", "flow": flowType?.rawValue,
        ]

        var traceObject: [String: Any] = ["vantage_point": vantagePointObject]

        let eventFieldsObject: [String] = [
            "time", "CATEGORY", "EVENT_TYPE", "DATA",
        ]
        traceObject["event_fields"] = eventFieldsObject

        var eventsArray: [Any] = []
        for event in eventsList {
            eventsArray.append(event.eventData())
        }
        eventsList.removeAll()

        traceObject["events"] = eventsArray

        let configurationObject = ["time_units": "us"]
        traceObject["configuration"] = configurationObject

        let traceList = [traceObject]
        topLevelObject["traces"] = traceList
        if let jsonData = try? JSONSerialization.data(withJSONObject: topLevelObject) {
            return jsonData
        } else {
            let topLevelObject = topLevelObject
            Logger.proto.error("Error serializing JSON: \(topLevelObject)")
            return nil
        }
    }

    // This is used with unit tests, therefore it needs to operate the same as dumpJSONToFile().
    // Therefore we use the common dumpData(forFlowType:) for both routines.
    public func dumpJSONString(forFlowType flowType: QLogFlowType?) -> String? {
        guard let jsonData = dumpData(forFlowType: flowType) else {
            return nil
        }
        let jsonString = String(data: jsonData, encoding: String.defaultCStringEncoding)
        return jsonString
    }

    public func dumpJSONToFile(
        atPath filename: String,
        forFlowType flowType: QLogFlowType?
    ) {
        guard let jsonData = dumpData(forFlowType: flowType) else {
            return
        }
        let _ = FileManager.default.createFile(atPath: filename, contents: jsonData)
    }
}
#else
final class QLog {}

#endif  // !NETWORK_EMBEDDED
#endif
