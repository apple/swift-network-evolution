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

#if !NETWORK_EMBEDDED

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

internal import DequeModule

/// A scheduler that runs a `NetworkContext` on a clock the test owns.
///
/// Nothing runs until a driver method is called, and time moves only when a driver method moves it, so a
/// test decides exactly which tasks have run and what time the library sees. Timers fire in deadline order
/// with no real waiting, and `now` inside a timer's task is that timer's deadline, which is what lets a
/// deadline the library just reached look reached rather than still pending.
///
/// Everything here belongs to one thread: the test's. The driver methods run on it, and the library queues
/// its own work from inside the tasks they run, so there is no second thread to lock against. A library
/// path that reaches this scheduler from a dispatch queue of its own is a bug in the test's setup, not
/// something this scheduler covers for.
///
/// `runningInScheduler` is true only while a driver method is in the middle of a task. `NetworkContext`
/// asserts on it, so touching library state from outside a task fails loudly instead of silently reading
/// state the next task will change.
@_spi(TestHarness)
@available(Network 0.1.0, *)
public final class VirtualTimeScheduler: NetworkContext.Scheduler {

    /// Non-zero because much of the stack treats `.zero` as "unset".
    public static var defaultStart: NetworkClock.Instant {
        NetworkClock.Instant.zero.advanced(by: .milliseconds(1000))
    }

    /// How far `nowAbsolute` runs ahead of `now`.
    ///
    /// The two clocks are kept apart so a context that reports one in place of the other fails an equality
    /// check instead of matching by coincidence.
    public static var absoluteOffset: NetworkDuration {
        .milliseconds(4000)
    }

    /// The most tasks one driver call may run. Reaching it with work still waiting calls `stallHandler`.
    public let stepLimit: Int

    /// Called with `stepLimit` when a driver call has run that many tasks and more are waiting.
    ///
    /// The default stops the test with a precondition failure, since the usual cause is a task that
    /// reschedules itself without end. A test of the guard itself can install a handler that records the
    /// trip instead; if the handler returns, the driver call stops where it is and leaves the rest pending.
    public var stallHandler: (Int) -> Void = { limit in
        preconditionFailure(
            "VirtualTimeScheduler ran \(limit) tasks in one driver call; "
                + "raise stepLimit or look for a task that reschedules itself without end"
        )
    }

    private struct PendingTimer {
        let deadline: NetworkClock.Instant
        /// Breaks ties between equal deadlines, so timers armed together fire in the order they were armed.
        let sequence: UInt64
        let reference: TimerReference
        let task: () -> Void
    }

    private var immediates = Deque<() -> Void>()
    /// Ordered by deadline, then by `sequence`.
    private var timers = Deque<PendingTimer>()
    /// Where each armed reference sits in `timers`, so a re-arm or an unschedule finds its entry by binary
    /// search instead of a scan. A test that arms thousands of timers would otherwise spend its time here.
    private var armed: [TimerReference: (deadline: NetworkClock.Instant, sequence: UInt64)] = [:]
    private var nextSequence: UInt64 = 0
    private var running = false
    private var stepsTaken = 0
    private var stalled = false

    /// - Parameters:
    ///   - start: What `now` reads before any driver call moves it.
    ///   - stepLimit: How many tasks one driver call may run before `stallHandler` is called.
    public init(start: NetworkClock.Instant = VirtualTimeScheduler.defaultStart, stepLimit: Int = 100_000) {
        precondition(stepLimit > 0, "stepLimit must allow at least one task")
        self.now = start
        self.stepLimit = stepLimit
    }

    // MARK: - Scheduler

    /// Queues the task; nothing runs until a driver method drains the queue.
    public func runImmediate(_ task: @escaping (() -> Void)) {
        immediates.append(task)
    }

    /// Arms a timer at `now` plus the delay, replacing any timer already armed under the same reference.
    ///
    /// Replacing mirrors `DefaultScheduler`: the library re-arms a timer by scheduling again with the
    /// reference it already holds, and expects one firing, not two. A negative delay is due at once.
    public func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
        removeTimer(for: reference)
        // A delay the clock cannot reach is a deadline that never comes. `DefaultScheduler` clamps one
        // rather than trapping, so this saturates instead of overflowing.
        let sinceZero = NetworkClock.Instant.zero.duration(to: now).nanoseconds
        let (nanoseconds, overflow) = sinceZero.addingReportingOverflow(max(delay, .zero).nanoseconds)
        let timer = PendingTimer(
            deadline: overflow ? .maximum : NetworkClock.Instant.zero.advanced(by: .nanoseconds(nanoseconds)),
            sequence: nextSequence,
            reference: reference,
            task: task
        )
        nextSequence += 1
        // The sequence is the largest so far, so the slot found is after every timer with the same deadline.
        timers.insert(timer, at: slot(forDeadline: timer.deadline, sequence: timer.sequence))
        armed[reference] = (timer.deadline, timer.sequence)
    }

    /// Removes the pending timer armed under the reference; a reference that owns none is left alone.
    public func unschedule(reference: TimerReference) {
        removeTimer(for: reference)
    }

    /// True only while a driver method is running a task.
    public var runningInScheduler: Bool {
        running
    }

    /// The virtual continuous clock: it moves only through the driver methods.
    public private(set) var now: NetworkClock.Instant

    /// The virtual absolute clock, a fixed `absoluteOffset` ahead of `now`.
    public var nowAbsolute: NetworkClock.Instant {
        now.advanced(by: VirtualTimeScheduler.absoluteOffset)
    }

    // MARK: - Driving

    /// The earliest pending deadline, or nil when no timer is armed.
    public var nextDeadline: NetworkClock.Instant? {
        timers.first?.deadline
    }

    /// How many timers are armed.
    public var pendingTimerCount: Int {
        timers.count
    }

    /// Runs every queued immediate, including the ones queued while draining, without moving time.
    public func runUntilIdle() {
        drive {
            drainImmediates()
        }
    }

    /// Moves `now` forward by the duration, firing every timer due on the way in deadline order.
    public func advance(by duration: NetworkDuration) {
        advance(to: now.advanced(by: duration))
    }

    /// Moves `now` to the target, firing every timer due on the way in deadline order.
    ///
    /// A timer armed by a task during the advance fires too if its deadline is inside the window. `now`
    /// ends at the target whether or not a timer was there, and it never moves backwards.
    public func advance(to target: NetworkClock.Instant) {
        drive {
            precondition(target >= now, "a virtual clock does not run backwards")
            drainImmediates()
            while hasTimer(dueBy: target), hasStepsLeft(), let timer = popTimer(dueBy: target) {
                run(timer.task)
                drainImmediates()
            }
            // A tripped stall guard leaves the clock where the last task saw it, so the timers it left behind
            // are still ahead of `now`.
            if !stalled {
                now = target
            }
        }
    }

    /// Moves `now` to the next deadline and fires that timer together with the immediates it queues.
    ///
    /// Returns false, having run only the immediates already queued, when no timer was armed.
    @discardableResult
    public func runUntilNextTimer() -> Bool {
        var fired = false
        drive {
            drainImmediates()
            guard hasTimer(dueBy: nil), hasStepsLeft(), let timer = popTimer(dueBy: nil) else {
                return
            }
            fired = true
            run(timer.task)
            drainImmediates()
        }
        return fired
    }

    // MARK: - Driver internals

    /// Brackets one driver call: marks the scheduler as running, resets the stall guard, and rejects a
    /// driver call made from inside a task, which would run the queue on top of itself.
    private func drive(_ body: () -> Void) {
        precondition(!running, "a driver method was called from inside a scheduled task")
        running = true
        stepsTaken = 0
        stalled = false
        defer {
            running = false
        }
        body()
    }

    private func drainImmediates() {
        while !immediates.isEmpty, hasStepsLeft(), let task = immediates.popFirst() {
            run(task)
        }
    }

    /// Whether this driver call may run another task; the first refusal is what trips the stall guard.
    ///
    /// Asked only with a task waiting, so a call that reaches the limit and has nothing left to run is a
    /// finished call, not a stalled one.
    private func hasStepsLeft() -> Bool {
        if stalled {
            return false
        }
        if stepsTaken < stepLimit {
            return true
        }
        stalled = true
        stallHandler(stepLimit)
        return false
    }

    /// Whether the earliest timer is due by the target; nil means any deadline counts.
    private func hasTimer(dueBy target: NetworkClock.Instant?) -> Bool {
        guard let first = timers.first else {
            return false
        }
        if let target, target < first.deadline {
            return false
        }
        return true
    }

    /// Takes the earliest timer, if it is due by the target, and moves `now` to its deadline before anything
    /// runs, so the task sees its own deadline as the present.
    private func popTimer(dueBy target: NetworkClock.Instant?) -> PendingTimer? {
        guard hasTimer(dueBy: target), let first = timers.first else {
            return nil
        }
        now = first.deadline
        armed[first.reference] = nil
        return timers.removeFirst()
    }

    private func removeTimer(for reference: TimerReference) {
        guard let entry = armed.removeValue(forKey: reference) else {
            return
        }
        let index = slot(forDeadline: entry.deadline, sequence: entry.sequence)
        precondition(index < timers.count && timers[index].sequence == entry.sequence, "armed timer missing")
        timers.remove(at: index)
    }

    /// The index of the timer with this deadline and sequence, or where one would go: the first slot whose
    /// timer is not ordered before it.
    private func slot(forDeadline deadline: NetworkClock.Instant, sequence: UInt64) -> Int {
        var low = 0
        var high = timers.count
        while low < high {
            let middle = (low + high) / 2
            let timer = timers[middle]
            if timer.deadline < deadline || (timer.deadline == deadline && timer.sequence < sequence) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func run(_ task: () -> Void) {
        stepsTaken += 1
        task()
    }
}

#endif  // !NETWORK_EMBEDDED
