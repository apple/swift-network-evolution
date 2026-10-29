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

#if !NETWORK_EMBEDDED && !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Synchronization) && canImport(Dispatch)

/// The owner's side of a standalone protocol: the clock, the timers, the asyncs and the events.
///
/// The environment replaces the Dispatch queue a `NetworkContext` normally runs on. The protocol is
/// built on a context whose scheduler only records what it is asked to do, so after any call into
/// the protocol the owner asks the environment what is needed:
///
/// ```
/// call into the protocol            // write, receive, connect, disconnect, ...
/// environment.turn(now: clock.now)  // run asyncs and due timers the protocol asked for
/// environment.drainEvents { ... }   // connected, new flow, data available, QUIC events, ...
/// driver.takeOutbound(...)          // datagrams or stream data to send below
/// arm a timer for environment.nextTimerDeadline
/// ```
///
/// An environment and every driver built on it belong to one execution context. Call into them
/// from one thread (or serial queue) at a time.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class StandaloneEnvironment {
    public let scheduler: StandaloneScheduler
    @_spi(Essentials)
    public let context: NetworkContext

    /// Creates an environment.
    ///
    /// - Parameters:
    ///   - identifier: Names the underlying context in logs.
    ///   - now: The starting time. Must be greater than zero.
    public init(identifier: String = "standalone", now: NetworkClock.Instant) {
        let scheduler = StandaloneScheduler(now: now)
        self.scheduler = scheduler
        self.context = NetworkContext(identifier: identifier, externalScheduler: scheduler)
    }

    // MARK: - Time, timers and asyncs

    /// The environment's current time.
    public var now: NetworkClock.Instant { scheduler.now }

    /// The earliest time the owner has to call `turn(now:)` by, or `nil` if no timer is armed.
    ///
    /// This is a "set a timer for this deadline" request: replace whatever timer the owner has
    /// armed with one for this deadline.
    public var nextTimerDeadline: NetworkClock.Instant? { scheduler.nextTimerDeadline }

    /// Whether the protocol asked to be called back and has not been yet.
    ///
    /// The owner calls `turn(now:)` as soon as it can. When the request comes from another thread,
    /// `scheduler.onWorkAvailable` fires.
    public var needsAsync: Bool { scheduler.hasPendingAsync }

    /// Moves the clock to `now`, then runs queued asyncs and every timer that is due, until the
    /// protocol has nothing more to do right now.
    public func turn(now: NetworkClock.Instant) {
        scheduler.advance(to: now)
        turn()
    }

    /// Runs queued asyncs and every timer that is due at the current time.
    public func turn() {
        var progressed = true
        while progressed {
            progressed = scheduler.runPendingAsync()
            if scheduler.fireDueTimers() { progressed = true }
        }
    }

    // MARK: - Events

    /// Whether any event is waiting.
    public var hasEvents: Bool { !context.eventContext.standaloneEvents.isEmpty }

    /// Removes and returns the oldest event.
    public func nextEvent() -> StandaloneEvent? {
        context.eventContext.standaloneEvents.isEmpty ? nil : context.eventContext.standaloneEvents.removeFirst()
    }

    /// Hands every queued event to `handler`, oldest first.
    ///
    /// Events the handler provokes (by calling back into a protocol) are delivered in the same
    /// call.
    public func drainEvents(_ handler: (StandaloneEvent) -> Void) {
        while let event = nextEvent() {
            handler(event)
        }
    }
}

#endif
