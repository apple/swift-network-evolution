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

/// Decides when the connection may do work that has to look at its flow tables or its send path,
/// and remembers the work that had to defer.
///
/// This state machine answers two questions:
///
/// 1.   Is a stream or datagram flow borrowed from its flow table? A flow lives inline in the
///    table, so working on one means borrowing it for the duration of a closure, and the table is
///    exclusively accessed for that whole time. Anything that would reach a table again (sending
///    frames, closing the connection, checking every stream for idleness) cannot run until the
///    borrow ends.
/// 2.   Is the send path active? `sendFrames` and the code that claims the send path around it
///    (the timers, `sendFramesFromRecovery`, receiving an ACK) are not re-entrant. A send that
///    comes in while one is running has to wait for it to finish.
///
/// Either one blocks a send, so they live here together:
///
///     idle ──beginFlowBorrow(of:)────▶ flowBorrowed ──endFlowBorrow(of:)────▶ idle
///     idle ──claimSendPath()──▶ sending  ──releaseSendPath()▶ idle
///
/// A connection can have a flow borrowed and be sending at once (a stream closed by an ACK that is
/// being processed, as an example). The work asks to wait with a defer call, and is handed back when it is allowed to run:
///
/// - Sends (`deferSend`, `deferPathSend`) wait until neither is set. Whichever clears last
///   reports that the sends are ready, and the connection replays them. A send deferred by a flow
///   borrow while the send path is active is therefore replayed by the send, not by the flow borrow.
/// - Close and idle checks (`deferClose`, `deferIdleCheck`) only wait for the flow borrow, since
///   they are not part of the send path.
///
/// Requests merge. Sends accumulate the flags they asked for, so none is lost. A close keeps the
/// first request, as running it immediately would have: any later one finds the connection already
/// closing.
///
/// This type only records the state, it does not actually handle replaying work.
/// The connection handles replaying the work, in
/// `runDeferredStreamWork` and `replayDeferredSends`.
///
/// The state is two bytes, so each check or transition is one small access.
@available(Network 0.1.0, *)
struct QUICConnectionStateMachine {
    // The bits of `status`: which send blockers are set and which requests are waiting.
    fileprivate struct Status: OptionSet {
        var rawValue: UInt16
        // The send blockers: the two conditions that make a send wait
        static let flowBorrowed = Status(rawValue: 1 << 0)
        static let sendActive = Status(rawValue: 1 << 1)
        // A send that waited, with the flags it asked for
        static let sendFrames = Status(rawValue: 1 << 2)
        static let ignoreCongestionWindow = Status(rawValue: 1 << 3)
        static let delayedACK = Status(rawValue: 1 << 4)
        // Sends on particular paths that waited. The paths themselves are in `pathSends`.
        static let pathSends = Status(rawValue: 1 << 5)
        // Work that only waits for the flow borrow
        static let closeRequested = Status(rawValue: 1 << 6)
        static let closeSendsFrame = Status(rawValue: 1 << 7)
        static let checkIdle = Status(rawValue: 1 << 8)
        // Which flow table is borrowed, so a second borrow of the same table can be caught.
        // These only ever run in DEBUG mode to catch errors
        static let streamTableBorrowed = Status(rawValue: 1 << 9)
        static let secondaryTableBorrowed = Status(rawValue: 1 << 10)

        static let sendBlockers: Status = [.flowBorrowed, .sendActive]
        static let pendingSends: Status = [.sendFrames, .pathSends]
        static let plainSend: Status = [.sendFrames, .ignoreCongestionWindow, .delayedACK]
        static let afterBorrow: Status = [.closeRequested, .closeSendsFrame, .checkIdle]
    }

    /// One of the connection's two flow tables.
    enum Table: CustomStringConvertible {
        /// The table of stream flows
        case streams
        /// The table of secondary flows, which is the datagram flows
        case secondary

        fileprivate var status: Status {
            switch self {
            case .streams: .streamTableBorrowed
            case .secondary: .secondaryTableBorrowed
            }
        }

        var description: String {
            switch self {
            case .streams: "stream"
            case .secondary: "secondary"
            }
        }
    }

    /// A send on one path that had to wait.
    struct PathSend {
        let path: QUICPath
        var ignoreCongestionWindow: Bool
        var retransmission: Bool
    }

    /// What the connection should do now that a flow borrow has ended. Never empty: when there is
    /// nothing to do, `endFlowBorrow` returns `nil` instead.
    struct DeferredWork {
        fileprivate var requests: Status
        /// Sends that waited are ready, because nothing else is holding them back.
        var replaysSends: Bool

        /// A close was requested; holds whether a CONNECTION_CLOSE frame should be sent.
        /// - nil: no close was requested while the flow was borrowed.
        /// - true: a close was requested, and it should send a CONNECTION_CLOSE frame.
        /// - false: a close was requested, and it should not send one.
        var close: Bool? {
            requests.contains(.closeRequested) ? requests.contains(.closeSendsFrame) : nil
        }
        /// The connection should recheck whether every stream is idle, which looks at every stream.
        var checkIdle: Bool { requests.contains(.checkIdle) }
    }

    private var status: Status = []
    private var pathSends: [MultiplexingPathIdentifier: PathSend] = [:]

    // MARK: Send blockers

    /// Whether a flow is borrowed from its flow table.
    @inline(always)
    var isFlowBorrowed: Bool {
        status.contains(.flowBorrowed)
    }

    /// Whether the send path is claimed.
    @inline(always)
    var isSendActive: Bool {
        status.contains(.sendActive)
    }

    /// Whether a send has to wait, because a flow is borrowed or the send path is claimed.
    @inline(always)
    var isSendBlocked: Bool {
        !status.isDisjoint(with: .sendBlockers)
    }

    /// Starts borrowing a flow table, and defers the work that must wait for the borrow. Returns
    /// whether a flow borrow was already under way, which the matching `endFlowBorrow` needs in order
    /// to tell an outermost borrow from a nested one.
    @inline(always)
    @discardableResult
    mutating func beginFlowBorrow(of table: Table) -> Bool {
        let wasFlowBorrowed = status.contains(.flowBorrowed)
        status.insert(.flowBorrowed)
        beginTableBorrow(table)
        return wasFlowBorrowed
    }

    /// Ends a flow borrow and hands back what the connection can now do.
    ///
    /// - Parameters:
    ///   - table: The table `beginFlowBorrow` was given.
    ///   - wasFlowBorrowed: What `beginFlowBorrow` returned. A nested borrow returns `nil` and leaves
    ///     the flow borrowed; the enclosing borrow collects everything when it ends.
    /// - Returns: The work to do, or `nil` if there is none.
    @inline(always)
    mutating func endFlowBorrow(of table: Table, wasFlowBorrowed: Bool) -> DeferredWork? {
        endTableBorrow(table)
        guard !wasFlowBorrowed else { return nil }
        let requests = status.intersection(.afterBorrow)
        let replaysSends = !status.contains(.sendActive) && !status.isDisjoint(with: .pendingSends)
        status.subtract([.afterBorrow, .flowBorrowed])
        guard !requests.isEmpty || replaysSends else { return nil }
        return DeferredWork(requests: requests, replaysSends: replaysSends)
    }

    // MARK: Which table is borrowed
    //
    // A flow table is reached by borrowing it, and a table is exclusively accessed for the whole of a
    // borrow, so borrowing the same table again can cause problems. There are no places in the code where
    // this is causing a problem today, but the table borrowing logic should help prevent this in the future.

    /// Notes that `table` is being borrowed. Asserts that it is not already.
    @inline(always)
    mutating func beginTableBorrow(_ table: Table) {
        #if DEBUG
        assert(
            !status.contains(table.status),
            "Overlapping flow borrowing: \(table) caught"
        )
        status.insert(table.status)
        #endif
    }

    /// Notes that `table` is no longer borrowed.
    @inline(always)
    mutating func endTableBorrow(_ table: Table) {
        #if DEBUG
        status.remove(table.status)
        #endif
    }

    #if DEBUG
    /// Whether `table` is borrowed. Only tracked in debug builds.
    func isBorrowed(_ table: Table) -> Bool {
        status.contains(table.status)
    }
    #endif

    /// Claims the send path if nothing is holding it back, in one step. Returns `false` if the send
    /// path is claimed or a flow is borrowed, in which case the caller defers its send instead.
    @inline(always)
    mutating func claimSendPathIfFree() -> Bool {
        guard status.isDisjoint(with: .sendBlockers) else { return false }
        status.insert(.sendActive)
        return true
    }

    /// Claims the send path. Returns whether it was already claimed, which the matching
    /// `releaseSendPath` needs in order to give it back only if this call was the one to take it.
    @inline(always)
    @discardableResult
    mutating func claimSendPath() -> Bool {
        let wasActive = status.contains(.sendActive)
        status.insert(.sendActive)
        return wasActive
    }

    /// Gives the send path back. Returns whether sends that waited are now ready to replay.
    ///
    /// They are not ready if an enclosing claim still holds the send path (it replays them when it
    /// releases) or if a flow is still borrowed (the flow borrow reports them when it ends).
    @inline(always)
    @discardableResult
    mutating func releaseSendPath(wasActive: Bool) -> Bool {
        guard !wasActive else { return false }
        status.remove(.sendActive)
        return !status.contains(.flowBorrowed) && !status.isDisjoint(with: .pendingSends)
    }

    // MARK: Sends that waited

    /// Whether any send is waiting.
    @inline(always)
    var hasDeferredSends: Bool {
        !status.isDisjoint(with: .pendingSends)
    }

    /// Remembers a send, keeping the flags it asked for.
    @inline(always)
    mutating func deferSend(ignoreCongestionWindow: Bool, delayedACK: Bool) {
        status.insert(.sendFrames)
        if ignoreCongestionWindow { status.insert(.ignoreCongestionWindow) }
        if delayedACK { status.insert(.delayedACK) }
    }

    /// Takes the waiting plain send, if there is one, with the flags it asked for.
    @inline(always)
    mutating func takePlainSend() -> (ignoreCongestionWindow: Bool, delayedACK: Bool)? {
        guard status.contains(.sendFrames) else { return nil }
        let send = (status.contains(.ignoreCongestionWindow), status.contains(.delayedACK))
        status.subtract(.plainSend)
        return send
    }

    /// Exchanges the waiting per-path sends with `other`, without recording that there are any.
    @inline(always)
    mutating func exchangePathSends(with other: inout [MultiplexingPathIdentifier: PathSend]) {
        swap(&pathSends, &other)
    }

    /// Records that sends on particular paths are waiting.
    @inline(always)
    mutating func requestPathSends() {
        status.insert(.pathSends)
    }

    /// Returns whether sends on particular paths were waiting, and forgets that they were.
    @inline(always)
    mutating func takePathSendsRequest() -> Bool {
        guard status.contains(.pathSends) else { return false }
        status.remove(.pathSends)
        return true
    }

    // MARK: Work that waits for the flow borrow

    /// Whether a close is waiting for the flow borrow to end. The first request wins, so a caller that
    /// is about to record a reason for closing can use this to keep the reason of the one already
    /// waiting.
    @inline(always) var isCloseDeferred: Bool {
        status.contains(.closeRequested)
    }

    @inline(always)
    mutating func deferClose(sendCloseFrame: Bool) {
        guard !status.contains(.closeRequested) else { return }
        status.insert(.closeRequested)
        if sendCloseFrame { status.insert(.closeSendsFrame) }
    }

    @inline(always)
    mutating func deferIdleCheck() {
        status.insert(.checkIdle)
    }
}

@available(Network 0.1.0, *)
extension QUICConnection {
    /// Remembers a send on one path that has to wait. Sends on the same path merge their flags.
    func deferPathSend(_ path: QUICPath, ignoreCongestionWindow: Bool, retransmission: Bool) {
        // This function just edits an entry in the stateMachine's pathSends dictionary.
        // It does not just edit it directly on the keyed value for performance reason.
        var sends: [MultiplexingPathIdentifier: QUICConnectionStateMachine.PathSend] = [:]
        stateMachine.exchangePathSends(with: &sends)
        var send =
            sends[path.pathIdentifier]
            ?? QUICConnectionStateMachine.PathSend(path: path, ignoreCongestionWindow: false, retransmission: false)
        send.ignoreCongestionWindow = send.ignoreCongestionWindow || ignoreCongestionWindow
        send.retransmission = send.retransmission || retransmission
        sends[path.pathIdentifier] = send
        stateMachine.exchangePathSends(with: &sends)
        stateMachine.requestPathSends()
    }

    /// Takes the sends waiting on particular paths, if there are any.
    func takePathSends() -> [QUICConnectionStateMachine.PathSend]? {
        guard stateMachine.takePathSendsRequest() else { return nil }
        var sends: [MultiplexingPathIdentifier: QUICConnectionStateMachine.PathSend] = [:]
        // After this the state machine no longer has any pathSends values
        stateMachine.exchangePathSends(with: &sends)
        return Array(sends.values)
    }
}

#endif
