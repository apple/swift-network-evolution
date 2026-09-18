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

// A stack assembled outside the main package.
//
// This is the extension point the framework's linkages are designed for: a client can define its
// own protocols and wire them into a stack the framework knows nothing about.
//
// The framework's linkages are concrete, so nothing here is generic over them. Each `Test*` linkage
// is a struct holding a `Base*Linkage` plus cases for the protocols only this module knows about --
// the harnesses and the test multiplexing protocol. A call on a test protocol dispatches through
// this module's own enum, and a call on anything else is handed to the held base linkage, which
// switches to a concrete framework protocol. Both of those are direct calls.
//
// The framework reaches back the other way through a box. Every `Test*` linkage that names a
// protocol from this module builds its `base` as `Base*Linkage(external:)` around a box class, once,
// when the linkage is created. So a framework protocol handed a test protocol as its upper or lower
// always holds an ordinary base linkage; reaching the test protocol costs one class call, and the
// box is what puts this module's types back on.
//
// `TestNetworkProtocolStorage` subclasses `BaseNetworkProtocolStorage`, so it inherits every
// framework protocol factory and only adds the test-only ones. The inherited factories hand back
// base linkages, so this module also provides `createTest*Instance` wrappers that put the test
// linkage around them.

@_spi(TestHarness)
@available(Network 0.1.0, *)
public final class TestNetworkProtocolStorage: BaseNetworkProtocolStorage {

    // A true subclass: every framework protocol -- UDP, IP, demux, TCP, the sockets, the bridges,
    // and QUIC -- is inherited, so this only adds factories for the protocols the framework does
    // not know about, plus the wrappers that lift the inherited ones into the test linkages.

    // MARK: - Framework protocol factories, lifted into the test linkages

    public func createTestUDPInstance() -> (TestInboundDatagramLinkage, TestOutboundDatagramLinkage) {
        let (inbound, outbound) = createUDPInstance()
        return (.init(base: inbound), .init(base: outbound))
    }

    public func createTestDemuxInstance() -> (TestInboundDatagramLinkage, TestOutboundDatagramLinkage) {
        let (inbound, outbound) = createDemuxInstance()
        return (.init(base: inbound), .init(base: outbound))
    }

    public func createTestIPInstance() -> (TestInboundDatagramLinkage, TestOutboundDatagramLinkage) {
        let (inbound, outbound) = createIPInstance()
        return (.init(base: inbound), .init(base: outbound))
    }

    public func createTestTCPInstance() -> (TestInboundDatagramLinkage, TestOutboundStreamLinkage) {
        let (inbound, outbound) = createTCPInstance()
        return (.init(base: inbound), .init(base: outbound))
    }

    public func createTestSocketDatagramInstance() -> TestOutboundDatagramLinkage {
        .init(base: createSocketDatagramInstance())
    }

    public func createTestSocketStreamInstance() -> TestOutboundStreamLinkage {
        .init(base: createSocketStreamInstance())
    }

    public func createTestBridgeDatagramInstance() -> TestOutboundDatagramLinkage {
        .init(base: createBridgeDatagramInstance())
    }

    public func createTestBridgeStreamInstance() -> TestOutboundStreamLinkage {
        .init(base: createBridgeStreamInstance())
    }

    public func createTestQUICInstance() -> (
        TestStreamListenerLinkage, TestDatagramListenerLinkage, TestDatagramMultipathLinkage
    ) {
        let (stream, datagram, multipath) = createQUICInstance()
        return (.init(base: stream), .init(base: datagram), .init(base: multipath))
    }

    // MARK: - Datagram harnesses

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

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestStreamLinkageFamily: StreamLinkageFamily {
    public typealias Upper = TestInboundStreamLinkage
    public typealias Lower = TestOutboundStreamLinkage
    public typealias Listener = TestStreamListenerLinkage
    public typealias InboundFlow = TestInboundStreamFlowLinkage
}

// MARK: - Inbound datagram linkage

// The box the framework holds for an inbound datagram protocol from this module. It takes the
// framework's concrete linkages and puts this module's types back on before calling in.
@available(Network 0.1.0, *)
final class TestExternalInboundDatagram: ExternalInboundDatagramLinkage {
    enum Target {
        case harness(DatagramUpperHarness<TestDatagramLinkageFamily>)
        case path(TestDatagramPath)
    }

    let target: Target

    init(harness: DatagramUpperHarness<TestDatagramLinkageFamily>) { self.target = .harness(harness) }
    init(path: TestDatagramPath) { self.target = .path(path) }

    var identifier: InstanceIdentifier {
        switch target {
        case .harness(let harness): return harness.identifier
        case .path(let path): return path.identifier
        }
    }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch target {
        case .path:
            // The path's lower is bound when the path is created, so there is nothing more to do.
            break
        case .harness(let harness):
            var mutableHarness = harness
            let lower = TestOutboundDatagramLinkage(base: lowerProtocol)
            let overrideUpper = try mutableHarness.attachLowerProtocol(lower)
            try lower.invokeAttachUpperProtocol(
                overrideUpper ?? TestInboundDatagramLinkage(harness: harness),
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch target {
        case .harness(let harness): harness.handleConnectedEvent(for: instance, in: &eventContext)
        case .path(let path): path.handleConnectedEvent(for: instance, in: &eventContext)
        }
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch target {
        case .harness(let harness): harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        case .path(let path): path.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
        }
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch target {
        case .harness(let harness): harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        case .path(let path):
            var mutablePath = path
            mutablePath.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
        }
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch target {
        case .harness(let harness): harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        case .path(let path):
            var mutablePath = path
            mutablePath.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
        }
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch target {
        case .harness(let harness): harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        case .path(let path):
            var mutablePath = path
            mutablePath.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
        }
    }
}

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
    }

    /// The framework linkage this one is reached through. For a framework protocol it is that
    /// protocol's own linkage; for a protocol from this module it is the boxed form of this
    /// linkage, built once here rather than on each call.
    public let base: BaseInboundDatagramLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseInboundDatagramLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(harness: DatagramUpperHarness<TestDatagramLinkageFamily>) {
        self.base = .init(external: TestExternalInboundDatagram(harness: harness))
        self.protocolType = .datagramUpperHarness(harness)
    }

    public init(path: TestDatagramPath) {
        self.base = .init(external: TestExternalInboundDatagram(path: path))
        self.protocolType = .multiplexingPath(path)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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
                lowerProtocol.base,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
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
        case .datagramUpperHarness(let harness):
            harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
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
        case .datagramUpperHarness(let harness):
            harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
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

@available(Network 0.1.0, *)
final class TestExternalOutboundDatagram: ExternalOutboundDatagramLinkage {
    enum Target {
        case harness(DatagramLowerHarness<TestDatagramLinkageFamily>)
        case flow(TestDatagramFlow)
    }

    let target: Target

    init(harness: DatagramLowerHarness<TestDatagramLinkageFamily>) { self.target = .harness(harness) }
    init(flow: TestDatagramFlow) { self.target = .flow(flow) }

    var identifier: InstanceIdentifier {
        switch target {
        case .harness(let harness): return harness.identifier
        case .flow(let flow): return flow.identifier
        }
    }

    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        switch target {
        case .flow:
            // `attachUpperProtocolToNewFlow` binds the upper when it creates the flow, so there
            // is nothing more to do here.
            break
        case .harness(let harness):
            var mutableHarness = harness
            try mutableHarness.attachUpperProtocol(
                TestInboundDatagramLinkage(base: upperProtocol),
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        }
    }

    func receiveDatagrams(
        maximumDatagramCount: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch target {
        case .flow(let flow):
            var mutableFlow = flow
            return try mutableFlow.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        case .harness(let harness):
            var mutableHarness = harness
            return try mutableHarness.receiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: instance,
                in: &eventContext
            )
        }
    }

    func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        switch target {
        case .flow(let flow):
            return try flow.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        case .harness(let harness):
            var mutableHarness = harness
            return try mutableHarness.getDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: instance,
                in: &eventContext
            )
        }
    }

    func sendDatagrams(
        _ datagrams: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch target {
        case .flow(let flow):
            var mutableFlow = flow
            try mutableFlow.sendDatagrams(datagrams, from: instance, in: &eventContext)
        case .harness(let harness):
            var mutableHarness = harness
            try mutableHarness.sendDatagrams(datagrams, from: instance, in: &eventContext)
        }
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        switch target {
        case .flow(let flow): flow.connect(for: instance, in: &eventContext)
        case .harness(let harness): harness.connect(for: instance, in: &eventContext)
        }
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch target {
        case .flow(let flow): flow.disconnect(error: error, for: instance, in: &eventContext)
        case .harness(let harness): harness.disconnect(error: error, for: instance, in: &eventContext)
        }
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        switch target {
        case .flow(let flow):
            var mutableFlow = flow
            try mutableFlow.detach(for: instance, in: &eventContext)
        case .harness(let harness):
            var mutableHarness = harness
            try mutableHarness.detach(for: instance, in: &eventContext)
        }
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        switch target {
        case .flow(let flow): flow.unregisterEventManager(in: &eventContext)
        case .harness(let harness): harness.unregisterEventManager(in: &eventContext)
        }
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        switch target {
        case .flow(let flow): flow.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        case .harness(let harness): harness.handleApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        switch target {
        case .flow(let flow): return flow.getMetadata(for: instance, in: &eventContext)
        case .harness(let harness): return harness.getMetadata(for: instance, in: &eventContext)
        }
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        // Neither the harness nor a multiplexed flow reports metrics.
        nil
    }
}

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

    public let base: BaseOutboundDatagramLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseOutboundDatagramLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(harness: DatagramLowerHarness<TestDatagramLinkageFamily>) {
        self.base = .init(external: TestExternalOutboundDatagram(harness: harness))
        self.protocolType = .datagramLowerHarness(harness)
    }

    public init(flow: TestDatagramFlow) {
        self.base = .init(external: TestExternalOutboundDatagram(flow: flow))
        self.protocolType = .multiplexedFlow(flow)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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
                upperProtocol.base,
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

@available(Network 0.1.0, *)
final class TestExternalInboundDatagramFlow: ExternalInboundDatagramFlowLinkage {
    let harness: NewDatagramFlowHarness<TestDatagramLinkageFamily>

    init(harness: NewDatagramFlowHarness<TestDatagramLinkageFamily>) { self.harness = harness }

    var identifier: InstanceIdentifier { harness.identifier }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseDatagramListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let listener = TestDatagramListenerLinkage(base: lowerProtocol)
        _ = try harness.attachLowerProtocol(listener)
        try listener.attachInboundFlow(
            TestInboundDatagramFlowLinkage(harness: harness),
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        harness.handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleNewInboundFlowEvent(
            flowInstance: flowInstance,
            flowMetadata: flowMetadata,
            for: instance,
            in: &eventContext
        )
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundDatagramFlowLinkage: InboundDatagramFlowLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestDatagramListenerLinkage
    public typealias DataLinkage = TestOutboundDatagramLinkage

    public enum ProtocolType {
        case base
        case newDatagramFlowHarness(NewDatagramFlowHarness<TestDatagramLinkageFamily>)
    }

    public let base: BaseInboundDatagramFlowLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseInboundDatagramFlowLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(harness: NewDatagramFlowHarness<TestDatagramLinkageFamily>) {
        self.base = .init(external: TestExternalInboundDatagramFlow(harness: harness))
        self.protocolType = .newDatagramFlowHarness(harness)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
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

@available(Network 0.1.0, *)
final class TestExternalDatagramListener: ExternalDatagramListenerLinkage {
    let instance: TestMultiplexingProtocol

    init(multiplexing instance: TestMultiplexingProtocol) { self.instance = instance }

    var identifier: InstanceIdentifier { instance.identifier }

    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        instance.isConnected(in: &eventContext)
    }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundDatagramFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var mutableInstance = instance
        try mutableInstance.attachUpperProtocol(
            TestInboundDatagramFlowLinkage(base: upperProtocol),
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func invokeAttachUpperProtocolToNewFlow(
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var mutableInstance = instance
        let upper = TestInboundDatagramLinkage(base: upperProtocol)
        let flowLower = try mutableInstance.attachUpperProtocolToNewFlow(
            upper,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
        try upper.invokeAttachLowerProtocol(
            flowLower,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: BaseInboundDatagramLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> BaseOutboundDatagramLinkage {
        var mutableInstance = instance
        let flowLower = try mutableInstance.attachUpperProtocolToExistingFlow(
            TestInboundDatagramLinkage(base: upperProtocol),
            existingFlowInstance: existingFlowInstance
        )
        return flowLower.base
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        self.instance.connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.instance.disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        var mutableInstance = self.instance
        try mutableInstance.detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        // The multiplexing protocol outlives its listener linkage; the test owns its lifetime.
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        self.instance.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        self.instance.getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        nil
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramListenerLinkage: DatagramListenerLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundDatagramFlowLinkage

    public enum ProtocolType {
        case base
        case multiplexing(TestMultiplexingProtocol)
    }

    public let base: BaseDatagramListenerLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseDatagramListenerLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(multiplexing instance: TestMultiplexingProtocol) {
        self.base = .init(external: TestExternalDatagramListener(multiplexing: instance))
        self.protocolType = .multiplexing(instance)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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
                upperProtocol.base,
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
                upperProtocol.base,
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
            // The framework hands back its own linkage, so put this module's wrapper on it.
            return .init(
                base: try base.invokeAttachUpperProtocolToExistingFlow(
                    upperProtocol.base,
                    existingFlowInstance: existingFlowInstance
                )
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
        case .multiplexing(let protocolInstance):
            protocolInstance.disconnect(error: error, for: instance, in: &eventContext)
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

@available(Network 0.1.0, *)
final class TestExternalDatagramMultipath: ExternalDatagramMultipathLinkage {
    let instance: TestMultiplexingProtocol

    init(multiplexing instance: TestMultiplexingProtocol) { self.instance = instance }

    var identifier: InstanceIdentifier { instance.identifier }

    func invokeAttachLowerProtocolForNewPath(
        _ lowerProtocol: BaseOutboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var mutableInstance = instance
        let lower = TestOutboundDatagramLinkage(base: lowerProtocol)
        let pathUpper = try mutableInstance.fromExternal { eventContext throws(NetworkError) in
            try mutableInstance.attachLowerProtocolForNewPath(
                lower,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path,
                in: &eventContext
            )
        }
        try lower.invokeAttachUpperProtocol(
            pathUpper,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestDatagramMultipathLinkage: DatagramMultipathLinkage, @unchecked Sendable {
    public typealias MultipathLowerProtocol = TestOutboundDatagramLinkage

    public enum ProtocolType {
        case base
        case multiplexing(TestMultiplexingProtocol)
    }

    public let base: BaseDatagramMultipathLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseDatagramMultipathLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(multiplexing instance: TestMultiplexingProtocol) {
        self.base = .init(external: TestExternalDatagramMultipath(multiplexing: instance))
        self.protocolType = .multiplexing(instance)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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
                lowerProtocol.base,
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

// MARK: - Inbound stream linkage

@available(Network 0.1.0, *)
final class TestExternalInboundStream: ExternalInboundStreamLinkage {
    let harness: StreamUpperHarness<TestStreamLinkageFamily>

    init(harness: StreamUpperHarness<TestStreamLinkageFamily>) { self.harness = harness }

    var identifier: InstanceIdentifier { harness.identifier }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseOutboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var mutableHarness = harness
        let lower = TestOutboundStreamLinkage(base: lowerProtocol)
        let overrideUpper = try mutableHarness.attachLowerProtocol(lower)
        try lower.invokeAttachUpperProtocol(
            overrideUpper ?? TestInboundStreamLinkage(harness: harness),
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        harness.handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleInboundDataAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleInboundDataAvailableEvent(for: instance, in: &eventContext)
    }

    func handleOutboundRoomAvailableEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleOutboundRoomAvailableEvent(for: instance, in: &eventContext)
    }

    func handleInboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleInboundAbortedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleOutboundAbortedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleOutboundAbortedEvent(error: error, for: instance, in: &eventContext)
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundStreamLinkage: InboundStreamLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestOutboundStreamLinkage

    public enum ProtocolType {
        case base
        case streamUpperHarness(StreamUpperHarness<TestStreamLinkageFamily>)
    }

    public let base: BaseInboundStreamLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseInboundStreamLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(harness: StreamUpperHarness<TestStreamLinkageFamily>) {
        self.base = .init(external: TestExternalInboundStream(harness: harness))
        self.protocolType = .streamUpperHarness(harness)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
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

@available(Network 0.1.0, *)
final class TestExternalOutboundStream: ExternalOutboundStreamLinkage {
    let harness: StreamLowerHarness<TestStreamLinkageFamily>

    init(harness: StreamLowerHarness<TestStreamLinkageFamily>) { self.harness = harness }

    var identifier: InstanceIdentifier { harness.identifier }

    func protocolIsConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }

    func invokeAttachUpperProtocol(
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        var mutableHarness = harness
        try mutableHarness.attachUpperProtocol(
            TestInboundStreamLinkage(base: upperProtocol),
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        var mutableHarness = harness
        return try mutableHarness.receiveStreamData(
            minimumBytes: minimumBytes,
            maximumBytes: maximumBytes,
            for: instance,
            in: &eventContext
        )
    }

    func getOutboundStreamDataRoomAvailable(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        var mutableHarness = harness
        return try mutableHarness.getOutboundStreamDataRoomAvailable(for: instance, in: &eventContext)
    }

    func sendStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        var mutableHarness = harness
        try mutableHarness.sendStreamData(streamData, from: instance, in: &eventContext)
    }

    func sendEarlyStreamData(
        _ streamData: consuming FrameArray,
        from instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        // The harness has no early-data path, matching what the framework's own linkage
        // reports for every non-QUIC protocol.
        throw NetworkError.posix(ENOTSUP)
    }

    func abortInbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    func abortOutbound(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        throw NetworkError.posix(ENOTSUP)
    }

    func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        harness.connect(for: instance, in: &eventContext)
    }

    func disconnect(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.disconnect(error: error, for: instance, in: &eventContext)
    }

    func detach(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        var mutableHarness = harness
        try mutableHarness.detach(for: instance, in: &eventContext)
    }

    func teardown(in eventContext: inout NetworkContext.EventContext) {
        harness.unregisterEventManager(in: &eventContext)
    }

    func handleApplicationEvent(
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleApplicationEvent(event: event, for: instance, in: &eventContext)
    }

    func getMetadata<P: NetworkProtocol>(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> ProtocolMetadata<P>? {
        harness.getMetadata(for: instance, in: &eventContext)
    }

    func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        nil
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestOutboundStreamLinkage: OutboundStreamLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundStreamLinkage

    public enum ProtocolType {
        case base
        case streamLowerHarness(StreamLowerHarness<TestStreamLinkageFamily>)
    }

    public let base: BaseOutboundStreamLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseOutboundStreamLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(harness: StreamLowerHarness<TestStreamLinkageFamily>) {
        self.base = .init(external: TestExternalOutboundStream(harness: harness))
        self.protocolType = .streamLowerHarness(harness)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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
                upperProtocol.base,
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

@available(Network 0.1.0, *)
final class TestExternalInboundStreamFlow: ExternalInboundStreamFlowLinkage {
    let harness: NewStreamFlowHarness<TestStreamLinkageFamily>

    init(harness: NewStreamFlowHarness<TestStreamLinkageFamily>) { self.harness = harness }

    var identifier: InstanceIdentifier { harness.identifier }

    func invokeAttachLowerProtocol(
        _ lowerProtocol: BaseStreamListenerLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        let listener = TestStreamListenerLinkage(base: lowerProtocol)
        _ = try harness.attachLowerProtocol(listener)
        try listener.attachInboundFlow(
            TestInboundStreamFlowLinkage(harness: harness),
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    func handleConnectedEvent(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
        harness.handleConnectedEvent(for: instance, in: &eventContext)
    }

    func handleDisconnectedEvent(
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleDisconnectedEvent(error: error, for: instance, in: &eventContext)
    }

    func handleNetworkProtocolEvent(
        event: NetworkProtocolEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleNetworkProtocolEvent(event: event, for: instance, in: &eventContext)
    }

    func handleNewInboundFlowEvent(
        flowInstance: InstanceIdentifier,
        flowMetadata: AbstractProtocolMetadata?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        harness.handleNewInboundFlowEvent(
            flowInstance: flowInstance,
            flowMetadata: flowMetadata,
            for: instance,
            in: &eventContext
        )
    }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestInboundStreamFlowLinkage: InboundStreamFlowLinkage, @unchecked Sendable {
    public typealias PairedLowerLinkage = TestStreamListenerLinkage
    public typealias DataLinkage = TestOutboundStreamLinkage

    public enum ProtocolType {
        case base
        case newStreamFlowHarness(NewStreamFlowHarness<TestStreamLinkageFamily>)
    }

    public let base: BaseInboundStreamFlowLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseInboundStreamFlowLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public init(harness: NewStreamFlowHarness<TestStreamLinkageFamily>) {
        self.base = .init(external: TestExternalInboundStreamFlow(harness: harness))
        self.protocolType = .newStreamFlowHarness(harness)
    }

    public var identifier: InstanceIdentifier { base.identifier }

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

    public func handleConnectedEvent(
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
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

// This module adds no stream listener of its own, so there is no box for this role: the linkage is
// always the framework's own, wrapped so the rest of the test family lines up.
@_spi(TestHarness)
@available(Network 0.1.0, *)
public struct TestStreamListenerLinkage: StreamListenerLinkage, @unchecked Sendable {
    public typealias PairedUpperLinkage = TestInboundStreamFlowLinkage

    public enum ProtocolType {
        case base
    }

    public let base: BaseStreamListenerLinkage
    public let protocolType: ProtocolType

    public init() {
        self.base = .init()
        self.protocolType = .base
    }

    public init(base: BaseStreamListenerLinkage) {
        self.base = base
        self.protocolType = .base
    }

    public var identifier: InstanceIdentifier { base.identifier }

    // Binds an inbound-flow observer to the listener. Called from the upper linkage so both
    // directions end up bound.
    public func attachInboundFlow(
        _ upperProtocol: TestInboundStreamFlowLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        try base.invokeAttachUpperProtocol(
            upperProtocol.base,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
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
        try base.invokeAttachUpperProtocolToNewFlow(
            upperProtocol.base,
            remote: remote,
            local: local,
            parameters: parameters,
            path: path
        )
    }

    public func invokeAttachUpperProtocolToExistingFlow(
        _ upperProtocol: TestInboundStreamLinkage,
        existingFlowInstance: InstanceIdentifier
    ) throws(NetworkError) -> TestOutboundStreamLinkage {
        // The framework hands back its own linkage, so put this module's wrapper on it.
        .init(
            base: try base.invokeAttachUpperProtocolToExistingFlow(
                upperProtocol.base,
                existingFlowInstance: existingFlowInstance
            )
        )
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
        base.getMetadata(for: instance, in: &eventContext)
    }

    public func getMetrics(
        requestedNetworkMetric: RequestedNetworkMetrics,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkMetrics? {
        base.getMetrics(
            requestedNetworkMetric: requestedNetworkMetric,
            for: instance,
            in: &eventContext
        )
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
