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

import Dispatch

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

@available(Network 0.1.0, *)
extension NetworkContext {
    private static let onQueueKey = DispatchSpecificKey<Void>()

    /// Runs `body` on the context's queue and returns its result.
    ///
    /// Acquiring the event context asserts that the caller is already running on the context's
    /// queue. Test bodies run on the main thread, so anything that reaches `fromExternal` — for
    /// example building a path with `makeFromExternalTest`, or letting a stream deallocate — has to
    /// hop here first. `sync` keeps `body` non-escaping, which matters for the noncopyable
    /// values these tests build.
    ///
    /// When the caller is already on the queue — inside a `context.async` block, or nested in
    /// another `onQueue` — `body` runs directly, since `sync` onto the current queue deadlocks.
    func onQueue<R>(_ body: () throws -> R) rethrows -> R {
        queue.setSpecific(key: NetworkContext.onQueueKey, value: ())
        if DispatchQueue.getSpecific(key: NetworkContext.onQueueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }
}

#endif
