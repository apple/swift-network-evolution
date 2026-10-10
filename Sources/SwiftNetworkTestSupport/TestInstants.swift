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
    ///
    /// Kept apart from `ManualTimeContext` because it needs nothing but the clock type. A build
    /// that cannot supply a scheduler can still seed a test with this.
    @_spi(Essentials)
    public static var testBase: NetworkClock.Instant {
        NetworkClock.Instant.zero.advanced(by: .milliseconds(1000))
    }
}
