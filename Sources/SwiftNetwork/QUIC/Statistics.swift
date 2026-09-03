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

@available(Network 0.1.0, *)
enum QUICStatistic: Int, CaseIterable {
    case connectionAttempts
    case connectionsEstablished
    case keepAliveFramesSent
    case keepAliveFramesAcknowledged
    case pathsValidated
    case successfulMigrations

    case retransmitTimeOut
    case keepAliveTimeOuts
    case probeTimeOuts

    case rxPackets
    case rxBytes
    case txPackets
    case txBytes

    case rxStreamFrames
    case rxStreamBytes
    case rxStreamBlockedFrames
    case rxStreamDataBlockedFrames
    case rxStreamResetFrames
    case rxStreamStopSendingFrames

    case txStreamFrames
    case txStreamBytes
    case txStreamBlockedFrames
    case txStreamDataBlockedFrames
    case txStreamResetFrames
    case txStreamStopSendingFrames

    case rxInitialCryptoFrames
    case rxInitialCryptoBytes
    case rxHandshakeCryptoFrames
    case rxHandshakeCryptoBytes
    case rx0RTTCryptoFrames
    case rx0RTTCryptoBytes
    case rx1RTTCryptoFrames
    case rx1RTTCryptoBytes

    case txInitialCryptoFrames
    case txInitialCryptoBytes
    case txHandshakeCryptoFrames
    case txHandshakeCryptoBytes
    case tx0RTTCryptoFrames
    case tx0RTTCryptoBytes
    case tx1RTTCryptoFrames
    case tx1RTTCryptoBytes
    case txRetransmittedCryptoFrames
    case txRetransmittedCryptoBytes

    case rxDataBlockedFrames
    case rxDuplicateBytes
    case rxOutOfOrderBytes
    case rxReorderedBytes
    case rxReorderedPackets

    case txDataBlockedFrames
    case txRetransmittedBytes
    case txRetransmittedPackets
    case txLostBytes
    case txLostPackets

    case rxApplicationCloseError
    case txApplicationCloseError

    case rxConnectionCloseReasonInternalError
    case rxConnectionCloseReasonServerBusy
    case rxConnectionCloseReasonFlowControlError
    case rxConnectionCloseReasonStreamLimitError
    case rxConnectionCloseReasonStreamStateError
    case rxConnectionCloseReasonFinalSizeError
    case rxConnectionCloseReasonFrameEncodingError
    case rxConnectionCloseReasonTransportParameterError
    case rxConnectionCloseReasonProtocolViolation
    case rxConnectionCloseReasonCryptoError

    case txConnectionCloseReasonInternalError
    case txConnectionCloseReasonServerBusy
    case txConnectionCloseReasonFlowControlError
    case txConnectionCloseReasonStreamLimitError
    case txConnectionCloseReasonStreamStateError
    case txConnectionCloseReasonFinalSizeError
    case txConnectionCloseReasonFrameEncodingError
    case txConnectionCloseReasonTransportParameterError
    case txConnectionCloseReasonProtocolViolation
    case txConnectionCloseReasonCryptoError

    case rxECT0
    case rxECT1
    case rxECTCE

    case txECT0
    case txECT1
    case txECTCE

    case inboundUnidirectionalStreams
    case inboundBidirectionalStreams
    case outboundUnidirectionalStreams
    case outboundBidirectionalStreams

    case ecnCapablePacketsSent
    case ecnCapablePacketsAcknowledged
    case ecnCapablePacketsMarked
    case ecnCapablePacketsLost

    case txDatagramFrameWithLength
    case rxDatagramFrameWithLength
    case txDatagramFrameWithOutLength
    case rxDatagramFrameWithOutLength

    case txNewToken
    case rxNewToken

    case txDepartureTimestamp

    case statelessResetReceived
    case statelessResetDuringPathProbe
}

// Availability due to Swift's inline array type (`[96 of Int]`)
@available(anyAppleOS 26, *)
struct Statistics: ~Copyable {

    private var statisticsArray: [98 of Int]

    init() {
        statisticsArray = .init(repeating: 0)
        precondition(
            statisticsArray.count == QUICStatistic.allCases.count,
            "statisticsArray count does not match the count of QUICStatistic cases"
        )
    }

    subscript(statistic: QUICStatistic) -> Int {
        get {
            statisticsArray[statistic.rawValue]
        }
        set(newValue) {
            statisticsArray[statistic.rawValue] = newValue
        }
    }

    @inline(always)
    @inlinable
    mutating func increment(_ key: QUICStatistic, by value: Int = 1) {
        statisticsArray[key.rawValue] &+= value
    }

    var connectionStatistics: [QUICStatistic: Int] {
        var dict: [QUICStatistic: Int] = [:]
        for key in QUICStatistic.allCases {
            dict[key] = statisticsArray[key.rawValue]
        }
        return dict
    }
}
#endif
