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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
#if !NETWORK_PRIVATE
// Uses cross module API for testing
@available(Network 0.1.0, *)
final class SwiftNetworkQUICCIDTests: NetTestCase {

    func testQUICRetiredOutboundConnectionIDIncludesStatelessResetToken() {
        var retiredConnectionID: QUICConnectionID?
        var retiredStatelessResetToken: QUICStatelessResetToken?
        var expectedConnectionID: QUICConnectionID?
        var expectedStatelessResetToken: QUICStatelessResetToken?

        QUICTestHarness().runQUICTest(
            afterHandshake: { harness in
                let expectation = XCTestExpectation(description: "Wait for retired outbound connection ID event")
                harness.context.async {
                    defer { expectation.fulfill() }
                    guard let clientInstance = harness.state?.clientInstance,
                        let clientHarness = harness.state?.clientHarness,
                        let dcid = clientInstance.currentPath?.dcid
                    else {
                        XCTFail("State needs to be present to proceed")
                        return
                    }

                    expectedConnectionID = dcid
                    expectedStatelessResetToken = clientInstance.remoteCIDs.find(connectionID: dcid)?.token
                    XCTAssertNotNil(
                        expectedStatelessResetToken,
                        "The server's connection ID should have an associated stateless reset token"
                    )

                    clientHarness.invokeApplicationEvent(.init(quicEvent: .retireOutboundConnectionID(dcid)))

                    XCTAssertEqual(clientHarness.retiredOutboundCIDEventCount, 1)
                    retiredConnectionID = clientHarness.lastRetiredOutboundConnectionID
                    retiredStatelessResetToken = clientHarness.lastRetiredOutboundStatelessResetToken
                }
                self.wait(for: [expectation], timeout: 5.0)
            }
        )

        XCTAssertEqual(retiredConnectionID, expectedConnectionID)
        XCTAssertNotNil(retiredStatelessResetToken)
        XCTAssertEqual(retiredStatelessResetToken, expectedStatelessResetToken)
    }

}
#endif
#endif
#endif
#endif
