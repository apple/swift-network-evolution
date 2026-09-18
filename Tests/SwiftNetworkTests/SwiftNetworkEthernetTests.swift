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

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

@available(Network 0.1.0, *)
final class SwiftNetworkEthernetTests: NetTestCase {

    func testEthernetHeaders() {
        let etherAddr1 = EthernetAddress([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
        let etherAddr2 = EthernetAddress([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])

        XCTAssertEqual(EthernetProtocol.headerLength, 14)

        XCTAssertNotNil(etherAddr1)
        XCTAssertNotNil(etherAddr2)
        guard let etherAddr1, let etherAddr2 else { return }

        let senderProperties = EthernetProtocol.Properties(
            localEthernet: etherAddr1,
            remoteEthernet: etherAddr2,
            addressFamily: .ipv4
        )
        let receiverProperties = EthernetProtocol.Properties(
            localEthernet: etherAddr2,
            remoteEthernet: etherAddr1,
            addressFamily: .ipv4
        )

        let frameLength = 24
        var frame = Frame(count: frameLength)
        XCTAssertEqual(frame.unclaimedLength, frameLength)

        let writeResult = senderProperties.writeHeader(into: &frame, claim: true)
        XCTAssertTrue(writeResult.isValid)
        XCTAssertEqual(frame.unclaimedLength, frameLength - EthernetProtocol.headerLength)

        let unclaimResult = frame.unclaim(fromStart: EthernetProtocol.headerLength)
        XCTAssertTrue(unclaimResult)

        let validateResult = receiverProperties.validateHeader(from: &frame, claim: false)
        XCTAssertTrue(validateResult.isValid)

        let expectedBytes: [UInt8] = [
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E, 0x08, 0x00,
        ]
        var syntheticFrame = Frame(copyBuffer: expectedBytes)

        let validateSyntheticResult = receiverProperties.validateHeader(from: &syntheticFrame, claim: false)
        XCTAssertTrue(validateSyntheticResult.isValid)

        frame.finalize(success: true)
        syntheticFrame.finalize(success: true)
    }
}
