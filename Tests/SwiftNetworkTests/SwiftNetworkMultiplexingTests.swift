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
final class SwiftNetworkMultiplexingTests: NetTestCase {

    // 10.0.0.20
    static let localIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x14]
    // 10.0.0.117
    static let remoteIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x75]
    static let outputMessage: [UInt8] = [0x0a, 0x0b, 0x0c, 0x0d]
    static let inputMessage: [UInt8] = [0x0d, 0x0c, 0x0b, 0x0a, 0x01]

    func testMultiplexingProtocol() {
        let parameters = Parameters()
        let context = parameters.context
        let path = PathProperties(parameters: parameters)

        let localEndpoint = Endpoint(address: IPv4Address(SwiftNetworkMultiplexingTests.localIPv4Address)!, port: 1234)
        let remoteEndpoint = Endpoint(address: IPv4Address(SwiftNetworkMultiplexingTests.localIPv4Address)!, port: 2345)

        var instance: TestMultiplexingProtocol? = nil
        var upperHarness1: DatagramUpperHarness?
        var lowerHarness: DatagramLowerHarness?
        var listenerHarness: NewDatagramFlowHarness?
        let expectation = XCTestExpectation()
        context.async {
            instance = TestMultiplexingProtocol(context: context)
            XCTAssertNotNil(instance)
            guard var instance else { return }

            let listenerLinkage = DatagramListenerLinkage(reference: instance.reference)

            listenerHarness = NewDatagramFlowHarness(
                identifier: "Listener1",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(listenerHarness, "Failed to attach multiplexing test to listener harness")
            guard let listenerHarness else {
                return
            }

            upperHarness1 = DatagramUpperHarness(
                identifier: "Client1",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )

            XCTAssertNotNil(upperHarness1, "Failed to attach multiplexing test to upper harness")
            guard let upperHarness1 else {
                expectation.fulfill()
                return
            }
            lowerHarness = DatagramLowerHarness(
                identifier: "Client",
                context: parameters.context
            )
            guard let lowerHarness else {
                expectation.fulfill()
                return
            }
            do {
                try instance.attachLowerDatagramProtocolForNewPath(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTAssertTrue(false, "Failed to add multiplexing test to lower harness")
                return
            }

            upperHarness1.start { connected in
                XCTAssertTrue(connected, "Protocol failed to become connected")
                expectation.fulfill()
            }

            XCTAssertEqual(listenerHarness.upperHarnesses.count, 0, "Listener expects to have 0 inbound flows")
        }
        wait(for: [expectation], timeout: 5.0)

        guard let upperHarness1, let lowerHarness, let listenerHarness else {
            return
        }

        let dataExpectation = XCTestExpectation()
        context.async {
            XCTAssertNotNil(instance)
            guard let instance else { return }

            let listenerLinkage = DatagramListenerLinkage(reference: instance.reference)

            let outputMessage = SwiftNetworkMultiplexingTests.outputMessage
            let inputMessage = SwiftNetworkMultiplexingTests.inputMessage

            let wrote = upperHarness1.write(outputMessage)

            XCTAssertTrue(wrote, "Failed to write")

            let lastPacketData = lowerHarness.extractLastOutboundPacket()
            XCTAssertNotNil(lastPacketData, "Failed to get multiplexed outbound packet")
            guard let lastPacketData else {
                return
            }

            let expectedPacketData = outputMessage.withUnsafeBytes { [UInt8]($0) }
            XCTAssertEqual(lastPacketData, expectedPacketData, "Failed to generate expected multiplexed output packet")

            let inputPacketData = inputMessage.withUnsafeBytes { [UInt8]($0) }
            lowerHarness.setNextInboundPacket(inputPacketData)

            let readApplicationBytes = upperHarness1.read()
            XCTAssertNotNil(readApplicationBytes, "Failed to get multiplexed input packet")
            guard let readApplicationBytes else {
                return
            }

            let readApplicationData = readApplicationBytes.withUnsafeBytes { [UInt8]($0) }
            XCTAssertEqual(inputPacketData, readApplicationData, "Failed to read expected multiplexed input data")

            instance.triggerNewFlowCreation()
            XCTAssertEqual(listenerHarness.upperHarnesses.count, 1, "Listener expects to have 1 inbound flows")

            let upperHarness2 = DatagramUpperHarness(
                identifier: "Client2",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(upperHarness2, "Failed to attach multiplexing test to inbound harness 2")
            guard let upperHarness2 else {
                return
            }

            upperHarness2.start { _ in }

            let upperHarness3 = DatagramUpperHarness(
                identifier: "Client3",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(upperHarness3, "Failed to attach multiplexing test to inbound harness 3")
            guard let upperHarness3 else {
                return
            }

            upperHarness3.start { _ in }

            let wrote2 = upperHarness2.write(outputMessage)
            XCTAssertTrue(wrote2, "Failed to write, second flow")

            let lastPacketData2 = lowerHarness.extractLastOutboundPacket()
            XCTAssertNotNil(lastPacketData, "Failed to get multiplexed output packet, second flow")
            guard let lastPacketData2 else {
                return
            }

            dataExpectation.fulfill()

            XCTAssertEqual(
                lastPacketData2,
                expectedPacketData,
                "Failed to generate expected multiplexed output packet, second flow"
            )

            upperHarness1.stop()
            upperHarness2.stop()
            upperHarness3.stop()

            upperHarness1.teardown()
            upperHarness2.teardown()
            upperHarness3.teardown()

            listenerHarness.teardown()
        }

        wait(for: [dataExpectation], timeout: 5.0)
    }

    func testMultiplexingProtocolPendingStreams() {
        let parameters = Parameters()
        let context = parameters.context
        let path = PathProperties(parameters: parameters)

        let localEndpoint = Endpoint(address: IPv4Address(SwiftNetworkMultiplexingTests.localIPv4Address)!, port: 1234)
        let remoteEndpoint = Endpoint(address: IPv4Address(SwiftNetworkMultiplexingTests.localIPv4Address)!, port: 2345)

        // Use a high number of streams to ensure that we don't have poor scaling
        let upperHarnessCount = 1000
        var upperHarnesses = [DatagramUpperHarness]()
        var lowerHarness: DatagramLowerHarness?
        var listenerHarness: NewDatagramFlowHarness?
        let expectation = XCTestExpectation()
        context.async {
            var instance = TestMultiplexingProtocol(context: context)
            instance.delayConnected = true
            let listenerLinkage = DatagramListenerLinkage(reference: instance.reference)

            listenerHarness = NewDatagramFlowHarness(
                identifier: "Listener1",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(listenerHarness, "Failed to attach multiplexing test to listener harness")
            guard let listenerHarness else {
                return
            }

            lowerHarness = DatagramLowerHarness(
                identifier: "Client",
                context: parameters.context
            )
            guard let lowerHarness else {
                expectation.fulfill()
                return
            }
            do {
                try instance.attachLowerDatagramProtocolForNewPath(
                    lowerHarness.reference,
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTAssertTrue(false, "Failed to add multiplexing test to lower harness")
                return
            }

            for index in 0..<upperHarnessCount {
                let upperHarness = DatagramUpperHarness(
                    identifier: "Client\(index)",
                    local: localEndpoint,
                    remote: remoteEndpoint,
                    parameters: parameters,
                    path: path,
                    context: parameters.context,
                    listenerProtocol: listenerLinkage
                )
                XCTAssertNotNil(upperHarness, "Failed to attach multiplexing test to upper harness")
                guard let upperHarness else {
                    expectation.fulfill()
                    return
                }

                upperHarnesses.append(upperHarness)
                upperHarness.start { connected in
                    // Send a placeholder event
                    upperHarness.invokeApplicationEvent(.connectionIdle)
                }
            }

            listenerHarness.start()

            instance.triggerConnected()

            expectation.fulfill()

            XCTAssertEqual(listenerHarness.upperHarnesses.count, 0, "Listener expects to have 0 inbound flows")
        }
        wait(for: [expectation], timeout: 5.0)

        guard upperHarnesses.count == upperHarnessCount, let listenerHarness else {
            return
        }

        let closeExpectation = XCTestExpectation()
        context.async {

            for upperHarness in upperHarnesses {
                upperHarness.stop()
                upperHarness.teardown()
            }
            listenerHarness.stop()
            listenerHarness.teardown()

            closeExpectation.fulfill()
        }

        wait(for: [closeExpectation], timeout: 5.0)
    }
}

#endif
