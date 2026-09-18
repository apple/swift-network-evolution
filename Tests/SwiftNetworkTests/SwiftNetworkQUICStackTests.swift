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

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

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
final class SwiftNetworkQUICStackTests: NetTestCase {

    // 10.0.0.20
    static let localIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x14]

    // 10.0.0.117
    static let remoteIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x75]

    // fd5a:3a11:d884:7340:78:60e4:d854:8595
    static let localIPv6Address: [UInt8] = [
        0xfd, 0x5a, 0x3a, 0x11, 0xd8, 0x84, 0x73, 0x40, 0x00, 0x78, 0x60, 0xe4, 0xd8, 0x54, 0x85, 0x95,
    ]

    // fd5a:3a11:d884:7340:8a7:8ada:1c36:6864
    static let remoteIPv6Address: [UInt8] = [
        0xfd, 0x5a, 0x3a, 0x11, 0xd8, 0x84, 0x73, 0x40, 0x08, 0xa7, 0x8a, 0xda, 0x1c, 0x36, 0x68, 0x64,
    ]

    var clientSigningKey = P256.Signing.PrivateKey()
    var serverSigningKey = P256.Signing.PrivateKey()
    func createQUICTestOptions(
        server: Bool = false,
        mutualAuthentication: Bool = false,
        sourceConnectionIDLength: Int = 0
    ) -> ProtocolOptions<QUICProtocol> {
        var tlsOptions = SwiftTLSProtocol.Options()
        tlsOptions.applicationProtocols = ["network_test"]
        tlsOptions.serverName = "quic-test.local"
        if server {
            if mutualAuthentication {
                tlsOptions.trustedRawPublicKeyCertificates = [[UInt8](clientSigningKey.publicKey.derRepresentation)]
            }
            tlsOptions.rawPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        } else {
            if mutualAuthentication {
                tlsOptions.rawPrivateKey = [UInt8](clientSigningKey.rawRepresentation)
            }
            tlsOptions.trustedRawPublicKeyCertificates = [[UInt8](serverSigningKey.publicKey.derRepresentation)]
        }

        let quicOptions = QUICStreamProtocol.options()
        quicOptions.tlsOptions = tlsOptions

        if sourceConnectionIDLength > 0 {
            quicOptions.connectionOptions.sourceConnectionIDLength = sourceConnectionIDLength
        }

        return quicOptions
    }

    func transferPackets(
        sender: DatagramLowerHarness<TestDatagramLinkageFamily>,
        receiver: DatagramLowerHarness<TestDatagramLinkageFamily>,
        maximumBurst: Int
    ) -> Int {
        var packetsSent: Int = 0
        for _ in 0..<maximumBurst {  // limit burst amount
            if let outboundPacket = sender.extractLastOutboundPacket() {
                receiver.setNextInboundPacket(outboundPacket)
                packetsSent += 1
            } else {
                break
            }
        }
        return packetsSent
    }

    struct PairedUDPIPPaths {
        var client: DatagramLowerHarness<TestDatagramLinkageFamily>
        var server: DatagramLowerHarness<TestDatagramLinkageFamily>

        var clientTop: TestDatagramLinkageFamily.Lower
        var serverTop: TestDatagramLinkageFamily.Lower

        init(
            context: NetworkContext,
            storage: TestNetworkProtocolStorage,
            identifier: String,
            clientEndpoint: Endpoint,
            serverEndpoint: Endpoint,
            maximumDatagramSize: Int = 1500
        ) {
            let (clientUDPUpper, clientUDPLower) = storage.createTestUDPInstance()
            clientTop = clientUDPLower

            let clientUDPOptions = UDPProtocol.options()
            clientUDPOptions.noMetadata = true
            clientUDPOptions.setLogID(prefix: "C", parent: identifier, protocolLogIDNumber: 2)
            clientUDPOptions.setProtocolInstance(clientUDPLower.identifier)

            let (clientIPUpper, clientIPLower) = storage.createTestIPInstance()

            let clientIPOptions = IPProtocol.options()
            clientIPOptions.setLogID(prefix: "C", parent: identifier, protocolLogIDNumber: 3)
            clientIPOptions.setProtocolInstance(clientIPLower.identifier)

            let (serverUDPUpper, serverUDPLower) = storage.createTestUDPInstance()

            serverTop = serverUDPLower
            let serverUDPOptions = UDPProtocol.options()
            serverUDPOptions.noMetadata = true
            serverUDPOptions.setLogID(prefix: "L", parent: identifier, protocolLogIDNumber: 2)
            serverUDPOptions.setProtocolInstance(serverUDPLower.identifier)

            let (serverIPUpper, serverIPLower) = storage.createTestIPInstance()

            let serverIPOptions = IPProtocol.options()
            serverIPOptions.setLogID(prefix: "L", parent: identifier, protocolLogIDNumber: 3)
            serverIPOptions.setProtocolInstance(serverIPLower.identifier)

            var clientParameters = Parameters()
            clientParameters.context = context

            var serverParameters = Parameters()
            serverParameters.context = context

            let clientPath = PathProperties(parameters: clientParameters)
            let serverPath = PathProperties(parameters: serverParameters)

            clientParameters.defaultStack.transport = .udp(clientUDPOptions)
            clientParameters.defaultStack.internet = .ip(clientIPOptions)

            serverParameters.defaultStack.transport = .udp(serverUDPOptions)
            serverParameters.defaultStack.internet = .ip(serverIPOptions)

            let (clientLowerHarness, clientLowerHarnessLinkage) = storage.createDatagramLowerHarness(
                identifier: "Client" + identifier,
                context: context)
            client = clientLowerHarness

            let (serverLowerHarness, serverLowerHarnessLinkage) = storage.createDatagramLowerHarness(
                identifier: "Server" + identifier,
                context: context)
            server = serverLowerHarness

            client.maximumOutputSize = maximumDatagramSize
            server.maximumOutputSize = maximumDatagramSize

            // Attach from the upper linkage so both directions are bound: the upper protocol's
            // `lower` is set, and `invokeAttachLowerProtocol` calls back into
            // `invokeAttachUpperProtocol` on the lower protocol.
            try! clientUDPUpper.invokeAttachLowerProtocol(clientIPLower,
                                                          remote: serverEndpoint,
                                                          local: clientEndpoint,
                                                          parameters: clientParameters,
                                                          path: clientPath)
            try! clientIPUpper.invokeAttachLowerProtocol(clientLowerHarnessLinkage,
                                                         remote: serverEndpoint,
                                                         local: clientEndpoint,
                                                         parameters: clientParameters,
                                                         path: clientPath)

            try! serverUDPUpper.invokeAttachLowerProtocol(serverIPLower,
                                                          remote: clientEndpoint,
                                                          local: serverEndpoint,
                                                          parameters: serverParameters,
                                                          path: serverPath)
            try! serverIPUpper.invokeAttachLowerProtocol(serverLowerHarnessLinkage,
                                                         remote: clientEndpoint,
                                                         local: serverEndpoint,
                                                         parameters: serverParameters,
                                                         path: serverPath)
        }

        private func transferPackets(
            sender: DatagramLowerHarness<TestDatagramLinkageFamily>,
            receiver: DatagramLowerHarness<TestDatagramLinkageFamily>,
            maximumBurst: Int
        ) -> Int {
            var packetsSent: Int = 0
            for _ in 0..<maximumBurst {
                if let outboundPacket = sender.extractLastOutboundPacket() {
                    receiver.setNextInboundPacket(outboundPacket)
                    packetsSent += 1
                } else {
                    break
                }
            }
            return packetsSent
        }

        func transferPackets(maximumBurst: Int = 10) -> Int {
            (transferPackets(sender: client, receiver: server, maximumBurst: maximumBurst)
                + transferPackets(sender: server, receiver: client, maximumBurst: maximumBurst))
        }
    }

    func quicStackHandshake(
        clientEndpoint: Endpoint,
        serverEndpoint: Endpoint,
        mutualAuthentication: Bool = false,
        migrateCount: Int = 0,
        dataToSend: [UInt8]? = nil
    ) {
        let clientParameters = Parameters()


        let expectation = XCTestExpectation()
        let context = clientParameters.context

        let storage = TestNetworkProtocolStorage(context: context)

        var clientConnected = false
        var serverConnected = false
        var clientUpperHarness: StreamUpperHarness<TestStreamLinkageFamily>?
        var serverUpperHarness: NewStreamFlowHarness<TestStreamLinkageFamily>?
        var clientQUICMultipathLinkage: TestDatagramMultipathLinkage?
        var serverQUICMultipathLinkage: TestDatagramMultipathLinkage?

        var pairedPathsArray = [PairedUDPIPPaths]()

        context.async {
            defer { expectation.fulfill() }

            let pairedPaths = PairedUDPIPPaths(
                context: context,
                storage: storage,
                identifier: "1",
                clientEndpoint: clientEndpoint,
                serverEndpoint: serverEndpoint
            )
            pairedPathsArray.append(pairedPaths)

            let clientPath = PathProperties(parameters: clientParameters)
            let (clientQUICStreamListener, _, clientQUICMultipath) = storage.createTestQUICInstance()
            clientQUICMultipathLinkage = clientQUICMultipath

            let clientQUICOptions: ProtocolOptions<QUICProtocol>
            if migrateCount > 0 {
                clientQUICOptions = self.createQUICTestOptions(
                    server: false,
                    mutualAuthentication: mutualAuthentication,
                    sourceConnectionIDLength: 8
                )
            } else {
                clientQUICOptions = self.createQUICTestOptions(
                    server: false,
                    mutualAuthentication: mutualAuthentication
                )
            }
            clientQUICOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientQUICOptions.setProtocolInstance(clientQUICStreamListener.identifier)

            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let (clientUpperHarnessInstance, clientUpperHarnessLinkage) = storage.createStreamUpperHarness(identifier: "Client", local: clientEndpoint, remote: serverEndpoint, parameters: clientParameters, path: clientPath, context: context)
            clientUpperHarness = clientUpperHarnessInstance
            XCTAssertNotNil(clientUpperHarness, "Failed to attach stack to client upper harness")
            guard let clientUpperHarness else {
                return
            }

            do {
                try clientQUICStreamListener.invokeAttachUpperProtocolToNewFlow(clientUpperHarnessLinkage, remote: serverEndpoint, local: clientEndpoint, parameters: clientParameters, path: clientPath)
            } catch {
                XCTAssertTrue(false, "Failed to attach client upper harness to QUIC")
            }

            do {
                                var clientQUICMultipath = clientQUICMultipath
                try clientQUICMultipath.invokeAttachLowerProtocolForNewPath(pairedPaths.clientTop, remote: serverEndpoint, local: clientEndpoint, parameters: clientParameters, path: clientPath)
            } catch {
                XCTAssertTrue(false, "Failed to attach client stack")
            }

            var serverParameters = Parameters()
            serverParameters.isServer = true
            let serverPath = PathProperties(parameters: serverParameters)
            let (serverQUICStreamListener, _, serverQUICMultipath) = storage.createTestQUICInstance()
            serverQUICMultipathLinkage = serverQUICMultipath

            let serverQUICOptions = self.createQUICTestOptions(
                server: true,
                mutualAuthentication: mutualAuthentication
            )
            serverQUICOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverQUICOptions.setProtocolInstance(serverQUICStreamListener.identifier)

            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))


            let (serverUpperHarnessInstance, serverUpperHarnessLinkage) = storage.createNewStreamFlowHarness(identifier: "Server", local: serverEndpoint, remote: clientEndpoint, parameters: serverParameters, path: serverPath, context: context)
            serverUpperHarness = serverUpperHarnessInstance
            XCTAssertNotNil(serverUpperHarness, "Failed to attach QUIC to server upper harness")
            guard let serverUpperHarness else {
                return
            }

            do {
                // Attach from the upper linkage so both directions are bound.
                try serverUpperHarnessLinkage.invokeAttachLowerProtocol(serverQUICStreamListener, remote: clientEndpoint, local: serverEndpoint, parameters: serverParameters, path: serverPath)
            } catch {
                XCTAssertTrue(false, "Failed to attach server upper harness to QUIC")
            }

            do {
                                var serverQUICMultipath = serverQUICMultipath
                try serverQUICMultipath.invokeAttachLowerProtocolForNewPath(pairedPaths.serverTop, remote: clientEndpoint, local: serverEndpoint, parameters: serverParameters, path: serverPath)
            } catch {
                XCTAssertTrue(false, "Failed to attach server stack")
            }

            serverUpperHarness.start { connected in
                serverConnected = true
                XCTAssertTrue(connected, "QUIC stack server failed to become connected")
                expectation.fulfill()
            }

            clientUpperHarness.start { connected in
                clientConnected = true
                XCTAssertTrue(connected, "QUIC stack client failed to become connected")
            }

            while !serverConnected {
                if pairedPaths.transferPackets() == 0 {
                    break
                }
            }
        }

        wait(for: [expectation], timeout: 10.0)
        XCTAssertTrue(clientConnected, "QUIC stack client wasn't connected")
        XCTAssertTrue(serverConnected, "QUIC stack server wasn't connected")

        XCTAssertNotNil(clientQUICMultipathLinkage)
        XCTAssertNotNil(serverQUICMultipathLinkage)
        guard let clientQUICMultipathLinkage, let serverQUICMultipathLinkage else {
            return
        }

        let eventExpectation = XCTestExpectation()
        context.async {
            clientUpperHarness?.invokeConnectionIdleEvent()
            clientUpperHarness?.invokeConnectionReusedEvent()
            pairedPathsArray.first?.client.deliverViableEvent()
            eventExpectation.fulfill()
        }
        wait(for: [eventExpectation], timeout: 5.0)

        if let dataToSend {
            let receiveExpectation = XCTestExpectation()
            context.async {
                Logger.test.info("Writing data to send")
                _ = clientUpperHarness?.write(dataToSend)
                for _ in 0..<10 {
                    if pairedPathsArray.first?.transferPackets() == 0 {
                        break
                    }
                    if let readData = serverUpperHarness?.upperHarnesses.first?.read() {
                        XCTAssertEqual(readData, dataToSend)
                        receiveExpectation.fulfill()
                    }
                }
            }
            wait(for: [receiveExpectation], timeout: 5.0)
        }

        for index in 0..<migrateCount {
            let migrationExpectation = XCTestExpectation()
            context.async {
                let pathIndex = 2 + index
                Logger.test.info("Creating path \(pathIndex)")
                let pairedPaths = PairedUDPIPPaths(
                    context: context,
                    storage: storage,
                    identifier: "\(pathIndex)",
                    clientEndpoint: clientEndpoint,
                    serverEndpoint: serverEndpoint
                )
                pairedPathsArray.append(pairedPaths)
                do {
                    let clientParameters = Parameters()
                    let clientPath = PathProperties(parameters: Parameters())
                    let serverParameters = Parameters()
                    let severPath = PathProperties(parameters: Parameters())

                                        var clientQUICMultipathLinkage = clientQUICMultipathLinkage
                    try clientQUICMultipathLinkage.invokeAttachLowerProtocolForNewPath(
                        pairedPaths.clientTop,
                        remote: serverEndpoint,
                        local: clientEndpoint,
                        parameters: clientParameters,
                        path: clientPath
                    )
                                        var serverQUICMultipathLinkage = serverQUICMultipathLinkage
                    try serverQUICMultipathLinkage.invokeAttachLowerProtocolForNewPath(
                        pairedPaths.serverTop,
                        remote: clientEndpoint,
                        local: serverEndpoint,
                        parameters: serverParameters,
                        path: severPath
                    )
                } catch {
                    XCTAssertTrue(false, "Failed to attach stacks to the new path")
                }

                // First, let the server know about the path
                pairedPaths.server.deliverPathIsNotPrimary()

                // Then, tell the client to switch to the path
                pairedPaths.client.deliverPathIsPrimary()

                for _ in 0..<2 {
                    if pairedPaths.transferPackets() == 0 {
                        break
                    }
                }

                // Currently we only keep the current path object and remove all the
                // other path objects we are migrating away from, so the number of
                // multiplexing paths should be one.
                if let clientConnection = storage.quicInstance(for: clientQUICMultipathLinkage.base) {
                    XCTAssertEqual(
                        clientConnection.multiplexingPaths.count,
                        1,
                        "Path leaked after migration \(pathIndex)"
                    )
                }

                if let dataToSend {
                    Logger.test.info("Writing data to send on path \(pathIndex)")
                    _ = clientUpperHarness?.write(dataToSend)
                    for _ in 0..<10 {
                        if pairedPaths.transferPackets() == 0 {
                            break
                        }
                        if let readData = serverUpperHarness?.upperHarnesses.first?.read() {
                            XCTAssertEqual(readData, dataToSend)
                            migrationExpectation.fulfill()
                        }
                    }
                } else {
                    migrationExpectation.fulfill()
                }
            }
            wait(for: [migrationExpectation], timeout: 5.0)
        }

        let stopExpectation = XCTestExpectation()
        context.async {
            clientUpperHarness?.stop()
            serverUpperHarness?.stop()

            clientUpperHarness?.teardown()
            serverUpperHarness?.teardown()
            stopExpectation.fulfill()
        }
        wait(for: [stopExpectation], timeout: 10.0)
    }

    func testQUICStackHandshakeIPv4() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server)
    }

    func testQUICStackHandshakeIPv6() {
        let ipv6Client = Endpoint(address: IPv6Address(SwiftNetworkQUICStackTests.localIPv6Address)!, port: 1234)
        let ipv6Server = Endpoint(address: IPv6Address(SwiftNetworkQUICStackTests.localIPv6Address)!, port: 8080)
        quicStackHandshake(clientEndpoint: ipv6Client, serverEndpoint: ipv6Server)
    }

    func testQUICStackHandshakeMutualAuthentication() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server, mutualAuthentication: true)
    }

    func testQUICStackHandshakeWithData() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8)
        )
    }

    func testQUICStackHandshakeMutualAuthenticationWithData() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            mutualAuthentication: true,
            dataToSend: Array("Hello World!".utf8)
        )
    }

    func testQUICStackHandshakeMigration() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server, migrateCount: 2)
    }

    func testQUICStackHandshakeMigrationWithData() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            migrateCount: 2,
            dataToSend: Array("Hello World!".utf8)
        )
    }

    func testQUICStackMigrationDoesNotLeakPaths() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            migrateCount: 4,
            dataToSend: Array("Hello World!".utf8)
        )
    }

    func testQUICPathEvents() {
        // 10.0.0.99 - new client address simulating the client switching network interfaces
        // So this test would be client initiated migration
        let newLocalIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x63]

        let clientEndpoint = Endpoint(
            address: IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!,
            port: 1234
        )
        let serverAddress = IPv4Address(SwiftNetworkQUICStackTests.localIPv4Address)!
        let serverPort: UInt16 = UInt16(8080)
        let serverEndpoint = Endpoint(
            address: serverAddress,
            port: serverPort
        )
        // The client gets a new source address; the server address stays fixed.
        let newClientAddress = IPv4Address(newLocalIPv4Address)!
        let newCLientPort = UInt16(4321)
        let newClientEndpoint = Endpoint(
            address: newClientAddress,
            port: newCLientPort
        )

        let clientParameters = Parameters()
        let context = clientParameters.context

        let handshakeExpectation = XCTestExpectation(description: "QUIC handshake complete")
        let pathChangedExpectation = XCTestExpectation(description: "pathChanged event received")
        let pathValidatedExpectation = XCTestExpectation(description: "pathValidated event received")

        let storage = TestNetworkProtocolStorage(context: context)

        var clientQUICMultipathLinkage: TestDatagramMultipathLinkage?
        var serverQUICMultipathLinkage: TestDatagramMultipathLinkage?
        var clientUpperHarness: StreamUpperHarness<TestStreamLinkageFamily>?
        var serverUpperHarness: NewStreamFlowHarness<TestStreamLinkageFamily>?
        var pairedPathsArray = [PairedUDPIPPaths]()

        var receivedPathChangedInfo: QUICPathInfo?
        var receivedPathValidatedInfo: QUICPathInfo?

        context.async {
            defer { handshakeExpectation.fulfill() }

            let initialPaths = PairedUDPIPPaths(
                context: context,
                storage: storage,
                identifier: "1",
                clientEndpoint: clientEndpoint,
                serverEndpoint: serverEndpoint
            )
            pairedPathsArray.append(initialPaths)

            let clientQUICOptions = self.createQUICTestOptions(
                server: false,
                sourceConnectionIDLength: 8
            )
            clientQUICOptions.setLogID(prefix: "C", parent: "pathEvents", protocolLogIDNumber: 1)
            let (clientQUICStreamListener, _, clientQUICMultipath) = storage.createTestQUICInstance()
            clientQUICMultipathLinkage = clientQUICMultipath
            clientQUICOptions.setProtocolInstance(clientQUICStreamListener.identifier)

            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let clientPath = PathProperties(parameters: clientParameters)
            let (clientUpperHarnessInstance, clientUpperHarnessLinkage) = storage.createStreamUpperHarness(
                identifier: "Client",
                local: clientEndpoint,
                remote: serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: context
            )
            clientUpperHarness = clientUpperHarnessInstance
            XCTAssertNotNil(clientUpperHarness)
            guard let clientUpperHarness else { return }

            try! clientQUICStreamListener.invokeAttachUpperProtocolToNewFlow(
                clientUpperHarnessLinkage,
                remote: serverEndpoint,
                local: clientEndpoint,
                parameters: clientParameters,
                path: clientPath
            )

            do {
                var clientQUICMultipath = clientQUICMultipath
                try clientQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    initialPaths.clientTop,
                    remote: serverEndpoint,
                    local: clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
            } catch {
                XCTFail("Failed to attach client stack: \(error)")
                return
            }

            var serverParameters = Parameters()
            serverParameters.isServer = true
            let serverPath = PathProperties(parameters: serverParameters)
            let serverQUICOptions = self.createQUICTestOptions(server: true)
            serverQUICOptions.setLogID(prefix: "L", parent: "pathEvents", protocolLogIDNumber: 1)
            let (serverQUICStreamListener, _, serverQUICMultipath) = storage.createTestQUICInstance()
            serverQUICMultipathLinkage = serverQUICMultipath
            serverQUICOptions.setProtocolInstance(serverQUICStreamListener.identifier)

            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))

            let (serverUpperHarnessInstance, serverUpperHarnessLinkage) = storage.createNewStreamFlowHarness(
                identifier: "Server",
                local: serverEndpoint,
                remote: clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: context
            )
            serverUpperHarness = serverUpperHarnessInstance
            XCTAssertNotNil(serverUpperHarness)
            guard let serverUpperHarness else { return }

            do {
                // Attach from the upper linkage so both directions are bound.
                try serverUpperHarnessLinkage.invokeAttachLowerProtocol(
                    serverQUICStreamListener,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach server upper harness to QUIC: \(error)")
                return
            }

            do {
                var serverQUICMultipath = serverQUICMultipath
                try serverQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    initialPaths.serverTop,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach server stack: \(error)")
                return
            }

            // Register path event callbacks on the server-side connection harness
            serverUpperHarness.completions.pathChanged = { pathInfo in
                receivedPathChangedInfo = pathInfo
                pathChangedExpectation.fulfill()
            }
            serverUpperHarness.completions.pathValidated = { pathInfo in
                receivedPathValidatedInfo = pathInfo
                pathValidatedExpectation.fulfill()
            }

            var serverConnected = false
            serverUpperHarness.start { connected in
                serverConnected = true
                XCTAssertTrue(connected)
                handshakeExpectation.fulfill()
            }

            clientUpperHarness.start { connected in
                XCTAssertTrue(connected)
            }

            while !serverConnected {
                if initialPaths.transferPackets() == 0 { break }
            }
        }

        wait(for: [handshakeExpectation], timeout: 10.0)
        XCTAssertNotNil(clientQUICMultipathLinkage)
        XCTAssertNotNil(serverQUICMultipathLinkage)
        guard var clientQUICMultipathLinkage, var serverQUICMultipathLinkage else { return }

        // Migration: client switches to a new source address, server address is unchanged
        let migrationExpectation = XCTestExpectation(description: "migration path complete")
        context.async {
            defer { migrationExpectation.fulfill() }

            // The server endpoint is the same — only the clients source address changes.
            let migrationPaths = PairedUDPIPPaths(
                context: context,
                storage: storage,
                identifier: "2",
                clientEndpoint: newClientEndpoint,
                serverEndpoint: serverEndpoint,
                maximumDatagramSize: 1500
            )
            pairedPathsArray.append(migrationPaths)

            let clientMigrationParameters = Parameters()
            let serverMigrationParameters = Parameters()

            try! clientQUICMultipathLinkage.invokeAttachLowerProtocolForNewPath(
                migrationPaths.clientTop,
                remote: serverEndpoint,
                local: newClientEndpoint,
                parameters: clientMigrationParameters,
                path: PathProperties(parameters: clientMigrationParameters)
            )
            try! serverQUICMultipathLinkage.invokeAttachLowerProtocolForNewPath(
                migrationPaths.serverTop,
                remote: newClientEndpoint,
                local: serverEndpoint,
                parameters: serverMigrationParameters,
                path: PathProperties(parameters: serverMigrationParameters)
            )

            migrationPaths.server.deliverPathIsNotPrimary()
            migrationPaths.client.deliverPathIsPrimary()

            for _ in 0..<10 {
                if migrationPaths.transferPackets() == 0 { break }
            }
        }

        wait(for: [migrationExpectation], timeout: 10.0)
        wait(for: [pathChangedExpectation, pathValidatedExpectation], timeout: 10.0)

        XCTAssertNotNil(receivedPathChangedInfo, "Expected pathChanged event")
        XCTAssertNotNil(receivedPathValidatedInfo, "Expected pathValidated event")

        // This validations are for the server side so the remote should change here
        if let pathInfo = receivedPathValidatedInfo {
            XCTAssertTrue(pathInfo.isValidated)
            XCTAssertTrue(pathInfo.local == AddressEndpoint(address: serverAddress, port: serverPort))
            XCTAssertTrue(pathInfo.remote == AddressEndpoint(address: newClientAddress, port: newCLientPort))
        }
        if let pathInfo = receivedPathChangedInfo {
            XCTAssertTrue(pathInfo.local == AddressEndpoint(address: serverAddress, port: serverPort))
            XCTAssertTrue(pathInfo.remote == AddressEndpoint(address: newClientAddress, port: newCLientPort))
        }

        let stopExpectation = XCTestExpectation(description: "stop")
        context.async {
            clientUpperHarness?.stop()
            serverUpperHarness?.stop()
            clientUpperHarness?.teardown()
            serverUpperHarness?.teardown()
            stopExpectation.fulfill()
        }
        wait(for: [stopExpectation], timeout: 10.0)
    }
}
#endif
#endif

#endif
