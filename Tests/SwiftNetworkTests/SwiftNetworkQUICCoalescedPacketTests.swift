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

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
final class SwiftNetworkQUICCoalescedPacketTests: NetTestCase {

    var serverSigningKey = P256.Signing.PrivateKey()
    func createQUICTestOptions(server: Bool = false) -> ProtocolOptions<QUICProtocol> {
        var tlsOptions = SwiftTLSProtocol.Options()
        tlsOptions.applicationProtocols = ["network_test"]
        tlsOptions.serverName = "quic-test.local"
        if server {
            tlsOptions.rawPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        } else {
            tlsOptions.trustedRawPublicKeyCertificates = [[UInt8](serverSigningKey.publicKey.derRepresentation)]
        }

        let quicOptions = QUICStreamProtocol.options()
        quicOptions.tlsOptions = tlsOptions

        return quicOptions
    }

    // Completes a handshake by carrying every datagram between the two stacks by hand, then
    // delivers a single datagram made of an Initial packet followed by a packet that carries
    // `payload`. Both ends discard their Initial keys during the handshake, so the receiver
    // cannot decrypt the first packet. Returns what the receiving stream read.
    func readAfterUndecryptablePacket(fromClient: Bool, payload: [UInt8]) -> [UInt8]? {
        let clientEndpoint = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let serverEndpoint = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)

        let clientParameters = Parameters()
        let context = clientParameters.context
        let storage = TestNetworkProtocolStorage(context: context)

        var clientConnected = false
        var serverConnected = false
        var readData: [UInt8]?

        let expectation = XCTestExpectation()
        context.async {
            defer { expectation.fulfill() }

            let clientPath = PathProperties(parameters: clientParameters)
            let (clientQUICStreamListener, _, clientQUICMultipath) = storage.createTestQUICInstance()

            let clientQUICOptions = self.createQUICTestOptions()
            clientQUICOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientQUICOptions.setProtocolInstance(clientQUICStreamListener.identifier)

            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let (clientUpperHarness, clientUpperHarnessLinkage) = storage.createStreamUpperHarness(
                identifier: "Client",
                local: clientEndpoint,
                remote: serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: context
            )
            let (clientLowerHarness, clientLowerHarnessLinkage) = storage.createDatagramLowerHarness(
                identifier: "Client",
                context: context
            )

            var serverParameters = Parameters()
            serverParameters.isServer = true
            let serverPath = PathProperties(parameters: serverParameters)
            let (serverQUICStreamListener, _, serverQUICMultipath) = storage.createTestQUICInstance()

            let serverQUICOptions = self.createQUICTestOptions(server: true)
            serverQUICOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverQUICOptions.setProtocolInstance(serverQUICStreamListener.identifier)

            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))

            let (serverUpperHarness, serverUpperHarnessLinkage) = storage.createNewStreamFlowHarness(
                identifier: "Server",
                local: serverEndpoint,
                remote: clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: context
            )
            let (serverLowerHarness, serverLowerHarnessLinkage) = storage.createDatagramLowerHarness(
                identifier: "Server",
                context: context
            )

            defer {
                clientUpperHarness.stop()
                serverUpperHarness.stop()

                clientUpperHarness.teardown()
                serverUpperHarness.teardown()
                storage.releaseHeldInstances()
            }

            do {
                try clientQUICStreamListener.invokeAttachUpperProtocolToNewFlow(
                    clientUpperHarnessLinkage,
                    remote: serverEndpoint,
                    local: clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
                var clientQUICMultipath = clientQUICMultipath
                try clientQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    clientLowerHarnessLinkage,
                    remote: serverEndpoint,
                    local: clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
                // Attach from the upper linkage so both directions are bound.
                try serverUpperHarnessLinkage.invokeAttachLowerProtocol(
                    serverQUICStreamListener,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
                var serverQUICMultipath = serverQUICMultipath
                try serverQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    serverLowerHarnessLinkage,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach stacks: \(error)")
                return
            }

            serverUpperHarness.start { connected in serverConnected = connected }
            clientUpperHarness.start { connected in clientConnected = connected }

            // Datagrams from the end that will send the coalesced datagram, kept to reuse one below.
            var sentDatagrams: [[UInt8]] = []
            func transferPackets() {
                for _ in 0..<50 {
                    var transferred = 0
                    while let datagram = clientLowerHarness.extractLastOutboundPacket() {
                        if fromClient { sentDatagrams.append(datagram) }
                        serverLowerHarness.setNextInboundPacket(datagram)
                        transferred += 1
                    }
                    while let datagram = serverLowerHarness.extractLastOutboundPacket() {
                        if !fromClient { sentDatagrams.append(datagram) }
                        clientLowerHarness.setNextInboundPacket(datagram)
                        transferred += 1
                    }
                    if transferred == 0 {
                        break
                    }
                }
            }
            transferPackets()
            guard clientConnected, serverConnected else {
                return
            }

            // A long header (0x80) with packet type Initial (0x30 clear). Initial packets are padded
            // inside the packet, so the whole datagram is exactly one packet.
            guard let initialPacket = sentDatagrams.last(where: { $0[0] & 0xb0 == 0x80 }) else {
                XCTFail("No Initial packet was sent")
                return
            }

            if fromClient {
                _ = clientUpperHarness.write(payload)
            } else {
                // The server can only write once the client has opened the stream.
                _ = clientUpperHarness.write([0])
                transferPackets()
                guard let serverStream = serverUpperHarness.upperHarnesses.first, serverStream.read() != nil else {
                    XCTFail("Server did not receive the stream")
                    return
                }
                _ = serverStream.write(payload)
            }

            let senderLowerHarness = fromClient ? clientLowerHarness : serverLowerHarness
            let receiverLowerHarness = fromClient ? serverLowerHarness : clientLowerHarness
            while let datagram = senderLowerHarness.extractLastOutboundPacket() {
                receiverLowerHarness.setNextInboundPacket(initialPacket + datagram)
            }

            readData =
                fromClient ? serverUpperHarness.upperHarnesses.first?.read() : clientUpperHarness.read()
        }
        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(clientConnected, "QUIC stack client wasn't connected")
        XCTAssertTrue(serverConnected, "QUIC stack server wasn't connected")
        return readData
    }

    func testServerProcessesPacketAfterUndecryptablePacket() {
        let payload: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(readAfterUndecryptablePacket(fromClient: true, payload: payload), payload)
    }

    func testClientProcessesPacketAfterUndecryptablePacket() {
        let payload: [UInt8] = [1, 2, 3, 4]
        XCTAssertEqual(readAfterUndecryptablePacket(fromClient: false, payload: payload), payload)
    }
}
#endif
#endif

#endif
