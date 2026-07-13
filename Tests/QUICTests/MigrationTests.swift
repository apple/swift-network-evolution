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

@available(Network 0.1.0, *)
let migrationTestsLogPrefixer: LogPrefixer = LogPrefixer("[MigrationTests]")

@available(Network 0.1.0, *)
final class MigrationTests: XCTestCase {
    var connection = QUICConnection(context: .implicitContext)

    static let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
    static let newCID = QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!

    override func setUp() {
        let expectation = XCTestExpectation()
        connection.context.async {
            try? self.connection.setup(remote: nil, local: nil, parameters: nil, path: nil)
            self.connection.recovery = Recovery(logPrefixer: migrationTestsLogPrefixer)
            self.connection.recovery.connection = self.connection
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    override func tearDown() {
        self.connection.currentPath = nil
    }

    // Builds a path that is open for sending, backed by a lower harness, with its DCID
    // registered in `remoteCIDs` so it can be retired. `validated` drives it to the
    // validated state so `migrate(to:)` will accept it.
    private func makePath(dcid: QUICConnectionID, sequenceNumber: UInt64, validated: Bool) -> QUICPath {
        let lower = DatagramLowerHarness(identifier: "\(sequenceNumber)", context: .implicitContext)
        lower.connect()
        var path = QUICPath(parent: connection)
        path.set(interface: nil, priority: 1, isInitial: true)  // -> .routeEstablished
        path.assignDCID(dcid)  // -> .cidAssigned (open for sending)
        if validated {
            path.changeState(to: .probing)
            path.changeState(to: .validated)
        }
        try? path.attachLowerProtocol(lower.reference, remote: nil, local: nil, parameters: nil, path: nil)
        try? connection.remoteCIDs.insert(
            sequenceNumber: sequenceNumber,
            connectionID: dcid,
            token: QUICStatelessResetToken(Array(repeating: UInt8(sequenceNumber & 0xff), count: 16))!
        )
        return path
    }

    func testMigrationRemovesOldPathAndRetiresItsCID() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)

            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.identifier] = oldPath
            self.connection.multiplexingPaths[newPath.identifier] = newPath
            let oldPathID = oldPath.identifier

            self.connection.migration.migrate(to: newPath, connection: self.connection)

            // The path we migrated away from is dropped from the connection and its
            // remote CID is retired.
            XCTAssertNil(self.connection.multiplexingPaths[oldPathID], "old path should be removed from multiplexingPaths")
            XCTAssertNil(
                self.connection.remoteCIDs.retire(connectionID: Self.oldCID),
                "old path's remote CID should be retired by migration"
            )

            // Only the new path remains, and it is now the current path.
            XCTAssertEqual(self.connection.multiplexingPaths.count, 1, "old path should not linger in multiplexingPaths")
            XCTAssertEqual(self.connection.currentPath?.identifier, newPath.identifier, "current path should be the new path")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
