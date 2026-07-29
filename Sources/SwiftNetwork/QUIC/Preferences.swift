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

#if NETWORK_EMBEDDED
// QUICPreferences for Embedded is small subset of preferences based on what is currently used in the stack otherwise.
struct QUICPreferences {
    static let shared = QUICPreferences()
    let ackCompressionEnabled: Bool = true
    let disableCachedRTT: Bool = false
    let pacePackets: Bool = false

    let initialStreamReceiveSpace: Int? = nil
    let initialConnectionReceiveSpace: Int? = nil
    let maxConcurrentStreams: Int? = nil
    let streamMaxReceiveWindow: Int? = nil
    let initialMaxData: Int? = nil
    let initialMaxStreamBidirectionalLocalData: Int? = nil
    let maxConnectivityProbes: Int = 3
    let maxSentPacketsCapacity: Int = 512

    private init() {}
}
#else
@available(Network 0.1.0, *)
struct QUICPreferences: ~Copyable, Sendable {
    static let shared = QUICPreferences()

    let debugEnabled: Bool
    let disableCubic: Bool
    let forceLEDBAT: Bool
    let disableCachedRTT: Bool
    let adaptiveTimeThreshold: Bool
    let adaptivePacketThreshold: Bool
    let enableAckFreq: Bool
    let pacePackets: Bool
    let disableKernelPacing: Bool
    let ackCompressionEnabled: Bool
    let maxPacketReorderThreshold: Int
    let ackDefaultPacketThreshold: Int
    let migrationVersion: Int
    let migrationPTOThreshold: Int
    let migrationKeepaliveThreshold: Int
    let quiclogDirectory: String
    let maxConnectivityProbes: Int
    let maxSentPacketsCapacity: Int

    // Flow Control
    let initialStreamReceiveSpace: Int?
    let initialConnectionReceiveSpace: Int?
    let maxConcurrentStreams: Int?
    let streamMaxReceiveWindow: Int?
    let initialMaxData: Int?
    let initialMaxStreamBidirectionalLocalData: Int?

    private init() {
        debugEnabled = QUICPreferences.findSetting("enable_debug", defaultValue: false)
        disableCubic = QUICPreferences.findSetting("disable_cubic", defaultValue: false)
        forceLEDBAT = QUICPreferences.findSetting("force_ledbat", defaultValue: false)
        disableCachedRTT = QUICPreferences.findSetting("disable_cached_rtt", defaultValue: false)
        adaptiveTimeThreshold = QUICPreferences.findSetting(
            "adaptive_time_thresh",
            defaultValue: true
        )
        adaptivePacketThreshold = QUICPreferences.findSetting(
            "adaptive_packet_thresh",
            defaultValue: true
        )
        enableAckFreq = QUICPreferences.findSetting("enable_ack_freq", defaultValue: false)
        pacePackets = QUICPreferences.findSetting("pace_packets", defaultValue: false)
        disableKernelPacing = QUICPreferences.findSetting(
            "disable_kernel_pacing",
            defaultValue: false
        )
        ackCompressionEnabled = QUICPreferences.findSetting(
            "enable_ack_compression",
            defaultValue: true
        )
        maxPacketReorderThreshold = QUICPreferences.findSetting(
            "max_packet_reorder_thresh",
            defaultValue: 20
        )
        ackDefaultPacketThreshold = QUICPreferences.findSetting(
            "ack_default_packet_threshold",
            defaultValue: Ack.defaultPacketThreshold
        )
        migrationVersion = QUICPreferences.findSetting(
            "migration_version",
            defaultValue: Migration.defaultMigrationVersion
        )
        migrationPTOThreshold = QUICPreferences.findSetting(
            "migration_pto_threshold",
            defaultValue: Migration.defaultPTOThreshold
        )
        migrationKeepaliveThreshold = QUICPreferences.findSetting(
            "migration_keepalive_threshold",
            defaultValue: Migration.defaultKeepaliveThreshold
        )
        maxConnectivityProbes = QUICPreferences.findSetting(
            "max_connectivity_probes",
            defaultValue: 3
        )
        maxSentPacketsCapacity = QUICPreferences.findSetting(
            "max_sent_packets_capacity",
            defaultValue: 512
        )
        quiclogDirectory = QUICPreferences.findSetting("quiclog_directory", defaultValue: "")

        // Flow Control
        streamMaxReceiveWindow = QUICPreferences.findSetting("stream_max_rcv_window", defaultValue: nil)
        initialStreamReceiveSpace = QUICPreferences.findSetting(
            "initial_stream_rcv_space",
            defaultValue: nil
        )
        initialConnectionReceiveSpace = QUICPreferences.findSetting(
            "initial_conn_rcv_space",
            defaultValue: nil
        )
        maxConcurrentStreams = QUICPreferences.findSetting("max_concurrent_streams", defaultValue: nil)
        initialMaxData = QUICPreferences.findSetting("initial_max_data", defaultValue: nil)
        initialMaxStreamBidirectionalLocalData = QUICPreferences.findSetting(
            "initial_max_stream_data_bidi_local",
            defaultValue: nil
        )
    }

    #if !NETWORK_PRIVATE
    static func findSetting<T>(_ settingName: String, defaultValue: T) -> T {
        defaultValue
    }
    #endif
}
#endif
#endif
