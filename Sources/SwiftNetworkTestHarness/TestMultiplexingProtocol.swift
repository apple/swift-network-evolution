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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(TestHarness)
@available(Network 0.1.0, *)
public final class TestDatagramFlow: MultiplexedDatagramFlow<TestMultiplexingProtocol, TestDatagramLinkageFamily.Upper>
{
    // Hands back a linkage that routes to this flow, so its upper protocol can reach it. The
    // default implementation returns an empty linkage.
    public override func asLowerLinkage() -> TestOutboundDatagramLinkage {
        TestOutboundDatagramLinkage(flow: self)
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public final class TestDatagramPath: MultiplexingDatagramPath<TestMultiplexingProtocol, TestDatagramLinkageFamily.Lower>
{
    // Hands back a linkage that routes to this path, so its lower protocol can deliver events to
    // it. The default implementation returns an empty linkage.
    public override func asUpperLinkage() -> TestInboundDatagramLinkage {
        TestInboundDatagramLinkage(path: self)
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

    public var multiplexedFlows = [MultiplexedFlowIdentifier: TestDatagramFlow]()
    public var multiplexingPaths = [MultiplexingPathIdentifier: TestDatagramPath]()

    public func serviceDatagramsToSend(
        flow: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Multiplexing protocol asked to service datagrams to send from flow \(flow.debugDescription)")
        guard let path = somePathIdentifier else {
            return
        }
        accessDatagramsToSend(flow: flow) { frames in
            // The event context is already held here, so use the `in:`-taking variants rather than the
            // external entry points, which would re-derive it.
            try? enqueueOutboundDatagrams(path: path, datagrams: frames.drainArray())
            try? sendEnqueuedOutboundDatagrams(path: path, in: &eventContext)
        }
    }

    public func serviceReceivedDatagrams(
        path: MultiplexingPathIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        log.debug("Multiplexing protocol asked to service received datagrams on path \(path.description)")
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
            multiplexedFlows[newFlow.flowIdentifier] = newFlow
            deliverNewInboundFlowEvent(newFlow.identifier, flowMetadata: nil, in: &eventContext)
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
