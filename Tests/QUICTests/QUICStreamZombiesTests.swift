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

@available(Network 0.1.0, *)
final class QUICStreamZombieListTests: XCTestCase {
    var zombieList = QUICStreamZombieList()

    func testAppend() {
        NetworkContext.implicitContext.async {
            let connection = QUICConnection(context: NetworkContext.implicitContext)
            defer { connection.destroyFromExternalTest() }
            connection.fromExternal { eventContext in
                let streamID: QUICStreamID = QUICStreamID(0)
                self.zombieList.append(
                    logIDString: "QUICStreamZombieListTests:\(#function)",
                    streamID: streamID,
                    lastSize: 0,
                    localMaxStreamData: 0
                )
                let zombie = self.zombieList.find(streamID: streamID)
                XCTAssertNotNil(zombie)
                self.zombieList.finalSizeReceived(
                    logIDString: "QUICStreamZombieListTests:\(#function)",
                    streamID: streamID,
                    finalSize: 42,
                    connection: connection,
                    in: &eventContext
                )
                XCTAssertNil(self.zombieList.find(streamID: streamID))
            }
        }
    }
}

#endif
