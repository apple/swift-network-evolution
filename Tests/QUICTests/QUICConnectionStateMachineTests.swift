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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#endif
#if canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif
#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if !NETWORK_NO_SWIFT_QUIC
// How the connection uses its state machine: what it holds back while a flow is borrowed or the
// send path is active, and what it keeps.
@available(Network 0.1.0, *)
final class QUICConnectionStateMachineTests: XCTestCase {

    // Runs `body` with a connection and one stream and one datagram flow in its flow tables.
    func withConnection(
        _ body: (QUICConnection, MultiplexedFlowIdentifier, MultiplexedFlowIdentifier) -> Void
    ) {
        let clock = TestClockContext("QUICConnectionStateMachineTests")
        let connection = clock.onQueue { QUICConnection(context: clock.context) }
        let (streamID, datagramID) = clock.onQueue { () -> (MultiplexedFlowIdentifier, MultiplexedFlowIdentifier) in
            let stream = QUICStreamInstance(parent: connection, inbound: true)
            let streamID = stream.flowIdentifier
            connection.insertFlow(stream, for: streamID)
            let datagram = QUICDatagramFlow(parent: connection, inbound: true)
            let datagramID = datagram.flowIdentifier
            connection.insertSecondaryFlow(datagram, for: datagramID)
            return (streamID, datagramID)
        }
        defer {
            clock.onQueue {
                connection.fromExternal { eventContext in
                    if var stream = connection.removeFlow(streamID) {
                        stream.releaseResources()
                        stream.unregisterEventManager(in: &eventContext)
                    }
                    if var datagram = connection.removeSecondaryFlow(datagramID) {
                        datagram.unregisterEventManager(in: &eventContext)
                    }
                }
                connection.destroyFromExternalTest()
            }
        }
        clock.onQueue { body(connection, streamID, datagramID) }
    }

    // MARK: Borrowing

    func testStreamBorrowMarksTheConnectionBorrowedOnlyWhileItRuns() {
        withConnection { connection, streamID, _ in
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
            let ran: Void? = connection.performOnStream(streamID) { (_: inout QUICStreamInstance) in
                XCTAssertTrue(connection.stateMachine.isFlowBorrowed)
            }
            XCTAssertNotNil(ran)
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
        }
    }

    func testBorrowingAnUnknownStreamLeavesTheConnectionIdle() {
        withConnection { connection, _, _ in
            let unknown = MultiplexedFlowIdentifier(testValue: 0xDEAD_BEEF)
            var ran = false
            let result: Void? = connection.performOnStream(unknown) { (_: inout QUICStreamInstance) in
                ran = true
            }
            XCTAssertNil(result)
            XCTAssertFalse(ran)
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
        }
    }

    func testDatagramFlowBorrowMarksTheConnectionBorrowedOnlyWhileItRuns() {
        withConnection { connection, _, datagramID in
            let ran: Void? = connection.performOnDatagramFlow(datagramID) { (_: inout QUICDatagramFlow) in
                XCTAssertTrue(connection.stateMachine.isFlowBorrowed)
            }
            XCTAssertNotNil(ran)
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
        }
    }

    // A datagram flow can be reached from inside a stream. Finishing the inner borrow must not
    // release the connection while the stream is still borrowed.
    func testNestedBorrowKeepsTheConnectionBorrowedUntilTheOuterOneEnds() {
        withConnection { connection, streamID, datagramID in
            let ran: Void? = connection.performOnStream(streamID) { (_: inout QUICStreamInstance) in
                _ = connection.performOnDatagramFlow(datagramID) { (_: inout QUICDatagramFlow) in
                    XCTAssertTrue(connection.stateMachine.isFlowBorrowed)
                }
                XCTAssertTrue(connection.stateMachine.isFlowBorrowed)
            }
            XCTAssertNotNil(ran)
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
        }
    }

    func testBorrowEndsWhenTheBodyThrows() {
        struct Boom: Error {}
        withConnection { connection, streamID, datagramID in
            do throws(Boom) {
                _ = try connection.performOnStream(streamID) { (_: inout QUICStreamInstance) throws(Boom) in
                    throw Boom()
                }
                XCTFail("Expected the body's error to propagate")
            } catch {}
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)

            do throws(Boom) {
                _ = try connection.performOnDatagramFlow(datagramID) { (_: inout QUICDatagramFlow) throws(Boom) in
                    throw Boom()
                }
                XCTFail("Expected the body's error to propagate")
            } catch {}
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
        }
    }

    // MARK: Which table is borrowed (tracked in debug builds only)

    #if DEBUG
    // Every way of borrowing a table notes it for as long as the borrow lasts, so that borrowing the
    // same table again, such as from an upper protocol callback, is caught with a message that says
    // which table. The assertion itself cannot be tested, since it stops the process.
    func testEveryRouteIntoTheFlowTablesNotesTheBorrow() {
        withConnection { connection, streamID, datagramID in
            func idle() {
                XCTAssertFalse(connection.stateMachine.isBorrowed(.streams))
                XCTAssertFalse(connection.stateMachine.isBorrowed(.secondary))
            }
            idle()

            _ = connection.performOnStream(streamID) { (_: inout QUICStreamInstance) in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
                XCTAssertFalse(connection.stateMachine.isBorrowed(.secondary))
            }
            idle()

            _ = connection.performOnDatagramFlow(datagramID) { (_: inout QUICDatagramFlow) in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.secondary))
                XCTAssertFalse(connection.stateMachine.isBorrowed(.streams))
            }
            idle()

            // The routes that do not defer work note the table too
            _ = connection.withFlow(streamID) { (_: inout QUICStreamInstance) in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
            }
            idle()
            _ = connection.withSecondaryFlow(datagramID) { (_: inout QUICDatagramFlow) in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.secondary))
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
            }
            idle()
            connection.applyToAllFlows { _ in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
            }
            idle()
            connection.applyToAllSecondaryFlows { _ in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.secondary))
            }
            idle()
            // The packet builder's borrow is only used while the send path is claimed
            let wasActive = connection.stateMachine.claimSendPath()
            _ = connection.withStreamBorrowed(streamID) { (_: inout QUICStreamInstance) in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
            }
            connection.stateMachine.releaseSendPath(wasActive: wasActive)
            idle()
        }
    }

    // A datagram flow can be reached from inside a stream: different tables, so both are borrowed at once
    func testBothTablesCanBeBorrowedAtOnce() {
        withConnection { connection, streamID, datagramID in
            _ = connection.performOnStream(streamID) { (_: inout QUICStreamInstance) in
                _ = connection.performOnDatagramFlow(datagramID) { (_: inout QUICDatagramFlow) in
                    XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
                    XCTAssertTrue(connection.stateMachine.isBorrowed(.secondary))
                }
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
                XCTAssertFalse(connection.stateMachine.isBorrowed(.secondary))
            }
            XCTAssertFalse(connection.stateMachine.isBorrowed(.streams))
        }
    }

    func testTableBorrowEndsWhenTheBodyThrows() {
        struct Boom: Error {}
        withConnection { connection, streamID, _ in
            do throws(Boom) {
                _ = try connection.withFlow(streamID) { (_: inout QUICStreamInstance) throws(Boom) in
                    throw Boom()
                }
                XCTFail("Expected the body's error to propagate")
            } catch {}
            XCTAssertFalse(connection.stateMachine.isBorrowed(.streams))
            // And the table can be borrowed again
            _ = connection.withFlow(streamID) { (_: inout QUICStreamInstance) in }
        }
    }
    #endif

    // A flow asks its connection to service the data it has queued while it is borrowed from the flow table,
    // because that is where its upper protocol's write arrives. The connection must work from the flow it
    // is given and must not look it up again, or it would borrow a table that is already borrowed. In
    // debug builds a second borrow of a table asserts, so this fails loudly if that ever happens.
    func testServicingASendQueueWhileBorrowedDoesNotBorrowTheTableAgain() {
        withConnection { connection, streamID, datagramID in
            connection.fromExternal { eventContext in
                _ = connection.performOnStream(streamID, in: &eventContext) {
                    (stream: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    stream.serviceUpperSendQueue(in: &ctx)
                }
                _ = connection.performOnDatagramFlow(datagramID, in: &eventContext) {
                    (flow: inout QUICDatagramFlow, ctx: inout NetworkContext.EventContext) in
                    flow.serviceUpperSendQueue(in: &ctx)
                }
            }
        }
    }

    // MARK: Sends held back

    // A send asked for while a stream is borrowed is held back, with the flags it asked for.
    func testSendFramesIsHeldBackWhileBorrowedAndKeepsItsFlags() {
        withConnection { connection, _, _ in
            let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
            let sent = connection.fromExternal { eventContext in
                connection.sendFrames(ignoreCongestionWindow: true, delayedACK: true, in: &eventContext)
            }
            let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)

            XCTAssertFalse(sent)
            XCTAssertEqual(work?.replaysSends, true)
            let send = connection.stateMachine.takePlainSend()
            XCTAssertEqual(send?.ignoreCongestionWindow, true)
            XCTAssertEqual(send?.delayedACK, true)
        }
    }

    // The same send is held back, the same way, while the send path is active.
    func testSendFramesIsHeldBackWhileTheSendPathIsActiveAndKeepsItsFlags() {
        withConnection { connection, _, _ in
            let wasActive = connection.stateMachine.claimSendPath()
            let sent = connection.fromExternal { eventContext in
                connection.sendFrames(ignoreCongestionWindow: false, delayedACK: true, in: &eventContext)
            }
            let ready = connection.stateMachine.releaseSendPath(wasActive: wasActive)

            XCTAssertFalse(sent)
            XCTAssertTrue(ready)
            let send = connection.stateMachine.takePlainSend()
            XCTAssertEqual(send?.ignoreCongestionWindow, false)
            XCTAssertEqual(send?.delayedACK, true)
        }
    }

    func testSendFramesOnAPathIsHeldBackWhileBorrowedAndKeepsItsFlags() {
        withConnection { connection, _, _ in
            connection.fromExternal { eventContext in
                var path = QUICPath(parent: connection, in: &eventContext)
                let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
                let sent = connection.sendFrames(
                    on: path,
                    ignoreCongestionWindow: true,
                    retransmission: false,
                    in: &eventContext
                )
                // A second send on the same path merges with the first
                _ = connection.sendFrames(on: path, retransmission: true, in: &eventContext)
                let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)

                XCTAssertFalse(sent)
                XCTAssertEqual(work?.replaysSends, true)
                let pathSends = connection.takePathSends()
                XCTAssertEqual(pathSends?.count, 1)
                XCTAssertEqual(pathSends?.first?.ignoreCongestionWindow, true)
                XCTAssertEqual(pathSends?.first?.retransmission, true)
                XCTAssertNil(connection.takePathSends())
                path.destroy(in: &eventContext)
            }
        }
    }

    func testSendsOnDifferentPathsAreKeptSeparate() {
        withConnection { connection, _, _ in
            connection.fromExternal { eventContext in
                var first = QUICPath(parent: connection, in: &eventContext)
                var second = QUICPath(parent: connection, in: &eventContext)
                connection.stateMachine.beginFlowBorrow(of: .streams)
                _ = connection.sendFrames(on: first, ignoreCongestionWindow: true, in: &eventContext)
                _ = connection.sendFrames(on: second, retransmission: true, in: &eventContext)
                _ = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: false)

                let pathSends = connection.takePathSends() ?? []
                XCTAssertEqual(pathSends.count, 2)
                for pathSend in pathSends {
                    if pathSend.path === first {
                        XCTAssertTrue(pathSend.ignoreCongestionWindow)
                        XCTAssertFalse(pathSend.retransmission)
                    } else {
                        XCTAssertTrue(pathSend.path === second)
                        XCTAssertFalse(pathSend.ignoreCongestionWindow)
                        XCTAssertTrue(pathSend.retransmission)
                    }
                }
                first.destroy(in: &eventContext)
                second.destroy(in: &eventContext)
            }
        }
    }

    // Replaying what waited leaves the connection idle and with nothing waiting
    func testReplayingDeferredSendsClearsThem() {
        withConnection { connection, _, _ in
            let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
            connection.fromExternal { eventContext in
                _ = connection.sendFrames(ignoreCongestionWindow: true, in: &eventContext)
            }
            let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
            XCTAssertEqual(work?.replaysSends, true)

            connection.fromExternal { eventContext in
                connection.replayDeferredSends(in: &eventContext)
            }
            XCTAssertFalse(connection.stateMachine.hasDeferredSends)
            XCTAssertFalse(connection.stateMachine.isSendActive)
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
        }
    }

    // MARK: Work that waits only for the borrow

    // Closing tears down every stream, so while one is borrowed it waits. The connection's state
    // must not change until the borrow ends, and the first request must be the one that is kept.
    func testCloseIsHeldBackWhileBorrowedAndTheFirstRequestWins() {
        withConnection { connection, _, _ in
            let stateBefore = connection.state
            let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
            connection.fromExternal { eventContext in
                connection.close(sendCloseFrame: false, in: &eventContext)
                connection.close(sendCloseFrame: true, in: &eventContext)
            }
            XCTAssertEqual(connection.state, stateBefore)
            let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)

            XCTAssertEqual(work?.close, false)
        }
    }

    // A close that was held back, once it has run, leaves nothing waiting. The connection is closing,
    // so the sends that waited no longer matter, and they must not be left behind to fire on a later,
    // unrelated release. A bare test connection has no handshake state, so the close does not reach its
    // own send here, which is the case where sends would otherwise be left over.
    func testDeferredCloseDoesNotLeaveSendsWaiting() {
        withConnection { connection, _, _ in
            connection.fromExternal { eventContext in
                var path = QUICPath(parent: connection, in: &eventContext)
                let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
                _ = connection.sendFrames(ignoreCongestionWindow: true, in: &eventContext)
                _ = connection.sendFrames(on: path, in: &eventContext)
                connection.close(sendCloseFrame: false, in: &eventContext)
                guard let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
                else {
                    return XCTFail("Expected the borrow to hand back work")
                }
                XCTAssertEqual(work.close, false)
                XCTAssertTrue(connection.stateMachine.hasDeferredSends)

                connection.runDeferredStreamWork(work, in: &eventContext)

                XCTAssertFalse(connection.stateMachine.hasDeferredSends)
                XCTAssertNil(connection.stateMachine.takePlainSend())
                XCTAssertNil(connection.takePathSends())
                path.destroy(in: &eventContext)
            }
        }
    }

    // Two closes while a flow is borrowed run as one close, and it must be the first. Run immediately,
    // the first close would have sent its error and the second would have found the connection
    // already closing. So the error has to be the first one not the last one.
    func testDeferredCloseKeepsTheFirstError() {
        withConnection { connection, _, _ in
            connection.fromExternal { eventContext in
                let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
                connection.close(with: .internalError, "first", sendCloseFrame: false, in: &eventContext)
                connection.close(with: .protocolViolation, "second", sendCloseFrame: true, in: &eventContext)

                XCTAssertEqual(
                    connection.closeError?.code,
                    QUICTransportError.QUICTransportErrorCode.internalError.rawValue
                )
                XCTAssertEqual(connection.closeError?.reason, "first")

                let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
                // The frame decision is the first request's as well
                XCTAssertEqual(work?.close, false)
            }
        }
    }

    func testDeferredCryptoCloseKeepsTheFirstError() {
        withConnection { connection, _, _ in
            connection.fromExternal { eventContext in
                let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
                connection.close(withCryptoError: 0x28, "first", in: &eventContext)
                connection.close(with: .protocolViolation, "second", in: &eventContext)
                connection.close(withCryptoError: 0x2A, "third", in: &eventContext)

                XCTAssertEqual(connection.closeError?.code, 0x28 + 0x0100)
                XCTAssertEqual(connection.closeError?.reason, "first")
                _ = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
            }
        }
    }

    // Without a borrow nothing is held back, so closing again still records the latest error as before.
    func testCloseWithoutABorrowStillRecordsTheError() {
        withConnection { connection, _, _ in
            connection.fromExternal { eventContext in
                connection.close(with: .internalError, "only", sendCloseFrame: false, in: &eventContext)
                XCTAssertEqual(
                    connection.closeError?.code,
                    QUICTransportError.QUICTransportErrorCode.internalError.rawValue
                )
                XCTAssertEqual(connection.closeError?.reason, "only")
            }
        }
    }

    func testIdleCheckIsHeldBackWhileBorrowed() {
        withConnection { connection, streamID, _ in
            // The idle check does nothing until some flow has marked itself idle
            connection.fromExternal { eventContext in
                _ = connection.handleApplicationEvent(flow: streamID, event: .connectionIdle, in: &eventContext)
            }
            let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
            connection.fromExternal { eventContext in
                connection.checkConnectionIdle(unackedPacketCount: 0, in: &eventContext)
            }
            let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)

            XCTAssertEqual(work?.checkIdle, true)
        }
    }

    // What a borrow defers is handed back exactly once; a later borrow starts with nothing.
    func testDeferredWorkIsNotCarriedIntoTheNextBorrow() {
        withConnection { connection, streamID, _ in
            _ = connection.performOnStream(streamID) { (_: inout QUICStreamInstance) in
                connection.stateMachine.deferIdleCheck()
            }
            XCTAssertFalse(connection.stateMachine.isFlowBorrowed)

            let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
            let work = connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
            XCTAssertNil(work)
        }
    }

    // MARK: The state machine on its own

    // MARK: Flow borrow

    func testStartsIdle() throws {
        var machine = QUICConnectionStateMachine()
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendActive)
        XCTAssertFalse(machine.isSendBlocked)
        XCTAssertFalse(machine.hasDeferredSends)
        XCTAssertNil(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: false))
    }

    func testBorrowTransitions() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        XCTAssertFalse(wasFlowBorrowed)
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertTrue(machine.isSendBlocked)
        XCTAssertFalse(machine.isSendActive)

        XCTAssertNil(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed))
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendBlocked)
    }

    func testNestedBorrowStaysBorrowedAndReturnsNoWork() throws {
        var machine = QUICConnectionStateMachine()
        let outer = machine.beginFlowBorrow(of: .streams)
        XCTAssertFalse(outer)
        let inner = machine.beginFlowBorrow(of: .secondary)
        XCTAssertTrue(inner)
        machine.deferIdleCheck()
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: false)

        let innerWork = machine.endFlowBorrow(of: .secondary, wasFlowBorrowed: inner)
        XCTAssertNil(innerWork)
        XCTAssertTrue(machine.isFlowBorrowed)

        // The enclosing borrow collects what the nested one deferred
        let outerWork = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: outer)
        XCTAssertEqual(outerWork?.checkIdle, true)
        XCTAssertEqual(outerWork?.replaysSends, true)
        XCTAssertFalse(machine.isFlowBorrowed)
    }

    // MARK: Send path

    func testClaimingTheSendPath() throws {
        var machine = QUICConnectionStateMachine()
        XCTAssertTrue(machine.claimSendPathIfFree())
        XCTAssertTrue(machine.isSendActive)
        XCTAssertTrue(machine.isSendBlocked)
        XCTAssertFalse(machine.isFlowBorrowed)

        // It cannot be claimed twice
        XCTAssertFalse(machine.claimSendPathIfFree())
        XCTAssertTrue(machine.isSendActive)

        XCTAssertFalse(machine.releaseSendPath(wasActive: false))
        XCTAssertFalse(machine.isSendActive)
        XCTAssertFalse(machine.isSendBlocked)
    }

    func testSendPathCannotBeClaimedWhileBorrowed() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        XCTAssertFalse(machine.claimSendPathIfFree())
        XCTAssertFalse(machine.isSendActive)
        _ = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertTrue(machine.claimSendPathIfFree())
    }

    func testBorrowingIsAllowedWhileTheSendPathIsActive() throws {
        // A stream closed by an ACK that is being processed borrows while sending is claimed
        var machine = QUICConnectionStateMachine()
        XCTAssertTrue(machine.claimSendPathIfFree())
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertTrue(machine.isSendActive)
        _ = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertTrue(machine.isSendActive)
        XCTAssertFalse(machine.isFlowBorrowed)
    }

    // A claimant that may run inside another one (the timers, receiving an ACK) takes the send path
    // only if nobody has, and gives it back only if it was the one that took it.
    func testNestedClaimsOnlyTheOutermostReleases() throws {
        var machine = QUICConnectionStateMachine()
        let outer = machine.claimSendPath()
        XCTAssertFalse(outer)
        let inner = machine.claimSendPath()
        XCTAssertTrue(inner)
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)

        // The inner claim leaves the send path held, and does not report the send ready
        XCTAssertFalse(machine.releaseSendPath(wasActive: inner))
        XCTAssertTrue(machine.isSendActive)

        // The outer claim releases it, and now the send that waited is ready
        XCTAssertTrue(machine.releaseSendPath(wasActive: outer))
        XCTAssertFalse(machine.isSendActive)
    }

    func testReleasingWithNothingWaitingReportsNothingReady() throws {
        var machine = QUICConnectionStateMachine()
        let wasActive = machine.claimSendPath()
        XCTAssertFalse(machine.releaseSendPath(wasActive: wasActive))
    }

    // MARK: Sends that wait

    func testSendDeferredWhileSendPathActiveIsReadyWhenItIsReleased() throws {
        var machine = QUICConnectionStateMachine()
        let wasActive = machine.claimSendPath()
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: false)
        XCTAssertTrue(machine.hasDeferredSends)

        XCTAssertTrue(machine.releaseSendPath(wasActive: wasActive))
        let send = machine.takePlainSend()
        XCTAssertEqual(send?.ignoreCongestionWindow, true)
        XCTAssertEqual(send?.delayedACK, false)
        XCTAssertFalse(machine.hasDeferredSends)
    }

    func testSendDeferredWhileBorrowedIsReadyWhenTheBorrowEnds() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: true)

        let work = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertNotNil(work)
        XCTAssertEqual(work?.replaysSends, true)
        XCTAssertNil(work?.close)
        XCTAssertEqual(work?.checkIdle, false)
        // The send is reported, not handed over: it stays until the connection takes it
        XCTAssertTrue(machine.hasDeferredSends)
        let send = machine.takePlainSend()
        XCTAssertEqual(send?.ignoreCongestionWindow, false)
        XCTAssertEqual(send?.delayedACK, true)
    }

    func testDeferredSendsMergeTheirFlags() throws {
        var machine = QUICConnectionStateMachine()
        _ = machine.claimSendPath()
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: false)
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: true)
        // A later send that asks for less does not take the earlier flags back
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)

        let send = machine.takePlainSend()
        XCTAssertEqual(send?.ignoreCongestionWindow, true)
        XCTAssertEqual(send?.delayedACK, true)
    }

    func testPlainDeferredSendAsksForNoFlags() throws {
        var machine = QUICConnectionStateMachine()
        _ = machine.claimSendPath()
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)
        let send = machine.takePlainSend()
        XCTAssertEqual(send?.ignoreCongestionWindow, false)
        XCTAssertEqual(send?.delayedACK, false)
    }

    func testTakingAPlainSendTwiceFindsNothingTheSecondTime() throws {
        var machine = QUICConnectionStateMachine()
        _ = machine.claimSendPath()
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: true)
        XCTAssertNotNil(machine.takePlainSend())
        XCTAssertNil(machine.takePlainSend())
        // And the flags did not stick around for the next send that waits
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)
        let send = machine.takePlainSend()
        XCTAssertEqual(send?.ignoreCongestionWindow, false)
        XCTAssertEqual(send?.delayedACK, false)
    }

    // A send that waited for both blockers is replayed by whichever clears last, and only once.
    func testSendWaitingForBothBlockersIsReadyWhenTheLastOneClears_sendPathLast() throws {
        var machine = QUICConnectionStateMachine()
        let wasActive = machine.claimSendPath()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)

        // The borrow ends first, while the send path is still held: not ready
        let work = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertNil(work)
        XCTAssertTrue(machine.hasDeferredSends)

        // The send path ends last, and reports the send ready
        XCTAssertTrue(machine.releaseSendPath(wasActive: wasActive))
    }

    func testSendWaitingForBothBlockersIsReadyWhenTheLastOneClears_borrowLast() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        let wasActive = machine.claimSendPath()
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)

        // The send path is released first, while a flow is still borrowed: not ready
        XCTAssertFalse(machine.releaseSendPath(wasActive: wasActive))
        XCTAssertTrue(machine.hasDeferredSends)

        // The borrow ends last, and reports the send ready
        XCTAssertEqual(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)?.replaysSends, true)
    }

    func testPathSendsAreRecordedSeparatelyFromPlainSends() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.requestPathSends()
        XCTAssertTrue(machine.hasDeferredSends)
        XCTAssertNil(machine.takePlainSend())

        XCTAssertEqual(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)?.replaysSends, true)
        XCTAssertTrue(machine.takePathSendsRequest())
        XCTAssertFalse(machine.takePathSendsRequest())
        XCTAssertFalse(machine.hasDeferredSends)
    }

    // MARK: Work that waits only for the borrow

    func testDeferredIdleCheckWaitsOnlyForTheBorrow() throws {
        var machine = QUICConnectionStateMachine()
        // Even with the send path held, the idle check is handed back when the borrow ends
        let wasActive = machine.claimSendPath()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.deferIdleCheck()

        let work = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertEqual(work?.checkIdle, true)
        XCTAssertEqual(work?.replaysSends, false)
        _ = machine.releaseSendPath(wasActive: wasActive)
    }

    func testDeferredCloseKeepsWhetherToSendTheFrame() throws {
        for sendCloseFrame in [true, false] {
            var machine = QUICConnectionStateMachine()
            let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
            machine.deferClose(sendCloseFrame: sendCloseFrame)
            let work = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
            XCTAssertNotNil(work)
            XCTAssertEqual(work?.close, sendCloseFrame)
        }
    }

    // Running a close immediately makes a later one a no-op, since the connection is already
    // closing. Deferring must behave the same way: the first request is the one that counts.
    func testFirstDeferredCloseWins() throws {
        for (first, second) in [(true, false), (false, true), (true, true), (false, false)] {
            var machine = QUICConnectionStateMachine()
            let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
            machine.deferClose(sendCloseFrame: first)
            machine.deferClose(sendCloseFrame: second)
            XCTAssertEqual(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)?.close, first)
        }
    }

    func testACloseWaitingForTheBorrowIsReportedUntilTheBorrowEnds() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        XCTAssertFalse(machine.isCloseDeferred)
        machine.deferClose(sendCloseFrame: false)
        XCTAssertTrue(machine.isCloseDeferred)
        // A second request leaves it waiting, and it is the same close
        machine.deferClose(sendCloseFrame: true)
        XCTAssertTrue(machine.isCloseDeferred)

        XCTAssertEqual(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)?.close, false)
        XCTAssertFalse(machine.isCloseDeferred)
    }

    func testCloseDeferredBeforeANestedBorrowStillWins() throws {
        var machine = QUICConnectionStateMachine()
        let outer = machine.beginFlowBorrow(of: .streams)
        machine.deferClose(sendCloseFrame: true)
        let inner = machine.beginFlowBorrow(of: .secondary)
        machine.deferClose(sendCloseFrame: false)
        _ = machine.endFlowBorrow(of: .secondary, wasFlowBorrowed: inner)
        XCTAssertEqual(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: outer)?.close, true)
    }

    // The next borrow must not see work from the last one, or it would be performed twice.
    func testEndingABorrowForgetsWhatItHandedBack() throws {
        var machine = QUICConnectionStateMachine()
        var wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.deferClose(sendCloseFrame: true)
        machine.deferIdleCheck()
        XCTAssertNotNil(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed))

        wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        XCTAssertFalse(wasFlowBorrowed)
        XCTAssertNil(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed))

        // And a close requested in the first borrow does not count as already requested
        wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.deferClose(sendCloseFrame: false)
        XCTAssertEqual(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)?.close, false)
    }

    func testBlockersAndRequestsDoNotDisturbEachOther() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: true)
        machine.requestPathSends()
        machine.deferClose(sendCloseFrame: true)
        machine.deferIdleCheck()
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendActive)

        let work = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertEqual(work?.close, true)
        XCTAssertEqual(work?.checkIdle, true)
        XCTAssertEqual(work?.replaysSends, true)
        // Sends stay until taken; the borrowed work was handed back and forgotten
        XCTAssertNotNil(machine.takePlainSend())
        XCTAssertTrue(machine.takePathSendsRequest())
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertNil(machine.endFlowBorrow(of: .streams, wasFlowBorrowed: false))
    }

    // MARK: Which table is borrowed (tracked in debug builds only)

    #if DEBUG
    func testBorrowingATableIsTrackedPerTable() throws {
        var machine = QUICConnectionStateMachine()
        XCTAssertFalse(machine.isBorrowed(.streams))
        XCTAssertFalse(machine.isBorrowed(.secondary))

        machine.beginTableBorrow(.streams)
        XCTAssertTrue(machine.isBorrowed(.streams))
        XCTAssertFalse(machine.isBorrowed(.secondary))

        // Borrowing the other table at the same time is fine
        machine.beginTableBorrow(.secondary)
        XCTAssertTrue(machine.isBorrowed(.streams))
        XCTAssertTrue(machine.isBorrowed(.secondary))

        machine.endTableBorrow(.streams)
        XCTAssertFalse(machine.isBorrowed(.streams))
        XCTAssertTrue(machine.isBorrowed(.secondary))
        machine.endTableBorrow(.secondary)
        XCTAssertFalse(machine.isBorrowed(.secondary))
    }

    // A table that is only noted as borrowed defers nothing: that is for the borrows that can run the
    // work afterwards
    func testNotingATableBorrowDoesNotBlockSends() throws {
        var machine = QUICConnectionStateMachine()
        machine.beginTableBorrow(.streams)
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendBlocked)
        XCTAssertTrue(machine.claimSendPathIfFree())
    }

    func testAFlowBorrowNotesItsTableAndClearsItWhenItEnds() throws {
        var machine = QUICConnectionStateMachine()
        let outer = machine.beginFlowBorrow(of: .streams)
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertTrue(machine.isBorrowed(.streams))
        XCTAssertFalse(machine.isBorrowed(.secondary))

        // Nested in the other table: both are borrowed, and each is cleared by its own end
        let inner = machine.beginFlowBorrow(of: .secondary)
        XCTAssertTrue(machine.isBorrowed(.streams))
        XCTAssertTrue(machine.isBorrowed(.secondary))
        _ = machine.endFlowBorrow(of: .secondary, wasFlowBorrowed: inner)
        XCTAssertTrue(machine.isBorrowed(.streams))
        XCTAssertFalse(machine.isBorrowed(.secondary))
        XCTAssertTrue(machine.isFlowBorrowed)

        _ = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: outer)
        XCTAssertFalse(machine.isBorrowed(.streams))
        XCTAssertFalse(machine.isFlowBorrowed)
    }

    // The same table can be borrowed again once the first borrow has ended
    func testATableCanBeBorrowedAgainAfterTheBorrowEnds() throws {
        var machine = QUICConnectionStateMachine()
        for _ in 0..<3 {
            machine.beginTableBorrow(.streams)
            machine.endTableBorrow(.streams)
            let wasFlowBorrowed = machine.beginFlowBorrow(of: .streams)
            _ = machine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed)
        }
        XCTAssertFalse(machine.isBorrowed(.streams))
    }
    #endif

    func testIsSmall() throws {
        // Two bytes of state plus the per-path sends; checking the blockers must stay a single small load.
        XCTAssertLessThanOrEqual(MemoryLayout<QUICConnectionStateMachine>.size, 16)
    }

    // MARK: Work that waits for a borrow, run through the connection

    // These go through the connection's own borrow, so the work held back is performed by
    // `runDeferredStreamWork` when the outermost borrow ends, rather than inspected by hand.

    // A close asked for while a stream is borrowed does nothing until the borrow ends, and then the
    // connection closes, with the error it was first asked to close with.
    func testCloseRequestedInsideABorrowRunsWhenTheBorrowEnds() throws {
        withConnection { connection, streamID, _ in
            connection.fromExternal { eventContext in
                var errorInsideBorrow: NetworkError?
                let ran: Void? = connection.performOnStream(streamID, in: &eventContext) {
                    (_: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    connection.close(with: .streamStateError, "closed inside a borrow", sendCloseFrame: false, in: &ctx)
                    XCTAssertTrue(connection.stateMachine.isCloseDeferred)
                    errorInsideBorrow = connection.errorToReport
                }
                XCTAssertNotNil(ran)
                XCTAssertNil(errorInsideBorrow)
                XCTAssertFalse(connection.stateMachine.isCloseDeferred)
                XCTAssertNotNil(connection.errorToReport)
            }
        }
    }

    // A close that was held back also takes the sends that were waiting with it, so nothing is left to
    // fire on a later, unrelated release.
    func testCloseRequestedInsideABorrowDropsTheSendsThatWaitedWithIt() throws {
        withConnection { connection, streamID, _ in
            connection.fromExternal { eventContext in
                _ = connection.performOnStream(streamID, in: &eventContext) {
                    (_: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    _ = connection.sendFrames(ignoreCongestionWindow: true, delayedACK: false, in: &ctx)
                    connection.close(sendCloseFrame: false, in: &ctx)
                    XCTAssertTrue(connection.stateMachine.hasDeferredSends)
                }
                XCTAssertFalse(connection.stateMachine.hasDeferredSends)
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
                XCTAssertFalse(connection.stateMachine.isSendActive)
            }
        }
    }

    // The idle check looks at every stream, so inside a borrow it has to wait. If it ran straight away it
    // would borrow the stream table a second time, which asserts in debug builds. It runs once the borrow
    // has ended, and the request is used up.
    func testIdleCheckRequestedInsideABorrowRunsWhenTheBorrowEnds() throws {
        withConnection { connection, streamID, _ in
            connection.fromExternal { eventContext in
                // The idle check does nothing until some flow has marked itself idle
                _ = connection.handleApplicationEvent(flow: streamID, event: .connectionIdle, in: &eventContext)

                _ = connection.performOnStream(streamID, in: &eventContext) {
                    (_: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    connection.checkConnectionIdle(unackedPacketCount: 0, in: &ctx)
                    XCTAssertTrue(connection.stateMachine.isFlowBorrowed)
                }
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)

                // Nothing is left over for the next borrow
                let wasFlowBorrowed = connection.stateMachine.beginFlowBorrow(of: .streams)
                XCTAssertNil(connection.stateMachine.endFlowBorrow(of: .streams, wasFlowBorrowed: wasFlowBorrowed))
            }
        }
    }

    // A send asked for inside a borrow is held back, then replayed when the borrow ends. Afterwards
    // nothing is waiting and neither the borrow nor the send path is left claimed.
    func testSendRequestedInsideABorrowIsReplayedWhenTheBorrowEnds() throws {
        withConnection { connection, streamID, _ in
            connection.fromExternal { eventContext in
                var sentInsideBorrow = true
                _ = connection.performOnStream(streamID, in: &eventContext) {
                    (_: inout QUICStreamInstance, ctx: inout NetworkContext.EventContext) in
                    sentInsideBorrow = connection.sendFrames(ignoreCongestionWindow: true, delayedACK: false, in: &ctx)
                    XCTAssertTrue(connection.stateMachine.hasDeferredSends)
                }
                XCTAssertFalse(sentInsideBorrow)
                XCTAssertFalse(connection.stateMachine.hasDeferredSends)
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
                XCTAssertFalse(connection.stateMachine.isSendActive)
            }
        }
    }

    // Borrows nest across the two tables, and only the outermost one performs the work. Work asked for
    // from inside the inner borrow waits for the outer one to end.
    func testWorkRequestedInsideANestedBorrowWaitsForTheOutermostBorrow() throws {
        withConnection { connection, streamID, datagramID in
            connection.fromExternal { eventContext in
                var deferredAfterInner = false
                _ = connection.performOnStream(streamID, in: &eventContext) {
                    (_: inout QUICStreamInstance, outerContext: inout NetworkContext.EventContext) in
                    _ = connection.performOnDatagramFlow(datagramID, in: &outerContext) {
                        (_: inout QUICDatagramFlow, innerContext: inout NetworkContext.EventContext) in
                        _ = connection.sendFrames(ignoreCongestionWindow: false, delayedACK: true, in: &innerContext)
                    }
                    // The inner borrow has ended, but the stream is still borrowed, so the send still waits
                    deferredAfterInner = connection.stateMachine.hasDeferredSends
                }
                XCTAssertTrue(deferredAfterInner)
                XCTAssertFalse(connection.stateMachine.hasDeferredSends)
                XCTAssertFalse(connection.stateMachine.isFlowBorrowed)
            }
        }
    }
}
#endif
