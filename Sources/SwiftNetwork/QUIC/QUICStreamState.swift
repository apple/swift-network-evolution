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
#endif
