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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)

@available(Network 0.1.0, *)
final class SwiftNetworkQUICPacketParsingTests: NetTestCase {

    func testMalformedInitial() throws {
        let harness = QUICTestHarness()

        // Attach a server-side QUIC stack to the bridge, mirroring the
        // server half of `QUICTestHarness.quicHandshake`, but never start
        // the client: the server connection stays in `.idle`, exactly as a
        // listening server is before any handshake.
        let server = try attachIdleServer(harness)
        defer {
            let teardownExpectation = XCTestExpectation(description: "Server harness torn down")
            harness.context.async {
                server.harness.stop()
                server.harness.teardown()
                harness.storage.releaseHeldInstances()
                teardownExpectation.fulfill()
            }
            wait(for: [teardownExpectation], timeout: 5.0)
        }

        XCTAssertEqual(
            server.instance.state,
            .idle,
            "Server connection must still be idle before the injection"
        )

        // 21-byte Initial: long header (0x80) | fixed bit (0x40) | type 0.
        // Version 1, zero-length DCID and SCID, zero-length token,
        // 1-byte payload-length varint claiming the remaining 12 bytes.
        // headerLength == 9, so sampleRange == 13..<29 in a 21-byte buffer.
        var datagram: [UInt8] = [
            0xC0,  // long header | fixed bit | Initial
            0x00, 0x00, 0x00, 0x01,  // version 1
            0x00,  // DCID length
            0x00,  // SCID length
            0x00,  // token length (varint)
            0x0C,  // payload length (varint) — 12 remaining bytes
        ]
        datagram.append(contentsOf: [UInt8](repeating: 0x41, count: 12))
        XCTAssertEqual(datagram.count, Constants.minimumPacketSize)

        let injectExpectation = XCTestExpectation(description: "Malformed Initial injected")
        harness.context.async {
            BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                Frame(copyBuffer: datagram),
                to: harness.serverPort
            )
            injectExpectation.fulfill()
        }
        wait(for: [injectExpectation], timeout: 5.0)

        let processedExpectation = XCTestExpectation(
            description: "Wait for server to process the injected datagram"
        )
        _ = XCTWaiter.wait(for: [processedExpectation], timeout: 1.0)
        Logger.test.info(
            "Server connection state after malformed Initial: \(server.instance.state)"
        )
    }

    func testMalformedShortHeaderAfterHandshake() throws {
        let harness = QUICTestHarness()
        harness.runQUICTest(
            afterHandshake: { harness in
                let injectExpectation = XCTestExpectation(
                    description: "Malformed short-header datagram injected"
                )

                harness.context.async {
                    guard let serverInstance = harness.state?.serverInstance else {
                        XCTFail("Server instance missing after handshake")
                        injectExpectation.fulfill()
                        return
                    }

                    // The CID the peer uses to address the server. The
                    // initial SCID (inserted first) is the one the client
                    // keeps using absent migration.
                    guard
                        let serverCID = serverInstance.localCIDs.managedConnectionIDs.first?
                            .connectionID.connectionID
                    else {
                        XCTFail("Server has no local connection IDs")
                        injectExpectation.fulfill()
                        return
                    }
                    XCTAssertEqual(
                        serverCID.count,
                        QUICConnectionID.defaultServerSCIDLength,
                        "Server local CID should have the default length (8)"
                    )

                    // 21-byte short header: fixed bit set, 5-bit spin/keys
                    // unused bits zero. headerLength == 1 + 8 == 9, so
                    // sampleRange == 13..<29 in a 21-byte buffer.
                    var datagram: [UInt8] = [0x40]
                    datagram.append(contentsOf: serverCID)
                    datagram.append(contentsOf: [UInt8](repeating: 0x42, count: 12))
                    XCTAssertEqual(datagram.count, Constants.minimumPacketSize)

                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        Frame(copyBuffer: datagram),
                        to: harness.serverPort
                    )
                    injectExpectation.fulfill()
                }
                self.wait(for: [injectExpectation], timeout: 5.0)

                let processedExpectation = XCTestExpectation(
                    description: "Wait for server to process the injected datagram"
                )
                _ = XCTWaiter.wait(for: [processedExpectation], timeout: 1.0)

                XCTAssertEqual(
                    harness.state?.serverInstance.state,
                    .connected,
                    "Server connection must survive a truncated short-header datagram"
                )
            }
        )
    }

    func testMalformedShortHeaderInsufficientPacketNumberAndSampleBytes() throws {
        let harness = QUICTestHarness()
        harness.runQUICTest(
            afterHandshake: { harness in
                let injectExpectation = XCTestExpectation(
                    description: "Malformed short-header datagram injected"
                )

                harness.context.async {
                    guard let serverInstance = harness.state?.serverInstance else {
                        XCTFail("Server instance missing after handshake")
                        injectExpectation.fulfill()
                        return
                    }

                    // The CID the peer uses to address the server. The
                    // initial SCID (inserted first) is the one the client
                    // keeps using absent migration.
                    guard
                        let serverCID = serverInstance.localCIDs.managedConnectionIDs.first?
                            .connectionID.connectionID
                    else {
                        XCTFail("Server has no local connection IDs")
                        injectExpectation.fulfill()
                        return
                    }
                    XCTAssertEqual(
                        serverCID.count,
                        QUICConnectionID.defaultServerSCIDLength,
                        "Server local CID should have the default length (8)"
                    )
                    // 25-byte short header: fixed bit set, headerLength ==
                    // 1 + 8 == 9, leaving 16 bytes of payload+tag. It clears the
                    // payloadAndTagSize check but falls short
                    // of the 4 byte packet number plus 16-byte header
                    // protection sample the parser needs before it can
                    // safely remove header protection.
                    var datagram: [UInt8] = [0x40]
                    datagram.append(contentsOf: serverCID)
                    datagram.append(contentsOf: [UInt8](repeating: 0x42, count: 16))
                    XCTAssertEqual(datagram.count, 25)

                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        Frame(copyBuffer: datagram),
                        to: harness.serverPort
                    )
                    injectExpectation.fulfill()
                }
                self.wait(for: [injectExpectation], timeout: 5.0)

                let processedExpectation = XCTestExpectation(
                    description: "Wait for server to process the injected datagram"
                )
                _ = XCTWaiter.wait(for: [processedExpectation], timeout: 1.0)

                XCTAssertEqual(
                    harness.state?.serverInstance.state,
                    .connected,
                    "Server connection must survive a short-header datagram with insufficient bytes for the packet number and sample"
                )
            }
        )
    }

    // MARK: - Helpers

    private struct IdleServer {
        let instance: QUICConnection
        let harness: NewStreamFlowHarness<TestStreamLinkageFamily>
    }

    private func attachIdleServer(_ harness: QUICTestHarness) throws -> IdleServer {
        let attachExpectation = XCTestExpectation(description: "Idle server stack attached")
        var result: IdleServer?

        harness.context.async {
            var serverParameters = Parameters()
            serverParameters.context = harness.context
            serverParameters.isServer = true

            var (serverQUICStreamListener, _, serverQUICMultipath) = harness.storage.createTestQUICInstance()
            guard let serverInstance = harness.storage.quicInstance(for: serverQUICStreamListener.base) else {
                XCTFail("Failed to create the server QUIC instance")
                attachExpectation.fulfill()
                return
            }

            let serverOptions = QUICProtocol.options()
            harness.updateQUICOptions(serverOptions, server: true)
            serverOptions.setLogID(
                prefix: "L",
                parent: "1",
                protocolLogIDNumber: 1
            )
            serverOptions.setProtocolInstance(serverQUICStreamListener.identifier)
            serverParameters.defaultStack.transport = .quic(serverOptions)

            let serverBridge = harness.storage.createTestBridgeDatagramInstance()
            let serverBridgeOptions = BridgeDatagramProtocol.options()
            serverBridgeOptions.setProtocolInstance(serverBridge.identifier)
            serverParameters.defaultStack.link = .custom(serverBridgeOptions)

            var serverPath = PathProperties(parameters: serverParameters)
            serverPath.effectiveMTU = 1500

            let (serverFlowHarness, serverHarnessLinkage) = harness.storage.createNewStreamFlowHarness(
                identifier: "Server",
                local: harness.serverEndpoint,
                remote: harness.clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: harness.context
            )

            do {
                // Attach from the upper linkage so both directions are bound.
                try serverHarnessLinkage.invokeAttachLowerProtocol(
                    serverQUICStreamListener,
                    remote: harness.clientEndpoint,
                    local: harness.serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach the server harness to QUIC: \(error)")
                attachExpectation.fulfill()
                return
            }

            do {
                try serverQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    serverBridge,
                    remote: harness.clientEndpoint,
                    local: harness.serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach QUIC server to datagram bridge: \(error)")
                attachExpectation.fulfill()
                return
            }

            result = IdleServer(instance: serverInstance, harness: serverFlowHarness)

            // Begin listening, exactly as `quicHandshake` does before the
            // client sends anything. A server-side connect only activates
            // the receive path; it does not initiate a handshake, so the
            // connection stays in `.idle`.
            serverFlowHarness.start()

            attachExpectation.fulfill()
        }
        wait(for: [attachExpectation], timeout: 5.0)

        guard let result else {
            XCTFail("Failed to attach the idle server")
            struct AttachError: Error {}
            throw AttachError()
        }
        return result
    }
}
#endif
#endif
#endif
