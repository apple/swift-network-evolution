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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public enum QUICStreamType: CustomStringConvertible {
    case bidirectional
    case unidirectional

    public var description: String {
        switch self {
        case .bidirectional: return "bidirectional"
        case .unidirectional: return "unidirectional"
        }
    }
}

#if !NETWORK_NO_SWIFT_QUIC
// RFC9000 2.1 Stream Types and Identifiers. We use specific type to ensure type
// safe operations, instead of extending UInt64 for example.
@available(Network 0.1.0, *)
struct QUICStreamID: Comparable, Hashable {
    // UInt64: A stream ID is a 62-bit integer that is unique for all streams on a connection.
    private(set) var value: UInt64
    // The least significant bit (0x01) of the stream ID identifies the initiator of the stream.
    private static let initiatorMask: UInt64 = 0x1
    // The second least significant bit (0x02) of the stream ID distinguishes between bidirectional streams
    // (with the bit set to 0) and unidirectional streams (with the bit set to 1).
    private static let typeMask: UInt64 = 0x2
    private static let mask: UInt64 = initiatorMask | typeMask

    // Note: In Swift we deal with "datagram" and "TLS" as entirely different things, so they are not applicable here.

    static let maxLocalStreams: UInt64 = QUICStreamID.maxLocal + 1
    static let maxLocal: UInt64 = 0x0fff_ffff_ffff_ffff  // Only 60 bits used locally
    static let maxValid: UInt64 = 0x3fff_ffff_ffff_ffff  // Up to 62 bits can be used by remote

    init(_ value: UInt32) {
        self.value = UInt64(value)
    }

    init?(_ value: UInt64) {
        guard value <= QUICStreamID.maxValid else {
            return nil
        }
        self.value = value
    }

    init?(_ value: UInt64, serverInitiated: Bool, isUnidirectional: Bool) {
        var streamID = value
        if serverInitiated {
            streamID |= QUICStreamID.initiatorMask
        }
        if isUnidirectional {
            streamID |= QUICStreamID.typeMask  // Unidirectional
        } else {
            streamID &= ~QUICStreamID.typeMask  // Bidirectional
        }
        self.init(streamID)
    }

    static func setInitiator(value: inout UInt64, isLocal: Bool) {
        if isLocal {
            value &= ~QUICStreamID.initiatorMask
        }
        value |= QUICStreamID.initiatorMask
        return
    }
    static func setStreamType(value: inout UInt64, isBidir: Bool) {
        if isBidir {
            value &= ~QUICStreamID.typeMask
            return
        }
        value |= QUICStreamID.typeMask
        return
    }
    static func < (lhs: QUICStreamID, rhs: QUICStreamID) -> Bool {
        lhs.value < rhs.value
    }

    static func == (lhs: QUICStreamID, rhs: QUICStreamID) -> Bool {
        lhs.value == rhs.value
    }

    // Client-initiated streams have even-numbered stream IDs (with the bit set to 0)
    var isClientInitiated: Bool { (self.value & QUICStreamID.initiatorMask) == 0 }

    // Server-initiated streams have odd-numbered stream IDs (with the bit set to 1).
    var isServerInitiated: Bool { (self.value & QUICStreamID.initiatorMask) != 0 }

    var isBidirectional: Bool { (self.value & QUICStreamID.typeMask) == 0 }

    var isUnidirectional: Bool { (self.value & QUICStreamID.typeMask) != 0 }

    func isLocalBidirectional(server: Bool) -> Bool {
        self.isBidirectional
            && ((!server && self.isServerInitiated) || (server && self.isClientInitiated))
    }

    func isSendOnly(server: Bool) -> Bool {
        self.isUnidirectional
            && ((!server && self.isClientInitiated) || (server && self.isServerInitiated))
    }

    func isReceiveOnly(server: Bool) -> Bool {
        self.isUnidirectional
            && ((!server && self.isServerInitiated) || (server && self.isClientInitiated))
    }

    func isInitiatedBy(server: Bool) -> Bool {
        if !server && self.isClientInitiated {
            return true
        } else if server && self.isServerInitiated {
            return true
        }
        return false
    }

    var quicStreamType: QUICStreamType { self.isBidirectional ? .bidirectional : .unidirectional }

    func _rawHashValue(seed: Int) -> Int {
        // This is a 'Hashable' fast path which elides the creation of Hasher
        self.value._rawHashValue(seed: seed)
    }
}

// MARK: QUICStreamID computations

@available(Network 0.1.0, *)
extension QUICStreamID {
    static func computeRemoteMaxStreamIDBidirectional(
        server: Bool,
        streams: UInt64
    ) -> QUICStreamID? {
        guard streams != 0 else { return nil }
        if !server {
            // There is a overflow check in QUICStreamID so this will return nil
            // if the shift overflows.
            return QUICStreamID((streams - 1) << 2)  // 4(n-1)
        } else {
            return QUICStreamID(((streams - 1) << 2) + 1)  // 4(n-1) + 1
        }
    }

    static func computeRemoteMaxStreamIDUnidirectional(
        server: Bool,
        streams: UInt64
    ) -> QUICStreamID? {
        guard streams != 0 else { return nil }
        if !server {
            return QUICStreamID(((streams - 1) << 2) + 2)  // 4(n-1) + 2
        } else {
            return QUICStreamID(((streams - 1) << 2) + 3)  // 4(n-1) + 3
        }
    }

    static func computeLocalMaxStreamIDBidirectional(server: Bool, streams: UInt64) -> QUICStreamID? {
        guard streams != 0 else { return nil }
        if !server {
            return QUICStreamID(((streams - 1) << 2) + 1)  // 4(n-1) + 1
        } else {
            return QUICStreamID((streams - 1) << 2)  // 4(n-1)
        }
    }

    static func computeLocalMaxStreamIDUnidirectional(
        server: Bool,
        streams: UInt64
    ) -> QUICStreamID? {
        guard streams != 0 else { return nil }
        if !server {
            return QUICStreamID(((streams - 1) << 2) + 3)  // 4(n-1) + 3
        } else {
            return QUICStreamID(((streams - 1) << 2) + 2)  // 4(n-1) + 2
        }
    }

    // Compute Max Stream Data for the remote end based on our connection role (server or client)
    // and the Stream ID we received from the remote end.
    static func computeRemoteMaxStreamData(
        isServer: Bool,
        remoteTransportParameters: TransportParameters?,
        streamID: QUICStreamID
    ) -> Int {
        guard let remoteTransportParameters = remoteTransportParameters else {
            return 0
        }

        if streamID.isUnidirectional {
            // It doesn't matter if we're server or client here
            return remoteTransportParameters.intValue(.initialMaxStreamDataUnidirectional)
        }

        let maxStreamData: Int
        let maxLimitLocal = remoteTransportParameters.intValue(
            .initialMaxStreamDataBidirectionalLocal
        )
        let maxLimitRemote = remoteTransportParameters.intValue(
            .initialMaxStreamDataBidirectionalRemote
        )

        if !isServer {
            maxStreamData = streamID.isServerInitiated ? maxLimitLocal : maxLimitRemote
        } else {
            maxStreamData = streamID.isServerInitiated ? maxLimitRemote : maxLimitLocal
        }

        return maxStreamData
    }

    static func computeLocalMaxStreamData(
        isServer: Bool,
        localTransportParameters: TransportParameters,
        streamID: QUICStreamID
    ) -> Int {

        if streamID.isUnidirectional {
            return localTransportParameters.intValue(.initialMaxStreamDataUnidirectional)
        }

        let maxStreamData: Int
        let maxLimitLocal = localTransportParameters.intValue(
            .initialMaxStreamDataBidirectionalLocal
        )
        let maxLimitRemote = localTransportParameters.intValue(
            .initialMaxStreamDataBidirectionalRemote
        )

        if !isServer {
            maxStreamData = streamID.isServerInitiated ? maxLimitRemote : maxLimitLocal
        } else {
            maxStreamData = streamID.isServerInitiated ? maxLimitLocal : maxLimitRemote
        }

        return maxStreamData
    }

}

@available(Network 0.1.0, *)
extension QUICStreamID {
    var variableLengthSize: Int {
        self.value.variableLengthSize
    }
}

@available(Network 0.1.0, *)
extension QUICStreamID {
    // Returns the next available Stream ID
    static func nextAvailableStreamID(
        allocatedStreamCount: Int,
        remoteMaxStreams: Int,
        remoteMaxStreamID: QUICStreamID?,
        server: Bool,
        logIDString: String,
        isUnidirectional: Bool
    ) -> QUICStreamID? {
        // There is a overflow check in QUICStreamID so this will return nil
        // if the shift overflows.
        let nextStreamID = allocatedStreamCount << 2
        let newStreamID = QUICStreamID(
            UInt64(nextStreamID),
            serverInitiated: server,
            isUnidirectional: isUnidirectional
        )
        guard let newStreamID else {
            return nil
        }

        if remoteMaxStreams == 0 {
            Logger.proto.debug("\(logIDString) remote max streams is 0")
            return nil
        }
        if let remoteMaxStreamID = remoteMaxStreamID,
            newStreamID > remoteMaxStreamID
        {
            Logger.proto.debug(
                "\(logIDString) new stream ID \(newStreamID) exceeds the unidirectional limit \(remoteMaxStreamID)"
            )
            return nil
        }
        return newStreamID
    }
}

@available(Network 0.1.0, *)
extension QUICStreamID: Strideable {
    func advanced(by n: Int) -> QUICStreamID {
        QUICStreamID(self.value + UInt64(n))!
    }

    func distance(to other: QUICStreamID) -> Int {
        Int(other.value - self.value)
    }
}

@available(Network 0.1.0, *)
extension QUICStreamID {
    static let strideLengthToNextOfSameTypeAndInitiator = 4
    // Advance to next stream ID of same type and initiator.
    // The operation can overflow the valid range of value, so must validate value again.
    func nextOfSameTypeAndInitiator() -> QUICStreamID? {
        QUICStreamID(
            self.value + UInt64(QUICStreamID.strideLengthToNextOfSameTypeAndInitiator)
        )
    }
}

@available(Network 0.1.0, *)
extension QUICStreamID: CustomStringConvertible {
    var description: String {
        String(value)
    }
}
#endif
