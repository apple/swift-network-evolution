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
class QUICPathValidationMessageTests: XCTestCase {
    let logString = "PathValidationTests"
    var connection: QUICConnection!
    var path: QUICPath!  // NOTE: This path immediately transitions to cid assigned due to setup()

    override func setUp() {
        connection = NetworkContext.implicitContext.onQueue {
            QUICConnection(context: NetworkContext.implicitContext)
        }
        path = connection.context.onQueue {
            QUICPath.makeFromExternalTest(parent: self.connection)
        }
        path.set(interface: nil, priority: 0, isInitial: true)
        connection.context.onQueue {
            connection.fromExternal { eventContext in
                path.assignDCID(QUICConnectionID(8), in: &eventContext)
            }
        }
    }

    override func tearDown() {
        // The path and the connection were both built outside a protocol stack, so nothing else
        // releases their event states.
        connection.context.onQueue {
            self.path.destroyFromExternalTest()
            self.connection.destroyFromExternalTest()
        }
        path = nil
        connection = nil
    }

    func testIncomingPathChallenge() {
        // challenge received from a path that is not validated
        let challenge = FramePathChallenge(data: 1)
        XCTAssertEqual(path.challengesSent, 0)
        let _ = connection.context.onQueue {
            connection.fromExternal { eventContext in
                connection.handlePathChallengeFrame(challenge, path: path, in: &eventContext)
            }
        }
        XCTAssertEqual(path.pendingInboundChallenges.count, 1)
        XCTAssertEqual(path.state, .probing)
        XCTAssertEqual(path.pendingOutboundChallenges.count, 0)

        // challenge received on a path that is validated, should just generate response
        path.changeState(to: .validated)
        let challenge2 = FramePathChallenge(data: 2)
        let _ = connection.context.onQueue {
            connection.fromExternal { eventContext in
                connection.handlePathChallengeFrame(challenge2, path: path, in: &eventContext)
            }
        }
        // pending challenges are not cleared until they are processed
        XCTAssertEqual(path.pendingInboundChallenges.count, 2)
        XCTAssertEqual(path.state, .validated)  // we remain validated when the peer re-probes
    }

    func testOutgoingPathChallenge() {
        self.connection.context.onQueue {
            XCTAssertEqual(path.state, .cidAssigned)

            let startTime = NetworkClock.Instant.systemNow
            var pendingItems = PendingItems(packetNumberSpace: .applicationData)
            connection.fromExternal { eventContext in
                path.addPendingItems(&pendingItems, now: startTime, in: &eventContext)
            }  // should be empty
            XCTAssertTrue(pendingItems.pathChallenges.isEmpty)
            XCTAssertTrue(pendingItems.pathResponses.isEmpty)

            // Add incoming and outgoing challenges. These will produce path-specific PendingItems
            connection.fromExternal { eventContext in
                path.beginValidation(in: &eventContext)
            }
            XCTAssertEqual(path.state, .probing)
            XCTAssertEqual(path.pendingOutboundChallenges.count, 0)
            connection.fromExternal { eventContext in
                path.handlePathChallenge(1, in: &eventContext)
            }
            XCTAssertEqual(path.pendingInboundChallenges.count, 1)
            connection.fromExternal { eventContext in
                path.addPendingItems(&pendingItems, now: startTime, in: &eventContext)
            }

            XCTAssertFalse(pendingItems.pathChallenges.isEmpty)
            XCTAssertFalse(pendingItems.pathResponses.isEmpty)
            XCTAssertEqual(path.pendingInboundChallenges.count, 0)

            let outboundChallenge = pendingItems.pathChallenges.first?.data ?? 0

            XCTAssertEqual(path.lastChallengeSentTime, startTime)
            XCTAssertEqual(path.nextChallengeDuration, .milliseconds(250))

            pendingItems = PendingItems(packetNumberSpace: .applicationData)  // clear items
            // simulate send on the path before the challenge retransmission time is met
            var interval = NetworkDuration.milliseconds(100)
            connection.fromExternal { eventContext in
                path.addPendingItems(&pendingItems, now: startTime + interval, in: &eventContext)
            }
            XCTAssertTrue(pendingItems.pathChallenges.isEmpty)
            XCTAssertTrue(pendingItems.pathResponses.isEmpty)

            // simulate a retransmission of the challenge
            interval = NetworkDuration.milliseconds(250)
            connection.fromExternal { eventContext in
                path.addPendingItems(&pendingItems, now: startTime + interval, in: &eventContext)
            }
            XCTAssertFalse(pendingItems.pathChallenges.isEmpty)
            XCTAssertTrue(pendingItems.pathResponses.isEmpty)

            connection.fromExternal { eventContext in
                path.handlePathChallengeResponse(outboundChallenge, in: &eventContext)
            }
            XCTAssertEqual(path.state, .validated)
            XCTAssertEqual(path.pendingOutboundChallenges.count, 0)
        }
    }

    // MARK: The packet builder's stream borrow relies on the send path being claimed

    // Runs `body` with one stream in the connection's stream table, and removes it afterwards.
    private func withStream(_ body: (MultiplexedFlowIdentifier) -> Void) {
        connection.context.onQueue {
            let stream = QUICStreamInstance(parent: connection, inbound: true)
            let streamID = stream.flowIdentifier
            connection.insertFlow(stream, for: streamID)
            defer {
                connection.fromExternal { eventContext in
                    if var stream = connection.removeFlow(streamID) {
                        stream.releaseResources()
                        stream.unregisterEventManager(in: &eventContext)
                    }
                }
            }
            body(streamID)
        }
    }

    // The packet builder borrows a stream while it holds the send path. That borrow does not mark a flow
    // as borrowed, because nothing it does can defer work, so only the send path keeps sends out.
    func testBuilderBorrowRunsUnderTheClaimedSendPathWithoutMarkingAFlowBorrowed() {
        withStream { streamID in
            let wasActive = connection.stateMachine.claimSendPath()
            var ran = false
            let borrowed: Void? = connection.withStreamBorrowed(streamID) { (_: inout QUICStreamInstance) in
                ran = true
                XCTAssertTrue(connection.stateMachine.isSendActive)
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
                #if DEBUG
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
                #endif
            }
            XCTAssertNotNil(borrowed)
            XCTAssertTrue(ran)
            #if DEBUG
            XCTAssertFalse(connection.stateMachine.isBorrowed(.streams))
            #endif
            // Nothing waited, so releasing the send path has nothing to replay
            XCTAssertFalse(connection.stateMachine.releaseSendPath(wasActive: wasActive))
            XCTAssertFalse(connection.stateMachine.isSendActive)
        }
    }

    // A send asked for from inside the builder's borrow is held back by the claimed send path, even though
    // no flow is marked borrowed, and nothing reaches the stream table. It is ready when the path is released.
    func testSendRequestedInsideBuilderBorrowIsHeldBackBySendPath() {
        withStream { streamID in
            let wasActive = connection.stateMachine.claimSendPath()
            var sent = true
            _ = connection.withStreamBorrowed(streamID) { (_: inout QUICStreamInstance) in
                sent = connection.fromExternal { eventContext in
                    connection.sendFrames(ignoreCongestionWindow: true, delayedACK: false, in: &eventContext)
                }
            }
            XCTAssertFalse(sent)
            XCTAssertTrue(connection.stateMachine.hasDeferredSends)
            XCTAssertTrue(connection.stateMachine.releaseSendPath(wasActive: wasActive))
            XCTAssertEqual(connection.stateMachine.takePlainSend()?.ignoreCongestionWindow, true)
        }
    }

    // A caller that claims the send path without checking for a flow borrow, as the timers do, is safe when
    // a flow is borrowed: sends stay held back, releasing does not replay them (the flow borrow still
    // holds them), and the outermost flow borrow reports them when it ends.
    func testClaimingTheSendPathInsideAFlowBorrowLeavesTheReplayToTheBorrow() {
        withStream { streamID in
            var released = true
            _ = connection.performOnStream(streamID) { (_: inout QUICStreamInstance) in
                let wasActive = connection.stateMachine.claimSendPath()
                XCTAssertTrue(connection.stateMachine.isSendBlocked)
                connection.stateMachine.deferSend(ignoreCongestionWindow: false, delayedACK: false)
                released = connection.stateMachine.releaseSendPath(wasActive: wasActive)
                XCTAssertTrue(connection.stateMachine.isFlowBorrowed)
            }
            XCTAssertFalse(released)
            // The borrow's own end replayed the send, so nothing is left waiting
            XCTAssertFalse(connection.stateMachine.hasDeferredSends)
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
            XCTAssertFalse(connection.stateMachine.isSendActive)
        }
    }

    // A send path claimed inside a flow borrow that ends first is still held by the claim, so the borrow
    // leaves the replay to the release.
    func testFlowBorrowEndingInsideAClaimedSendPathLeavesTheReplayToTheRelease() {
        withStream { streamID in
            let wasActive = connection.stateMachine.claimSendPath()
            let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
            connection.stateMachine.deferSend(ignoreCongestionWindow: false, delayedACK: true)
            let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
            XCTAssertNil(work)
            XCTAssertTrue(connection.stateMachine.releaseSendPath(wasActive: wasActive))
            XCTAssertEqual(connection.stateMachine.takePlainSend()?.delayedACK, true)
            _ = streamID
        }
    }
}

#endif
