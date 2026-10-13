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

@_spi(ProtocolProvider) import SwiftNetworkBenchmarks
@testable import IPUDPTransfer

@available(Network 0.1.0, *)
final class IPUDPTransferTests: XCTestCase {
    func testOversizedDatagramDoesNotCountAsTransfer() {
        let transfer = IPUDPTransfer()
        let loggingHandle = LoggingHandle(loggingType: .none)

        let validTransferTime = transfer.run(
            iterations: 1,
            packets: 1,
            loggingHandle: loggingHandle,
            group: DispatchGroup(),
            sendSize: 1472
        )
        XCTAssertGreaterThan(validTransferTime, 0)

        let oversizedTransferTime = transfer.run(
            iterations: 1,
            packets: 1,
            loggingHandle: loggingHandle,
            group: DispatchGroup(),
            sendSize: 1473
        )
        XCTAssertEqual(oversizedTransferTime, 0)
    }
}
