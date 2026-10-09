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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum TransportParameterTypes: UInt64, CaseIterable {
    case originalDCID = 0
    case maxIdleTimeout = 1
    case statelessResetToken = 2
    case maxUDPPayloadSize = 3
    case initialMaxData = 4
    case initialMaxStreamDataBidirectionalLocal = 5
    case initialMaxStreamDataBidirectionalRemote = 6
    case initialMaxStreamDataUnidirectional = 7
    case initialMaxStreamsBidirectional = 8
    case initialMaxStreamsUnidirectional = 9
    case ackDelayExponent = 10
    case maxAckDelay = 11
    case disableActiveMigration = 12
    case preferredAddress = 13
    case activeConnectionIDLimit = 14
    case initialSCID = 15
    case retrySCID = 16

    case maxDatagramFrameSize = 32
    case minAckDelay = 0xff03_de1a

    /* Apple Private Relay custom TP. */
    case migrationVersion = 0xff08_0808

    /// The index used by `TransportParameters` underlying storage.
    var index: Int {
        switch self.rawValue {
        case 0...16:
            return Int(self.rawValue)
        case Self.maxDatagramFrameSize.rawValue:
            return 17
        case Self.minAckDelay.rawValue:
            return 18
        case Self.migrationVersion.rawValue:
            return 19
        default:
            fatalError("Missing case")
        }
    }
}

enum TransportParameterDecodeErrors: Int, Error {
    case invalidSize
    case outOfBounds
    case unknownType
}

enum TransportParameterEncodeErrors: Int, Error {
    case invalidValue
}

@available(Network 0.1.0, *)
enum TransportParameter: Equatable {
    case originalDCID(
        _ type: TransportParameterTypes = .originalDCID,
        connectionID: QUICConnectionID
    )
    case maxIdleTimeout(_ type: TransportParameterTypes = .maxIdleTimeout, value: UInt64)
    case statelessResetToken(
        _ type: TransportParameterTypes = .statelessResetToken,
        statelessResetToken: QUICStatelessResetToken
    )
    case maxUDPPayloadSize(_ type: TransportParameterTypes = .maxUDPPayloadSize, value: UInt64)
    case initialMaxData(_ type: TransportParameterTypes = .initialMaxData, value: UInt64)
    case initialMaxStreamDataBidirectionalLocal(
        _ type: TransportParameterTypes = .initialMaxStreamDataBidirectionalLocal,
        value: UInt64
    )
    case initialMaxStreamDataBidirectionalRemote(
        _ type: TransportParameterTypes = .initialMaxStreamDataBidirectionalRemote,
        value: UInt64
    )
    case initialMaxStreamDataUnidirectional(
        _ type: TransportParameterTypes = .initialMaxStreamDataUnidirectional,
        value: UInt64
    )
    case initialMaxStreamsBidirectional(
        _ type: TransportParameterTypes = .initialMaxStreamsBidirectional,
        value: UInt64
    )
    case initialMaxStreamsUnidirectional(
        _ type: TransportParameterTypes = .initialMaxStreamsUnidirectional,
        value: UInt64
    )
    case ackDelayExponent(_ type: TransportParameterTypes = .ackDelayExponent, value: UInt64)
    case maxAckDelay(_ type: TransportParameterTypes = .maxAckDelay, duration: NetworkDuration)
    case disableActiveMigration(_ type: TransportParameterTypes = .disableActiveMigration)
    case preferredAddress(
        _ type: TransportParameterTypes = .preferredAddress,
        preferredAddress: PreferredAddress
    )
    case activeConnectionIDLimit(
        _ type: TransportParameterTypes = .activeConnectionIDLimit,
        value: UInt64
    )
    case initialSCID(_ type: TransportParameterTypes = .initialSCID, connectionID: QUICConnectionID)
    case retrySCID(_ type: TransportParameterTypes = .retrySCID, connectionID: QUICConnectionID)
    case maxDatagramFrameSize(
        _ type: TransportParameterTypes = .maxDatagramFrameSize,
        value: UInt64
    )
    case minAckDelay(_ type: TransportParameterTypes = .minAckDelay, duration: NetworkDuration)
    case migrationVersion(_ type: TransportParameterTypes = .migrationVersion, value: UInt64)

    var serializeForEarlyData: Bool {
        switch self {
        case .ackDelayExponent, .maxAckDelay, .initialSCID, .originalDCID, .preferredAddress,
            .retrySCID, .statelessResetToken, .minAckDelay:
            return false
        default:
            return true
        }
    }

    static func defaultValue(forType: TransportParameterTypes) -> Int? {
        switch forType {
        case .maxUDPPayloadSize:
            return TransportParameters.maxUDPPayloadSize
        case .ackDelayExponent:
            return Ack.defaultDelayExponent
        case .maxAckDelay:
            return Int(Ack.defaultMaxDelay.milliseconds)
        case .maxIdleTimeout,
            .initialMaxData,
            .initialMaxStreamDataBidirectionalLocal,
            .initialMaxStreamDataBidirectionalRemote,
            .initialMaxStreamDataUnidirectional,
            .initialMaxStreamsBidirectional,
            .initialMaxStreamsUnidirectional,
            .maxDatagramFrameSize,
            .minAckDelay,
            .migrationVersion:
            return Int(0)
        case .activeConnectionIDLimit:
            return Int(2)
        case .originalDCID, .initialSCID, .retrySCID, .statelessResetToken,
            .preferredAddress, .disableActiveMigration:
            return nil
        }
    }

    var usingDefaultValue: Bool {
        guard let defaultValue = TransportParameter.defaultValue(forType: self.type) else {
            return false
        }
        // Duration parameters are compared in their wire unit.
        switch self {
        case .maxAckDelay(_, let duration):
            return duration.milliseconds == defaultValue
        case .minAckDelay(_, let duration):
            return duration.microseconds == defaultValue
        default:
            return value == defaultValue
        }
    }

    var type: TransportParameterTypes {
        switch self {
        case .disableActiveMigration:
            return .disableActiveMigration
        case .originalDCID(let type, _),
            .maxIdleTimeout(let type, _),
            .statelessResetToken(let type, _),
            .maxUDPPayloadSize(let type, _),
            .initialMaxData(let type, _),
            .initialMaxStreamDataBidirectionalLocal(let type, _),
            .initialMaxStreamDataBidirectionalRemote(let type, _),
            .initialMaxStreamDataUnidirectional(let type, _),
            .initialMaxStreamsBidirectional(let type, _),
            .initialMaxStreamsUnidirectional(let type, _),
            .ackDelayExponent(let type, _),
            .maxAckDelay(let type, _),
            .preferredAddress(let type, _),
            .activeConnectionIDLimit(let type, _),
            .initialSCID(let type, _),
            .retrySCID(let type, _),
            .maxDatagramFrameSize(let type, _),
            .minAckDelay(let type, _),
            .migrationVersion(let type, _):
            return type
        }
    }

    var value: Int {
        switch self {
        case .originalDCID, .statelessResetToken, .preferredAddress, .disableActiveMigration,
            .initialSCID, .retrySCID, .maxAckDelay, .minAckDelay:
            fatalError("invalid function call")
        case .maxIdleTimeout(_, let value),
            .maxUDPPayloadSize(_, let value),
            .initialMaxData(_, let value),
            .initialMaxStreamDataBidirectionalLocal(_, let value),
            .initialMaxStreamDataBidirectionalRemote(_, let value),
            .initialMaxStreamDataUnidirectional(_, let value),
            .initialMaxStreamsBidirectional(_, let value),
            .initialMaxStreamsUnidirectional(_, let value),
            .ackDelayExponent(_, let value),
            .activeConnectionIDLimit(_, let value),
            .maxDatagramFrameSize(_, let value),
            .migrationVersion(_, let value):
            return Int(value)
        }
    }

    var duration: NetworkDuration {
        switch self {
        case .maxAckDelay(_, let duration),
            .minAckDelay(_, let duration):
            return duration
        default:
            fatalError("invalid function call")
        }
    }

    var connectionID: QUICConnectionID {
        switch self {
        case .originalDCID(_, let connectionID), .initialSCID(_, let connectionID),
            .retrySCID(_, let connectionID):
            return connectionID
        default:
            fatalError("invalid function call")
        }
    }

    var statelessResetToken: QUICStatelessResetToken {
        switch self {
        case .statelessResetToken(_, let statelessResetToken):
            return statelessResetToken
        default:
            fatalError("invalid function call")
        }
    }

    var preferredAddress: PreferredAddress {
        switch self {
        case .preferredAddress(_, let preferredAddress):
            return preferredAddress
        default:
            fatalError("invalid function call")
        }
    }

    func logParameter(_ logPrefixer: borrowing LogPrefixer) {
        switch self {
        case .originalDCID(let type, let connectionID), .initialSCID(let type, let connectionID),
            .retrySCID(let type, let connectionID):
            logPrefixer.debug("\(type)=\(connectionID)")
        case .disableActiveMigration(let type):
            logPrefixer.debug("\(type)")
        case .statelessResetToken(let type, let statelessResetToken):
            logPrefixer.debug("\(type)=\(statelessResetToken)")
        case .preferredAddress(let type, let preferredAddress):
            logPrefixer.debug("\(type)=\(preferredAddress)")
        case .maxIdleTimeout(let type, let value),
            .maxUDPPayloadSize(let type, let value),
            .initialMaxData(let type, let value),
            .initialMaxStreamDataBidirectionalLocal(let type, let value),
            .initialMaxStreamDataBidirectionalRemote(let type, let value),
            .initialMaxStreamDataUnidirectional(let type, let value),
            .initialMaxStreamsBidirectional(let type, let value),
            .initialMaxStreamsUnidirectional(let type, let value),
            .ackDelayExponent(let type, let value),
            .activeConnectionIDLimit(let type, let value),
            .maxDatagramFrameSize(let type, let value),
            .migrationVersion(let type, let value):
            logPrefixer.debug("\(type)=\(value)")
        case .maxAckDelay(let type, let duration),
            .minAckDelay(let type, let duration):
            logPrefixer.debug("\(type)=\(duration)")
        }
    }

    func serialize(_ buffer: inout [UInt8], logPrefixer: borrowing LogPrefixer) throws(QUICError) {
        if self.usingDefaultValue {
            return
        }
        switch self {
        case .originalDCID(let type, let connectionID), .initialSCID(let type, let connectionID),
            .retrySCID(let type, let connectionID):
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(connectionID.length)
                    write.buffer(connectionID.connectionID)
                }
            )
        case .disableActiveMigration(let type):
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(0)
                }
            )
        case .statelessResetToken(let type, let statelessResetToken):
            if statelessResetToken.token.count != QUICStatelessResetToken.size {
                throw QUICError.transportParametersEncode(
                    TransportParameterEncodeErrors.invalidValue
                )
            }
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(QUICStatelessResetToken.size)
                    write.buffer(statelessResetToken.token)
                }
            )
        case .preferredAddress(let type, let preferredAddress):
            if preferredAddress.ipv6Address.count != 16 {
                throw QUICError.transportParametersEncode(
                    TransportParameterEncodeErrors.invalidValue
                )
            }
            if preferredAddress.statelessResetToken.token.count != QUICStatelessResetToken.size {
                throw QUICError.transportParametersEncode(
                    TransportParameterEncodeErrors.invalidValue
                )
            }
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(preferredAddress.length)
                    write.uint32NetworkByteOrder(preferredAddress.ipv4Address)
                    write.uint16NetworkByteOrder(UInt16(preferredAddress.ipv4Port))
                    write.buffer(preferredAddress.ipv6Address)
                    write.uint16NetworkByteOrder(UInt16(preferredAddress.ipv6Port))
                    write.uint8(UInt8(preferredAddress.connectionID.length))
                    write.buffer(preferredAddress.connectionID.connectionID)
                    write.buffer(preferredAddress.statelessResetToken.token)
                }
            )
        case .maxIdleTimeout(let type, let value),
            .maxUDPPayloadSize(let type, let value),
            .initialMaxData(let type, let value),
            .initialMaxStreamDataBidirectionalLocal(let type, let value),
            .initialMaxStreamDataBidirectionalRemote(let type, let value),
            .initialMaxStreamDataUnidirectional(let type, let value),
            .initialMaxStreamsBidirectional(let type, let value),
            .initialMaxStreamsUnidirectional(let type, let value),
            .ackDelayExponent(let type, let value),
            .activeConnectionIDLimit(let type, let value),
            .maxDatagramFrameSize(let type, let value),
            .migrationVersion(let type, let value):
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(value.variableLengthSize)
                    write.vle(value)
                }
            )
        // N.B.: maxAckDelay is serialized in *milliseconds*.
        case .maxAckDelay(let type, let duration):
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(duration.milliseconds.variableLengthSize)
                    write.vle(duration.milliseconds)
                }
            )
        // N.B.: minAckDelay is serialized in *microseconds*.
        case .minAckDelay(let type, let duration):
            buffer.append(
                contentsOf: Serializer.serialize { write in
                    write.vle(type.rawValue)
                    write.vle(duration.microseconds.variableLengthSize)
                    write.vle(duration.microseconds)
                }
            )
        }
        self.logParameter(logPrefixer)
    }

    private static func deserializeUInt64(_ buffer: [UInt8]) throws(QUICError) -> UInt64 {
        var value: UInt64 = 0
        var vleSize = 0
        let result = Deserializer.deserialize(buffer.span) { read throws(DeserializationError) in
            try read.vleWithSize(&value, &vleSize)
        }
        guard case .success = result else {
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        guard vleSize == buffer.count else {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("VLE size \(vleSize) doesn't match TP size \(bufferCount)")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return value
    }

    private static func deserializeUInt64(_ buffer: Span<UInt8>) throws(QUICError) -> UInt64 {
        var value: UInt64 = 0
        var vleSize = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vleWithSize(&value, &vleSize)
        }
        guard case .success = result else {
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        guard vleSize == buffer.count else {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("VLE size \(vleSize) doesn't match TP size \(bufferCount)")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return value
    }

    // max_ack_delay is encoded in milliseconds. The raw value is peer-controlled, so it is
    // range-checked before conversion: a large value would overflow NetworkDuration.
    private static func deserializeMaxAckDelay(_ buffer: Span<UInt8>) throws(QUICError) -> NetworkDuration {
        let milliseconds = try deserializeUInt64(buffer)
        guard milliseconds <= UInt64(Ack.maxDelay.milliseconds) else {
            #if !DisableErrorLogging
            Logger.proto.error("max_ack_delay \(milliseconds) ms is greater than \(Ack.maxDelay)")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.outOfBounds)
        }
        return .milliseconds(milliseconds)
    }

    // min_ack_delay is encoded in microseconds. It must not exceed max_ack_delay, so anything
    // above the largest valid max_ack_delay is rejected before conversion.
    private static func deserializeMinAckDelay(_ buffer: Span<UInt8>) throws(QUICError) -> NetworkDuration {
        let microseconds = try deserializeUInt64(buffer)
        guard microseconds <= UInt64(Ack.maxDelay.microseconds) else {
            #if !DisableErrorLogging
            Logger.proto.error("min_ack_delay \(microseconds) us is greater than \(Ack.maxDelay)")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.outOfBounds)
        }
        return .microseconds(microseconds)
    }

    private static func deserializeConnectionID(
        _ buffer: [UInt8]
    ) throws(QUICError) -> QUICConnectionID {
        guard buffer.count <= QUICConnectionID.maximumSize,
            let connectionID = QUICConnectionID(buffer)
        else {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("ConnectionID size \(bufferCount) is invalid")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return connectionID
    }

    private static func deserializeConnectionID(
        _ buffer: Span<UInt8>
    ) throws(QUICError) -> QUICConnectionID {
        guard buffer.count <= QUICConnectionID.maximumSize,
            let connectionID = QUICConnectionID(buffer)
        else {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("ConnectionID size \(bufferCount) is invalid")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return connectionID
    }

    private static func deserializeStatelessResetToken(
        _ buffer: [UInt8]
    ) throws(QUICError) -> QUICStatelessResetToken {
        guard let statelessResetToken = QUICStatelessResetToken(buffer) else {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("StatelessResetToken size \(bufferCount) is invalid")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return statelessResetToken
    }

    private static func deserializeStatelessResetToken(
        _ buffer: Span<UInt8>
    ) throws(QUICError) -> QUICStatelessResetToken {
        guard let statelessResetToken = QUICStatelessResetToken(buffer) else {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("StatelessResetToken size \(bufferCount) is invalid")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return statelessResetToken
    }

    private static func deserializePreferredAddress(
        _ buffer: [UInt8]
    ) throws(QUICError) -> PreferredAddress {
        if buffer.count < PreferredAddress.minimumSize
            || buffer.count > PreferredAddress.maximumSize
        {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("PreferredAddress size \(bufferCount) is invalid")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        var ipv4Address: UInt32 = 0
        var ipv4Port: UInt16 = 0
        var ipv6Address = [UInt8]()
        var ipv6Port: UInt16 = 0
        var cidLength: UInt8 = 0
        var connectionIDStorage = QUICConnectionIDStorage.empty
        var statelessResetToken = [UInt8]()

        let result = Deserializer.deserialize(buffer.span) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(&ipv4Address)
            try read.uint16NetworkByteOrder(&ipv4Port)
            try read.buffer(&ipv6Address, length: 16)
            try read.uint16NetworkByteOrder(&ipv6Port)
            try read.uint8(&cidLength)
            try read.connectionID(&connectionIDStorage, length: Int(cidLength))
            try read.buffer(&statelessResetToken, length: QUICStatelessResetToken.size)
        }
        let connectionID = QUICConnectionID(storage: connectionIDStorage, size: Int(cidLength))
        guard case .success = result,
            let statelessResetToken = QUICStatelessResetToken(statelessResetToken)
        else {
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return PreferredAddress(
            connectionID: connectionID,
            statelessResetToken: statelessResetToken,
            ipv4Port: Int(ipv4Port),
            ipv4Address: ipv4Address,
            ipv6Port: Int(ipv6Port),
            ipv6Address: ipv6Address
        )
    }

    private static func deserializePreferredAddress(
        _ buffer: Span<UInt8>
    ) throws(QUICError) -> PreferredAddress {
        if buffer.count < PreferredAddress.minimumSize
            || buffer.count > PreferredAddress.maximumSize
        {
            let bufferCount = buffer.count
            #if !DisableErrorLogging
            Logger.proto.error("PreferredAddress size \(bufferCount) is invalid")
            #endif
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        var ipv4Address: UInt32 = 0
        var ipv4Port: UInt16 = 0
        var ipv6Address = [UInt8]()
        var ipv6Port: UInt16 = 0
        var cidLength: UInt8 = 0
        var connectionIDStorage = QUICConnectionIDStorage.empty
        var statelessResetToken = [UInt8]()

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(&ipv4Address)
            try read.uint16NetworkByteOrder(&ipv4Port)
            try read.buffer(&ipv6Address, length: 16)
            try read.uint16NetworkByteOrder(&ipv6Port)
            try read.uint8(&cidLength)
            try read.connectionID(&connectionIDStorage, length: Int(cidLength))
            try read.buffer(&statelessResetToken, length: QUICStatelessResetToken.size)
        }
        let connectionID = QUICConnectionID(storage: connectionIDStorage, size: Int(cidLength))
        guard case .success = result,
            let statelessResetToken = QUICStatelessResetToken(statelessResetToken)
        else {
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        return PreferredAddress(
            connectionID: connectionID,
            statelessResetToken: statelessResetToken,
            ipv4Port: Int(ipv4Port),
            ipv4Address: ipv4Address,
            ipv6Port: Int(ipv6Port),
            ipv6Address: ipv6Address
        )
    }

    static func deserialize(
        rawType: UInt64,
        buffer: [UInt8],
        logPrefixer: borrowing LogPrefixer
    ) throws(QUICError) -> TransportParameter {
        guard let type = TransportParameterTypes(rawValue: rawType) else {
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.unknownType)
        }
        let parameter: TransportParameter
        switch type {
        case .originalDCID:
            parameter = try .originalDCID(connectionID: deserializeConnectionID(buffer))
        case .maxIdleTimeout:
            parameter = try .maxIdleTimeout(value: deserializeUInt64(buffer))
        case .statelessResetToken:
            parameter = try .statelessResetToken(
                statelessResetToken: deserializeStatelessResetToken(buffer)
            )
        case .maxUDPPayloadSize:
            parameter = try .maxUDPPayloadSize(value: deserializeUInt64(buffer))
        case .initialMaxData:
            parameter = try .initialMaxData(value: deserializeUInt64(buffer))
        case .initialMaxStreamDataBidirectionalLocal:
            parameter = try .initialMaxStreamDataBidirectionalLocal(
                value: deserializeUInt64(buffer)
            )
        case .initialMaxStreamDataBidirectionalRemote:
            parameter = try .initialMaxStreamDataBidirectionalRemote(
                value: deserializeUInt64(buffer)
            )
        case .initialMaxStreamDataUnidirectional:
            parameter = try .initialMaxStreamDataUnidirectional(value: deserializeUInt64(buffer))
        case .initialMaxStreamsBidirectional:
            parameter = try .initialMaxStreamsBidirectional(value: deserializeUInt64(buffer))
        case .initialMaxStreamsUnidirectional:
            parameter = try .initialMaxStreamsUnidirectional(value: deserializeUInt64(buffer))
        case .ackDelayExponent:
            parameter = try .ackDelayExponent(value: deserializeUInt64(buffer))
        case .maxAckDelay:
            parameter = try .maxAckDelay(duration: deserializeMaxAckDelay(buffer.span))
        case .disableActiveMigration:
            parameter = .disableActiveMigration()
        case .preferredAddress:
            parameter = try .preferredAddress(preferredAddress: deserializePreferredAddress(buffer))
        case .activeConnectionIDLimit:
            parameter = try .activeConnectionIDLimit(value: deserializeUInt64(buffer))
        case .initialSCID:
            parameter = try .initialSCID(connectionID: deserializeConnectionID(buffer))
        case .retrySCID:
            parameter = try .retrySCID(connectionID: deserializeConnectionID(buffer))
        case .maxDatagramFrameSize:
            parameter = try .maxDatagramFrameSize(value: deserializeUInt64(buffer))
        case .minAckDelay:
            parameter = try .minAckDelay(duration: deserializeMinAckDelay(buffer.span))
        case .migrationVersion:
            parameter = try .migrationVersion(value: deserializeUInt64(buffer))
        }
        parameter.logParameter(logPrefixer)
        return parameter
    }

    static func deserialize(
        rawType: UInt64,
        buffer: Span<UInt8>,
        logPrefixer: borrowing LogPrefixer
    ) throws(QUICError) -> TransportParameter {
        guard let type = TransportParameterTypes(rawValue: rawType) else {
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.unknownType)
        }
        let parameter: TransportParameter
        switch type {
        case .originalDCID:
            parameter = try .originalDCID(connectionID: deserializeConnectionID(buffer))
        case .maxIdleTimeout:
            parameter = try .maxIdleTimeout(value: deserializeUInt64(buffer))
        case .statelessResetToken:
            parameter = try .statelessResetToken(
                statelessResetToken: deserializeStatelessResetToken(buffer)
            )
        case .maxUDPPayloadSize:
            parameter = try .maxUDPPayloadSize(value: deserializeUInt64(buffer))
        case .initialMaxData:
            parameter = try .initialMaxData(value: deserializeUInt64(buffer))
        case .initialMaxStreamDataBidirectionalLocal:
            parameter = try .initialMaxStreamDataBidirectionalLocal(
                value: deserializeUInt64(buffer)
            )
        case .initialMaxStreamDataBidirectionalRemote:
            parameter = try .initialMaxStreamDataBidirectionalRemote(
                value: deserializeUInt64(buffer)
            )
        case .initialMaxStreamDataUnidirectional:
            parameter = try .initialMaxStreamDataUnidirectional(value: deserializeUInt64(buffer))
        case .initialMaxStreamsBidirectional:
            parameter = try .initialMaxStreamsBidirectional(value: deserializeUInt64(buffer))
        case .initialMaxStreamsUnidirectional:
            parameter = try .initialMaxStreamsUnidirectional(value: deserializeUInt64(buffer))
        case .ackDelayExponent:
            parameter = try .ackDelayExponent(value: deserializeUInt64(buffer))
        case .maxAckDelay:
            parameter = try .maxAckDelay(duration: deserializeMaxAckDelay(buffer))
        case .disableActiveMigration:
            parameter = .disableActiveMigration()
        case .preferredAddress:
            parameter = try .preferredAddress(preferredAddress: deserializePreferredAddress(buffer))
        case .activeConnectionIDLimit:
            parameter = try .activeConnectionIDLimit(value: deserializeUInt64(buffer))
        case .initialSCID:
            parameter = try .initialSCID(connectionID: deserializeConnectionID(buffer))
        case .retrySCID:
            parameter = try .retrySCID(connectionID: deserializeConnectionID(buffer))
        case .maxDatagramFrameSize:
            parameter = try .maxDatagramFrameSize(value: deserializeUInt64(buffer))
        case .minAckDelay:
            parameter = try .minAckDelay(duration: deserializeMinAckDelay(buffer))
        case .migrationVersion:
            parameter = try .migrationVersion(value: deserializeUInt64(buffer))
        }
        parameter.logParameter(logPrefixer)
        return parameter
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.type != rhs.type {
            return false
        }
        switch lhs {
        case .disableActiveMigration:
            return lhs.type == rhs.type
        case .statelessResetToken:
            return lhs.statelessResetToken == rhs.statelessResetToken
        case .originalDCID, .retrySCID, .initialSCID:
            return lhs.connectionID == rhs.connectionID
        case .preferredAddress:
            return lhs.preferredAddress == rhs.preferredAddress
        case .maxIdleTimeout, .maxUDPPayloadSize, .initialMaxData,
            .initialMaxStreamDataBidirectionalLocal,
            .initialMaxStreamDataBidirectionalRemote, .initialMaxStreamDataUnidirectional,
            .initialMaxStreamsBidirectional,
            .initialMaxStreamsUnidirectional,
            .ackDelayExponent,
            .activeConnectionIDLimit,
            .maxDatagramFrameSize,
            .migrationVersion:
            return lhs.value == rhs.value
        case .maxAckDelay, .minAckDelay:
            return lhs.duration == rhs.duration
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct TransportParameters: PrefixedLoggable {
    var log: LogPrefixer
    public static let minUDPPayloadSize = 1200
    // N.B.: this isn't a realistic packet size but it's the maximum value
    // the transport parameter can have.
    public static let maxUDPPayloadSize = 65527
    public static let maxDatagramFrameSize: UInt64 = 65535
    private var parameters: [TransportParameter?]

    init(logPrefixer: LogPrefixer = .init()) {
        self.log = logPrefixer
        self.parameters = Array(
            repeating: nil,
            count: TransportParameterTypes.allCases.count
        )
    }

    subscript(_ type: TransportParameterTypes) -> TransportParameter? {
        self.parameters[type.index]
    }

    mutating func append(_ parameter: TransportParameter) {
        self.parameters[parameter.type.index] = parameter
    }

    mutating func remove(_ parameter: TransportParameter) {
        self.remove(parameter.type)
    }

    mutating func remove(_ type: TransportParameterTypes) {
        self.parameters[type.index] = nil
    }

    mutating func removeAll() {
        for index in self.parameters.indices {
            self.parameters[index] = nil
        }
    }

    func serialize(
        forEarlyData: Bool = false
    ) throws(QUICError) -> [UInt8] {
        var buffer = [UInt8]()
        // N.B.: we shuffle the parameters to randomize the order in which they are serialized.
        for parameter in parameters.lazy.compactMap({ $0 }).shuffled() {
            if forEarlyData && !parameter.serializeForEarlyData {
                continue
            }
            try parameter.serialize(&buffer, logPrefixer: self.log)
        }
        log.debug("Serialized size: \(buffer.count)")
        return buffer
    }

    static func deserialize(
        _ buffer: Span<UInt8>,
        logPrefixer: LogPrefixer
    ) throws(QUICError) -> TransportParameters {
        var parameters = TransportParameters(logPrefixer: logPrefixer)
        guard buffer.count >= 0 && buffer.count < UInt16.max else {
            parameters.log.error("Invalid TP size \(buffer.count)")
            throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.invalidSize)
        }
        parameters.log.debug("Deserializing transport parameters (size \(buffer.count))")

        var maxAckDelay: NetworkDuration? = nil
        var minAckDelay: NetworkDuration? = nil
        var buffer = buffer
        while !buffer.isEmpty {
            var rawType: UInt64 = 0
            var parameterLength = 0
            let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
                try read.vle(&rawType)
                try read.vle(&parameterLength)
            }

            switch result {
            case .error:
                throw QUICError.transportParametersDecode(
                    TransportParameterDecodeErrors.invalidSize
                )
            case .success(_, let remainingBytes):
                if remainingBytes > 0 {
                    // Removes the values we just parsed: rawType and parameterLength.
                    buffer = buffer.extracting((buffer.count - remainingBytes)...)
                } else {
                    buffer = Span()
                }
            }
            guard buffer.count >= parameterLength && parameterLength < UInt16.max else {
                parameters.log.error("Invalid length \(parameterLength)")
                throw QUICError.transportParametersDecode(
                    TransportParameterDecodeErrors.invalidSize
                )
            }
            let parameter: TransportParameter
            let parameterBuffer = buffer.extracting(0..<parameterLength)
            buffer = buffer.extracting(parameterLength...)
            do {
                parameter = try TransportParameter.deserialize(
                    rawType: rawType,
                    buffer: parameterBuffer,
                    logPrefixer: logPrefixer
                )
            } catch QUICError.transportParametersDecode(TransportParameterDecodeErrors.unknownType) {
                parameters.log.debug("<unknown type \(rawType)> <len \(parameterLength)>")
                continue
            }

            if case .maxUDPPayloadSize(_, let value) = parameter,
                value < TransportParameters.minUDPPayloadSize
                    || value > TransportParameters.maxUDPPayloadSize
            {
                parameters.log.error("max_udp_payload_size is out of bounds")
                throw QUICError.transportParametersDecode(
                    TransportParameterDecodeErrors.outOfBounds
                )
            }

            if case .ackDelayExponent(_, let value) = parameter, value > Ack.maxDelayExponent {
                parameters.log.error("ack_delay_exponent is greater than \(Ack.maxDelayExponent)")
                throw
                    QUICError
                    .transportParametersDecode(TransportParameterDecodeErrors.outOfBounds)
            }

            // N.B.: the 2^14 ms bound on max_ack_delay is enforced while parsing.
            if case .maxAckDelay(_, let duration) = parameter {
                maxAckDelay = duration
            }
            if case .minAckDelay(_, let duration) = parameter {
                minAckDelay = duration
            }
            parameters.append(parameter)
        }
        // minAckDelay must not be greater than maxAckDelay.
        // If maxAckDelay wasn't sent, we use the default.
        if let minAckDelay = minAckDelay {
            let maxAckDelay = maxAckDelay ?? Ack.defaultMaxDelay
            if minAckDelay > maxAckDelay {
                parameters.log.error(
                    "min_ack_delay \(minAckDelay) is GREATER than max_ack_delay \(maxAckDelay)"
                )
                throw QUICError.transportParametersDecode(TransportParameterDecodeErrors.outOfBounds)
            }
        }
        return parameters
    }

    // Return the integer value for the specified TransportParameter type
    // If the specified type does not have an integer value, the function will fail and error out
    func intValue(_ forType: TransportParameterTypes) -> Int {
        guard let transportParameter = self[forType] else {
            guard let defaultValue = TransportParameter.defaultValue(forType: forType) else {
                fatalError("Parameter not set and no default value provided")
            }
            return defaultValue
        }
        return transportParameter.value
    }
}
#endif
