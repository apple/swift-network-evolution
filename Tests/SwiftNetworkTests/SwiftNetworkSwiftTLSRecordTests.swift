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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkSwiftTLSRecordTests: NetTestCase {
    #if IMPORT_SWIFTTLS && canImport(SwiftTLS)
    // 10.0.0.20
    static let localIPv4Address: [UInt8] = [10, 0, 0, 20]

    // 10.0.0.117
    static let remoteIPv4Address: [UInt8] = [10, 0, 0, 117]

    var serverSigningKey = P256.Signing.PrivateKey()
    var otherSigningKey = P256.Signing.PrivateKey()

    func createTLSRecordTestOptions(
        server: Bool = false,
        mismatch: Bool = false
    ) -> ProtocolOptions<SwiftTLSProtocol> {
        let tlsProtocolOptions = SwiftTLSProtocol.options()
        var actualOptions = SwiftTLSProtocol.Options()
        actualOptions.applicationProtocols = ["network_test"]
        actualOptions.serverName = "tls-test.local"
        if server {
            actualOptions.rawPrivateKey =
                mismatch ? [UInt8](otherSigningKey.rawRepresentation) : [UInt8](serverSigningKey.rawRepresentation)
        } else {
            actualOptions.trustedRawPublicKeyCertificates = [[UInt8](serverSigningKey.publicKey.derRepresentation)]
        }
        tlsProtocolOptions.tlsOptions = actualOptions
        return tlsProtocolOptions
    }

    @discardableResult
    // abstract a reliable transport by just shuttling packets between client and server
    func sendPacket(
        sender: StreamLowerHarness,
        receiver: StreamLowerHarness,
        maximumBurst: Int,
        verbose: Bool = true
    ) -> Int {
        var packetsSent: Int = 0
        for _ in 0..<maximumBurst {
            if let outboundPacket = sender.extractLastOutboundPacket() {
                receiver.setNextInboundPacket(outboundPacket)
                packetsSent += 1
                if verbose {
                    Logger.test.debug(
                        "Sending packet with \(outboundPacket.count) bytes from \(sender.log.logPrefix) to \(receiver.log.logPrefix)"
                    )
                }
            }
        }
        return packetsSent
    }

    struct TLSLoopBackState {
        let context: NetworkContext
        let clientReference: ProtocolInstanceReference
        let clientNetworkLayer: StreamLowerHarness
        let clientApplicationLayer: StreamUpperHarness
        let serverReference: ProtocolInstanceReference
        let serverNetworkLayer: StreamLowerHarness
        let serverApplicationLayer: StreamUpperHarness
    }

    struct EndpointResult {
        var reference: ProtocolInstanceReference
        var parameters: Parameters
        var upperHarness: StreamUpperHarness
        var lowerHarness: StreamLowerHarness
    }

    func createEndpoint(
        identifier: String,
        reference: ProtocolInstanceReference,
        context: NetworkContext,
        options: ProtocolOptions<SwiftTLSProtocol>,
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        isServer: Bool
    ) -> EndpointResult? {
        var parameters = Parameters()
        parameters.context = context
        parameters.isServer = isServer

        parameters.defaultStack.prepend(applicationProtocol: options)
        let path = PathProperties(parameters: parameters)

        let tlsLinkage = OutboundStreamLinkage(reference: reference)
        let upperHarness = StreamUpperHarness(
            identifier: identifier,
            local: localEndpoint,
            remote: remoteEndpoint,
            parameters: parameters,
            path: path,
            context: parameters.context,
            lowerStreamProtocol: tlsLinkage
        )

        let lowerHarness = StreamLowerHarness(identifier: identifier, context: parameters.context)

        XCTAssertNotNil(upperHarness, "Failed to attach TLS to upper harness")
        guard let upperHarness else {
            return nil
        }

        do {
            try reference.attachLowerStreamProtocol(
                lowerHarness.reference,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: path
            )
        } catch {
            XCTAssertTrue(false, "Failed to attach TLS to lower harness)")
        }

        return EndpointResult(
            reference: reference,
            parameters: parameters,
            upperHarness: upperHarness,
            lowerHarness: lowerHarness
        )
    }

    #if !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Dispatch)
    final class TestInlineScheduler: NetworkContext.Scheduler {
        /// Run an immediate task.  No assumptions are made about how the task will be run.
        func runImmediate(_ task: @escaping (() -> Void)) {
            task()
        }
        /// Schedule a task to be run after a delay, using a reference.
        func schedule(_ task: @escaping (() -> Void), after delay: NetworkDuration, reference: TimerReference) {
            fatalError("Unsupported")
        }
        /// Unschedule a task with a reference
        func unschedule(reference: TimerReference) {
            fatalError("Unsupported")
        }
        /// Whether the current code is running in the scheduler
        var runningInScheduler: Bool {
            true
        }
        /// A fixed instant. Scheduling is unsupported here, so nothing fires on a deadline.
        var now: NetworkClock.Instant {
            NetworkClock.Instant(milliseconds: 1000)
        }
        var nowAbsolute: NetworkClock.Instant {
            self.now
        }
    }
    #endif

    func runTLSHandshake(identifier: String, fail: Bool = false, inlineScheduler: Bool = false) -> TLSLoopBackState? {
        let clientEndpoint = Endpoint(
            address: IPv4Address(SwiftNetworkSwiftTLSRecordTests.localIPv4Address)!,
            port: 1234
        )
        let serverEndpoint = Endpoint(
            address: IPv4Address(SwiftNetworkSwiftTLSRecordTests.remoteIPv4Address)!,
            port: 2345
        )
        let context: NetworkContext
        if inlineScheduler {
            #if !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Dispatch)
            context = NetworkContext(identifier: identifier, externalScheduler: TestInlineScheduler())
            #else
            context = NetworkContext(identifier: identifier)
            #endif
        } else {
            context = NetworkContext(identifier: identifier)
        }
        context.activate()

        let clientReference = SwiftTLSProtocol.instance(context: context)
        let clientOptions = createTLSRecordTestOptions(server: false)
        clientOptions.setProtocolInstance(clientReference)
        clientOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)

        let serverReference = SwiftTLSProtocol.instance(context: context)
        let serverOptions = createTLSRecordTestOptions(server: true, mismatch: fail)
        serverOptions.setProtocolInstance(serverReference)
        serverOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)

        let handshakeExpectaton = XCTestExpectation(description: "Wait for TLS handshake to complete")
        let handshakeFailedExpectation = XCTestExpectation(description: "HS should fail, wait for it")

        var clientCreated = false
        var serverCreated = false
        var clientConnected = false
        var serverConnected = false

        var result: TLSLoopBackState?

        context.async { [self] in
            guard
                let client = self.createEndpoint(
                    identifier: "Client",
                    reference: clientReference,
                    context: context,
                    options: clientOptions,
                    localEndpoint: clientEndpoint,
                    remoteEndpoint: serverEndpoint,
                    isServer: false
                )
            else {
                handshakeExpectaton.fulfill()
                return
            }
            clientCreated = true

            guard
                let server = self.createEndpoint(
                    identifier: "Server",
                    reference: serverReference,
                    context: context,
                    options: serverOptions,
                    localEndpoint: serverEndpoint,
                    remoteEndpoint: clientEndpoint,
                    isServer: true
                )
            else {
                handshakeExpectaton.fulfill()
                return
            }
            serverCreated = true

            result = TLSLoopBackState(
                context: context,
                clientReference: clientReference,
                clientNetworkLayer: client.lowerHarness,
                clientApplicationLayer: client.upperHarness,
                serverReference: serverReference,
                serverNetworkLayer: server.lowerHarness,
                serverApplicationLayer: server.upperHarness
            )

            var serverStartCallbackCalled = false
            server.upperHarness.start { connected in
                if connected {
                    serverConnected = true
                    handshakeExpectaton.fulfill()  // server ready second
                } else {
                    serverConnected = false
                    handshakeFailedExpectation.fulfill()  // server gets alert from client on rpk mismatch
                }
                serverStartCallbackCalled = true
            }

            client.upperHarness.start { connected in
                clientConnected = connected
            }

            while !serverStartCallbackCalled {
                let maxBurst = 10
                let clientPacketsSent = sendPacket(
                    sender: client.lowerHarness,
                    receiver: server.lowerHarness,
                    maximumBurst: maxBurst,
                    verbose: true
                )

                let serverPacketsSent = sendPacket(
                    sender: server.lowerHarness,
                    receiver: client.lowerHarness,
                    maximumBurst: maxBurst,
                    verbose: true
                )
                if clientPacketsSent + serverPacketsSent == 0 {
                    break
                }
            }
        }
        if !fail {
            wait(for: [handshakeExpectaton], timeout: 10.0)
            XCTAssertTrue(clientCreated, "TLS client failed to create")
            XCTAssertTrue(serverCreated, "TLS server failed to create")
            XCTAssertTrue(clientConnected, "TLS client failed to become connected")
            XCTAssertTrue(serverConnected, "TLS server failed to become connected")
        } else {
            wait(for: [handshakeFailedExpectation], timeout: 10.0)
            XCTAssertTrue(clientCreated, "TLS client failed to create")
            XCTAssertTrue(serverCreated, "TLS server failed to create")
            XCTAssertTrue(!clientConnected, "TLS client unexpectedly became connected")
            XCTAssertTrue(!serverConnected, "TLS server unexpectedly became connected")
        }
        return result
    }

    func echoServer(
        dataToSendGenerator: TestDataGenerator,
        state: TLSLoopBackState,
        context: NetworkContext,
        delay: TimeInterval
    ) {
        let clientWriteExpectation = XCTestExpectation(description: "Wait for client writes to complete")

        var writeSuccess: Bool = false
        func clientWrites() {
            var writeCount = 1
            for dataToSend in dataToSendGenerator {
                let writeResult: Bool
                if dataToSendGenerator.numberOfBlocks == writeCount && dataToSendGenerator.sendFIN {
                    writeResult = state.clientApplicationLayer.write(dataToSend, sendFIN: true)
                } else {
                    writeResult = state.clientApplicationLayer.write(dataToSend)
                }
                XCTAssertTrue(writeResult)
                if !writeResult {
                    clientWriteExpectation.fulfill()
                    return  // no need to continue
                }
                writeCount += 1
            }
            clientWriteExpectation.fulfill()
            writeSuccess = true
        }

        let loopbackExpectation = XCTestExpectation(description: "Wait for loopback to finish")
        var keepRunning = true
        func loopbackPackets() {
            sendPacket(sender: state.clientNetworkLayer, receiver: state.serverNetworkLayer, maximumBurst: 200)
            sendPacket(sender: state.serverNetworkLayer, receiver: state.clientNetworkLayer, maximumBurst: 200)
            if keepRunning {
                state.context.async {
                    loopbackPackets()
                }
            } else {
                loopbackExpectation.fulfill()
            }
        }

        defer {
            keepRunning = false
        }

        // This function perform the server application side reads,
        // validates, and echoes back the data.
        // If anything is unexpected, it's clearly a problem on this path,
        // so fail fast.
        var serverReadBytes = 0
        let clientToServerDataTransferExpectation = XCTestExpectation(
            description: "Wait for TLS data transfer to server"
        )
        func serverReadValidateEcho() -> (success: Bool, streamFinished: Bool) {
            var numberOfStreamsFinished = 0
            let serverUpperHarness = state.serverApplicationLayer
            let response = serverUpperHarness.read()
            if let response {
                do {
                    try dataToSendGenerator.validate(at: serverReadBytes, data: response)
                } catch {
                    XCTFail("Server received data that failed validation: \(error)")
                    return (false, numberOfStreamsFinished == 1)  // fail fast!
                }
                serverReadBytes += response.count
                if serverReadBytes >= dataToSendGenerator.totalSize {
                    // This stream is done
                    numberOfStreamsFinished += 1
                }

                // echo back to the client, this just enqueues on the server's app-side buffer
                let sendFIN = serverUpperHarness.receivedFIN
                if sendFIN {
                    Logger.test.debug("Server echoing FIN back to client")
                }
                let writeResult = serverUpperHarness.write(response, sendFIN: sendFIN)
                XCTAssertTrue(writeResult, "Server failed to write back echo to client")
                if !writeResult {
                    return (false, numberOfStreamsFinished == 1)
                }
            }
            return (true, numberOfStreamsFinished == 1)
        }

        func server() {
            let result = serverReadValidateEcho()
            guard result.success else {
                XCTFail("Failed to echo data back to client")
                clientToServerDataTransferExpectation.fulfill()
                return
            }
            if result.streamFinished {
                clientToServerDataTransferExpectation.fulfill()
                return  // server is done, successfully
            }
            if keepRunning {
                context.async {
                    server()
                }
            } else {
                clientToServerDataTransferExpectation.fulfill()
            }
        }

        var clientReadBytes = 0
        let serverToClientDataTransferExpectation = XCTestExpectation(
            description: "Wait for TLS data transfer to client"
        )
        func client() {
            if let response = state.clientApplicationLayer.read() {
                do {
                    try dataToSendGenerator.validate(at: clientReadBytes, data: response)
                } catch {
                    XCTFail("Client received data that failed to validate: \(error)")
                    serverToClientDataTransferExpectation.fulfill()
                    return  // fail fast!
                }
                clientReadBytes += response.count
            }
            if clientReadBytes >= dataToSendGenerator.totalSize {
                if dataToSendGenerator.sendFIN {
                    let receivedFIN = state.clientApplicationLayer.receivedFIN
                    XCTAssertTrue(receivedFIN, "Client failed to receive FIN from server")
                }
                serverToClientDataTransferExpectation.fulfill()
                return  // client is done, successfully!
            }
            if keepRunning {
                context.async {
                    client()
                }
            } else {
                serverToClientDataTransferExpectation.fulfill()
            }
        }

        // Get the client ready to receive data
        let initialClientReadExpectation = XCTestExpectation(description: "Wait for client read data to be available")
        context.async {
            state.clientApplicationLayer.waitForInboundDataAvailable { success in
                XCTAssertTrue(success)
                initialClientReadExpectation.fulfill()
                client()
            }
        }

        // Put the loopback on the work queue first, so it's ready to serve
        // the packets back and forth.
        // Put the server on the work queue, so it too is ready to serve.
        // Then finally start the client writes, which kicks everything off.
        context.async {
            loopbackPackets()
            server()
            clientWrites()
        }

        wait(for: [clientWriteExpectation], timeout: delay)
        XCTAssertTrue(writeSuccess)
        if !writeSuccess {
            // Fail fast if the writes didn't work, nothing else will.
            return
        }

        wait(for: [initialClientReadExpectation], timeout: delay)

        // Now wait for asynchronous operations to finish finish (detailed
        // success or failure has already been asserted)
        // Did all the bytes make it to the server, otherwise the rest won't work:
        wait(for: [clientToServerDataTransferExpectation], timeout: delay)
        XCTAssertEqual(dataToSendGenerator.totalSize, serverReadBytes, "Server did not process all data")
        if dataToSendGenerator.totalSize != serverReadBytes {
            return
        }
        // Next, did all the bytes make it back to client?
        wait(for: [serverToClientDataTransferExpectation], timeout: delay)
        XCTAssertEqual(dataToSendGenerator.totalSize, clientReadBytes, "Client did not receive all data")
        if dataToSendGenerator.totalSize != clientReadBytes {
            return
        }

        // Finally, lets shut down the loopback. It should have nothing to
        // do until the close happens.
        keepRunning = false
        wait(for: [loopbackExpectation], timeout: delay)
    }

    func loopbackStop(state: TLSLoopBackState?) {
        guard let state else {
            XCTFail("State must be non-nil")
            return
        }
        let stopClientCompleteExpectation = XCTestExpectation(description: "Wait for client stop() to complete")
        state.context.async {
            state.clientApplicationLayer.stop()
            stopClientCompleteExpectation.fulfill()
        }
        wait(for: [stopClientCompleteExpectation], timeout: 5.0)

        let stopServerCompleteExpectation = XCTestExpectation(description: "Wait for server stop() to complete")
        state.context.async {
            state.serverApplicationLayer.stop()
            stopServerCompleteExpectation.fulfill()
        }
        wait(for: [stopServerCompleteExpectation], timeout: 5.0)

        let teardownClientCompleteExpectation = XCTestExpectation(description: "Wait for client teardown() to complete")
        state.context.async {
            state.clientApplicationLayer.teardown()
            teardownClientCompleteExpectation.fulfill()
        }
        wait(for: [teardownClientCompleteExpectation], timeout: 5.0)
        let teardownServerCompleteExpectation = XCTestExpectation(description: "Wait for server teardown() to complete")
        state.context.async {
            state.serverApplicationLayer.teardown()
            teardownServerCompleteExpectation.fulfill()
        }
        wait(for: [teardownServerCompleteExpectation], timeout: 5.0)

    }

    // MARK: - SwiftTLSRecordTests

    func testSwiftTLSRecordHandshakeOnly() {
        Logger.test.debug("Test phase: Starting handshake")
        let result = runTLSHandshake(identifier: #function)
        XCTAssertNotNil(result, "TLS handshake failed")
        Logger.test.debug("Test phase: Connection Terminate")
        loopbackStop(state: result)
    }

    func testSwiftTLSRecordSendDataBlock() {
        Logger.test.debug("Test phase: Starting handshake")
        let state = runTLSHandshake(identifier: #function)
        XCTAssertNotNil(state, "TLS handshake failed")

        guard let state else {
            return
        }

        let generator = TestDataGenerator(singleDataBlock: Array("Hello World!".utf8))
        Logger.test.debug("Test phase: sending data")
        echoServer(dataToSendGenerator: generator, state: state, context: state.context, delay: 5.0)
        loopbackStop(state: state)
    }

    func testSwiftTLSRecordSend40KiB() {
        Logger.test.debug("Test phase: Starting handshake")
        let state = runTLSHandshake(identifier: #function)
        XCTAssertNotNil(state, "TLS handshake failed")

        guard let state else {
            return
        }

        let generator = TestDataGenerator(blockSize: 10240, numberOfBlocks: 4, uniqueBits: 0)
        Logger.test.debug("Test phase: sending data")
        echoServer(dataToSendGenerator: generator, state: state, context: state.context, delay: 5.0)
        loopbackStop(state: state)
    }

    func testSwiftTLSRecordFailHandshake() throws {
        Logger.test.debug("Test phase: Starting handshake")
        let state = runTLSHandshake(identifier: #function, fail: true)
        XCTAssertNotNil(state, "TLS handshake failed")

        guard let state else {
            return
        }
        loopbackStop(state: state)
    }

    func testSwiftTLSRecordCloseNotify() throws {
        Logger.test.debug("Test phase: Starting handshake")
        let state = runTLSHandshake(identifier: #function)
        XCTAssertNotNil(state, "TLS handshake failed")
        guard let state else {
            return
        }

        let generator = TestDataGenerator(singleDataBlock: Array("Hello World!".utf8), sendFIN: true)
        Logger.test.debug("Test phase: sending data")
        echoServer(dataToSendGenerator: generator, state: state, context: state.context, delay: 5.0)
        loopbackStop(state: state)
    }

    func testSwiftTLSRecordSend40KiBCloseNotify() {
        Logger.test.debug("Test phase: Starting handshake")
        let state = runTLSHandshake(identifier: #function)
        XCTAssertNotNil(state, "TLS handshake failed")

        guard let state else {
            return
        }

        let generator = TestDataGenerator(blockSize: 10240, numberOfBlocks: 4, uniqueBits: 0, sendFIN: true)
        Logger.test.debug("Test phase: sending data")
        echoServer(dataToSendGenerator: generator, state: state, context: state.context, delay: 5.0)
        loopbackStop(state: state)
    }
    #endif

    func testImportSwiftTLS() throws {
        #if IMPORT_SWIFTTLS && canImport(SwiftTLS)
        XCTAssertTrue(true, "SwiftTLS can be imported")
        #else
        throw XCTSkip("SwiftTLS cannot be imported")
        #endif
    }
}
#endif
