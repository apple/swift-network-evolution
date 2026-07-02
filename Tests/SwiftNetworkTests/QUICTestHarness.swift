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
final class QUICTestHarness {
    // 127.0.0.1
    static let clientIPv4Address: [UInt8] = [0x7f, 0x00, 0x00, 0x01]
    static let serverIPv4Address: [UInt8] = [0x7f, 0x00, 0x00, 0x01]

    let clientPort: UInt16
    let serverPort: UInt16

    let clientEndpoint: Endpoint
    let serverEndpoint: Endpoint

    var serverSigningKey = P256.Signing.PrivateKey()
    var context: NetworkContext

    struct QUICHarnessState {
        let clientHarness: NewStreamFlowHarness
        let serverHarness: NewStreamFlowHarness

        let clientDatagramHarness: NewDatagramFlowHarness?
        let serverDatagramHarness: NewDatagramFlowHarness?

        let clientReference: ProtocolInstanceReference
        let serverReference: ProtocolInstanceReference

        let clientInstance: QUICProtocol.Instance
        let serverInstance: QUICProtocol.Instance

        let clientBridge: BridgeDatagramProtocol.Instance
        let serverBridge: BridgeDatagramProtocol.Instance
    }
    var state: QUICHarnessState? = nil

    init(context: NetworkContext = .init(identifier: #function)) {
        self.context = context
        self.context.activate()

        clientPort = BridgeDatagramProtocol.Instance.nextGeneratedPort
        serverPort = BridgeDatagramProtocol.Instance.nextGeneratedPort
        clientEndpoint = Endpoint(address: IPv4Address(QUICTestHarness.clientIPv4Address)!, port: clientPort)
        serverEndpoint = Endpoint(address: IPv4Address(QUICTestHarness.serverIPv4Address)!, port: serverPort)
    }

    private func wait(for expectations: [XCTestExpectation], timeout seconds: TimeInterval, expectTimeout: Bool = false)
    {
        let result = XCTWaiter.wait(for: expectations, timeout: seconds)
        if expectTimeout {
            XCTAssertEqual(result, .timedOut)
        } else {
            XCTAssertEqual(result, .completed)
        }
    }

    private func updateQUICOptions(
        _ quicOptions: ProtocolOptions<QUICProtocol>,
        server: Bool = false,
        datagram: Bool = false
    ) {
        var tlsOptions = quicOptions.tlsOptions
        if tlsOptions.applicationProtocols?.isEmpty ?? true {
            tlsOptions.applicationProtocols = ["network_test"]
        }
        tlsOptions.serverName = "quic-test.local"
        if server {
            tlsOptions.rawPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        } else {
            tlsOptions.trustedRawPublicKeyCertificates = [[UInt8](serverSigningKey.publicKey.derRepresentation)]
        }
        quicOptions.tlsOptions = tlsOptions

        if let streamOptions = quicOptions.perProtocolOptions {
            if datagram {
                if !server {
                    streamOptions.isDatagram = true
                    streamOptions.associatedStreamID = 0
                }
                streamOptions.quicConnectionOptions.datagramQuarterStreamID = true
                streamOptions.quicConnectionOptions.datagramEnableFlowID = true
                streamOptions.quicConnectionOptions.maxDatagramFrameSize = 65535
            }
        }
    }

    private func quicHandshake(
        datagram: Bool = false,
        expectHandshakeError: NetworkError? = nil,
        clientLinkDelay: NetworkDuration = .zero,
        serverLinkDelay: NetworkDuration = .zero,
        clientDrops: DatagramDrops? = nil,
        serverDrops: DatagramDrops? = nil,
        timeout: TimeInterval = 5.0,
        clientOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options()
    ) throws(NetworkError) {
        var clientConnected = false
        var serverConnected = false
        let handshakeExpectation = XCTestExpectation(description: "Wait for QUIC connection to be established")

        var matchedError = false
        var receivedError: NetworkError? = nil

        // Async onto the context to attach the protocol stack and start the handshake
        context.async {
            // Setup client parameters
            var clientParameters = Parameters()
            clientParameters.context = self.context
            clientParameters.isServer = false

            let clientInstance = QUICProtocol.Instance(context: self.context)
            let clientReference = clientInstance.reference
            self.updateQUICOptions(clientOptions, server: false, datagram: datagram)
            clientOptions.setLogID(
                prefix: "C",
                parent: "1",
                protocolLogIDNumber: 1
            )
            clientOptions.setProtocolInstance(clientReference)
            clientParameters.defaultStack.transport = .quic(clientOptions)

            let clientBridgeInstance = BridgeDatagramProtocol.Instance(context: self.context)
            let clientBridge = clientBridgeInstance.reference
            let clientBridgeOptions = BridgeDatagramProtocol.options()
            clientBridgeOptions.setProtocolInstance(clientBridge)
            clientBridgeOptions.linkDelay = clientLinkDelay
            clientBridgeOptions.datagramDrops = clientDrops
            clientParameters.defaultStack.link = .custom(clientBridgeOptions)

            var clientPath = PathProperties(parameters: clientParameters)
            clientPath.effectiveMTU = 1500
            let clientLinkage = StreamListenerLinkage(reference: clientReference)

            // Setup server parameters
            var serverParameters = Parameters()
            serverParameters.context = self.context
            serverParameters.isServer = true

            let serverInstance = QUICProtocol.Instance(context: self.context)
            let serverReference = serverInstance.reference
            serverOptions.setLogID(
                prefix: "L",
                parent: "1",
                protocolLogIDNumber: 1
            )
            self.updateQUICOptions(serverOptions, server: true, datagram: datagram)
            serverOptions.setProtocolInstance(serverReference)
            serverParameters.defaultStack.transport = .quic(serverOptions)

            let serverBridgeInstance = BridgeDatagramProtocol.Instance(context: self.context)
            let serverBridge = serverBridgeInstance.reference
            let serverBridgeOptions = BridgeDatagramProtocol.options()
            serverBridgeOptions.setProtocolInstance(serverBridge)
            serverBridgeOptions.linkDelay = serverLinkDelay
            serverBridgeOptions.datagramDrops = serverDrops
            serverParameters.defaultStack.link = .custom(serverBridgeOptions)

            var serverPath = PathProperties(parameters: serverParameters)
            serverPath.effectiveMTU = 1500
            let serverLinkage = StreamListenerLinkage(reference: serverReference)

            // Attach client
            let clientHarness = NewStreamFlowHarness(
                identifier: "Client",
                local: self.clientEndpoint,
                remote: self.serverEndpoint,
                parameters: clientParameters,
                path: clientPath,
                context: self.context,
                listenerProtocol: clientLinkage
            )
            do {
                try clientReference.attachLowerDatagramProtocolForNewPath(
                    clientBridge,
                    remote: self.serverEndpoint,
                    local: self.clientEndpoint,
                    parameters: clientParameters,
                    path: clientPath
                )
            } catch {
                XCTFail("Failed to attach QUIC client to datagram bridge")
            }

            // Attach server
            let serverHarness = NewStreamFlowHarness(
                identifier: "Server",
                local: self.serverEndpoint,
                remote: self.clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: self.context,
                listenerProtocol: serverLinkage
            )
            do {
                try serverReference.attachLowerDatagramProtocolForNewPath(
                    serverBridge,
                    remote: self.clientEndpoint,
                    local: self.serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach QUIC server to datagram bridge")
            }

            // Attach datagram harnesses
            let clientDatagramHarness: NewDatagramFlowHarness?
            let serverDatagramHarness: NewDatagramFlowHarness?

            if datagram {
                let clientDatagramLinkage = DatagramListenerLinkage(reference: clientReference)
                clientDatagramHarness = NewDatagramFlowHarness(
                    identifier: "Client",
                    local: self.clientEndpoint,
                    remote: self.serverEndpoint,
                    parameters: clientParameters,
                    path: clientPath,
                    context: self.context,
                    listenerProtocol: clientDatagramLinkage
                )

                let serverDatagramLinkage = DatagramListenerLinkage(reference: serverReference)
                serverDatagramHarness = NewDatagramFlowHarness(
                    identifier: "Server",
                    local: self.serverEndpoint,
                    remote: self.clientEndpoint,
                    parameters: serverParameters,
                    path: serverPath,
                    context: self.context,
                    listenerProtocol: serverDatagramLinkage
                )
            } else {
                clientDatagramHarness = nil
                serverDatagramHarness = nil
            }

            guard let serverHarness, let clientHarness else {
                // Fail fast
                handshakeExpectation.fulfill()
                return
            }

            self.state = QUICHarnessState(
                clientHarness: clientHarness,
                serverHarness: serverHarness,
                clientDatagramHarness: clientDatagramHarness,
                serverDatagramHarness: serverDatagramHarness,
                clientReference: clientReference,
                serverReference: serverReference,
                clientInstance: clientInstance,
                serverInstance: serverInstance,
                clientBridge: clientBridgeInstance,
                serverBridge: serverBridgeInstance
            )

            clientHarness.waitForError { error in
                if let error {
                    Logger.test.info("Client reported error \(error)")
                    receivedError = error
                }
                if error == expectHandshakeError {
                    matchedError = true
                    handshakeExpectation.fulfill()
                }
            }

            serverHarness.waitForError { error in
                if let error {
                    Logger.test.info("Server reported error \(error)")
                    receivedError = error
                }
                if error == expectHandshakeError {
                    matchedError = true
                    handshakeExpectation.fulfill()
                }
            }

            serverHarness.start { connected in
                if connected {
                    serverConnected = true
                    if expectHandshakeError == nil {
                        handshakeExpectation.fulfill()  // server transitions to connected last, wait for it
                    }
                }
            }
            clientHarness.start { connected in
                if connected {
                    clientConnected = true
                }
            }
        }

        wait(for: [handshakeExpectation], timeout: timeout)

        if let expectHandshakeError {
            XCTAssertFalse(clientConnected && serverConnected, "QUIC client and server incorrectly became connected")
            XCTAssertTrue(
                matchedError,
                "Failed to get expected error \(expectHandshakeError), received \(receivedError.debugDescription)"
            )

            stop()

            throw NetworkError.posix(ENOTCONN)
        }

        XCTAssertTrue(clientConnected, "QUIC client failed to become connected")
        XCTAssertTrue(serverConnected, "QUIC server failed to become connected")
        XCTAssertNotNil(state, "Result cannot be nil here for the tests to proceed")
        guard clientConnected, serverConnected else {
            XCTFail("This test cannot continue without both client and server being connected")
            throw NetworkError.posix(EINVAL)
        }
    }

    private func createNewStream(
        identifier: String,
        quicOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverInitiated: Bool = false
    ) -> StreamUpperHarness? {
        var handlerInstance: QUICProtocol.Instance?
        if serverInitiated {
            handlerInstance = state?.serverInstance
        } else {
            handlerInstance = state?.clientInstance
        }
        guard let instance = handlerInstance else {
            XCTFail("No instance found")
            return nil
        }
        var upperHarnessConnected = false
        var parameters = Parameters()
        parameters.context = context

        var upperHarness: StreamUpperHarness?
        let newStreamExpectation = XCTestExpectation(description: "Wait for new QUIC stream to be ready")
        let options = quicOptions.deepCopy()
        context.async {
            options.setLogID(
                prefix: identifier,
                parent: "",
                protocolLogIDNumber: 1
            )
            options.setProtocolInstance(instance.reference)
            parameters.defaultStack.transport = .custom(options)
            var path = PathProperties(parameters: parameters)
            path.effectiveMTU = 1500

            let listenerLinkage = StreamListenerLinkage(reference: instance.reference)
            let streamUpperHarness = StreamUpperHarness(
                identifier: identifier,
                local: self.clientEndpoint,
                remote: self.serverEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(streamUpperHarness, "Failed to attach new QUIC stream")
            guard let streamUpperHarness else {
                newStreamExpectation.fulfill()
                return
            }
            upperHarness = streamUpperHarness

            guard let upperHarness else {
                newStreamExpectation.fulfill()
                return
            }

            upperHarness.start { connected in
                if connected {
                    upperHarnessConnected = true
                    newStreamExpectation.fulfill()
                }
            }
        }
        wait(for: [newStreamExpectation], timeout: 5.0)

        XCTAssertTrue(upperHarnessConnected, "New QUIC stream failed to become ready")

        guard upperHarnessConnected else {
            return nil
        }

        if let upperHarness {
            if serverInitiated {
                state?.serverHarness.upperHarnesses.append(upperHarness)
            } else {
                state?.clientHarness.upperHarnesses.append(upperHarness)
            }
        }

        return upperHarness
    }

    private func createNewDatagramFlow(
        identifier: String,
        quicOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options()
    ) -> DatagramUpperHarness? {
        guard let instance = state?.clientInstance else {
            XCTFail("No instance found")
            return nil
        }
        var upperHarnessConnected = false
        var parameters = Parameters()
        parameters.context = context

        var upperHarness: DatagramUpperHarness?
        let newFlowExpectation = XCTestExpectation(description: "Wait for new QUIC datagram flow to be ready")
        let options = quicOptions.deepCopy()
        context.async {
            options.setLogID(
                prefix: identifier,
                parent: "",
                protocolLogIDNumber: 1
            )
            options.setProtocolInstance(instance.reference)
            parameters.defaultStack.transport = .custom(options)
            var path = PathProperties(parameters: parameters)
            path.effectiveMTU = 1500

            let listenerLinkage = DatagramListenerLinkage(reference: instance.reference)
            let datagramUpperHarness = DatagramUpperHarness(
                identifier: identifier,
                local: self.clientEndpoint,
                remote: self.serverEndpoint,
                parameters: parameters,
                path: path,
                context: parameters.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(datagramUpperHarness, "Failed to attach new QUIC datagram flow")
            guard let datagramUpperHarness else {
                newFlowExpectation.fulfill()
                return
            }
            upperHarness = datagramUpperHarness

            guard let upperHarness else {
                newFlowExpectation.fulfill()
                return
            }

            upperHarness.start { connected in
                if connected {
                    upperHarnessConnected = true
                    newFlowExpectation.fulfill()
                }
            }
        }
        wait(for: [newFlowExpectation], timeout: 5.0)

        XCTAssertTrue(upperHarnessConnected, "New QUIC datagram flow failed to become ready")

        guard upperHarnessConnected else {
            return nil
        }

        if let upperHarness {
            state?.clientDatagramHarness?.upperHarnesses.append(upperHarness)
        }

        return upperHarness
    }

    private func markIdle() {
        guard let state else {
            XCTFail("State must be non-nil")
            return
        }
        let idleCompleteExpectation = XCTestExpectation(description: "Wait for marking idle")
        context.async {
            for upperHarness in state.clientHarness.upperHarnesses {
                upperHarness.invokeConnectionIdleEvent()
            }
            for upperHarness in state.serverHarness.upperHarnesses {
                upperHarness.invokeConnectionIdleEvent()
            }
            idleCompleteExpectation.fulfill()
        }
        wait(for: [idleCompleteExpectation], timeout: 5.0)
    }

    private func stop() {
        guard let state else {
            XCTFail("State must be non-nil")
            return
        }
        let stopCompleteExpectation = XCTestExpectation(description: "Wait for stop/teardown to complete")
        context.async {
            state.clientHarness.stop()
            state.serverHarness.stop()
            state.serverDatagramHarness?.stop()
            state.clientHarness.teardown()
            state.serverHarness.teardown()
            state.serverDatagramHarness?.teardown()
            stopCompleteExpectation.fulfill()
            self.state = nil
        }
        wait(for: [stopCompleteExpectation], timeout: 5.0)
    }

    // Installs a callback on the client and server bridge that fires passing the raw first byte to the
    // caller for a short header packet.  Used to detect a spin bit passing between the client and server.
    func observeFirstByteForOutboundShortHeaderPacket(handler: @escaping (_ firstByte: UInt8) -> Void) {
        guard let state else { return }
        let observe: ((UInt8) -> Void) = { firstByte in
            guard (firstByte & 0xC0) == 0x40 else { return }
            handler(firstByte)
        }
        state.clientBridge.observeFirstByte = observe
        state.serverBridge.observeFirstByte = observe
    }

    func echoDataOnStream(
        dataGenerator: TestDataGenerator,
        streamIndex: Int,
        readChunkSize: Int = .max,
        timeout: TimeInterval = 5.0
    ) {
        guard let state else {
            XCTFail("State must be non-nil")
            return
        }

        guard state.clientHarness.upperHarnesses.count > streamIndex else {
            XCTFail("Stream index \(streamIndex) is out of bounds")
            return
        }

        let serverReadExpectation = XCTestExpectation(description: "Wait for server to read request")
        let clientReadExpectation = XCTestExpectation(description: "Wait for client to read response")

        let serverStreamExpectation = XCTestExpectation(description: "Wait for server to receive stream")
        let clientStreamHarness = state.clientHarness.upperHarnesses[streamIndex]

        var serverStreamHarness: StreamUpperHarness? = nil

        // Set up waiting for a server stream
        context.async {
            state.serverHarness.waitForNewFlow {
                guard let serverStream = state.serverHarness.upperHarnesses.last else {
                    serverStreamExpectation.fulfill()
                    return
                }
                serverStreamHarness = serverStream
                serverStreamExpectation.fulfill()
            }
        }

        // Write on the client stream
        context.async {
            var chunkCount = 1
            for dataChunk in dataGenerator {
                var writeResult = false
                if dataGenerator.numberOfBlocks == chunkCount && dataGenerator.sendFIN {
                    writeResult = clientStreamHarness.write(dataChunk, sendFIN: true)
                } else {
                    writeResult = clientStreamHarness.write(dataChunk)
                }
                XCTAssertTrue(writeResult)
                chunkCount += 1
            }
        }

        // Wait for the server stream
        wait(for: [serverStreamExpectation], timeout: timeout)
        XCTAssertNotNil(serverStreamHarness)
        guard let serverStreamHarness else { return }

        // Block for reading on the client
        var clientReadBytes = 0
        var clientReadHandler: ((Bool) -> Void)? = nil
        // The read handlers capture themselves: each re-registers via
        // `waitForInboundDataAvailable`, which stores the closure on the
        // harness's completions. Break the retain cycle.
        defer { clientReadHandler = nil }
        clientReadHandler = { hasData in
            defer {
                if hasData {
                    // Schedule a follow-on read
                    clientStreamHarness.waitForInboundDataAvailable { success in
                        clientReadHandler?(success)
                    }
                }
            }

            while let response = clientStreamHarness.read(upTo: readChunkSize) {
                do {
                    try dataGenerator.validate(at: clientReadBytes, data: response)
                } catch {
                    XCTFail("Client received data that failed to validate: \(error)")
                    clientReadExpectation.fulfill()
                    return
                }
                clientReadBytes += response.count
            }

            if clientReadBytes >= dataGenerator.totalSize {
                if dataGenerator.sendFIN {
                    let receivedFIN = clientStreamHarness.receivedFIN
                    XCTAssertTrue(receivedFIN, "Client failed to receive FIN from server")
                }
                clientReadExpectation.fulfill()
                return
            }
        }

        // Block for reading on the server
        var serverReadBytes = 0
        var serverReadHandler: ((Bool) -> Void)? = nil
        defer { serverReadHandler = nil }
        serverReadHandler = { hasData in
            defer {
                if hasData {
                    // Schedule a follow-on read
                    serverStreamHarness.waitForInboundDataAvailable { success in
                        serverReadHandler?(success)
                    }
                }
            }

            while let response = serverStreamHarness.read() {
                do {
                    try dataGenerator.validate(at: serverReadBytes, data: response)
                } catch {
                    XCTFail("Server received data that failed to validate: \(error)")
                    serverReadExpectation.fulfill()
                    return
                }
                serverReadBytes += response.count

                let receivedFIN = serverStreamHarness.receivedFIN
                let writeResult = serverStreamHarness.write(response, sendFIN: receivedFIN)
                XCTAssertTrue(writeResult, "Server failed send response")
            }

            if serverReadBytes >= dataGenerator.totalSize {
                if dataGenerator.sendFIN {
                    let receivedFIN = serverStreamHarness.receivedFIN
                    XCTAssertTrue(receivedFIN, "Server failed to receive FIN from client")
                }
                if serverStreamHarness.receivedFIN {
                    serverStreamHarness.stop()
                }
                serverReadExpectation.fulfill()
                return
            }
        }

        context.async {
            serverReadHandler?(true)
            clientReadHandler?(true)
        }

        wait(for: [serverReadExpectation], timeout: timeout)
        wait(for: [clientReadExpectation], timeout: timeout)

        // If FINs are sent, also ensure that the streams move to disconnected
        if dataGenerator.sendFIN {
            let clientDisconnectedExpectation = XCTestExpectation(description: "Wait for client stream to close")
            let serverDisconnectedExpectation = XCTestExpectation(description: "Wait for server stream to close")
            context.async {
                clientStreamHarness.waitForDisconnected {
                    clientDisconnectedExpectation.fulfill()
                }
                serverStreamHarness.waitForDisconnected {
                    serverDisconnectedExpectation.fulfill()
                }
            }
            wait(for: [clientDisconnectedExpectation], timeout: timeout)
            wait(for: [serverDisconnectedExpectation], timeout: timeout)
        }
    }

    private func echoDatagrams(
        dataGenerator: TestDataGenerator,
        datagramFlow: DatagramUpperHarness,
        timeout: TimeInterval = 5.0
    ) {
        guard let state else {
            XCTFail("State must be non-nil")
            return
        }

        guard let serverDatagramHarness = state.serverDatagramHarness else {
            XCTFail("Server datagram harness must be non-nil")
            return
        }

        let serverReadExpectation = XCTestExpectation(description: "Wait for server to read request")
        let clientReadExpectation = XCTestExpectation(description: "Wait for client to read response")

        let serverDatagramFlowExpectation = XCTestExpectation(description: "Wait for server to receive stream")
        let clientDatagramFlow = datagramFlow

        var serverDatagramFlow: DatagramUpperHarness? = nil

        // Set up waiting for a server flow
        context.async {
            serverDatagramHarness.waitForNewFlow {
                guard let serverFlow = serverDatagramHarness.upperHarnesses.last else {
                    serverDatagramFlowExpectation.fulfill()
                    return
                }
                serverDatagramFlow = serverFlow
                serverDatagramFlowExpectation.fulfill()
            }
        }

        // Write on the client flow
        context.async {
            var chunkCount = 1
            for dataChunk in dataGenerator {
                let writeResult = clientDatagramFlow.write(dataChunk)
                XCTAssertTrue(writeResult)
                chunkCount += 1
            }
        }

        // Wait for the server stream
        wait(for: [serverDatagramFlowExpectation], timeout: timeout)
        XCTAssertNotNil(serverDatagramFlow)
        guard let serverDatagramFlow else { return }

        // Block for reading on the client
        var clientReadBytes = 0
        var clientReadHandler: ((Bool) -> Void)? = nil
        // The read handlers capture themselves: each re-registers via
        // `waitForInboundDataAvailable`, which stores the closure on the
        // harness's completions. Break the retain cycle.
        defer { clientReadHandler = nil }
        clientReadHandler = { hasData in
            defer {
                if hasData {
                    // Schedule a follow-on read
                    clientDatagramFlow.waitForInboundDataAvailable { success in
                        clientReadHandler?(success)
                    }
                }
            }

            while let response = clientDatagramFlow.read() {
                do {
                    try dataGenerator.validate(at: clientReadBytes, data: response)
                } catch {
                    XCTFail("Client received data that failed to validate: \(error)")
                    clientReadExpectation.fulfill()
                    return
                }
                clientReadBytes += response.count
            }

            if clientReadBytes >= dataGenerator.totalSize {
                clientReadExpectation.fulfill()
                return
            }
        }

        // Block for reading on the server
        var serverReadBytes = 0
        var serverReadHandler: ((Bool) -> Void)? = nil
        defer { serverReadHandler = nil }
        serverReadHandler = { hasData in
            defer {
                if hasData {
                    // Schedule a follow-on read
                    serverDatagramFlow.waitForInboundDataAvailable { success in
                        serverReadHandler?(success)
                    }
                }
            }

            while let response = serverDatagramFlow.read() {
                do {
                    try dataGenerator.validate(at: serverReadBytes, data: response)
                } catch {
                    XCTFail("Server received data that failed to validate: \(error)")
                    serverReadExpectation.fulfill()
                    return
                }
                serverReadBytes += response.count

                let writeResult = serverDatagramFlow.write(response)
                XCTAssertTrue(writeResult, "Server failed send response")
            }

            if serverReadBytes >= dataGenerator.totalSize {
                serverReadExpectation.fulfill()
                return
            }
        }

        context.async {
            serverReadHandler?(true)
            clientReadHandler?(true)
        }

        wait(for: [serverReadExpectation], timeout: timeout)
        wait(for: [clientReadExpectation], timeout: timeout)
    }

    private func validateStreamMetadata(
        index clientStreamIndex: Int,
        datagram: Bool
    ) {
        guard let state else {
            XCTFail("State must be non-nil")
            return
        }

        guard state.clientHarness.upperHarnesses.count > clientStreamIndex else {
            XCTFail("Client stream index \(clientStreamIndex) is out of bounds")
            return
        }

        let clientStreamHarness = state.clientHarness.upperHarnesses[clientStreamIndex]

        let metadata: ProtocolMetadata<QUICProtocol>? = clientStreamHarness.getMetadata()
        XCTAssertNotNil(metadata)
        if let metadata {
            let streamID = metadata.streamID
            XCTAssertNotNil(streamID)
            if let streamID {
                Logger.test.debug("Opened stream ID \(streamID)")
                XCTAssertEqual(streamID, UInt64(clientStreamIndex * 4))
            }
            if datagram {
                XCTAssertTrue(metadata.isDatagram)
            } else {
                XCTAssertTrue(metadata.isBidirectional)
            }
        }

        guard state.serverHarness.upperHarnesses.count > clientStreamIndex else {
            XCTFail("Server stream index \(clientStreamIndex) is out of bounds")
            return
        }
        let serverHarness = state.serverHarness.upperHarnesses[clientStreamIndex]
        let serverMetadata: ProtocolMetadata<QUICProtocol>? = serverHarness.getMetadata()
        XCTAssertNotNil(serverMetadata)
        if let serverMetadata {
            let streamID = serverMetadata.streamID
            XCTAssertNotNil(streamID)
            if let streamID {
                Logger.test.debug("Opened stream ID \(streamID)")
                XCTAssertEqual(streamID, UInt64(clientStreamIndex * 4))
            }
            if datagram {
                XCTAssertTrue(serverMetadata.isDatagram)
            } else {
                XCTAssertTrue(serverMetadata.isBidirectional)
            }
        }
    }

    func runQUICTest(
        identifier: String = #function,
        streamCount: Int = 0,
        datagram: Bool = false,
        dataBlock: [UInt8]? = nil,
        expectHandshakeError: NetworkError? = nil,
        blockSize: Int = 0,
        blockCount: Int = 0,
        sendFIN: Bool = true,
        clientLinkDelay: NetworkDuration = .zero,
        serverLinkDelay: NetworkDuration = .zero,
        clientDrops: DatagramDrops? = nil,
        serverDrops: DatagramDrops? = nil,
        clientReadChunkSize: Int = Int.max,
        timeout: TimeInterval = 5.0,
        applicationError: UInt64? = nil,
        applicationErrorReason: String? = nil,
        sendApplicationCloseError: Bool = false,
        sendStreamResetError: Bool = false,
        sendStreamStopSendingError: Bool = false,
        verifyResetStreamHalfClosure: Bool = false,
        shouldMarkIdle: Bool = false,
        clientOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        sendMaxStreamUpdate: Bool = false,
        validateMetrics: Bool = false,
        extraServerCIDs: [(QUICConnectionID, QUICStatelessResetToken)] = .init(),
        afterHandshake: ((QUICTestHarness) -> Void)? = nil,  // Block to run after handshake is complete
        afterData: ((QUICTestHarness) -> Void)? = nil,  // Block to run after handshake is complete
    ) {
        // Start with the handshake
        Logger.test.debug("Test phase: Handshake")

        var sendFIN = sendFIN
        if datagram {
            sendFIN = false
        }

        do {
            try quicHandshake(
                datagram: datagram,
                expectHandshakeError: expectHandshakeError,
                clientLinkDelay: clientLinkDelay,
                serverLinkDelay: serverLinkDelay,
                clientDrops: clientDrops,
                serverDrops: serverDrops,
                timeout: timeout,
                clientOptions: clientOptions,
                serverOptions: serverOptions
            )
        } catch {
            if expectHandshakeError == nil {
                XCTFail("Handshake needs to complete to proceed")
            }
            return
        }

        if !extraServerCIDs.isEmpty {
            let extraCIDExpectation = XCTestExpectation(description: "Wait for QUIC CIDs to be delivered")
            context.async {
                let serverMetadata: ProtocolMetadata<QUICProtocol>? = self.state?.serverHarness.getMetadata()
                XCTAssertNotNil(serverMetadata)
                if let serverMetadata {
                    let activeConnectionIDLimit = serverMetadata.connectionMetadata?.activeConnectionIDLimit
                    XCTAssertNotNil(activeConnectionIDLimit)
                    if let activeConnectionIDLimit {
                        XCTAssertGreaterThanOrEqual(activeConnectionIDLimit, extraServerCIDs.count)
                    }
                }

                for (cid, resetToken) in extraServerCIDs {
                    self.state?.serverHarness.invokeApplicationEvent(
                        .init(quicEvent: .announceNewInboundConnectionID(cid, statelessResetToken: resetToken))
                    )
                }

                XCTAssertEqual(self.state?.serverHarness.newInboundCIDEventCount, extraServerCIDs.count)
                extraCIDExpectation.fulfill()
            }
            wait(for: [extraCIDExpectation], timeout: 5.0)
        }

        if let afterHandshake {
            afterHandshake(self)
        }

        if !datagram {
            // Transfer stream data
            var streamCount = streamCount
            if streamCount == 0 && (dataBlock != nil || blockCount > 0) {
                // If there is some data to transfer, make sure there is at least one stream
                streamCount = 1
            }

            for index in 0..<streamCount {
                Logger.test.debug("Test phase: Data Transfer (flow index \(index))")

                let addedStreamHandler = createNewStream(
                    identifier: "C\(index+1)",
                    quicOptions: clientOptions
                )
                XCTAssertNotNil(addedStreamHandler)

                var generator: TestDataGenerator? = nil
                if let dataBlock {
                    generator = TestDataGenerator(singleDataBlock: dataBlock, sendFIN: sendFIN)
                } else if blockSize > 0, blockCount > 0 {
                    generator = TestDataGenerator(
                        blockSize: blockSize,
                        numberOfBlocks: blockCount,
                        uniqueBits: UInt8(clamping: index),
                        sendFIN: sendFIN
                    )
                }

                if let generator {
                    echoDataOnStream(
                        dataGenerator: generator,
                        streamIndex: index,
                        readChunkSize: clientReadChunkSize,
                        timeout: timeout
                    )
                } else {
                    XCTAssertTrue(dataBlock == nil && blockSize == 0 && blockCount == 0)
                }

                // When the client is setup an inputHandler (stream) is setup right
                // away so there will always be metadata available on the client.
                // On the server side the inputHandler (stream) is only created when
                // handleNewFlow is called in NewFlowHandler.
                // The server will only call handleNewFlow for newly create client streams
                // sending data, not for the handshake.
                let metadataExpectation = XCTestExpectation(description: "Wait for QUIC metadata to be fetched")
                context.async {
                    self.validateStreamMetadata(index: index, datagram: datagram)
                    metadataExpectation.fulfill()
                }
                wait(for: [metadataExpectation], timeout: 2.0)

                // Detect if the server needs to send a MAX_STREAMS update
                if sendMaxStreamUpdate {
                    guard state?.serverHarness.upperHarnesses.count ?? 0 > index else {
                        XCTFail("Server application layer index \(index) is out of bounds")
                        return
                    }
                    let maxStreamExpectation = XCTestExpectation(description: "Wait for QUIC max stream to be fetched")
                    context.async {
                        let serverHarness = self.state?.serverHarness.upperHarnesses[index]
                        if let serverHarness,
                            let serverMetadata: ProtocolMetadata<QUICProtocol> = serverHarness.getMetadata()
                        {
                            guard
                                let remoteMaxStreamsForPeer = serverMetadata.connectionMetadata?
                                    .getRemoteMaxStreamsBidirectional()
                            else {
                                XCTFail("Server application layer index \(index) is out of bounds")
                                return
                            }
                            // Trigger the update on remoteMaxStreams - 2 so the frame can be processed on the next stream creation
                            if UInt64(index) == (remoteMaxStreamsForPeer - 2) {
                                // Set the new max streams limit to the number of streams the client wants to open
                                serverMetadata.connectionMetadata?.setLocalMaxStreamsBidirectional(
                                    localMaxStreamsBidirectional: UInt64(streamCount)
                                )
                            }
                        }
                    }
                    maxStreamExpectation.fulfill()
                    wait(for: [maxStreamExpectation], timeout: 2.0)
                }
            }

            // Count the final number of streams in each direction
            if let state {
                XCTAssertEqual(state.clientHarness.upperHarnesses.count, streamCount)
                XCTAssertEqual(state.serverHarness.upperHarnesses.count, streamCount)
                for serverUpperHarness in state.serverHarness.upperHarnesses {
                    XCTAssertTrue(
                        serverUpperHarness.receivedConnected,
                        "Server input handler should have returned true"
                    )
                }
            }
        } else {
            Logger.test.debug("Test phase: Data Transfer (Datagram)")

            // Datagram case
            let datagramFlow = createNewDatagramFlow(
                identifier: identifier,
                quicOptions: clientOptions
            )
            XCTAssertNotNil(datagramFlow)
            guard let datagramFlow else { return }

            var generator: TestDataGenerator? = nil
            if let dataBlock {
                generator = TestDataGenerator(singleDataBlock: dataBlock, sendFIN: sendFIN)
            } else if blockSize > 0, blockCount > 0 {
                generator = TestDataGenerator(blockSize: blockSize, numberOfBlocks: blockCount, uniqueBits: 0)
            }

            if let generator {
                echoDatagrams(
                    dataGenerator: generator,
                    datagramFlow: datagramFlow,
                    timeout: timeout
                )
            } else {
                XCTAssertTrue(dataBlock == nil && blockSize == 0 && blockCount == 0)
            }
        }

        if let afterData {
            afterData(self)
        }

        if validateMetrics {
            if let serverHarness = state?.serverHarness, let clientHarness = state?.clientHarness {
                var clientReports: NetworkMetrics?
                var serverReports: NetworkMetrics?
                let snapshotExpectation = XCTestExpectation(description: "Wait for QUIC connection to receive metrics")
                context.async {
                    clientReports = clientHarness.getMetrics(requestedNetworkMetric: .dataTransferSnapshot)
                    serverReports = serverHarness.getMetrics(requestedNetworkMetric: .dataTransferSnapshot)
                    XCTAssertNotNil(clientReports)
                    XCTAssertNotNil(serverReports)
                    snapshotExpectation.fulfill()
                }
                wait(for: [snapshotExpectation], timeout: 2.0)
                // Now validate the protocol establishment report
                clientReports = nil
                serverReports = nil
                let protocolEstablishmentReportExpectation = XCTestExpectation(
                    description: "Wait for QUIC connection to receive metrics"
                )
                context.async {
                    clientReports = clientHarness.getMetrics(requestedNetworkMetric: .protocolEstablishmentReports)
                    serverReports = serverHarness.getMetrics(requestedNetworkMetric: .protocolEstablishmentReports)
                    XCTAssertNotNil(clientReports)
                    XCTAssertNotNil(serverReports)
                    protocolEstablishmentReportExpectation.fulfill()
                }
                wait(for: [protocolEstablishmentReportExpectation], timeout: 2.0)
            } else {
                XCTFail("There should be saved server and client harnesses")
            }
        }

        // If applicationError is present, act upon that here
        if let applicationError, let applicationErrorReason {
            if let serverHarness = state?.serverHarness, let clientHarness = state?.clientHarness {
                let errorExpectation = XCTestExpectation(description: "Wait for QUIC connection to receive error")
                var networkError: NetworkError?
                serverHarness.waitForError { code in
                    guard let code else {
                        XCTAssertNotNil(code, "Error must be invoked with a valid error code")
                        errorExpectation.fulfill()
                        return
                    }
                    networkError = code
                    errorExpectation.fulfill()
                }
                context.async {
                    if sendApplicationCloseError {
                        clientHarness.stop(
                            error: .init(quicApplicationError: applicationError, reason: applicationErrorReason)
                        )
                    } else {
                        if let transportError = QUICTransportError(applicationError, applicationErrorReason) {
                            clientHarness.stop(error: .init(quicTransportError: transportError))
                        }
                    }
                }
                wait(for: [errorExpectation], timeout: 2.0)
                XCTAssertNotNil(networkError, "Application error should be set")
                // NOTE that converting to Int32 here should be safe for applicationError because these values should be lower in value
                if sendApplicationCloseError {
                    XCTAssertEqual(
                        networkError?.quicApplicationError,
                        Int64(applicationError),
                        "Server should be taken down by connection close error"
                    )
                    XCTAssertEqual(
                        UInt64(state?.serverInstance.applicationCloseError?.code ?? 0),
                        applicationError,
                        "APPLICATION_CLOSE error codes do not match"
                    )
                    XCTAssertEqual(
                        state?.serverInstance.applicationCloseError?.reason,
                        applicationErrorReason,
                        "APPLICATION_CLOSE error reasons do not match"
                    )
                } else {
                    XCTAssertEqual(
                        networkError?.quicTransportError,
                        Int64(applicationError),
                        "Server should be taken down by connection close error"
                    )
                    XCTAssertEqual(
                        UInt64(state?.serverInstance.closeError?.code ?? 0),
                        applicationError,
                        "CONNECTION_CLOSE error codes do not match"
                    )
                    XCTAssertEqual(
                        state?.serverInstance.closeError?.reason,
                        applicationErrorReason,
                        "CONNECTION_CLOSE error reasons do not match"
                    )
                }

            } else {
                XCTFail("There should be saved server input handlers")
            }
        }

        let testStreamError = (sendStreamResetError || sendStreamStopSendingError)
        if let applicationError, testStreamError {
            if let serverUpperHarness = state?.serverHarness.upperHarnesses.first,
                let clientUpperHarness = state?.clientHarness.upperHarnesses.first
            {
                // Sends error code with STOP_SENDING / RESET_STREAM
                let errorExpectation = XCTestExpectation(description: "Wait for ECONNRESET error")
                var networkError: NetworkError?
                // Set up error handler before triggering the error
                let errorBlock: ((NetworkError?) -> Void) = { code in
                    guard let code,
                        let applicationErrorCode = code.quicApplicationError
                    else {
                        XCTAssertNotNil(code, "Error must be invoked with a valid error code")
                        errorExpectation.fulfill()
                        return
                    }
                    networkError = code
                    XCTAssertEqual(
                        UInt64(applicationErrorCode),
                        applicationError,
                        "Application error codes do not match"
                    )

                    if let metadata: ProtocolMetadata<QUICProtocol> = serverUpperHarness.getMetadata(),
                        let errorCode = metadata.applicationError
                    {
                        // Match the sent error in the metadata
                        XCTAssertEqual(errorCode, applicationError, "Application error codes do not match")
                    } else {
                        XCTFail("There should input handler metadata to read application error from")
                    }
                    errorExpectation.fulfill()
                }
                serverUpperHarness.waitForInboundAborted(completion: errorBlock)
                serverUpperHarness.waitForOutboundAborted(completion: errorBlock)

                context.async {
                    if sendStreamResetError {
                        clientUpperHarness.abortOutbound(
                            error: .init(quicApplicationError: applicationError, reason: applicationErrorReason)
                        )
                    } else if sendStreamStopSendingError {
                        clientUpperHarness.abortInbound(
                            error: .init(quicApplicationError: applicationError, reason: applicationErrorReason)
                        )
                    }
                }
                wait(for: [errorExpectation], timeout: 4.0)
                XCTAssertNotNil(networkError, "Application error should be set")

                if verifyResetStreamHalfClosure {
                    XCTAssertFalse(
                        serverUpperHarness.receivedDisconnected,
                        "Server stream must not be disconnected — only the read side was reset"
                    )

                    let halfClosureExpectation = XCTestExpectation(
                        description: "Client reads server response after RESET_STREAM"
                    )
                    let halfClosurePayload = Array("half-closure-test".utf8)
                    context.async {
                        clientUpperHarness.waitForInboundDataAvailable { _ in
                            let data = clientUpperHarness.read()
                            XCTAssertEqual(
                                data,
                                halfClosurePayload,
                                "Client should receive the data written by the server"
                            )
                            halfClosureExpectation.fulfill()
                        }
                        let writeResult = serverUpperHarness.write(halfClosurePayload)
                        XCTAssertTrue(writeResult, "Server should be able to write after peer's RESET_STREAM")
                    }
                    wait(for: [halfClosureExpectation], timeout: 4.0)
                }
            } else {
                XCTFail("There should be saved server input handlers")
            }
        }

        if shouldMarkIdle {
            markIdle()
        }

        Logger.test.debug("Test phase: Termination")
        stop()
    }

    enum AbortKind {
        case reset
        case stopSending
    }

    /// When a STREAM frame creates a new inbound flow and an abort frame
    /// (RESET_STREAM / STOP_SENDING) targeting that same flow arrives in the
    /// same packet, the abort event is queued through the flow's upper
    /// linkage — which is still `.none` because the new-flow event hasn't been
    /// processed yet. The abort event is queued and delivered later
    ///
    /// - Parameter abortKind: `.reset` to send RESET_STREAM (causes
    ///   `inboundAborted`), `.stopSending` to send STOP_SENDING (causes
    ///   `outboundAborted`).
    func runQUICNewStreamWithImmediateAbort(
        abortKind: AbortKind,
        applicationError: UInt64 = 42,
        timeout: TimeInterval = 4.0
    ) {
        do {
            try quicHandshake()
        } catch {
            XCTFail("Handshake failed: \(error)")
            return
        }

        guard let clientStream = createNewStream(identifier: "C1") else {
            XCTFail("Failed to create client stream")
            return
        }

        let serverFlowExpectation = XCTestExpectation(description: "Server sees new flow")
        let serverAbortExpectation = XCTestExpectation(description: "Server sees abort event")
        var serverStream: StreamUpperHarness?

        context.async {
            self.state?.serverHarness.waitForNewFlow {
                guard let stream = self.state?.serverHarness.upperHarnesses.last else {
                    XCTFail("Server flow missing")
                    serverFlowExpectation.fulfill()
                    return
                }
                serverStream = stream
                switch abortKind {
                case .reset:
                    stream.waitForInboundAborted { error in
                        XCTAssertNotNil(error, "Server should see inbound abort")
                        XCTAssertTrue(
                            stream.receivedConnected,
                            "Connected event must drain before the abort event"
                        )
                        serverAbortExpectation.fulfill()
                    }
                case .stopSending:
                    stream.waitForOutboundAborted { error in
                        XCTAssertNotNil(error, "Server should see outbound abort")
                        XCTAssertTrue(
                            stream.receivedConnected,
                            "Connected event must drain before the abort event"
                        )
                        serverAbortExpectation.fulfill()
                    }
                }
                serverFlowExpectation.fulfill()
            }
        }

        // Send data + abort in tight succession so they coalesce into the
        // same outbound packet. The server then processes the STREAM frame
        // (creating the flow) and the abort frame (targeting that flow) in
        // one pass.
        context.async {
            _ = clientStream.write(Array("hello".utf8))
            switch abortKind {
            case .reset:
                clientStream.abortOutbound(error: .init(quicApplicationError: applicationError))
            case .stopSending:
                clientStream.abortInbound(error: .init(quicApplicationError: applicationError))
            }
        }

        wait(for: [serverFlowExpectation], timeout: timeout)
        wait(for: [serverAbortExpectation], timeout: timeout)

        _ = serverStream  // silence unused-warning; harness keeps strong ref
        stop()
    }

    /// `RESET_STREAM` is the very first frame the server sees for a fresh
    /// peer-initiated bidi stream — no preceding `STREAM` frame. The server
    /// must still create the inbound flow and deliver the inbound-aborted
    /// event for the reset to be observable end-to-end.
    func runQUICResetStreamFirstFrameOnNewStream(
        applicationError: UInt64 = 42,
        timeout: TimeInterval = 4.0
    ) {
        do {
            try quicHandshake()
        } catch {
            XCTFail("Handshake failed: \(error)")
            return
        }

        guard let clientStream = createNewStream(identifier: "C1") else {
            XCTFail("Failed to create client stream")
            return
        }

        let serverFlowExpectation = XCTestExpectation(description: "Server sees new flow")
        let serverAbortExpectation = XCTestExpectation(description: "Server sees inbound abort event")
        var serverStream: StreamUpperHarness?

        context.async {
            self.state?.serverHarness.waitForNewFlow {
                guard let stream = self.state?.serverHarness.upperHarnesses.last else {
                    XCTFail("Server flow missing")
                    serverFlowExpectation.fulfill()
                    return
                }
                serverStream = stream
                stream.waitForInboundAborted { error in
                    XCTAssertNotNil(error, "Server should see inbound abort from RESET_STREAM")
                    XCTAssertEqual(
                        error?.quicApplicationError,
                        Int64(applicationError),
                        "Application error code should be propagated from RESET_STREAM"
                    )
                    serverAbortExpectation.fulfill()
                }
                serverFlowExpectation.fulfill()
            }
        }

        // Reset with no prior write so the only frame the client emits for
        // this stream id is RESET_STREAM. There is no STREAM frame to
        // stride-create the flow ahead of the reset.
        context.async {
            clientStream.abortOutbound(error: .init(quicApplicationError: applicationError))
        }

        wait(for: [serverFlowExpectation], timeout: timeout)
        wait(for: [serverAbortExpectation], timeout: timeout)

        _ = serverStream  // silence unused-warning; harness keeps strong ref
        stop()
    }

    func runQUICServerTestForPendingBidirectional(
        identifier: String = #function,
        dataBlock: [UInt8],
        timeout: TimeInterval = 5.0,
        clientOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options()
    ) {
        XCTAssertNoThrow(
            try quicHandshake(
                timeout: timeout,
                clientOptions: clientOptions,
                serverOptions: serverOptions
            )
        )

        // Create 8 streams, just up to the limit
        for index in 0..<8 {
            let addedStreamHandler = createNewStream(identifier: "C\(index+1)")
            XCTAssertNotNil(addedStreamHandler, "Stream \(index) should be created successfully")
            let generator = TestDataGenerator(singleDataBlock: dataBlock)
            echoDataOnStream(
                dataGenerator: generator,
                streamIndex: index,
                timeout: timeout
            )
        }

        // Send MAX_STREAMS update from the server to allow more streams and start the pending stream above
        let maxStreamsUpdateExpectation = XCTestExpectation(description: "Wait for MAX_STREAMS update to be processed")
        context.async {
            // Create a new stream by hand, this should put us over the remote max streams limit
            var parameters = Parameters()
            parameters.context = self.context
            let options = QUICProtocol.options()
            options.setLogID(
                prefix: identifier,
                parent: "",
                protocolLogIDNumber: 1
            )
            options.setProtocolInstance(self.state!.clientInstance.reference)
            parameters.defaultStack.transport = .custom(options)
            let path = PathProperties(parameters: parameters)

            let listenerLinkage = StreamListenerLinkage(reference: self.state!.clientInstance.reference)
            let ninthStream = StreamUpperHarness(
                identifier: identifier,
                local: self.clientEndpoint,
                remote: self.serverEndpoint,
                parameters: parameters,
                path: path,
                context: self.context,
                listenerProtocol: listenerLinkage
            )
            XCTAssertNotNil(ninthStream, "Failed to attach new QUIC stream")
            guard let ninthStream else {
                return
            }
            // This stream should be added as pending because its over the stream limit
            ninthStream.start()
            self.state?.clientHarness.upperHarnesses.append(ninthStream)
            Logger.test.debug("Stream 9 should not be in pending state")

            if let serverHandler = self.state?.serverHarness.upperHarnesses.first,
                let serverMetadata: ProtocolMetadata<QUICProtocol> = serverHandler.getMetadata()
            {
                serverMetadata.connectionMetadata?.setLocalMaxStreamsBidirectional(localMaxStreamsBidirectional: 16)
                maxStreamsUpdateExpectation.fulfill()
            }
        }
        wait(for: [maxStreamsUpdateExpectation], timeout: timeout)

        // Send on the 9th stream now
        if state?.clientHarness.upperHarnesses.count ?? 0 >= 8 {
            let generator = TestDataGenerator(singleDataBlock: dataBlock)
            echoDataOnStream(
                dataGenerator: generator,
                streamIndex: 8,  // Should be the stream created above
                timeout: timeout
            )
        }
        XCTAssertEqual(state?.clientHarness.upperHarnesses.count, 9, "Should have 9 streams total")
        stop()
    }

    func runQUICServerTestWithUnidirectionalStreams(
        identifier: String = #function,
        streamCount: Int = 1,
        dataBlock: [UInt8],
        timeout: TimeInterval = 5.0,
        streamIDsToValidate: [UInt64] = [],
        clientOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        sendMaxStreamUpdate: Bool = false
    ) {
        // NOTE: This test was intended to be used with small data blocks, for large data blocks use TestDataGenerator
        Logger.test.debug("Test phase: Handshake")

        clientOptions.isUnidirectional = true
        serverOptions.isUnidirectional = true

        XCTAssertNoThrow(
            try quicHandshake(
                timeout: timeout,
                clientOptions: clientOptions,
                serverOptions: serverOptions
            )
        )

        // There will be one input handler created on the client side already so start at 1 here.
        // For unidirectional streams, write on the client and validate the read on the server
        // Do this for each unidirectional stream one at a time so we do not corrupt the nextInputPacket
        for index in 0..<streamCount {
            let clientStream = createNewStream(
                identifier: "C\(index+1)",
                quicOptions: clientOptions
            )
            XCTAssertNotNil(clientStream)
            let generator = TestDataGenerator(singleDataBlock: dataBlock)
            let clientWriteExpectation = XCTestExpectation(description: "Wait for client write \(index) to complete")
            context.async {
                Logger.test.debug("Client writing data: \(dataBlock)")
                let writeResult = clientStream?.write(generator.block)
                XCTAssertNotNil(writeResult, "writeResult should not be nil")
                XCTAssertTrue(writeResult!, "Client write failed for stream \(index)")
                clientWriteExpectation.fulfill()
            }
            wait(for: [clientWriteExpectation], timeout: timeout)

            // Wait for the server side stream to pass through handleNewFlow and become connected
            let serverHandlerExpectation = XCTestExpectation(description: "Wait for server input handler \(index)")
            func checkForServerHandler() {
                if state?.serverHarness.upperHarnesses.count ?? 0 > index {
                    let serverHandler = state?.serverHarness.upperHarnesses[index]
                    if let serverHandler, serverHandler.receivedConnected {
                        serverHandlerExpectation.fulfill()
                        return
                    }
                }
                context.async {
                    checkForServerHandler()
                }
            }
            context.async {
                checkForServerHandler()
            }
            wait(for: [serverHandlerExpectation], timeout: timeout)

            // The server stream read needs to be processed and validated before continuing on to the next client write
            let serverReadExpectation = XCTestExpectation(description: "Wait for server read \(index) to complete")
            let serverHandlerIndex = index
            context.async {
                func attemptServerRead() {
                    guard serverHandlerIndex < self.state?.serverHarness.upperHarnesses.count ?? 0 else {
                        self.context.async {
                            attemptServerRead()
                        }
                        return
                    }
                    let serverUpperHarness = self.state?.serverHarness.upperHarnesses[serverHandlerIndex]
                    if let serverUpperHarness, let response = serverUpperHarness.read() {
                        Logger.test.debug("Server read data: \(response)")
                        do {
                            try generator.validate(at: 0, data: response)
                            // If validated without error consider the read good
                        } catch {
                            XCTFail("Error caught while validating data at index \(index), error: \(error)")
                        }
                        serverReadExpectation.fulfill()
                    } else {
                        self.context.async {
                            attemptServerRead()
                        }
                    }
                }
                attemptServerRead()
            }
            wait(for: [serverReadExpectation], timeout: timeout)

            let metadataCheckExpectation = XCTestExpectation(description: "Wait to check metadata")
            context.async {
                if streamIDsToValidate.count > 0 {
                    let streamIDAtIndex = streamIDsToValidate[index]
                    let metadata: ProtocolMetadata<QUICProtocol>? = clientStream?.getMetadata()
                    XCTAssertNotNil(metadata)
                    if let metadata {
                        let streamID = metadata.streamID
                        XCTAssertNotNil(streamID)
                        if let streamID {
                            XCTAssertEqual(
                                streamID,
                                streamIDAtIndex,
                                "Unidirectional stream did not match, expected: \(streamIDAtIndex), received: \(streamID)"
                            )
                        }
                    }
                }
                // Detect if the server needs to send a MAX_STREAMS update
                if sendMaxStreamUpdate {
                    guard self.state?.serverHarness.upperHarnesses.count ?? 0 > index else {
                        XCTFail("Server application layer index \(index) is out of bounds")
                        return
                    }
                    let serverHarness = self.state?.serverHarness.upperHarnesses[index]
                    if let serverHarness,
                        let serverMetadata: ProtocolMetadata<QUICProtocol> = serverHarness.getMetadata()
                    {
                        guard
                            let remoteMaxStreamsForPeer = serverMetadata.connectionMetadata?
                                .getRemoteMaxStreamsUnidirectional()
                        else {
                            XCTFail("Server application layer index \(index) is out of bounds")
                            return
                        }
                        // Trigger the update on remoteMaxStreams - 2 so the frame can be processed on the next stream creation
                        if UInt64(index) == (remoteMaxStreamsForPeer - 2) {
                            // Set the new max streams limit to the number of streams the client wants to open
                            serverMetadata.connectionMetadata?.setLocalMaxStreamsUnidirectional(
                                localMaxStreamsUnidirectional: UInt64(streamCount)
                            )
                        }
                    }
                }

                metadataCheckExpectation.fulfill()
            }
            wait(for: [metadataCheckExpectation], timeout: timeout)
        }
        XCTAssertEqual(
            state?.serverHarness.upperHarnesses.count,
            streamCount,
            "Expected \(streamCount) server input handlers, but got \(state?.serverHarness.upperHarnesses.count ?? 0)"
        )

        Logger.test.debug("Test phase: Termination")
        stop()
    }

    func runQUICServerInitiatedUnidirectionalStreams(
        identifier: String = #function,
        streamCount: Int = 1,
        dataBlock: [UInt8],
        timeout: TimeInterval = 5.0,
        streamIDsToValidate: [UInt64] = [],
        clientOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options()
    ) {
        // NOTE: This test was intended to be used with small data blocks, for large data blocks use TestDataGenerator

        clientOptions.isUnidirectional = true
        serverOptions.isUnidirectional = true

        XCTAssertNoThrow(
            try quicHandshake(
                timeout: timeout,
                clientOptions: clientOptions,
                serverOptions: serverOptions
            )
        )

        for index in 0..<streamCount {
            let addedStreamHandler = createNewStream(
                identifier: "C\(index+1)",
                quicOptions: serverOptions,
                serverInitiated: true
            )
            XCTAssertNotNil(addedStreamHandler)
        }
        guard let clientHarness = state?.clientHarness else {
            XCTFail("Failure to unwrap clientHarness")
            return
        }

        for (index, serverHarness) in state!.serverHarness.upperHarnesses.enumerated() {
            let generator = TestDataGenerator(singleDataBlock: dataBlock)
            let serverWriteExpectation = XCTestExpectation(description: "Wait for server write \(index) to complete")
            context.async {
                Logger.test.debug("Client writing data: \(dataBlock)")
                let writeResult = serverHarness.write(generator.block)
                XCTAssertTrue(writeResult, "Server write failed for stream \(index)")
                serverWriteExpectation.fulfill()
            }
            wait(for: [serverWriteExpectation], timeout: timeout)

            // Wait for the client side stream to pass through handleNewFlow and become connected
            let clientHandlerExpectation = XCTestExpectation(description: "Wait for client input handler \(index)")
            func checkForClientHandler() {
                if clientHarness.upperHarnesses.count > index {
                    let clientHandler = clientHarness.upperHarnesses[index]

                    if clientHandler.receivedConnected {
                        clientHandlerExpectation.fulfill()
                        return
                    }
                }
                context.async {
                    checkForClientHandler()
                }
            }
            context.async {
                checkForClientHandler()
            }
            wait(for: [clientHandlerExpectation], timeout: timeout)

            // The client stream read needs to be processed and validated before continuing on to the next server write
            let clientReadExpectation = XCTestExpectation(description: "Wait for client read \(index) to complete")
            let clientHandlerIndex = index
            context.async {
                func attemptClientRead() {
                    guard clientHandlerIndex < clientHarness.upperHarnesses.count else {
                        self.context.async {
                            attemptClientRead()
                        }
                        return
                    }
                    let clientUpperHarness = clientHarness.upperHarnesses[clientHandlerIndex]
                    if let response = clientUpperHarness.read() {
                        Logger.test.debug("Client read data: \(response)")
                        do {
                            try generator.validate(at: 0, data: response)
                            // If validated without error consider the read good
                        } catch {
                            XCTFail("Error caught while validating data at index \(index), error: \(error)")
                        }
                        clientReadExpectation.fulfill()
                    } else {
                        self.context.async {
                            attemptClientRead()
                        }
                    }
                }
                attemptClientRead()
            }
            wait(for: [clientReadExpectation], timeout: timeout)

            let metadataCheckExpectation = XCTestExpectation(description: "Wait to check metadata")
            context.async {
                if streamIDsToValidate.count > 0 {
                    let streamIDAtIndex = streamIDsToValidate[index]
                    let metadata: ProtocolMetadata<QUICProtocol>? = serverHarness.getMetadata()
                    XCTAssertNotNil(metadata)
                    if let metadata {
                        let streamID = metadata.streamID
                        XCTAssertNotNil(streamID)
                        if let streamID {
                            XCTAssertEqual(
                                streamID,
                                streamIDAtIndex,
                                "Unidirectional stream did not match, expected: \(streamIDAtIndex), received: \(streamID)"
                            )
                        }
                    }
                }
                metadataCheckExpectation.fulfill()
            }
            wait(for: [metadataCheckExpectation], timeout: timeout)
        }
        XCTAssertEqual(
            clientHarness.upperHarnesses.count,
            streamCount,
            "Expected \(streamCount) client input handlers, but got \(clientHarness.upperHarnesses.count)"
        )

        Logger.test.debug("Test phase: Termination")
        stop()
    }

    func runQUICTestUnidirectionalAndBidirectionalStreams(
        identifier: String = #function,
        streamCount: Int = 1,
        dataBlock: [UInt8],
        timeout: TimeInterval = 5.0,
        streamIDsToValidate: [UInt64] = [],
        clientOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options()
    ) {

        XCTAssertNoThrow(
            try quicHandshake(
                timeout: timeout,
                clientOptions: clientOptions,
                serverOptions: serverOptions
            )
        )

        // Create one unidirectional stream and make a small write
        clientOptions.isUnidirectional = true
        let addedStreamHandler = createNewStream(
            identifier: "C1",
            quicOptions: clientOptions,
            serverInitiated: true
        )
        let clientWriteExpectation = XCTestExpectation(description: "Wait for client write to complete")
        context.async {
            Logger.test.debug("Client writing data: \(dataBlock)")
            let writeResult = addedStreamHandler?.write(dataBlock)
            XCTAssertNotNil(writeResult, "writeResult should not be nil")
            XCTAssertTrue(writeResult!, "Client write failed to write on the unidirectional stream")
            clientWriteExpectation.fulfill()
        }
        wait(for: [clientWriteExpectation], timeout: timeout)

        // Now create more bidirectional streams and write on them
        clientOptions.isUnidirectional = false

        for index in 1..<(streamCount + 1) {
            Logger.test.debug("Test phase: Data Transfer (flow index \(index))")

            let addedStreamHandler = createNewStream(
                identifier: "C\(index)",
                quicOptions: clientOptions
            )
            XCTAssertNotNil(addedStreamHandler)

            echoDataOnStream(
                dataGenerator: TestDataGenerator(singleDataBlock: dataBlock, sendFIN: true),
                streamIndex: index,
                readChunkSize: dataBlock.count,
                timeout: timeout
            )
        }

        Logger.test.debug("Test phase: Termination")
        stop()
    }

}
#endif
#endif
#endif
