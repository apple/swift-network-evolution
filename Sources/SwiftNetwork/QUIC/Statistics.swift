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
    case connectionAttempts = 0
    case connectionsEstablished = 1
    case keepAliveFramesSent = 2
    case keepAliveFramesAcknowledged = 3
    case pathsValidated = 4
    case successfulMigrations = 5

    case retransmitTimeOut = 6
    case keepAliveTimeOuts = 7
    case probeTimeOuts = 8

    case rxPackets = 9
    case rxBytes = 10
    case txPackets = 11
    case txBytes = 12

    case rxStreamFrames = 13
    case rxStreamBytes = 14
    case rxStreamBlockedFrames = 15
    case rxStreamDataBlockedFrames = 16
    case rxStreamResetFrames = 17
    case rxStreamStopSendingFrames = 18

    case txStreamFrames = 19
    case txStreamBytes = 20
    case txStreamBlockedFrames = 21
    case txStreamDataBlockedFrames = 22
    case txStreamResetFrames = 23
    case txStreamStopSendingFrames = 24

    case rxInitialCryptoFrames = 25
    case rxInitialCryptoBytes = 26
    case rxHandshakeCryptoFrames = 27
    case rxHandshakeCryptoBytes = 28
    case rx0RTTCryptoFrames = 29
    case rx0RTTCryptoBytes = 30
    case rx1RTTCryptoFrames = 31
    case rx1RTTCryptoBytes = 32

    case txInitialCryptoFrames = 33
    case txInitialCryptoBytes = 34
    case txHandshakeCryptoFrames = 35
    case txHandshakeCryptoBytes = 36
    case tx0RTTCryptoFrames = 37
    case tx0RTTCryptoBytes = 38
    case tx1RTTCryptoFrames = 39
    case tx1RTTCryptoBytes = 40
    case txRetransmittedCryptoFrames = 41
    case txRetransmittedCryptoBytes = 42

    case rxDataBlockedFrames = 43
    case rxDuplicateBytes = 44
    case rxOutOfOrderBytes = 45
    case rxReorderedBytes = 46
    case rxReorderedPackets = 47

    case txDataBlockedFrames = 48
    case txRetransmittedBytes = 49
    case txRetransmittedPackets = 50
    case txLostBytes = 51
    case txLostPackets = 52

    case rxApplicationCloseError = 53
    case txApplicationCloseError = 54

    case rxConnectionCloseReasonInternalError = 55
    case rxConnectionCloseReasonServerBusy = 56
    case rxConnectionCloseReasonFlowControlError = 57
    case rxConnectionCloseReasonStreamLimitError = 58
    case rxConnectionCloseReasonStreamStateError = 59
    case rxConnectionCloseReasonFinalSizeError = 60
    case rxConnectionCloseReasonFrameEncodingError = 61
    case rxConnectionCloseReasonTransportParameterError = 62
    case rxConnectionCloseReasonProtocolViolation = 63
    case rxConnectionCloseReasonCryptoError = 64

    case txConnectionCloseReasonInternalError = 65
    case txConnectionCloseReasonServerBusy = 66
    case txConnectionCloseReasonFlowControlError = 67
    case txConnectionCloseReasonStreamLimitError = 68
    case txConnectionCloseReasonStreamStateError = 69
    case txConnectionCloseReasonFinalSizeError = 70
    case txConnectionCloseReasonFrameEncodingError = 71
    case txConnectionCloseReasonTransportParameterError = 72
    case txConnectionCloseReasonProtocolViolation = 73
    case txConnectionCloseReasonCryptoError = 74

    case rxECT0 = 75
    case rxECT1 = 76
    case rxECTCE = 77

    case txECT0 = 78
    case txECT1 = 79
    case txECTCE = 80

    case inboundUnidirectionalStreams = 81
    case inboundBidirectionalStreams = 82
    case outboundUnidirectionalStreams = 83
    case outboundBidirectionalStreams = 84

    case ecnCapablePacketsSent = 85
    case ecnCapablePacketsAcknowledged = 86
    case ecnCapablePacketsMarked = 87
    case ecnCapablePacketsLost = 88

    case txDatagramFrameWithLength = 89
    case rxDatagramFrameWithLength = 90
    case txDatagramFrameWithOutLength = 91
    case rxDatagramFrameWithOutLength = 92

    case txNewToken = 93
    case rxNewToken = 94

    case txDepartureTimestamp = 95

    case statelessResetReceived = 96
    case statelessResetDuringPathProbe = 97
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
