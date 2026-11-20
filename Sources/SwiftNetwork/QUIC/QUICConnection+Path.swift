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

/// What the rest of the connection asks about the current path while that path may not be
/// reachable.
///
/// A path is borrowed in place for a long piece of work (building the packets of a send, probing the
/// path MTU), and that work passes the path along by `inout`. A question that arrives in the meantime,
/// such as the application asking how much room it has to write, cannot look at the path, since it is
/// already borrowed. It reads this state instead, which was taken when the work began.
@available(Network 0.1.0, *)
struct CurrentPathState {
    var mss = 0
    var smoothedRTT: NetworkDuration = .zero
    var availableCongestionWindow: UInt64 = 0
    /// The probe timeout before it is backed off by `ptoCount`, which Recovery arms its timer with.
    var probeTimeout: NetworkDuration = .zero
    var ptoCount = 0
}

@available(Network 0.1.0, *)
extension QUICPath {
    /// What flow control asks about the path. Cheap to read, so it is read each time it is asked for.
    ///
    /// Inlined so the path is read where it is stored. Called out of line from inside a borrow of the path,
    /// the whole path is copied to the stack first, which costs far more than reading three fields.
    @inline(always)
    var snapshot: CurrentPathState {
        CurrentPathState(
            mss: mss,
            smoothedRTT: rtt.smoothedRTT,
            availableCongestionWindow: congestionControlAvailableCongestionWindow
        )
    }

    /// All of the state, including the probe timeout Recovery arms its timer with. Worked out only when the
    /// state is being held for a path that is about to be unreachable. Inlined for the same reason as `snapshot`.
    @inline(always)
    var fullSnapshot: CurrentPathState {
        var state = self.snapshot
        state.probeTimeout = Recovery.computedPTO(rtt: rtt)
        state.ptoCount = recoveryState.PTOCount
        return state
    }
}

@available(Network 0.1.0, *)
extension QUICConnection {
    /// Keeps the state of the current path for whoever asks while it is being worked on. Called where the
    /// state changes: when work on the path begins, and when an ACK has changed its RTT and window.
    @inline(always)
    func holdStateIfCurrent(_ path: borrowing QUICPath) {
        if path.pathIdentifier == currentPathID {
            heldCurrentPathState = path.fullSnapshot
        }
    }

    /// Passes on a path's request to reset the migration timer, which the path made because it sent or
    /// answered a challenge. Returns whether there was one. The reset itself runs when no path is
    /// borrowed (`resetMigrationTimerIfPending`), since the timer looks at every path.
    @inline(always)
    @discardableResult
    func forwardMigrationTimerResetRequest(from path: inout QUICPath) -> Bool {
        guard let requestedAt = path.migrationTimerResetRequest else { return false }
        path.migrationTimerResetRequest = nil
        migrationWork.migrationTimerResetPending = true
        migrationWork.migrationTimerResetNow = requestedAt
        return true
    }

    /// Takes back what a send charged a path's congestion control for a packet that Recovery then refused to
    /// track. The charge is made when the packet is built, so it would otherwise stay in flight for good.
    ///
    /// Kept out of line: inlined into Recovery's loop over sent packets, the optimizer hoists the path entries
    /// access above the check for a borrowed path, and the access then conflicts with the borrow that is open
    /// around the send.
    @inline(never)
    func refundCongestionControlCharge(bytes: Int, on pathID: MultiplexingPathIdentifier) {
        let refunded: Void? = withPath(pathID) { (path: inout QUICPath) in
            path.congestionControlPacketDiscarded(bytesSent: bytes, qlog: qLog)
        }
        if refunded == nil {
            log.fault("Could not refund \(bytes) bytes charged to path \(pathID): the path is busy or gone")
        }
    }

    // MARK: Borrowing for work

    /// Borrows the path, in place, for a long piece of work that sends nothing of its own, for callers that
    /// are in the middle of Recovery. A send that is asked for while it runs waits, and is replayed by whoever
    /// finishes the work, once Recovery is free.
    ///
    /// Returns `nil` without running `body` if there is no such path, or it is already borrowed.
    func withPathWorkFromRecovery<R: ~Copyable>(
        _ pathID: MultiplexingPathIdentifier,
        _ body: (inout QUICPath) -> R
    ) -> R? {
        guard hasPath(pathID), !isPathBorrowed else { return nil }
        deferredWork.beginPathCheckout()
        defer { deferredWork.endPathCheckout() }
        return withPath(pathID) { (path: inout QUICPath) -> R in
            if path.pathIdentifier == currentPathID {
                heldCurrentPathState = path.fullSnapshot
            }
            let result = body(&path)
            forwardMigrationTimerResetRequest(from: &path)
            return result
        }
    }

    /// Like `withPathWorkFromRecovery`, and replays the sends that waited once the path is back. Only for callers
    /// that are not in the middle of Recovery, which sending reaches.
    func withPathWork<R: ~Copyable>(
        _ pathID: MultiplexingPathIdentifier,
        replayingSendsIn eventContext: inout NetworkContext.EventContext,
        _ body: (inout QUICPath, inout NetworkContext.EventContext) -> R
    ) -> R? {
        guard hasPath(pathID), !isPathBorrowed else { return nil }
        deferredWork.beginPathCheckout()
        let result = withPath(pathID) { (path: inout QUICPath) -> R in
            if path.pathIdentifier == currentPathID {
                heldCurrentPathState = path.fullSnapshot
            }
            let result = body(&path, &eventContext)
            forwardMigrationTimerResetRequest(from: &path)
            return result
        }
        if deferredWork.endPathCheckout() {
            replayDeferredSends(in: &eventContext)
        }
        return result
    }
}

#endif
