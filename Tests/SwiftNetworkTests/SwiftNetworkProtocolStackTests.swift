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
    // A copy of QUIC options must keep every connection setting; otherwise a copied listener or accepted connection
    // silently runs with defaults.
    func testQUICOptionsCopyKeepsConnectionSettings() {
        let quicOptions = QUICProtocol.options()
        quicOptions.modifyConnectionOptions { $0.maximumConcurrentBidirectionalStreams = 5 }
        quicOptions.modifyConnectionOptions { $0.maximumConcurrentUnidirectionalStreams = 7 }
        quicOptions.modifyConnectionOptions { $0.maxPathsPerInterface = 3 }

        let copy = quicOptions.deepCopy()
        XCTAssertEqual(copy.connectionOptions.maximumConcurrentBidirectionalStreams, 5)
        XCTAssertEqual(copy.connectionOptions.maximumConcurrentUnidirectionalStreams, 7)
        XCTAssertEqual(copy.connectionOptions.maxPathsPerInterface, 3)
    }

    // Changes made through the shared connection options must reach the stream options they came from, since callers
    // configure QUIC that way. A deep copy must not share them.
    func testSharedQUICConnectionOptionsChangeOnlyTheirStreamOptions() {
        let quicOptions = QUICProtocol.options()
        let sharedConnectionOptions = quicOptions.perProtocolOptions!.copySharedConnectionOptions()
        sharedConnectionOptions.modifyPerProtocolOptions { $0.idleTimeout = .seconds(5) }
        XCTAssertEqual(quicOptions.connectionOptions.idleTimeout, .seconds(5))

        let copy = quicOptions.deepCopy()
        let copiedConnectionOptions = copy.perProtocolOptions!.copySharedConnectionOptions()
        copiedConnectionOptions.modifyPerProtocolOptions { $0.idleTimeout = .seconds(9) }
        XCTAssertEqual(copy.connectionOptions.idleTimeout, .seconds(9))
        XCTAssertEqual(quicOptions.connectionOptions.idleTimeout, .seconds(5))
    }

    // QUIC options built from the same stream options must keep their own stream settings but share the connection
    // configuration; otherwise a stream setting leaks into another stream, or a connection setting reaches only one
    // of its streams.
    func testQUICOptionsCopySharesOnlyTheConnectionConfiguration() {
        let quicOptions = QUICProtocol.options()
        let sharingOptions = ProtocolOptions<QUICProtocol>(
            protocolIdentifier: quicOptions.identifier,
            perProtocolOptions: quicOptions.perProtocolOptions
        )

        sharingOptions.modifyPerProtocolOptions { $0.associatedStreamID = 8 }
        XCTAssertEqual(sharingOptions.perProtocolOptions?.associatedStreamID, 8)
        XCTAssertNil(quicOptions.perProtocolOptions?.associatedStreamID)

        sharingOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(5) }
        XCTAssertEqual(quicOptions.connectionOptions.idleTimeout, .seconds(5))
    }
}
