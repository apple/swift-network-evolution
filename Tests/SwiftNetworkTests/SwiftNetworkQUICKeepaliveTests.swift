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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if IMPORT_SWIFTTLS
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
final class SwiftNetworkQUICKeepaliveTests: NetTestCase {
    func testQUICClientKeepAliveWithLowTimeoutAndPMTUDInterval() throws {
        // This test is expected to timeout because the idleTimeout is set to 2 seconds.
        // The handshake starts up and no data is transferred, so the connection should timeout after 2 seconds.
        // Note that the keep-alive interval does not actually keep the connection alive,
        // the PMTUD probe actually is the part that keeps the connection alive.
        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }
        clientOptions.modifyConnectionOptions { $0.pmtudUpdateInterval = .seconds(1) }
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.pmtudUpdateInterval = .seconds(1) }

        var networkError: NetworkError? = nil

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterHandshake: { harness in
                harness.onContext {
                    harness.state?.clientHarness.waitForError { error in
                        networkError = error
                    }

                    if let metadata: ProtocolMetadata<QUICProtocol> = harness.state?.clientHarness.getMetadata() {
                        // Add keep-alive for 1 second intervals
                        metadata.connectionMetadata?.setKeepalive(keepAlive: 1)
                    }
                }

                // Negative assertion: no error may arrive while time passes beyond the idle timeout.
                harness.allow(.seconds(3))
                XCTAssertNil(networkError, "Connection did not stay alive across the idle timeout")
            }
        )
    }

    func testQUICClientKeepAliveWithLowTimeoutAndPMTUDDisabled() throws {
        // This test is expected to timeout because the idleTimeout is set to 2 seconds.
        // The handshake starts up and no data is transferred, so the connection should timeout after 2 seconds.
        // Note that the keep-alive interval does keep the connection alive,
        // since the PMTUD probe is disabled.
        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { $0.idleTimeout = .seconds(2) }
        clientOptions.modifyConnectionOptions { $0.pmtud = false }
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { $0.pmtud = false }

        var networkError: NetworkError? = nil

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions,
            afterHandshake: { harness in
                harness.onContext {
                    harness.state?.clientHarness.waitForError { error in
                        networkError = error
                    }

                    if let metadata: ProtocolMetadata<QUICProtocol> = harness.state?.clientHarness.getMetadata() {
                        // Add keep-alive for 1 second intervals
                        metadata.connectionMetadata?.setKeepalive(keepAlive: 1)
                    }
                }

                // Negative assertion: no error may arrive while time passes beyond the idle timeout.
                harness.allow(.seconds(3))
                XCTAssertNil(networkError, "Connection did not stay alive across the idle timeout")
            }
        )
    }
}
#endif
#endif
#endif
