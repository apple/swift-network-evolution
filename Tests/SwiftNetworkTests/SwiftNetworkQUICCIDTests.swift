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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if IMPORT_SWIFTTLS
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
// Uses cross module API for testing
@available(Network 0.1.0, *)
final class SwiftNetworkQUICCIDTests: NetTestCase {

    func testQUICRetiredOutboundConnectionIDIncludesStatelessResetToken() {
        var newOutboundConnectionID: QUICConnectionID?
        var newOutboundStatelessResetToken: QUICStatelessResetToken?
        var expectedNewStatelessResetToken: QUICStatelessResetToken?

        var retiredConnectionID: QUICConnectionID?
        var retiredStatelessResetToken: QUICStatelessResetToken?
        var expectedConnectionID: QUICConnectionID?
        var expectedStatelessResetToken: QUICStatelessResetToken?

        QUICTestHarness().runQUICTest(
            afterHandshake: { harness in
                harness.onContext {
                    guard let clientInstance = harness.state?.clientInstance,
                        let clientHarness = harness.state?.clientHarness,
                        let dcid = clientInstance.currentPath?.dcid
                    else {
                        XCTFail("State needs to be present to proceed")
                        return
                    }

                    // The server announces additional CIDs to the client right after the handshake,
                    // so the client harness should have a cid count here
                    XCTAssertGreaterThan(
                        clientHarness.newOutboundCIDEventCount,
                        0,
                        "Client should have received at least one new outbound connection ID"
                    )
                    newOutboundConnectionID = clientHarness.lastNewOutboundConnectionID
                    newOutboundStatelessResetToken = clientHarness.lastNewOutboundStatelessResetToken
                    if let newOutboundConnectionID {
                        expectedNewStatelessResetToken =
                            clientInstance.remoteCIDs.find(
                                connectionID: newOutboundConnectionID
                            )?.token
                    }
                    XCTAssertNotNil(
                        expectedNewStatelessResetToken,
                        "Connection ID should have an associated stateless reset token"
                    )

                    expectedConnectionID = dcid
                    expectedStatelessResetToken = clientInstance.remoteCIDs.find(connectionID: dcid)?.token
                    XCTAssertNotNil(
                        expectedStatelessResetToken,
                        "The server's connection ID should have an associated stateless reset token"
                    )

                    clientHarness.invokeApplicationEvent(.init(quicEvent: .retireOutboundConnectionID(dcid)))

                    XCTAssertEqual(clientHarness.retiredOutboundCIDEventCount, 1)
                    retiredConnectionID = clientHarness.lastRetiredOutboundConnectionID
                    retiredStatelessResetToken = clientHarness.lastRetiredOutboundStatelessResetToken
                }
            }
        )

        XCTAssertNotNil(newOutboundStatelessResetToken)
        XCTAssertEqual(newOutboundStatelessResetToken, expectedNewStatelessResetToken)

        XCTAssertEqual(retiredConnectionID, expectedConnectionID)
        XCTAssertNotNil(retiredStatelessResetToken)
        XCTAssertEqual(retiredStatelessResetToken, expectedStatelessResetToken)
    }

    func testQUICStatelessResetWithTokenForLaterConnectionID() {
        // The server issues a second connection ID in a NEW_CONNECTION_ID frame, with its own
        // stateless reset token. Once the client has moved over to that connection ID, a stateless
        // reset ending in its token closes the connection. RFC 9000 §10.3.1 only allows checking
        // tokens of connection IDs that have been used, so the client switches before the reset.
        let initialToken = QUICStatelessResetToken(
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        )!
        let laterToken = QUICStatelessResetToken(
            [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0]
        )!
        let laterConnectionID = QUICConnectionID(10)

        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.initialSourceConnectionID = QUICConnectionID(10) }
        serverOptions.modifyConnectionOptions { $0.initialStatelessResetToken = initialToken }
        // Only the connection ID below is issued, so it is the one the client switches to.
        serverOptions.modifyConnectionOptions { $0.disableAutomaticNewConnectionIDs = true }

        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            extraServerCIDs: [(laterConnectionID, laterToken)],
            afterHandshake: { harness in
                harness.wait(
                    until: { harness.state?.clientInstance.remoteCIDs.find(connectionID: laterConnectionID) != nil },
                    timeout: 5.0,
                    "client to receive the NEW_CONNECTION_ID frame"
                )

                var reportedError: NetworkError?
                harness.onContext {
                    guard let clientInstance = harness.state?.clientInstance,
                        let clientHarness = harness.state?.clientHarness,
                        let currentPath = clientInstance.currentPath
                    else {
                        XCTFail("State needs to be present to proceed")
                        return
                    }
                    XCTAssertEqual(
                        clientInstance.remoteCIDs.find(connectionID: laterConnectionID)?.token,
                        laterToken,
                        "The NEW_CONNECTION_ID token should be stored with its connection ID"
                    )

                    let switched = clientInstance.fromExternal { eventContext in
                        clientInstance.assignNewDCID(to: currentPath, in: &eventContext)
                    }
                    XCTAssertTrue(switched, "Client should switch to the new connection ID")
                    XCTAssertEqual(currentPath.dcid, laterConnectionID)
                    XCTAssertEqual(clientInstance.remoteCIDs.find(connectionID: laterConnectionID)?.used, true)

                    clientHarness.waitForError { error in
                        reportedError = error
                    }
                    let statelessResetPacket = try! QUICConnectionUtilities.createStatelessResetPacket(
                        token: laterToken,
                        triggeringPacketLength: 35
                    )
                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        .init(copyBuffer: statelessResetPacket),
                        to: harness.clientPort
                    )
                }
                harness.wait(until: { reportedError != nil }, timeout: 5.0, "client to report the reset")
                XCTAssertEqual(reportedError, NetworkError.posix(ECONNRESET))
            }
        )
    }

    func testQUICStatelessResetWithTokenForUnusedConnectionIDIsIgnored() {
        // The server issues a second connection ID in a NEW_CONNECTION_ID frame, but the client
        // keeps using the first one. RFC 9000 §10.3.1 forbids checking the tokens of connection IDs
        // that haven't been used, so a stateless reset ending in the second token must be dropped,
        // and the echo that runQUICTest does afterwards has to complete.
        let initialToken = QUICStatelessResetToken(
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        )!
        let unusedToken = QUICStatelessResetToken(
            [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB0]
        )!
        let unusedConnectionID = QUICConnectionID(10)

        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.initialSourceConnectionID = QUICConnectionID(10) }
        serverOptions.modifyConnectionOptions { $0.initialStatelessResetToken = initialToken }
        serverOptions.modifyConnectionOptions { $0.disableAutomaticNewConnectionIDs = true }

        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            serverOptions: serverOptions,
            extraServerCIDs: [(unusedConnectionID, unusedToken)],
            afterHandshake: { harness in
                harness.wait(
                    until: { harness.state?.clientInstance.remoteCIDs.find(connectionID: unusedConnectionID) != nil },
                    timeout: 5.0,
                    "client to receive the NEW_CONNECTION_ID frame"
                )

                var reportedError: NetworkError?
                harness.onContext {
                    guard let clientInstance = harness.state?.clientInstance,
                        let clientHarness = harness.state?.clientHarness
                    else {
                        XCTFail("State needs to be present to proceed")
                        return
                    }
                    let unusedCID = clientInstance.remoteCIDs.find(connectionID: unusedConnectionID)
                    XCTAssertEqual(unusedCID?.token, unusedToken)
                    XCTAssertEqual(unusedCID?.used, false, "The client must not have switched to the new connection ID")
                    XCTAssertNotEqual(clientInstance.currentPath?.dcid, unusedConnectionID)

                    clientHarness.waitForError { error in
                        reportedError = error
                    }
                    let statelessResetPacket = try! QUICConnectionUtilities.createStatelessResetPacket(
                        token: unusedToken,
                        triggeringPacketLength: 35
                    )
                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        .init(copyBuffer: statelessResetPacket),
                        to: harness.clientPort
                    )
                }
                // Give a wrongly accepted reset time to surface as an error.
                harness.allow(.milliseconds(100))
                harness.onContext {
                    XCTAssertEqual(harness.state?.clientInstance.state, .connected)
                    XCTAssertNil(harness.state?.clientInstance.closeError)
                }
                XCTAssertNil(reportedError, "A reset with the token of an unused connection ID must be ignored")
            }
        )
    }

}
#endif
#endif
#endif
