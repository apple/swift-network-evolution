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
@testable import SwiftNetwork
#endif

#if !NETWORK_NO_SWIFT_QUIC
@available(Network 0.1.0, *)
final class SwiftNetworkConnectionStateMachineTests: XCTestCase {

    // MARK: Flow borrow

    func testStartsIdle() throws {
        var machine = QUICConnectionStateMachine()
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendActive)
        XCTAssertFalse(machine.isSendBlocked)
        XCTAssertFalse(machine.hasDeferredSends)
        XCTAssertNil(machine.endFlowBorrow(wasFlowBorrowed: false))
    }

    func testBorrowTransitions() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow()
        XCTAssertFalse(wasFlowBorrowed)
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertTrue(machine.isSendBlocked)
        XCTAssertFalse(machine.isSendActive)

        XCTAssertNil(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed))
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendBlocked)
    }

    func testNestedBorrowStaysBorrowedAndReturnsNoWork() throws {
        var machine = QUICConnectionStateMachine()
        let outer = machine.beginFlowBorrow()
        XCTAssertFalse(outer)
        let inner = machine.beginFlowBorrow()
        XCTAssertTrue(inner)
        machine.deferIdleCheck()
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: false)

        let innerWork = machine.endFlowBorrow(wasFlowBorrowed: inner)
        XCTAssertNil(innerWork)
        XCTAssertTrue(machine.isFlowBorrowed)

        // The enclosing borrow collects what the nested one deferred
        let outerWork = machine.endFlowBorrow(wasFlowBorrowed: outer)
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
        let wasFlowBorrowed = machine.beginFlowBorrow()
        XCTAssertFalse(machine.claimSendPathIfFree())
        XCTAssertFalse(machine.isSendActive)
        _ = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertTrue(machine.claimSendPathIfFree())
    }

    func testBorrowingIsAllowedWhileTheSendPathIsActive() throws {
        // A stream closed by an ACK that is being processed borrows while sending is claimed
        var machine = QUICConnectionStateMachine()
        XCTAssertTrue(machine.claimSendPathIfFree())
        let wasFlowBorrowed = machine.beginFlowBorrow()
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertTrue(machine.isSendActive)
        _ = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
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
        let wasFlowBorrowed = machine.beginFlowBorrow()
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: true)

        let work = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
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
        let wasFlowBorrowed = machine.beginFlowBorrow()
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)

        // The borrow ends first, while the send path is still held: not ready
        let work = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertNil(work)
        XCTAssertTrue(machine.hasDeferredSends)

        // The send path ends last, and reports the send ready
        XCTAssertTrue(machine.releaseSendPath(wasActive: wasActive))
    }

    func testSendWaitingForBothBlockersIsReadyWhenTheLastOneClears_borrowLast() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow()
        let wasActive = machine.claimSendPath()
        machine.deferSend(ignoreCongestionWindow: false, delayedACK: false)

        // The send path is released first, while a flow is still borrowed: not ready
        XCTAssertFalse(machine.releaseSendPath(wasActive: wasActive))
        XCTAssertTrue(machine.hasDeferredSends)

        // The borrow ends last, and reports the send ready
        XCTAssertEqual(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)?.replaysSends, true)
    }

    func testPathSendsAreRecordedSeparatelyFromPlainSends() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow()
        machine.requestPathSends()
        XCTAssertTrue(machine.hasDeferredSends)
        XCTAssertNil(machine.takePlainSend())

        XCTAssertEqual(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)?.replaysSends, true)
        XCTAssertTrue(machine.takePathSendsRequest())
        XCTAssertFalse(machine.takePathSendsRequest())
        XCTAssertFalse(machine.hasDeferredSends)
    }

    // MARK: Work that waits only for the borrow

    func testDeferredIdleCheckWaitsOnlyForTheBorrow() throws {
        var machine = QUICConnectionStateMachine()
        // Even with the send path held, the idle check is handed back when the borrow ends
        let wasActive = machine.claimSendPath()
        let wasFlowBorrowed = machine.beginFlowBorrow()
        machine.deferIdleCheck()

        let work = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertEqual(work?.checkIdle, true)
        XCTAssertEqual(work?.replaysSends, false)
        _ = machine.releaseSendPath(wasActive: wasActive)
    }

    func testDeferredCloseKeepsWhetherToSendTheFrame() throws {
        for sendCloseFrame in [true, false] {
            var machine = QUICConnectionStateMachine()
            let wasFlowBorrowed = machine.beginFlowBorrow()
            machine.deferClose(sendCloseFrame: sendCloseFrame)
            let work = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
            XCTAssertNotNil(work)
            XCTAssertEqual(work?.close, sendCloseFrame)
        }
    }

    // Running a close immediately makes a later one a no-op, since the connection is already
    // closing. Deferring must behave the same way: the first request is the one that counts.
    func testFirstDeferredCloseWins() throws {
        for (first, second) in [(true, false), (false, true), (true, true), (false, false)] {
            var machine = QUICConnectionStateMachine()
            let wasFlowBorrowed = machine.beginFlowBorrow()
            machine.deferClose(sendCloseFrame: first)
            machine.deferClose(sendCloseFrame: second)
            XCTAssertEqual(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)?.close, first)
        }
    }

    func testCloseDeferredBeforeANestedBorrowStillWins() throws {
        var machine = QUICConnectionStateMachine()
        let outer = machine.beginFlowBorrow()
        machine.deferClose(sendCloseFrame: true)
        let inner = machine.beginFlowBorrow()
        machine.deferClose(sendCloseFrame: false)
        _ = machine.endFlowBorrow(wasFlowBorrowed: inner)
        XCTAssertEqual(machine.endFlowBorrow(wasFlowBorrowed: outer)?.close, true)
    }

    // The next borrow must not see work from the last one, or it would be performed twice.
    func testEndingABorrowForgetsWhatItHandedBack() throws {
        var machine = QUICConnectionStateMachine()
        var wasFlowBorrowed = machine.beginFlowBorrow()
        machine.deferClose(sendCloseFrame: true)
        machine.deferIdleCheck()
        XCTAssertNotNil(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed))

        wasFlowBorrowed = machine.beginFlowBorrow()
        XCTAssertFalse(wasFlowBorrowed)
        XCTAssertNil(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed))

        // And a close requested in the first borrow does not count as already requested
        wasFlowBorrowed = machine.beginFlowBorrow()
        machine.deferClose(sendCloseFrame: false)
        XCTAssertEqual(machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)?.close, false)
    }

    func testBlockersAndRequestsDoNotDisturbEachOther() throws {
        var machine = QUICConnectionStateMachine()
        let wasFlowBorrowed = machine.beginFlowBorrow()
        machine.deferSend(ignoreCongestionWindow: true, delayedACK: true)
        machine.requestPathSends()
        machine.deferClose(sendCloseFrame: true)
        machine.deferIdleCheck()
        XCTAssertTrue(machine.isFlowBorrowed)
        XCTAssertFalse(machine.isSendActive)

        let work = machine.endFlowBorrow(wasFlowBorrowed: wasFlowBorrowed)
        XCTAssertEqual(work?.close, true)
        XCTAssertEqual(work?.checkIdle, true)
        XCTAssertEqual(work?.replaysSends, true)
        // Sends stay until taken; the borrowed work was handed back and forgotten
        XCTAssertNotNil(machine.takePlainSend())
        XCTAssertTrue(machine.takePathSendsRequest())
        XCTAssertFalse(machine.isFlowBorrowed)
        XCTAssertNil(machine.endFlowBorrow(wasFlowBorrowed: false))
    }

    func testIsSmall() throws {
        // Two bytes of state plus the per-path sends; checking the blockers must stay a single small load.
        XCTAssertLessThanOrEqual(MemoryLayout<QUICConnectionStateMachine>.size, 16)
    }
}
#endif
