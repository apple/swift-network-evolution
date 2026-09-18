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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
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
struct ProtocolEventManagerState: ~Copyable {
    enum EventState {
        case idle
        case handlingCallFromUpperProtocol
        case handlingAsyncCall
        case handlingExternalCall
        case handlingTimerWakeupCall
        case processingEventFromLowerProtocol
    }

    // Connected state only moves forward
    enum ConnectedState: CustomStringConvertible {
        case initial  // Not reported connected or disconnected
        case connected  // Reported connected, won't get a connect call
        case disconnected  // Reported disconnected

        var description: String {
            switch self {
            case .initial: return "initial"
            case .connected: return "connected"
            case .disconnected: return "disconnected"
            }
        }
    }

    // Connect call state only moves forward
    enum ConnectCallState: CustomStringConvertible {
        case initial  // Neither connect nor disconnect called
        case connectRequested  // Connect was previously requested, but not called
        case connectCalled  // Connect was previously called
        case disconnectCalled  // Disconnect was previously called

        var description: String {
            switch self {
            case .initial: return "initial"
            case .connectRequested: return "connectRequested"
            case .connectCalled: return "connectCalled"
            case .disconnectCalled: return "disconnectCalled"
            }
        }
    }

    enum PendingEvent: ~Copyable {
        typealias EventBlock = (inout NetworkContext.EventContext, InstanceIdentifier) -> Void
        typealias ErrorEventBlock = (inout NetworkContext.EventContext, InstanceIdentifier, NetworkError?) -> Void
        typealias NewInboundFlowEventBlock = (
            inout NetworkContext.EventContext,
            InstanceIdentifier,
            InstanceIdentifier,
            AbstractProtocolMetadata?
        ) -> Void
        typealias NetworkProtocolEventBlock = (
            inout NetworkContext.EventContext,
            InstanceIdentifier,
            NetworkProtocolEvent
        ) -> Void

        case connected(_ from: InstanceIdentifier, _ to: InstanceIdentifier, _ block: EventBlock)
        case disconnected(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            error: NetworkError?,
            _ block: ErrorEventBlock
        )
        case inboundDataAvailable(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            _ block: EventBlock
        )
        case outboundRoomAvailable(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            _ block: EventBlock
        )
        case inboundAborted(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            error: NetworkError?,
            _ block: ErrorEventBlock
        )
        case outboundAborted(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            error: NetworkError?,
            _ block: ErrorEventBlock
        )
        case newInboundFlow(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            flowInstance: InstanceIdentifier,
            flowMetadata: AbstractProtocolMetadata?,
            _ block: NewInboundFlowEventBlock
        )
        case networkProtocolEvent(
            _ from: InstanceIdentifier,
            _ to: InstanceIdentifier,
            event: NetworkProtocolEvent,
            _ block: NetworkProtocolEventBlock
        )

        fileprivate func run(in eventContext: inout NetworkContext.EventContext) {
            switch self {
            case .connected(let from, _, let block): block(&eventContext, from)
            case .disconnected(let from, _, let error, let block): block(&eventContext, from, error)
            case .inboundDataAvailable(let from, _, let block): block(&eventContext, from)
            case .outboundRoomAvailable(let from, _, let block): block(&eventContext, from)
            case .inboundAborted(let from, _, let error, let block): block(&eventContext, from, error)
            case .outboundAborted(let from, _, let error, let block): block(&eventContext, from, error)
            case .newInboundFlow(let from, _, let flow, let metadata, let block):
                block(&eventContext, from, flow, metadata)
            case .networkProtocolEvent(let from, _, let event, let block): block(&eventContext, from, event)
            }
        }

        @inline(always)
        fileprivate var toInstance: InstanceIdentifier {
            switch self {
            case .connected(_, let to, _): return to
            case .disconnected(_, let to, _, _): return to
            case .inboundDataAvailable(_, let to, _): return to
            case .outboundRoomAvailable(_, let to, _): return to
            case .inboundAborted(_, let to, _, _): return to
            case .outboundAborted(_, let to, _, _): return to
            case .newInboundFlow(_, let to, _, _, _): return to
            case .networkProtocolEvent(_, let to, _, _): return to
            }
        }

        // Enqueues this event on its target and returns the target's event state index, having
        // taken a hold on that state. Returns `.none` if the event has no live target.
        fileprivate consuming func deliver(
            in eventContext: inout NetworkContext.EventContext
        ) -> NetworkStateIndex {
            let toInstance = self.toInstance
            guard !toInstance.isNone else { return .none }
            return toInstance.addEventFromLowerProtocolHoldingState(event: self, in: &eventContext)
        }

        fileprivate consuming func reassign(
            to newTo: InstanceIdentifier,
            _ newBlock: @escaping EventBlock,
            _ newErrorBlock: @escaping ErrorEventBlock,
            _ newInboundFlowBlock: @escaping NewInboundFlowEventBlock,
            _ newNetworkProtocolEventBlock: @escaping NetworkProtocolEventBlock,
            _ newInboundAbortedBlock: @escaping ErrorEventBlock,
            _ newOutboundAbortedBlock: @escaping ErrorEventBlock
        ) -> PendingEvent {
            switch self {
            case .connected(let from, _, _): return .connected(from, newTo, newBlock)
            case .disconnected(let from, _, let error, _):
                return .disconnected(from, newTo, error: error, newErrorBlock)
            case .inboundDataAvailable(let from, _, _): return .inboundDataAvailable(from, newTo, newBlock)
            case .outboundRoomAvailable(let from, _, _): return .outboundRoomAvailable(from, newTo, newBlock)
            case .inboundAborted(let from, _, let error, _):
                return .inboundAborted(from, newTo, error: error, newInboundAbortedBlock)
            case .outboundAborted(let from, _, let error, _):
                return .outboundAborted(from, newTo, error: error, newOutboundAbortedBlock)
            case .newInboundFlow(let from, _, let flow, let metadata, _):
                return .newInboundFlow(
                    from,
                    newTo,
                    flowInstance: flow,
                    flowMetadata: metadata,
                    newInboundFlowBlock
                )
            case .networkProtocolEvent(let from, _, let event, _):
                return .networkProtocolEvent(from, newTo, event: event, newNetworkProtocolEventBlock)
            }
        }

        fileprivate var isConnected: Bool {
            switch self {
            case .connected: return true
            default: return false
            }
        }

        fileprivate var isDisconnected: Bool {
            switch self {
            case .disconnected: return true
            default: return false
            }
        }

    }

    mutating func startCallFromUpperProtocol() {
        guard eventState == .idle else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .handlingCallFromUpperProtocol
    }

    mutating func finishCallFromUpperProtocol() {
        guard eventState == .handlingCallFromUpperProtocol else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .idle
    }

    mutating func startExternalCall() -> Bool {
        guard eventState == .idle else {
            // Don't mark as a fatal error, since this is often used
            // as a guard to ensure that the events will unwind
            return false
        }
        eventState = .handlingExternalCall
        return true
    }

    mutating func finishExternalCall() {
        guard eventState == .handlingExternalCall else {
            // Don't mark as a fatal error, since this is often used
            // as a guard to ensure that the events will unwind
            return
        }
        eventState = .idle
    }

    mutating func addEventFromLowerProtocol(event: consuming PendingEvent) {
        pendingEventsFromLowerProtocol.append(event)
    }

    mutating func startTimerWakeupCall() {
        guard eventState == .idle else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .handlingTimerWakeupCall
    }

    mutating func finishTimerWakeupCall() {
        guard eventState == .handlingTimerWakeupCall else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .idle
    }

    mutating func startAsyncCall() {
        guard eventState == .idle else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .handlingAsyncCall
    }

    mutating func finishAsyncCall() {
        guard eventState == .handlingAsyncCall else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .idle
    }

    mutating func startDrainingPendingEventsFromLower(hasNewEvent: Bool = false) -> Int {
        guard eventState == .idle else {
            // Fast exit if we're not fully unwound
            return 0
        }

        guard !pendingEventsFromLowerProtocol.isEmpty else {
            // Fast path case for no pending events
            if hasNewEvent {
                eventState = .processingEventFromLowerProtocol
                return 1
            } else {
                return 0
            }
        }

        eventState = .processingEventFromLowerProtocol
        if hasNewEvent {
            return pendingEventsFromLowerProtocol.count + 1
        } else {
            return pendingEventsFromLowerProtocol.count
        }
    }

    mutating func readPendingEventFromLower() -> PendingEvent {
        pendingEventsFromLowerProtocol.removeFirst()
    }

    mutating func finishDrainingPendingEventsFromLower() {
        guard eventState == .processingEventFromLowerProtocol else {
            fatalError("Illegal state: \(eventState)")
        }
        eventState = .idle
    }

    func countPendingEventsToUpper() -> Int {
        pendingEventsToDeliverToUpperProtocol.count
    }

    mutating func readPendingEventToUpper() -> PendingEvent? {
        pendingEventsToDeliverToUpperProtocol.popFirst()
    }

    mutating func addPendingEventToDeliverToUpperProtocol(_ event: consuming PendingEvent) {
        guard eventState != .idle else {
            fatalError("Illegal state: \(eventState)")
        }
        pendingEventsToDeliverToUpperProtocol.append(event)
    }

    mutating func enqueuePendingEventForUpperProtocol(_ event: consuming PendingEvent) {
        unassignedPendingEventsToDeliverToUpperProtocol.append(event)
    }

    mutating func discardPendingEventsForUpperProtocol() {
        unassignedPendingEventsToDeliverToUpperProtocol.removeAll()
    }

    var eventState: EventState = .idle
    var connectedState: ConnectedState = .initial
    var connectCallState: ConnectCallState = .initial
    var pendingEventsFromLowerProtocol = NetworkUniqueDeque<PendingEvent>()
    var pendingEventsToDeliverToUpperProtocol = NetworkUniqueDeque<PendingEvent>()
    var unassignedPendingEventsToDeliverToUpperProtocol = NetworkUniqueDeque<PendingEvent>()

    // Number of things that still hold this index: queued async blocks, at most one scheduled
    // timer wakeup, any such block currently running, and any event delivered to this state but
    // not yet drained. They all dereference the index, so the event state must outlive them;
    // see `retiring`.
    private(set) var outstandingHolders: UInt32 = 0

    // Whether the scheduled timer wakeup is currently counted in `outstandingHolders`. Timers are
    // rescheduled in place rather than stacked, so this keeps a reschedule from counting twice.
    private var timerScheduled = false

    // Set when unregistration was requested while blocks were still outstanding. The last block
    // to finish removes the event state.
    var retiring = false

    mutating func addOutstandingHolder() {
        outstandingHolders += 1
    }

    mutating func finishOutstandingHolder() {
        outstandingHolders -= 1
    }

    mutating func addScheduledTimer() {
        // Rescheduling replaces the existing timer entry, so it is still just one outstanding
        // wakeup.
        guard !timerScheduled else { return }
        timerScheduled = true
        outstandingHolders += 1
    }

    mutating func clearScheduledTimer() {
        guard timerScheduled else { return }
        timerScheduled = false
        outstandingHolders -= 1
    }

    // Whether the event state can be removed now.
    var canRemove: Bool {
        outstandingHolders == 0 && eventState == .idle && !drainingEvents
    }

    var drainingEvents = false

    var isIdle: Bool {
        eventState == .idle
    }

    init() {}
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct ProtocolEventManager: ~Copyable {
    var contextIndex: NetworkStateIndex
    var context: NetworkContext?
    public init() {
        contextIndex = .none
        context = nil
    }
    internal mutating func register(
        with context: NetworkContext,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkStateIndex {
        if !contextIndex.isNone {
            // Already registered
            return contextIndex
        }
        self.context = context
        let registeredIndex = eventContext.registerProtocolEventState()
        contextIndex = registeredIndex
        return registeredIndex
    }
    internal mutating func unregister(in eventContext: inout NetworkContext.EventContext) {
        guard !contextIndex.isNone else { return }
        eventContext.retireProtocolEventState(contextIndex)
        self.contextIndex = .none
    }
    /// Catches a protocol instance that is destroyed while its event state is still registered.
    deinit {
        if !contextIndex.isNone {
            preconditionFailure(
                "Protocol event manager destroyed while still registered; the protocol instance "
                    + "must unregister its event manager during teardown"
            )
        }
    }
}

@available(Network 0.1.0, *)
extension NetworkContext.EventContext {
    fileprivate func softAssert() {
        #if DEBUG
        self.assert()
        #endif
    }

    // Marks a scheduled timer for `index` as no longer outstanding, dropping the event state if
    // that was the last thing keeping a retiring one alive.
    fileprivate mutating func clearScheduledTimer(_ index: NetworkStateIndex) {
        protocolEventStates[index].clearScheduledTimer()
        removeProtocolEventStateIfRetired(index)
    }

    // Removes an event state that is retiring once nothing still holds it.
    fileprivate mutating func removeProtocolEventStateIfRetired(_ index: NetworkStateIndex) {
        guard protocolEventStates[index].retiring, protocolEventStates[index].canRemove else {
            return
        }
        unregisterProtocolEventState(index)
    }

    // Retires the event state for `index`, removing it now if nothing still holds it.
    fileprivate mutating func retireProtocolEventState(_ index: NetworkStateIndex) {
        guard protocolEventStates[index].canRemove else {
            protocolEventStates[index].retiring = true
            return
        }
        unregisterProtocolEventState(index)
    }
    // Drains the events `deliver(in:)` enqueued on `indexToTrigger`, then releases the hold it
    // took. The hold is why this index is still valid: retirement of this state is deferred until
    // the hold goes away, even if an earlier event in the same batch requested it.
    @inline(always)
    fileprivate mutating func runEvents(on indexToTrigger: NetworkStateIndex) {
        let eventCount = protocolEventStates[indexToTrigger].startDrainingPendingEventsFromLower()
        if eventCount > 0 {
            for _ in 0..<eventCount {
                let pendingEvent = protocolEventStates[indexToTrigger].readPendingEventFromLower()
                pendingEvent.run(in: &self)
            }
            protocolEventStates[indexToTrigger].finishDrainingPendingEventsFromLower()
            drainPendingEvents(index: indexToTrigger)
        }
        protocolEventStates[indexToTrigger].finishOutstandingHolder()
        removeProtocolEventStateIfRetired(indexToTrigger)
    }

    @inline(always)
    fileprivate mutating func runEvent(_ event: consuming ProtocolEventManagerState.PendingEvent) {
        let instanceToTrigger = event.toInstance
        guard !instanceToTrigger.isNone else { return }
        let indexToTrigger = instanceToTrigger.protocolEventStateIndex()
        guard !indexToTrigger.isNone else { return }

        let eventCount = protocolEventStates[indexToTrigger].startDrainingPendingEventsFromLower(hasNewEvent: true)
        if eventCount == 0 {
            // Cannot run events. Enqueue new event.
            protocolEventStates[indexToTrigger].addEventFromLowerProtocol(event: event)
            return
        } else if eventCount == 1 {
            // Fast path for common case. Just run the new event, don't enqueue.
            event.run(in: &self)
        } else {
            // Enqueue new event, then run all events.
            protocolEventStates[indexToTrigger].addEventFromLowerProtocol(event: event)
            for _ in 0..<eventCount {
                let pendingEvent = protocolEventStates[indexToTrigger].readPendingEventFromLower()
                pendingEvent.run(in: &self)
            }
        }
        protocolEventStates[indexToTrigger].finishDrainingPendingEventsFromLower()
        drainPendingEvents(index: indexToTrigger)
    }

    fileprivate mutating func drainPendingEvents(index: NetworkStateIndex) {
        if protocolEventStates[index].isIdle && !protocolEventStates[index].drainingEvents {
            protocolEventStates[index].drainingEvents = true
            let lowerEvents = protocolEventStates[index].startDrainingPendingEventsFromLower()
            if lowerEvents > 0 {
                for _ in 0..<lowerEvents {
                    protocolEventStates[index].readPendingEventFromLower().run(in: &self)
                }
                protocolEventStates[index].finishDrainingPendingEventsFromLower()
            }
            var upperEvents = protocolEventStates[index].countPendingEventsToUpper()
            while upperEvents > 0 {
                if upperEvents == 1 {
                    // For cases with one event, just deliver to the lower protocol queue and run
                    if let pendingEvent = protocolEventStates[index].readPendingEventToUpper() {
                        runEvent(pendingEvent)
                    }
                } else {
                    // For cases with more than one event, batch all of the events in the lower protocol queue and run them in one pass
                    var indicesToTrigger = Deque<NetworkStateIndex>(minimumCapacity: upperEvents)
                    for _ in 0..<upperEvents {
                        if let pendingEvent = protocolEventStates[index].readPendingEventToUpper() {
                            let indexToTrigger = pendingEvent.deliver(in: &self)
                            if !indexToTrigger.isNone {
                                indicesToTrigger.append(indexToTrigger)
                            }
                        }
                    }
                    while let indexToTrigger = indicesToTrigger.popFirst() {
                        runEvents(on: indexToTrigger)
                    }
                }
                upperEvents = protocolEventStates[index].countPendingEventsToUpper()
            }
            protocolEventStates[index].drainingEvents = false
            // Draining counts as holding this state, so it is the last holder when retirement was
            // requested while the loop above was running. Calls that only drain on the way out —
            // `handleCallFromUpperProtocol` and `fromExternal` — depend on this hook.
            removeProtocolEventStateIfRetired(index)
        }
    }

    fileprivate mutating func deliverEventToUpperProtocol(
        index: NetworkStateIndex,
        parentIndex: NetworkStateIndex,
        event: consuming ProtocolEventManagerState.PendingEvent,
        drain: Bool = true
    ) {
        softAssert()
        if event.isConnected {
            switch protocolEventStates[index].connectedState {
            case .initial: protocolEventStates[index].connectedState = .connected
            case .connected, .disconnected: return  // Don't deliver a redundant event
            }
        } else if event.isDisconnected {
            switch protocolEventStates[index].connectedState {
            case .disconnected: return  // Don't deliver a redundant event
            default: protocolEventStates[index].connectedState = .disconnected
            }
        }
        if !parentIndex.isNone {
            protocolEventStates[parentIndex].addPendingEventToDeliverToUpperProtocol(event)
            if drain {
                drainPendingEvents(index: parentIndex)
            }
        } else {
            protocolEventStates[index].addPendingEventToDeliverToUpperProtocol(event)
        }
    }

    fileprivate mutating func reassignQueuedPendingEventsForUpperProtocol(
        index: NetworkStateIndex,
        parentIndex: NetworkStateIndex,
        newUpper: InstanceIdentifier,
        block: @escaping ProtocolEventManagerState.PendingEvent.EventBlock,
        errorBlock: @escaping ProtocolEventManagerState.PendingEvent.ErrorEventBlock,
        newInboundFlowBlock: @escaping ProtocolEventManagerState.PendingEvent.NewInboundFlowEventBlock,
        networkProtocolEventBlock: @escaping ProtocolEventManagerState.PendingEvent.NetworkProtocolEventBlock,
        inboundAbortedBlock: @escaping ProtocolEventManagerState.PendingEvent.ErrorEventBlock,
        outboundAbortedBlock: @escaping ProtocolEventManagerState.PendingEvent.ErrorEventBlock
    ) {
        softAssert()
        if !parentIndex.isNone {
            var foundEvents = false
            while let event = protocolEventStates[index].unassignedPendingEventsToDeliverToUpperProtocol.popFirst() {
                let event = event.reassign(
                    to: newUpper,
                    block,
                    errorBlock,
                    newInboundFlowBlock,
                    networkProtocolEventBlock,
                    inboundAbortedBlock,
                    outboundAbortedBlock
                )
                deliverEventToUpperProtocol(index: index, parentIndex: parentIndex, event: event, drain: false)
                foundEvents = true
            }
            if foundEvents {
                drainPendingEvents(index: parentIndex)
            }
        } else {
            while let event = protocolEventStates[index].unassignedPendingEventsToDeliverToUpperProtocol.popFirst() {
                let event = event.reassign(
                    to: newUpper,
                    block,
                    errorBlock,
                    newInboundFlowBlock,
                    networkProtocolEventBlock,
                    inboundAbortedBlock,
                    outboundAbortedBlock
                )
                deliverEventToUpperProtocol(index: index, parentIndex: .none, event: event, drain: false)
            }
        }
    }

    fileprivate mutating func enqueuePendingEventForUpperProtocol(
        index: NetworkStateIndex,
        event: consuming ProtocolEventManagerState.PendingEvent
    ) {
        softAssert()
        protocolEventStates[index].enqueuePendingEventForUpperProtocol(event)
    }

    fileprivate mutating func discardPendingEventsForUpperProtocol(index: NetworkStateIndex) {
        softAssert()
        protocolEventStates[index].discardPendingEventsForUpperProtocol()
    }

    fileprivate mutating func addEventFromLowerProtocol(
        index: NetworkStateIndex,
        event: consuming ProtocolEventManagerState.PendingEvent
    ) {
        softAssert()
        protocolEventStates[index].addEventFromLowerProtocol(event: event)
    }

    fileprivate mutating func addEventFromLowerProtocolHoldingState(
        index: NetworkStateIndex,
        event: consuming ProtocolEventManagerState.PendingEvent
    ) {
        softAssert()
        protocolEventStates[index].addEventFromLowerProtocol(event: event)
        protocolEventStates[index].addOutstandingHolder()
    }

    fileprivate mutating func handleCallFromUpperProtocol<R, E: Error>(
        index: NetworkStateIndex,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        softAssert()
        protocolEventStates[index].startCallFromUpperProtocol()
        defer {
            protocolEventStates[index].finishCallFromUpperProtocol()
            drainPendingEvents(index: index)
        }
        return try body(&self)
    }

    fileprivate mutating func handleCallFromUpperProtocol<R: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        softAssert()
        protocolEventStates[index].startCallFromUpperProtocol()
        defer {
            protocolEventStates[index].finishCallFromUpperProtocol()
            drainPendingEvents(index: index)
        }
        return try body(&self)
    }

    fileprivate mutating func handleCallFromUpperProtocol<R, T: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ value: consuming T,
        _ body: (inout NetworkContext.EventContext, consuming T) throws(E) -> R
    ) throws(E) -> R {
        softAssert()
        protocolEventStates[index].startCallFromUpperProtocol()
        defer {
            protocolEventStates[index].finishCallFromUpperProtocol()
            drainPendingEvents(index: index)
        }
        return try body(&self, value)
    }

    fileprivate mutating func fromExternal<R, E: Error>(
        index: NetworkStateIndex,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        softAssert()
        let startedExternalCall = protocolEventStates[index].startExternalCall()
        defer {
            if startedExternalCall {
                protocolEventStates[index].finishExternalCall()
                drainPendingEvents(index: index)
            }
        }
        return try body(&self)
    }

    fileprivate mutating func fromExternal<R: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        softAssert()
        let startedExternalCall = protocolEventStates[index].startExternalCall()
        defer {
            if startedExternalCall {
                protocolEventStates[index].finishExternalCall()
                drainPendingEvents(index: index)
            }
        }
        return try body(&self)
    }

    fileprivate mutating func fromExternal<R, T: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ value: consuming T,
        _ body: (inout NetworkContext.EventContext, consuming T) throws(E) -> R
    ) throws(E) -> R {
        softAssert()
        let startedExternalCall = protocolEventStates[index].startExternalCall()
        defer {
            if startedExternalCall {
                protocolEventStates[index].finishExternalCall()
                drainPendingEvents(index: index)
            }
        }
        return try body(&self, value)
    }

    fileprivate mutating func runAsync(
        index: NetworkStateIndex,
        _ block: (inout NetworkContext.EventContext) -> Void
    ) {
        protocolEventStates[index].startAsyncCall()
        defer {
            protocolEventStates[index].finishAsyncCall()
            drainPendingEvents(index: index)
            // This block no longer holds the index. Account for it after draining, since draining
            // can schedule further work, and drop the event state if this was the last holder.
            protocolEventStates[index].finishOutstandingHolder()
            removeProtocolEventStateIfRetired(index)
        }
        block(&self)
    }

    fileprivate mutating func runTimerWakeup(
        index: NetworkStateIndex,
        _ wakeup: (inout NetworkContext.EventContext) -> Void
    ) {
        assert()
        // The scheduler drops a timer entry when it fires, so that entry is no longer outstanding.
        // The wakeup call itself now holds the index instead: `wakeup` can unregister this event
        // state, and the `defer` below still needs it. Swapping one holder for the other keeps the
        // count from reaching zero mid-call, and lets `wakeup` arm a fresh timer.
        protocolEventStates[index].addOutstandingHolder()
        protocolEventStates[index].clearScheduledTimer()
        protocolEventStates[index].startTimerWakeupCall()
        defer {
            protocolEventStates[index].finishTimerWakeupCall()
            drainPendingEvents(index: index)
            protocolEventStates[index].finishOutstandingHolder()
            removeProtocolEventStateIfRetired(index)
        }
        wakeup(&self)
    }

    fileprivate mutating func connectRequested(index: NetworkStateIndex) {
        softAssert()
        if protocolEventStates[index].connectCallState == .initial {
            // Connect can't be called yet, but remember that it has been requested
            protocolEventStates[index].connectCallState = .connectRequested
        }
    }

    fileprivate mutating func canCallConnect(index: NetworkStateIndex, requested: Bool) -> Bool {
        softAssert()
        guard
            (protocolEventStates[index].connectCallState == .initial && requested)
                || protocolEventStates[index].connectCallState == .connectRequested,
            protocolEventStates[index].connectedState == .initial
        else {
            if protocolEventStates[index].connectCallState == .initial && requested {
                // Connect can't be called yet, but remember that it has been requested
                protocolEventStates[index].connectCallState = .connectRequested
            }
            return false
        }
        protocolEventStates[index].connectCallState = .connectCalled
        return true
    }

    fileprivate mutating func canCallDisconnect(index: NetworkStateIndex) -> Bool {
        softAssert()
        guard protocolEventStates[index].connectCallState != .disconnectCalled,
            protocolEventStates[index].connectedState != .disconnected
        else {
            return false
        }
        protocolEventStates[index].connectCallState = .disconnectCalled
        return true
    }

    fileprivate mutating func isConnected(index: NetworkStateIndex) -> Bool {
        softAssert()
        return protocolEventStates[index].connectedState == .connected
    }

    fileprivate mutating func async(
        context: NetworkContext,
        index: NetworkStateIndex,
        _ block: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        softAssert()
        // The queued block holds `index` until it runs, so keep the event state alive until then.
        protocolEventStates[index].addOutstandingHolder()
        self.async {
            context.eventContext.runAsync(index: index, block)
        }
    }

    fileprivate mutating func scheduleWakeup(
        context: NetworkContext,
        index: NetworkStateIndex,
        timerReference: TimerReference,
        after delay: NetworkDuration,
        _ wakeup: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        softAssert()
        // The scheduled wakeup holds `index` until it fires or is unscheduled.
        protocolEventStates[index].addScheduledTimer()
        resetTimer(
            for: timerReference,
            to: .after(
                delay,
                {
                    // The scheduler hands back no state, so this is where the timer re-enters
                    // the stack: acquire the state once and thread it into `wakeup`.
                    context.eventContext.runTimerWakeup(index: index, wakeup)
                }
            )
        )
    }

}

@available(Network 0.1.0, *)
extension NetworkContext {
    fileprivate func softAssert() {
        #if DEBUG
        self.assert()
        #endif
    }

    fileprivate func async(
        index: NetworkStateIndex,
        _ block: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        softAssert()
        self.eventContext.protocolEventStates[index].addOutstandingHolder()
        self.async {
            self.eventContext.runAsync(index: index, block)
        }
    }

    fileprivate func scheduleWakeup(
        index: NetworkStateIndex,
        timerReference: TimerReference,
        after delay: NetworkDuration,
        _ wakeup: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        softAssert()
        self.eventContext.protocolEventStates[index].addScheduledTimer()
        resetTimer(
            for: timerReference,
            to: .after(
                delay,
                {
                    self.eventContext.runTimerWakeup(index: index, wakeup)
                }
            )
        )
    }
}

@available(Network 0.1.0, *)
extension ProtocolInstance where Self: ~Copyable {
    func connectRequested(in eventContext: inout NetworkContext.EventContext) {
        identifier.connectRequested(in: &eventContext)
    }

    func canCallConnect(requested: Bool, in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.canCallConnect(requested: requested, in: &eventContext)
    }

    func canCallDisconnect(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.canCallDisconnect(in: &eventContext)
    }

    /// Whether this protocol instance is connected.
    ///
    /// Mirrors `InstanceIdentifier.isConnected`, so a linkage outside the framework can ask
    /// the question of an instance it holds directly rather than of its identifier.
    @inline(always)
    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        identifier.isConnected(in: &eventContext)
    }
}

@available(Network 0.1.0, *)
extension InstanceIdentifier {
    func connectRequested(in eventContext: inout NetworkContext.EventContext) {
        guard !eventStateIndex.isNone else { return }
        eventContext.connectRequested(index: eventStateIndex)
    }

    func canCallConnect(requested: Bool, in eventContext: inout NetworkContext.EventContext) -> Bool {
        guard !eventStateIndex.isNone else { return false }
        return eventContext.canCallConnect(index: eventStateIndex, requested: requested)
    }

    func canCallDisconnect(in eventContext: inout NetworkContext.EventContext) -> Bool {
        guard !eventStateIndex.isNone else { return false }
        return eventContext.canCallDisconnect(index: eventStateIndex)
    }

    public func isConnected(in eventContext: inout NetworkContext.EventContext) -> Bool {
        guard !eventStateIndex.isNone else { return false }
        return eventContext.isConnected(index: eventStateIndex)
    }

    // Returns the event state index for a call that requires this instance to be registered.
    // Replaces what used to be a force-unwrap of an optional index: `.none` is a valid
    // `NetworkStateIndex` value that would otherwise quietly address the first slot.
    @inline(always)
    private var requiredProtocolEventStateIndex: NetworkStateIndex {
        let index = protocolEventStateIndex
        precondition(!index.isNone, "Protocol instance is not registered with an event context")
        return index
    }

    @inline(always)
    func handleCallFromUpperProtocol<R, E: Error>(
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        return try eventContext.handleCallFromUpperProtocol(index: protocolEventStateIndex, body)
    }

    @inline(always)
    func handleCallFromUpperProtocol<R: ~Copyable, E: Error>(
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        return try eventContext.handleCallFromUpperProtocol(index: protocolEventStateIndex, body)
    }

    @inline(always)
    func handleCallFromUpperProtocol<R, T: ~Copyable, E: Error>(
        _ value: consuming T,
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext, consuming T) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        return try eventContext.handleCallFromUpperProtocol(index: protocolEventStateIndex, value, body)
    }

    @inline(always)
    func deliverEventToUpperProtocol(
        event: consuming ProtocolEventManagerState.PendingEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventStateIndex.isNone else { return }
        eventContext.deliverEventToUpperProtocol(
            index: eventStateIndex,
            parentIndex: parentEventStateIndex,
            event: event
        )
    }

    @inline(always)
    func enqueuePendingEventForUpperProtocol(
        event: consuming ProtocolEventManagerState.PendingEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        guard !eventStateIndex.isNone else { return }
        eventContext.enqueuePendingEventForUpperProtocol(
            index: eventStateIndex,
            event: event
        )
    }

    @inline(always)
    func reassignQueuedPendingEventsForUpperProtocol(
        to newUpper: InstanceIdentifier,
        in eventContext: inout NetworkContext.EventContext,
        block: @escaping ProtocolEventManagerState.PendingEvent.EventBlock,
        errorBlock: @escaping ProtocolEventManagerState.PendingEvent.ErrorEventBlock,
        newInboundFlowBlock: @escaping ProtocolEventManagerState.PendingEvent.NewInboundFlowEventBlock,
        networkProtocolEventBlock: @escaping ProtocolEventManagerState.PendingEvent.NetworkProtocolEventBlock,
        inboundAbortedBlock: @escaping ProtocolEventManagerState.PendingEvent.ErrorEventBlock,
        outboundAbortedBlock: @escaping ProtocolEventManagerState.PendingEvent.ErrorEventBlock
    ) {
        guard !eventStateIndex.isNone else { return }
        eventContext.reassignQueuedPendingEventsForUpperProtocol(
            index: eventStateIndex,
            parentIndex: parentEventStateIndex,
            newUpper: newUpper,
            block: block,
            errorBlock: errorBlock,
            newInboundFlowBlock: newInboundFlowBlock,
            networkProtocolEventBlock: networkProtocolEventBlock,
            inboundAbortedBlock: inboundAbortedBlock,
            outboundAbortedBlock: outboundAbortedBlock
        )
    }

    @inline(always)
    func discardPendingEventsForUpperProtocol(in eventContext: inout NetworkContext.EventContext) {
        guard !eventStateIndex.isNone else { return }
        eventContext.discardPendingEventsForUpperProtocol(index: eventStateIndex)
    }

    @inline(always)
    func addEventFromLowerProtocol(
        event: consuming ProtocolEventManagerState.PendingEvent,
        in eventContext: inout NetworkContext.EventContext
    ) {
        let protocolEventStateIndex = protocolEventStateIndex
        guard !protocolEventStateIndex.isNone else { return }
        eventContext.addEventFromLowerProtocol(index: protocolEventStateIndex, event: event)
    }

    // As `addEventFromLowerProtocol`, but also takes a hold on the target's event state and
    // returns its index. Returns `.none` if there is no event state. See `PendingEvent.deliver(in:)`.
    @inline(always)
    fileprivate func addEventFromLowerProtocolHoldingState(
        event: consuming ProtocolEventManagerState.PendingEvent,
        in eventContext: inout NetworkContext.EventContext
    ) -> NetworkStateIndex {
        let protocolEventStateIndex = protocolEventStateIndex
        guard !protocolEventStateIndex.isNone else { return .none }
        eventContext.addEventFromLowerProtocolHoldingState(
            index: protocolEventStateIndex,
            event: event
        )
        return protocolEventStateIndex
    }

    public func fromExternal<R, E: Error>(
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        return try eventContext.fromExternal(index: protocolEventStateIndex, body)
    }

    public func fromExternal<R: ~Copyable, E: Error>(
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        return try eventContext.fromExternal(index: protocolEventStateIndex, body)
    }

    func fromExternal<R, T: ~Copyable, E: Error>(
        _ value: consuming T,
        in eventContext: inout NetworkContext.EventContext,
        _ body: (inout NetworkContext.EventContext, consuming T) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        return try eventContext.fromExternal(index: protocolEventStateIndex, value, body)
    }

    public func async(
        context: NetworkContext,
        in eventContext: inout NetworkContext.EventContext,
        _ block: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        let protocolEventStateIndex = requiredProtocolEventStateIndex
        eventContext.async(context: context, index: protocolEventStateIndex, block)
    }

    /// Schedules a timer wakeup, running `wakeup` with the event context once the timer fires.
    ///
    /// The scheduler hands back no state, so the timer is an entry point into the stack: the
    /// state is acquired when the timer fires and threaded into `wakeup`.
    public func scheduleWakeup(
        context: NetworkContext,
        after delay: NetworkDuration,
        timerReference: TimerReference,
        in eventContext: inout NetworkContext.EventContext,
        _ wakeup: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        guard !protocolEventStateIndex.isNone else { return }
        eventContext.scheduleWakeup(
            context: context,
            index: protocolEventStateIndex,
            timerReference: timerReference,
            after: delay,
            wakeup
        )
    }

    public func unscheduleWakeup(timerReference: TimerReference, in eventContext: inout NetworkContext.EventContext) {
        eventContext.assert()
        eventContext.resetTimer(for: timerReference, to: .unschedule)
        guard !protocolEventStateIndex.isNone else { return }
        eventContext.clearScheduledTimer(protocolEventStateIndex)
    }
}
