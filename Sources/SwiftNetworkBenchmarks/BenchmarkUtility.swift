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
    public var clientApplicationLayers: [StreamUpperHarness<TestStreamLinkageFamily>]
    public let clientInstance: QUICConnection
    public let clientNetworkLayer: DatagramLowerHarness<TestDatagramLinkageFamily>
    public let serverApplicationLayer: NewStreamFlowHarness<TestStreamLinkageFamily>
    public let serverNetworkLayer: DatagramLowerHarness<TestDatagramLinkageFamily>
    public let serverInstance: QUICConnection
    public let clientNewFlowHandler: NewStreamFlowHarness<TestStreamLinkageFamily>?
    public init(
        context: NetworkContext,
        clientApplicationLayers: [StreamUpperHarness<TestStreamLinkageFamily>],
        clientInstance: QUICConnection,
        clientNetworkLayer: DatagramLowerHarness<TestDatagramLinkageFamily>,
        serverApplicationLayer: NewStreamFlowHarness<TestStreamLinkageFamily>,
        serverNetworkLayer: DatagramLowerHarness<TestDatagramLinkageFamily>,
        serverInstance: QUICConnection,
        clientNewFlowHandler: NewStreamFlowHarness<TestStreamLinkageFamily>?
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
public struct QUICClientEndpointResult {
    public var instance: QUICConnection
    public var parameters: Parameters
    public var upperHandler: StreamUpperHarness<TestStreamLinkageFamily>
    public var lowerHandler: DatagramLowerHarness<TestDatagramLinkageFamily>
    public var clientNewFlowHandler: NewStreamFlowHarness<TestStreamLinkageFamily>?
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICServerEndpointResult {
    public var instance: QUICConnection
    public var parameters: Parameters
    public var upperHandler: NewStreamFlowHarness<TestStreamLinkageFamily>
    public var lowerHandler: DatagramLowerHarness<TestDatagramLinkageFamily>
}

@_spi(ProtocolProvider)
public enum BenchmarkError: Error {
    case setupError
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public final class QUICBenchmarkUtility {

    // 127.0.0.1 (Just point both at loopback)
    public static let localIPv4Address: [UInt8] = [0x7f, 0x00, 0x00, 0x01]
    public static let remoteIPv4Address: [UInt8] = [0x7f, 0x00, 0x00, 0x01]
    var serverSigningKey = P256.Signing.PrivateKey()

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

    /// Builds the client half of a loopback QUIC stack.
    ///
    /// The QUIC instance is created by `storage`, which owns it and hands back the linkages used
    /// to wire the stack together. `options` must already name the instance's identifier, so the
    /// caller creates the instance first via `createTestQUICInstance()`.
    public func createClientEndpoint(
        storage: TestNetworkProtocolStorage,
        streamListener: TestStreamListenerLinkage,
        multipath: TestDatagramMultipathLinkage,
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

        guard let instance = storage.quicInstance(for: streamListener.base) else {
            logger.log("Failed to look up the client QUIC instance")
            throw BenchmarkError.setupError
        }

        let (streamHandler, streamHandlerLinkage) = storage.createStreamUpperHarness(
            identifier: "Client",
            local: localEndpoint,
            remote: remoteEndpoint,
            parameters: parameters,
            path: path,
            context: context
        )
        do {
            try streamListener.invokeAttachUpperProtocolToNewFlow(
                streamHandlerLinkage,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: path
            )
        } catch {
            logger.log("Failed to attach the client stream handler to QUIC")
            throw BenchmarkError.setupError
        }

        let (outputHandler, outputHandlerLinkage) = storage.createDatagramLowerHarness(
            identifier: "Client",
            context: context
        )
        do {
            var multipath = multipath
            try multipath.invokeAttachLowerProtocolForNewPath(
                outputHandlerLinkage,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: path
            )
        } catch {
            logger.log("Failed to attach the output handler to the instance")
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

    /// Builds the server half of a loopback QUIC stack. See `createClientEndpoint`.
    public func createServerEndpoint(
        storage: TestNetworkProtocolStorage,
        streamListener: TestStreamListenerLinkage,
        multipath: TestDatagramMultipathLinkage,
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

        guard let instance = storage.quicInstance(for: streamListener.base) else {
            logger.log("Failed to look up the server QUIC instance")
            throw BenchmarkError.setupError
        }

        let (serverNewFlowHandler, serverNewFlowHandlerLinkage) = storage.createNewStreamFlowHarness(
            identifier: "Server",
            local: localEndpoint,
            remote: remoteEndpoint,
            parameters: serverParameters,
            path: serverPath,
            context: context
        )
        do {
            // Attach from the upper linkage so both directions are bound.
            try serverNewFlowHandlerLinkage.invokeAttachLowerProtocol(
                // The inherited QUIC factory hands back the framework's listener; the harness's
                // flow linkage pairs with the test family's wrapper around it.
                streamListener,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: serverParameters,
                path: serverPath
            )
        } catch {
            logger.log("Failed to attach the server new flow handler to QUIC")
            throw BenchmarkError.setupError
        }

        let (outputHandler, outputHandlerLinkage) = storage.createDatagramLowerHarness(
            identifier: "Server",
            context: context
        )
        do {
            var multipath = multipath
            try multipath.invokeAttachLowerProtocolForNewPath(
                outputHandlerLinkage,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: serverParameters,
                path: serverPath
            )
        } catch {
            logger.log("Failed to attach the output handler to the instance")
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
        // Tearing down the application layers detaches them from QUIC, which retires each
        // connection once its last upper protocol has gone. Closing the connections here as well
        // would reach an already-released instance.
    }
    public init() {}
}

#endif

@_spi(ProtocolProvider)
#if !(os(Linux) || NETWORK_EMBEDDED)
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
#endif
public struct LoggingHandle: CustomStringConvertible {
    #if os(Linux) || NETWORK_EMBEDDED
    let logger = Logger(label: "com.apple.network.benchmarks")
    #else
    #if canImport(os)
    let logger = Logger(subsystem: "com.apple.network.benchmarks", category: "perf")
    #endif
    #endif
    public enum LoggingType: Int {
        case none = 0
        case print = 1
        case log = 2
    }
    public var loggingType: LoggingType = .none

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
public final class DataBenchmarkUtility {
    @discardableResult
    public func loopOutputHandlerPackets<LinkageFamily: DatagramLinkageFamily>(
        sender: DatagramLowerHarness<LinkageFamily>,
        receiver: DatagramLowerHarness<LinkageFamily>,
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
