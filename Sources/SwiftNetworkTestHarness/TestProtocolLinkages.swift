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

// A compatibility shim over the harnesses, which now live in SwiftNetwork itself.
//
// The base linkages have no extension point in this configuration: every protocol that can appear in
// a stack has a case in their enums, so the harnesses and the test multiplexing protocol had to move
// into the framework. Nothing is wrapped any more -- a `Test*Linkage` *is* the corresponding
// `Base*Linkage` -- so these are typealiases, and the call sites that were written against the
// wrapper names keep working unchanged.

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @_spi(TestHarness) @_exported import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @_spi(TestHarness) @_exported import Network
#endif

#if !NETWORK_NO_TESTING_HARNESS && !NETWORK_EMBEDDED

// MARK: - Storage

// The framework's storage already owns every protocol instance and every harness, so the test
// storage adds nothing.
@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestNetworkProtocolStorage = BaseNetworkProtocolStorage

// MARK: - Linkage families

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestDatagramLinkageFamily = BaseDatagramLinkageFamily

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestStreamLinkageFamily = BaseStreamLinkageFamily

// MARK: - Linkages

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestInboundDatagramLinkage = BaseInboundDatagramLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestOutboundDatagramLinkage = BaseOutboundDatagramLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestInboundDatagramFlowLinkage = BaseInboundDatagramFlowLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestDatagramListenerLinkage = BaseDatagramListenerLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestDatagramMultipathLinkage = BaseDatagramMultipathLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestInboundStreamLinkage = BaseInboundStreamLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestOutboundStreamLinkage = BaseOutboundStreamLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestInboundStreamFlowLinkage = BaseInboundStreamFlowLinkage

@_spi(TestHarness)
@available(Network 0.1.0, *)
public typealias TestStreamListenerLinkage = BaseStreamListenerLinkage

// MARK: - Storage factories

// The `createTest*` spellings the tests use. The framework's own factories now return the linkages
// these used to wrap, so each one is a direct forward.
@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseNetworkProtocolStorage {

    public func createTestUDPInstance() -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        createUDPInstance()
    }

    public func createTestDemuxInstance() -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        createDemuxInstance()
    }

    public func createTestIPInstance() -> (BaseInboundDatagramLinkage, BaseOutboundDatagramLinkage) {
        createIPInstance()
    }

    public func createTestTCPInstance() -> (BaseInboundDatagramLinkage, BaseOutboundStreamLinkage) {
        createTCPInstance()
    }

    public func createTestSocketDatagramInstance() -> BaseOutboundDatagramLinkage {
        createSocketDatagramInstance()
    }

    public func createTestSocketStreamInstance() -> BaseOutboundStreamLinkage {
        createSocketStreamInstance()
    }

    public func createTestBridgeDatagramInstance() -> BaseOutboundDatagramLinkage {
        createBridgeDatagramInstance()
    }

    public func createTestBridgeStreamInstance() -> BaseOutboundStreamLinkage {
        createBridgeStreamInstance()
    }

    #if !NETWORK_NO_SWIFT_QUIC
    public func createTestQUICInstance() -> (
        BaseStreamListenerLinkage, BaseDatagramListenerLinkage, BaseDatagramMultipathLinkage
    ) {
        createQUICInstance()
    }
    #endif

    public func createTestMultiplexingInstance() -> (
        listener: BaseDatagramListenerLinkage,
        multipath: BaseDatagramMultipathLinkage,
        instance: TestMultiplexingProtocol
    ) {
        createMultiplexingInstance()
    }

    // MARK: Harness instance factories

    public func createTestDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> DatagramUpperHarness<BaseDatagramLinkageFamily> {
        createDatagramUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
    }

    public func createTestDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) -> DatagramUpperHarness<BaseDatagramLinkageFamily> {
        createDatagramUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            in: &eventContext
        )
    }

    public func createTestDatagramLowerHarness(
        identifier: String = ""
    ) -> DatagramLowerHarness<BaseDatagramLinkageFamily> {
        createDatagramLowerHarnessInstance(identifier: identifier)
    }

    public func createTestNewDatagramFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> NewDatagramFlowHarness<BaseDatagramLinkageFamily> {
        createNewDatagramFlowHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
    }

    public func createTestStreamUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> StreamUpperHarness<BaseStreamLinkageFamily> {
        createStreamUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
    }

    public func createTestStreamUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) -> StreamUpperHarness<BaseStreamLinkageFamily> {
        createStreamUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            in: &eventContext
        )
    }

    public func createTestStreamLowerHarness(
        identifier: String = ""
    ) -> StreamLowerHarness<BaseStreamLinkageFamily> {
        createStreamLowerHarnessInstance(identifier: identifier)
    }

    public func createTestNewStreamFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> NewStreamFlowHarness<BaseStreamLinkageFamily> {
        createNewStreamFlowHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
    }
}

// MARK: - Wrapper compatibility

// The wrappers used to hold the framework linkage in a `base` property, and call sites reached
// through it to get at the framework-side linkage. A linkage now *is* that, so `base` is `self`.
@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseInboundDatagramLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseOutboundDatagramLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseInboundStreamLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseOutboundStreamLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseStreamListenerLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseDatagramListenerLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseDatagramMultipathLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseInboundDatagramFlowLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

@_spi(TestHarness)
@available(Network 0.1.0, *)
extension BaseInboundStreamFlowLinkage {
    public var base: Self { self }
    public init(base: Self) { self = base }
}

#endif  // !NETWORK_NO_TESTING_HARNESS && !NETWORK_EMBEDDED
