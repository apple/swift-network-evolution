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

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkUDPTests: NetTestCase {

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

    // 10.0.0.20:1234 ->  10.0.0.117:2345, "hello"
    static let outputIPv4Packet: [UInt8] = [
        0x04, 0xd2, 0x09, 0x29, 0x00, 0x0d, 0x99, 0x7e, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    //  10.0.0.117:2345 -> 10.0.0.20:1234, "there\n"
    static let inputIPv4Packet: [UInt8] = [
        0x09, 0x29, 0x04, 0xd2, 0x00, 0x0e, 0x9e, 0x69, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]

    // fd5a:3a11:d884:7340:78:60e4:d854:8595.1234 ->  fd5a:3a11:d884:7340:8a7:8ada:1c36:6864.2345, "hello"
    static let outputIPv6Packet: [UInt8] = [
        0x04, 0xd2, 0x09, 0x29, 0x00, 0x0d, 0xd0, 0x41, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    //  fd5a:3a11:d884:7340:8a7:8ada:1c36:6864.2345 -> fd5a:3a11:d884:7340:78:60e4:d854:8595.1234, "there\n"
    static let inputIPv6Packet: [UInt8] = [
        0x09, 0x29, 0x04, 0xd2, 0x00, 0x0e, 0xd5, 0x2c, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]

    static let badChecksumInputIPv4Packet: [UInt8] = [
        0x09, 0x29, 0x04, 0xd2, 0x00, 0x0e, 0x9e, 0x00, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]
    static let badPortsInputIPv4Packet: [UInt8] = [
        0x04, 0xd2, 0x09, 0x29, 0x00, 0x0e, 0x9e, 0x69, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]

    static let shortInputIPv4Packet: [UInt8] = [0x01, 0x02]

    static let outputMessage = "hello"
    static let inputMessage = "there\n"

    func internalTestUDP(
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        outputPacket: [UInt8],
        inputPacket: [UInt8],
        secondaryInputPacket: [UInt8]? = nil,
        expectBadInput: Bool = false,
        validateMetrics: Bool = false
    ) {
        let parameters = Parameters()

        let expectation = XCTestExpectation()
        let context = parameters.context
        context.async {
            defer { expectation.fulfill() }
            let path = PathProperties(parameters: parameters)

            let reference = UDPProtocol.instance(context: context)
            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            udpOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            udpOptions.setProtocolInstance(reference)
            parameters.defaultStack.transport = .udp(udpOptions)

            let udpLinkage = OutboundDatagramLinkage(reference: reference)
            let upperHarness = DatagramUpperHarness(
                identifier: "Client",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: context,
                lowerProtocol: udpLinkage
            )
            XCTAssertNotNil(upperHarness, "Failed to attach UDP to upper harness")
            guard let upperHarness else {
                return
            }

            let lowerHarness = DatagramLowerHarness(
                identifier: "Client",
                context: context
            )
            do {
                try reference.attachLowerDatagramProtocol(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach UDP to lower harness")
            }

            upperHarness.start { connected in
                XCTAssertTrue(connected, "UDP failed to become connected")
            }

            var message = SwiftNetworkUDPTests.outputMessage
            let wrote = message.withUTF8 { bytes in
                upperHarness.write(bytes.map({ $0 }))
            }
            XCTAssertTrue(wrote, "Failed to write")

            let lastPacketData = lowerHarness.extractLastOutboundPacket()
            XCTAssertNotNil(lastPacketData, "Failed to get UDP outbound packet")
            guard let lastPacketData = lastPacketData else {
                return
            }

            let expectedPacketData = outputPacket.withUnsafeBytes { [UInt8]($0) }
            XCTAssertEqual(lastPacketData, expectedPacketData, "Failed to generate expected UDP output packet")

            if let secondaryInputPacket {
                lowerHarness.setNextInboundPacket(inputPacket, sendAvailableEvent: false)
                lowerHarness.setNextInboundPacket(secondaryInputPacket)
            } else {
                lowerHarness.setNextInboundPacket(inputPacket)
            }

            let readApplicationBytes = upperHarness.read()
            if expectBadInput {
                XCTAssertNil(readApplicationBytes, "Unexpectedly to get UDP input packet")
            } else {
                XCTAssertNotNil(readApplicationBytes, "Failed to get UDP input packet")
                guard let readApplicationBytes = readApplicationBytes else {
                    return
                }

                let readApplicationData = readApplicationBytes.withUnsafeBytes { Data($0) }

                var expectedInputMessage = SwiftNetworkUDPTests.inputMessage
                let expectedInputData = expectedInputMessage.withUTF8 { Data($0) }

                XCTAssertEqual(expectedInputData, readApplicationData, "Failed to read expected UDP input data")
            }
            if validateMetrics {
                let metrics = upperHarness.getMetrics(requestedNetworkMetric: .dataTransferSnapshot)
                XCTAssertNotNil(metrics)
                switch metrics {
                case .dataTransferSnapshot(let snapshot):
                    XCTAssertTrue(snapshot.receivedTransportByteCount > 0)
                    XCTAssertTrue(snapshot.sentTransportByteCount > 0)
                default:
                    XCTFail("Failed to get UDP harness metrics")
                }
            }

            upperHarness.stop()
            upperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testUDPIPv4() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkUDPTests.inputIPv4Packet
        )
    }

    func testUDPIPv4WithMetrics() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkUDPTests.inputIPv4Packet,
            validateMetrics: true
        )
    }

    func testUDPIPv6() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkUDPTests.localIPv6Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkUDPTests.remoteIPv6Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkUDPTests.inputIPv6Packet
        )
    }

    func internalTestUDPChecksumFlags(
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        instanceFlags: UInt16,
        validateOutbound: @escaping (DatagramLowerHarness) -> Void
    ) {
        let parameters = Parameters()
        let expectation = XCTestExpectation()
        let context = parameters.context
        context.async {
            defer { expectation.fulfill() }
            let path = PathProperties(parameters: parameters)

            let reference = UDPProtocol.instance(context: context, flags: instanceFlags)
            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            udpOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            udpOptions.setProtocolInstance(reference)
            parameters.defaultStack.transport = .udp(udpOptions)

            let udpLinkage = OutboundDatagramLinkage(reference: reference)
            guard
                let upperHarness = DatagramUpperHarness(
                    identifier: "Client",
                    local: localEndpoint,
                    remote: remoteEndpoint,
                    parameters: parameters,
                    path: path,
                    context: context,
                    lowerProtocol: udpLinkage
                )
            else {
                XCTFail("Failed to attach UDP to upper harness")
                return
            }

            let lowerHarness = DatagramLowerHarness(identifier: "Client", context: context)
            do {
                try reference.attachLowerDatagramProtocol(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach UDP to lower harness")
                return
            }

            upperHarness.start { connected in
                XCTAssertTrue(connected, "UDP failed to become connected")
            }

            var message = SwiftNetworkUDPTests.outputMessage
            XCTAssertTrue(message.withUTF8 { upperHarness.write($0.map { $0 }) }, "Failed to write")

            validateOutbound(lowerHarness)

            upperHarness.stop()
            upperHarness.teardown()
        }
        wait(for: [expectation], timeout: 10.0)
    }

    func testUDPIPv4FullChecksumOffload() {
        internalTestUDPChecksumFlags(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            instanceFlags: UDPProtocol.Instance.Flags.fullChecksumOffload.rawValue
        ) { lowerHarness in
            let flags = lowerHarness.pendingOutboundPackets.peekFirstFrame { $0.checksumOffloadFlags }
            // udpv4 = 0x10, zeroInvert = 0x02 → 0x12
            XCTAssertEqual(flags, 0x10 | 0x02, "Expected fullChecksumOffload flags for IPv4 UDP")
        }
    }

    func testUDPIPv6FullChecksumOffload() {
        internalTestUDPChecksumFlags(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkUDPTests.localIPv6Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkUDPTests.remoteIPv6Address)!, port: 2345),
            instanceFlags: UDPProtocol.Instance.Flags.fullChecksumOffload.rawValue
        ) { lowerHarness in
            let flags = lowerHarness.pendingOutboundPackets.peekFirstFrame { $0.checksumOffloadFlags }
            // udpv6 = 0x40, zeroInvert = 0x02 → 0x42
            XCTAssertEqual(flags, 0x40 | 0x02, "Expected fullChecksumOffload flags for IPv6 UDP")
        }
    }

    func testUDPIPv4NoChecksum() {
        internalTestUDPChecksumFlags(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            instanceFlags: UDPProtocol.Instance.Flags.noChecksum.rawValue
        ) { lowerHarness in
            guard let packet = lowerHarness.extractLastOutboundPacket() else {
                XCTFail("No outbound packet")
                return
            }
            // Everything should be zero here
            XCTAssertTrue(packet.count >= 8, "Packet too short")
            XCTAssertEqual(packet[6], 0x00, "Checksum high byte should be zero")
            XCTAssertEqual(packet[7], 0x00, "Checksum low byte should be zero")
        }
    }

    func testBadChecksumUDPIPv4() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkUDPTests.badChecksumInputIPv4Packet,
            expectBadInput: true
        )
    }

    func testUDPReadAfterBadPacket() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkUDPTests.badChecksumInputIPv4Packet,
            secondaryInputPacket: SwiftNetworkUDPTests.inputIPv4Packet
        )
    }

    func testBadPortsUDPIPv4() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkUDPTests.badPortsInputIPv4Packet,
            expectBadInput: true
        )
    }

    func testBadShortUDPIPv4() {
        internalTestUDP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkUDPTests.remoteIPv4Address)!, port: 2345),
            outputPacket: SwiftNetworkUDPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkUDPTests.shortInputIPv4Packet,
            expectBadInput: true
        )
    }

    func udpEcho(clientEndpoint: Endpoint, serverEndpoint: Endpoint, messages: [[UInt8]]) {
        let clientParameters = Parameters()

        let expectation = XCTestExpectation()
        let context = clientParameters.context
        context.async {
            defer { expectation.fulfill() }

            let clientPath = PathProperties(parameters: clientParameters)
            let clientReference = UDPProtocol.instance(context: clientParameters.context)
            let clientOptions = UDPProtocol.options()
            clientOptions.noMetadata = true
            clientOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientOptions.setProtocolInstance(clientReference)
            clientParameters.defaultStack.transport = .udp(clientOptions)

            let clientUDPLinkage = OutboundDatagramLinkage(reference: clientReference)
            let clientUpperHarness = DatagramUpperHarness(
                identifier: "Client",
                local: clientEndpoint,
                remote: serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: clientParameters.context,
                lowerProtocol: clientUDPLinkage
            )
            XCTAssertNotNil(clientUpperHarness, "Failed to attach UDP to client input harness")
            guard let clientUpperHarness else {
                return
            }

            let clientLowerHarness = DatagramLowerHarness(identifier: "Client", context: clientParameters.context)
            clientLowerHarness.maximumOutputSize = 9000
            do {
                try clientReference.attachLowerDatagramProtocol(
                    clientLowerHarness.reference,
                    remote: serverEndpoint,
                    local: clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach UDP to lower harness")
            }

            let serverParameters = Parameters()
            let serverPath = PathProperties(parameters: serverParameters)
            let serverReference = UDPProtocol.instance(context: serverParameters.context)
            let serverOptions = UDPProtocol.options()
            serverOptions.noMetadata = true
            serverOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverOptions.setProtocolInstance(serverReference)
            serverParameters.defaultStack.transport = .udp(serverOptions)

            let serverUDPLinkage = OutboundDatagramLinkage(reference: serverReference)
            let serverUpperHarness = DatagramUpperHarness(
                identifier: "Server",
                local: serverEndpoint,
                remote: clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: serverParameters.context,
                lowerProtocol: serverUDPLinkage
            )
            XCTAssertNotNil(serverUpperHarness, "Failed to attach UDP to server input harness")
            guard let serverUpperHarness else {
                return
            }

            let serverLowerHarness = DatagramLowerHarness(identifier: "Server", context: serverParameters.context)
            serverLowerHarness.maximumOutputSize = 9000
            do {
                try serverReference.attachLowerDatagramProtocol(
                    serverLowerHarness.reference,
                    remote: clientEndpoint,
                    local: serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTAssertTrue(false, "Failed to attach UDP server to lower harness")
            }

            clientUpperHarness.start { connected in
                XCTAssertTrue(connected, "UDP client failed to become connected")
            }

            serverUpperHarness.start { connected in
                XCTAssertTrue(connected, "UDP server failed to become connected")
            }

            for message in messages {
                let clientWrote = clientUpperHarness.write(message)
                XCTAssertTrue(clientWrote, "Client failed to write")

                let clientOutputPacket = clientLowerHarness.extractLastOutboundPacket()
                XCTAssertNotNil(clientOutputPacket, "Failed to get client UDP output packet")
                guard let clientOutputPacket else {
                    return
                }

                serverLowerHarness.setNextInboundPacket(clientOutputPacket)

                let serverInputBytes = serverUpperHarness.read()
                XCTAssertNotNil(serverInputBytes, "Server failed to get UDP input packet")
                guard let serverInputBytes = serverInputBytes else {
                    return
                }

                XCTAssertEqual(serverInputBytes, message, "Server input packet did not match expected message")

                let serverWrote = serverUpperHarness.write(message)
                XCTAssertTrue(serverWrote, "Server failed to write")

                let serverOutputPacket = serverLowerHarness.extractLastOutboundPacket()
                XCTAssertNotNil(serverOutputPacket, "Failed to get server UDP output packet")
                guard let serverOutputPacket = serverOutputPacket else {
                    return
                }

                clientLowerHarness.setNextInboundPacket(serverOutputPacket)

                let clientInputBytes = clientUpperHarness.read()
                XCTAssertNotNil(clientInputBytes, "Client failed to get UDP input packet")
                guard let clientInputBytes = clientInputBytes else {
                    return
                }

                XCTAssertEqual(clientInputBytes, message, "Client input packet did not match expected message")
            }

            clientUpperHarness.stop()
            serverUpperHarness.stop()

            clientUpperHarness.teardown()
            serverUpperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testUDPEcho() {
        // This is a somewhat random set of messages, intended to test various lengths types of content
        var messages: [[UInt8]] = [
            [0x01, 0x02, 0x03, 0x4, 0x05, 0x06, 0x07, 0x08],
            [0x00, 0x00],
            [],
            [
                0x25, 0xcc, 0xd1, 0x09, 0x03, 0x31, 0x0c, 0x04, 0xd1, 0x56, 0xb6, 0x80, 0x23, 0x95, 0xa4, 0x09,
                0xc5, 0x12, 0xc7, 0x82, 0x65, 0xfb, 0x2c, 0xa9, 0xff, 0x18, 0xee, 0x7b, 0x78, 0xf3, 0x9d, 0xdb,
                0x1c, 0x5c, 0x51, 0x0e, 0x9d, 0x7d, 0x6e, 0x04, 0x13, 0xe2, 0x96, 0x17, 0xda, 0x1c, 0x61, 0x2d,
                0x2d, 0x6b, 0x43, 0x94, 0x8b, 0xd1, 0x38, 0x6e, 0x58, 0xe7, 0x89, 0x61, 0x7a, 0x00, 0x8c, 0x15,
                0x3e, 0x15, 0x69, 0xbe, 0x0e, 0xe6, 0x68, 0x54, 0x6a, 0x8d, 0x44, 0x25, 0xba, 0xfc, 0xce, 0x1e,
                0x96, 0xef, 0xda, 0xe0, 0x72, 0x0f, 0x81, 0x74, 0x3e, 0x25, 0x9f, 0x3f,
            ],
        ]

        if let lastMessage = messages.last {
            // Make a copy of the last message 50x that is larger, to test a "jumbo" datagram case
            var jumboMessage = [UInt8]()
            for _ in 0..<50 { jumboMessage.append(contentsOf: lastMessage) }
            messages.append(jumboMessage)
        }

        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkUDPTests.localIPv4Address)!, port: 8080)
        udpEcho(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server, messages: messages)

        let ipv6Client = Endpoint(address: IPv6Address(SwiftNetworkUDPTests.localIPv6Address)!, port: 2345)
        let ipv6Server = Endpoint(address: IPv6Address(SwiftNetworkUDPTests.localIPv6Address)!, port: 8443)
        udpEcho(clientEndpoint: ipv6Client, serverEndpoint: ipv6Server, messages: messages)
    }
}

#endif
