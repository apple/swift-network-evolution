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
final class QUICStreamLoad: @unchecked Sendable {

    // 169.254.156.146
    let localIPv4Address: [UInt8] = [0xa9, 0xfe, 0x9c, 0x92]
    // 169.254.225.163
    let remoteIPv4Address: [UInt8] = [0xa9, 0xfe, 0xe1, 0xa3]

    let dataBenchmarkUtility = DataBenchmarkUtility()
    let quicBenchmakrUtility = QUICBenchmarkUtility()
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
        nonisolated(unsafe) let ipv4Client = Endpoint(address: IPv4Address(localIPv4Address)!, port: 1234)
        nonisolated(unsafe) let ipv4Server = Endpoint(address: IPv4Address(remoteIPv4Address)!, port: 2345)

        var uploadPayload = [UInt8](repeating: 0, count: uploadSize)
        uploadPayload = (0..<uploadSize).map { _ in UInt8.random(in: 0...255) }
        var downloadPayload = [UInt8](repeating: 0, count: downloadSize)
        downloadPayload = (0..<downloadSize).map { _ in UInt8.random(in: 0...255) }

        print(
            "Running QUIC stream load of \(streamCount) streams (\(concurrentStreams) at a time), with \(uploadSize) upload bytes and \(downloadSize) download bytes"
        )
        let startTime = NetworkClock.Instant.now

        nonisolated(unsafe) var handshakeDuration = NetworkDuration.zero
        var streamRoundTripDurations = [NetworkDuration]()

        nonisolated(unsafe) var clientInput: NewStreamFlowHarness? = nil
        nonisolated(unsafe) var clientListenerLinkage: StreamListenerLinkage? = nil
        nonisolated(unsafe) var serverInput: NewStreamFlowHarness? = nil

        group.enter()
        nonisolated(unsafe) var clientParameters = Parameters()
        let context = NetworkContext(identifier: "QUICStreamLoad")
        clientParameters.context = context
        nonisolated(unsafe) let path = PathProperties(parameters: clientParameters)

        nonisolated(unsafe) var serverParameters = Parameters()
        serverParameters.isServer = true
        serverParameters.context = context
        nonisolated(unsafe) let serverPath = PathProperties(parameters: serverParameters)

        context.activate()
        context.async {

            let handshakeStart = NetworkClock.Instant.now

            // Client
            let clientIP = IPProtocol.instance(context: clientParameters.context)
            let clientIPOptions = IPProtocol.options()
            clientIPOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 3)
            clientIPOptions.setProtocolInstance(clientIP)
            clientParameters.defaultStack.internet = .ip(clientIPOptions)

            let clientUDP = UDPProtocol.instance(context: context)
            let clientUDPOptions = UDPProtocol.options()
            clientUDPOptions.noMetadata = true
            clientUDPOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 2)
            clientUDPOptions.setProtocolInstance(clientUDP)
            clientParameters.defaultStack.transport = .udp(clientUDPOptions)

            let clientQUIC = QUICProtocol.instance(context: context)
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
            clientQUICOptions.setProtocolInstance(clientQUIC)

            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let clientOutput = BridgeDatagramProtocol.instance(context: clientParameters.context)
            let bridgeOptions = BridgeDatagramProtocol.options()
            bridgeOptions.linkDelay = linkDelay
            bridgeOptions.setProtocolInstance(clientOutput)
            clientParameters.defaultStack.link = .custom(bridgeOptions)

            clientListenerLinkage = StreamListenerLinkage(reference: clientQUIC)
            clientInput = NewStreamFlowHarness(
                identifier: "Client",
                local: ipv4Client,
                remote: ipv4Server,
                parameters: clientParameters,
                path: path,
                context: context,
                listenerProtocol: clientListenerLinkage!
            )
            guard let clientInput else {
                group.leave()
                return
            }

            do {
                try clientQUIC.attachLowerDatagramProtocolForNewPath(
                    clientUDP,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
                try clientUDP.attachLowerDatagramProtocol(
                    clientIP,
                    remote: ipv4Server,
                    local: ipv4Client,
                    parameters: clientParameters,
                    path: path
                )
                try clientIP.attachLowerDatagramProtocol(
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
            let serverIP = IPProtocol.instance(context: clientParameters.context)
            let serverIPOptions = IPProtocol.options()
            serverIPOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 3)
            clientIPOptions.setProtocolInstance(serverIP)
            serverParameters.defaultStack.internet = .ip(serverIPOptions)

            let serverUDP = UDPProtocol.instance(context: context)
            let serverUDPOptions = UDPProtocol.options()
            serverUDPOptions.noMetadata = true
            serverUDPOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 2)
            serverUDPOptions.setProtocolInstance(serverUDP)
            serverParameters.defaultStack.transport = .udp(serverUDPOptions)

            let serverQUIC = QUICProtocol.instance(context: context)
            var serverTLSOptions = SwiftTLSProtocol.Options()
            serverTLSOptions.applicationProtocols = ["network_test"]
            serverTLSOptions.serverName = "quic-test.local"
            serverTLSOptions.rawPrivateKey = [UInt8](self.serverSigningKey.rawRepresentation)

            let serverQUICOptions = QUICStreamProtocol.options()
            serverQUICOptions.tlsOptions = serverTLSOptions
            serverQUICOptions.connectionOptions.initialMaxStreamsBidirectional = 100
            serverQUICOptions.connectionOptions.maximumConcurrentBidirectionalStreams = concurrentStreams * 2
            serverQUICOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverQUICOptions.setProtocolInstance(serverQUIC)
            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))

            let serverOutput = BridgeDatagramProtocol.instance(context: serverParameters.context)
            let serverBridgeOptions = BridgeDatagramProtocol.options()
            serverBridgeOptions.linkDelay = linkDelay
            serverBridgeOptions.setProtocolInstance(serverOutput)
            serverParameters.defaultStack.link = .custom(serverBridgeOptions)

            let serverListenerLinkage = StreamListenerLinkage(reference: serverQUIC)
            serverInput = NewStreamFlowHarness(
                identifier: "Server",
                local: ipv4Server,
                remote: ipv4Client,
                parameters: serverParameters,
                path: serverPath,
                context: serverParameters.context,
                listenerProtocol: serverListenerLinkage
            )
            guard let serverInput else {
                group.leave()
                return
            }

            do {
                try serverQUIC.attachLowerDatagramProtocolForNewPath(
                    serverUDP,
                    remote: ipv4Client,
                    local: ipv4Server,
                    parameters: serverParameters,
                    path: serverPath
                )

                try serverUDP.attachLowerDatagramProtocol(
                    serverIP,
                    remote: ipv4Client,
                    local: ipv4Server,
                    parameters: clientParameters,
                    path: path
                )
                try serverIP.attachLowerDatagramProtocol(
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
                handshakeDuration = handshakeStart.duration(to: .now)
                group.leave()
            }
            clientInput.start()
        }
        group.wait()

        guard let serverInput, let clientInput, let clientListenerLinkage else {
            return .zero
        }
        nonisolated(unsafe) let unsafeServerInput = serverInput
        nonisolated(unsafe) let unsafeClientListenerLinkage = clientListenerLinkage

        var index = 0
        for _ in 0..<streamCount {
            group.enter()
        }

        nonisolated(unsafe) var testStreamBlock: (() -> Void)? = nil

        testStreamBlock = {
            guard index < streamCount else { return }

            index += 1

            let streamStart = NetworkClock.Instant.now

            let myIndex = index
            let clientStream = StreamUpperHarness(
                identifier: "Client\(myIndex)",
                local: ipv4Client,
                remote: ipv4Server,
                parameters: clientParameters,
                path: path,
                context: context,
                listenerProtocol: unsafeClientListenerLinkage
            )
            guard let clientStream else {
                group.leave()
                return
            }

            clientStream.start()

            var serverStreamToTeardown: StreamUpperHarness? = nil

            // Get new server stream
            unsafeServerInput.waitForNewFlow {
                guard let serverStream = unsafeServerInput.upperHarnesses.last else {
                    group.leave()
                    return
                }

                serverStreamToTeardown = serverStream

                // Read on server, respond to client
                var serverPayloadReceived = false
                var serverReadDataSize = 0
                var serverReadCompletion: ((Bool) -> Void)? = nil
                serverReadCompletion = { _ in
                    let readBytes = serverStream.readAndDrop()
                    if readBytes > 0 {
                        serverReadDataSize += readBytes
                    }
                    if serverReadDataSize == uploadSize, serverStream.receivedFIN {
                        serverPayloadReceived = true
                    }

                    if !serverPayloadReceived {
                        serverStream.waitForInboundDataAvailable(completion: serverReadCompletion!)
                    } else {
                        serverReadCompletion = nil
                        let writeSuccess = serverStream.write(downloadPayload, sendFIN: true, earlyData: true)
                        if !writeSuccess {
                            print("Issue took place writing on the server \(myIndex)")
                        }
                        serverStream.stop()
                    }
                }
                serverStream.fromExternal {
                    serverReadCompletion!(true)
                }

                // Read on client
                var clientPayloadReceived = false
                var clientReadDataSize = 0
                var clientReadCompletion: ((Bool) -> Void)? = nil
                clientReadCompletion = { _ in
                    let readBytes = clientStream.readAndDrop()
                    if readBytes > 0 {
                        clientReadDataSize += readBytes
                    }
                    if clientReadDataSize == downloadSize, clientStream.receivedFIN {
                        clientPayloadReceived = true
                    }

                    if !clientPayloadReceived {
                        clientStream.waitForInboundDataAvailable(completion: clientReadCompletion!)
                    } else {
                        streamRoundTripDurations.append(streamStart.duration(to: .now))

                        clientReadCompletion = nil
                        group.leave()
                        clientStream.stop()

                        // Start the next stream
                        if index < streamCount, let testStreamBlock {
                            testStreamBlock()
                        }

                        clientStream.teardown()
                        serverStreamToTeardown?.teardown()
                    }
                }
                clientStream.fromExternal {
                    clientReadCompletion!(true)
                }
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
            nonisolated(unsafe) let unsafeTestStreamBlock = testStreamBlock
            context.async {
                for _ in 0..<concurrentStreams {
                    unsafeTestStreamBlock()
                }
            }
        }

        group.wait()

        testStreamBlock = nil

        print("Completed \(index) / \(streamCount) streams")

        group.enter()
        nonisolated(unsafe) let unsafeClientInputTeardown = clientInput
        nonisolated(unsafe) let unsafeServerInputTeardown = serverInput
        context.async {
            unsafeClientInputTeardown.stop()
            unsafeClientInputTeardown.teardown()
            unsafeServerInputTeardown.stop()
            unsafeServerInputTeardown.teardown()
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

        let totalTime = startTime.duration(to: .now)

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
