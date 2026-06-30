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
final class SwiftNetworkQUICEarlyDataTests: NetTestCase, @unchecked Sendable {

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

    var epskData: [UInt8] = [
        0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68,
        0xc8, 0x4e,
    ]
    var epskIdentity: [UInt8] = [0x65, 0x70, 0x73, 0x6B]
    var serverSigningKey = P256.Signing.PrivateKey()
    func createQUICTestOptions(
        server: Bool = false,
        enableEarlyData: Bool,
        sourceConnectionIDLength: Int = 0,
        resumedTransportParameters: [UInt8]? = nil,
        resendRejectedEarlyDataAutomatically: Bool = false
    ) -> ProtocolOptions<QUICProtocol> {
        var tlsOptions = SwiftTLSProtocol.Options()
        tlsOptions.applicationProtocols = ["network_test"]
        tlsOptions.serverName = "quic-test.local"
        tlsOptions.enableEarlyData = enableEarlyData
        tlsOptions.resumedQUICTransportParameters = resumedTransportParameters
        tlsOptions.setExternalPSK(identity: epskIdentity, epsk: epskData)

        let quicOptions = QUICStreamProtocol.options()
        quicOptions.tlsOptions = tlsOptions

        if sourceConnectionIDLength > 0 {
            quicOptions.connectionOptions.sourceConnectionIDLength = sourceConnectionIDLength
        }

        if resendRejectedEarlyDataAutomatically {
            quicOptions.connectionOptions.resendRejectedEarlyDataAutomatically = true
        }

        return quicOptions
    }

    func transferPackets(
        sender: DatagramLowerHarness,
        receiver: DatagramLowerHarness,
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
        var client: DatagramLowerHarness
        var server: DatagramLowerHarness

        var clientTop: ProtocolInstanceReference
        var serverTop: ProtocolInstanceReference

        init(
            context: NetworkContext,
            identifier: String,
            clientEndpoint: Endpoint,
            serverEndpoint: Endpoint,
            maximumDatagramSize: Int = 1500
        ) {
            clientTop = UDPProtocol.instance(context: context)
            let clientUDPOptions = UDPProtocol.options()
            clientUDPOptions.noMetadata = true
            clientUDPOptions.setLogID(prefix: "C", parent: identifier, protocolLogIDNumber: 2)
            clientUDPOptions.setProtocolInstance(clientTop)

            let clientIP = IPProtocol.instance(context: context)
            let clientIPOptions = IPProtocol.options()
            clientIPOptions.setLogID(prefix: "C", parent: identifier, protocolLogIDNumber: 3)
            clientIPOptions.setProtocolInstance(clientIP)

            serverTop = UDPProtocol.instance(context: context)
            let serverUDPOptions = UDPProtocol.options()
            serverUDPOptions.noMetadata = true
            serverUDPOptions.setLogID(prefix: "L", parent: identifier, protocolLogIDNumber: 2)
            serverUDPOptions.setProtocolInstance(serverTop)

            let serverIP = IPProtocol.instance(context: context)
            let serverIPOptions = IPProtocol.options()
            serverIPOptions.setLogID(prefix: "L", parent: identifier, protocolLogIDNumber: 3)
            serverIPOptions.setProtocolInstance(serverIP)

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

            client = DatagramLowerHarness(identifier: "Client" + identifier, context: context)
            server = DatagramLowerHarness(identifier: "Server" + identifier, context: context)

            client.maximumOutputSize = maximumDatagramSize
            server.maximumOutputSize = maximumDatagramSize

            try! clientTop.attachLowerDatagramProtocol(
                clientIP,
                remote: serverEndpoint,
                local: clientEndpoint,
                parameters: clientParameters,
                path: clientPath
            )
            try! clientIP.attachLowerDatagramProtocol(
                client.reference,
                remote: serverEndpoint,
                local: clientEndpoint,
                parameters: clientParameters,
                path: clientPath
            )

            try! serverTop.attachLowerDatagramProtocol(
                serverIP,
                remote: clientEndpoint,
                local: serverEndpoint,
                parameters: serverParameters,
                path: serverPath
            )
            try! serverIP.attachLowerDatagramProtocol(
                server.reference,
                remote: clientEndpoint,
                local: serverEndpoint,
                parameters: serverParameters,
                path: serverPath
            )
        }

        private func transferPackets(
            sender: DatagramLowerHarness,
            receiver: DatagramLowerHarness,
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

    @discardableResult
    func quicStackHandshake(
        clientEndpoint: Endpoint,
        serverEndpoint: Endpoint,
        dataToSend: [UInt8]? = nil,
        acceptEarlyData: Bool = true,
        resumedTransportParameters: [UInt8]? = nil,
        expectFailure: Bool = false,
        resendRejectedEarlyDataAutomatically: Bool = false
    ) -> [UInt8]? {
        nonisolated(unsafe) let clientEndpoint = clientEndpoint
        nonisolated(unsafe) let serverEndpoint = serverEndpoint
        let context = NetworkContext.implicitContext

        let expectation = XCTestExpectation()
        nonisolated(unsafe) var clientConnected = false
        nonisolated(unsafe) var serverConnected = false
        nonisolated(unsafe) var clientUpperHarness: StreamUpperHarness?
        nonisolated(unsafe) var serverUpperHarness: NewStreamFlowHarness?
        nonisolated(unsafe) var clientQUICReference: ProtocolInstanceReference?
        nonisolated(unsafe) var serverQUICReference: ProtocolInstanceReference?

        nonisolated(unsafe) var pairedPathsArray = [PairedUDPIPPaths]()

        nonisolated(unsafe) var earlyDataRejected = false
        nonisolated(unsafe) var remoteTransportParameters: [UInt8]? = nil
        let rejectedExpectation = XCTestExpectation()
        let errorExpectation = XCTestExpectation()

        context.async {
            defer { expectation.fulfill() }

            var clientParameters = Parameters()
            clientParameters.context = context

            let pairedPaths = PairedUDPIPPaths(
                context: context,
                identifier: "1",
                clientEndpoint: clientEndpoint,
                serverEndpoint: serverEndpoint
            )
            pairedPathsArray.append(pairedPaths)

            let clientPath = PathProperties(parameters: clientParameters)
            let clientQUIC = QUICProtocol.instance(context: context)
            clientQUICReference = clientQUIC

            let clientQUICOptions: ProtocolOptions<QUICProtocol>
            clientQUICOptions = self.createQUICTestOptions(
                server: false,
                enableEarlyData: true,
                resumedTransportParameters: resumedTransportParameters,
                resendRejectedEarlyDataAutomatically: resendRejectedEarlyDataAutomatically
            )
            clientQUICOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientQUICOptions.setProtocolInstance(clientQUIC)

            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let clientListenerLinkage = StreamListenerLinkage(reference: clientQUIC)
            clientUpperHarness = StreamUpperHarness(
                identifier: "Client",
                local: clientEndpoint,
                remote: serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: clientParameters.context,
                listenerProtocol: clientListenerLinkage
            )
            XCTAssertNotNil(clientUpperHarness, "Failed to attach stack to client upper harness")
            guard let clientUpperHarness else {
                return
            }

            do {
                try clientQUIC.attachLowerDatagramProtocolForNewPath(
                    pairedPaths.clientTop,
                    remote: serverEndpoint,
                    local: clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach client stack")
            }

            var serverParameters = Parameters()
            serverParameters.isServer = true
            let serverPath = PathProperties(parameters: serverParameters)
            let serverQUIC = QUICProtocol.instance(context: context)
            serverQUICReference = serverQUIC

            let serverQUICOptions = self.createQUICTestOptions(server: true, enableEarlyData: acceptEarlyData)
            serverQUICOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverQUICOptions.setProtocolInstance(serverQUIC)

            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))

            let serverListenerLinkage = StreamListenerLinkage(reference: serverQUIC)
            serverUpperHarness = NewStreamFlowHarness(
                identifier: "Server",
                local: serverEndpoint,
                remote: clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: serverParameters.context,
                listenerProtocol: serverListenerLinkage
            )
            XCTAssertNotNil(serverUpperHarness, "Failed to attach QUIC to server upper harness")
            guard let serverUpperHarness else {
                return
            }

            do {
                try serverQUIC.attachLowerDatagramProtocolForNewPath(
                    pairedPaths.serverTop,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach server stack")
            }

            clientUpperHarness.completions.earlyDataRejected = {
                earlyDataRejected = true
                rejectedExpectation.fulfill()
            }

            clientUpperHarness.completions.receivedRemoteTransportParameters = { state in
                remoteTransportParameters = state
            }

            if expectFailure {
                clientUpperHarness.waitForError { error in
                    XCTAssertNotNil(error, "QUIC client did not report error")
                    errorExpectation.fulfill()
                }
            }

            serverUpperHarness.start { connected in
                serverConnected = true
                XCTAssertTrue(connected, "QUIC server failed to become connected")
                expectation.fulfill()
            }

            clientUpperHarness.start { connected in
                clientConnected = true
                XCTAssertTrue(connected, "QUIC client failed to become connected")
            }

            if let dataToSend {
                Logger.test.info("Writing data to send")
                let wrote = clientUpperHarness.write(dataToSend, earlyData: true)
                XCTAssertTrue(wrote, "QUIC client failed to write")
            }

            while !serverConnected {
                if pairedPaths.transferPackets() == 0 {
                    break
                }
            }
        }

        if expectFailure {
            wait(for: [errorExpectation], timeout: 5.0)
        } else {

            wait(for: [expectation], timeout: 10.0)
            XCTAssertTrue(clientConnected, "QUIC stack client wasn't connected")
            XCTAssertTrue(serverConnected, "QUIC stack server wasn't connected")

            XCTAssertNotNil(clientQUICReference)
            XCTAssertNotNil(serverQUICReference)

            if let dataToSend {
                if !acceptEarlyData, !resendRejectedEarlyDataAutomatically {
                    wait(for: [rejectedExpectation], timeout: 5.0)
                    XCTAssertTrue(earlyDataRejected, "Early data not rejected")
                    context.async {
                        Logger.test.info("Re-writing data to send")
                        let wrote = clientUpperHarness?.write(dataToSend) ?? false
                        XCTAssertTrue(wrote, "QUIC client failed to write")
                    }
                } else {
                    XCTAssertFalse(earlyDataRejected, "Early data rejected")
                }

                let receiveExpectation = XCTestExpectation()
                context.async {
                    Logger.test.info("Trying to read data")
                    @Sendable func attemptServerRead() {
                        if pairedPathsArray.first?.transferPackets() == 0 {
                            // Wait for new writes from the client to be sent
                            context.async {
                                attemptServerRead()
                            }
                            return
                        }
                        Logger.test.info("Trying to read data")
                        if let readData = serverUpperHarness?.upperHarnesses.first?.read() {
                            XCTAssertEqual(readData, dataToSend)
                            receiveExpectation.fulfill()
                        }
                    }
                    attemptServerRead()
                }
                wait(for: [receiveExpectation], timeout: 5.0)
            }
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

        return remoteTransportParameters
    }

    #if !NETWORK_PRIVATE
    var fakeTransportParameters: TransportParameters {
        var transportParameters = TransportParameters()
        transportParameters.append(.initialMaxStreamsBidirectional(value: 8))
        transportParameters.append(.initialMaxStreamsUnidirectional(value: 8))
        transportParameters.append(.initialMaxStreamDataBidirectionalLocal(value: 2 * 1024 * 1024))
        transportParameters.append(.initialMaxStreamDataBidirectionalRemote(value: 2 * 1024 * 1024))
        transportParameters.append(.initialMaxStreamDataUnidirectional(value: 2 * 1024 * 1024))
        return transportParameters
    }
    #endif

    func testQUICExternalPSK() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 8080)
        quicStackHandshake(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server)
    }

    #if !NETWORK_PRIVATE
    func testQUICExternalPSKWithEarlyData() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 8080)
        let transportParameters = fakeTransportParameters
        let serializedParameters = try? transportParameters.serialize(forEarlyData: true)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8),
            resumedTransportParameters: serializedParameters
        )
    }
    #endif

    func testQUICExternalPSKWithEarlyDataResumption() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 8080)
        let transportParameters = quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8)
        )

        XCTAssertNotNil(
            transportParameters,
            "QUIC client failed to get transport parameters from server for resumption"
        )
        guard let transportParameters else { return }

        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8),
            resumedTransportParameters: transportParameters
        )
    }

    #if !NETWORK_PRIVATE
    func testQUICExternalPSKWithEarlyDataInvalidTransportParameters() throws {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 8080)
        var transportParameters = fakeTransportParameters
        transportParameters.remove(.initialMaxStreamsBidirectional)
        transportParameters.append(.initialMaxStreamsBidirectional(value: 16))
        let serializedParameters = try? transportParameters.serialize(forEarlyData: true)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8),
            resumedTransportParameters: serializedParameters,
            expectFailure: true
        )
    }

    func testQUICExternalPSKWithEarlyDataNotAccepted() throws {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 8080)
        let transportParameters = fakeTransportParameters
        let serializedParameters = try? transportParameters.serialize(forEarlyData: true)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8),
            acceptEarlyData: false,
            resumedTransportParameters: serializedParameters
        )
    }

    func testQUICExternalPSKWithEarlyDataNotAcceptedAutomaticResent() {
        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkQUICEarlyDataTests.localIPv4Address)!, port: 8080)
        let transportParameters = fakeTransportParameters
        let serializedParameters = try? transportParameters.serialize(forEarlyData: true)
        quicStackHandshake(
            clientEndpoint: ipv4Client,
            serverEndpoint: ipv4Server,
            dataToSend: Array("Hello World!".utf8),
            acceptEarlyData: false,
            resumedTransportParameters: serializedParameters,
            resendRejectedEarlyDataAutomatically: true
        )
    }
    #endif
}
#endif
#endif

#endif
