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
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// A linkage family group defined outside the main package.
//
// This is the extension point the base linkages are designed for: a client of the framework can
// define its own protocols and wire them into a stack without the framework knowing about them.
//
// `TestLinkageFamilyGroup` is the single generic parameter the whole stack is built from. Its
// datagram and stream families name the `Test*` linkages below, and each of those holds the
// matching `Base*Linkage<TestLinkageFamilyGroup>` alongside cases for the protocols only this
// module knows about -- the harnesses and the test multiplexing protocol. Anything a `Test*` enum
// doesn't name falls through to the held base linkage, so every framework protocol keeps working.
// Wrapping a struct in a struct is essentially free.
//
// `TestNetworkProtocolStorage` subclasses `BaseNetworkProtocolStorageParent`, so it inherits every
// framework protocol factory and only adds the test-only ones.

@_spi(TestHarness)
@available(Network 0.1.0, *)
public final class TestNetworkProtocolStorage:
    BaseNetworkProtocolStorageParent<TestLinkageFamilyGroup> {

    // A true subclass: every framework protocol -- UDP, IP, demux, TCP, the sockets, the bridges,
    // and QUIC -- is inherited, so this only adds factories for the protocols the framework does
    // not know about.

    // The harnesses, built against the test families and held here to keep them alive for the
    // lifetime of the storage.
    private var datagramUpperHarnessesForTest = [DatagramUpperHarness<TestDatagramLinkageFamily>]()
    private var datagramLowerHarnessesForTest = [DatagramLowerHarness<TestDatagramLinkageFamily>]()
    private var newDatagramFlowHarnessesForTest = [NewDatagramFlowHarness<TestDatagramLinkageFamily>]()

    public func createTestDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> DatagramUpperHarness<TestDatagramLinkageFamily> {
        let instance = DatagramUpperHarness<TestDatagramLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        datagramUpperHarnessesForTest.append(instance)
        return instance
    }

    /// Creates an upper harness using an event context the caller already holds. The new-inbound-
    /// flow event runs inline with the state held, so registering there has to use this.
    public func createTestDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) -> DatagramUpperHarness<TestDatagramLinkageFamily> {
        let instance = DatagramUpperHarness<TestDatagramLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context,
            in: &eventContext
        )
        datagramUpperHarnessesForTest.append(instance)
        return instance
    }

    public func createTestDatagramLowerHarness(
        identifier: String = ""
    ) -> DatagramLowerHarness<TestDatagramLinkageFamily> {
        let instance = DatagramLowerHarness<TestDatagramLinkageFamily>(
            identifier: identifier,
            context: context
        )
        datagramLowerHarnessesForTest.append(instance)
        return instance
    }

    public func createTestNewDatagramFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> NewDatagramFlowHarness<TestDatagramLinkageFamily> {
        let instance = NewDatagramFlowHarness<TestDatagramLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        ) { [self] state in
            let inbound = createTestDatagramUpperHarness(
                identifier: "Inbound",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                in: &state
            )
            return (inbound, TestInboundDatagramLinkage(harness: inbound))
        }
        newDatagramFlowHarnessesForTest.append(instance)
        return instance
    }

    public func createTestMultiplexingInstance() -> (
        listener: TestDatagramListenerLinkage,
        multipath: TestDatagramMultipathLinkage,
        instance: TestMultiplexingProtocol
    ) {
        let instance = TestMultiplexingProtocol(context: context)
        return (
            listener: TestDatagramListenerLinkage(multiplexing: instance),
            multipath: TestDatagramMultipathLinkage(multiplexing: instance),
            instance: instance
        )
    }

    // MARK: - Stream harnesses

    private var streamUpperHarnessesForTest = [StreamUpperHarness<TestStreamLinkageFamily>]()
    private var streamLowerHarnessesForTest = [StreamLowerHarness<TestStreamLinkageFamily>]()
    private var newStreamFlowHarnessesForTest = [NewStreamFlowHarness<TestStreamLinkageFamily>]()

    public func createTestStreamUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> StreamUpperHarness<TestStreamLinkageFamily> {
        let instance = StreamUpperHarness<TestStreamLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        streamUpperHarnessesForTest.append(instance)
        return instance
    }

    /// Creates an upper harness using an event context the caller already holds. The new-inbound-
    /// flow event runs inline with the state held, so registering there has to use this.
    public func createTestStreamUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) -> StreamUpperHarness<TestStreamLinkageFamily> {
        let instance = StreamUpperHarness<TestStreamLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context,
            in: &eventContext
        )
        streamUpperHarnessesForTest.append(instance)
        return instance
    }

    public func createTestStreamLowerHarness(
        identifier: String = ""
    ) -> StreamLowerHarness<TestStreamLinkageFamily> {
        let instance = StreamLowerHarness<TestStreamLinkageFamily>(
            identifier: identifier,
            context: context
        )
        streamLowerHarnessesForTest.append(instance)
        return instance
    }

    public func createTestNewStreamFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> NewStreamFlowHarness<TestStreamLinkageFamily> {
        let instance = NewStreamFlowHarness<TestStreamLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        ) { [self] state in
            let inbound = createTestStreamUpperHarness(
                identifier: "Inbound",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                in: &state
            )
            return (inbound, TestInboundStreamLinkage(harness: inbound))
        }
        newStreamFlowHarnessesForTest.append(instance)
        return instance
    }


}

// MARK: - Datagram linkage families

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramLinkageFamily: DatagramLinkageFamily {
    public typealias Upper = TestInboundDatagramLinkage
    public typealias Lower = TestOutboundDatagramLinkage
    public typealias Listener = TestDatagramListenerLinkage
    public typealias InboundFlow = TestInboundDatagramFlowLinkage
}

// MARK: - Inbound datagram linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundDatagramLinkage: InboundDatagramLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestOutboundDatagramLinkage

    // Protocols this module knows about. `base` is the fall-through for everything the
    // framework provides.
    public enum ProtocolType {
        case base
        case datagramUpperHarness(DatagramUpperHarness<TestDatagramLinkageFamily>)
        // A path on the multiplexing protocol: this is what the path hands back from
        // `asUpperLinkage()` so its lower protocol can deliver events to it.
        case multiplexingPath(TestDatagramPath)
        // Framework protocols, held by the test storage and typed to the test families so a
        // harness can be their upper. Reached by index, like the base storage does.
    }

    public let base: BaseInboundDatagramLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let harnessInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(base: BaseInboundDatagramLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(harness: DatagramUpperHarness<TestDatagramLinkageFamily>) {
        self.base = .init()
        self.protocolType = .datagramUpperHarness(harness)
        self.harnessInstance = harness.identifier
    }

    public init(path: TestDatagramPath) {
        self.base = .init()
        self.protocolType = .multiplexingPath(path)
        self.harnessInstance = path.identifier
    }


    public var identifier: InstanceIdentifier { harnessInstance ?? base.identifier }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: TestOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexingPath(let path):
            // The path's lower is bound when the path is created, so there is nothing more to do.
            _ = path
        case .datagramUpperHarness(let harness):
            var harness = harness
            let overrideUpper = try harness.attachLowerProtocol(lowerProtocol)
            try lowerProtocol.invokeAttachUpperProtocol(
                overrideUpper ?? self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            // Not a test protocol, so hand the whole call to the wrapped base linkage. Both sides
            // are base linkages here, so it completes the pairing itself.
            try base.invokeAttachLowerProtocol(
                lowerProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .multiplexingPath(let path):
            path.handleConnectedEvent(for: instance, in: &eventContext)
        case .datagramUpperHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        default: base.handleConnectedEvent(for: instance, in: &eventContext)
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexingPath(let path):
            path.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .datagramUpperHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        default: base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexingPath(let path):
            var path = path
            path.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .datagramUpperHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        default: base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexingPath(let path):
            var path = path
            path.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .datagramUpperHarness(let harness): harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        default: base.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        }
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexingPath(let path):
            var path = path
            path.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .datagramUpperHarness(let harness): harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        default: base.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Outbound datagram linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestOutboundDatagramLinkage: OutboundDatagramLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundDatagramLinkage

    public enum ProtocolType {
        case base
        case datagramLowerHarness(DatagramLowerHarness<TestDatagramLinkageFamily>)
        // A flow on the multiplexing protocol: this is what the flow hands back from
        // `asLowerLinkage()` so its upper protocol can talk to it.
        case multiplexedFlow(TestDatagramFlow)
    }

    public let base: BaseOutboundDatagramLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let harnessInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(base: BaseOutboundDatagramLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(harness: DatagramLowerHarness<TestDatagramLinkageFamily>) {
        self.base = .init()
        self.protocolType = .datagramLowerHarness(harness)
        self.harnessInstance = harness.identifier
    }

    public init(flow: TestDatagramFlow) {
        self.base = .init()
        self.protocolType = .multiplexedFlow(flow)
        self.harnessInstance = flow.identifier
    }


    public var identifier: InstanceIdentifier {
        harnessInstance ?? base.identifier
    }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        case .datagramLowerHarness, .multiplexedFlow:
            return identifier.isConnected(in: &eventContext)
        default: return base.protocolIsConnected(in: &eventContext)
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: TestInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexedFlow:
            // `attachUpperProtocolToNewFlow` binds the upper when it creates the flow, so there
            // is nothing more to do here.
            break
        case .datagramLowerHarness(let harness):
            var harness = harness
            try harness.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try base.invokeAttachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .multiplexedFlow(let flow):
            var flow = flow
            return try flow.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        case .datagramLowerHarness(let harness):
            var harness = harness
            return try harness.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        default:
            return try base.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        }
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .multiplexedFlow(let flow):
            return try flow.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        case .datagramLowerHarness(let harness):
            var harness = harness
            return try harness.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        default:
            return try base.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        }
    }

    public func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexedFlow(let flow):
            var flow = flow
            try flow.sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            var harness = harness
            try harness.sendDatagrams(datagrams, from: instance, in: &eventContext)
        default: try base.sendDatagrams(datagrams, from: instance, in: &eventContext)
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .multiplexedFlow(let flow): flow.connect(for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness): harness.connect(for: instance, in: &eventContext)
        default: base.connect(for: instance, in: &eventContext)
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexedFlow(let flow): flow.disconnect(error: error, for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            harness.disconnect(error: error, for: instance, in: &eventContext)
        default: base.disconnect(error: error, for: instance, in: &eventContext)
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexedFlow(let flow):
            var flow = flow
            try flow.detach(for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            var harness = harness
            try harness.detach(for: instance, in: &eventContext)
        default: try base.detach(for: instance, in: &eventContext)
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .datagramLowerHarness(let harness): harness.unregisterEventManager(in: &eventContext)
        case .multiplexedFlow(let flow): flow.unregisterEventManager(in: &eventContext)
        default: base.teardown(in: &eventContext)
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexedFlow(let flow):
            flow.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness):
            harness.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .multiplexedFlow(let flow): return flow.getMetadata(for: instance, in: &eventContext)
        case .datagramLowerHarness(let harness): return harness.getMetadata(for: instance, in: &eventContext)
        default: return base.getMetadata(for: instance, in: &eventContext)
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .datagramLowerHarness, .multiplexedFlow:
            // These hold their instance here rather than in `base`, whose linkage is empty, so
            // they must not fall through: the base implementation force-unwraps its storage.
            return nil
        default:
            return base.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Inbound datagram flow linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundDatagramFlowLinkage: InboundDatagramFlowLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestDatagramListenerLinkage
    public typealias DataLinkage = TestOutboundDatagramLinkage

    public enum ProtocolType {
        case base
        case newDatagramFlowHarness(NewDatagramFlowHarness<TestDatagramLinkageFamily>)
    }

    public let base: BaseInboundDatagramFlowLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let harnessInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(base: BaseInboundDatagramFlowLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(harness: NewDatagramFlowHarness<TestDatagramLinkageFamily>) {
        self.base = .init()
        self.protocolType = .newDatagramFlowHarness(harness)
        self.harnessInstance = harness.identifier
    }

    public var identifier: InstanceIdentifier { harnessInstance ?? base.identifier }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: TestDatagramListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .newDatagramFlowHarness(let harness):
            _ = try harness.attachLowerProtocol(lowerProtocol)
            try lowerProtocol.attachInboundFlow(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try lowerProtocol.attachInboundFlow(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .newDatagramFlowHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        default: base.handleConnectedEvent(for: instance, in: &eventContext)
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .newDatagramFlowHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        default: base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .newDatagramFlowHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        default: base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .newDatagramFlowHarness(let harness):
            harness.handleNewInboundFlowEvent(
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                for: instance,
                in: &eventContext
            )
        default:
            base.handleNewInboundFlowEvent(
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                for: instance,
                in: &eventContext
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Datagram listener linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramListenerLinkage: DatagramListenerLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundDatagramFlowLinkage

    public enum ProtocolType {
        case base
        case multiplexing(TestMultiplexingProtocol)
    }

    public let base: BaseDatagramListenerLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let multiplexingInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.multiplexingInstance = nil
    }

    public init(base: BaseDatagramListenerLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.multiplexingInstance = nil
    }

    public init(multiplexing instance: TestMultiplexingProtocol) {
        self.base = .init()
        self.protocolType = .multiplexing(instance)
        self.multiplexingInstance = instance.identifier
    }

    public var identifier: InstanceIdentifier {
        multiplexingInstance ?? base.identifier
    }

    // Binds an inbound-flow observer to the listener. Called from the upper linkage so both
    // directions end up bound.
    public func attachInboundFlow(
        _ upperProtocol: TestInboundDatagramFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexing(let instance):
            var instance = instance
            try instance.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try base.invokeAttachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        case .multiplexing(let instance): return instance.isConnected(in: &eventContext)
        default: return base.protocolIsConnected(in: &eventContext)
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: TestInboundDatagramFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try attachInboundFlow(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    public func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: TestInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexing(let instance):
            var instance = instance
            let flowLower = try instance.attachUpperProtocolToNewFlow(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            try upperProtocol.invokeAttachLowerProtocol(
                flowLower,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try base.invokeAttachUpperProtocolToNewFlow(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: TestInboundDatagramLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> TestOutboundDatagramLinkage {
        switch protocolType {
        case .multiplexing(let instance):
            var instance = instance
            return try instance.attachUpperProtocolToExistingFlow(
                upperProtocol,
                existingFlowInstance: existingFlowInstance
            )
        default:
            // The wrapped base linkage is specialized on this group, so it already hands back the
            // test family's own linkage -- no re-wrapping needed.
            return try base.invokeAttachUpperProtocolToExistingFlow(
                upperProtocol,
                existingFlowInstance: existingFlowInstance
            )
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .multiplexing(let protocolInstance): protocolInstance.connect(for: instance, in: &eventContext)
        default: base.connect(for: instance, in: &eventContext)
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexing(let protocolInstance): protocolInstance.disconnect(error: error, for: instance, in: &eventContext)
        default: base.disconnect(error: error, for: instance, in: &eventContext)
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexing(let protocolInstance):
            var protocolInstance = protocolInstance
            try protocolInstance.detach(for: instance, in: &eventContext)
        default: try base.detach(for: instance, in: &eventContext)
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .multiplexing: break
        default: base.teardown(in: &eventContext)
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .multiplexing(let protocolInstance):
            protocolInstance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .multiplexing(let protocolInstance): return protocolInstance.getMetadata(for: instance, in: &eventContext)
        default: return base.getMetadata(for: instance, in: &eventContext)
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .multiplexing: return nil
        default:
            return base.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Datagram multipath linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramMultipathLinkage: DatagramMultipathLinkage, @unchecked Sendable {
    public typealias MultipathLowerProtocol = TestOutboundDatagramLinkage

    public enum ProtocolType {
        case base
        case multiplexing(TestMultiplexingProtocol)
    }

    public let base: BaseDatagramMultipathLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let multiplexingInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.multiplexingInstance = nil
    }

    public init(base: BaseDatagramMultipathLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.multiplexingInstance = nil
    }

    public init(multiplexing instance: TestMultiplexingProtocol) {
        self.base = .init()
        self.protocolType = .multiplexing(instance)
        self.multiplexingInstance = instance.identifier
    }

    public var identifier: InstanceIdentifier {
        multiplexingInstance ?? base.identifier
    }

    public mutating func invokeAttachLowerProtocolForNewPath(
        _ lowerProtocol: TestOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .multiplexing(let instance):
            // The handler creates the path and returns the linkage representing it, which is then
            // bound as the lower protocol's upper side so both directions are connected.
            var instance = instance
            let pathUpper = try instance.fromExternal { eventContext throws(NetworkError) in
                try instance.attachLowerProtocolForNewPath(
                    lowerProtocol,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path,
                    in: &eventContext
                )
            }
            try lowerProtocol.invokeAttachUpperProtocol(
                pathUpper,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try base.invokeAttachLowerProtocolForNewPath(
                lowerProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Harness factories

// These mirror the factories the framework's storage used to provide, so call sites read the same
// as before the harnesses moved out of the package. Each returns the instance together with the
// linkage that reaches it, and takes `context:` for source compatibility even though the storage
// already holds the context it was built with.
@_spi(TestHarness)
@available(Network 0.1.0, *)
extension TestNetworkProtocolStorage {

    public func createDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (DatagramUpperHarness<TestDatagramLinkageFamily>, TestInboundDatagramLinkage) {
        let instance = createTestDatagramUpperHarness(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, TestInboundDatagramLinkage(harness: instance))
    }

    public func createDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        in eventContext: inout NetworkContext.EventContext
    ) -> (DatagramUpperHarness<TestDatagramLinkageFamily>, TestInboundDatagramLinkage) {
        let instance = createTestDatagramUpperHarness(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            in: &eventContext
        )
        return (instance, TestInboundDatagramLinkage(harness: instance))
    }

    public func createDatagramLowerHarness(
        identifier: String = "",
        context: NetworkContext
    ) -> (DatagramLowerHarness<TestDatagramLinkageFamily>, TestOutboundDatagramLinkage) {
        let instance = createTestDatagramLowerHarness(identifier: identifier)
        return (instance, TestOutboundDatagramLinkage(harness: instance))
    }

    public func createNewDatagramFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (NewDatagramFlowHarness<TestDatagramLinkageFamily>, TestInboundDatagramFlowLinkage) {
        let instance = createTestNewDatagramFlowHarness(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, TestInboundDatagramFlowLinkage(harness: instance))
    }

    public func createStreamUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (StreamUpperHarness<TestStreamLinkageFamily>, TestInboundStreamLinkage) {
        let instance = createTestStreamUpperHarness(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, TestInboundStreamLinkage(harness: instance))
    }

    public func createStreamLowerHarness(
        identifier: String = "",
        context: NetworkContext
    ) -> (StreamLowerHarness<TestStreamLinkageFamily>, TestOutboundStreamLinkage) {
        let instance = createTestStreamLowerHarness(identifier: identifier)
        return (instance, TestOutboundStreamLinkage(harness: instance))
    }

    public func createNewStreamFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (NewStreamFlowHarness<TestStreamLinkageFamily>, TestInboundStreamFlowLinkage) {
        let instance = createTestNewStreamFlowHarness(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, TestInboundStreamFlowLinkage(harness: instance))
    }
}

// MARK: - The test linkage family group

// The one generic parameter the whole test stack is built from. It names the two families below
// and, because `LinkageFamilyGroup` now subsumes what `QUICLinkageFamilies` used to express, says
// how to wrap a QUIC stream, datagram flow, or path in one of this stack's linkages.
@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestLinkageFamilyGroup: LinkageFamilyGroup {
    public typealias StreamFamily = TestStreamLinkageFamily
    public typealias DatagramFamily = TestDatagramLinkageFamily
    public typealias MultipathLinkageType = TestDatagramMultipathLinkage

    public static func linkage(
        for quicStream: QUICStreamInstance<TestLinkageFamilyGroup>
    ) -> TestOutboundStreamLinkage {
        .init(base: baseLinkage(forQUICStream: quicStream))
    }

    public static func linkage(
        for quicDatagramFlow: QUICDatagramFlow<TestLinkageFamilyGroup>
    ) -> TestOutboundDatagramLinkage {
        .init(base: baseLinkage(forQUICDatagramFlow: quicDatagramFlow))
    }

    public static func linkage(
        for quicPath: QUICPath<TestLinkageFamilyGroup>
    ) -> TestInboundDatagramLinkage {
        .init(base: baseLinkage(forQUICPath: quicPath))
    }

    // This group's families are the `Test*` wrappers, so lifting puts the wrapper back on.
    public static func family(
        for linkage: BaseInboundDatagramLinkage<TestLinkageFamilyGroup>
    ) -> TestInboundDatagramLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseInboundDatagramFlowLinkage<TestLinkageFamilyGroup>
    ) -> TestInboundDatagramFlowLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseInboundStreamLinkage<TestLinkageFamilyGroup>
    ) -> TestInboundStreamLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseInboundStreamFlowLinkage<TestLinkageFamilyGroup>
    ) -> TestInboundStreamFlowLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseOutboundDatagramLinkage<TestLinkageFamilyGroup>
    ) -> TestOutboundDatagramLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseDatagramListenerLinkage<TestLinkageFamilyGroup>
    ) -> TestDatagramListenerLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseDatagramMultipathLinkage<TestLinkageFamilyGroup>
    ) -> TestDatagramMultipathLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseOutboundStreamLinkage<TestLinkageFamilyGroup>
    ) -> TestOutboundStreamLinkage { .init(base: linkage) }

    public static func family(
        for linkage: BaseStreamListenerLinkage<TestLinkageFamilyGroup>
    ) -> TestStreamListenerLinkage { .init(base: linkage) }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestStreamLinkageFamily: StreamLinkageFamily {
    public typealias Upper = TestInboundStreamLinkage
    public typealias Lower = TestOutboundStreamLinkage
    public typealias Listener = TestStreamListenerLinkage
    public typealias InboundFlow = TestInboundStreamFlowLinkage
}

// MARK: - Inbound stream linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundStreamLinkage: InboundStreamLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestOutboundStreamLinkage

    public enum ProtocolType {
        case base
        case streamUpperHarness(StreamUpperHarness<TestStreamLinkageFamily>)
    }

    public let base: BaseInboundStreamLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let harnessInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(base: BaseInboundStreamLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(harness: StreamUpperHarness<TestStreamLinkageFamily>) {
        self.base = .init()
        self.protocolType = .streamUpperHarness(harness)
        self.harnessInstance = harness.identifier
    }

    public var identifier: InstanceIdentifier { harnessInstance ?? base.identifier }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: TestOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            var harness = harness
            let overrideUpper = try harness.attachLowerProtocol(lowerProtocol)
            try lowerProtocol.invokeAttachUpperProtocol(
                overrideUpper ?? self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            // The base linkage binds its own upper side, so the test linkage has to complete the
            // pairing itself: it attaches the lower protocol, then hands this linkage back up.
            try lowerProtocol.invokeAttachUpperProtocol(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .streamUpperHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        default: base.handleConnectedEvent(for: instance, in: &eventContext)
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        default: base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        default: base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        default: base.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        }
    }

    public func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        default: base.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        }
    }

    public func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            harness.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
        default: base.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    public func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamUpperHarness(let harness):
            harness.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
        default: base.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Outbound stream linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestOutboundStreamLinkage: OutboundStreamLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundStreamLinkage

    public enum ProtocolType {
        case base
        case streamLowerHarness(StreamLowerHarness<TestStreamLinkageFamily>)
    }

    public let base: BaseOutboundStreamLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let localInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.localInstance = nil
    }

    public init(base: BaseOutboundStreamLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.localInstance = nil
    }

    public init(harness: StreamLowerHarness<TestStreamLinkageFamily>) {
        self.base = .init()
        self.protocolType = .streamLowerHarness(harness)
        self.localInstance = harness.identifier
    }


    public var identifier: InstanceIdentifier { localInstance ?? base.identifier }

    public func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        switch protocolType {
        case .streamLowerHarness: return identifier.isConnected(in: &eventContext)
        default: return base.protocolIsConnected(in: &eventContext)
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: TestInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .streamLowerHarness(let harness):
            var harness = harness
            try harness.attachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try base.invokeAttachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch protocolType {
        case .streamLowerHarness(let harness):
            var harness = harness
            return try harness.receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        default:
            return try base.receiveStreamData(
                minimumBytes: minimumBytes,
                maximumBytes: maximumBytes,
                for: instance,
                in: &eventContext
            )
        }
    }

    public func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        switch protocolType {
        case .streamLowerHarness(let harness):
            var harness = harness
            return try harness.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        default:
            return try base.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
        }
    }

    public func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .streamLowerHarness(let harness):
            var harness = harness
            try harness.sendStreamData(streamData, from: instance, in: &eventContext)
        default: try base.sendStreamData(streamData, from: instance, in: &eventContext)
        }
    }

    public func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .streamLowerHarness:
            // The harness has no early-data path, matching what the framework's own linkage
            // reported for every non-QUIC protocol.
            throw NetworkError.posix(ENOTSUP)
        default: try base.sendEarlyStreamData(streamData, from: instance, in: &eventContext)
        }
    }

    public func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .streamLowerHarness:
            // Not supported by the harness, matching the framework's own linkage.
            throw NetworkError.posix(ENOTSUP)
        default: try base.abortInbound(error: error, for: instance, in: &eventContext)
        }
    }

    public func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .streamLowerHarness:
            // Not supported by the harness, matching the framework's own linkage.
            throw NetworkError.posix(ENOTSUP)
        default: try base.abortOutbound(error: error, for: instance, in: &eventContext)
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .streamLowerHarness(let harness): harness.connect(for: instance, in: &eventContext)
        default: base.connect(for: instance, in: &eventContext)
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamLowerHarness(let harness):
            harness.disconnect(error: error, for: instance, in: &eventContext)
        default: base.disconnect(error: error, for: instance, in: &eventContext)
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        case .streamLowerHarness(let harness):
            var harness = harness
            try harness.detach(for: instance, in: &eventContext)
        default: try base.detach(for: instance, in: &eventContext)
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .streamLowerHarness(let harness): harness.unregisterEventManager(in: &eventContext)
        default: base.teardown(in: &eventContext)
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .streamLowerHarness(let harness):
            harness.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        default: base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        case .streamLowerHarness(let harness): return harness.getMetadata(for: instance, in: &eventContext)
        default: return base.getMetadata(for: instance, in: &eventContext)
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        case .streamLowerHarness:
            // Held here rather than in `base`, whose linkage is empty; see the datagram
            // equivalent. Falling through would force-unwrap a nil storage.
            return nil
        default:
            return base.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Inbound stream flow linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundStreamFlowLinkage: InboundStreamFlowLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestStreamListenerLinkage
    public typealias DataLinkage = TestOutboundStreamLinkage

    public enum ProtocolType {
        case base
        case newStreamFlowHarness(NewStreamFlowHarness<TestStreamLinkageFamily>)
    }

    public let base: BaseInboundStreamFlowLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let harnessInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(base: BaseInboundStreamFlowLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.harnessInstance = nil
    }

    public init(harness: NewStreamFlowHarness<TestStreamLinkageFamily>) {
        self.base = .init()
        self.protocolType = .newStreamFlowHarness(harness)
        self.harnessInstance = harness.identifier
    }

    public var identifier: InstanceIdentifier { harnessInstance ?? base.identifier }

    public func invokeAttachLowerProtocol(
        _ lowerProtocol: TestStreamListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        case .newStreamFlowHarness(let harness):
            let harness = harness
            _ = try harness.attachLowerProtocol(lowerProtocol)
            try lowerProtocol.attachInboundFlow(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        default:
            try lowerProtocol.attachInboundFlow(
                self,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        case .newStreamFlowHarness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        default: base.handleConnectedEvent(for: instance, in: &eventContext)
        }
    }

    public func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .newStreamFlowHarness(let harness):
            harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        default: base.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    public func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .newStreamFlowHarness(let harness):
            harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        default: base.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        case .newStreamFlowHarness(let harness):
            harness.handleNewInboundFlowEvent(
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                for: instance,
                in: &eventContext
            )
        default:
            base.handleNewInboundFlowEvent(
                flowInstance: flowInstance,
                flowMetadata: flowMetadata,
                for: instance,
                in: &eventContext
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

// MARK: - Stream listener linkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestStreamListenerLinkage: StreamListenerLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundStreamFlowLinkage

    public enum ProtocolType {
        case base
    }

    public let base: BaseStreamListenerLinkage<TestLinkageFamilyGroup>
    public let protocolType: ProtocolType
    private let localInstance: InstanceIdentifier?

    public init() {
        self.base = .init()
        self.protocolType = .base
        self.localInstance = nil
    }

    public init(base: BaseStreamListenerLinkage<TestLinkageFamilyGroup>) {
        self.base = base
        self.protocolType = .base
        self.localInstance = nil
    }

    public var identifier: InstanceIdentifier { localInstance ?? base.identifier }

    // Binds an inbound-flow observer to the listener. Called from the upper linkage so both
    // directions end up bound.
    public func attachInboundFlow(
        _ upperProtocol: TestInboundStreamFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        default:
            try base.invokeAttachUpperProtocol(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func invokeAttachUpperProtocol(
        _ upperProtocol: TestInboundStreamFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try attachInboundFlow(
            upperProtocol,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    public func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: TestInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch protocolType {
        default:
            try base.invokeAttachUpperProtocolToNewFlow(
                upperProtocol,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            return
        }
    }

    public func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: TestInboundStreamLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> TestOutboundStreamLinkage {
        switch protocolType {
        default:
            // The wrapped base linkage is specialized on this group, so it already hands back the
            // test family's own linkage -- no re-wrapping needed.
            return try base.invokeAttachUpperProtocolToExistingFlow(
                upperProtocol,
                existingFlowInstance: existingFlowInstance
            )
        }
    }

    public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        default: base.connect(for: instance, in: &eventContext)
        }
    }

    public func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: base.disconnect(error: error, for: instance, in: &eventContext)
        }
    }

    public func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch protocolType {
        default: try base.detach(for: instance, in: &eventContext)
        }
    }

    public func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch protocolType {
        default: base.teardown(in: &eventContext)
        }
    }

    public func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch protocolType {
        default: base.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    public func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch protocolType {
        default: return base.getMetadata(for: instance, in: &eventContext)
        }
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        switch protocolType {
        default:
            return base.getMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: instance,
                in: &eventContext
            )
        }
    }

    public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
        lhs.identifier == rhs.identifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}
