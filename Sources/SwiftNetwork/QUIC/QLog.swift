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
#elseif canImport(Android)
import Android
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
    public var vantagePointName: String
    public var description: String {
        "title: \(logTitle ?? ""), description: \(logDescription ?? ""), path: \(logPath), vantage point name: \(vantagePointName)"
    }
    public init(
        logTitle: String? = nil,
        logDescription: String? = nil,
        logPath: String,
        vantagePointName: String = "SwiftNetwork"
    ) {
        self.logTitle = logTitle
        self.logDescription = logDescription
        self.logPath = logPath
        self.vantagePointName = vantagePointName
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
    case retransmitReordered = "retransmit_reordered"
    case retransmitTimeout = "retransmit_timeout"
    case ptoProbe = "pto_probe"
    case retransmitCrypto = "retransmit_crypto"
    case congestionControlBandwidthProbe = "cc_bandwidth_probe"
    // Not a draft value: the trigger is omitted from the event when it is unknown.
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

@available(Network 0.1.0, *)
extension NetworkDuration {
    // qlog logs time-related values as float64 milliseconds, with a fractional part for finer detail.
    var qlogMilliseconds: Double {
        Double(nanoseconds) / 1_000_000
    }
}

extension QLogStreamState {
    // The strings are the BaseStreamStates and GranularStreamStates from the QUIC events draft.
    var qlogName: String {
        switch self {
        case .idle: return "idle"
        case .open: return "open"
        case .halfClosedLocal: return "half_closed_local"
        case .halfClosedRemote: return "half_closed_remote"
        case .closed: return "closed"
        case .ready: return "ready"
        case .send: return "send"
        case .dataSent: return "data_sent"
        case .resetSent: return "reset_sent"
        case .resetReceived: return "reset_received"
        case .receive: return "receive"
        case .sizeKnown: return "size_known"
        case .dataRead: return "data_read"
        case .resetRead: return "reset_read"
        case .dataReceived: return "data_received"
        case .destroyed: return "destroyed"
        case .unknown: return "unknown"
        }
    }
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
    let streamSide: QLogStreamSide

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["stream_id"] = QLog.wrapUInt64IfNotMax(streamID.value)
        data["stream_type"] = streamType.description
        data["old"] = oldStreamState == .idle ? nil : oldStreamState.qlogName
        data["new"] = newStreamState.qlogName
        data["stream_side"] = streamSide.rawValue
        return data
    }
}

@available(Network 0.1.0, *)
struct EventParametersSet: EventProtocol {
    let owner: QLogOwner
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
    let maxAckDelay: NetworkDuration?
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
        // initiator is "local" or "remote", matching QLogOwner's raw values.
        data["initiator"] = owner.rawValue
        data["resumption_allowed"] = resumptionAllowed
        data["early_data_enabled"] = earlyDataEnabled
        if !tlsCipher.isEmpty {
            data["tls_cipher"] = tlsCipher
        }
        data["original_destination_connection_id"] = originalDCID?.description
        data["retry_source_connection_id"] = retrySCID?.description
        data["initial_source_connection_id"] = initialSCID?.description
        data["disable_active_migration"] = disableActiveMigration
        data["max_idle_timeout"] = maxIdleTimeout
        data["max_udp_payload_size"] = maxUDPPayloadSize
        data["ack_delay_exponent"] = ackDelayExponent
        // qlog reports max_ack_delay in milliseconds, matching the wire encoding.
        data["max_ack_delay"] = maxAckDelay.map { Int($0.milliseconds) }
        data["active_connection_id_limit"] = activeConnectionIDLimit
        data["initial_max_data"] = initialMaxData
        data["initial_max_stream_data_bidi_local"] = initialMaxStreamDataBidirectionalLocal
        data["initial_max_stream_data_bidi_remote"] = initialMaxStreamDataBidirectionalRemote
        data["initial_max_stream_data_uni"] = initialMaxStreamDataUnidirectional
        data["initial_max_streams_bidi"] = initialMaxStreamsBidirectional
        data["initial_max_streams_uni"] = initialMaxStreamsUnidirectional
        if let preferredAddress {
            let ipv4 = preferredAddress.ipv4Address
            let ipv4Text = (0..<4).map { String((ipv4 >> UInt32(24 - 8 * $0)) & 0xff) }.joined(separator: ".")
            // IPAddressPort allows a raw hexstring for the address, which avoids ambiguous IPv6 forms.
            let ipv6Text = preferredAddress.ipv6Address.map { String(format: "%02x", $0) }.joined()
            data["preferred_address"] =
                [
                    "address_v4": ["ip": ipv4Text, "port": preferredAddress.ipv4Port],
                    "address_v6": ["ip": ipv6Text, "port": preferredAddress.ipv6Port],
                    "connection_id": preferredAddress.connectionID.description,
                    "stateless_reset_token": preferredAddress.statelessResetToken.description,
                ] as [String: Any]
        }
        return data
    }
}

@available(Network 0.1.0, *)
struct EventPacket {
    let packetHeader: PacketHeader
    let frameList: EventFrames
    enum Trigger {
        case sentReceivedTrigger(QLogPacketSentReceivedTrigger?)
        case lostTrigger(QLogPacketLostTrigger?)
    }
    let trigger: Trigger
}

@available(Network 0.1.0, *)
struct PacketHeader {
    let packetType: PacketType
    // Not present in Version Negotiation and Retry packets.
    let packetNumber: PacketNumber?
    let packetSize: UInt64
    let payloadLength: UInt64
    var version: QUICVersion = .v1
    var scil: Int = 0
    var dcil: Int = 0
    var scid: String = ""
    var dcid: String = ""

    init(packet: borrowing SentPacketRecord) {
        self.packetType = PacketType(packet: packet)
        self.packetNumber = packet.number
        self.packetSize = UInt64(packet.totalLength)
        self.payloadLength = 0
    }

    init(packet: borrowing Packet) {
        self.packetType = PacketType(packet: packet)
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

    // Returns nil for packets that failed decryption, as their header is not known.
    init?(parsedPacket: borrowing PacketParser.ParsedPacket) {
        switch parsedPacket {
        case .versionNegotiation(let vn):
            self.init(
                packetType: .versionNegotiation,
                version: .negotiation,
                packetSize: vn.length,
                destinationConnectionID: vn.destinationConnectionID,
                sourceConnectionID: vn.sourceConnectionID
            )
        case .retry(let retry):
            self.init(
                packetType: .retry,
                version: retry.version,
                packetSize: retry.length,
                destinationConnectionID: retry.destinationConnectionID,
                sourceConnectionID: retry.sourceConnectionID
            )
        case .failedDecryption:
            return nil
        case .protected(let packet):
            self.init(packet: packet)
        }
    }

    private init(
        packetType: PacketType,
        version: QUICVersion,
        packetSize: Int,
        destinationConnectionID: QUICConnectionID,
        sourceConnectionID: QUICConnectionID
    ) {
        self.packetType = packetType
        self.packetNumber = nil
        self.packetSize = UInt64(packetSize)
        self.payloadLength = UInt64.max
        self.version = version
        self.scil = sourceConnectionID.length
        self.scid = sourceConnectionID.description
        self.dcil = destinationConnectionID.length
        self.dcid = destinationConnectionID.description
    }

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["packet_type"] = packetType.rawValue
        if let packetNumber {
            data["packet_number"] = packetNumber.value
        }
        // QuicVersion is a hexstring.
        data["version"] = String(format: "%08x", version.rawValue)
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

    // The RawInfo for the packet: its full byte length and the length of its payload. The length
    // is omitted when it is not known, such as for Version Negotiation and Retry packets.
    func rawInfo() -> [String: Any]? {
        var raw: [String: Any] = [:]
        raw["length"] = QLog.wrapUInt64IfNotMax(packetSize)
        raw["payload_length"] = QLog.wrapUInt64IfNotMax(payloadLength)
        return raw.isEmpty ? nil : raw
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

    var timestamp: NetworkDuration {
        switch self {
        case .parametersSet(_, let timestamp),
            .packetSent(_, let timestamp),
            .packetReceived(_, let timestamp),
            .streamStateUpdated(_, let timestamp),
            .metricsUpdated(_, let timestamp),
            .congestionStateUpdated(_, let timestamp),
            .packetLost(_, let timestamp):
            return timestamp
        }
    }

    /// Builds the abstract Event class (time, name, data) described in the qlog main schema.
    func makeEvent(timestamp: NetworkDuration, data: [String: Any]) -> [String: Any] {
        // All timestamps and time-related values (e.g., offsets) in qlog are logged as
        // floats based in milliseconds, with a fractional part for finer detail.
        [
            "time": timestamp.qlogMilliseconds,
            "name": self.name(),
            "data": data,
        ]
    }

    func eventData() -> [String: Any] {
        switch self {
        case .packetReceived(let eventPacket, let timestamp),
            .packetSent(let eventPacket, let timestamp),
            .packetLost(let eventPacket, let timestamp):

            var dataContent: [String: Any] = [:]

            dataContent["header"] = eventPacket.packetHeader.dumpData()
            // packet_lost has no raw field in the draft.
            var isPacketLost = false
            if case .packetLost = self {
                isPacketLost = true
            }
            if !isPacketLost, let raw = eventPacket.packetHeader.rawInfo() {
                dataContent["raw"] = raw
            }

            dataContent["frames"] = eventPacket.frameList.dumpData()

            // An unknown trigger is not one of the draft's values, so it is omitted.
            switch eventPacket.trigger {
            case .sentReceivedTrigger(let trigger):
                if trigger != .unknown {
                    dataContent["trigger"] = trigger?.rawValue
                }
            case .lostTrigger(let trigger):
                dataContent["trigger"] = trigger?.rawValue
            }
            return makeEvent(timestamp: timestamp, data: dataContent)

        case .parametersSet(let event as any EventProtocol, let timestamp),
            .streamStateUpdated(let event as any EventProtocol, let timestamp),
            .metricsUpdated(let event as any EventProtocol, let timestamp),
            .congestionStateUpdated(let event as any EventProtocol, let timestamp):
            return makeEvent(timestamp: timestamp, data: event.dumpData())
        }
    }

    /// Event name in the form "<namespace>:<event_type>".
    func name() -> String {
        switch self {
        case .parametersSet:
            return "quic:parameters_set"
        case .packetSent:
            return "quic:packet_sent"
        case .packetReceived:
            return "quic:packet_received"
        case .streamStateUpdated:
            return "quic:stream_state_updated"
        case .metricsUpdated:
            return "quic:recovery_metrics_updated"
        case .congestionStateUpdated:
            return "quic:congestion_state_updated"
        case .packetLost:
            return "quic:packet_lost"
        }
    }
}

@available(Network 0.1.0, *)
struct EventFrame {
    var frame: QUICShorthandFrame
    // The ack_delay_exponent of the endpoint that sent the frame.
    var ackDelayExponent: Int
    init(frame: QUICShorthandFrame, ackDelayExponent: Int) {
        self.frame = frame
        self.ackDelayExponent = ackDelayExponent
    }

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        switch self.frame {
        case .padding(let frame):
            data["frame_type"] = "padding"
            // A negative length means the padding size is not known.
            if frame.length >= 0 {
                data["raw"] = ["payload_length": frame.length]
            }
        case .ping(_):
            data["frame_type"] = "ping"
        case .ack(let frame):
            data["frame_type"] = "ack"
            // RFC 9000 Section 19.3: the ACK Delay field is decoded by multiplying it by 2 to
            // the power of the sender's ack_delay_exponent.
            data["ack_delay"] = frame.delay << ackDelayExponent
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
            // Application error strings are defined by the application protocol.
            data["error"] = "unknown"
            data["error_code"] = frame.code
        case .stopSending(let frame):
            data["frame_type"] = "stop_sending"
            data["stream_id"] = frame.id
            data["error"] = "unknown"
            data["error_code"] = frame.code
        case .crypto(let frame):
            data["frame_type"] = "crypto"
            data["offset"] = frame.offset
            data["raw"] = ["length": frame.length]
        case .newToken(let frame):
            data["frame_type"] = "new_token"
            data["token"] = ["raw": ["length": frame.length]]
        case .stream(let frame):
            data["frame_type"] = "stream"
            data["offset"] = frame.offset
            data["stream_id"] = frame.id
            data["raw"] = ["length": frame.length]
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
            data["connection_id_length"] = frame.connectionID.length
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
            EventFrame.addTransportError(frame.errorCode, to: &data)
            data["trigger_frame_type"] = frame.frameType
            if !frame.reason.isEmpty {
                data["reason"] = frame.reason
            }
        case .applicationClose(let frame):
            data["frame_type"] = "connection_close"
            data["error_space"] = "application"
            // Application error strings are defined by the application protocol.
            data["error"] = "unknown"
            data["error_code"] = frame.errorCode
            if !frame.reason.isEmpty {
                data["reason"] = frame.reason
            }
        case .handshakeDone(_):
            data["frame_type"] = "handshake_done"
        case .datagram(let frame):
            data["frame_type"] = "datagram"
            data["raw"] = ["length": frame.length]
        }
        return data
    }

    // The TransportError strings from the QUIC events draft, indexed by RFC 9000 error code.
    private static let transportErrors = [
        "no_error", "internal_error", "connection_refused", "flow_control_error",
        "stream_limit_error", "stream_state_error", "final_size_error", "frame_encoding_error",
        "transport_parameter_error", "connection_id_limit_error", "protocol_violation",
        "invalid_token", "application_error", "crypto_buffer_exceeded", "key_update_error",
        "aead_limit_reached", "no_viable_path",
    ]

    private static func addTransportError(_ code: UInt64, to data: inout [String: Any]) {
        if code < UInt64(transportErrors.count) {
            data["error"] = transportErrors[Int(code)]
        } else if (0x100...0x1ff).contains(code) {
            // CryptoError is crypto_error_ followed by the QUIC error code in lowercase hex.
            data["error"] = "crypto_error_0x" + String(code, radix: 16)
        } else {
            data["error"] = "unknown"
            data["error_code"] = code
        }
    }
}

@available(Network 0.1.0, *)
struct EventFrames {
    var frames: [EventFrame] = []

    init() {}
    init(packet: borrowing Packet, ackDelayExponent: Int) {
        if let shorthandFrames = packet.shorthandFrames {
            for shorthandFrame in shorthandFrames {
                self.frames.append(.init(frame: shorthandFrame, ackDelayExponent: ackDelayExponent))
            }
        }
    }
    init(parsedPacket: borrowing PacketParser.ParsedPacket, ackDelayExponent: Int) {
        switch parsedPacket {
        case .protected(let packet):
            self.init(packet: packet, ackDelayExponent: ackDelayExponent)
        case .versionNegotiation:
            self.init()
        case .retry:
            self.init()
        case .failedDecryption:
            self.init()
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
        switch packet.keyState {
        case .initial:
            self = .initial
        case .handshake:
            self = .handshake
        case .earlyData:
            self = .zeroRTT
        case .phase0, .phase1:
            self = .oneRTT
        }
    }
}

@available(Network 0.1.0, *)
struct EventMetrics: EventProtocol {
    // nil when the event does not report the value.
    let minRTT: NetworkDuration?
    let smoothedRTT: NetworkDuration?
    let latestRTT: NetworkDuration?
    let rttVariance: NetworkDuration?
    let ptoCount: UInt64
    let congestionWindow: UInt64
    let bytesInFlight: UInt64
    let slowStartThresh: UInt64
    let packetsInFlight: UInt64
    let inRecovery: Bool?

    func dumpData() -> [String: Any] {
        var data: [String: Any] = [:]
        data["min_rtt"] = minRTT?.qlogMilliseconds
        data["smoothed_rtt"] = smoothedRTT?.qlogMilliseconds
        data["latest_rtt"] = latestRTT?.qlogMilliseconds
        data["rtt_variance"] = rttVariance?.qlogMilliseconds
        data["pto_count"] = QLog.wrapUInt64IfNotMax(ptoCount)
        data["congestion_window"] = QLog.wrapUInt64IfNotMax(congestionWindow)
        data["bytes_in_flight"] = QLog.wrapUInt64IfNotMax(bytesInFlight)
        data["ssthresh"] = QLog.wrapUInt64IfNotMax(slowStartThresh)
        data["packets_in_flight"] = QLog.wrapUInt64IfNotMax(packetsInFlight)
        data["in_recovery"] = inRecovery
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
    private static let fileSchema = "urn:ietf:params:qlog:file:contained"
    private static let serializationFormat = "application/qlog+json"
    // Holds the top-level fields other than file_schema and serialization_format,
    // which dumpData(forFlowType:) writes first.
    private var topLevelObject: [String: Any]
    private var disableTimestamps: Bool = false
    private let context: NetworkContext
    private let startTime: NetworkClock.Instant
    var configuration: QLogConfiguration?

    public init(configuration: QLogConfiguration? = nil, context: NetworkContext) {
        self.configuration = configuration
        self.context = context
        self.startTime = context.now
        self.eventsList = []
        self.topLevelObject = [:]
        if let title = configuration?.logTitle {
            self.topLevelObject["title"] = title
        }
        if let description = configuration?.logDescription {
            self.topLevelObject["description"] = description
        } else if let configurationObjectDescription = configuration?.description {
            self.topLevelObject["description"] = configurationObjectDescription
        }
    }

    static func wrapUInt64InStringIfNotMax(_ value: UInt64) -> String? {
        if value == UInt64.max {
            return nil
        }
        return String(value)
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

    func packetSent(_ packet: borrowing Packet, ackDelayExponent: Int, timestamp: NetworkClock.Instant) {
        let packetHeader = PacketHeader(packet: packet)
        let frameList = EventFrames(packet: packet, ackDelayExponent: ackDelayExponent)
        let packetEvent = EventPacket(
            packetHeader: packetHeader,
            frameList: frameList,
            trigger: .sentReceivedTrigger(.unknown)
        )
        let event = Event.packetSent(packetEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    func packetReceived(
        _ parsedPacket: borrowing PacketParser.ParsedPacket,
        // The draft has no coalescing flag; coalesced packets are matched through datagram checksums.
        coalesced _: Bool,
        ackDelayExponent: Int,
        timestamp: NetworkClock.Instant
    ) {
        // Packets that failed decryption are not logged as received.
        guard let packetHeader = PacketHeader(parsedPacket: parsedPacket) else {
            return
        }
        let packetEvent = EventPacket(
            packetHeader: packetHeader,
            frameList: EventFrames(parsedPacket: parsedPacket, ackDelayExponent: ackDelayExponent),
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
            packetHeader: PacketHeader(packet: packet),
            frameList: .init(),
            trigger: .lostTrigger(trigger)
        )
        let event = Event.packetLost(packetEvent, timestamp: calculateTimestamp(timestamp))
        eventsList.append(event)
    }

    func metricsUpdated(
        minRTT: NetworkDuration?,
        smoothedRTT: NetworkDuration?,
        latestRTT: NetworkDuration?,
        rttVariance: NetworkDuration?,
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
            minRTT: nil,
            smoothedRTT: nil,
            latestRTT: nil,
            rttVariance: nil,
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
        timestamp: NetworkClock.Instant? = nil
    ) {
        let timestamp = timestamp ?? context.now
        metricsUpdated(
            minRTT: nil,
            smoothedRTT: nil,
            latestRTT: nil,
            rttVariance: nil,
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
        stream: borrowing QUICStreamInstance,
        oldStreamState: QLogStreamState,
        newStreamState: QLogStreamState,
        streamSide: QLogStreamSide,
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
        timestamp: NetworkClock.Instant? = nil
    ) {
        let timestamp = timestamp ?? context.now
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

    public func parametersSet(
        owner: QLogOwner,
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
        maxAckDelay: NetworkDuration?,
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
        owner: QLogOwner,
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
            maxAckDelay: transportParameters[TransportParameterTypes.maxAckDelay]?.duration,
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
        // The vantage point type is required and the draft allows "unknown".
        var vantagePointObject: [String: Any] = ["type": flowType?.rawValue ?? "unknown"]
        if let name = configuration?.vantagePointName {
            vantagePointObject["name"] = name
        }

        var traceObject: [String: Any] = ["vantage_point": vantagePointObject]
        // Trace title is optional
        if let title = configuration?.logTitle {
            traceObject["title"] = "Trace of \(title)"
        }
        let implementation: [String: Any] = [
            "name": "SwiftQUIC"
        ]
        traceObject["implementation"] = implementation
        // Using draft-14 event schema
        traceObject["event_schemas"] = ["urn:ietf:params:qlog:events:quic-14"]
        // Event times are measured from the log's start on a monotonic clock
        traceObject["common_fields"] = [
            "reference_time": ["clock_type": "monotonic", "epoch": "unknown"]
        ]

        // 8.1 - Events in each individual trace SHOULD be logged in time order,
        let sortedEvents = eventsList.enumerated().sorted {
            ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset)
        }.map(\.element)
        var eventsArray: [[String: Any]] = []
        for event in sortedEvents {
            eventsArray.append(event.eventData())
        }
        eventsList.removeAll()

        traceObject["events"] = eventsArray

        let traceList = [traceObject]
        topLevelObject["traces"] = traceList
        if let jsonData = try? JSONSerialization.data(withJSONObject: topLevelObject) {
            // 3.0 - In order to make it easier to parse and identify qlog files and their serialization format,
            // the file_schema and serialization_format fields and their values SHOULD be in the first 256 bytes
            // of the resulting log file..
            let header = Data(
                #"{"file_schema":"\#(QLog.fileSchema)","serialization_format":"\#(QLog.serializationFormat)","#.utf8
            )
            return header + jsonData.dropFirst()
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
