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

@available(Network 0.1.0, *)
extension NetworkClock.Instant {
    /// A fixed instant to seed tests that need one.
    ///
    /// The value is arbitrary, but it does have to be fixed: seeding from the real clock makes
    /// every duration depend on how long the test itself took to run.
    ///
    /// Non-zero because much of the stack treats `.zero` as "unset". Built by advancing from
    /// `.zero` rather than with `Instant(milliseconds:)`, which is internal to `SwiftNetwork`.
    @_spi(Essentials)
    public static var testBase: NetworkClock.Instant {
        NetworkClock.Instant.zero.advanced(by: .milliseconds(1000))
    }

}

/// A context on a clock the test owns, and the scheduler that drives it.
///
/// Tests need both halves: the context to hand to `Parameters`, and the scheduler to drain queued
/// work or advance virtual time. `NetworkContext.scheduler` is internal to `SwiftNetwork`, so a
/// test cannot recover the scheduler from the context it just built.
@_spi(Essentials)
@available(Network 0.1.0, *)
public struct ManualTimeContext {

    /// Drives queued work and owns virtual time.
    @_spi(Essentials)
    public let scheduler: ManualScheduler

    /// Hand this to `Parameters(context:)`, or to a protocol instance.
    @_spi(Essentials)
    public let context: NetworkContext

    @_spi(Essentials)
    public init(_ identifier: String, now: NetworkClock.Instant = .testBase) {
        let scheduler = ManualScheduler(now: now)
        self.scheduler = scheduler
        self.context = NetworkContext(identifier: identifier, externalScheduler: scheduler)
    }

    /// Runs queued work and any timer already due, including whatever those queue in turn.
    ///
    /// Prefer `scheduler.run(until:)` when progress needs virtual time to advance.
    @_spi(Essentials)
    public func run() {
        self.scheduler.run()
    }
}
