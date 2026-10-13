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
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkProtocolStackTests: NetTestCase {
    func testIPOptions() {
        let ipOptions = IPProtocol.definition.protocolOptions()
        ipOptions.modifyPerProtocolOptions { $0.version = .v6 }
        ipOptions.modifyPerProtocolOptions { $0.hopLimit = 10 }

        XCTAssertTrue(ipOptions.matches(definition: IPProtocol.definition), "Invalid protocol definition")

        XCTAssertEqual(ipOptions.perProtocolOptions?.hopLimit, 10, "Failed to set hop limit")
        XCTAssertEqual(ipOptions.perProtocolOptions?.version, .v6, "Failed to set version")

        let ipOptionsCopy = ipOptions.deepCopy()
        XCTAssertTrue(ipOptionsCopy.matches(definition: IPProtocol.definition), "Invalid protocol definition on copy")
        XCTAssertEqual(ipOptionsCopy.perProtocolOptions?.hopLimit, 10, "Failed to get hop limit on copy")
        XCTAssertEqual(ipOptionsCopy.perProtocolOptions?.version, .v6, "Failed to get version on copy")
    }

    func testIPOptionsInStack() {
        let stack = ProtocolStack()

        let ipOptions = stack.internetOptionsAsIPOptions(mutable: true)
        XCTAssertNotNil(ipOptions, "Internet protocol is nil")
        guard let ipOptions else {
            return
        }

        XCTAssertTrue(
            ipOptions.matches(definition: IPProtocol.definition),
            "Invalid protocol definition on internet protocol"
        )

        ipOptions.modifyPerProtocolOptions { $0.version = .v6 }
        ipOptions.modifyPerProtocolOptions { $0.hopLimit = 10 }
        XCTAssertEqual(ipOptions.perProtocolOptions?.hopLimit, 10, "Failed to set hop limit")
        XCTAssertEqual(ipOptions.perProtocolOptions?.version, .v6, "Failed to set version")

        let ipOptionsFromStack = stack.internet?.options as! ProtocolOptions<IPProtocol>
        XCTAssertEqual(ipOptionsFromStack.perProtocolOptions?.hopLimit, 10, "Failed to get hop limit in protocol stack")
        XCTAssertEqual(ipOptionsFromStack.perProtocolOptions?.version, .v6, "Failed to get version in protocol stack")

        let stackCopy = ProtocolStack(deepCopy: stack)
        let ipOptionsFromCopy = stackCopy.internet?.options as! ProtocolOptions<IPProtocol>
        XCTAssertEqual(
            ipOptionsFromCopy.perProtocolOptions?.hopLimit,
            10,
            "Failed to get hop limit in protocol stack copy"
        )
        XCTAssertEqual(
            ipOptionsFromCopy.perProtocolOptions?.version,
            .v6,
            "Failed to get version in protocol stack copy"
        )
    }

    func testUDPOptionsInStack() {
        let stack = ProtocolStack()

        let udpOptions = UDPProtocol.definition.protocolOptions()
        udpOptions.modifyPerProtocolOptions { $0.formUnion(.noMetadata) }
        stack.transport = .udp(udpOptions)

        let _ = ProtocolStack(deepCopy: stack)
        let transportOptions = stack.transport?.options
        XCTAssertNotNil(transportOptions, "Transport protocol is nil")

        XCTAssertTrue(
            transportOptions!.matches(definition: UDPProtocol.definition),
            "Invalid protocol definition on transport protocol"
        )
        let udpOptionsFromStack = transportOptions as! ProtocolOptions<UDPProtocol>
        XCTAssertTrue(
            udpOptionsFromStack.perProtocolOptions!.contains(.noMetadata),
            "Failed to get noMetadata in protocol stack copy"
        )
    }
}
