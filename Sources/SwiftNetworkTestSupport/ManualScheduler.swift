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

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

/// A `NetworkContext.Scheduler` that virtualizes time.
///
/// This scheduler owns both the clock and the timers, because the stack arms timers rather than
/// polling the clock. Advancing time fires each timer with `now` set to that timer's own deadline,
/// so a test can drive a retransmission or an idle timeout without sleeping.
///
/// Every instant this API takes or returns is in the continuous domain; the absolute clock follows
/// by the same delta.
///
/// Install it with `NetworkContext(identifier:externalScheduler:)`.
///
/// **NOTE: **For synchronous tests only: no queue and no locking. Every call must come from the thread that
/// constructed the scheduler.
@available(Network 0.1.0, *)
@_spi(Essentials)
public final class ManualScheduler: NetworkContext.Scheduler {

    /// Comparable in firing order: by deadline, then by the order the timer was armed.
    private struct Timer: Comparable {
        var deadline: NetworkClock.Instant
        var armOrder: UInt64
        var task: () -> Void

        func isDue(by instant: NetworkClock.Instant) -> Bool {
            self.deadline <= instant
        }

        /// Whether this timer fires during an advance from `continuous` to `deadline`.
        ///
        /// A timer armed during that advance, for an instant already reached, waits for the next
        /// advance rather than firing re-entrantly, matching a serial dispatch queue.
        func firesDuringAdvance(
            from continuous: NetworkClock.Instant,
            to end: NetworkClock.Instant,
            armOrderCutoff: UInt64
        ) -> Bool {
            if !self.isDue(by: end) {
                return false
            }
            if self.isDue(by: continuous), self.armOrder >= armOrderCutoff {
                return false
            }
            return true
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.deadline != rhs.deadline {
                return lhs.deadline < rhs.deadline
            }
            return lhs.armOrder < rhs.armOrder
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.deadline == rhs.deadline && lhs.armOrder == rhs.armOrder
        }
    }

    private var timers: [TimerReference: Timer] = [:]
    private var armOrderCounter: UInt64 = 0
    /// Work handed to `runImmediate`, waiting for the next `run()` or advance.
    private var queuedWork: [() -> Void] = []
    private var continuous: NetworkClock.Instant
    private var absolute: NetworkClock.Instant

    /// The thread that owns this scheduler.
    private let owningThread = pthread_self()

    /// How many times `runQueuedWork` drains before concluding nothing is making progress.
    private static let maximumQueuedWorkBatches = 10_000

    /// Creates a scheduler holding both clocks, with no timers armed and no work queued.
    ///
    /// - Parameters:
    ///   - now: Must be greater than zero, because much of the stack treats `.zero` as "unset".
    ///   - nowAbsolute: Defaults to `now`.
    @_spi(Essentials)
    public init(now: NetworkClock.Instant, nowAbsolute: NetworkClock.Instant? = nil) {
        precondition(now > .zero, "manual time must be greater than zero")
        self.continuous = now
        self.absolute = nowAbsolute ?? now
    }

    @_spi(Essentials)
    public var now: NetworkClock.Instant { self.continuous }
    @_spi(Essentials)
    public var nowAbsolute: NetworkClock.Instant { self.absolute }

    /// Whether the calling thread owns the scheduler.
    @_spi(Essentials)
    public var runningInScheduler: Bool {
        pthread_equal(pthread_self(), self.owningThread) != 0
    }

    /// Queues `task` to run at the next `run()` or advance.
    ///
    /// Does not run in-line to avoid re-entrancy.
    @_spi(Essentials)
    public func runImmediate(_ task: @escaping (() -> Void)) {
        self.queuedWork.append(task)
    }

    @_spi(Essentials)
    public func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
        self.timers[reference] = Timer(
            deadline: self.continuous.advanced(by: delay),
            armOrder: self.nextArmOrder(),
            task: task
        )
    }

    @_spi(Essentials)
    public func unschedule(reference: TimerReference) {
        self.timers[reference] = nil
    }

    /// Consumes an arm order, so no two timers share one.
    private func nextArmOrder() -> UInt64 {
        let order = self.armOrderCounter
        self.armOrderCounter &+= 1
        return order
    }

    /// Lets a test assert that something was scheduled, or that canceling really canceled.
    @_spi(Essentials)
    public var scheduledCount: Int { self.timers.count }

    /// Runs queued work and any timer already due, including whatever those queue in turn.
    /// No virtual time passes.
    @_spi(Essentials)
    public func run() {
        self.advanceTime(to: self.continuous)
    }

    /// Runs queued work, including anything produced in the course of that work.
    ///
    /// Work queued by a task joins the back of the line rather than interrupting the batch in
    /// progress, matching a serial dispatch queue. Draining in batches rather than recursing is
    /// what produces that order.
    ///
    /// Separate from `run()` because `advanceTime(to:)` calls this method between timers and must
    /// not recurse back into the timer scan partway through one.
    ///
    /// The loop is bounded to protect against a task that re-queues itself.
    private func runQueuedWork() {
        var batches = 0
        while !self.queuedWork.isEmpty {
            batches &+= 1
            if batches > Self.maximumQueuedWorkBatches {
                preconditionFailure(
                    """
                    Queued work did not settle in \(Self.maximumQueuedWorkBatches) batches. \
                    A task is requeuing itself without making progress; it most likely needs \
                    virtual time to advance, which cannot happen while queued work is draining.
                    """
                )
            }
            let batch = self.queuedWork
            self.queuedWork.removeAll()
            for task in batch {
                task()
            }
        }
    }

    /// Moves time forward by `duration`, firing every timer that comes due at its own deadline.
    @_spi(Essentials)
    public func advanceTime(by duration: NetworkDuration) {
        precondition(duration >= .zero, "manual time must not go backwards")
        self.advanceTime(to: self.continuous.advanced(by: duration))
    }

    /// Moves time forward to `deadline`, firing every timer that comes due.
    ///
    /// Time is set to each timer's own deadline before that timer runs, not jumped straight to
    /// `deadline`, so a timer that reads `now` sees the time it was scheduled for.
    @_spi(Essentials)
    public func advanceTime(to deadline: NetworkClock.Instant) {
        precondition(deadline >= self.continuous, "manual time must not go backwards")

        // Store the initial value so we don't fire timers armed by this drain.
        var armOrderCutoff = self.armOrderCounter

        // Run queued work before we advance time.
        self.runQueuedWork()

        while true {
            // Folded into one pass: this scan runs once per timer fired, and filtering first would
            // allocate a dictionary on every pass.
            let next = self.timers.min { lhs, rhs in
                let lhsFires = lhs.value.firesDuringAdvance(
                    from: self.continuous,
                    to: deadline,
                    armOrderCutoff: armOrderCutoff
                )
                let rhsFires = rhs.value.firesDuringAdvance(
                    from: self.continuous,
                    to: deadline,
                    armOrderCutoff: armOrderCutoff
                )
                if lhsFires != rhsFires {
                    return lhsFires
                }
                return lhs.value < rhs.value
            }
            guard let next,
                next.value.firesDuringAdvance(
                    from: self.continuous,
                    to: deadline,
                    armOrderCutoff: armOrderCutoff
                )
            else {
                break
            }

            self.timers[next.key] = nil
            let instantBefore = self.continuous
            self.setContinuousTime(to: next.value.deadline)
            next.value.task()
            // Timers armed before now are late rather than re-entrant, so let them fire. Only
            // when the clock really moved: otherwise a timer that rearms itself for the same
            // instant fires forever.
            if self.continuous != instantBefore {
                armOrderCutoff = self.armOrderCounter
            }
            self.runQueuedWork()
        }

        self.setContinuousTime(to: deadline)
        self.runQueuedWork()
    }

    /// Sets the continuous clock to `instant`, moving the absolute clock by the same delta.
    ///
    /// NOTE: `instant`s earlier than current time are ignored.
    private func setContinuousTime(to instant: NetworkClock.Instant) {
        let delta = self.continuous.duration(to: instant)
        guard delta > .zero else { return }
        self.continuous = instant
        self.absolute = self.absolute.advanced(by: delta)
    }

    // MARK: - Running

    private var earliestDeadline: NetworkClock.Instant? {
        self.timers.values.lazy.map(\.deadline).min()
    }

    /// Drives the scheduler until `condition` holds or `limit` is exhausted, and reports which.
    ///
    /// Use this where a test would otherwise wait for a callback: nothing else is running to
    /// signal one, so progress has to come from this call. Each round drains queued work and then,
    /// if the condition still does not hold, jumps to the next armed deadline. Draining first lets
    /// work already queued satisfy the condition without any time passing.
    ///
    /// Prefer `run()` and `advanceTime(by:)` where a test knows how much progress it expects.
    ///
    /// - Parameters:
    ///   - condition: Checked after the drain and again after the advance.
    ///   - limit: How much virtual time to allow before giving up. Nothing real elapses.
    ///   - rounds: Backstop against a condition that never holds while the scheduler keeps making
    ///     progress.
    /// - Returns: Whether `condition` held. A `false` means the budget or the round count ran out
    ///   with the condition still unmet, so a caller that ignores it goes on to assert against a
    ///   state that never arrived.
    @_spi(Essentials)
    public func run(
        until condition: () -> Bool,
        limit: NetworkDuration = .seconds(30),
        rounds: Int = 10_000
    ) -> Bool {
        let deadline = self.continuous.advanced(by: limit)

        for _ in 0..<rounds {
            self.run()
            if condition() { return true }

            guard let next = self.earliestDeadline, next <= deadline else {
                // Nothing armed within the budget, so no amount of further waiting can
                // change the answer.
                return false
            }
            // Clamped because an already-due wakeup reports a deadline in the past, and
            // `advanceTime(to:)` does not go backwards.
            self.advanceTime(to: max(next, self.continuous))
            if condition() { return true }
        }
        return false
    }
}
