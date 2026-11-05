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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#endif

#if !NETWORK_PRIVATE
@available(Network 0.1.0, *)
class NetTestCase: XCTestCase {
    private var timersArmedAtStart: Int?

    override func setUp() {
        super.setUp()
        timersArmedAtStart = Self.timersArmed(on: NetworkContext.implicitContext)
    }

    override func tearDown() {
        if let timersArmedAtStart, let pending = Self.timersArmed(on: NetworkContext.implicitContext) {
            XCTAssertLessThanOrEqual(
                pending,
                timersArmedAtStart,
                "\(pending - timersArmedAtStart) timer(s) left armed on the implicit context; something this test started is still running"
            )
        }
        super.tearDown()
    }

    static func timersArmed(on context: NetworkContext) -> Int? {
        run(on: context) { context.globals.timerList.entries.count }
    }

    static func run<R>(
        on context: NetworkContext,
        timeout: NetworkDuration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping () -> R
    ) -> R? {
        context.activate()
        context.assertExternal()
        var result: R?
        let finished = DispatchSemaphore(value: 0)
        context.async {
            result = body()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + .nanoseconds(Int(timeout.nanoseconds))) == .success else {
            XCTFail("The context did not run the work within \(timeout); it is blocked", file: file, line: line)
            return nil
        }
        return result
    }

    #if !NETWORK_NO_SWIFT_QUIC
    // Waits for `connections` to finish closing: each one has reached a terminal state and has no
    // timer left armed.
    func waitForQUICConnectionsToFinish(
        _ connections: [QUICConnection],
        on context: NetworkContext,
        timeout: NetworkDuration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let clock = NetworkClock()
        let deadline = clock.now + timeout
        while true {
            let finished = Self.run(on: context, timeout: timeout, file: file, line: line) {
                connections.allSatisfy { $0.state.isTerminal && $0.timer.nextDeadline == .zero }
            }
            guard let finished else {
                return
            }
            if finished {
                return
            }
            if clock.now >= deadline {
                XCTFail("QUIC connections did not finish closing within \(timeout)", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    #endif
}
#endif
