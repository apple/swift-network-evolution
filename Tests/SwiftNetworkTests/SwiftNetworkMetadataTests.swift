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

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

@_spi(SwiftTLSProtocol) import SwiftTLS

import XCTest
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

/// Reaching a protocol's metadata through `NetworkConnection.getMetadata()`, and the TLS key
/// exporter in particular. Runs over the bridge protocols, so no sockets or interfaces.
///
/// Each end reads its own metadata inside its `.ready` handler, where an application would. The
/// peers are torn down before the comparisons run, which also shows the exporter snapshot
/// outliving the connection.
@available(Network 0.1.0, *)
final class SwiftNetworkMetadataTests: XCTestCase {

    /// No lock: each end is written once from its own `.ready` handler, and only read after
    /// `DispatchGroup.wait` has ordered both writes before the read.
    private final class Captured<Value>: @unchecked Sendable {
        var client: Value?
        var server: Value?
    }

    /// The metadata accessor reaches a protocol that is in the stack, and answers `nil` rather than
    /// trapping for one that is not.
    func testMetadataIsReachableAndAbsentProtocolsAreNil() throws {
        let quicPresent = Captured<Bool>()
        let tcpAbsent = Captured<Bool>()

        connectQUICPeers(alpn: "MetadataReachTest", ports: (8894, 8895)) { connection, metadata, isClient in
            let absent: ProtocolMetadata<TCPProtocol>? = connection.getMetadata()
            if isClient {
                quicPresent.client = metadata != nil
                tcpAbsent.client = absent == nil
            } else {
                quicPresent.server = metadata != nil
                tcpAbsent.server = absent == nil
            }
        }

        XCTAssertEqual(quicPresent.client, true, "no QUIC metadata reachable through the client")
        XCTAssertEqual(quicPresent.server, true, "no QUIC metadata reachable through the server")
        XCTAssertEqual(tcpAbsent.client, true, "a protocol absent from the stack should yield nil")
        XCTAssertEqual(tcpAbsent.server, true, "a protocol absent from the stack should yield nil")
    }

    /// Both ends of a QUIC connection derive identical exporter key material, reached through QUIC's
    /// metadata, with the key never leaving `SymmetricKey`.
    ///
    /// TLS is not a layer in a QUIC stack -- the handshake rides in QUIC's own CRYPTO frames -- so
    /// asking for `SwiftTLSProtocol` metadata here finds nothing. QUIC instead republishes what its
    /// TLS instance produced as ``QUICConnectionMetadata/swiftTLSMetadata``.
    func testQUICExporterAgreesAcrossConnection() throws {
        let exporters = Captured<SwiftTLSExporter>()

        connectQUICPeers(alpn: "ExporterTest", ports: (8896, 8897)) { _, metadata, isClient in
            let exporter = metadata?.connectionMetadata?.swiftTLSMetadata?
                .perProtocolMetadata?.exporter
            if isClient { exporters.client = exporter } else { exporters.server = exporter }
        }

        // The exporter must be published by the time `.ready` is delivered, not merely eventually.
        let client = try XCTUnwrap(exporters.client, "client published no exporter")
        let server = try XCTUnwrap(exporters.server, "server published no exporter")

        try assertExportersAgree(client, server, label: "EXPORTER-swiftnetwork-quic-test")
    }

    #if HAS_SWIFTTLS_RECORD
    /// The same property for the record layer, where TLS genuinely is a layer in the stack and the
    /// ordinary walk down the protocol stack finds it -- no QUIC involved.
    ///
    /// Configured like `SwiftNetworkConnectionTests.testTLSNoTransportDataPath`: raw public keys,
    /// matching ALPN, and one end in server mode. With no TLS options the instance cannot build a
    /// handshaker at all and `setup()` fails with `EINVAL`.
    func testRecordLayerExporterAgreesAcrossConnection() throws {
        let serverSigningKey = P256.Signing.PrivateKey()
        let serverPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        let serverPublicKeys = [[UInt8](serverSigningKey.publicKey.derRepresentation)]

        let exporters = Captured<SwiftTLSExporter>()
        let ready = DispatchGroup()

        /// Reads this end's exporter out of the published TLS metadata.
        @Sendable func capture(_ connection: NetworkConnection<TLS>, isClient: Bool) {
            let tls: ProtocolMetadata<SwiftTLSProtocol>? = connection.getMetadata()
            let exporter = tls?.perProtocolMetadata?.exporter
            if isClient { exporters.client = exporter } else { exporters.server = exporter }
        }

        ready.enter()
        let client = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7798),
            using: .parameters {
                TLS {
                    NoTransport {
                        StreamBridge()
                    }
                }
                .trustedRawPublicKeyCertificates(serverPublicKeys)
                .applicationProtocols(["network_test"])
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7797))
        )
        .onStateUpdate { connection, state in
            guard case .ready = state else { return }
            capture(connection, isClient: true)
            ready.leave()
        }

        ready.enter()
        let server = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: 7797),
            using: .parameters {
                TLS {
                    NoTransport {
                        StreamBridge()
                    }
                }
                .rawPrivateKey(serverPrivateKey)
                .applicationProtocols(["network_test"])
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: 7798))
                .serverMode(true)
        )
        .onStateUpdate { connection, state in
            guard case .ready = state else { return }
            capture(connection, isClient: false)
            ready.leave()
        }

        // `StreamBridge` resolves its peer through a static port registry populated in `setup()`,
        // and drops anything addressed to an unregistered port. The TLS client transmits its
        // ClientHello during `start()`, so the server has to be started first.
        server.start()
        client.start()

        XCTAssertEqual(
            ready.wait(timeout: DispatchTime.now() + .seconds(10)),
            DispatchTimeoutResult.success,
            "both ends should reach .ready"
        )
        client.cancel()
        server.cancel()

        let clientExporter = try XCTUnwrap(exporters.client, "client published no exporter")
        let serverExporter = try XCTUnwrap(exporters.server, "server published no exporter")

        try assertExportersAgree(clientExporter, serverExporter, label: "EXPORTER-swiftnetwork-record-layer-test")
    }
    #endif

    // MARK: - Shared assertions

    /// The contract two ends of one connection must satisfy, per RFC 8446 section 7.5.
    private func assertExportersAgree(
        _ a: SwiftTLSExporter,
        _ b: SwiftTLSExporter,
        label: String,
        line: UInt = #line
    ) throws {
        let context = Array("exporter context".utf8)

        // The property that matters: both ends agree, having exchanged nothing about the key.
        // Compared as `SymmetricKey`, so the secret is never copied into ordinary memory here.
        let aKey = try XCTUnwrap(a.exportKeyingMaterial(label: label, context: context, length: 32), line: line)
        let bKey = try XCTUnwrap(b.exportKeyingMaterial(label: label, context: context, length: 32), line: line)
        XCTAssertEqual(aKey.bitCount, 32 * 8, line: line)
        XCTAssertEqual(aKey, bKey, "the two ends derived different exporter material", line: line)

        // A second length, to confirm both ends honour it identically.
        let aLong = try XCTUnwrap(a.exportKeyingMaterial(label: label, context: context, length: 48), line: line)
        let bLong = try XCTUnwrap(b.exportKeyingMaterial(label: label, context: context, length: 48), line: line)
        XCTAssertEqual(aLong.bitCount, 48 * 8, line: line)
        XCTAssertEqual(aLong, bLong, line: line)

        // Label and context are genuinely bound in, so this is not comparing a constant.
        XCTAssertNotEqual(
            aKey,
            a.exportKeyingMaterial(label: "EXPORTER-other", context: context, length: 32),
            line: line
        )
        XCTAssertNotEqual(
            aKey,
            a.exportKeyingMaterial(label: label, context: [], length: 32),
            line: line
        )

        // Invalid lengths yield nil rather than trapping. RFC 5869 caps a derivation at
        // `255 * Hash.byteCount`; the exporter does not report which hash was negotiated, so this uses
        // a bound past the largest one TLS 1.3 can pick (SHA-384), which is invalid for any of them.
        for badLength in [0, -1, 255 * SHA384.Digest.byteCount + 1] {
            XCTAssertNil(
                a.exportKeyingMaterial(label: label, context: context, length: badLength),
                "length \(badLength) should be rejected",
                line: line
            )
        }
    }

    // MARK: - Shared setup

    /// Brings up a QUIC client and server over `DatagramBridge`, hands each end its own connection
    /// and metadata on that connection's context, waits for both, then tears them down.
    ///
    /// The bridge pairs the two by local port, so the endpoints have to mirror each other.
    private func connectQUICPeers(
        alpn: String,
        ports: (server: UInt16, client: UInt16),
        onReady:
            @escaping @Sendable (
                _ connection: NetworkConnection<QUIC>,
                _ metadata: ProtocolMetadata<QUICProtocol>?,
                _ isClient: Bool
            ) -> Void
    ) {
        let serverSigningKey = P256.Signing.PrivateKey()
        let serverPrivateKey = [UInt8](serverSigningKey.rawRepresentation)
        let serverPublicKeys = [[UInt8](serverSigningKey.publicKey.derRepresentation)]

        let ready = DispatchGroup()

        ready.enter()
        let client = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: ports.server),
            using: .parameters {
                QUIC(alpn: [alpn]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.trustedRawPublicKeyCertificates(serverPublicKeys)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: ports.client))
        )
        .onStateUpdate { connection, state in
            guard case .ready = state else { return }
            onReady(connection, connection.getMetadata(), true)
            ready.leave()
        }

        ready.enter()
        let server = NetworkConnection(
            to: Endpoint(address: IPv4Address.loopback, port: ports.client),
            using: .parameters {
                QUIC(alpn: [alpn]) {
                    UDP {
                        IP {
                            DatagramBridge()
                        }
                    }
                }.tls.rawPrivateKey(serverPrivateKey)
            }.localEndpoint(Endpoint(address: IPv4Address.loopback, port: ports.server))
                .serverMode(true)
        )
        .onStateUpdate { connection, state in
            guard case .ready = state else { return }
            onReady(connection, connection.getMetadata(), false)
            ready.leave()
        }

        server.start()
        client.start()

        XCTAssertEqual(
            ready.wait(timeout: DispatchTime.now() + .seconds(10)),
            DispatchTimeoutResult.success,
            "both ends should reach .ready"
        )

        client.cancel()
        server.cancel()
    }
}
