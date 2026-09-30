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

import Dispatch
import XCTest

@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

@available(Network 0.1.0, *)
extension NetworkContext {
    /// Runs `body` on the context and returns its result, for a caller that is not on it.
    ///
    /// Reaching the event context asserts that the caller is already running on the context, so
    /// anything that registers protocol state -- building a `BaseNetworkProtocolStorage`, creating
    /// a protocol instance -- has to hop here first rather than doing it on the test thread.
    ///
    /// Hands the work to `async` and waits rather than using `sync`, because a context may be
    /// backed by a dispatch workloop and a workloop does not accept `dispatch_sync`. `body` stays
    /// non-escaping.
    ///
    /// The same helper exists in `QUICTests/QUICTestContext.swift`; the two test targets do not
    /// share a support module, so it is duplicated rather than imported.
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
            // can happen after the signal above, so take one more turn on the context first.
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
