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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
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

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

@available(Network 0.1.0, *)
extension QUICConnection {

    // MARK: - QUICStream access

    // A QUIC stream is a non-copyable value stored in the connection's flow table, so borrow it from
    // the table for the duration of a closure. The table is exclusively accessed for that whole time.
    // Anything that would reach the table again from inside the closure has to wait until the borrow ends.

    /// Borrows a stream, runs `body` on it, and then performs any connection work that was held
    /// back while it was borrowed.
    ///
    /// Returns `nil` without running `body` if there is no stream with that identifier.
    @inline(always)
    func performOnStream<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout QUICStreamInstance, inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R? {
        try withFlowBorrowed(of: .streams, in: &eventContext) {
            (eventContext: inout NetworkContext.EventContext) throws(E) -> R? in
            try multiplexedFlows.withFlow(flowID) { (stream: inout QUICStreamInstance) throws(E) -> R in
                try body(&stream, &eventContext)
            }
        }
    }

    /// Marks a flow table as borrowed while `body` runs, then performs the connection work that was held
    /// back while it was borrowed. The `defer` makes that happen on every way out, including a throw,
    /// so a borrow cannot be left open or its deferred work lost.
    ///
    /// Borrows nest: only the outermost one performs the deferred work.
    @inline(always)
    func withFlowBorrowed<R: ~Copyable, E: Error>(
        of table: QUICConnectionStateMachine.Table,
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        let wasFlowBorrowed = stateMachine.beginFlowBorrow(of: table)
        defer {
            if let work = stateMachine.endFlowBorrow(of: table, wasFlowBorrowed: wasFlowBorrowed) {
                runDeferredStreamWork(work, in: &eventContext)
            }
        }
        return try body(&eventContext)
    }

    /// The same, from outside the protocol stack, where no event context is held.
    func withFlowBorrowed<R: ~Copyable, E: Error>(
        of table: QUICConnectionStateMachine.Table,
        _ body: () throws(E) -> R
    ) throws(E) -> R {
        let wasFlowBorrowed = stateMachine.beginFlowBorrow(of: table)
        defer {
            if let work = stateMachine.endFlowBorrow(of: table, wasFlowBorrowed: wasFlowBorrowed) {
                performDeferredStreamWorkFromExternal(work)
            }
        }
        return try body()
    }

    /// Borrows a stream for the packet builder, which writes it while sending frames. Sending holds the
    /// send path, so nothing here can defer work; this only notes the borrow of the table so that a
    /// second borrow of it is caught in debug builds.
    @inline(always)
    func withStreamBorrowed<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout QUICStreamInstance) throws(E) -> R
    ) throws(E) -> R? {
        assert(stateMachine.isSendActive, "A stream is borrowed for sending without the send path claimed")
        stateMachine.beginTableBorrow(.streams)
        defer { stateMachine.endTableBorrow(.streams) }
        return try multiplexedFlows.withFlow(flowID, body)
    }

    /// Borrows each stream in turn, then performs any connection work they held back.
    @inline(always)
    func applyToAllStreams(
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout QUICStreamInstance, inout NetworkContext.EventContext) -> Void
    ) {
        withFlowBorrowed(of: .streams, in: &eventContext) { (eventContext: inout NetworkContext.EventContext) in
            multiplexedFlows.forEachFlow { (stream: inout QUICStreamInstance) in
                body(&stream, &eventContext)
            }
        }
    }

    /// Borrows a stream from outside the protocol stack, where no event context is held.
    /// Used in testing
    func performOnStream<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout QUICStreamInstance) throws(E) -> R
    ) throws(E) -> R? {
        try withFlowBorrowed(of: .streams) { () throws(E) -> R? in
            try multiplexedFlows.withFlow(flowID, body)
        }
    }

    @inline(never)
    func runDeferredStreamWork(
        _ work: QUICConnectionStateMachine.DeferredWork,
        in eventContext: inout NetworkContext.EventContext
    ) {
        if let sendCloseFrame = work.close {
            // A close sends frames itself, so there is no point sending them first.
            close(sendCloseFrame: sendCloseFrame, in: &eventContext)
            // The connection is closing, so the sends that waited no longer matter, and neither does
            // whether it is idle. A close that did not reach its own send (the connection was already
            // closing, or never started) would leave those sends, and the paths they hold, to fire on
            // some later release, so drop them here.
            _ = stateMachine.takePlainSend()
            _ = takePathSends()
            return
        }
        if work.replaysSends {
            // The sends the borrowed flows triggered, with the flags they asked for
            replayDeferredSends(in: &eventContext)
        }
        if work.checkIdle {
            checkConnectionIdle(unackedPacketCount: ack.unackedPacketCount, in: &eventContext)
        }
    }

    func performDeferredStreamWorkFromExternal(_ work: QUICConnectionStateMachine.DeferredWork) {
        fromExternal { eventContext in
            runDeferredStreamWork(work, in: &eventContext)
        }
    }

    // MARK: Operations the stream linkage calls

    #if DEBUG
    /// Checks that the upper protocol calling in is the one attached to the stream.
    private func streamAcceptsCall(
        flow flowID: MultiplexedFlowIdentifier,
        from instance: InstanceIdentifier,
        _ label: String,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        let valid = performOnStream(flowID, in: &eventContext) {
            (stream: inout QUICStreamInstance, _: inout NetworkContext.EventContext) -> Bool in
            do throws(ProtocolInstanceError) {
                try stream.validate(upper: instance, label)
                return true
            } catch {
                return false
            }
        }
        return valid ?? false
    }
    #endif

    /// Used in BaseProtocolLinkages
    func attachUpperProtocolToStream(
        flow flowID: MultiplexedFlowIdentifier,
        _ upperProtocol: BaseInboundStreamLinkage,
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        // `attachUpperProtocolToNewFlow` already bound this upper when it created the flow, so
        // seeing the same one again is the expected second leg of the attach, not a conflict.
        // A *different* upper is still rejected.
        let bound = performOnStream(flowID) { (stream: inout QUICStreamInstance) -> Bool in
            guard stream.upper.isDetached || stream.upper == upperProtocol else {
                return false
            }
            stream.upper = upperProtocol
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
            performOnStream(flowID) { (stream: inout QUICStreamInstance) in
                stream.upper = .init()
            }
            throw error
        }
    }
    /// Used in BaseProtocolLinkages
    func connectStream(
        flow flowID: MultiplexedFlowIdentifier,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // The identifier lookup doubles as the check that the stream is still there; the check that
        // the caller is the attached upper protocol only exists in debug builds.
        #if DEBUG
        guard streamAcceptsCall(flow: flowID, from: instance, "connect", in: &eventContext) else { return }
        #endif
        guard let streamIdentifier = instanceIdentifier(ofFlow: flowID) else { return }
        if isConnected(in: &eventContext) {
            if streamIdentifier.canCallConnect(requested: true, in: &eventContext) {
                connect(flow: flowID, in: &eventContext)
            }
        } else {
            streamIdentifier.connectRequested(in: &eventContext)
            connectInternal(in: &eventContext)
        }
        // Hand over anything buffered while this flow had no upper protocol. This runs after
        // connecting so the connected event is delivered first, matching the ordering the
        // non-detached path in `deliverConnectedEvent` produces.
        performOnStream(flowID, in: &eventContext) {
            (stream: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
            stream.drainQueuedEventsForUpperProtocol(in: &ctx)
        }
    }
    /// Used in BaseProtocolLinkages
    func disconnectStream(
        flow flowID: MultiplexedFlowIdentifier,
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if DEBUG
        guard streamAcceptsCall(flow: flowID, from: instance, "disconnect", in: &eventContext) else { return }
        #endif
        guard let streamIdentifier = instanceIdentifier(ofFlow: flowID) else { return }
        if streamIdentifier.canCallDisconnect(in: &eventContext) {
            disconnect(flow: flowID, error: error, in: &eventContext)
        }
    }
    /// Used in BaseProtocolLinkages
    func handleApplicationEventForStream(
        flow flowID: MultiplexedFlowIdentifier,
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // Don't validate upper, can pass through
        if handleApplicationEvent(flow: flowID, event: event, in: &eventContext) == .consumed {
            return
        }
        applyToAllPaths { path in
            path.lower.invokeApplicationEvent(event: event, for: instance, in: &eventContext)
        }
    }

    /// Detaches the upper protocol from a stream and releases the stream.
    /// Used in BaseProtocolLinkages
    func detachStream(
        flow flowID: MultiplexedFlowIdentifier,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        // First the stream itself: it checks the caller and closes its own side.
        let tornDown = performOnStream(flowID, in: &eventContext) {
            (stream: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) -> Bool in
            do throws(ProtocolInstanceError) {
                try stream.validate(upper: instance, "detach")
            } catch {
                return false
            }
            stream.teardown(in: &ctx)
            return true
        }
        guard tornDown == true else { throw NetworkError.posix(EINVAL) }

        // Then the connection's view of the flow, which looks at the stream and so cannot happen
        // while it is borrowed.
        teardown(flow: flowID, in: &eventContext)

        // Finally release the stream. Once it is out of the table nothing else can reach it.
        if var stream = removeFlow(flowID) {
            stream.upper = .init()
            stream.identifier.discardPendingEventsForUpperProtocol(in: &eventContext)
            stream.upperReceiveQueue.finalizeAllFramesAsFailed()
            stream.upperSendQueue.finalizeAllFramesAsFailed()
            stream.releaseResources()
            stream.unregisterEventManager(in: &eventContext)
        }
        var connection = self
        connection.teardownIfPossible(in: &eventContext)
    }

    // MARK: - QUICDatagramFlow access

    // A QUIC datagram flow is a non-copyable value stored in the connection's flow table, so borrow it from
    // the table for the duration of a closure. The table is exclusively accessed for that whole time.
    // Anything that would reach the table again from inside the closure has to wait until the borrow ends.

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
        try withFlowBorrowed(of: .secondary, in: &eventContext) {
            (eventContext: inout NetworkContext.EventContext) throws(E) -> R? in
            try multiplexedSecondaryFlows.withFlow(flowID) { (flow: inout QUICDatagramFlow) throws(E) -> R in
                try body(&flow, &eventContext)
            }
        }
    }

    /// Borrows a datagram flow from outside the protocol stack, where no event context is held.
    func performOnDatagramFlow<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout QUICDatagramFlow) throws(E) -> R
    ) throws(E) -> R? {
        try withFlowBorrowed(of: .secondary) { () throws(E) -> R? in
            try multiplexedSecondaryFlows.withFlow(flowID, body)
        }
    }

    // MARK: Operations the datagram linkage calls

    #if DEBUG
    /// Checks that the upper protocol calling in is the one attached to the datagram flow.
    private func datagramFlowAcceptsCall(
        flow flowID: MultiplexedFlowIdentifier,
        from instance: InstanceIdentifier,
        _ label: String,
        in eventContext: inout NetworkContext.EventContext
    ) -> Bool {
        let valid = performOnDatagramFlow(flowID, in: &eventContext) {
            (flow: inout QUICDatagramFlow, _: inout NetworkContext.EventContext) -> Bool in
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

    /// Used in BaseProtocolLinkages
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

    /// Used in BaseProtocolLinkages
    func connectDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if DEBUG
        guard datagramFlowAcceptsCall(flow: flowID, from: instance, "connect", in: &eventContext) else { return }
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

    /// Used in BaseProtocolLinkages
    func disconnectDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if DEBUG
        guard datagramFlowAcceptsCall(flow: flowID, from: instance, "disconnect", in: &eventContext) else { return }
        #endif
        guard let flowIdentifier = secondaryInstanceIdentifier(ofFlow: flowID) else { return }
        if flowIdentifier.canCallDisconnect(in: &eventContext) {
            disconnect(flow: flowID, error: error, in: &eventContext)
        }
    }

    /// Used in BaseProtocolLinkages
    func handleApplicationEventForDatagramFlow(
        flow flowID: MultiplexedFlowIdentifier,
        event: ApplicationEvent,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        handleApplicationEventForStream(flow: flowID, event: event, for: instance, in: &eventContext)
    }

    /// Detaches the upper protocol from a datagram flow and releases the flow.
    /// Used in BaseProtocolLinkages
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
