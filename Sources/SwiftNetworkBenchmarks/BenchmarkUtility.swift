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
import Dispatch

#if canImport(CryptoKit)
internal import CryptoKit
#elseif canImport(Crypto)
internal import Crypto
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
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICLoopbackState {
    public let context: NetworkContext
    public var clientApplicationLayers: [StreamUpperHarness]
    public let clientInstance: QUICConnection
    public let clientNetworkLayer: DatagramLowerHarness
    public let serverApplicationLayer: NewStreamFlowHarness
    public let serverNetworkLayer: DatagramLowerHarness
    public let serverInstance: QUICConnection
    public let clientNewFlowHandler: NewStreamFlowHarness?
    public init(
        context: NetworkContext,
        clientApplicationLayers: [StreamUpperHarness],
        clientInstance: QUICConnection,
        clientNetworkLayer: DatagramLowerHarness,
        serverApplicationLayer: NewStreamFlowHarness,
        serverNetworkLayer: DatagramLowerHarness,
        serverInstance: QUICConnection,
        clientNewFlowHandler: NewStreamFlowHarness?
    ) {
        self.context = context
        self.clientApplicationLayers = clientApplicationLayers
        self.clientInstance = clientInstance
        self.clientNetworkLayer = clientNetworkLayer
        self.serverApplicationLayer = serverApplicationLayer
        self.serverNetworkLayer = serverNetworkLayer
        self.serverInstance = serverInstance
        self.clientNewFlowHandler = clientNewFlowHandler
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICClientEndpointResult: @unchecked Sendable {
    public var instance: QUICConnection
    public var parameters: Parameters
    public var upperHandler: StreamUpperHarness
    public var lowerHandler: DatagramLowerHarness
    public var clientNewFlowHandler: NewStreamFlowHarness?
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICServerEndpointResult: @unchecked Sendable {
    public var instance: QUICConnection
    public var parameters: Parameters
    public var upperHandler: NewStreamFlowHarness
    public var lowerHandler: DatagramLowerHarness
}

@_spi(ProtocolProvider)
public enum BenchmarkError: Error {
    case setupError
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICBenchmarkUtility: Sendable {

    // 127.0.0.1 (Just point both at loopback)
    public static let localIPv4Address: [UInt8] = [0x7f, 0x00, 0x00, 0x01]
    public static let remoteIPv4Address: [UInt8] = [0x7f, 0x00, 0x00, 0x01]
    let serverSigningKey = P256.Signing.PrivateKey()

    public func createQUICTestOptions(
        server: Bool = false,
        datagram: Bool = false,
        idleTimeout: NetworkDuration = .seconds(30),
        unidirectionalStreams: Bool = false
    ) -> ProtocolOptions<QUICProtocol> {
        var tlsOptions = SwiftTLSProtocol.Options()
        tlsOptions.applicationProtocols = ["network_test"]
        tlsOptions.serverName = "quic-test.local"
        if server {
            tlsOptions.rawPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        } else {
            tlsOptions.trustedRawPublicKeyCertificates = [[UInt8](serverSigningKey.publicKey.derRepresentation)]
        }

        let quicOptions = QUICStreamProtocol.options()
        quicOptions.isUnidirectional = unidirectionalStreams
        quicOptions.tlsOptions = tlsOptions

        if let streamOptions = quicOptions.perProtocolOptions {
            streamOptions.quicConnectionOptions.idleTimeout = idleTimeout
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
        return quicOptions
    }

    public func createClientEndpoint(
        instance: QUICProtocol.Instance,
        context: NetworkContext,
        options: ProtocolOptions<QUICProtocol>,
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        logger: LoggingHandle
    ) throws -> QUICClientEndpointResult? {
        // Set context on parameters to activate the context before asyncing
        var parameters = Parameters()
        parameters.context = context
        parameters.isServer = false

        parameters.defaultStack.transport = .quic(options)
        let path = PathProperties(parameters: parameters)
        var instance = instance

        let listenerLinkage = StreamListenerLinkage(reference: instance.reference)
        let streamHandler = StreamUpperHarness(
            identifier: "Client",
            local: localEndpoint,
            remote: remoteEndpoint,
            parameters: parameters,
            path: path,
            context: context,
            listenerProtocol: listenerLinkage
        )
        guard let streamHandler else {
            return nil
        }
        let outputHandler = DatagramLowerHarness(identifier: "Client", context: context)
        do {
            try instance.attachLowerDatagramProtocolForNewPath(
                outputHandler.reference,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: path
            )
        } catch {
            logger.log("Failed to attach the output handler to the instace")
            throw BenchmarkError.setupError
        }
        return QUICClientEndpointResult(
            instance: instance,
            parameters: parameters,
            upperHandler: streamHandler,
            lowerHandler: outputHandler,
            clientNewFlowHandler: nil
        )
    }

    public func createServerEndpoint(
        instance: QUICProtocol.Instance,
        context: NetworkContext,
        options: ProtocolOptions<QUICProtocol>,
        localEndpoint: Endpoint,
        remoteEndpoint: Endpoint,
        logger: LoggingHandle
    ) throws -> QUICServerEndpointResult? {
        var serverParameters = Parameters()
        serverParameters.context = context
        serverParameters.defaultStack.transport = .quic(options)
        serverParameters.isServer = true
        let serverPath = PathProperties(parameters: serverParameters)

        var instance = instance

        let listenerLinkage = StreamListenerLinkage(reference: instance.reference)

        let serverNewFlowHandler = NewStreamFlowHarness(
            local: localEndpoint,
            remote: remoteEndpoint,
            parameters: serverParameters,
            path: serverPath,
            context: context,
            streamListenerProtocol: listenerLinkage
        )
        guard let serverNewFlowHandler else {
            logger.log("Failed to create server new flow handler")
            return nil
        }

        let outputHandler = DatagramLowerHarness(identifier: "Server", context: context)
        do {
            try instance.attachLowerDatagramProtocolForNewPath(
                outputHandler.reference,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: serverParameters,
                path: serverPath
            )
        } catch {
            logger.log("Failed to attach the output handler to the instace")
            throw BenchmarkError.setupError
        }
        return QUICServerEndpointResult(
            instance: instance,
            parameters: serverParameters,
            upperHandler: serverNewFlowHandler,
            lowerHandler: outputHandler
        )
    }

    public func tearDownState(state: QUICLoopbackState) {
        for clientApplicationLayer in state.clientApplicationLayers {
            clientApplicationLayer.stop()
        }
        state.serverApplicationLayer.stop()
        if let clientNewFlowHandler = state.clientNewFlowHandler {
            clientNewFlowHandler.stop()
        }
        for clientApplicationLayer in state.clientApplicationLayers {
            clientApplicationLayer.teardown()
        }
        state.serverApplicationLayer.teardown()
        state.clientInstance.close()
        state.serverInstance.close()
    }
    public init() {}
}

#endif

@_spi(ProtocolProvider)
#if !(os(Linux) || NETWORK_EMBEDDED)
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
#endif
public struct LoggingHandle: CustomStringConvertible, Sendable {
    #if os(Linux) || NETWORK_EMBEDDED
    let logger = Logger(label: "com.apple.network.benchmarks")
    #else
    #if canImport(os)
    let logger = Logger(subsystem: "com.apple.network.benchmarks", category: "perf")
    #endif
    #endif
    public enum LoggingType: Int, Sendable {
        case none = 0
        case print = 1
        case log = 2
    }
    public let loggingType: LoggingType

    public init(loggingType: LoggingType) {
        self.loggingType = loggingType
    }
    public init(_ type: String) {
        switch type {
        case "print":
            self.loggingType = .print
        case "log":
            self.loggingType = .log
        case "off":
            self.loggingType = .none
        default:
            self.loggingType = .none
        }
    }
    public func log(_ logMessage: @autoclosure () -> String) {
        switch self.loggingType {
        case .print:
            let message = logMessage()
            print(message)
        case .log:
            let message = logMessage()
            self.logger.info("\(message)")
        case .none:
            break
        }
    }

    public var description: String {
        switch self.loggingType {
        case .print:
            return "print"
        case .log:
            return "log"
        case .none:
            return "off"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class DataBenchmarkUtility: Sendable {
    @discardableResult
    public func loopOutputHandlerPackets(
        sender: DatagramLowerHarness,
        receiver: DatagramLowerHarness,
        maximumBurst: Int
    ) -> Int {
        var packetsSent: Int = 0
        for _ in 0..<maximumBurst {  // limit burst amount
            guard receiver.setNextInboundPacket(from: sender, sendAvailableEvent: false) else {
                break  // nothing more to do right now
            }
            packetsSent += 1
        }
        if packetsSent > 0 {
            receiver.deliverInboundDataAvailableEvent()
        }
        return packetsSent
    }
    public init() {}
}
