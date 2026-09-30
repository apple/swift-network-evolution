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
#elseif canImport(Musl)
import Musl
#endif

#if !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Dispatch) && !NETWORK_EMBEDDED

/// A `NetworkContext.Scheduler` that drives timers with Swift Concurrency instead of
/// `DispatchSourceTimer`, and that doubles as the context's `SerialExecutor`.
///
/// Two things differ from `NetworkContext.DefaultScheduler`:
///
/// - **Timers** are armed by a single `ContinuousClock` driver task. One task serves every
///   timer: entries are held in a deadline-ordered list, and scheduling something sooner than
///   the current earliest deadline cancels and re-arms the driver rather than adding another
///   task. A timer is therefore an *entry point* into the stack, never a suspension of it --
///   nothing holding the event context ever awaits, so an armed timer cannot stop the context
///   from being entered by an application call, a socket event, or another timer.
///
/// - **It is a `SerialExecutor`**, so tasks and actors can be bound to the context's serial
///   execution. This is what lets `await` *enter* the context while the work inside stays
///   synchronous. The scheduler is its own executor rather than owning a separate one, which
///   keeps executor identity stable and avoids a reference cycle between the two.
///
/// Serialization at the bottom is still a `DispatchQueue`. That is a deliberate choice, not an
/// unfinished edge: a hand-written serial executor needs its own worker thread to pull from a
/// job queue, and libdispatch's serial queue already is a well-tuned one. Everything above goes
/// through `runImmediate`/`enqueue`, so replacing it later is a local change.
///
/// Socket readiness still uses `DispatchSource` in `SocketProtocol`. Moving that to a
/// per-context kqueue/epoll poller is separate work and needs syscall wrappers the package does
/// not have yet.
///
/// `@unchecked Sendable` for the same reason `NetworkContext` is: the mutable timer state below
/// is confined to `queue`, which every path funnels through. Do not add mutable state that is
/// touched off the queue.
@_spi(Essentials)
@available(Network 0.1.0, *)
public final class ConcurrencyScheduler: NetworkContext.Scheduler, SerialExecutor, @unchecked Sendable {

    /// A scheduled timer. Held in deadline order; `reference` identifies it for removal.
    private struct Entry {
        let deadline: ContinuousClock.Instant
        let reference: TimerReference
        let task: () -> Void
    }

    private let queue: DispatchQueue

    /// Identifies `queue` so `runningInScheduler` can answer as a Boolean instead of trapping;
    /// `NetworkContext.Globals.runningOnQueue` uses the same approach.
    private static let queueIdentity = DispatchSpecificKey<ObjectIdentifier>()

    /// Pending timers in deadline order. Only ever touched on `queue`.
    private var entries: [Entry] = []

    /// The single in-flight sleep and the deadline it was armed for. Only touched on `queue`.
    private var driver: Task<Void, Never>?
    private var armedDeadline: ContinuousClock.Instant?

    public init(label: String = "network concurrency context") {
        self.queue = DispatchQueue(label: label)
        self.queue.setSpecific(key: ConcurrencyScheduler.queueIdentity, value: ObjectIdentifier(self))
    }

    // MARK: - Scheduler

    public func runImmediate(_ task: @escaping (() -> Void)) {
        queue.async(execute: DispatchWorkItem(block: task))
    }

    public func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
        // Read the deadline from the caller's clock reading, not the queue's: a delay means
        // "this long from when it was asked for". A negative delay fires at the first
        // opportunity, matching `NetworkContext.FutureTime.after`.
        let deadline = ContinuousClock.now + .nanoseconds(max(delay.nanoseconds, 0))
        onQueue {
            self.removeEntry(for: reference)
            self.insertEntry(Entry(deadline: deadline, reference: reference, task: task))
            self.rearmDriver()
        }
    }

    public func unschedule(reference: TimerReference) {
        onQueue {
            self.removeEntry(for: reference)
            self.rearmDriver()
        }
    }

    public var runningInScheduler: Bool {
        DispatchQueue.getSpecific(key: ConcurrencyScheduler.queueIdentity) == ObjectIdentifier(self)
    }

    public var now: NetworkClock.Instant {
        NetworkClock.Instant.systemNow
    }

    public var nowAbsolute: NetworkClock.Instant {
        NetworkClock.Instant.systemNowAbsolute
    }

    // MARK: - SerialExecutor

    public func enqueue(_ job: consuming ExecutorJob) {
        // `UnownedJob` is what survives into the escaping closure; the job is consumed here.
        // Going through the queue satisfies `enqueue`'s contract that the work must not run on
        // the caller's stack.
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    public func checkIsolated() {
        precondition(runningInScheduler, "Not running on the network context's scheduler")
    }

    // MARK: - Timer driving

    /// Runs `body` on the scheduler's serial execution, inline when already there.
    ///
    /// `schedule` and `unschedule` are called both from inside the context and from outside it,
    /// and the timer list is queue-confined, so entering it has to work either way. Running
    /// inline when already on the queue keeps a timer armed from inside the stack from slipping
    /// to a later turn, matching what the Dispatch scheduler does today.
    private func onQueue(_ body: @escaping () -> Void) {
        if runningInScheduler {
            body()
        } else {
            queue.async(execute: DispatchWorkItem(block: body))
        }
    }

    private func insertEntry(_ entry: Entry) {
        // Linear insertion keeps the list sorted. Pending timer counts are small -- per-protocol
        // retransmission, idle, and pacing timers -- so this beats a heap's constant factor
        // here. `NetworkPriorityQueue`, which the Dispatch scheduler uses, is the drop-in if
        // that assumption ever stops holding.
        let index = entries.firstIndex { $0.deadline > entry.deadline } ?? entries.count
        entries.insert(entry, at: index)
    }

    private func removeEntry(for reference: TimerReference) {
        if let index = entries.firstIndex(where: { $0.reference == reference }) {
            entries.remove(at: index)
        }
    }

    /// Arms the driver for the earliest pending deadline, replacing a sleep that now wakes too late.
    private func rearmDriver() {
        guard let earliest = entries.first?.deadline else {
            driver?.cancel()
            driver = nil
            armedDeadline = nil
            return
        }
        // A sleep that already wakes at or before the earliest deadline is still good enough.
        if let armedDeadline, armedDeadline <= earliest, driver != nil {
            return
        }
        driver?.cancel()
        armedDeadline = earliest
        driver = Task { [weak self] in
            // Cancellation is how re-arming works, so a cancelled sleep is expected: it just
            // ends this driver, and the task that replaced it owns the new deadline.
            try? await Task.sleep(until: earliest, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.runImmediate { self.fireDueEntries() }
        }
    }

    /// Runs every entry whose deadline has passed, then re-arms for whatever remains.
    ///
    /// Mirrors `NetworkContext.Globals.TimerList.runTimer()`: a fired block may schedule further
    /// timers, so the list is re-read each iteration rather than snapshotted, and re-arming
    /// happens last so those new timers are accounted for.
    private func fireDueEntries() {
        driver = nil
        armedDeadline = nil

        while let first = entries.first, first.deadline <= ContinuousClock.now {
            entries.removeFirst()
            first.task()
        }
        rearmDriver()
    }
}

// MARK: - Context integration

@_spi(Essentials)
@available(Network 0.1.0, *)
extension NetworkContext {

    /// Creates a context whose timers are driven by Swift Concurrency.
    ///
    /// The stack behaves identically inside; only what wakes it changes. See
    /// `ConcurrencyScheduler`.
    public static func concurrencyScheduled(identifier: String) -> NetworkContext {
        NetworkContext(identifier: identifier, externalScheduler: ConcurrencyScheduler(label: identifier))
    }

    /// The serial executor for this context's scheduler, if it provides one.
    ///
    /// `nil` for the Dispatch-backed default, whose queue is a plain `DispatchQueue` rather than
    /// a `DispatchSerialQueue`. Bind Swift Concurrency work to this rather than hopping through
    /// `async(_:)` when the context has one.
    public var serialExecutor: (any SerialExecutor)? {
        scheduler as? any SerialExecutor
    }
}

#endif
