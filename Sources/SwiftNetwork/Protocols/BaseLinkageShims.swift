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

// The base linkages the framework's own stack is built from, to use when
// running the base protocols directly.

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramUpper: InboundDatagramLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = BaseDatagramLower

    var base: BaseInboundDatagramLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseInboundDatagramLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func invokeAttachLowerProtocol(_ lowerProtocol: BaseDatagramLower, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        try base.invokeAttachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.handleConnectedEvent(for: instance, in: &eventContext)
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramLower: OutboundDatagramLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = BaseDatagramUpper

    var base: BaseOutboundDatagramLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseOutboundDatagramLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func receiveDatagrams(maximumDatagramCount: Int, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) -> FrameArray? {
        return try base.receiveDatagrams(maximumDatagramCount: maximumDatagramCount, for: instance, in: &eventContext)
    }

    public func getDatagramsToSend(maximumDatagramCount: Int, minimumDatagramSize: Int, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) -> FrameArray? {
        return try base.getDatagramsToSend(maximumDatagramCount: maximumDatagramCount, minimumDatagramSize: minimumDatagramSize, for: instance, in: &eventContext)
    }

    public func sendDatagrams(_ datagrams: consuming FrameArray, from instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        try base.sendDatagrams(datagrams, from: instance, in: &eventContext)
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        return base.isConnected(in: &eventContext)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.connect(for: instance, in: &eventContext)
    }

    public func disconnect(error: NetworkError?, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.disconnect(error: error, for: instance, in: &eventContext)
    }

    public func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        try base.detach(for: instance, in: &eventContext)
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        base.teardown(in: &eventContext)
    }

    public func handleApplicationEvent(event: ApplicationEvent, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    public func getMetadata<P: NetworkProtocol>(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) -> ProtocolMetadata<P>? {
        return base.getMetadata(for: instance, in: &eventContext)
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        return base.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
    }

    public func invokeAttachUpperProtocol(_ upperProtocol: BaseDatagramUpper, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        try base.invokeAttachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramListener: DatagramListenerLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = BaseDatagramInboundFlow

    var base: BaseDatagramListenerLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseDatagramListenerLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func invokeAttachUpperProtocol(_ upperProtocol: PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        try base.invokeAttachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func invokeAttachUpperProtocolToNewFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        try base.invokeAttachUpperProtocolToNewFlow(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func invokeAttachUpperProtocolToExistingFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, existingFlowInstance: InstanceIdentifier) throws(NetworkError) -> PairedUpperLinkage.DataLinkage {
        return try base.invokeAttachUpperProtocolToExistingFlow(upperProtocol, existingFlowInstance: existingFlowInstance)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.connect(for: instance, in: &eventContext)
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.disconnect(error: error, for: instance, in: &eventContext)
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try base.detach(for: instance, in: &eventContext)
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        base.teardown(in: &eventContext)
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        return base.getMetadata(for: instance, in: &eventContext)
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        return base.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramInboundFlow: InboundDatagramFlowLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = BaseDatagramListener
    public typealias DataLinkage = BaseDatagramLower

    var base: BaseInboundDatagramFlowLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseInboundDatagramFlowLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func invokeAttachLowerProtocol(_ lowerProtocol: BaseDatagramListener, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        try base.invokeAttachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.handleConnectedEvent(for: instance, in: &eventContext)
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleNewInboundFlowEvent(flowInstance: flowInstance, flowMetadata: flowMetadata, for: instance, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseDatagramMultipath: DatagramMultipathLinkage, @unchecked Sendable {
    public typealias MultipathLowerProtocol = BaseDatagramLower

    var base: BaseDatagramMultipathLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseDatagramMultipathLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }


    public func invokeAttachLowerProtocolForNewPath(
        _ lowerProtocol: MultipathLowerProtocol,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try base.invokeAttachLowerProtocolForNewPath(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamUpper: InboundStreamLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = BaseStreamLower

    var base: BaseInboundStreamLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseInboundStreamLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamLower,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try base.invokeAttachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.handleConnectedEvent(for: instance, in: &eventContext)
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }

    public func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
    }

    public func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamLower: OutboundStreamLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = BaseStreamUpper

    var base: BaseOutboundStreamLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseOutboundStreamLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        return try base.receiveStreamData(minimumBytes: minimumBytes, maximumBytes: maximumBytes, for: instance, in: &eventContext)
    }

    public func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        return try base.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
    }

    public func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try base.sendStreamData(streamData, from: instance, in: &eventContext)
    }

    public func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try base.sendEarlyStreamData(streamData, from: instance, in: &eventContext)
    }

    public func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try base.abortInbound(error: error, for: instance, in: &eventContext)
    }

    public func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try base.abortOutbound(error: error, for: instance, in: &eventContext)
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        return base.isConnected(in: &eventContext)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.connect(for: instance, in: &eventContext)
    }

    public func disconnect(error: NetworkError?, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.disconnect(error: error, for: instance, in: &eventContext)
    }

    public func detach(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) throws(NetworkError) {
        try base.detach(for: instance, in: &eventContext)
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        base.teardown(in: &eventContext)
    }

    public func handleApplicationEvent(event: ApplicationEvent, for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    public func getMetadata<P: NetworkProtocol>(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) -> ProtocolMetadata<P>? {
        return base.getMetadata(for: instance, in: &eventContext)
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        return base.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: BaseStreamUpper,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try base.invokeAttachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamListener: StreamListenerLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = BaseStreamInboundFlow

    var base: BaseStreamListenerLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseStreamListenerLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: PairedUpperLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try base.invokeAttachUpperProtocol(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func invokeAttachUpperProtocolToNewFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, remote: Endpoint?, local: Endpoint?, parameters: Parameters?, path: PathProperties?) throws(NetworkError) {
        try base.invokeAttachUpperProtocolToNewFlow(upperProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func invokeAttachUpperProtocolToExistingFlow(_ upperProtocol: PairedUpperLinkage.DataLinkage.PairedUpperLinkage, existingFlowInstance: InstanceIdentifier) throws(NetworkError) -> PairedUpperLinkage.DataLinkage {
        return try base.invokeAttachUpperProtocolToExistingFlow(upperProtocol, existingFlowInstance: existingFlowInstance)
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.connect(for: instance, in: &eventContext)
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.disconnect(error: error, for: instance, in: &eventContext)
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        try base.detach(for: instance, in: &eventContext)
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        base.teardown(in: &eventContext)
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        return base.getMetadata(for: instance, in: &eventContext)
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        return base.getMetrics(requestedNetworkMetric: requestedNetworkMetric, for: instance, in: &eventContext)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct BaseStreamInboundFlow: InboundStreamFlowLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = BaseStreamListener
    public typealias DataLinkage = BaseStreamLower

    var base: BaseInboundStreamFlowLinkage<BaseLinkageFamilyGroup>

    public init() { base = .init() }

    init(base: BaseInboundStreamFlowLinkage<BaseLinkageFamilyGroup>) { self.base = base }

    public var identifier: InstanceIdentifier { base.identifier }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamListener,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try base.invokeAttachLowerProtocol(lowerProtocol, remote: remote, local: local, parameters: parameters, path: path)
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        base.handleConnectedEvent(for: instance, in: &eventContext)
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleNewInboundFlowEvent(flowInstance: flowInstance, flowMetadata: flowMetadata, for: instance, in: &eventContext)
    }
}
