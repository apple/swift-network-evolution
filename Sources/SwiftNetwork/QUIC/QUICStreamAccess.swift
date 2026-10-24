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

// MARK: - Reaching a stream

// A QUIC stream is a non-copyable value stored in the connection's flow table, so the only
// way to work on one is to borrow it from the table for the duration of a closure. The table is
// exclusively accessed for that whole time. Anything that would reach the table again from inside
// the closure has to wait until the borrow ends.
//

/// Whether a stream is borrowed from the flow table, and the connection-level work that streams asked
/// for while it was. Kept together so a borrow touches one stored property, not several.
@available(Network 0.1.0, *)
struct StreamAccessState {
    /// Set while a stream is borrowed from the flow table
    var borrowed = false
    var sendFrames = false
    /// Set when a close was requested; holds whether a CONNECTION_CLOSE frame should be sent.
    var close: Bool? = nil
    /// Whether the connection should recheck if every stream is idle, which looks at every stream.
    var checkIdle = false

    /// Whether there is work that a borrowed stream held back for the connection.
    var hasDeferredWork: Bool { sendFrames || close != nil || checkIdle }
}

@available(Network 0.1.0, *)
extension QUICConnection {

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
        let result: R?
        streamAccess.borrowed = true
        do throws(E) {
            result = try multiplexedFlows.withFlow(flowID) { (stream: inout QUICStreamInstance) throws(E) -> R in
                try body(&stream, &eventContext)
            }
        } catch {
            if endBorrow() {
                runDeferredStreamWork(in: &eventContext)
            }
            throw error
        }
        if endBorrow() {
            runDeferredStreamWork(in: &eventContext)
        }
        return result
    }

    /// Borrows each stream in turn, then performs any connection work they held back.
    @inline(always)
    func applyToAllStreams(
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout QUICStreamInstance, inout NetworkContext.EventContext) -> Void
    ) {
        streamAccess.borrowed = true
        multiplexedFlows.forEachFlow { (stream: inout QUICStreamInstance) in
            body(&stream, &eventContext)
        }
        if endBorrow() {
            runDeferredStreamWork(in: &eventContext)
        }
    }

    /// Borrows a stream from outside the protocol stack, where no event context is held.
    func performOnStream<R: ~Copyable, E: Error>(
        _ flowID: MultiplexedFlowIdentifier,
        _ body: (inout QUICStreamInstance) throws(E) -> R
    ) throws(E) -> R? {
        let result: R?
        streamAccess.borrowed = true
        do throws(E) {
            result = try multiplexedFlows.withFlow(flowID, body)
        } catch {
            if endBorrow() {
                performDeferredStreamWorkFromExternal()
            }
            throw error
        }
        if endBorrow() {
            performDeferredStreamWorkFromExternal()
        }
        return result
    }

    /// Marks the borrow as over. Returns whether streams held back work for the connection.
    @inline(always)
    private func endBorrow() -> Bool {
        streamAccess.borrowed = false
        return streamAccess.hasDeferredWork
    }

    @inline(never)
    private func runDeferredStreamWork(in eventContext: inout NetworkContext.EventContext) {
        let work = streamAccess
        streamAccess = StreamAccessState()
        if let sendCloseFrame = work.close {
            // A close sends frames itself, so there is no point sending them first.
            close(sendCloseFrame: sendCloseFrame, in: &eventContext)
        } else if work.sendFrames {
            sendFrames(in: &eventContext)
        }
        if work.checkIdle {
            checkConnectionIdle(unackedPacketCount: ack.unackedPacketCount, in: &eventContext)
        }
    }

    private func performDeferredStreamWorkFromExternal() {
        fromExternal { eventContext in
            runDeferredStreamWork(in: &eventContext)
        }
    }

    // MARK: Operations the stream linkage calls

    #if DEBUG
    /// Checks that the upper protocol calling in is the one attached to the stream.
    private func streamAcceptsCall(
        flow flowID: MultiplexedFlowIdentifier,
        from instance: InstanceIdentifier,
        _ label: String
    ) -> Bool {
        let valid = performOnStream(flowID) { (stream: inout QUICStreamInstance) -> Bool in
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

    func connectStream(
        flow flowID: MultiplexedFlowIdentifier,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        // The identifier lookup doubles as the check that the stream is still there; the check that
        // the caller is the attached upper protocol only exists in debug builds.
        #if DEBUG
        guard streamAcceptsCall(flow: flowID, from: instance, "connect") else { return }
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

    func disconnectStream(
        flow flowID: MultiplexedFlowIdentifier,
        error: NetworkError?,
        for instance: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext
    ) {
        #if DEBUG
        guard streamAcceptsCall(flow: flowID, from: instance, "disconnect") else { return }
        #endif
        guard let streamIdentifier = instanceIdentifier(ofFlow: flowID) else { return }
        if streamIdentifier.canCallDisconnect(in: &eventContext) {
            disconnect(flow: flowID, error: error, in: &eventContext)
        }
    }

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
}

#endif
