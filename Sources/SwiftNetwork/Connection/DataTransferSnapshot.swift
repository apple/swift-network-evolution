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

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct DataTransferSnapshot: Equatable, Sendable {
    public var snapshotTimestamp: NetworkClock.Instant = .zero
    public var interfaceIndex: UInt64?
    public var interfaceType: InterfaceType?
    public var pathIdentifier: UInt64?

    public var receivedIPPacketCount: UInt64 = 0
    public var receivedIPEct1PacketCount: UInt64 = 0
    public var receivedIPEct0PacketCount: UInt64 = 0
    public var receivedIPCEPacketCount: UInt64 = 0
    public var sentIPPacketCount: UInt64 = 0

    public var receivedTransportByteCount: UInt64 = 0
    public var receivedTransportDuplicateByteCount: UInt64 = 0
    public var receivedTransportOutOfOrderByteCount: UInt64 = 0
    public var sentTransportByteCount: UInt64 = 0
    public var sentTransportRetransmittedByteCount: UInt64 = 0
    public var sentTransportECNCapablePacketCount: UInt64 = 0
    public var sentTransportECNCapableAckedPacketCount: UInt64 = 0
    public var sentTransportECNCapableMarkedPacketCount: UInt64 = 0
    public var sentTransportECNCapableLostPacketCount: UInt64 = 0

    public var transportSmoothedRTT = NetworkDuration.zero
    public var transportMinimumRTT = NetworkDuration.zero
    public var transportCurrentRTT = NetworkDuration.zero
    public var transportRTTVariance = NetworkDuration.zero

    public var transportCongestionWindow: UInt64 = 0
    public var transportSlowStartThreshold: UInt64 = 0

    public var receivedApplicationByteCount: UInt64 = 0
    public var sentApplicationByteCount: UInt64 = 0

    public var migrationToCellCount: UInt64 = 0
    public var migrationToWifiCount: UInt64 = 0
    public var migrationToWiredCount: UInt64 = 0
    public var migrationToOtherCount: UInt64 = 0
    public var migrationToFallbackCount: UInt64 = 0

    public init() {}
}
