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
//  Constants for QUIC

#if !NETWORK_NO_SWIFT_QUIC
@available(Network 0.1.0, *)
enum Constants {
    static let initialMSS = 1200
    static let streamIDDatagramMask: UInt64 = 0x8000_0000_0000_0000
    static let pathIdentifierTypeThisPath: UInt64 = 2
    static let highMemorySystem: UInt64 = 3 * 1024 * 1024 * 1024
    static let maxQueuedPackets: Int = 5
    static let maxStreamLimit: UInt64 = (UInt64.max >> 4) + 1  // UINT60_MAX
    static let minimumPayloadLength = 3
    static let activeCIDLimit: UInt64 = 64
    static let maxDatagramFrameSize = 65535
    static let minimumPacketSize = 21
    static let maximumAllowedAckDelay = UInt32.max

    // Check burst every 10 packets
    static let packetBurstCount = 10

    // Don't burst more than 40 packets at a time
    static let maxPacketBurstCount = 40

    // Don't burst for more than 1 millisecond at a time
    static let maxPacketBurstDuration = NetworkDuration.milliseconds(1)

    static let packetReorderThreshold = PacketNumber(3)
    static let timeReorderThreshold = 3
    static let persistentCongestionThreshold = 3
    static let maxPacketReorderThreshold = 20
    static let adaptiveTimeThreshold = true
    static let adaptivePacketThreshold = true
    static let defaultKeepaliveValue = UInt16.max
    static let defaultKeepaliveDuration: NetworkDuration = .seconds(20)
    static let defaultVersion: QUICVersion = .v1
    static let retryTokenMaxLength: UInt8 = 128
    static let retryTokenIntegrityTagLength: UInt8 = 16
    static let statelessResetTokenSize: Int = 16
    static let preferredAddressCIDSequenceNumber: UInt64 = 1
    static let defaultIdleTimeout: NetworkDuration = .seconds(30)
    static let defaultMaxConnectionIDs = 8
    // Don't delay more than 10ms between two bursts
    static let maxBurstIntervalKernelPacing: NetworkDuration = .milliseconds(10)
    // The congestion window will have to be reset after a non-validated period.
    static let congestionWindowNonvalidatedPeriod: NetworkDuration = .minutes(3)
    static let streamDataMaxSize = UInt32.max
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum QUICVersion: UInt32, Sendable {
    case negotiation = 0
    case v1 = 0x0000_0001
    // Versions that follow the pattern 0x?a?a?a?a are reserved for forcing
    // version negotiation to be exercised -- that is, any version number where the
    // low four bits of all bytes is 1010 (in binary). A client or server MAY advertise
    // support for any of these reserved versions.
    case negotiationPattern = 0x1a2a_3a4a

    static let versionHeaderSize = MemoryLayout<UInt32>.size
    // Version used for unit testing
    static let unsupportedVersion: UInt32 = 0x0102_0304
}
#endif
