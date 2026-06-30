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
final class SwiftNetworkIPTests: NetTestCase {

    // 169.254.156.146
    static let localIPv4Address: [UInt8] = [0xa9, 0xfe, 0x9c, 0x92]

    // 169.254.225.163
    static let remoteIPv4Address: [UInt8] = [0xa9, 0xfe, 0xe1, 0xa3]

    // fe80::1444:4d27:b896:d383
    static let localIPv6Address: [UInt8] = [
        0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44, 0x4d, 0x27, 0xb8, 0x96, 0xd3, 0x83,
    ]

    // fe80::1cd6:90f7:2466:d31b
    static let remoteIPv6Address: [UInt8] = [
        0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6, 0x90, 0xf7, 0x24, 0x66, 0xd3, 0x1b,
    ]

    // 169.254.156.146 -> 169.254.225.163, UDP hello
    static let outputIPv4Packet: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x68, 0x99, 0xa9, 0xfe, 0x9c, 0x92, 0xa9, 0xfe,
        0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    //  169.254.225.163 -> 169.254.156.146, UDP hello
    static let inputIPv4Packet: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x68, 0x99, 0xa9, 0xfe, 0xe1, 0xa3, 0xa9, 0xfe,
        0x9c, 0x92, 0x04, 0xd2, 0xfc, 0xf7, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    // fe80::1444:4d27:b896:d383 -> fe80::1cd6:90f7:2466:d31b, UDP hello
    static let outputIPv6Packet: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44,
        0x4d, 0x27, 0xb8, 0x96, 0xd3, 0x83, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6, 0x90, 0xf7,
        0x24, 0x66, 0xd3, 0x1b, 0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    // fe80::1cd6:90f7:2466:d31b -> fe80::1444:4d27:b896:d383, UDP hello
    static let inputIPv6Packet: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6,
        0x90, 0xf7, 0x24, 0x66, 0xd3, 0x1b, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44, 0x4d, 0x27,
        0xb8, 0x96, 0xd3, 0x83, 0x04, 0xd2, 0xfc, 0xf7, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    //  169.254.225.163 -> 169.254.156.146, UDP hello with DSCP
    static let outputIPv4PacketWithDSCP: [UInt8] = [
        0x45, 0x20, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
        0x40, 0x11, 0x68, 0x79, 0xa9, 0xfe, 0x9c, 0x92,
        0xa9, 0xfe, 0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2,
        0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]
    //  169.254.225.163 -> 169.254.156.146, UDP hello with corrupt checksum
    static let outputIPv4PacketWithCorruptChecksum: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
        0x40, 0x11, 0xef, 0xbe, 0xa9, 0xfe, 0x9c, 0x92,
        0xa9, 0xfe, 0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2,
        0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]
    //  169.254.225.163 -> 169.254.156.146, UDP hello with altered hop limit / checksum
    static let outputIPv4PacketWithAlteredHopLimit: [UInt8] = [
        0x45, 0x00, 0x00, 0x21, 0x00, 0x00, 0x40, 0x00,
        0x20, 0x11, 0x88, 0x99, 0xa9, 0xfe, 0x9c, 0x92,
        0xa9, 0xfe, 0xe1, 0xa3, 0xfc, 0xf7, 0x04, 0xd2,
        0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    static let outputIPv6PacketWithAlteredHopLimit: [UInt8] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0d, 0x11, 0x20, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x44,
        0x4d, 0x27, 0xb8, 0x96, 0xd3, 0x83, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, 0xd6, 0x90, 0xf7,
        0x24, 0x66, 0xd3, 0x1b, 0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
    ]

    static let badChecksumInputIPv4Packet: [UInt8] = [
        0x09, 0x29, 0x04, 0xd2, 0x00, 0x0e, 0x9e, 0x00, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]
    static let badPortsInputIPv4Packet: [UInt8] = [
        0x04, 0xd2, 0x09, 0x29, 0x00, 0x0e, 0x9e, 0x69, 0x74, 0x68, 0x65, 0x72, 0x65, 0x0a,
    ]

    static let shortInputIPv4Packet: [UInt8] = [0x01, 0x02]

    static let outputMessage: [UInt8] = [0xfc, 0xf7, 0x04, 0xd2, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f]
    static let inputMessage: [UInt8] = [0x04, 0xd2, 0xfc, 0xf7, 0x00, 0x0d, 0xe8, 0x04, 0x68, 0x65, 0x6c, 0x6c, 0x6f]

    func internalTestIP(
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        outputPacket: [UInt8],
        inputPacket: [UInt8],
        secondaryInputPacket: [UInt8]? = nil,
        expectFailure: Bool = false,
        dscpValue: UInt8 = 0,
        corrumptChecksum: Bool = false,
        hopLimit: UInt8? = nil
    ) {
        nonisolated(unsafe) let localEndpoint = localEndpoint
        nonisolated(unsafe) let remoteEndpoint = remoteEndpoint

        let expectation = XCTestExpectation()
        let context = NetworkContext.implicitContext
        context.async {
            defer { expectation.fulfill() }
            var parameters = Parameters()
            parameters.context = context
            let path = PathProperties(parameters: parameters)

            let reference = IPProtocol.instance(context: parameters.context)
            let ipOptions = IPProtocol.options()
            ipOptions.dscpValue = dscpValue
            if corrumptChecksum {
                ipOptions.flags = IPProtocol.IPOptions.Flags(rawValue: 8)
            }
            if let ttl = hopLimit {
                ipOptions.hopLimit = ttl
            }
            ipOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 2)
            ipOptions.setProtocolInstance(reference)
            parameters.defaultStack.internet = .ip(ipOptions)

            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            udpOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            parameters.defaultStack.transport = .udp(udpOptions)

            let ipLinkage = OutboundDatagramLinkage(reference: reference)
            let upperHarness = DatagramUpperHarness(
                identifier: "Client",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                lowerProtocol: ipLinkage
            )
            XCTAssertNotNil(upperHarness, "Failed to attach IP to upper harness")
            guard let upperHarness else {
                return
            }

            let lowerHarness = DatagramLowerHarness(
                identifier: "Client",
                context: parameters.context
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
                XCTAssertTrue(false, "Failed to attach IP to lower harness")
            }

            upperHarness.start { connected in
                XCTAssertTrue(connected, "IP failed to become connected")
            }

            let message = SwiftNetworkIPTests.outputMessage
            let wrote = upperHarness.write(message)
            XCTAssertTrue(wrote, "Failed to write")

            let lastPacketData = lowerHarness.extractLastOutboundPacket()
            XCTAssertNotNil(lastPacketData, "Failed to get IP output packet")
            guard let lastPacketData = lastPacketData else {
                return
            }

            let expectedPacketData = outputPacket.withUnsafeBytes { [UInt8]($0) }

            if case .address(let address) = localEndpoint.type,
                case .v6 = address.type
            {
                // Skip comparing flow label for IPv6
                XCTAssertEqual(lastPacketData[0], expectedPacketData[0], "Failed to generate expected IP output packet")
                var lastPacketDataSuffix = lastPacketData
                lastPacketDataSuffix.removeSubrange(0...3)
                var expectedPacketDataSuffix = expectedPacketData
                expectedPacketDataSuffix.removeSubrange(0...3)
                if expectFailure {
                    // Expected failure path
                } else {
                    // Expected Success path
                    XCTAssertEqual(
                        lastPacketDataSuffix,
                        expectedPacketDataSuffix,
                        "Failed to generate expected IP output packet"
                    )
                }
            } else {
                if expectFailure {
                    // Expected failure path
                    XCTAssertNotEqual(lastPacketData, expectedPacketData)
                } else {
                    // Expected Success path
                    XCTAssertEqual(lastPacketData, expectedPacketData, "Failed to generate expected IP output packet")
                }
            }

            if let secondaryInputPacket {
                lowerHarness.setNextInboundPacket(inputPacket, sendAvailableEvent: false)
                lowerHarness.setNextInboundPacket(secondaryInputPacket)
            } else {
                lowerHarness.setNextInboundPacket(inputPacket)
            }

            let readApplicationBytes = upperHarness.read()
            if expectFailure {
                // Expected failure path
                XCTAssertNil(readApplicationBytes, "Unexpectedly received IP input packet")
            } else {
                // Expected Success path
                XCTAssertNotNil(readApplicationBytes, "Failed to get IP input packet")
                guard let readApplicationBytes = readApplicationBytes else {
                    return
                }

                let expectedInputBytes = SwiftNetworkIPTests.inputMessage

                XCTAssertEqual(expectedInputBytes, readApplicationBytes, "Failed to read expected IP input data")
            }

            upperHarness.stop()
            upperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testIPv4() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet
        )
    }

    func testIPv6() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet
        )
    }

    // These tests should all fail input frame validation
    // sourceAddress does not match remoteAddress
    func testIPAddressMismatchIPv4Local() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            expectFailure: true
        )
    }

    func testIPAddressMismatchIPv6Local() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet,
            expectFailure: true
        )
    }

    func testIPAddressMismatchIPv4Remote() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            expectFailure: true
        )
    }

    func testIPAddressMismatchIPv6Remote() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6Packet,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet,
            expectFailure: true
        )
    }

    func testCorruptChecksum() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4PacketWithCorruptChecksum,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            corrumptChecksum: true
        )
    }

    func testIPReadAfterBadPacket() {
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4Packet,
            inputPacket: SwiftNetworkIPTests.badPortsInputIPv4Packet,
            secondaryInputPacket: SwiftNetworkIPTests.inputIPv4Packet
        )
    }

    func testDSCP() {
        // Test dscp for IPv4
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4PacketWithDSCP,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            dscpValue: 8
        )

    }

    func testHopLimitIPv4() {
        // Test setting ttl / hoplimit for IPv4
        internalTestIP(
            localEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv4Address(SwiftNetworkIPTests.remoteIPv4Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv4PacketWithAlteredHopLimit,
            inputPacket: SwiftNetworkIPTests.inputIPv4Packet,
            hopLimit: 32
        )
    }

    func testHopLimitIPv6() {
        // Test setting ttl / hoplimit for IPv6
        internalTestIP(
            localEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0),
            remoteEndpoint: Endpoint(address: IPv6Address(SwiftNetworkIPTests.remoteIPv6Address)!, port: 0),
            outputPacket: SwiftNetworkIPTests.outputIPv6PacketWithAlteredHopLimit,
            inputPacket: SwiftNetworkIPTests.inputIPv6Packet,
            hopLimit: 32
        )
    }

    func ipEcho(clientEndpoint: Endpoint, serverEndpoint: Endpoint, messages: [[UInt8]]) {
        nonisolated(unsafe) let clientEndpoint = clientEndpoint
        nonisolated(unsafe) let serverEndpoint = serverEndpoint
        let expectation = XCTestExpectation()
        let context = NetworkContext.implicitContext
        context.async {
            defer { expectation.fulfill() }
            var clientParameters = Parameters()
            clientParameters.context = context
            let clientPath = PathProperties(parameters: clientParameters)
            let clientReference = IPProtocol.instance(context: clientParameters.context)
            let clientOptions = IPProtocol.options()
            clientOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientOptions.setProtocolInstance(clientReference)
            clientParameters.defaultStack.internet = .ip(clientOptions)

            let clientIPLinkage = OutboundDatagramLinkage(reference: clientReference)
            let clientUpperHarness = DatagramUpperHarness(
                identifier: "Client",
                local: clientEndpoint,
                remote: serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: clientParameters.context,
                lowerProtocol: clientIPLinkage
            )
            XCTAssertNotNil(clientUpperHarness, "Failed to attach IP to client input harness")
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
                XCTAssertTrue(false, "Failed to attach IP to lower harness")
            }

            let serverParameters = Parameters()
            let serverPath = PathProperties(parameters: serverParameters)
            let serverReference = IPProtocol.instance(context: clientParameters.context)
            let serverOptions = IPProtocol.options()
            serverOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverOptions.setProtocolInstance(serverReference)
            serverParameters.defaultStack.internet = .ip(serverOptions)

            let serverIPLinkage = OutboundDatagramLinkage(reference: serverReference)
            let serverUpperHarness = DatagramUpperHarness(
                identifier: "Server",
                local: serverEndpoint,
                remote: clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: serverParameters.context,
                lowerProtocol: serverIPLinkage
            )
            XCTAssertNotNil(serverUpperHarness, "Failed to attach IP to server input harness")
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
                XCTAssertTrue(false, "Failed to attach IP server to lower harness")
            }

            clientUpperHarness.start { connected in
                XCTAssertTrue(connected, "IP client failed to become connected")
            }

            serverUpperHarness.start { connected in
                XCTAssertTrue(connected, "IP server failed to become connected")
            }

            for message in messages {
                let clientWrote = clientUpperHarness.write(message)
                XCTAssertTrue(clientWrote, "Client failed to write")

                let clientOutboundPacket = clientLowerHarness.extractLastOutboundPacket()
                XCTAssertNotNil(clientOutboundPacket, "Failed to get client IP outbound packet")
                guard let clientOutboundPacket = clientOutboundPacket else {
                    return
                }

                serverLowerHarness.setNextInboundPacket(clientOutboundPacket)

                let serverInboundBytes = serverUpperHarness.read()
                XCTAssertNotNil(serverInboundBytes, "Server failed to get IP inbound packet")
                guard let serverInboundBytes = serverInboundBytes else {
                    return
                }

                XCTAssertEqual(serverInboundBytes, message, "Server inbound packet did not match expected message")

                let serverWrote = serverUpperHarness.write(message)
                XCTAssertTrue(serverWrote, "Server failed to write")

                let serverOutboundPacket = serverLowerHarness.extractLastOutboundPacket()
                XCTAssertNotNil(serverOutboundPacket, "Failed to get server IP outbound packet")
                guard let serverOutboundPacket = serverOutboundPacket else {
                    return
                }

                clientLowerHarness.setNextInboundPacket(serverOutboundPacket)

                let clientInboundBytes = clientUpperHarness.read()
                XCTAssertNotNil(clientInboundBytes, "Client failed to get IP inbound packet")
                guard let clientInboundBytes = clientInboundBytes else {
                    return
                }

                XCTAssertEqual(clientInboundBytes, message, "Client inbound packet did not match expected message")
            }

            clientUpperHarness.stop()
            serverUpperHarness.stop()

            clientUpperHarness.teardown()
            serverUpperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testIPEcho() {
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

        let ipv4Client = Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0)
        let ipv4Server = Endpoint(address: IPv4Address(SwiftNetworkIPTests.localIPv4Address)!, port: 0)
        ipEcho(clientEndpoint: ipv4Client, serverEndpoint: ipv4Server, messages: messages)

        let ipv6Client = Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0)
        let ipv6Server = Endpoint(address: IPv6Address(SwiftNetworkIPTests.localIPv6Address)!, port: 0)
        ipEcho(clientEndpoint: ipv6Client, serverEndpoint: ipv6Server, messages: messages)
    }
}

#endif
