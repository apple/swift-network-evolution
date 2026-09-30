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

// Where the event context lives, and the only two ways to reach it.
//
// The stack has exactly two kinds of entry, and they differ by *who delivers the work*, not by
// how deep in the stack the call sits:
//
// - Work the scheduler itself delivers -- a timer firing, a socket readiness callback, a block
//   handed to `runImmediate` -- is already running on the context's serial execution. It reaches
//   the event context through `entered(_:)`, synchronously, with no `await`. Protocols deep in
//   the stack that call an external-entry overload such as `deliverConnectedEvent()` end up here
//   without changing their spelling.
//
// - Work arriving from somewhere genuinely off the scheduler -- a client API call on
//   `NetworkChannel`, an async TLS certificate evaluation callback -- reaches it through
//   `enter(_:)`, which is actor-isolated and so requires `await`. The compiler enforces that.
//
// Once either door is open the event context is threaded `inout` and nothing suspends, which is
// what keeps the stack's internals free of `await`.

#if !NETWORK_PRIVATE || NETWORK_STANDALONE

// MARK: - Executor

#if !NETWORK_EMBEDDED

/// A serial executor over a `NetworkContext.Scheduler`.
///
/// Used when the scheduler does not already conform to `SerialExecutor` itself, which is the case
/// for the Dispatch-backed `NetworkContext.DefaultScheduler`. Owned by the isolation actor; the
/// scheduler does not own it back, so there is no cycle.
@available(Network 0.1.0, *)
final class NetworkContextExecutor: SerialExecutor {
    // `@unchecked` on the stored scheduler: `SerialExecutor` refines `Sendable`, and
    // `any NetworkContext.Scheduler` is not `Sendable` today. `NetworkContext` already holds one
    // and is itself `@unchecked Sendable`, so this claims nothing new -- a scheduler is
    // context-confined and its `runImmediate`/`runningInScheduler` are already called from any
    // thread. Making `Scheduler` refine `Sendable` would remove this, at the cost of breaking
    // external conformances.
    private let scheduler: any NetworkContext.Scheduler

    init(scheduler: any NetworkContext.Scheduler) {
        self.scheduler = scheduler
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        // `runImmediate` guarantees the work does not run on the caller's stack, which is
        // exactly `enqueue`'s contract.
        scheduler.runImmediate {
            unownedJob.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        precondition(scheduler.runningInScheduler, "Not running on the network context's scheduler")
    }
}

// MARK: - Isolation

/// Owns a context's `EventContext` and gates access to it.
///
/// See the note at the top of this file for the two doors and which callers use which.
@available(Network 0.1.0, *)
actor NetworkContextIsolation {

    /// The event context.
    ///
    /// `nonisolated(unsafe)` because the two doors have to share one piece of storage:
    /// `enter(_:)` is actor-isolated, while `entered(_:)` is reached synchronously from
    /// scheduler-delivered work that cannot prove isolation to the compiler. Actor isolation
    /// cannot cover both today -- see `entered(_:)`.
    ///
    /// Safety rests on a single invariant: **both doors only ever run on `executor`**, which is
    /// serial, so two accesses can never overlap. `enter(_:)` is bound to the executor by actor
    /// isolation; `entered(_:)` checks it dynamically before touching this.
    private nonisolated(unsafe) var eventContext: NetworkContext.EventContext

    /// The serial execution everything in this context runs on.
    ///
    /// The scheduler itself when it is already a `SerialExecutor` -- as `ConcurrencyScheduler`
    /// is -- so that executor identity matches the queue the work actually runs on. Otherwise a
    /// `NetworkContextExecutor` wrapper over `runImmediate`.
    nonisolated let executor: any SerialExecutor

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    init(
        globals: NetworkContext.Globals,
        scheduler: any NetworkContext.Scheduler,
        schedulerIsDefault: Bool
    ) {
        self.eventContext = .init(globals: globals, scheduler: scheduler, schedulerIsDefault: schedulerIsDefault)
        self.executor = (scheduler as? any SerialExecutor) ?? NetworkContextExecutor(scheduler: scheduler)
    }

    /// Enters the context from off the scheduler. Requires `await`.
    ///
    /// For callers with no scheduling relationship to the context: a client API call on
    /// `NetworkChannel`, or an async callback such as TLS certificate evaluation. Being
    /// actor-isolated, this is the door the compiler enforces -- there is no way to call it
    /// without suspending onto the context's executor first.
    ///
    /// `body` is `sending` because it crosses into the actor's region. Captures must therefore be
    /// `Sendable`; the synchronous door below has no such requirement.
    func enter<R: ~Copyable, E: Error>(
        _ body: sending (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> sending R {
        try body(&eventContext)
    }

    /// Enters the context from work the scheduler itself delivered. No `await`.
    ///
    /// **This is the one place the event context is reached without the compiler proving
    /// isolation.** Callers are already on the executor because the scheduler put them there --
    /// a timer firing, a socket readiness callback, a `runImmediate` block -- and a synchronous
    /// callback arriving from libdispatch or a kqueue can never be *statically* proven isolated.
    /// The check is real: `checkIsolated()` traps off-executor.
    ///
    /// `assumeIsolated` is the API designed for exactly this -- a dynamic check promoted to
    /// static isolation -- and is what this should be. It cannot be used yet because it requires
    /// its result to be `Copyable` and, being `rethrows`, cannot carry `throws(E)`; this stack's
    /// entry points are `~Copyable`-returning and typed-throwing. When `assumeIsolated` is
    /// generalised over both, the body of this one function becomes
    /// `try executor.assumeIsolated { try body(&$0.eventContext) }`, the `nonisolated(unsafe)`
    /// above goes away, and **no call site changes**.
    ///
    /// Takes a plain closure, not a `sending` one: nothing crosses an isolation boundary here, so
    /// captures need not be `Sendable`.
    nonisolated func entered<R: ~Copyable, E: Error>(
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        executor.checkIsolated()
        return try body(&eventContext)
    }

    /// The same door as `entered(_:)`, in accessor shape rather than closure shape.
    ///
    /// Needed only by delegating initializers: `self.init(context:in:)` cannot appear inside a
    /// closure, so those three call sites cannot use `entered(_:)`. Same invariant, same
    /// `checkIsolated()`; when `assumeIsolated` is generalised this collapses into `entered(_:)`
    /// along with it.
    nonisolated var enteredEventContext: NetworkContext.EventContext {
        _read {
            executor.checkIsolated()
            yield eventContext
        }
        _modify {
            executor.checkIsolated()
            yield &eventContext
        }
    }
}

#else

/// Embedded builds have no concurrency runtime, so the event context is held directly and only
/// the synchronous door exists. `NetworkContext.entered(_:)` has the same signature either way,
/// so nothing that uses it needs to know which of these it got.
@available(Network 0.1.0, *)
final class NetworkContextIsolation {
    private var eventContext: NetworkContext.EventContext

    init(
        globals: NetworkContext.Globals,
        scheduler: any NetworkContext.Scheduler,
        schedulerIsDefault: Bool
    ) {
        self.eventContext = .init(globals: globals, scheduler: scheduler, schedulerIsDefault: schedulerIsDefault)
    }

    func entered<R: ~Copyable, E: Error>(
        _ body: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        try body(&eventContext)
    }

    var enteredEventContext: NetworkContext.EventContext {
        _read { yield eventContext }
        _modify { yield &eventContext }
    }
}

#endif

// MARK: - Context facade

@available(Network 0.1.0, *)
extension NetworkContext {

    /// Enters the context from work the scheduler delivered; see
    /// `NetworkContextIsolation.entered(_:)`.
    ///
    /// This is what every external-entry overload in the stack -- `deliverConnectedEvent()`,
    /// `invokeConnect()`, and the rest of the no-`in:` pairs -- funnels through.
    @inline(__always)
    func entered<R: ~Copyable, E: Error>(
        _ body: (inout EventContext) throws(E) -> R
    ) throws(E) -> R {
        try isolation.entered(body)
    }

    /// The event context, for delegating initializers only; see
    /// `NetworkContextIsolation.enteredEventContext`.
    var enteredEventContext: EventContext {
        _read { yield isolation.enteredEventContext }
        _modify { yield &isolation.enteredEventContext }
    }

    #if !NETWORK_EMBEDDED
    /// Enters the context from off the scheduler; see `NetworkContextIsolation.enter(_:)`.
    func enter<R: ~Copyable, E: Error>(
        _ body: sending (inout EventContext) throws(E) -> R
    ) async throws(E) -> sending R {
        try await isolation.enter(body)
    }

    /// The serial executor this context runs on.
    ///
    /// Always present, unlike `NetworkContext.serialExecutor`, which only reports a scheduler
    /// that is itself a `SerialExecutor`.
    var isolationExecutor: any SerialExecutor {
        isolation.executor
    }
    #endif
}

#endif
