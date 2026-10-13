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

@available(Network 0.1.0, *)
enum QUICShorthandFrame: CustomStringConvertible {
    case padding(_ entry: ShorthandFramePadding)
    case ping(_ entry: ShorthandFrameGeneric)
    case ack(_ entry: ShorthandFrameAck)
    case resetStream(_ entry: ShorthandFrameResetStream)
    case stopSending(_ entry: ShorthandFrameStopSending)
    case crypto(_ entry: ShorthandFrameCrypto)
    case newToken(_ entry: ShorthandFrameNewToken)
    case stream(_ entry: ShorthandFrameStream)
    // stream with flags 0x09-0x0f
    case maxData(_ entry: ShorthandFrameMaxData)
    case maxStreamData(_ entry: ShorthandFrameMaxStreamData)
    case maxStreamsBidirectional(_ entry: ShorthandFrameMaxStreamsBidirectional)
    case maxStreamsUnidirectional(_ entry: ShorthandFrameMaxStreamsUnidirectional)
    case dataBlocked(_ entry: ShorthandFrameDataBlocked)
    case streamDataBlocked(_ entry: ShorthandFrameStreamDataBlocked)
    case streamsBlockedBidirectional(_ entry: ShorthandFrameStreamsBlockedBidirectional)
    case streamsBlockedUnidirectional(_ entry: ShorthandFrameStreamsBlockedUnidirectional)
    case newConnectionID(_ entry: ShorthandFrameNewConnectionID)
    case retireConnectionID(_ entry: ShorthandFrameRetireConnectionID)
    case pathChallenge(_ entry: ShorthandFrameGeneric)
    case pathResponse(_ entry: ShorthandFrameGeneric)
    case connectionClose(_ entry: ShorthandFrameConnectionClose)
    case applicationClose(_ entry: ShorthandFrameApplicationClose)
    case handshakeDone(_ entry: ShorthandFrameGeneric)

    /* RFC 9221 */
    case datagram(_ entry: ShorthandFrameDatagram)

    var description: String {
        switch self {
        case .padding(let entry): return entry.description
        case .ping(let entry): return entry.description
        case .ack(let entry): return entry.description
        case .resetStream(let entry): return entry.description
        case .stopSending(let entry): return entry.description
        case .crypto(let entry): return entry.description
        case .newToken(let entry): return entry.description
        case .stream(let entry): return entry.description
        case .maxData(let entry): return entry.description
        case .maxStreamData(let entry): return entry.description
        case .maxStreamsBidirectional(let entry): return entry.description
        case .maxStreamsUnidirectional(let entry): return entry.description
        case .dataBlocked(let entry): return entry.description
        case .streamDataBlocked(let entry): return entry.description
        case .streamsBlockedBidirectional(let entry): return entry.description
        case .streamsBlockedUnidirectional(let entry): return entry.description
        case .newConnectionID(let entry): return entry.description
        case .retireConnectionID(let entry): return entry.description
        case .pathChallenge(let entry): return entry.description
        case .pathResponse(let entry): return entry.description
        case .connectionClose(let entry): return entry.description
        case .applicationClose(let entry): return entry.description
        case .handshakeDone(let entry): return entry.description
        case .datagram(let entry): return entry.description
        }
    }

    static func shouldGenerateShorthandFrames(hasQLog: Bool) -> Bool {
        #if QlogOutput
        if hasQLog {
            // Always generate shorthand if qlog is enabled
            return true
        }
        #endif
        #if !NETWORK_EMBEDDED
        // Generate shorthand when datapath logs are enabled
        return Logger.swiftNetworkDatapathLoggingEnabled
        #else
        return false
        #endif
    }
}

@available(Network 0.1.0, *)
protocol ShorthandLogEntry: CustomStringConvertible {
    var outgoing: Bool { get }
}

#endif
