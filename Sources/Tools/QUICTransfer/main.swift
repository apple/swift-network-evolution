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
final class QUICTransfer {

    // 169.254.156.146
    let localIPv4Address: [UInt8] = [0xa9, 0xfe, 0x9c, 0x92]
    // 169.254.225.163
    let remoteIPv4Address: [UInt8] = [0xa9, 0xfe, 0xe1, 0xa3]

    let dataBenchmarkUtility = DataBenchmarkUtility()
    let quicBenchmakrUtility = QUICBenchmarkUtility()
    let NSEC_PER_MSEC = UInt64(Duration.milliseconds(1) / Duration.nanoseconds(1))
    var serverSigningKey = P256.Signing.PrivateKey()

    func run(
        iterations: Int,
        loggingHandle: LoggingHandle,
        group: DispatchGroup,
        sendSize: Int,
        linkDelay: NetworkDuration = .zero
    ) -> Double {
        let ipv4Client = Endpoint(address: IPv4Address(localIPv4Address)!, port: 1234)
        let ipv4Server = Endpoint(address: IPv4Address(remoteIPv4Address)!, port: 2345)
        var clientStream: StreamUpperHarness? = nil
        var clientInput: NewStreamFlowHarness? = nil
        var serverInput: NewStreamFlowHarness? = nil
        // Create a random payload to send back and forth
        var payload = [UInt8](repeating: 0, count: sendSize)
        payload = (0..<sendSize).map { _ in UInt8.random(in: 0...255) }
        print("Running QUIC transfer, transferring \(iterations) packet\(iterations > 1 ? "s" : "")")
        let timestart = DispatchTime.now().uptimeNanoseconds

        group.enter()
        var clientParameters = Parameters()
        let context = NetworkContext(identifier: "QUICTransfer")
        clientParameters.context = context
        let path = PathProperties(parameters: clientParameters)

        var serverParameters = Parameters()
        serverParameters.isServer = true
        serverParameters.context = context

        context.activate()
        context.async {
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
            clientQUICOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
            clientQUICOptions.setProtocolInstance(clientQUIC)
            clientParameters.defaultStack.prepend(applicationProtocol: .quic(clientQUICOptions))

            let clientOutput = BridgeDatagramProtocol.instance(context: clientParameters.context)
            let bridgeOptions = BridgeDatagramProtocol.options()
            bridgeOptions.linkDelay = linkDelay
            bridgeOptions.setProtocolInstance(clientOutput)
            clientParameters.defaultStack.link = .custom(bridgeOptions)

            let clientListenerLinkage = StreamListenerLinkage(reference: clientQUIC)
            clientInput = NewStreamFlowHarness(
                identifier: "Client",
                local: ipv4Client,
                remote: ipv4Server,
                parameters: clientParameters,
                path: path,
                context: context,
                listenerProtocol: clientListenerLinkage
            )

            clientStream = StreamUpperHarness(
                identifier: "C1",
                local: ipv4Client,
                remote: ipv4Server,
                parameters: clientParameters,
                path: path,
                context: context,
                listenerProtocol: clientListenerLinkage
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
            let serverPath = PathProperties(parameters: serverParameters)
            let serverIP = IPProtocol.instance(context: context)
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
            serverQUICOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
            serverQUICOptions.setProtocolInstance(serverQUIC)
            serverParameters.defaultStack.prepend(applicationProtocol: .quic(serverQUICOptions))

            let serverOutput = BridgeDatagramProtocol.instance(context: context)
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
                // Server connected event
                group.leave()
            }
            clientInput.start()
            clientStream?.start()
        }
        group.wait()
        guard let serverInput, let clientInput, let clientStream else {
            return 0
        }
        var serverStream: StreamUpperHarness?

        var writeIndex = 0
        var writeSucceeded = true
        var totalReadSize = 0
        let totalExpectedSize = iterations * payload.count
        let doneSemaphore = DispatchSemaphore(value: 0)

        // Client write loop to perform all writes until finished
        func writeLoop() {
            guard writeIndex < iterations else { return }
            guard clientStream.write(payload) else {
                loggingHandle.log("Client failed to write at iteration: \(writeIndex)")
                writeSucceeded = false
                return
            }
            writeIndex += 1
            context.async {
                writeLoop()
            }
        }

        // Server read loop: keeps draining inbound data as it arrives.
        // Readloop used for multiple iterations
        func readLoop(stream: StreamUpperHarness) {
            stream.waitForInboundDataAvailable { available in
                guard available else { return }
                totalReadSize += stream.readAndDrop()
                if totalReadSize >= totalExpectedSize {
                    doneSemaphore.signal()
                } else {
                    readLoop(stream: stream)
                }
            }
        }

        context.async {
            // Setup inbound flow observer and then start the client write loop
            serverInput.waitForNewFlow {
                serverStream = serverInput.upperHarnesses.last
                if let serverStream {
                    // If there is only one inbound read then a read can take place here and that is it.
                    // If there are more data after the first read then a read loop will need to be setup
                    // to observe the rest of the inbound data events.
                    totalReadSize += serverStream.readAndDrop()
                    if totalReadSize >= totalExpectedSize {
                        doneSemaphore.signal()
                    } else {
                        readLoop(stream: serverStream)
                    }
                    readLoop(stream: serverStream)
                } else {
                    doneSemaphore.signal()
                }
            }
            writeLoop()
        }
        doneSemaphore.wait()

        guard serverStream != nil, writeSucceeded else {
            return 0
        }

        let index = min(totalReadSize / payload.count, iterations)

        group.enter()
        context.async {
            clientStream.stop()
            clientInput.stop()
            clientInput.teardown()
            serverInput.stop()
            serverInput.teardown()
            group.leave()
        }
        group.wait()

        print("Completed \(index) / \(iterations) transfers")
        // Short circuit and return 0 if index does not match iterations
        if index != iterations {
            return 0
        }
        // Get the elapsed time
        let endTime = DispatchTime.now().uptimeNanoseconds
        var totalTime = Double(endTime - timestart) / Double(NSEC_PER_MSEC)
        totalTime = (totalTime / 1000.0)
        return totalTime
    }
}

if #available(anyAppleOS 26, *) {
    // Take command line arguments
    var iterations = 10000  // 5gb total (if 500000 sendSize)
    var loggingHandler: LoggingHandle = LoggingHandle(loggingType: .none)
    var sendSize = 500000  // 500kb
    var linkDelay = NetworkDuration.zero
    let arguments = CommandLine.arguments.dropFirst(0)
    if arguments.contains("-iterations"),
        let index = arguments.firstIndex(of: "-iterations")
    {
        if arguments.count >= (index + 2) {
            if let parsedIterations = Int(arguments[index + 1]) {
                iterations = parsedIterations
            }
        }
    }

    if arguments.contains("-logging"),
        let index = arguments.firstIndex(of: "-logging")
    {
        if arguments.count >= (index + 2) {
            let parsedLoggingOption = String(arguments[index + 1])
            loggingHandler = LoggingHandle(parsedLoggingOption)
        }
    }

    if arguments.contains("-size"),
        let index = arguments.firstIndex(of: "-size")
    {
        if arguments.count >= (index + 2) {
            if let sendSizeOption = Int(arguments[index + 1]) {
                sendSize = sendSizeOption
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

    // Create and run the transfers
    let quicTransfer = QUICTransfer()
    let group = DispatchGroup()
    print("Starting \(iterations) transfers with logging set to \(loggingHandler)")
    let totalTime = quicTransfer.run(
        iterations: iterations,
        loggingHandle: loggingHandler,
        group: group,
        sendSize: sendSize,
        linkDelay: linkDelay
    )
    if totalTime > 0 {
        print("Finished all (\(iterations)) transfers in \(totalTime) seconds")
    } else {
        print("Error running all (\(iterations)) transfers, something failed")
    }
} else {
    fatalError("This tool requires macOS 26 or newer")
}

#endif
