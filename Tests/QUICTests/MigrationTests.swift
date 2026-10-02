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
let migrationTestsLogPrefixer: LogPrefixer = LogPrefixer("[MigrationTests]")

@available(Network 0.1.0, *)
final class MigrationTests: XCTestCase {
    var connection = QUICConnection(context: .implicitContext)
    // The base linkages are storage-backed, so lower harnesses have to come from storage
    // rather than being wrapped in a bare linkage.
    let storage = TestNetworkProtocolStorage(context: .implicitContext)

    static let oldCID = QUICConnectionID([0xA1, 0xA2, 0xA3, 0xA4])!
    static let newCID = QUICConnectionID([0xB1, 0xB2, 0xB3, 0xB4])!
    static let thirdCID = QUICConnectionID([0xC1, 0xC2, 0xC3, 0xC4])!
    static let preferredCID = QUICConnectionID([0xD1, 0xD2, 0xD3, 0xD4])!

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
        // The paths built by `makePath` outlive the test body, and migration only destroys the
        // one it migrated away from, so release whatever is left.
        self.connection.context.onQueue {
            for path in self.connection.multiplexingPaths.values {
                path.destroyFromExternalTest()
            }
        }
        self.connection.multiplexingPaths.removeAll()
    }

    // Builds a path that is open for sending, backed by a lower harness, with its DCID
    // registered in `remoteCIDs` so it can be retired. `validated` drives it to the
    // validated state so `migrate(to:)` will accept it.
    private func makePath(dcid: QUICConnectionID, sequenceNumber: UInt64, validated: Bool) -> QUICPath {
        let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
            identifier: "\(sequenceNumber)",
            context: .implicitContext
        )
        lower.fromExternal { eventContext in
            lower.connect(in: &eventContext)
        }
        // Every caller builds its paths from inside `context.async`, so this runs on the context.
        var path = QUICPath.makeFromExternalTest(parent: self.connection)
        path.set(interface: nil, priority: 1, isInitial: true)  // -> .routeEstablished
        path.assignDCID(dcid)  // -> .cidAssigned (open for sending)
        if validated {
            path.changeState(to: .probing)
            path.changeState(to: .validated)
        }
        // The path is a framework protocol, so it is bound through the base form of the
        // harness's linkage.
        _ = try? path.attachLowerProtocol(lowerLinkage.base)
        try? lowerLinkage.base.invokeAttachUpperProtocol(
            path.asUpperLinkage(),
            remote: nil,
            local: nil,
            parameters: nil,
            path: nil
        )
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
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath
            let oldPathID = oldPath.pathIdentifier

            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: newPath,
                    connection: self.connection,
                    in: &eventContext
                )
            }

            // The path we migrated away from is dropped from the connection and its
            // remote CID is retired.
            XCTAssertNil(
                self.connection.multiplexingPaths[oldPathID],
                "Old path not removed"
            )
            XCTAssertNil(
                self.connection.remoteCIDs.retire(connectionID: Self.oldCID),
                "Old path CID not retired"
            )

            // Only the new path remains, and it is now the current path.
            XCTAssertEqual(
                self.connection.multiplexingPaths.count,
                1,
                "Unexpected path count"
            )
            XCTAssertEqual(
                self.connection.currentPath?.identifier,
                newPath.identifier,
                "Current path not switched"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // `Timer` fires an entry up to `Timer.timerThreshold` before its deadline and disables it
    // first, so the migration handler can be woken with an instant that precedes the challenge it
    // woke for. It must re-arm anyway; otherwise probing stalls on an otherwise idle path until an
    // unrelated event happens to arm the timer again.
    func testMigrationTimerRearmsWhenFiredInsideTimerLeeway() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            path.changeState(to: .probing)

            // Send the first challenge, which sets the next challenge deadline and arms the timer.
            let base = NetworkClock.Instant.testBase
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            self.connection.fromExternal { eventContext in
                path.addPathChallenge(to: &pendingItems, now: base, in: &eventContext)
            }
            guard let nextChallengeTime = path.nextChallengeTime else {
                XCTFail("First challenge did not schedule a follow-up")
                expectation.fulfill()
                return
            }
            XCTAssertEqual(self.connection.timer.nextDeadline, nextChallengeTime)

            // Wake one microsecond early, which is inside the leeway window `Timer` allows. Go
            // through `Timer.timerFired`, since that is what disables the entry before handing the
            // instant to the handler.
            self.connection.fromExternal { eventContext in
                self.connection.timer.timerFired(
                    at: nextChallengeTime.advanced(by: .microseconds(-1)),
                    in: &eventContext
                )
            }

            XCTAssertEqual(
                self.connection.timer.nextDeadline,
                nextChallengeTime,
                "Migration timer left disarmed after an early fire"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Migration Policy Tests

    func testMigrationPolicyDerivedCorrectly() {
        let expectation = XCTestExpectation()
        connection.context.async {
            // Default: migration is enabled
            var migration = Migration()
            migration.derivePolicy(hasPreferredAddress: false)
            XCTAssertEqual(migration.policy.description, "enabled")
            XCTAssertTrue(migration.policy.allowsActiveMigration)
            XCTAssertTrue(migration.policy.allowsPreferredAddress)

            // Disabled active migration, no preferred address
            migration.disableActiveMigration()
            migration.derivePolicy(hasPreferredAddress: false)
            XCTAssertEqual(migration.policy.description, "disabled")
            XCTAssertFalse(migration.policy.allowsActiveMigration)
            XCTAssertFalse(migration.policy.allowsPreferredAddress)

            // Disabled active migration, but has preferred address
            migration.derivePolicy(hasPreferredAddress: true)
            XCTAssertEqual(migration.policy.description, "preferredAddressOnly")
            XCTAssertFalse(migration.policy.allowsActiveMigration)
            XCTAssertTrue(migration.policy.allowsPreferredAddress)

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testMigrationStateTransitions() {
        let expectation = XCTestExpectation()
        connection.context.async {
            // Initially idle
            XCTAssertEqual(
                self.connection.migration.migrationState.description,
                "idle"
            )

            let unvalidatedPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            let validatedPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)
            self.connection.currentPath = unvalidatedPath
            self.connection.multiplexingPaths[unvalidatedPath.pathIdentifier] = unvalidatedPath
            self.connection.multiplexingPaths[validatedPath.pathIdentifier] = validatedPath

            // Migrating to a validated path goes through migrating -> idle
            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: validatedPath,
                    connection: self.connection,
                    in: &eventContext
                )
            }
            XCTAssertEqual(
                self.connection.migration.migrationState.description,
                "idle",
                "Migration state should return to idle after successful migration"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Preferred Address Tests

    func testPreferredAddressIsStoredForLaterMigration() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let preferredAddress = PreferredAddress(
                connectionID: Self.preferredCID,
                statelessResetToken: QUICStatelessResetToken(Array(repeating: 0xDD, count: 16))!,
                ipv4Port: 443,
                ipv4Address: 0x7F000001,  // 127.0.0.1
                ipv6Port: 443,
                ipv6Address: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
            )

            self.connection.migration.addPreferredAddress(preferredAddress)
            XCTAssertNotNil(
                self.connection.migration.pendingPreferredAddress,
                "Preferred address should be stored"
            )
            XCTAssertEqual(
                self.connection.migration.pendingPreferredAddress?.connectionID,
                Self.preferredCID
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testPreferredAddressNotAttemptedOnServer() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let preferredAddress = PreferredAddress(
                connectionID: Self.preferredCID,
                statelessResetToken: QUICStatelessResetToken(Array(repeating: 0xDD, count: 16))!,
                ipv4Port: 443,
                ipv4Address: 0x7F000001,
                ipv6Port: 443,
                ipv6Address: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
            )

            self.connection.migration.addPreferredAddress(preferredAddress)
            // Simulate server
            self.connection.migration.handshakeConfirmed(self.connection)

            XCTAssertFalse(
                self.connection.migration.preferredAddressAttempted,
                "Server should not attempt preferred address migration"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - CID Lifecycle Tests

    func testNewDCIDIsTracked() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let cid = QUICConnectionID([0x01, 0x02, 0x03, 0x04])!
            self.connection.migration.newDCID(cid)
            XCTAssertEqual(
                self.connection.migration.pendingDCIDs.count,
                1,
                "New DCID should be tracked"
            )
            XCTAssertEqual(self.connection.migration.pendingDCIDs.first, cid)

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testRetireDCIDRemovesFromPending() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let cid = QUICConnectionID([0x01, 0x02, 0x03, 0x04])!
            self.connection.migration.newDCID(cid)
            XCTAssertEqual(self.connection.migration.pendingDCIDs.count, 1)

            self.connection.migration.retireDCID(cid)
            XCTAssertEqual(
                self.connection.migration.pendingDCIDs.count,
                0,
                "Retired DCID should be removed from pending list"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testDuplicateCIDRetirementIsIdempotent() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let cid = QUICConnectionID([0x01, 0x02, 0x03, 0x04])!
            self.connection.migration.newDCID(cid)
            self.connection.migration.retireDCID(cid)
            // Second retirement of the same CID should not crash
            self.connection.migration.retireDCID(cid)
            XCTAssertEqual(
                self.connection.migration.pendingDCIDs.count,
                0,
                "Double retirement should be idempotent"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Path Lifecycle Tests

    func testPathRoleSetCorrectlyOnMigration() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)

            self.connection.currentPath = oldPath
            oldPath.pathRole = .primary
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath

            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: newPath,
                    connection: self.connection,
                    in: &eventContext
                )
            }

            // New path should be primary
            XCTAssertEqual(
                newPath.pathRole.description,
                "primary",
                "New path should be marked as primary"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testPathValidationAttemptsTracked() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path

            XCTAssertEqual(path.validationAttempts, 0, "Should start with 0 validation attempts")

            // Begin validation should increment attempts
            path.changeState(to: .probing)
            // Simulate re-validation by going through validated -> probing
            path.changeState(to: .validated)
            path.beginValidation(ifNecessary: false)
            XCTAssertEqual(
                path.validationAttempts,
                1,
                "Validation attempt should be tracked"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testPathFailureReasonSetOnValidationTimeout() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            path.changeState(to: .probing)

            let base = NetworkClock.Instant.testBase
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)

            // Exhaust all challenge attempts
            self.connection.fromExternal { eventContext in
                for i in 0..<QUICPath.maximumPendingChallenges {
                    let now = base.advanced(by: .seconds(i * 10))
                    path.addPathChallenge(to: &pendingItems, now: now, in: &eventContext)
                }
                // One more should trigger unreachable
                let finalTime = base.advanced(by: .seconds(QUICPath.maximumPendingChallenges * 10))
                path.addPathChallenge(to: &pendingItems, now: finalTime, in: &eventContext)
            }

            XCTAssertEqual(
                path.failureReason?.description,
                "validationTimeout",
                "Path failure reason should be validationTimeout"
            )
            XCTAssertEqual(path.state, .unreachable, "Path should be unreachable")
            XCTAssertEqual(path.pathRole.description, "retired", "Path should be retired")

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testOldPathCIDRetiredNotActivePathCID() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)

            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath

            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: newPath,
                    connection: self.connection,
                    in: &eventContext
                )
            }

            // The old path's CID should have been retired
            XCTAssertNil(
                self.connection.remoteCIDs.find(connectionID: Self.oldCID),
                "Old path's CID should be retired"
            )

            // The new (active) path's CID should NOT have been retired
            XCTAssertNotNil(
                self.connection.remoteCIDs.find(connectionID: Self.newCID),
                "Active path's CID should NOT be retired"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testMigrationStatisticsIncremented() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let oldPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let newPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: true)

            self.connection.currentPath = oldPath
            self.connection.multiplexingPaths[oldPath.pathIdentifier] = oldPath
            self.connection.multiplexingPaths[newPath.pathIdentifier] = newPath

            let migrationsBefore = self.connection.stats[.successfulMigrations]
            let retirementsBefore = self.connection.stats[.cidRetirements]

            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: newPath,
                    connection: self.connection,
                    in: &eventContext
                )
            }

            XCTAssertEqual(
                self.connection.stats[.successfulMigrations],
                migrationsBefore + 1,
                "Successful migration count should increment"
            )
            XCTAssertEqual(
                self.connection.stats[.cidRetirements],
                retirementsBefore + 1,
                "CID retirement count should increment"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Keepalive Loss Tests

    func testKeepaliveLossResetsOnAcknowledge() {
        let expectation = XCTestExpectation()
        connection.context.async {
            // Simulate keepalive losses below threshold
            self.connection.fromExternal { eventContext in
                self.connection.migration.checkForKeepaliveLoss(
                    outstandingCount: 1,
                    connection: self.connection,
                    in: &eventContext
                )
            }
            XCTAssertEqual(
                self.connection.migration.consecutiveKeepaliveLosses,
                1
            )

            // Acknowledge resets
            self.connection.fromExternal { eventContext in
                self.connection.migration.checkForKeepaliveLoss(
                    outstandingCount: 0,
                    connection: self.connection,
                    in: &eventContext
                )
            }
            XCTAssertEqual(
                self.connection.migration.consecutiveKeepaliveLosses,
                0,
                "Counter should reset when outstanding count drops to 0"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Path Selection Tests

    func testSelectBestPathReturnsCurrentWhenNoAlternate() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path

            let best = self.connection.selectBestPath()
            XCTAssertEqual(
                best?.identifier,
                path.identifier,
                "Should return current path when no alternate exists"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testMigrationToSamePathIsNoOp() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path

            let migrationsBefore = self.connection.stats[.successfulMigrations]

            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: path,
                    connection: self.connection,
                    in: &eventContext
                )
            }

            // Should be a no-op
            XCTAssertEqual(
                self.connection.stats[.successfulMigrations],
                migrationsBefore,
                "Migrating to the same path should not increment counter"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testMigrationToUnvalidatedPathSetsAwaitingValidation() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let currentPath = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            let unvalidatedPath = self.makePath(dcid: Self.newCID, sequenceNumber: 2, validated: false)

            self.connection.currentPath = currentPath
            self.connection.multiplexingPaths[currentPath.pathIdentifier] = currentPath
            self.connection.multiplexingPaths[unvalidatedPath.pathIdentifier] = unvalidatedPath

            self.connection.fromExternal { eventContext in
                self.connection.migration.migrate(
                    to: unvalidatedPath,
                    connection: self.connection,
                    in: &eventContext
                )
            }

            // Should not have migrated yet
            XCTAssertEqual(
                self.connection.currentPath?.identifier,
                currentPath.identifier,
                "Should not migrate to unvalidated path immediately"
            )
            XCTAssertEqual(
                self.connection.migration.migrationState.description,
                "awaitingValidation",
                "State should be awaitingValidation"
            )
            XCTAssertTrue(
                unvalidatedPath.migrationPending,
                "Path should have migrationPending flag"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testPathLastActivityTimeUpdated() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: false)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path
            path.changeState(to: .probing)

            XCTAssertEqual(
                path.lastActivityTime,
                .zero,
                "Last activity should be zero before any challenge"
            )

            let base = NetworkClock.Instant.testBase
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            self.connection.fromExternal { eventContext in
                path.addPathChallenge(to: &pendingItems, now: base, in: &eventContext)
            }

            XCTAssertEqual(
                path.lastActivityTime,
                base,
                "Last activity should be updated after sending challenge"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }

    func testRefuseToTearDownCurrentPath() {
        let expectation = XCTestExpectation()
        connection.context.async {
            let path = self.makePath(dcid: Self.oldCID, sequenceNumber: 1, validated: true)
            self.connection.currentPath = path
            self.connection.multiplexingPaths[path.pathIdentifier] = path

            let pathCountBefore = self.connection.multiplexingPaths.count

            // Attempting to tear down the current path should be refused
            self.connection.fromExternal { eventContext in
                self.connection.tearDownMigratedPath(path, in: &eventContext)
            }

            XCTAssertEqual(
                self.connection.multiplexingPaths.count,
                pathCountBefore,
                "Current path should not be torn down"
            )
            XCTAssertEqual(
                self.connection.currentPath?.identifier,
                path.identifier,
                "Current path should remain unchanged"
            )

            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
    }
}

#endif
