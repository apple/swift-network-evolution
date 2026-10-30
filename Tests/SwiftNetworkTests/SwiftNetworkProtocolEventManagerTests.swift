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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkProtocolEventManagerTests: NetTestCase {
    /// A state that is unregistered during a call from outside has to wait for the call to finish. The
    /// call that leaves it idle removes it, even though that call queued no events to drain.
    func testStateUnregisteredDuringACallIsRemovedWhenTheCallEnds() {
        let context = NetworkContext(identifier: #function)
        context.activate()
        let done = XCTestExpectation()
        context.async {
            var manager = ProtocolEventManager()
            let identifier = InstanceIdentifier(eventManager: &manager, in: &context.eventContext)
            let registered = context.eventContext.protocolEventStates.count

            identifier.fromExternal(in: &context.eventContext) { eventContext in
                manager.unregister(in: &eventContext)
                XCTAssertEqual(
                    eventContext.protocolEventStates.count,
                    registered,
                    "the state stays until the call that holds it ends"
                )
            }
            XCTAssertEqual(context.eventContext.protocolEventStates.count, registered - 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)
    }
}
