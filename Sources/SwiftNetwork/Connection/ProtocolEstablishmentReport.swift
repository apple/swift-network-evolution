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
public enum ClientAccurateECNState: UInt32, Equatable {
    case ecnInvalid = 0
    case ecnFeatureDisabled = 1
    case ecnFeatureEnabled = 2
    case classicECNAvailable = 3  // TCP only
    case ecnNotAvailable = 4
    case ecnNegotiationBlackholed = 5
    case ecnAccurateECNBleachingDetected = 6  // TCP only
    case ecnNegotiationSuccess = 7
    case ecnNegotiationSuccessECTManglingDetected = 8  // TCP only
    case ecnNegotiationSuccessECTBleachingDetected = 9  // TCP only
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum ServerAccurateECNState: UInt32, Equatable {
    case ecnInvalid = 0
    case ecnFeatureDisabled = 1
    case ecnFeatureEnabled = 2
    case noECNRequested = 3
    case classicEcnRequested = 4
    case ecnRequested = 5
    case ecnNegotiationBlackholed = 6
    case ecnAccurateECNBleachingDetected = 7
    case ecnNegotiationSuccess = 8
    case ecnNegotiationSuccessECTManglingDetected = 9
    case ecnNegotiationSuccessECTBleachingDetected = 10
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct ProtocolEstablishmentReport: Equatable {
    public let handshakeDuration: NetworkDuration
    public let handshakeRTT: NetworkDuration
    public let protocolIdentifier: ProtocolIdentifier
    public let clientAccurateECNState: ClientAccurateECNState
    public let serverAccurateECNState: ServerAccurateECNState

    public init(
        handshakeDuration: NetworkDuration,
        handshakeRTT: NetworkDuration,
        protocolIdentifier: ProtocolIdentifier,
        clientAccurateECNState: ClientAccurateECNState = .ecnInvalid,
        serverAccurateECNState: ServerAccurateECNState = .ecnInvalid
    ) {
        self.handshakeDuration = handshakeDuration
        self.handshakeRTT = handshakeRTT
        self.protocolIdentifier = protocolIdentifier
        self.clientAccurateECNState = clientAccurateECNState
        self.serverAccurateECNState = serverAccurateECNState
    }

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let l4sEnabled = Flags(rawValue: 1 << 0)
        static let quicMigrationSupported = Flags(rawValue: 1 << 1)
        static let quicStatelessResetReceived = Flags(rawValue: 1 << 2)
        static let quicStatelessResetDuringPathProbe = Flags(rawValue: 1 << 3)
    }
    private var flags = Flags()
    public var l4sEnabled: Bool {
        get { flags.contains(.l4sEnabled) }
        set { if newValue { flags.insert(.l4sEnabled) } else { flags.remove(.l4sEnabled) } }
    }
    public var quicMigrationSupported: Bool {
        get { flags.contains(.quicMigrationSupported) }
        set { if newValue { flags.insert(.quicMigrationSupported) } else { flags.remove(.quicMigrationSupported) } }
    }
    public var quicStatelessResetReceived: Bool {
        get { flags.contains(.quicStatelessResetReceived) }
        set {
            if newValue { flags.insert(.quicStatelessResetReceived) } else { flags.remove(.quicStatelessResetReceived) }
        }
    }
    public var quicStatelessResetDuringPathProbe: Bool {
        get { flags.contains(.quicStatelessResetDuringPathProbe) }
        set {
            if newValue {
                flags.insert(.quicStatelessResetDuringPathProbe)
            } else {
                flags.remove(.quicStatelessResetDuringPathProbe)
            }
        }
    }
}
