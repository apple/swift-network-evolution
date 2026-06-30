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

#if !NETWORK_EMBEDDED && canImport(Dispatch)
import Dispatch
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

#if canImport(Synchronization)
internal import Synchronization
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct TimerReference: Equatable, Hashable {
    var index: Int?

    public func hash(into hasher: inout Hasher) {
        hasher.combine(index)
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public protocol NetworkContextProtocol: AnyObject, Hashable {
    init(identifier: String)
    var identifier: String { get }
    func activate()
    func async(_ block: @Sendable @escaping () -> Void)
    func isolatedAsync(_ block: @escaping () -> Void)
    func barrierAsync(_ block: @Sendable @escaping () -> Void)
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class NetworkContext: NetworkContextProtocol, @unchecked Sendable {
    public func hash(into hasher: inout Hasher) {
        #if !NETWORK_EMBEDDED
        hasher.combine(self.identifier)
        #else
        // Embedded does not currently support directly taking the hash of a string
        for byte in self.identifier.utf8 {
            hasher.combine(byte)
        }
        #endif
    }

    public protocol Scheduler: AnyObject {
        /// Runs an immediate task, scheduled from the scheduler's context (so the completion is non-sendable).
        /// No assumptions are made about how the task is run.
        func runImmediateIsolated(_ task: @escaping () -> Void)

        /// Runs an immediate task. No assumptions are made about how the task is run.
        func runImmediate(_ task: @Sendable @escaping () -> Void)

        /// Schedules a task to run after a delay, using a reference.
        ///
        /// The `milliseconds` parameter specifies the delay before the task runs.
        func schedule(_ task: @escaping () -> Void, milliseconds: Int64, reference: TimerReference)
        /// Unschedules a task with a reference.
        func unschedule(reference: TimerReference)
        /// A Boolean value that indicates whether the current code is running in the scheduler.
        var runningInScheduler: Bool { get }
    }

    /// Indicates the privacy level for the context.
    ///
    /// `publicLogs` is good for contexts used only with endpoints that don't divulge information
    /// about what the app is doing, such as a process that always connects to the same server.
    /// `privateLogs` hides the endpoints involved in connections; this level is appropriate for a
    /// browser, where hostnames would indicate a great deal of information about what the app is doing.
    /// `sensitiveLogs` suppresses all logging and is appropriate for something like private browsing.
    enum PrivacyLevel: Hashable, CustomStringConvertible {
        case publicLogs
        case privateLogs
        case sensitiveLogs
        case silentLogs

        var description: String {
            switch self {
            case .publicLogs: return "public"
            case .privateLogs: return "private"
            case .sensitiveLogs: return "sensitive"
            case .silentLogs: return "silent"
            }
        }
    }

    #if !NETWORK_PRIVATE || NETWORK_STANDALONE
    public static func == (lhs: NetworkContext, rhs: NetworkContext) -> Bool {
        lhs === rhs
    }

    var globals: NetworkContext.Globals
    let scheduler: any NetworkContext.Scheduler
    let schedulerIsDefault: Bool
    internal let _identifier: String

    internal init(
        identifier: String,
        globals: NetworkContext.Globals,
        scheduler: any NetworkContext.Scheduler,
        schedulerIsDefault: Bool
    ) {
        self._identifier = identifier
        self.globals = globals
        self.scheduler = scheduler
        self.schedulerIsDefault = schedulerIsDefault
    }

    public static let implicitContext: NetworkContext = NetworkContext(identifier: "context")

    public var identifier: String {
        get {
            _identifier
        }
    }

    var cacheContext: NetworkContext {
        self
    }

    internal let _privacyLevel = NetworkMutex<PrivacyLevel>(.privateLogs)
    var privacyLevel: PrivacyLevel {
        get {
            _privacyLevel.withLock { $0 }
        }
        set {
            _privacyLevel.withLock { $0 = newValue }
        }
    }
    #else
    var storage: NetworkContext.Storage
    internal init(storage: consuming NetworkContext.Storage) {
        self.storage = storage
    }
    #endif

    #if !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Dispatch)
    public init(identifier: String) {
        _identifier = identifier
        globals = Globals(label: identifier)
        scheduler = DefaultScheduler(globals: globals)
        schedulerIsDefault = true
    }

    public init(identifier: String, externalScheduler: any Scheduler) {
        _identifier = identifier
        globals = Globals(label: identifier)
        scheduler = externalScheduler
        schedulerIsDefault = false
    }
    #endif

    var disableLogging: Bool {
        self.privacyLevel == .silentLogs
    }

    #if !NETWORK_PRIVATE || NETWORK_STANDALONE
    public func activate() {}

    #if !NETWORK_DRIVERKIT && !NETWORK_STANDALONE
    func assert() {
        if schedulerIsDefault {
            dispatchPrecondition(condition: DispatchPredicate.onQueue(queue))
        } else {
            precondition(scheduler.runningInScheduler, "Not running on context scheduler")
        }
    }
    #endif

    func sharesWorkloop(with other: NetworkContext) -> Bool {
        false
    }

    var isolateProtocolCache: Bool {
        false
    }

    var sensitiveRedacted: Bool {
        false
    }

    var privateRedacted: Bool {
        false
    }
    #endif

    // MARK: - Storage of Per-Protocol Event Manager States

    #if !NETWORK_PRIVATE || NETWORK_STANDALONE
    internal var protocolEventStates = NetworkGappyArray<ProtocolEventManagerState>()
    internal var udpInstances = NetworkGappyArray<UDPProtocol.Instance>()
    internal var ipInstances = NetworkGappyArray<IPProtocol.Instance>()
    #endif
    internal func registerProtocolEventState() -> NetworkStateIndex {
        protocolEventStates.insert(.init())
    }
    internal func unregisterProtocolEventState(_ index: NetworkStateIndex) {
        protocolEventStates.remove(index: index)
    }

    internal func registerUDPInstance(_ instance: consuming UDPProtocol.Instance) -> NetworkStateIndex {
        udpInstances.insert(instance)
    }
    internal func unregisterUDPInstance(_ index: NetworkStateIndex) {
        udpInstances.remove(index: index)
    }

    internal func registerIPInstance(_ instance: consuming IPProtocol.Instance) -> NetworkStateIndex {
        ipInstances.insert(instance)
    }
    internal func unregisterIPInstance(_ index: NetworkStateIndex) {
        ipInstances.remove(index: index)
    }
}

// MARK: - Globals

#if !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Dispatch) && !NETWORK_EMBEDDED
@available(Network 0.1.0, *)
extension NetworkContext {
    struct TimerEntry: ~Copyable, NetworkComparable {
        var targetTime: DispatchTime
        var block: () -> Void
        let reference: TimerReference
        var running: Bool = false
        static func < (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
            lhs.targetTime < rhs.targetTime
        }
        static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
            (lhs.targetTime == rhs.targetTime && lhs.reference == rhs.reference)
        }
    }

    final class Globals {
        final class TimerList {
            var entries = NetworkPriorityQueue<TimerEntry>()
            var queue: DispatchQueue
            var timerSource: (any DispatchSourceTimer)?
            var currentTarget: DispatchTime = .distantFuture

            init(queue: DispatchQueue) {
                self.queue = queue
            }

            func runTimer() {
                // Clear the current target to allow resetting
                currentTarget = .distantFuture

                guard let timerSource else {
                    // Already cancelled, ignore
                    return
                }
                while !entries.isEmpty {
                    let now = DispatchTime.now()
                    let targetTime = entries.first.targetTime
                    if targetTime > now {
                        // Target is in future, reset and return
                        currentTarget = targetTime
                        timerSource.schedule(deadline: targetTime)
                        return
                    }
                    guard var entry = entries.pop() else {
                        return
                    }
                    entry.running = true
                    entry.block()
                    entry.running = false
                }
                // If we get to here, the list is drained
                timerSource.cancel()
                self.timerSource = nil
                currentTarget = .distantFuture
            }

            func remove(for reference: TimerReference) {
                remove(by: reference)
                if entries.isEmpty {
                    timerSource?.cancel()
                    timerSource = nil
                    currentTarget = .distantFuture
                }
            }

            private func remove(by reference: TimerReference) {
                entries.removeFirst(where: { $0.reference == reference })
            }

            func insert(targetTime: DispatchTime, reference: TimerReference, task: @escaping () -> Void) {
                // First, remove an existing entry for this reference
                remove(by: reference)
                // Check to see if the targetTime is before the first entry before it's added
                // Adding the entry will automatically sort the new entry
                let needsReschedule: Bool
                if entries.isEmpty {
                    needsReschedule = true
                } else {
                    needsReschedule = targetTime < entries.first.targetTime
                }

                // Insert the new entry
                let entry = TimerEntry(targetTime: targetTime, block: task, reference: reference)
                entries.push(entry)

                // Reset the target time if needed
                if needsReschedule {
                    if timerSource == nil {
                        timerSource = DispatchSource.makeTimerSource(queue: queue)
                    }
                    currentTarget = targetTime
                    if let timerSource {
                        let timerHandler = DispatchWorkItem {
                            self.runTimer()
                        }
                        timerSource.setEventHandler(handler: timerHandler)
                        timerSource.schedule(deadline: currentTarget)
                        timerSource.activate()
                    }
                }
            }
        }
        var timerList: TimerList
        var queue: DispatchQueue

        init(label: String) {
            queue = DispatchQueue(label: "networking context")
            timerList = TimerList(queue: queue)
        }
    }

    final class DefaultScheduler: Scheduler {
        let globals: Globals
        init(globals: Globals) {
            self.globals = globals
        }
        /// Runs an immediate task, scheduled from the scheduler's context (so the completion is non-sendable).
        /// No assumptions are made about how the task is run.
        func runImmediateIsolated(_ task: @escaping () -> Void) {
            globals.queue.async(execute: DispatchWorkItem(block: task))
        }
        /// Runs an immediate task. No assumptions are made about how the task is run.
        func runImmediate(_ task: @Sendable @escaping () -> Void) {
            globals.queue.async(execute: DispatchWorkItem(block: task))
        }
        /// Schedules a task to run after a delay, using a reference.
        ///
        /// The `milliseconds` parameter specifies the delay before the task runs.
        func schedule(_ task: @escaping () -> Void, milliseconds: Int64, reference: TimerReference) {
            let targetTime = DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(milliseconds))
            globals.timerList.insert(targetTime: targetTime, reference: reference, task: task)
        }
        /// Unschedules a task with a reference.
        func unschedule(reference: TimerReference) {
            globals.timerList.remove(for: reference)
        }
        /// A Boolean value that indicates whether the current code is running in the scheduler.
        var runningInScheduler: Bool {
            // TODO: Not supported by DispatchQueue
            fatalError("Unsupported")
        }
    }
}

// MARK: - Async

@available(Network 0.1.0, *)
extension NetworkContext {

    var queue: DispatchQueue {
        globals.queue
    }

    public func async(_ block: @Sendable @escaping () -> Void) {
        scheduler.runImmediate(block)
    }

    public func isolatedAsync(_ block: @escaping () -> Void) {
        #if DEBUG
        assert()
        #endif
        scheduler.runImmediateIsolated(block)
    }

    public func barrierAsync(_ block: @Sendable @escaping () -> Void) {
        scheduler.runImmediate(block)
    }

    public var runningInContext: Bool {
        scheduler.runningInScheduler
    }
}

#endif

// MARK: - Timers

@available(Network 0.1.0, *)
extension NetworkContext {

    enum FutureTime {
        case unschedule
        case milliseconds(UInt64, () -> Void)  // Milliseconds into the future
    }

    #if !NETWORK_PRIVATE || NETWORK_STANDALONE
    func resetTimer(for reference: TimerReference, to time: FutureTime) {
        switch time {
        case .unschedule:
            scheduler.unschedule(reference: reference)
        case .milliseconds(let milliseconds, let block):
            scheduler.schedule(block, milliseconds: Int64(milliseconds), reference: reference)
        }
    }
    #endif
}
