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

// The storage-side factories for the test harnesses and the test multiplexing protocol.
//
// These protocols are compiled into the framework rather than layered on top of it, because the base
// linkages have no extension point: taking part in a stack means having a case in their enums. So
// the harnesses build against `BaseDatagramLinkageFamily` / `BaseStreamLinkageFamily` directly, and
// the storage holds them alive for its own lifetime the way it does every other instance.

#if !NETWORK_EMBEDDED

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension BaseNetworkProtocolStorage {

    // MARK: - Datagram harnesses

    public func createDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (DatagramUpperHarness<BaseDatagramLinkageFamily>, BaseInboundDatagramLinkage) {
        let instance = createDatagramUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, BaseInboundDatagramLinkage(harness: instance))
    }

    /// Creates an upper harness using an event context the caller already holds. The new-inbound-
    /// flow event runs inline with the state held, so registering there has to use this.
    public func createDatagramUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext,
        in eventContext: inout NetworkContext.EventContext
    ) -> (DatagramUpperHarness<BaseDatagramLinkageFamily>, BaseInboundDatagramLinkage) {
        let instance = createDatagramUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            in: &eventContext
        )
        return (instance, BaseInboundDatagramLinkage(harness: instance))
    }

    public func createDatagramLowerHarness(
        identifier: String = "",
        context: NetworkContext
    ) -> (DatagramLowerHarness<BaseDatagramLinkageFamily>, BaseOutboundDatagramLinkage) {
        let instance = createDatagramLowerHarnessInstance(identifier: identifier)
        return (instance, BaseOutboundDatagramLinkage(harness: instance))
    }

    public func createNewDatagramFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (NewDatagramFlowHarness<BaseDatagramLinkageFamily>, BaseInboundDatagramFlowLinkage) {
        let instance = createNewDatagramFlowHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, BaseInboundDatagramFlowLinkage(harness: instance))
    }

    // MARK: - Stream harnesses

    public func createStreamUpperHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (StreamUpperHarness<BaseStreamLinkageFamily>, BaseInboundStreamLinkage) {
        let instance = createStreamUpperHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, BaseInboundStreamLinkage(harness: instance))
    }

    public func createStreamLowerHarness(
        identifier: String = "",
        context: NetworkContext
    ) -> (StreamLowerHarness<BaseStreamLinkageFamily>, BaseOutboundStreamLinkage) {
        let instance = createStreamLowerHarnessInstance(identifier: identifier)
        return (instance, BaseOutboundStreamLinkage(harness: instance))
    }

    public func createNewStreamFlowHarness(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        context: NetworkContext
    ) -> (NewStreamFlowHarness<BaseStreamLinkageFamily>, BaseInboundStreamFlowLinkage) {
        let instance = createNewStreamFlowHarnessInstance(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path
        )
        return (instance, BaseInboundStreamFlowLinkage(harness: instance))
    }

    // MARK: - Test multiplexing protocol

    public func createMultiplexingInstance() -> (
        listener: BaseDatagramListenerLinkage,
        multipath: BaseDatagramMultipathLinkage,
        instance: TestMultiplexingProtocol
    ) {
        let instance = TestMultiplexingProtocol(context: context)
        return (
            listener: BaseDatagramListenerLinkage(multiplexing: instance),
            multipath: BaseDatagramMultipathLinkage(multiplexing: instance),
            instance: instance
        )
    }

    // MARK: - Instance factories

    // These build and retain the harness itself; the linkage-returning wrappers above are what
    // callers normally use.

    public func createDatagramUpperHarnessInstance(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> DatagramUpperHarness<BaseDatagramLinkageFamily> {
        let instance = DatagramUpperHarness<BaseDatagramLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        heldHarnesses.datagramUpper.append(instance)
        return instance
    }

    public func createDatagramUpperHarnessInstance(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) -> DatagramUpperHarness<BaseDatagramLinkageFamily> {
        let instance = DatagramUpperHarness<BaseDatagramLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context,
            in: &eventContext
        )
        heldHarnesses.datagramUpper.append(instance)
        return instance
    }

    public func createDatagramLowerHarnessInstance(
        identifier: String = ""
    ) -> DatagramLowerHarness<BaseDatagramLinkageFamily> {
        let instance = DatagramLowerHarness<BaseDatagramLinkageFamily>(
            identifier: identifier,
            context: context
        )
        heldHarnesses.datagramLower.append(instance)
        return instance
    }

    public func createNewDatagramFlowHarnessInstance(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> NewDatagramFlowHarness<BaseDatagramLinkageFamily> {
        let instance = NewDatagramFlowHarness<BaseDatagramLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        ) { [self] state in
            let inbound = createDatagramUpperHarnessInstance(
                identifier: "Inbound",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                in: &state
            )
            return (inbound, BaseInboundDatagramLinkage(harness: inbound))
        }
        heldHarnesses.newDatagramFlow.append(instance)
        return instance
    }

    public func createStreamUpperHarnessInstance(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> StreamUpperHarness<BaseStreamLinkageFamily> {
        let instance = StreamUpperHarness<BaseStreamLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        )
        heldHarnesses.streamUpper.append(instance)
        return instance
    }

    public func createStreamUpperHarnessInstance(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties,
        in eventContext: inout NetworkContext.EventContext
    ) -> StreamUpperHarness<BaseStreamLinkageFamily> {
        let instance = StreamUpperHarness<BaseStreamLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context,
            in: &eventContext
        )
        heldHarnesses.streamUpper.append(instance)
        return instance
    }

    public func createStreamLowerHarnessInstance(
        identifier: String = ""
    ) -> StreamLowerHarness<BaseStreamLinkageFamily> {
        let instance = StreamLowerHarness<BaseStreamLinkageFamily>(
            identifier: identifier,
            context: context
        )
        heldHarnesses.streamLower.append(instance)
        return instance
    }

    public func createNewStreamFlowHarnessInstance(
        identifier: String = "",
        local: Endpoint,
        remote: Endpoint,
        parameters: Parameters,
        path: PathProperties
    ) -> NewStreamFlowHarness<BaseStreamLinkageFamily> {
        let instance = NewStreamFlowHarness<BaseStreamLinkageFamily>(
            identifier: identifier,
            local: local,
            remote: remote,
            parameters: parameters,
            path: path,
            context: context
        ) { [self] state in
            let inbound = createStreamUpperHarnessInstance(
                identifier: "Inbound",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                in: &state
            )
            return (inbound, BaseInboundStreamLinkage(harness: inbound))
        }
        heldHarnesses.newStreamFlow.append(instance)
        return instance
    }

    /// Retires every harness this storage is holding.
    ///
    /// A harness registers an event state when it is built, and one that nothing detached still
    /// holds it, which trips a precondition when the harness is destroyed. This is the end of the
    /// harnesses' lives, so retire whatever is still registered before letting go.
    public func releaseHeldInstances() {
        for harness in heldHarnesses.datagramUpper { harness.retireEventStateForTest() }
        for harness in heldHarnesses.datagramLower { harness.retireEventStateForTest() }
        for harness in heldHarnesses.newDatagramFlow { harness.retireEventStateForTest() }
        for harness in heldHarnesses.streamUpper { harness.retireEventStateForTest() }
        for harness in heldHarnesses.streamLower { harness.retireEventStateForTest() }
        for harness in heldHarnesses.newStreamFlow { harness.retireEventStateForTest() }
        heldHarnesses = HeldHarnesses()
    }
}

// The harnesses the storage is keeping alive. Held in one struct so the storage needs a single
// stored property for all of them.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct HeldHarnesses {
    var datagramUpper = [DatagramUpperHarness<BaseDatagramLinkageFamily>]()
    var datagramLower = [DatagramLowerHarness<BaseDatagramLinkageFamily>]()
    var newDatagramFlow = [NewDatagramFlowHarness<BaseDatagramLinkageFamily>]()
    var streamUpper = [StreamUpperHarness<BaseStreamLinkageFamily>]()
    var streamLower = [StreamLowerHarness<BaseStreamLinkageFamily>]()
    var newStreamFlow = [NewStreamFlowHarness<BaseStreamLinkageFamily>]()

    public init() {}
}

#endif  // !NETWORK_EMBEDDED
