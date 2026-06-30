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

@available(Network 0.1.0, *)
final class IPUDPTransfer: @unchecked Sendable {

    // 169.254.156.146
    let localIPv4Address: [UInt8] = [0xa9, 0xfe, 0x9c, 0x92]
    // 169.254.225.163
    let remoteIPv4Address: [UInt8] = [0xa9, 0xfe, 0xe1, 0xa3]

    let dataBenchmarkUtility = DataBenchmarkUtility()
    let NSEC_PER_MSEC = UInt64(Duration.milliseconds(1) / Duration.nanoseconds(1))

    var iterationIndex = 0

    func run(iterations: Int, packets: Int, loggingHandle: LoggingHandle, group: DispatchGroup, sendSize: Int) -> Double
    {
        // Create a random payload to send back and forth
        var mutablePayload = [UInt8](repeating: 0, count: sendSize)
        mutablePayload = (0..<sendSize).map { _ in UInt8.random(in: 0...255) }
        let payload = mutablePayload
        print(
            "Running IP/UDP transfer, transferring \(iterations) iteration\(iterations > 1 ? "s" : "") of \(packets) packet\(packets > 1 ? "s" : "")"
        )
        let timestart = DispatchTime.now().uptimeNanoseconds

        // NOTE: Today this benchmark relies on DispatchGroups due to Sendability issues on some of the project types.
        // In the future we should try to adopt Swift Concurrency.
        group.enter()
        let context = NetworkContext(identifier: "IPUDPTransfer")
        context.activate()
        context.async {
            let ipv4Client = Endpoint(address: IPv4Address(self.localIPv4Address)!, port: 0)
            let ipv4Server = Endpoint(address: IPv4Address(self.remoteIPv4Address)!, port: 0)

            var clientParameters = Parameters()
            clientParameters.context = context

            for _ in 0..<iterations {
                // Client
                let path = PathProperties(parameters: clientParameters)
                let clientIP = IPProtocol.instance(context: clientParameters.context)
                let clientIPOptions = IPProtocol.options()
                clientIPOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 2)
                clientIPOptions.setProtocolInstance(clientIP)
                clientParameters.defaultStack.internet = .ip(clientIPOptions)

                let clientUDP = UDPProtocol.instance(context: context)
                let clientUDPOptions = UDPProtocol.options()
                clientUDPOptions.noMetadata = true
                clientUDPOptions.setLogID(prefix: "C", parent: "1", protocolLogIDNumber: 1)
                clientUDPOptions.setProtocolInstance(clientUDP)
                clientParameters.defaultStack.transport = .udp(clientUDPOptions)

                let clientUDPLinkage = OutboundDatagramLinkage(reference: clientUDP)
                let clientInput = DatagramUpperHarness(
                    identifier: "Client",
                    local: ipv4Client,
                    remote: ipv4Server,
                    parameters: clientParameters,
                    path: path,
                    context: context,
                    lowerProtocol: clientUDPLinkage
                )
                guard let clientInput else {
                    return
                }

                let clientOutput = DatagramLowerHarness(
                    identifier: "Client",
                    context: clientParameters.context
                )
                do {
                    try clientUDP.attachLowerDatagramProtocol(
                        clientIP,
                        remote: ipv4Server,
                        local: ipv4Client,
                        parameters: clientParameters,
                        path: path
                    )
                    try clientIP.attachLowerDatagramProtocol(
                        clientOutput.reference,
                        remote: ipv4Server,
                        local: ipv4Client,
                        parameters: clientParameters,
                        path: path
                    )
                } catch {
                    loggingHandle.log("Failed to attach client IP to lower protocol")
                    return
                }
                // Server
                var serverParameters = Parameters()
                serverParameters.context = context
                let serverPath = PathProperties(parameters: serverParameters)
                let serverIP = IPProtocol.instance(context: clientParameters.context)
                let serverIPOptions = IPProtocol.options()
                serverIPOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 2)
                clientIPOptions.setProtocolInstance(serverIP)
                serverParameters.defaultStack.internet = .ip(serverIPOptions)

                let serverUDP = UDPProtocol.instance(context: context)
                let serverUDPOptions = UDPProtocol.options()
                serverUDPOptions.noMetadata = true
                serverUDPOptions.setLogID(prefix: "L", parent: "1", protocolLogIDNumber: 1)
                serverUDPOptions.setProtocolInstance(serverUDP)
                serverParameters.defaultStack.transport = .udp(serverUDPOptions)

                let serverUDPLinkage = OutboundDatagramLinkage(reference: serverUDP)
                let serverInput = DatagramUpperHarness(
                    identifier: "Server",
                    local: ipv4Server,
                    remote: ipv4Client,
                    parameters: serverParameters,
                    path: serverPath,
                    context: context,
                    lowerProtocol: serverUDPLinkage
                )
                guard let serverInput else {
                    return
                }

                let serverOutput = DatagramLowerHarness(
                    identifier: "Server",
                    context: clientParameters.context
                )
                do {
                    try serverUDP.attachLowerDatagramProtocol(
                        serverIP,
                        remote: ipv4Client,
                        local: ipv4Server,
                        parameters: clientParameters,
                        path: path
                    )
                    try serverIP.attachLowerDatagramProtocol(
                        serverOutput.reference,
                        remote: ipv4Client,
                        local: ipv4Server,
                        parameters: serverParameters,
                        path: serverPath
                    )
                } catch {
                    loggingHandle.log("Failed to attach server IP to lower protocol")
                    return
                }
                serverInput.start()
                clientInput.start()
                // Transfer data
                for _ in 0..<packets {
                    let _ = clientInput.write(payload)
                    let _ = self.dataBenchmarkUtility.loopOutputHandlerPackets(
                        sender: clientOutput,
                        receiver: serverOutput,
                        maximumBurst: 10
                    )
                    guard serverInput.read() != nil else {
                        loggingHandle.log("Failed to read a payload")
                        break
                    }
                }
                clientInput.stop()
                clientInput.teardown()
                serverInput.stop()
                serverInput.teardown()

                self.iterationIndex += 1
            }
            group.leave()
        }
        group.wait()
        print("Completed \(iterationIndex) / \(iterations) iterations")
        // Short circuit and return 0 if index does not match iterations
        if iterationIndex != iterations {
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
    var iterations = 1000
    var packets = 1000
    var loggingHandler: LoggingHandle = LoggingHandle(loggingType: .none)
    var sendSize = 1000  // 1k
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

    if arguments.contains("-packets"),
        let index = arguments.firstIndex(of: "-packets")
    {
        if arguments.count >= (index + 2) {
            if let parsedPackets = Int(arguments[index + 1]) {
                packets = parsedPackets
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

    // Create and run the transfers
    let ipUDPTransfer = IPUDPTransfer()
    let group = DispatchGroup()
    print("Starting \(iterations) transfers of \(packets) packets with logging set to \(loggingHandler)")
    let totalTime = ipUDPTransfer.run(
        iterations: iterations,
        packets: packets,
        loggingHandle: loggingHandler,
        group: group,
        sendSize: sendSize
    )
    if totalTime > 0 {
        print("Finished all (\(iterations)) transfers in \(totalTime) seconds")
    } else {
        print("Error running all (\(iterations)) transfers, something failed")
    }
} else {
    fatalError("This tool requires macOS 26 or newer")
}
