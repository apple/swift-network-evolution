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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
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

@available(Network 0.1.0, *)
final class TestDatagramFlow: MultiplexedDatagramFlow<TestMultiplexingProtocol> {

}

@available(Network 0.1.0, *)
final class TestDatagramPath: MultiplexingDatagramPath<TestMultiplexingProtocol> {

}

@available(Network 0.1.0, *)
final class TestMultiplexingProtocol: ManyToManyApplicationDatagramProtocol, ManyToManyOutboundDatagramProtocol,
    DatagramListenerHandler, HomogeneousManyToManyProtocolHandler, ProtocolInstanceContainer
{
    typealias UpperProtocol = InboundDatagramFlowLinkage

    var inboundFlowLinkage = UpperProtocol.init()
    var asListener: UpperProtocol.PairedLinkage { .init(reference: reference) }

    var delayConnected = false

    typealias Flow = TestDatagramFlow
    typealias Path = TestDatagramPath

    func setup(
        flow: MultiplexedFlowIdentifier,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {

    }

    public private(set) var context: NetworkContext
    init(context: NetworkContext) { self.context = context }

    var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    var log = NetworkLoggerState()
    var eventManager = ProtocolEventManager()

    var multiplexedFlows = [MultiplexedFlowIdentifier: TestDatagramFlow]()
    var multiplexingPaths = [MultiplexingPathIdentifier: TestDatagramPath]()

    func serviceDatagramsToSend(flow: MultiplexedFlowIdentifier) {
        log.debug("Multiplexing protocol asked to service datagrams to send from flow \(flow.debugDescription)")
        guard let path = somePathIdentifier else {
            return
        }
        accessDatagramsToSend(flow: flow) { frames in
            try? enqueueOutboundDatagrams(path: path, datagrams: frames.drainArray())
            try? sendEnqueuedOutboundDatagrams(path: path)
        }
    }

    func serviceReceivedDatagrams(path: MultiplexingPathIdentifier) {
        log.debug("Multiplexing protocol asked to service received datagrams on path \(path.description)")
        guard let flow = someFlowIdentifier else {
            return
        }
        accessReceivedDatagrams(path: path) { frames in
            try? deliverInboundDatagrams(flow: flow, datagrams: frames.drainArray())
        }
    }

    func handleInboundDataAvailableEvent(path: MultiplexingPathIdentifier) {
        log.debug("Multiplexing protocol inbound data available for path \(path.description)")
    }

    func handleOutboundRoomAvailableEvent(path: MultiplexingPathIdentifier) {
        log.debug("Multiplexing protocol outbound room available for path \(path.description)")
    }

    // FROM LISTENER
    func connect() {
        log.debug("Multiplexing protocol connect for listener")
        if !delayConnected {
            deliverConnectedEvent(flow: .allFlows)
        }
    }

    // FROM LISTENER
    func disconnect(error: NetworkError?) {
        log.debug("Multiplexing protocol disconnect for listener")

    }

    // FROM FLOW
    func connect(flow: MultiplexedFlowIdentifier) {
        log.debug("Multiplexing protocol connect for flow \(flow.debugDescription)")

        if !delayConnected {
            deliverConnectedEvent(flow: flow)
        }
    }

    // FROM FLOW
    func disconnect(flow: MultiplexedFlowIdentifier) {
        log.debug("Multiplexing protocol disconnect for flow \(flow.debugDescription)")
    }

    func teardown(flow: MultiplexedFlowIdentifier) {
        log.debug("Multiplexing protocol teardown for flow \(flow.debugDescription)")
    }

    func getMetadata<P>(flow: MultiplexedFlowIdentifier) -> ProtocolMetadata<P>? where P: NetworkProtocol {
        nil
    }

    func handleConnectedEvent(path: MultiplexingPathIdentifier) {
        log.debug("Multiplexing protocol connected for path \(path.description)")
    }

    func handleDisconnectedEvent(path: MultiplexingPathIdentifier, error: NetworkError?) {
        log.debug("Multiplexing protocol disconnected connected for path \(path.description)")
    }

    func triggerNewFlowCreation() {
        log.debug("Multiplexing protocol creating a new inbound flow")
        fromExternal {
            let newFlow = Flow(parent: self, inbound: true)
            multiplexedFlows[newFlow.identifier] = newFlow
            deliverNewInboundFlowEvent(newFlow.reference, flowMetadata: nil)
        }
    }

    func triggerConnected() {
        log.debug("Multiplexing protocol triggering connected event")
        fromExternal {
            delayConnected = false
            deliverConnectedEvent(flow: .allFlows)
        }
    }
}
