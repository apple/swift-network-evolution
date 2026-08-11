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
        case connected(_ from: ProtocolInstanceReference, _ to: ProtocolInstanceReference)
        case disconnected(_ from: ProtocolInstanceReference, _ to: ProtocolInstanceReference, error: NetworkError?)
        case inboundDataAvailable(_ from: ProtocolInstanceReference, _ to: ProtocolInstanceReference)
        case outboundRoomAvailable(_ from: ProtocolInstanceReference, _ to: ProtocolInstanceReference)
        case inboundAborted(_ from: ProtocolInstanceReference, _ to: ProtocolInstanceReference, error: NetworkError?)
        case outboundAborted(_ from: ProtocolInstanceReference, _ to: ProtocolInstanceReference, error: NetworkError?)
        case newInboundFlow(
            _ from: ProtocolInstanceReference,
            _ to: ProtocolInstanceReference,
            flowReference: ProtocolInstanceReference,
            flowMetadata: AbstractProtocolMetadata?
        )
        case networkProtocolEvent(
            _ from: ProtocolInstanceReference,
            _ to: ProtocolInstanceReference,
            event: NetworkProtocolEvent
        )

        fileprivate func run() {
            switch self {
            case .connected(let from, let to): to.handleConnectedEvent(from)
            case .disconnected(let from, let to, let error): to.handleDisconnectedEvent(from, error: error)
            case .inboundDataAvailable(let from, let to): to.handleInboundDataAvailableEvent(from)
            case .outboundRoomAvailable(let from, let to): to.handleOutboundRoomAvailableEvent(from)
            case .inboundAborted(let from, let to, let error): to.handleInboundAbortedEvent(from, error: error)
            case .outboundAborted(let from, let to, let error): to.handleOutboundAbortedEvent(from, error: error)
            case .newInboundFlow(let from, let to, let flow, let metadata):
                to.handleNewInboundFlowEvent(from, flowReference: flow, flowMetadata: metadata)
            case .networkProtocolEvent(let from, let to, let event): to.handleNetworkProtocolEvent(from, event: event)
            }
        }

        fileprivate consuming func deliver() -> ProtocolInstanceReference {
            let toReference: ProtocolInstanceReference
            switch self {
            case .connected(_, let to): toReference = to
            case .disconnected(_, let to, _): toReference = to
            case .inboundDataAvailable(_, let to): toReference = to
            case .outboundRoomAvailable(_, let to): toReference = to
            case .inboundAborted(_, let to, _): toReference = to
            case .outboundAborted(_, let to, _): toReference = to
            case .newInboundFlow(_, let to, _, _): toReference = to
            case .networkProtocolEvent(_, let to, _): toReference = to
            }
            if !toReference.isNone {
                toReference.addEventFromLowerProtocol(event: self)
            }
            return toReference
        }

        fileprivate consuming func reassign(to newTo: ProtocolInstanceReference) -> PendingEvent {
            switch self {
            case .connected(let from, _): return .connected(from, newTo)
            case .disconnected(let from, _, let error): return .disconnected(from, newTo, error: error)
            case .inboundDataAvailable(let from, _): return .inboundDataAvailable(from, newTo)
            case .outboundRoomAvailable(let from, _): return .outboundRoomAvailable(from, newTo)
            case .inboundAborted(let from, _, let error): return .inboundAborted(from, newTo, error: error)
            case .outboundAborted(let from, _, let error): return .outboundAborted(from, newTo, error: error)
            case .newInboundFlow(let from, _, let flow, let metadata):
                return .newInboundFlow(from, newTo, flowReference: flow, flowMetadata: metadata)
            case .networkProtocolEvent(let from, _, let event): return .networkProtocolEvent(from, newTo, event: event)
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

    mutating func startDrainingPendingEventsFromLower() -> Int {
        guard eventState == .idle, !pendingEventsFromLowerProtocol.isEmpty else {
            // Fast exit if we're not fully unwound
            return 0
        }

        eventState = .processingEventFromLowerProtocol
        return pendingEventsFromLowerProtocol.count
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

    var timerScheduled = false

    var drainingEvents = false

    var isIdle: Bool {
        eventState == .idle
    }

    init() {}
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct ProtocolEventManager: ~Copyable {
    private(set) var contextIndex: NetworkStateIndex?
    private var context: NetworkContext?
    public init() {
        contextIndex = nil
        context = nil
    }
    internal mutating func register(with context: NetworkContext) -> NetworkStateIndex {
        if let contextIndex {
            // Already registered
            return contextIndex
        }
        self.context = context
        let registeredIndex = context.registerProtocolEventState()
        contextIndex = registeredIndex
        return registeredIndex
    }
    deinit {
        guard let contextIndex, let context else { return }
        context.async {
            context.unregisterProtocolEventState(contextIndex)
        }
    }
}

@available(Network 0.1.0, *)
extension NetworkContext {
    fileprivate func softAssert() {
        #if DEBUG
        self.assert()
        #endif
    }
    @inline(__always)
    fileprivate func runEvent(referenceToTrigger: ProtocolInstanceReference) {
        guard !referenceToTrigger.isNone,
            let indexToTrigger = referenceToTrigger.protocolEventStateIndex()
        else { return }
        let eventCount = protocolEventStates[indexToTrigger].startDrainingPendingEventsFromLower()
        if eventCount > 0 {
            for _ in 0..<eventCount {
                let pendingEvent = protocolEventStates[indexToTrigger].readPendingEventFromLower()
                pendingEvent.run()
            }
            protocolEventStates[indexToTrigger].finishDrainingPendingEventsFromLower()
            drainPendingEvents(index: indexToTrigger)
        }
    }
    fileprivate func drainPendingEvents(index: NetworkStateIndex) {
        if protocolEventStates[index].isIdle && !protocolEventStates[index].drainingEvents {
            protocolEventStates[index].drainingEvents = true
            let lowerEvents = protocolEventStates[index].startDrainingPendingEventsFromLower()
            if lowerEvents > 0 {
                for _ in 0..<lowerEvents {
                    protocolEventStates[index].readPendingEventFromLower().run()
                }
                protocolEventStates[index].finishDrainingPendingEventsFromLower()
            }
            var upperEvents = protocolEventStates[index].countPendingEventsToUpper()
            while upperEvents > 0 {
                if upperEvents == 1 {
                    // For cases with one event, just deliver to the lower protocol queue and run
                    if let pendingEvent = protocolEventStates[index].readPendingEventToUpper() {
                        runEvent(referenceToTrigger: pendingEvent.deliver())
                    }
                } else {
                    // For cases with more than one event, batch all of the events in the lower protocol queue and run them in one pass
                    var referencesToTrigger = Deque<ProtocolInstanceReference>(minimumCapacity: upperEvents)
                    for _ in 0..<upperEvents {
                        if let pendingEvent = protocolEventStates[index].readPendingEventToUpper() {
                            referencesToTrigger.append(pendingEvent.deliver())
                        }
                    }
                    while let referenceToTrigger = referencesToTrigger.popFirst() {
                        runEvent(referenceToTrigger: referenceToTrigger)
                    }
                }
                upperEvents = protocolEventStates[index].countPendingEventsToUpper()
            }
            protocolEventStates[index].drainingEvents = false
        }
    }

    fileprivate func deliverEventToUpperProtocol(
        index: NetworkStateIndex,
        parentIndex: NetworkStateIndex?,
        event: consuming ProtocolEventManagerState.PendingEvent,
        drain: Bool = true
    ) {
        self.softAssert()
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
        if let parentIndex {
            protocolEventStates[parentIndex].addPendingEventToDeliverToUpperProtocol(event)
            if drain {
                drainPendingEvents(index: parentIndex)
            }
        } else {
            protocolEventStates[index].addPendingEventToDeliverToUpperProtocol(event)
        }
    }

    fileprivate func reassignQueuedPendingEventsForUpperProtocol(
        index: NetworkStateIndex,
        parentIndex: NetworkStateIndex?,
        newUpper: ProtocolInstanceReference
    ) {
        self.softAssert()
        if let parentIndex {
            var foundEvents = false
            while let event = protocolEventStates[index].unassignedPendingEventsToDeliverToUpperProtocol.popFirst() {
                let event = event.reassign(to: newUpper)
                deliverEventToUpperProtocol(index: index, parentIndex: parentIndex, event: event, drain: false)
                foundEvents = true
            }
            if foundEvents {
                drainPendingEvents(index: parentIndex)
            }
        } else {
            while let event = protocolEventStates[index].unassignedPendingEventsToDeliverToUpperProtocol.popFirst() {
                let event = event.reassign(to: newUpper)
                deliverEventToUpperProtocol(index: index, parentIndex: nil, event: event, drain: false)
            }
        }
    }

    fileprivate func enqueuePendingEventForUpperProtocol(
        index: NetworkStateIndex,
        event: consuming ProtocolEventManagerState.PendingEvent
    ) {
        self.softAssert()
        protocolEventStates[index].enqueuePendingEventForUpperProtocol(event)
    }

    fileprivate func discardPendingEventsForUpperProtocol(index: NetworkStateIndex) {
        self.softAssert()
        protocolEventStates[index].discardPendingEventsForUpperProtocol()
    }

    fileprivate func addEventFromLowerProtocol(
        index: NetworkStateIndex,
        event: consuming ProtocolEventManagerState.PendingEvent
    ) {
        self.softAssert()
        protocolEventStates[index].addEventFromLowerProtocol(event: event)
    }

    fileprivate func handleCallFromUpperProtocol<R, E: Error>(
        index: NetworkStateIndex,
        _ body: () throws(E) -> R
    ) throws(E) -> R {
        self.softAssert()
        protocolEventStates[index].startCallFromUpperProtocol()
        defer {
            protocolEventStates[index].finishCallFromUpperProtocol()
            drainPendingEvents(index: index)
        }
        return try body()
    }

    fileprivate func handleCallFromUpperProtocol<R: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ body: () throws(E) -> R
    ) throws(E) -> R {
        self.softAssert()
        protocolEventStates[index].startCallFromUpperProtocol()
        defer {
            protocolEventStates[index].finishCallFromUpperProtocol()
            drainPendingEvents(index: index)
        }
        return try body()
    }

    fileprivate func handleCallFromUpperProtocol<R, T: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ value: consuming T,
        _ body: (consuming T) throws(E) -> R
    ) throws(E) -> R {
        self.softAssert()
        protocolEventStates[index].startCallFromUpperProtocol()
        defer {
            protocolEventStates[index].finishCallFromUpperProtocol()
            drainPendingEvents(index: index)
        }
        return try body(value)
    }

    fileprivate func fromExternal<R, E: Error>(index: NetworkStateIndex, _ body: () throws(E) -> R) throws(E) -> R {
        self.softAssert()
        let startedExternalCall = protocolEventStates[index].startExternalCall()
        defer {
            if startedExternalCall {
                protocolEventStates[index].finishExternalCall()
                drainPendingEvents(index: index)
            }
        }
        return try body()
    }

    fileprivate func fromExternal<R: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ body: () throws(E) -> R
    ) throws(E) -> R {
        self.softAssert()
        let startedExternalCall = protocolEventStates[index].startExternalCall()
        defer {
            if startedExternalCall {
                protocolEventStates[index].finishExternalCall()
                drainPendingEvents(index: index)
            }
        }
        return try body()
    }

    fileprivate func fromExternal<R, T: ~Copyable, E: Error>(
        index: NetworkStateIndex,
        _ value: consuming T,
        _ body: (consuming T) throws(E) -> R
    ) throws(E) -> R {
        self.softAssert()
        let startedExternalCall = protocolEventStates[index].startExternalCall()
        defer {
            if startedExternalCall {
                protocolEventStates[index].finishExternalCall()
                drainPendingEvents(index: index)
            }
        }
        return try body(value)
    }

    fileprivate func async(index: NetworkStateIndex, _ block: @escaping () -> Void) {
        self.softAssert()
        self.async {
            self.protocolEventStates[index].startAsyncCall()
            defer {
                self.protocolEventStates[index].finishAsyncCall()
                self.drainPendingEvents(index: index)
            }
            block()
        }
    }

    fileprivate func scheduleWakeup(
        index: NetworkStateIndex,
        referenceToWakeup: ProtocolInstanceReference,
        milliseconds: UInt64
    ) {
        self.softAssert()
        self.resetTimer(
            for: referenceToWakeup.timerReference,
            to: .milliseconds(
                milliseconds,
                {
                    self.assert()
                    self.protocolEventStates[index].startTimerWakeupCall()
                    defer {
                        self.protocolEventStates[index].finishTimerWakeupCall()
                        self.drainPendingEvents(index: index)
                    }
                    referenceToWakeup.timerWakeup()
                }
            )
        )
    }

    fileprivate func connectRequested(index: NetworkStateIndex) {
        self.softAssert()
        if protocolEventStates[index].connectCallState == .initial {
            // Connect can't be called yet, but remember that it has been requested
            protocolEventStates[index].connectCallState = .connectRequested
        }
    }

    fileprivate func canCallConnect(index: NetworkStateIndex, requested: Bool) -> Bool {
        self.softAssert()
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

    fileprivate func canCallDisconnect(index: NetworkStateIndex) -> Bool {
        self.softAssert()
        guard protocolEventStates[index].connectCallState != .disconnectCalled,
            protocolEventStates[index].connectedState != .disconnected
        else {
            return false
        }
        protocolEventStates[index].connectCallState = .disconnectCalled
        return true
    }

    fileprivate func isConnected(index: NetworkStateIndex) -> Bool {
        self.softAssert()
        return protocolEventStates[index].connectedState == .connected
    }
}

@available(Network 0.1.0, *)
extension ProtocolInstance where Self: ~Copyable {
    func connectRequested() {
        reference.connectRequested()
    }

    func canCallConnect(requested: Bool) -> Bool {
        reference.canCallConnect(requested: requested)
    }

    var canCallDisconnect: Bool {
        reference.canCallDisconnect
    }

    @inline(__always)
    var isConnected: Bool {
        reference.isConnected
    }
}

@available(Network 0.1.0, *)
extension ProtocolInstanceReference {

    func connectRequested() {
        guard let _protocolEventStateIndex else { return }
        context.connectRequested(index: _protocolEventStateIndex)
    }

    func canCallConnect(requested: Bool) -> Bool {
        guard let _protocolEventStateIndex else { return false }
        return context.canCallConnect(index: _protocolEventStateIndex, requested: requested)
    }

    var canCallDisconnect: Bool {
        guard let _protocolEventStateIndex else { return false }
        return context.canCallDisconnect(index: _protocolEventStateIndex)
    }

    @inline(__always)
    var isConnected: Bool {
        guard let _protocolEventStateIndex else { return false }
        return context.isConnected(index: _protocolEventStateIndex)
    }

    @inline(__always)
    func handleCallFromUpperProtocol<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        let protocolEventStateIndex = protocolEventStateIndex()!
        return try context.handleCallFromUpperProtocol(index: protocolEventStateIndex, body)
    }

    @inline(__always)
    func handleCallFromUpperProtocol<R: ~Copyable, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        let protocolEventStateIndex = protocolEventStateIndex()!
        return try context.handleCallFromUpperProtocol(index: protocolEventStateIndex, body)
    }

    @inline(__always)
    func handleCallFromUpperProtocol<R, T: ~Copyable, E: Error>(
        _ value: consuming T,
        _ body: (consuming T) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = protocolEventStateIndex()!
        return try context.handleCallFromUpperProtocol(index: protocolEventStateIndex, value, body)
    }

    @inline(__always)
    func deliverEventToUpperProtocol(event: consuming ProtocolEventManagerState.PendingEvent) {
        guard let _protocolEventStateIndex else { return }
        context.deliverEventToUpperProtocol(
            index: _protocolEventStateIndex,
            parentIndex: _parentProtocolEventStateIndex,
            event: event
        )
    }

    @inline(__always)
    func enqueuePendingEventForUpperProtocol(event: consuming ProtocolEventManagerState.PendingEvent) {
        guard let _protocolEventStateIndex else { return }
        context.enqueuePendingEventForUpperProtocol(
            index: _protocolEventStateIndex,
            event: event
        )
    }

    @inline(__always)
    func reassignQueuedPendingEventsForUpperProtocol(to newUpper: ProtocolInstanceReference) {
        guard let _protocolEventStateIndex else { return }
        context.reassignQueuedPendingEventsForUpperProtocol(
            index: _protocolEventStateIndex,
            parentIndex: _parentProtocolEventStateIndex,
            newUpper: newUpper
        )
    }

    @inline(__always)
    func discardPendingEventsForUpperProtocol() {
        guard let _protocolEventStateIndex else { return }
        context.discardPendingEventsForUpperProtocol(index: _protocolEventStateIndex)
    }

    @inline(__always)
    func addEventFromLowerProtocol(event: consuming ProtocolEventManagerState.PendingEvent) {
        guard let protocolEventStateIndex = protocolEventStateIndex() else { return }
        context.addEventFromLowerProtocol(index: protocolEventStateIndex, event: event)
    }

    public func fromExternal<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        let protocolEventStateIndex = protocolEventStateIndex()!
        return try context.fromExternal(index: protocolEventStateIndex, body)
    }

    public func fromExternal<R: ~Copyable, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        let protocolEventStateIndex = protocolEventStateIndex()!
        return try context.fromExternal(index: protocolEventStateIndex, body)
    }

    func fromExternal<R, T: ~Copyable, E: Error>(
        _ value: consuming T,
        _ body: (consuming T) throws(E) -> R
    ) throws(E) -> R {
        let protocolEventStateIndex = protocolEventStateIndex()!
        return try context.fromExternal(index: protocolEventStateIndex, value, body)
    }

    public func async(_ block: @escaping () -> Void) {
        let protocolEventStateIndex = protocolEventStateIndex()!
        context.async(index: protocolEventStateIndex, block)
    }

    func timerWakeup() {
        switch reference {
        case .none: return
        case .tcp(let instance): instance.wakeup()
        #if !NETWORK_NO_SWIFT_QUIC
        case .quic(let instance): instance.wakeup()
        #endif
        #if !NETWORK_EMBEDDED
        case .custom(let container, let index): container.accessTimerSchedulable(at: index) { $0.wakeup() }
        #endif
        default: return
        }
    }

    var timerReference: TimerReference {
        TimerReference(index: self._protocolEventStateIndex?.rawValue ?? 0)
    }

    public func scheduleWakeup(milliseconds: UInt64) {
        let protocolEventStateIndex = protocolEventStateIndex()!
        context.scheduleWakeup(index: protocolEventStateIndex, referenceToWakeup: self, milliseconds: milliseconds)
    }

    public func unscheduleWakeup() {
        context.assert()
        self.context.resetTimer(for: timerReference, to: .unschedule)
    }
}
