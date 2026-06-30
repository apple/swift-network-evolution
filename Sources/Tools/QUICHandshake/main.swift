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

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)

@available(Network 0.1.0, *)
final class QUICHandshake: @unchecked Sendable {

    let quicBenchmarkUtility = QUICBenchmarkUtility()
    let dataBenchmarkUtility = DataBenchmarkUtility()
    let NSEC_PER_MSEC = UInt64(Duration.milliseconds(1) / Duration.nanoseconds(1))
    let ipv4Client = Endpoint(address: IPv4Address(QUICBenchmarkUtility.localIPv4Address)!, port: 1234)
    let ipv4Server = Endpoint(address: IPv4Address(QUICBenchmarkUtility.remoteIPv4Address)!, port: 8080)

    func run(iterations: Int, loggingHandle: LoggingHandle, group: DispatchGroup) -> Double {
        print("Running QUIC \(iterations) handshake\(iterations > 1 ? "s" : "")")
        let timestart = DispatchTime.now().uptimeNanoseconds
        let context = NetworkContext(identifier: "QUICHandshake")
        context.activate()

        // NOTE: Today this benchmark relies on DispatchGroups due to Sendability issues on some of the project types.
        // In the future we should try to adopt Swift Concurrency.
        for index in 0..<iterations {
            group.enter()
            context.async {
                let clientInstance = QUICProtocol.Instance(context: context)
                let clientOptions = self.quicBenchmarkUtility.createQUICTestOptions(datagram: false)
                clientOptions.setLogID(
                    prefix: "C",
                    parent: "1",
                    protocolLogIDNumber: 1
                )
                clientOptions.setProtocolInstance(clientInstance.reference)

                let serverInstance = QUICProtocol.Instance(context: context)
                let serverOptions = self.quicBenchmarkUtility.createQUICTestOptions(server: true, datagram: false)
                serverOptions.setLogID(
                    prefix: "L",
                    parent: "1",
                    protocolLogIDNumber: 1
                )
                serverOptions.setProtocolInstance(serverInstance.reference)

                // Create endpoints
                guard
                    let client = try? self.quicBenchmarkUtility.createClientEndpoint(
                        instance: clientInstance,
                        context: context,
                        options: clientOptions,
                        localEndpoint: self.ipv4Client,
                        remoteEndpoint: self.ipv4Server,
                        logger: loggingHandle
                    )
                else {
                    loggingHandle.log("Test failed, client endpoint could not be created")
                    return
                }
                guard
                    let server = try? self.quicBenchmarkUtility.createServerEndpoint(
                        instance: serverInstance,
                        context: context,
                        options: serverOptions,
                        localEndpoint: self.ipv4Server,
                        remoteEndpoint: self.ipv4Client,
                        logger: loggingHandle
                    )
                else {
                    loggingHandle.log("Test failed, server endpoint could not be created")
                    return
                }
                let state = QUICLoopbackState(
                    context: context,
                    clientApplicationLayers: [client.upperHandler],
                    clientInstance: client.instance,
                    clientNetworkLayer: client.lowerHandler,
                    serverApplicationLayer: server.upperHandler,
                    serverNetworkLayer: server.lowerHandler,
                    serverInstance: serverInstance,
                    clientNewFlowHandler: client.clientNewFlowHandler
                )

                var serverConnectedReceived = false
                server.upperHandler.start { connected in
                    if connected {
                        loggingHandle.log("Server connected")
                    } else {
                        loggingHandle.log("Server failed to connect")
                    }
                    serverConnectedReceived = true
                }
                client.upperHandler.start { connected in
                    if connected {
                        loggingHandle.log("Client connected")
                    } else {
                        loggingHandle.log("Client failed to connect")
                    }
                }
                while !serverConnectedReceived {
                    // Shuffle handshake packets back and forth
                    let clientPacketsSent = self.dataBenchmarkUtility.loopOutputHandlerPackets(
                        sender: client.lowerHandler,
                        receiver: server.lowerHandler,
                        maximumBurst: 20
                    )
                    let serverPacketsSent = self.dataBenchmarkUtility.loopOutputHandlerPackets(
                        sender: server.lowerHandler,
                        receiver: client.lowerHandler,
                        maximumBurst: 20
                    )
                    if (clientPacketsSent + serverPacketsSent) == 0 {
                        break
                    }
                }
                // Wait until both instances are connected to signal handshake complete
                @Sendable func pollForConnectedInstances() {
                    // Wait for the client connection state to go into connected
                    if client.instance.state == .connected {
                        loggingHandle.log("Client connection handshake finished")
                        return
                    } else {
                        context.async {
                            pollForConnectedInstances()
                        }
                    }
                }
                context.async {
                    pollForConnectedInstances()
                }
                // Wait for both connections to complete
                loggingHandle.log("Handshake complete, tear down")

                self.quicBenchmarkUtility.tearDownState(state: state)
                loggingHandle.log("=== Finished iteration: \(index)")
                group.leave()
            }
        }
        group.wait()
        // Get the elapsed time
        let endTime = DispatchTime.now().uptimeNanoseconds
        var totalTime = Double(endTime - timestart) / Double(NSEC_PER_MSEC)
        totalTime = (totalTime / 1000.0)
        return totalTime
    }
}

if #available(anyAppleOS 26, *) {
    // Take command line arguments
    var iterations = 10000
    var loggingHandler: LoggingHandle = LoggingHandle(loggingType: .none)
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

    // Create and run the handshake
    let handshake = QUICHandshake()
    let group = DispatchGroup()
    print("Starting \(iterations) iterations with logging set to \(loggingHandler)")
    let totalTime = handshake.run(iterations: iterations, loggingHandle: loggingHandler, group: group)

    print("Finished all (\(iterations)) iterations in \(totalTime) seconds")
} else {
    fatalError("This tool requires macOS 26 or newer")
}

#endif
