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
public struct QUICTransportError: NetworkDomainSpecificError {
    public static var domain: NetworkError.Domain { .init(rawValue: "QUICTransportError") }

    public enum QUICTransportErrorCode: Int64, Sendable {
        case noError = 0x0000
        case internalError = 0x0001
        case serverBusy = 0x0002
        case flowControlError = 0x0003
        case streamLimitError = 0x0004
        case streamStateError = 0x0005
        case finalSizeError = 0x0006
        case frameEncodingError = 0x0007
        case transportParameterError = 0x0008
        case connectionIDLimitError = 0x0009
        case protocolViolation = 0x000A
        case invalidToken = 0x000B
        case applicationError = 0x000C
        case cryptoBufferExceeded = 0x000D
        case keyUpdateError = 0x000E
        case aeadLimitReached = 0x000F
        case noViablePath = 0x0010
    }

    static func codeIsValidCryptoCode(_ code: Int64) -> Bool {
        code >= 0x0000 && code <= 0x00FF
    }

    static func transportErrorCodeIsCryptoError(_ code: Int64) -> Bool {
        code >= 0x0100 && code <= 0x01FF
    }

    enum QUICTransportErrorCodeInner {
        case transport(QUICTransportErrorCode)
        case crypto(Int64)

        var code: Int64 {
            switch self {
            case .transport(let code): code.rawValue
            case .crypto(let code): code + 0x0100
            }
        }
    }

    let errorCode: QUICTransportErrorCodeInner
    public let reason: String?

    public var code: Int64 {
        errorCode.code
    }

    init(_ code: QUICTransportErrorCodeInner, _ reason: String? = nil) {
        let reasonString: String?
        if let reason, !reason.isEmpty {
            reasonString = reason
        } else {
            reasonString = nil
        }
        self.errorCode = code
        self.reason = reasonString
    }

    init(_ code: QUICTransportErrorCode, _ reason: String? = nil) {
        self.init(QUICTransportErrorCodeInner.transport(code), reason)
    }

    init?(cryptoError: Int64, _ reason: String? = nil) {
        guard Self.codeIsValidCryptoCode(cryptoError) else { return nil }
        self.init(QUICTransportErrorCodeInner.crypto(cryptoError), reason)
    }

    public init?(_ code: Int64, _ reason: String? = nil) {
        if Self.transportErrorCodeIsCryptoError(code) {
            self.init(cryptoError: code - 0x0100, reason)
        } else {
            guard let code = QUICTransportErrorCode(rawValue: code) else { return nil }
            self.init(code, reason)
        }
    }

    public init?(_ code: UInt64, _ reason: String? = nil) {
        guard let code = Int64(exactly: code) else { return nil }
        self.init(code, reason)
    }

    public static func category(of error: QUICTransportError) -> NetworkError.CommonCategory? {
        if case .transport(let transportError) = error.errorCode {
            switch transportError {
            case .flowControlError, .streamLimitError, .streamStateError, .frameEncodingError,
                .transportParameterError, .connectionIDLimitError, .protocolViolation:
                return .specViolation
            default: return nil
            }
        }
        return nil
    }

    public var description: String {
        if let reason {
            return reason
        }
        switch errorCode {
        case .transport(let transportError):
            switch transportError {
            case .noError: return "No error"
            case .internalError: return "Implementation fault"
            case .serverBusy: return "Protocol error detected"
            case .flowControlError: return "Flow-control limits exceeded"
            case .streamLimitError: return "Stream limits exceeded"
            case .streamStateError: return "Frame received for invalid stream state"
            case .finalSizeError: return "Received invalid final size update"
            case .frameEncodingError: return "Received badly formatted frame"
            case .transportParameterError: return "Received badly formatted transport parameter"
            case .connectionIDLimitError: return "Connection ID limits exceeded"
            case .protocolViolation: return "Protocol violation detected"
            case .invalidToken: return "Received invalid token from client"
            case .applicationError: return "Application error"
            case .cryptoBufferExceeded: return "Crypto buffer exceeded"
            case .keyUpdateError: return "Key update error"
            case .aeadLimitReached: return "Reached limit for the AEAD algorithm"
            case .noViablePath: return "Path does not support QUIC"
            }
        case .crypto(let code):
            return "QUIC Crypto Error: \(code)"
        }
    }

    static func code(for error: NetworkError) -> Int64 {
        if let domainSpecificError = error.domainSpecificError,
            domainSpecificError.domain == Self.domain
        {
            return domainSpecificError.code
        }
        if let category = error.category {
            switch category {
            case .specViolation: return QUICTransportErrorCode.protocolViolation.rawValue
            case .applicationCancellation: return QUICTransportErrorCode.applicationError.rawValue
            default: break
            }
        }
        return QUICTransportErrorCode.internalError.rawValue
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICApplicationError: NetworkDomainSpecificError {
    public static var domain: NetworkError.Domain { .init(rawValue: "QUICApplicationError") }

    public let code: Int64
    public let reason: String?

    public init(_ code: Int64, _ reason: String? = nil) {
        self.code = code
        self.reason = reason
    }

    public init?(_ code: UInt64, _ reason: String? = nil) {
        guard let code = Int64(exactly: code) else { return nil }
        self.init(code, reason)
    }

    public var description: String {
        if let reason {
            return reason
        } else {
            return "QUIC Application Error: \(code)"
        }
    }

    public static func category(of error: QUICApplicationError) -> NetworkError.CommonCategory? {
        nil
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension NetworkError {
    public init(quicTransportError: QUICTransportError) {
        self.init(quicTransportError)
    }

    public init(quicApplicationError: QUICApplicationError) {
        self.init(quicApplicationError)
    }

    public init(quicApplicationError code: Int64, reason: String? = nil) {
        self.init(quicApplicationError: QUICApplicationError(code, reason))
    }
    public init?(quicApplicationError code: UInt64, reason: String? = nil) {
        guard let error = QUICApplicationError(code, reason) else { return nil }
        self.init(quicApplicationError: error)
    }

    public var quicApplicationError: Int64? {
        guard let domainSpecificError,
            domainSpecificError.domain == QUICApplicationError.domain
        else {
            return nil
        }
        return domainSpecificError.code
    }

    public var quicTransportError: Int64? {
        guard let domainSpecificError,
            domainSpecificError.domain == QUICTransportError.domain
        else {
            return nil
        }
        return domainSpecificError.code
    }

    public init?(quicTransportError code: Int64, reason: String? = nil) {
        guard let error = QUICTransportError(code, reason) else { return nil }
        self.init(quicTransportError: error)
    }

    public init?(quicTransportError code: UInt64, reason: String? = nil) {
        guard let error = QUICTransportError(code, reason) else { return nil }
        self.init(quicTransportError: error)
    }
}

// QUICError is a common type for representing all exceptions thrown by the QUIC stack
// More granular error types are not used as embedded swift does not support untyped throws

#if !NETWORK_NO_SWIFT_QUIC
@available(Network 0.1.0, *)
enum QUICError: Error {
    case packet(QUICPacketError)
    case packetBuilder(PacketBuilderError)
    case packetFormats(QUICPacketFormatsError)
    #if IMPORT_CRYPTO || IMPORT_SWIFTTLS  // Keep in sync with protector scoping
    case protector(SecFramerError)
    #endif
    case frameParse(FrameParseError)
    case frameWrite(FrameWriteError)
    case transportParametersDecode(TransportParameterDecodeErrors)
    case transportParametersEncode(TransportParameterEncodeErrors)
    case connectionID(QUICConnectionIDError)

    var info: (code: Int, description: String) {
        switch self {
        case .packet(let subtype):
            return (subtype.rawValue, "QUIC Packet Exception")
        case .packetBuilder(let subtype):
            return (subtype.rawValue, subtype.description())
        case .packetFormats(let subtype):
            return (subtype.rawValue, "Packet Formats Exception")
        #if IMPORT_CRYPTO || IMPORT_SWIFTTLS  // Keep in sync with protector scoping
        case .protector(let subtype):
            return (subtype.rawValue, "QUIC Protector Exception")
        #endif
        case .frameParse(let subtype):
            return (Int.min, subtype.description())
        case .frameWrite(let subtype):
            return (subtype.rawValue, "QUIC Frame Write Exception")
        case .transportParametersDecode(let subtype):
            return (subtype.rawValue, "QUIC Transport Parameters Decode Exception")
        case .transportParametersEncode(let subtype):
            return (subtype.rawValue, "QUIC Transport Parameters Encoder Exception")
        case .connectionID(let subtype):
            return (subtype.rawValue, "QUIC Connection ID error")
        }
    }
}
#else
enum QUICError: Error {
    case none
}
#endif

#if os(Linux) || os(Android)
typealias CryptoKitMetaError = any Error
#endif
