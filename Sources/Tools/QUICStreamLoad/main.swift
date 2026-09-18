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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkBenchmarks
import Dispatch

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)

@available(Network 0.1.0, *)
final class QUICStreamLoad {

    // 169.254.156.146
    let localIPv4Address: [UInt8] = [0xa9, 0xfe, 0x9c, 0x92]
    // 169.254.225.163
    let remoteIPv4Address: [UInt8] = [0xa9, 0xfe, 0xe1, 0xa3]

    var serverSigningKey = P256.Signing.PrivateKey()

    func run(
        loggingHandle: LoggingHandle,
        group: DispatchGroup,
        streamCount: Int,
        concurrentStreams: Int,
        uploadSize: Int,
        downloadSize: Int,
        linkDelay: NetworkDuration
    ) -> NetworkDuration {
        let ipv4Client = Endpoint(address: IPv4Address(localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(remoteIPv4Address)!, port: 2345)

        var uploadPayload = [UInt8](repeating: 0, count: uploadSize)
        uploadPayload = (0..<uploadSize).map { _ in UInt8.random(in: 0...255) }
        var downloadPayload = [UInt8](repeating: 0, count: downloadSize)
        downloadPayload = (0..<downloadSize).map { _ in UInt8.random(in: 0...255) }

        print(
            "Running QUIC stream load of \(streamCount) streams (\(concurrentStreams) at a time), with \(uploadSize) upload bytes and \(downloadSize) download bytes"
        )
        let startTime = NetworkClock.Instant.systemNow

        var handshakeDuration = NetworkDuration.zero
        var streamRoundTripDurations = [NetworkDuration]()

        var clientInput: NewStreamFlowHarness<TestStreamLinkageFamily>? = nil
        var clientQUICStreamListenerLinkage: TestStreamListenerLinkage? = nil
        var serverInput: NewStreamFlowHarness<TestStreamLinkageFamily>? = nil

        group.enter()
        var clientParameters = Parameters()
        let context = NetworkContext(identifier: "QUICStreamLoad")
        clientParameters.context = context
        let path = PathProperties(parameters: clientParameters)

        var serverParameters = Parameters()
        serverParameters.isServer = true
        serverParameters.context = context
        let serverPath = PathProperties(parameters: serverParameters)

        context.activate()
        // The storage owns the protocol instances and hands back the linkages used to wire the
        // stack together.
        let storage = TestNetworkProtocolStorage(context: context)
        context.async {

            let handshakeStart = NetworkClock.Instant.systemNow

            // Client
            let (clientIPUpper, clientIPLower) = storage.createTestIPInstance()
            let clientIPOptions = IPProtocol.options()
            clientIPOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 3)
            clientIPOptions.setProtocolInstance(clientIPLower.identifier)
            clientParameters.defaultStack.internet = .ip(clientIPOptions)

            let (clientUDPUpper, clientUDPLower) = storage.createTestUDPInstance()
            let clientUDPOptions = UDPProtocol.options()
            clientUDPOptions.noMetadata = true
            clientUDPOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 2)
            clientUDPOptions.setProtocolInstance(clientUDPLower.identifier)
            clientParameters.defaultStack.transport = .udp(clientUDPOptions)

            var (clientQUICStreamListener, _, clientQUICMultipath) = storage.createTestQUICInstance()
            var clientTLSOptions = SwiftTLSProtocol.Options()
            clientTLSOptions.applicationProtocols = ["network_test"]
            clientTLSOptions.serverName = "quic-test.local"
            clientTLSOptions.trustedRawPublicKeyCertificates = [
                [UInt8](self.serverSigningKey.publicKey.derRepresentation)
            ]
            let clientQUICOptions = QUICStreamProtocol.options()
            clientQUICOptions.tlsOptions = clientTLSOptions
            clientQUICOptions.connectionOptions.initialMaxStreamsBidirectional = 100
            clientQUICOptions.connectionOptions.maximumConcurrentBidirectionalStreams = concurrentStreams * 2
            clientQUICOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientQUICOptions.setProtocolInstance(clientQUICStreamListener.identifier)

            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let clientOutput = storage.createTestBridgeDatagramInstance()
            let bridgeOptions = BridgeDatagramProtocol.options()
            bridgeOptions.linkDelay = linkDelay
            bridgeOptions.setProtocolInstance(clientOutput.identifier)
            clientParameters.defaultStack.link = .custom(bridgeOptions)

            clientQUICStreamListenerLinkage = clientQUICStreamListener
            let (clientInputInstance, clientInputLinkage) = storage.createNewStreamFlowHarness(
                identifier: "Client",
                local: ipv4Client,
                remote: ipv4Server,
                parameters: clientParameters,
                path: path,
                context: context
            )
            clientInput = clientInputInstance
            guard let clientInput else {
                group.leave()
                return
            }

            do {
                // Attach from the upper linkage so both directions are bound.
                try clientInputLinkage.invokeAttachLowerProtocol(
                    clientQUICStreamListener,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
                // QUIC -> UDP -> IP -> BridgeProtocol
                try clientQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    clientUDPLower,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
                try clientUDPUpper.invokeAttachLowerProtocol(
                    clientIPLower,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
                try clientIPUpper.invokeAttachLowerProtocol(
                    clientOutput,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
            } catch {
                loggingHandle.log("Failed to attach client IP to lower protocol")
                group.leave()
                return
            }
            // Server
            let (serverIPUpper, serverIPLower) = storage.createTestIPInstance()
            let serverIPOptions = IPProtocol.options()
            serverIPOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 3)
            serverIPOptions.setProtocolInstance(serverIPLower.identifier)
            serverParameters.defaultStack.internet = .ip(serverIPOptions)

            let (serverUDPUpper, serverUDPLower) = storage.createTestUDPInstance()
            let serverUDPOptions = UDPProtocol.options()
            serverUDPOptions.noMetadata = true
            serverUDPOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 2)
            serverUDPOptions.setProtocolInstance(serverUDPLower.identifier)
            serverParameters.defaultStack.transport = .udp(serverUDPOptions)

            var (serverQUICStreamListener, _, serverQUICMultipath) = storage.createTestQUICInstance()
            var serverTLSOptions = SwiftTLSProtocol.Options()
            serverTLSOptions.applicationProtocols = ["network_test"]
            serverTLSOptions.serverName = "quic-test.local"
            serverTLSOptions.rawPrivateKey = [UInt8](self.serverSigningKey.rawRepresentation)

            let serverQUICOptions = QUICStreamProtocol.options()
            serverQUICOptions.tlsOptions = serverTLSOptions
            serverQUICOptions.connectionOptions.initialMaxStreamsBidirectional = 100
            serverQUICOptions.connectionOptions.maximumConcurrentBidirectionalStreams = concurrentStreams * 2
            serverQUICOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverQUICOptions.setProtocolInstance(serverQUICStreamListener.identifier)
            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))

            let serverOutput = storage.createTestBridgeDatagramInstance()
            let serverBridgeOptions = BridgeDatagramProtocol.options()
            serverBridgeOptions.linkDelay = linkDelay
            serverBridgeOptions.setProtocolInstance(serverOutput.identifier)
            serverParameters.defaultStack.link = .custom(serverBridgeOptions)

            let (serverInputInstance, serverInputLinkage) = storage.createNewStreamFlowHarness(
                identifier: "Server",
                local: ipv4Server,
                remote: ipv4Client,
                parameters: serverParameters,
                path: serverPath,
                context: context
            )
            serverInput = serverInputInstance

            guard let serverInput else {
                group.leave()
                return
            }

            do {
                // Attach from the upper linkage so both directions are bound.
                try serverInputLinkage.invokeAttachLowerProtocol(
                    serverQUICStreamListener,
                    remote: ipv4Client,
                    local: ipv4Server,
                    parameters: serverParameters,
                    path: serverPath
                )
                // QUIC -> UDP -> IP -> BridgeProtocol
                try serverQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    serverUDPLower,
                    remote: ipv4Client,
                    local: ipv4Server,
                    parameters: serverParameters,
                    path: serverPath
                )
                try serverUDPUpper.invokeAttachLowerProtocol(
                    serverIPLower,
                    remote: ipv4Client,
                    local: ipv4Server,
                    parameters: serverParameters,
                    path: serverPath
                )
                try serverIPUpper.invokeAttachLowerProtocol(
                    serverOutput,
                    remote: ipv4Client,
                    local: ipv4Server,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                loggingHandle.log("Failed to attach server IP to lower protocol")
                group.leave()
                return
            }
            serverInput.start { connected in
                handshakeDuration = handshakeStart.duration(to: .systemNow)
                group.leave()
            }
            clientInput.start()
        }
        group.wait()

        guard let serverInput, let clientInput, let clientQUICStreamListenerLinkage else {
            return .zero
        }

        var index = 0
        for _ in 0..<streamCount {
            group.enter()
        }

        var testStreamBlock: (() -> Void)? = nil

        testStreamBlock = {
            guard index < streamCount else { return }

            index += 1

            let streamStart = NetworkClock.Instant.systemNow

            let myIndex = index
            let (clientStream, clientStreamLinkage) = storage.createStreamUpperHarness(
                identifier: "Client\(myIndex)",
                local: ipv4Client,
                remote: ipv4Server,
                parameters: clientParameters,
                path: path,
                context: context
            )
            do {
                // Each load stream is a new outbound flow on the shared client connection.
                try clientQUICStreamListenerLinkage.invokeAttachUpperProtocolToNewFlow(
                    clientStreamLinkage,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
            } catch {
                print("Failed to attach client stream \(myIndex) to QUIC: \(error)")
                group.leave()
                return
            }

            clientStream.start()

            var serverStreamToTeardown: StreamUpperHarness<TestStreamLinkageFamily>? = nil

            // Get new server stream
            serverInput.waitForNewFlow { newFlowState in
                guard let serverStream = serverInput.upperHarnesses.last else {
                    group.leave()
                    return
                }

                serverStreamToTeardown = serverStream

                // Read on server, respond to client
                var serverPayloadReceived = false
                var serverReadDataSize = 0
                var serverReadCompletion: ((inout NetworkContext.EventContext, Bool) -> Void)? = nil
                serverReadCompletion = { state, _ in
                    let readBytes = serverStream.readAndDrop(in: &state)
                    if readBytes > 0 {
                        serverReadDataSize += readBytes
                    }
                    if serverReadDataSize == uploadSize, serverStream.receivedFIN {
                        serverPayloadReceived = true
                    }

                    if !serverPayloadReceived {
                        serverStream.waitForInboundDataAvailable(in: &state, completion: serverReadCompletion!)
                    } else {
                        serverReadCompletion = nil
                        let writeSuccess = serverStream.write(
                            downloadPayload,
                            sendFIN: true,
                            earlyData: true,
                            in: &state
                        )
                        if !writeSuccess {
                            print("Issue took place writing on the server \(myIndex)")
                        }
                        serverStream.stop(in: &state)
                    }
                }
                serverReadCompletion!(&newFlowState, true)

                // Read on client
                var clientPayloadReceived = false
                var clientReadDataSize = 0
                var clientReadCompletion: ((inout NetworkContext.EventContext, Bool) -> Void)? = nil
                clientReadCompletion = { state, _ in
                    let readBytes = clientStream.readAndDrop(in: &state)
                    if readBytes > 0 {
                        clientReadDataSize += readBytes
                    }
                    if clientReadDataSize == downloadSize, clientStream.receivedFIN {
                        clientPayloadReceived = true
                    }

                    if !clientPayloadReceived {
                        clientStream.waitForInboundDataAvailable(in: &state, completion: clientReadCompletion!)
                    } else {
                        streamRoundTripDurations.append(streamStart.duration(to: .systemNow))

                        clientReadCompletion = nil
                        group.leave()
                        clientStream.stop(in: &state)

                        // Start the next stream on a fresh hop: it builds new protocol instances,
                        // which is an external entry point and cannot run while this event still
                        // holds the event context.
                        if index < streamCount, let testStreamBlock {
                            state.async {
                                testStreamBlock()
                            }
                        }

                        clientStream.teardown(in: &state)
                        serverStreamToTeardown?.teardown(in: &state)
                    }
                }
                clientReadCompletion!(&newFlowState, true)
            }

            // Send from client to server, which triggers the new flow above
            let writeSuccess = clientStream.write(uploadPayload, sendFIN: true, earlyData: true)
            guard writeSuccess else {
                print("Issue took place writing on the client")
                group.leave()
                return
            }
        }

        // Kick off first round of streams. Each stream will in turn kick another.
        if let testStreamBlock {
            context.async {
                for _ in 0..<concurrentStreams {
                    testStreamBlock()
                }
            }
        }

        group.wait()

        testStreamBlock = nil

        print("Completed \(index) / \(streamCount) streams")

        group.enter()
        context.async {
            clientInput.stop()
            clientInput.teardown()
            serverInput.stop()
            serverInput.teardown()
            group.leave()
        }
        group.wait()

        // Short circuit and return 0 if index does not match iterations
        if index != streamCount {
            return .zero
        }

        print("Handshake completed in \(handshakeDuration)")
        let minStreamRTT = streamRoundTripDurations.min()!
        let maxStreamRTT = streamRoundTripDurations.max()!
        let meanStreamRTT = streamRoundTripDurations.reduce(NetworkDuration.zero, +) / streamRoundTripDurations.count
        print("Stream round trip: min = \(minStreamRTT), max = \(maxStreamRTT), mean = \(meanStreamRTT)")

        let totalTime = startTime.duration(to: .systemNow)

        let rate = (Int64(streamCount) * 1_000_000_000) / totalTime.nanoseconds
        print("Rate: \(rate) streams/s")

        return totalTime
    }
}

if #available(anyAppleOS 26, *) {
    // Take command line arguments
    var loggingHandler: LoggingHandle = LoggingHandle(loggingType: .none)
    var uploadSize = 1000  // 1kb
    var downloadSize = 1000  // 1kb
    var streamCount = 100000
    var concurrentStreams = 100
    var linkDelay = NetworkDuration.zero
    let arguments = CommandLine.arguments.dropFirst(0)

    if arguments.contains("-logging"),
        let index = arguments.firstIndex(of: "-logging")
    {
        if arguments.count >= (index + 2) {
            let parsedLoggingOption = String(arguments[index + 1])
            loggingHandler = LoggingHandle(parsedLoggingOption)
        }
    }

    if arguments.contains("-stream-count"),
        let index = arguments.firstIndex(of: "-stream-count")
    {
        if arguments.count >= (index + 2) {
            if let streamCountOption = Int(arguments[index + 1]) {
                streamCount = streamCountOption
            }
        }
    }

    if arguments.contains("-concurrent-streams"),
        let index = arguments.firstIndex(of: "-concurrent-streams")
    {
        if arguments.count >= (index + 2) {
            if let concurrentStreamsOption = Int(arguments[index + 1]) {
                concurrentStreams = concurrentStreamsOption
            }
        }
    }

    if arguments.contains("-link-delay-ms"),
        let index = arguments.firstIndex(of: "-link-delay-ms")
    {
        if arguments.count >= (index + 2) {
            if let linkDelayOption = Int(arguments[index + 1]) {
                linkDelay = .milliseconds(linkDelayOption)
            }
        }
    }

    if arguments.contains("-link-delay-us"),
        let index = arguments.firstIndex(of: "-link-delay-us")
    {
        if arguments.count >= (index + 2) {
            if let linkDelayOption = Int(arguments[index + 1]) {
                linkDelay = .microseconds(linkDelayOption)
            }
        }
    }

    if arguments.contains("-upload-size"),
        let index = arguments.firstIndex(of: "-upload-size")
    {
        if arguments.count >= (index + 2) {
            if let sizeOption = Int(arguments[index + 1]) {
                uploadSize = sizeOption
            }
        }
    }

    if arguments.contains("-download-size"),
        let index = arguments.firstIndex(of: "-download-size")
    {
        if arguments.count >= (index + 2) {
            if let sizeOption = Int(arguments[index + 1]) {
                downloadSize = sizeOption
            }
        }
    }

    // Create and run the transfers
    let quicStreamLoad = QUICStreamLoad()
    let group = DispatchGroup()
    let totalTime = quicStreamLoad.run(
        loggingHandle: loggingHandler,
        group: group,
        streamCount: streamCount,
        concurrentStreams: concurrentStreams,
        uploadSize: uploadSize,
        downloadSize: downloadSize,
        linkDelay: linkDelay
    )
    if totalTime > .zero {
        print("Finished test in \(totalTime)")
    } else {
        print("Error running test")
    }
} else {
    fatalError("This tool requires macOS 26 or newer")
}

#endif
