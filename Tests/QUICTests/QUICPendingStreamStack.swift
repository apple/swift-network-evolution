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

#if !NETWORK_NO_SWIFT_QUIC

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

// A connection with a path and one pending stream under an upper harness, shared by the tests that need
// a stream with an upper protocol on a connection that has no peer.
@available(Network 0.1.0, *)
extension XCTestCase {
    /// The parts of a stack that a handshake-completion test drives: a connection with a path and one
    /// pending stream, plus the harness above that stream.
    struct AsynchronousHandshakeStack {
        let storage: TestNetworkProtocolStorage
        let connection: QUICConnection
        let harness: StreamUpperHarness<TestStreamLinkageFamily>
    }

    /// Builds a connection as it stands while a handshake is still in flight: a path to send on, and
    /// one stream that was opened early and so has no stream ID yet.
    ///
    /// The connection is a server, so the peer's transport parameters only have to carry the
    /// connection ID of the path they arrived on; a client would also check the original destination
    /// connection ID it generated, which it keeps to itself.
    func makeAsynchronousHandshakeStack() -> AsynchronousHandshakeStack? {
        let storage = TestNetworkProtocolStorage(context: .implicitContext)
        let (streamListener, _, _) = NetworkContext.implicitContext.onQueue {
            storage.createTestQUICInstance()
        }
        guard let connection = storage.quicInstance(for: streamListener.base) else {
            XCTFail("Failed to create a QUIC connection")
            return nil
        }

        var parameters = Parameters()
        let quicOptions = QUICStreamProtocol.options()
        quicOptions.setProtocolInstance(streamListener.identifier)
        parameters.defaultStack.prepend(applicationProtocol: .quic(quicOptions))
        parameters.isServer = true
        let path = PathProperties(parameters: parameters)
        let local = Endpoint(hostname: "10.0.0.1", port: 4433)
        let remote = Endpoint(hostname: "10.0.0.2", port: 1234)
        let peerConnectionID = QUICConnectionID([0xC1, 0xC2, 0xC3, 0xC4])!

        var upperHarness: StreamUpperHarness<TestStreamLinkageFamily>?
        let setUp = XCTestExpectation(description: "connection set up with a pending stream")
        connection.context.async {
            do {
                try connection.setup(remote: remote, local: local, parameters: parameters, path: path)
            } catch {
                XCTFail("Failed to set up the connection: \(error)")
            }
            // What `crypto.start` wires up, without starting a handshake: the events under test only
            // need the parent reference, but closing the connection tears the TLS linkage down, so
            // that has to be bound too.
            let crypto = connection.crypto
            crypto.parentConnection = connection
            var tlsParameters = Parameters()
            tlsParameters.isServer = true
            let tlsOptions = SwiftTLSProtocol.options()
            tlsOptions.setProtocolInstance(crypto.tlsInstance.identifier)
            // The TLS instance's own setup insists on the transport parameters it would carry into
            // the handshake, which is all it reads here.
            var tlsPerProtocolOptions = SwiftTLSProtocol.Options()
            tlsPerProtocolOptions.quicTransportParameters =
                (try? connection.localTransportParameters.serialize()) ?? []
            tlsOptions.replacePerProtocolOptions(tlsPerProtocolOptions)
            tlsParameters.defaultStack.append(applicationProtocol: .swiftTLS(tlsOptions))
            do {
                try crypto.invokeAttachLowerProtocol(
                    crypto.tlsInstance,
                    remote: nil,
                    local: nil,
                    parameters: tlsParameters,
                    path: nil
                )
            } catch {
                XCTFail("Failed to attach the TLS instance below crypto: \(error)")
            }

            let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
                identifier: "Lower",
                context: .implicitContext
            )
            lower.fromExternal { eventContext in
                lower.connect(in: &eventContext)
            }
            var quicPath = QUICPath.makeFromExternalTest(parent: connection)
            quicPath.set(interface: nil, priority: 1, isInitial: true)
            connection.fromExternal { eventContext in
                quicPath.assignDCID(peerConnectionID, in: &eventContext)
            }
            _ = try? quicPath.attachLowerProtocol(lowerLinkage.base)
            try? lowerLinkage.base.invokeAttachUpperProtocol(
                quicPath.asUpperLinkage(),
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            connection.currentPath = quicPath
            connection.multiplexingPaths[quicPath.pathIdentifier] = quicPath

            // A stream opened while the handshake is in flight has no stream ID yet, so it is one
            // of the pending streams that completion has to ready.
            let (harness, harnessLinkage) = storage.createStreamUpperHarness(
                identifier: "Client",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                context: .implicitContext
            )
            upperHarness = harness
            do {
                try streamListener.invokeAttachUpperProtocolToNewFlow(
                    harnessLinkage,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach an upper harness to a new flow: \(error)")
            }

            // The peer's transport parameters arrive with its handshake data, so the connection
            // has them before verification finishes.
            var peerTransportParameters = TransportParameters(logPrefixer: LogPrefixer())
            peerTransportParameters.append(.initialSCID(connectionID: peerConnectionID))
            peerTransportParameters.append(.initialMaxStreamsBidirectional(value: 4))
            peerTransportParameters.append(.initialMaxStreamsUnidirectional(value: 4))
            peerTransportParameters.append(.initialMaxData(value: 1 << 20))
            peerTransportParameters.append(.initialMaxStreamDataBidirectionalLocal(value: 1 << 16))
            peerTransportParameters.append(.initialMaxStreamDataBidirectionalRemote(value: 1 << 16))
            peerTransportParameters.append(.initialMaxStreamDataUnidirectional(value: 1 << 16))
            connection.fromExternal { eventContext in
                connection.setRemoteTransportParameters(
                    peerTransportParameters,
                    earlyData: false,
                    in: &eventContext
                )
            }
            setUp.fulfill()
        }
        wait(for: [setUp], timeout: 5.0)
        guard let upperHarness else {
            XCTFail("Failed to build an upper harness")
            return nil
        }
        return .init(storage: storage, connection: connection, harness: upperHarness)
    }

    func destroy(_ stack: AsynchronousHandshakeStack) {
        let connection = stack.connection
        connection.context.onQueue {
            // Strictly top down, and the harness goes first: detaching it takes the stream flow with
            // it, and a connection whose last upper protocol has gone tears itself down, paths and
            // all. That cascade is what breaks the cycle between a connection and its flows — a
            // connection torn down with flows still attached stays alive, because the closing side of
            // that only finishes once a peer answers and a test has no peer.
            stack.harness.teardown()
            if !connection.identifier.isNone {
                connection.destroyFromExternalTest()
            }
            connection.currentPath = nil
            for path in connection.multiplexingPaths.values where !path.identifier.isNone {
                path.destroyFromExternalTest()
            }
            connection.multiplexingPaths.removeAll()
            stack.storage.releaseHeldInstances()
        }
    }

    /// Runs `body` the way an asynchronous certificate verification completing does: on the TLS
    /// instance's event state, a turn of its own, with the connection's own state idle. Returns once
    /// the events that turn queued have been delivered.
    func onAsynchronousHandshakeTurn(
        _ connection: QUICConnection,
        _ body: @escaping (QUICCrypto, inout NetworkContext.EventContext) -> Void
    ) {
        let finished = XCTestExpectation(description: "handshake turn delivered")
        connection.context.async {
            let crypto = connection.crypto
            crypto.tlsInstance.async { eventContext in
                body(crypto, &eventContext)
            }
            // What that turn queued is delivered as it unwinds, so wait for a turn after it.
            connection.context.async {
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5.0)
    }
}

#endif
