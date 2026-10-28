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
final class ConnectionStateMachineTests: XCTestCase {

    // Runs `body` with a connection and one stream and one datagram flow in its flow tables.
    func withConnection(
        _ body: (QUICConnection, MultiplexedFlowIdentifier, MultiplexedFlowIdentifier) -> Void
    ) {
        let clock = TestClockContext("ConnectionStateMachineTests")
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
            _ = connection.withStreamBorrowed(streamID) { (_: inout QUICStreamInstance) in
                XCTAssertTrue(connection.stateMachine.isBorrowed(.streams))
            }
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
}
#endif
