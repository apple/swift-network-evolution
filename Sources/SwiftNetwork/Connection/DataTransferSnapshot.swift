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
    var snapshotTimestamp: NetworkClock.Instant = .zero
    var interfaceIndex: UInt64?
    var pathIdentifier: UInt64?

    var receivedIPPacketCount: UInt64 = 0
    var receivedIPEct1PacketCount: UInt64 = 0
    var receivedIPEct0PacketCount: UInt64 = 0
    var receivedIPCEPacketCount: UInt64 = 0
    var sentIPPacketCount: UInt64 = 0

    var receivedTransportByteCount: UInt64 = 0
    var receivedTransportDuplicateByteCount: UInt64 = 0
    var receivedTransportOutOfOrderByteCount: UInt64 = 0
    var sentTransportByteCount: UInt64 = 0
    var sentTransportRetransmittedByteCount: UInt64 = 0
    var sentTransportRetransmittedPacketCount: UInt64 = 0
    var sentTransportLostByteCount: UInt64 = 0
    var sentTransportLostPacketCount: UInt64 = 0
    var sentTransportECNCapablePacketCount: UInt64 = 0
    var sentTransportECNCapableAckedPacketCount: UInt64 = 0
    var sentTransportECNCapableMarkedPacketCount: UInt64 = 0
    var sentTransportECNCapableLostPacketCount: UInt64 = 0

    var transportSmoothedRTT: NetworkDuration = .milliseconds(0)
    var transportMinimumRTT: NetworkDuration = .milliseconds(0)
    var transportCurrentRTT: NetworkDuration = .milliseconds(0)
    var transportRTTVariance: NetworkDuration = .milliseconds(0)

    var transportCongestionWindow: UInt64 = 0
    var transportSlowStartThreshold: UInt64 = 0
    var transportBytesInFlight: UInt64 = 0

    var receivedApplicationByteCount: UInt64 = 0
    var sentApplicationByteCount: UInt64 = 0

    var migrationToCellCount: UInt64 = 0
    var migrationToWifiCount: UInt64 = 0
    var migrationToWiredCount: UInt64 = 0
    var migrationToOtherCount: UInt64 = 0
    var migrationToFallbackCount: UInt64 = 0
    var pathsValidated: UInt64 = 0
    var successfulMigrations: UInt64 = 0

    var pmtudSuccessfulProbes: UInt64 = 0
    var pmtudFailedProbes: UInt64 = 0

    var receivedStreamFrameCount: UInt64 = 0
    var sentStreamFrameCount: UInt64 = 0
    var receivedStreamResetFrameCount: UInt64 = 0
    var sentStreamResetFrameCount: UInt64 = 0

    var receivedDatagramFrameCount: UInt64 = 0
    var sentDatagramFrameCount: UInt64 = 0

    public func jsonString() -> String? {
        #if canImport(Foundation)
        let dict: [String: Any] = [
            "snapshotTimestamp": snapshotTimestamp.milliseconds,
            "pathIdentifier": pathIdentifier ?? 0,
            "receivedIPPacketCount": receivedIPPacketCount,
            "sentIPPacketCount": sentIPPacketCount,
            "receivedTransportByteCount": receivedTransportByteCount,
            "sentTransportByteCount": sentTransportByteCount,
            "transportSmoothedRTT": transportSmoothedRTT.milliseconds,
            "transportMinimumRTT": transportMinimumRTT.milliseconds,
            "transportCongestionWindow": transportCongestionWindow,
            "transportBytesInFlight": transportBytesInFlight,
            "sentTransportLostByteCount": sentTransportLostByteCount,
            "sentTransportRetransmittedByteCount": sentTransportRetransmittedByteCount,
            "sentTransportECNCapableMarkedPacketCount": sentTransportECNCapableMarkedPacketCount,
            "sentTransportECNCapableLostPacketCount": sentTransportECNCapableLostPacketCount,
            "pathsValidated": pathsValidated,
            "successfulMigrations": successfulMigrations,
            "pmtudSuccessfulProbes": pmtudSuccessfulProbes,
            "pmtudFailedProbes": pmtudFailedProbes
        ]
        if let data = try? Foundation.JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            return String(data: data, encoding: .utf8)
        }
        #endif
        return nil
    }
}

