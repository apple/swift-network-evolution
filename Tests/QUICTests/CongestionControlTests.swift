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

import XCTest
@testable import QUIC

final class CongestionControlTests: XCTestCase {
    func testCongestionControlPolicyResolution() {
        var pacer = Pacer(enabled: false)
        let qlog = QLog(isServer: true, connectionID: QUICConnectionID(id: []))
        let log = LogPrefixer(prefix: "test")

        // Test Cubic Initialization
        let cubicPolicy = CongestionControlPolicy(algorithm: .cubic)
        let cubicEngine = CongestionControlEngine(
            policy: cubicPolicy,
            mss: 1200,
            pacer: &pacer,
            qlog: qlog,
            log: log
        )
        XCTAssertEqual(cubicEngine.name, "cubic")
        
        #if !NETWORK_EMBEDDED
        // Test Prague Initialization
        let praguePolicy = CongestionControlPolicy(algorithm: .prague)
        let pragueEngine = CongestionControlEngine(
            policy: praguePolicy,
            mss: 1200,
            pacer: &pacer,
            qlog: qlog,
            log: log
        )
        XCTAssertEqual(pragueEngine.name, "prague")

        // Test Ledbat Initialization
        let ledbatPolicy = CongestionControlPolicy(algorithm: .ledbat)
        let ledbatEngine = CongestionControlEngine(
            policy: ledbatPolicy,
            mss: 1200,
            pacer: &pacer,
            qlog: qlog,
            log: log
        )
        XCTAssertEqual(ledbatEngine.name, "ledbat")
        #endif
    }

    func testCongestionControlApplyTransitions() {
        var pacer = Pacer(enabled: false)
        let qlog = QLog(isServer: true, connectionID: QUICConnectionID(id: []))
        let log = LogPrefixer(prefix: "test")

        var engine = CongestionControlEngine(
            policy: CongestionControlPolicy(algorithm: .cubic),
            mss: 1200,
            pacer: &pacer,
            qlog: qlog,
            log: log
        )
        
        XCTAssertEqual(engine.name, "cubic")
        
        #if !NETWORK_EMBEDDED
        // Apply Prague policy and ensure state inheritance triggers correctly
        engine.apply(
            policy: CongestionControlPolicy(algorithm: .prague),
            mss: 1200,
            pacer: &pacer,
            qlog: qlog,
            log: log
        )
        XCTAssertEqual(engine.name, "prague")

        // Apply Ledbat policy
        engine.apply(
            policy: CongestionControlPolicy(algorithm: .ledbat),
            mss: 1200,
            pacer: &pacer,
            qlog: qlog,
            log: log
        )
        XCTAssertEqual(engine.name, "ledbat")
        #endif
    }
}

#endif
