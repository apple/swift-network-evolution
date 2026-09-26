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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
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

        let storage = TestNetworkProtocolStorage(context: context)

        var instance: TestMultiplexingProtocol? = nil
        var listener: TestDatagramListenerLinkage? = nil
        var upperHarness1: DatagramUpperHarness<TestDatagramLinkageFamily>?
        var lowerHarness: DatagramLowerHarness<TestDatagramLinkageFamily>?
        var listenerHarness: NewDatagramFlowHarness<TestDatagramLinkageFamily>?
        let expectation = XCTestExpectation()
        context.async {
            // The multiplexing protocol lives outside the framework, and so do the linkages that
            // reach it: the test storage hands back a listener and a multipath linkage for it.
            let (listenerLinkage, multipathLinkage, multiplexing) =
                storage.createTestMultiplexingInstance()
            instance = multiplexing
            listener = listenerLinkage

            listenerHarness = storage.createTestNewDatagramFlowHarness(
                identifier: "Listener1",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path
            )
            guard let listenerHarness else {
                XCTFail("Failed to create listener harness")
                expectation.fulfill()
                return
            }
            do {
                try TestInboundDatagramFlowLinkage(harness: listenerHarness)
                    .invokeAttachLowerProtocol(
                        listenerLinkage,
                        remote: remoteEndpoint,
                        local: localEndpoint,
                        parameters: parameters,
                        path: path
                    )
            } catch {
                XCTFail("Failed to attach listener harness to multiplexing protocol: \(error)")
                expectation.fulfill()
                return
            }

            upperHarness1 = storage.createTestDatagramUpperHarness(
                identifier: "Client1",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path
            )
            guard let upperHarness1 else {
                expectation.fulfill()
                return
            }
            lowerHarness = storage.createTestDatagramLowerHarness(identifier: "Client")
            guard let lowerHarness else {
                expectation.fulfill()
                return
            }

            do {
                // A new outbound flow on the multiplexing protocol for the client harness.
                try listenerLinkage.invokeAttachUpperProtocolToNewFlow(
                    TestInboundDatagramLinkage(harness: upperHarness1),
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
                // And the multiplexing protocol's single path onto the lower harness.
                var multipathLinkage = multipathLinkage
                try multipathLinkage.invokeAttachLowerProtocolForNewPath(
                    TestOutboundDatagramLinkage(harness: lowerHarness),
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach multiplexing test stack: \(error)")
                expectation.fulfill()
                return
            }

            upperHarness1.start { connected in
                XCTAssertTrue(connected, "Protocol failed to become connected")
                expectation.fulfill()
            }

            XCTAssertEqual(listenerHarness.upperHarnesses.count, 0, "Listener expects to have 0 inbound flows")
        }
        wait(for: [expectation], timeout: 5.0)

        guard let upperHarness1, let lowerHarness, let listenerHarness, let listenerLinkage = listener
        else {
            return
        }

        let dataExpectation = XCTestExpectation()
        context.async {
            XCTAssertNotNil(instance)
            guard let instance else { return }

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

            // Two more outbound flows on the same multiplexing protocol.
            let upperHarness2 = storage.createTestDatagramUpperHarness(
                identifier: "Client2",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path
            )
            let upperHarness3 = storage.createTestDatagramUpperHarness(
                identifier: "Client3",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path
            )
            do {
                for harness in [upperHarness2, upperHarness3] {
                    try listenerLinkage.invokeAttachUpperProtocolToNewFlow(
                        TestInboundDatagramLinkage(harness: harness),
                        remote: remoteEndpoint,
                        local: localEndpoint,
                        parameters: parameters,
                        path: path
                    )
                }
            } catch {
                XCTFail("Failed to attach additional flows: \(error)")
                dataExpectation.fulfill()
                return
            }

            upperHarness2.start { _ in }
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
            storage.releaseHeldInstances()
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
        let storage = TestNetworkProtocolStorage(context: context)
        var upperHarnesses = [DatagramUpperHarness<TestDatagramLinkageFamily>]()
        var lowerHarness: DatagramLowerHarness<TestDatagramLinkageFamily>?
        var listenerHarness: NewDatagramFlowHarness<TestDatagramLinkageFamily>?
        let expectation = XCTestExpectation()
        context.async {
            let (listenerLinkage, multipathLinkage, instance) =
                storage.createTestMultiplexingInstance()
            instance.delayConnected = true

            listenerHarness = storage.createTestNewDatagramFlowHarness(
                identifier: "Listener1",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path
            )
            guard let listenerHarness else {
                XCTFail("Failed to create listener harness")
                expectation.fulfill()
                return
            }
            do {
                try TestInboundDatagramFlowLinkage(harness: listenerHarness)
                    .invokeAttachLowerProtocol(
                        listenerLinkage,
                        remote: remoteEndpoint,
                        local: localEndpoint,
                        parameters: parameters,
                        path: path
                    )
            } catch {
                XCTFail("Failed to attach listener harness: \(error)")
                expectation.fulfill()
                return
            }

            lowerHarness = storage.createTestDatagramLowerHarness(identifier: "Client")
            guard let lowerHarness else {
                expectation.fulfill()
                return
            }
            do {
                var multipathLinkage = multipathLinkage
                try multipathLinkage.invokeAttachLowerProtocolForNewPath(
                    TestOutboundDatagramLinkage(harness: lowerHarness),
                    remote: remoteEndpoint,
                    local: localEndpoint,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach lower harness: \(error)")
                expectation.fulfill()
                return
            }

            for index in 0..<upperHarnessCount {
                let upperHarness = storage.createTestDatagramUpperHarness(
                    identifier: "Client\(index)",
                    local: localEndpoint,
                    remote: remoteEndpoint,
                    parameters: parameters,
                    path: path
                )
                do {
                    try listenerLinkage.invokeAttachUpperProtocolToNewFlow(
                        TestInboundDatagramLinkage(harness: upperHarness),
                        remote: remoteEndpoint,
                        local: localEndpoint,
                        parameters: parameters,
                        path: path
                    )
                } catch {
                    XCTFail("Failed to attach flow \(index): \(error)")
                    expectation.fulfill()
                    return
                }

                upperHarnesses.append(upperHarness)
                upperHarness.start { state, connected in
                    // Send a placeholder event. The completion runs inline with the state held,
                    // so thread it in rather than re-acquiring it.
                    upperHarness.invokeApplicationEvent(.connectionIdle, in: &state)
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
            storage.releaseHeldInstances()

            closeExpectation.fulfill()
        }

        wait(for: [closeExpectation], timeout: 5.0)
    }
}

#endif
