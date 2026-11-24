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
public enum RequestedNetworkMetrics {
    case protocolEstablishmentReports
    case dataTransferSnapshot
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum NetworkMetrics {
    case protocolEstablishmentReports([ProtocolEstablishmentReport])
    case dataTransferSnapshot(DataTransferSnapshot)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol NetworkMetricsProviding: ~Copyable {
    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics?
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension NetworkMetricsProviding where Self: ~Copyable {
    /// The data transfer snapshot, or nil if the instance did not answer with one.
    public func getDataTransferSnapshot(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> DataTransferSnapshot? {
        getMetrics(requestedNetworkMetric: .dataTransferSnapshot, for: instance, in: &eventContext)?
            .dataTransferSnapshot
    }

    /// The protocol establishment reports, or nil if the instance did not answer with them.
    public func getProtocolEstablishmentReports(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> [ProtocolEstablishmentReport]? {
        getMetrics(requestedNetworkMetric: .protocolEstablishmentReports, for: instance, in: &eventContext)?
            .protocolEstablishmentReports
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension NetworkMetrics {
    /// The data transfer snapshot, if this answers a `.dataTransferSnapshot` request.
    public var dataTransferSnapshot: DataTransferSnapshot? {
        guard case .dataTransferSnapshot(let snapshot) = self else { return nil }
        return snapshot
    }

    /// The protocol establishment reports, if this answers a `.protocolEstablishmentReports` request.
    public var protocolEstablishmentReports: [ProtocolEstablishmentReport]? {
        guard case .protocolEstablishmentReports(let reports) = self else { return nil }
        return reports
    }
}
