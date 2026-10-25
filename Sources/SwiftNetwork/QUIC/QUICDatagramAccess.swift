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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(os)
internal import os
#endif

// MARK: - Reaching a datagram flow

// A QUIC datagram flow is a non-copyable value stored in the connection's secondary flow table, so
// like a stream, the only way to work on one is to borrow it from the table for the duration of a
// closure. The table is exclusively accessed for that whole time. Anything that would reach the
// table again from inside the closure has to wait until the borrow ends.
//
// A borrowed datagram flow shares the connection's `streamAccess` gate with streams: connection
// work that looks at flows (sending frames, closing, checking idleness) is recorded while the flow
// is borrowed and performed once the borrow ends.

@available(Network 0.1.0, *)
extension QUICConnection {

    /// Borrows a datagram flow, runs `body` on it, and then performs any connection work that was
    /// held back while it was borrowed.
    ///
    /// Returns `nil` without running `body` if there is no datagram flow with that identifier.
    @inline(always)
    func performOnDatagramFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout QUICDatagramFlow, inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R? {
        let wasBorrowed = streamAccess.borrowed
        streamAccess.borrowed = true
        let result: R?
        do throws(E) {
            result = try multiplexedSecondaryFlows.withFlow(flowID) { (flow: inout QUICDatagramFlow) throws(E) -> R in
                try body(&flow, &eventContext)
            }
        } catch {
            if endDatagramBorrow(restoring: wasBorrowed) {
                runDeferredStreamWork(in: &eventContext)
            }
            throw error
        }
        if endDatagramBorrow(restoring: wasBorrowed) {
            runDeferredStreamWork(in: &eventContext)
        }
        return result
    }

    /// Borrows a datagram flow from outside the protocol stack, where no event context is held.
    func performOnDatagramFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout QUICDatagramFlow) throws(E) -> R
    ) throws(E) -> R? {
        let wasBorrowed = streamAccess.borrowed
        streamAccess.borrowed = true
        let result: R?
        do throws(E) {
            result = try multiplexedSecondaryFlows.withFlow(flowID, body)
        } catch {
            if endDatagramBorrow(restoring: wasBorrowed) {
                performDeferredStreamWorkFromExternal()
            }
            throw error
        }
        if endDatagramBorrow(restoring: wasBorrowed) {
            performDeferredStreamWorkFromExternal()
        }
        return result
    }

    /// Marks the borrow as over. Returns whether the flow held back work for the connection, which
    /// is only the case for the outermost borrow.
    @inline(always)
    private func endDatagramBorrow(restoring wasBorrowed: Bool) -> Bool {
        streamAccess.borrowed = wasBorrowed
        return !wasBorrowed && streamAccess.hasDeferredWork
    }

    // MARK: Operations the datagram linkage calls

    #if DEBUG
    /// Checks that the upper protocol calling in is the one attached to the datagram flow.
    private func datagramFlowAcceptsCall(
        flow flowID: MultiplexedFlowIdentifier,
        from instance: InstanceIdentifier,
        _ label: String
    ) -> Bool {
        let valid = performOnDatagramFlow(flowID) { (flow: inout QUICDatagramFlow) -> Bool in
            do throws(ProtocolInstanceError) {
                try flow.validate(upper: instance, label)
                return true
            } catch {
                return false
            }
        }
        return valid ?? false
    }
    #endif

    func attachUpperProtocolToDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        _ upperProtocol: BaseInboundDatagramLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        // `attachUpperProtocolToNewFlow` already bound this upper when it created the flow, so
        // seeing the same one again is the expected second leg of the attach, not a conflict.
        // A *different* upper is still rejected.
        let bound = performOnDatagramFlow(flowID) { (flow: inout QUICDatagramFlow) -> Bool in
            guard flow.upper.isDetached || flow.upper == upperProtocol else {
                return false
            }
            flow.upper = upperProtocol
            return true
        }
        guard let bound else { throw NetworkError.posix(ENOENT) }
        guard bound else { throw NetworkError.posix(EALREADY) }

        do {
            try setup(
                flow: flowID,
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
        } catch let error {
            performOnDatagramFlow(flowID) { (flow: inout QUICDatagramFlow) in
                flow.upper = .init()
            }
            throw error
        }
    }

    func connectDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if DEBUG
        guard datagramFlowAcceptsCall(flow: flowID, from: instance, "connect") else { return }
        #endif
        guard let flowIdentifier = secondaryInstanceIdentifier(ofFlow: flowID) else { return }
        if isConnected(in: &eventContext) {
            if flowIdentifier.canCallConnect(requested: true, in: &eventContext) {
                connect(flow: flowID, in: &eventContext)
            }
        } else {
            flowIdentifier.connectRequested(in: &eventContext)
            connectInternal(in: &eventContext)
        }
        // Hand over anything buffered while this flow had no upper protocol. This runs after
        // connecting so the connected event is delivered first, matching the ordering the
        // non-detached path in `deliverConnectedEvent` produces.
        performOnDatagramFlow(flowID, in: &eventContext) {
            (flow: inout QUICDatagramFlow, ctx: inout NetworkContext.EventContext) in
            flow.drainQueuedEventsForUpperProtocol(in: &ctx)
        }
    }

    func disconnectDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if DEBUG
        guard datagramFlowAcceptsCall(flow: flowID, from: instance, "disconnect") else { return }
        #endif
        guard let flowIdentifier = secondaryInstanceIdentifier(ofFlow: flowID) else { return }
        if flowIdentifier.canCallDisconnect(in: &eventContext) {
            disconnect(flow: flowID, error: error, in: &eventContext)
        }
    }

    func handleApplicationEventForDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        handleApplicationEventForStream(flow: flowID, event: event, for: instance, in: &eventContext)
    }

    /// Detaches the upper protocol from a datagram flow and releases the flow.
    func detachDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        // First the flow itself: it checks the caller and releases whatever it holds.
        let tornDown = performOnDatagramFlow(flowID, in: &eventContext) {
            (flow: inout QUICDatagramFlow, ctx: inout NetworkContext.EventContext) -> Bool in
            do throws(ProtocolInstanceError) {
                try flow.validate(upper: instance, "detach")
            } catch {
                return false
            }
            flow.teardown(in: &ctx)
            return true
        }
        guard tornDown == true else { throw NetworkError.posix(EINVAL) }

        // Then the connection's view of the flow, which looks at the flow and so cannot happen
        // while it is borrowed.
        teardown(flow: flowID, in: &eventContext)

        // Finally release the flow. Once it is out of the table nothing else can reach it.
        if var flow = removeSecondaryFlow(flowID) {
            flow.upper = .init()
            flow.identifier.discardPendingEventsForUpperProtocol(in: &eventContext)
            flow.upperReceiveQueue.finalizeAllFramesAsFailed()
            flow.upperSendQueue.finalizeAllFramesAsFailed()
            flow.unregisterEventManager(in: &eventContext)
        }
        var connection = self
        connection.teardownIfPossible(in: &eventContext)
    }
}

#endif
