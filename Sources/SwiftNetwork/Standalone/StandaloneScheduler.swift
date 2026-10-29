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

#if !NETWORK_EMBEDDED && canImport(Synchronization)

internal import Synchronization

/// A `NetworkContext.Scheduler` that does not schedule anything itself.
///
/// A client that owns exactly one protocol drives it directly: it decides when timers fire, when
/// "async back to me" work runs, and what time it is. This scheduler records those requests
/// instead of acting on them, so the owner can ask "do you have a timer for me to set?" and "do
/// you need me to call you back?" when a call into the protocol unwinds.
///
/// The owner supplies the clock through `advance(to:)`. Time never moves on its own, and nothing
/// runs until the owner calls `runPendingAsync()` or `fireDueTimers()`.
///
/// **Threading:** every call except `runImmediate` must come from the owner's single execution
/// context, the one it uses to call into the protocol. `runImmediate` is safe from any thread,
/// because a protocol can hand work to the scheduler from a callback on another thread (for
/// example, an asynchronous certificate verification result). Set `onWorkAvailable` to learn when
/// that happens.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class StandaloneScheduler: NetworkContext.Scheduler, @unchecked Sendable {

    /// A task the scheduler holds on behalf of the protocol. Tasks are not `Sendable`; the owner's
    /// single execution context serializes them, which is the guarantee this class rests on.
    private struct Task: @unchecked Sendable {
        let run: () -> Void
    }

    private struct Timer: Sendable {
        var deadline: NetworkClock.Instant
        var armOrder: UInt64
        var task: Task
    }

    private struct State: @unchecked Sendable {
        var pending: [Task] = []
        var timers: [TimerReference: Timer] = [:]
        var armOrderCounter: UInt64 = 0
        var continuous: NetworkClock.Instant
        var absolute: NetworkClock.Instant
    }

    private let state: NetworkMutex<State>
    private let wakeHandler: NetworkMutex<(@Sendable () -> Void)?> = NetworkMutex(nil)

    /// How many times `runPendingAsync` drains before concluding nothing is making progress.
    private static var maximumBatches: Int { 10_000 }

    /// Creates a scheduler with no timers armed and no work queued.
    ///
    /// - Parameters:
    ///   - now: The starting continuous time. Must be greater than zero, because much of the stack
    ///     treats `.zero` as "unset".
    ///   - nowAbsolute: The starting absolute time. Defaults to `now`.
    public init(now: NetworkClock.Instant, nowAbsolute: NetworkClock.Instant? = nil) {
        precondition(now > .zero, "standalone time must be greater than zero")
        self.state = NetworkMutex(State(continuous: now, absolute: nowAbsolute ?? now))
    }

    // MARK: - NetworkContext.Scheduler

    public var now: NetworkClock.Instant { state.withLock { $0.continuous } }
    public var nowAbsolute: NetworkClock.Instant { state.withLock { $0.absolute } }

    /// Always true: the owner's calling context *is* the scheduler. See the type's threading note.
    public var runningInScheduler: Bool { true }

    public func runImmediate(_ task: @escaping () -> Void) {
        state.withLock { $0.pending.append(Task(run: task)) }
        let handler = wakeHandler.withLock { $0 }
        handler?()
    }

    public func schedule(_ task: @escaping () -> Void, after delay: NetworkDuration, reference: TimerReference) {
        state.withLock { state in
            let order = state.armOrderCounter
            state.armOrderCounter &+= 1
            state.timers[reference] = Timer(
                deadline: state.continuous.advanced(by: delay),
                armOrder: order,
                task: Task(run: task)
            )
        }
    }

    public func unschedule(reference: TimerReference) {
        state.withLock { $0.timers[reference] = nil }
    }

    // MARK: - Owner interface

    /// Called, possibly from another thread, whenever work is queued by `runImmediate`.
    ///
    /// Use it to wake the owner's loop. It is not called for timers.
    public var onWorkAvailable: (@Sendable () -> Void)? {
        get { wakeHandler.withLock { $0 } }
        set { wakeHandler.withLock { $0 = newValue } }
    }

    /// Whether the protocol has asked to be called back.
    public var hasPendingAsync: Bool { state.withLock { !$0.pending.isEmpty } }

    /// The earliest deadline among the armed timers, or `nil` if none is armed.
    ///
    /// A deadline at or before `now` means a timer is already due.
    public var nextTimerDeadline: NetworkClock.Instant? {
        state.withLock { state in
            var earliest: NetworkClock.Instant?
            for timer in state.timers.values {
                if earliest == nil || timer.deadline < earliest! {
                    earliest = timer.deadline
                }
            }
            return earliest
        }
    }

    /// The number of armed timers. Useful for asserting that teardown cancelled everything.
    public var scheduledTimerCount: Int { state.withLock { $0.timers.count } }

    /// Moves the clock forward. Does not run anything.
    ///
    /// The absolute clock moves by the same delta. A time earlier than `now` is ignored.
    public func advance(to instant: NetworkClock.Instant) {
        state.withLock { state in
            let delta = state.continuous.duration(to: instant)
            guard delta > .zero else { return }
            state.continuous = instant
            state.absolute = state.absolute.advanced(by: delta)
        }
    }

    /// Runs the work queued by `runImmediate`, including whatever that work queues in turn.
    ///
    /// Work queued by a task joins the back of the line, so each batch finishes before the next
    /// begins.
    @discardableResult
    public func runPendingAsync() -> Bool {
        var ranAny = false
        var batches = 0
        while true {
            let batch: [Task] = state.withLock { state in
                let batch = state.pending
                state.pending.removeAll()
                return batch
            }
            if batch.isEmpty { break }
            ranAny = true
            batches &+= 1
            if batches > Self.maximumBatches {
                preconditionFailure("Queued work did not settle; a task is requeuing itself without progress")
            }
            for task in batch {
                task.run()
            }
        }
        return ranAny
    }

    /// Runs every timer whose deadline is at or before `now`, in deadline order.
    ///
    /// A timer that arms another timer for an instant that has already passed does not fire it in
    /// the same call, so a timer that rearms itself cannot spin here.
    @discardableResult
    public func fireDueTimers() -> Bool {
        var firedAny = false
        let cutoff = state.withLock { $0.armOrderCounter }
        while true {
            let next: Task? = state.withLock { state in
                let now = state.continuous
                var best: (TimerReference, Timer)?
                for (reference, timer) in state.timers where timer.deadline <= now && timer.armOrder < cutoff {
                    if let current = best {
                        if timer.deadline < current.1.deadline
                            || (timer.deadline == current.1.deadline && timer.armOrder < current.1.armOrder)
                        {
                            best = (reference, timer)
                        }
                    } else {
                        best = (reference, timer)
                    }
                }
                guard let best else { return nil }
                state.timers[best.0] = nil
                return best.1.task
            }
            guard let task = next else { break }
            firedAny = true
            task.run()
            // Work a timer queued runs before the next timer, as it would on a serial queue.
            runPendingAsync()
        }
        return firedAny
    }
}

#endif
