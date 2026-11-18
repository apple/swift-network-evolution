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

#if canImport(SwiftNetwork)
#if !NETWORK_EMBEDDED

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramFlow: ~Copyable, MultiplexedDatapathFlow, AutomaticUpperDatagramProcessing {
    public typealias ParentProtocol = TestMultiplexingProtocol
    public typealias UpperProtocol = TestDatagramLinkageFamily.Upper

    var base: MultiplexedDatagramFlow<TestMultiplexingProtocol, TestDatagramLinkageFamily.Upper>

    public init(parent: TestMultiplexingProtocol, inbound: Bool) {
        base = MultiplexedDatagramFlow(parent: parent, inbound: inbound)
    }

    public init(parent: TestMultiplexingProtocol, inbound: Bool, in eventContext: inout NetworkContext.EventContext) {
        base = MultiplexedDatagramFlow(parent: parent, inbound: inbound, in: &eventContext)
    }

    public var parentProtocol: TestMultiplexingProtocol {
        get { base.parentProtocol }
        set { base.parentProtocol = newValue }
    }
    public var upper: TestDatagramLinkageFamily.Upper {
        get { base.upper }
        set { base.upper = newValue }
    }
    public var eventManager: ProtocolEventManager {
        _read { yield base.eventManager }
        _modify { yield &base.eventManager }
    }
    public var log: NetworkLoggerState {
        _read { yield base.log }
        _modify { yield &base.log }
    }
    public var upperSendQueue: FrameArray {
        _read { yield base.upperSendQueue }
        _modify { yield &base.upperSendQueue }
    }
    public var upperReceiveQueue: FrameArray {
        _read { yield base.upperReceiveQueue }
        _modify { yield &base.upperReceiveQueue }
    }
    public var maximumUpperDatagramSize: Int {
        get { base.maximumUpperDatagramSize }
        set { base.maximumUpperDatagramSize = newValue }
    }
    public var blockUpperSendQueue: Bool {
        get { base.blockUpperSendQueue }
        set { base.blockUpperSendQueue = newValue }
    }
    public var flowIdentifier: MultiplexedFlowIdentifier { base.flowIdentifier }
    public var identifier: InstanceIdentifier {
        get { base.identifier }
        set { base.identifier = newValue }
    }

    public func drainQueuedEventsForUpperProtocol(in eventContext: inout NetworkContext.EventContext) {
        base.drainQueuedEventsForUpperProtocol(in: &eventContext)
    }

    public mutating func serviceUpperSendQueue(in eventContext: inout NetworkContext.EventContext) {
        parentProtocol.serviceDatagramsToSend(
            borrowedFlow: flowIdentifier,
            sendQueue: &upperSendQueue,
            in: &eventContext
        )
    }

    // Hands back a linkage that routes to this flow, so its upper protocol can reach it. The
    // default implementation returns an empty linkage.
    public func asLowerLinkage() -> TestOutboundDatagramLinkage {
        TestOutboundDatagramLinkage(multiplexing: parentProtocol, flow: flowIdentifier, identifier: identifier)
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramPath: ~Copyable, MultiplexingDatapathPath, AutomaticLowerDatagramProcessing {
    public typealias ParentProtocol = TestMultiplexingProtocol
    public typealias LowerProtocol = TestDatagramLinkageFamily.Lower

    var base: MultiplexingDatagramPath<TestMultiplexingProtocol, TestDatagramLinkageFamily.Lower>

    public init(parent: TestMultiplexingProtocol, in eventContext: inout NetworkContext.EventContext) {
        base = MultiplexingDatagramPath(parent: parent, in: &eventContext)
    }

    public var parentProtocol: TestMultiplexingProtocol {
        get { base.parentProtocol }
        set { base.parentProtocol = newValue }
    }
    public var lower: TestDatagramLinkageFamily.Lower {
        get { base.lower }
        set { base.lower = newValue }
    }
    public var eventManager: ProtocolEventManager {
        _read { yield base.eventManager }
        _modify { yield &base.eventManager }
    }
    public var pathIdentifier: MultiplexingPathIdentifier { base.pathIdentifier }
    public var lowerSendQueue: FrameArray {
        _read { yield base.lowerSendQueue }
        _modify { yield &base.lowerSendQueue }
    }
    public var lowerReceiveQueue: FrameArray {
        _read { yield base.lowerReceiveQueue }
        _modify { yield &base.lowerReceiveQueue }
    }
    public var pathIsPrimary: Bool {
        get { base.pathIsPrimary }
        set { base.pathIsPrimary = newValue }
    }
    public var pathHasMigrationInfo: Bool {
        get { base.pathHasMigrationInfo }
        set { base.pathHasMigrationInfo = newValue }
    }
    public var identifier: InstanceIdentifier {
        get { base.identifier }
        set { base.identifier = newValue }
    }

    public mutating func serviceLowerReceiveQueue(in eventContext: inout NetworkContext.EventContext) {
        base.serviceLowerReceiveQueue(in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailable(in eventContext: inout NetworkContext.EventContext) {
        base.handleOutboundRoomAvailable(in: &eventContext)
    }

    public mutating func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    public mutating func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        base.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }

    // Hands back a linkage that routes to this path, so its lower protocol can deliver events to
    // it. The path is found in the protocol's table by its identifier.
    public func asUpperLinkage() -> TestInboundDatagramLinkage {
        TestInboundDatagramLinkage(multiplexing: parentProtocol, path: pathIdentifier, identifier: identifier)
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public final class TestMultiplexingProtocol: ManyToManyApplicationDatagramProtocol, ManyToManyOutboundDatagramProtocol,
    DatagramListenerHandler, HomogeneousManyToManyProtocolHandler
{
    public typealias UpperProtocol = TestDatagramLinkageFamily.InboundFlow

    public var inboundFlowLinkage = UpperProtocol()
    public var asListener: TestDatagramLinkageFamily.Listener { .init(multiplexing: self) }

    public var delayConnected = false

    public typealias Flow = TestDatagramFlow
    public typealias Path = TestDatagramPath

    public func setup(
        flow: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {

    }

    public private(set) var context: NetworkContext
    public init(context: NetworkContext) {
        self.context = context
        self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
    }

    public var identifier: InstanceIdentifier
    public var log = NetworkLoggerState()
    public var eventManager = ProtocolEventManager()

    public var multiplexedFlows = MultiplexedFlowTable<Flow>()

    public func withMultiplexedFlows<R: ~Copyable, E: Error>(
        _ body: (inout MultiplexedFlowTable<Flow>) throws(E) -> R
    ) throws(E) -> R {
        try body(&multiplexedFlows)
    }

    public func insertFlow(_ flow: consuming Flow, for flowID: MultiplexedFlowIdentifier) {
        multiplexedFlows.insert(flow, for: flowID)
    }

    public var multiplexedPaths = MultiplexedPathTable<Path>()

    var isPathBorrowed = false

    public func withUnborrowedPaths<R: ~Copyable, E: Error>(
        _ body: (inout MultiplexedPathTable<Path>) throws(E) -> R
    ) throws(E) -> R? {
        guard !isPathBorrowed else { return nil }
        isPathBorrowed = true
        defer { isPathBorrowed = false }
        return try body(&multiplexedPaths)
    }

    public func insertPath(_ path: consuming Path, for pathID: MultiplexingPathIdentifier) {
        multiplexedPaths.insert(path, for: pathID)
    }

    public func serviceDatagramsToSend(
        flow: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Multiplexing protocol asked to service datagrams to send from flow \(flow.debugDescription)")
        guard let path = somePathIdentifier else {
            return
        }
        // Take the datagrams out while the flow is borrowed, and send them once it is not: sending
        // can reach back into the flow table.
        var drained: FrameArray? = nil
        accessDatagramsToSend(flow: flow) { frames in
            drained = frames.drainArray()
        }
        guard let datagrams = drained.take() else { return }
        forwardDatagrams(datagrams, onPath: path, in: &eventContext)
    }

    // The flow is borrowed, so its queue is handed in and nothing here looks a flow up. The datagrams go to
    // the path, which has a table of its own.
    public func serviceDatagramsToSend(
        borrowedFlow flow: MultiplexedFlowIdentifier,
        sendQueue: inout FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug(
            "Multiplexing protocol asked to service datagrams to send from borrowed flow \(flow.debugDescription)"
        )
        guard let path = somePathIdentifier else {
            return
        }
        forwardDatagrams(sendQueue.drainArray(), onPath: path, in: &eventContext)
    }

    private func forwardDatagrams(
        _ datagrams: consuming FrameArray,
        onPath path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // The event context is already held here, so use the `in:`-taking variants rather than the
        // external entry points, which would re-derive it.
        try? enqueueOutboundDatagrams(path: path, datagrams: datagrams)
        try? sendEnqueuedOutboundDatagrams(path: path, in: &eventContext)
    }

    /// How many times the protocol was asked to service the datagrams received on a path, and how many of
    /// those times there were none to service. A path should only ask when it has something.
    public private(set) var receivedServicePasses = 0
    public private(set) var emptyReceivedServicePasses = 0

    public func serviceReceivedDatagrams(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Multiplexing protocol asked to service received datagrams on path \(path.description)")
        receivedServicePasses += 1
        var wasEmpty = false
        accessReceivedDatagrams(path: path) { frames in wasEmpty = frames.isEmpty }
        if wasEmpty {
            emptyReceivedServicePasses += 1
        }
        guard let flow = someFlowIdentifier else {
            return
        }
        accessReceivedDatagrams(path: path) { frames in
            try? deliverInboundDatagrams(
                flow: flow,
                datagrams: frames.drainArray(),
                in: &eventContext
            )
        }
    }

    public func handleInboundDataAvailableEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Multiplexing protocol inbound data available for path \(path.description)")
    }

    public func handleOutboundRoomAvailableEvent(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Multiplexing protocol outbound room available for path \(path.description)")
    }

    // FROM LISTENER
    public func connect(in eventContext: inout NetworkContext.EventContext) {
        log.debug("Multiplexing protocol connect for listener")
        if !delayConnected {
            deliverConnectedEvent(flow: .allFlows, in: &eventContext)
        }
    }

    // FROM LISTENER
    public func disconnect(error: NetworkError?, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Multiplexing protocol disconnect for listener")

    }

    // FROM FLOW
    public func connect(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Multiplexing protocol connect for flow \(flow.debugDescription)")

        if !delayConnected {
            deliverConnectedEvent(flow: flow, in: &eventContext)
        }
    }

    // FROM FLOW
    public func disconnect(flow: MultiplexedFlowIdentifier) {
        log.debug("Multiplexing protocol disconnect for flow \(flow.debugDescription)")
    }

    public func teardown(flow: MultiplexedFlowIdentifier, in eventContext: inout NetworkContext.EventContext) {
        log.debug("Multiplexing protocol teardown for flow \(flow.debugDescription)")
    }

    public func getMetadata<P>(flow: MultiplexedFlowIdentifier) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        nil
    }

    public func handleConnectedEvent(path: MultiplexingPathIdentifier) {
        log.debug("Multiplexing protocol connected for path \(path.description)")
    }

    public func handleDisconnectedEvent(path: MultiplexingPathIdentifier, error: NetworkError?) {
        log.debug("Multiplexing protocol disconnected connected for path \(path.description)")
    }

    public func triggerNewFlowCreation() {
        log.debug("Multiplexing protocol creating a new inbound flow")
        fromExternal { eventContext in
            let newFlow = Flow(parent: self, inbound: true, in: &eventContext)
            let newFlowIdentifier = newFlow.flowIdentifier
            let newFlowInstance = newFlow.identifier
            insertFlow(newFlow, for: newFlowIdentifier)
            deliverNewInboundFlowEvent(newFlowInstance, flowMetadata: nil, in: &eventContext)
        }
    }

    public func triggerConnected() {
        log.debug("Multiplexing protocol triggering connected event")
        fromExternal { eventContext in
            delayConnected = false
            deliverConnectedEvent(flow: .allFlows, in: &eventContext)
        }
    }
}

#endif  // !NETWORK_EMBEDDED
