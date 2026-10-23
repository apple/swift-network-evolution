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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestSupport)
@_spi(Essentials) import SwiftNetworkTestSupport
#endif

/// A context on the clock `TestClock` selects.
@available(Network 0.1.0, *)
struct TestClockContext {
    let context: NetworkContext

    /// Drives `context` on a mock clock; `nil` on the system clock, where the context runs itself.
    let manual: ManualTimeContext?

    init(_ identifier: String) {
        if TestClock.usesRealTime {
            self.context = NetworkContext(identifier: identifier)
            self.manual = nil
        } else {
            let manual = ManualTimeContext(identifier)
            self.context = manual.context
            self.manual = manual
        }
        // A mock context has its own globals, and a connection built on it before activation traps.
        self.context.activate()
    }
}

#endif
