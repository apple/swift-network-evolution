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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
extension NetworkContext {
    /// Runs `body` on the context and returns its result, for a caller that is not on it.
    ///
    /// Acquiring the event context asserts that the caller is already running on the context, so
    /// anything that reaches `fromExternal` -- for example building a path with
    /// `makeFromExternalTest`, or letting a stream deallocate -- has to hop here first. `body` stays
    /// non-escaping, which matters for the noncopyable values these tests build.
    ///
    /// This hands the work to `async` and waits for it rather than running it with `sync`, because a
    /// context may be backed by a dispatch workloop, and a workloop does not accept `dispatch_sync`.
    ///
    /// Waiting means a caller already on the context would wait for itself, so the two modes are
    /// separate: this one hops, and code that is already on the context calls its work directly.
    /// The assertion keeps that split honest rather than deciding at run time.
    ///
    /// A context has nothing to run on until it is activated, and activating twice is harmless, so
    /// this does it rather than asking every test to remember.
    func onQueue<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        activate()
        dispatchPrecondition(condition: .notOnQueue(queue))

        var outcome: Result<R, E>? = nil
        withoutActuallyEscaping(body) { escapingBody in
            let finished = DispatchSemaphore(value: 0)
            async {
                do {
                    outcome = .success(try escapingBody())
                } catch let error as E {
                    // `withoutActuallyEscaping` erases the closure's thrown type, so name it back.
                    outcome = .failure(error)
                } catch {
                    preconditionFailure("body threw \(type(of: error)), which it is typed not to")
                }
                finished.signal()
            }
            finished.wait()

            // `body` has run, but the block that captured it is released by whatever ran it, which
            // can happen after the signal above. `withoutActuallyEscaping` traps if the closure is
            // still referenced when this scope ends, so take one more turn on the context: the
            // block ahead of this one has been let go by the time this one runs.
            let drained = DispatchSemaphore(value: 0)
            async { drained.signal() }
            drained.wait()
        }

        switch outcome! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

#endif
