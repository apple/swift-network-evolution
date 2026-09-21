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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

/*
 * A zombie stream is a stream that was forcefully deallocated by the upper
 * layer protocol (via remove_input_handler()) but we have yet to receive its
 * final size from the peer.  The name comes from the zombie process which sits
 * in the process table waiting for the parent to read its exit code.
 */

@available(Network 0.1.0, *)
struct QUICStreamZombie {
    let streamID: QUICStreamID
    let logIDString: String

    // Contains the last received STREAM size before we
    // destroyed this stream.  Used when we calculate the
    // new final size for flow control.
    var lastSize: UInt64

    // Contains the MAX_STREAM_DATA that was advertised
    // to the peer by the time this stream went away.
    var localMaxStreamData: UInt64

    init(streamID: QUICStreamID, lastSize: UInt64, localMaxStreamData: UInt64, logIDString: String) {
        self.streamID = streamID
        self.lastSize = lastSize
        self.localMaxStreamData = localMaxStreamData
        self.logIDString = logIDString
        Logger.proto.info(
            "\(logIDString) Unknown final size; creating zombie stream (last size \(lastSize))"
        )
    }

    func updateLastOffset(
        connection: QUICConnection,
        newLastOffset: UInt64,
        newFinalSize: UInt64,
        lastOffset: UInt64,
    ) -> UInt64? {
        // Like QUICStream.updateLastOffset() but on a zombie and:
        // - final is always true
        // - receiveState is assumed to be .receive
        // - previous finalSize is invalid
        // - and any side effects to QUICStreamInstance are thrown away

        // Case 1 is never true because final is true

        // (2) Endpoint received data with final size that's lower
        // than the size of the stream data that was already established
        if newLastOffset < lastOffset {
            connection.log.error(
                "Endpoint received size \(newLastOffset) that's lower than size of the stream \(lastOffset)"
            )
            connection.close(
                with:
                    .finalSizeError,
                "received final size lower than already received size"
            )
            return nil
        }

        // Case 3 is never true because finalSize is invalid
        connection.log.datapath("Zombie final size was \(newFinalSize)")

        guard lastOffset < newLastOffset else {
            return nil
        }
        let lastOffsetDelta = newLastOffset - lastOffset
        connection.updateLastReceivedOffsetForZombie(lastOffsetDelta: lastOffsetDelta)
        return lastOffsetDelta
    }
}

@available(Network 0.1.0, *)
struct QUICStreamZombieList {
    private var zombies: [QUICStreamZombie] = []

    mutating func append(
        logIDString: String,
        streamID: QUICStreamID,
        lastSize: UInt64,
        localMaxStreamData: UInt64
    ) {
        guard !zombies.contains(where: { $0.streamID == streamID }) else {
            Logger.proto.fault(
                "\(logIDString) Connection trying to create zombie that's already on zombie list! (last size \(lastSize))"
            )
            return
        }
        Logger.proto.info(
            "\(logIDString) Unknown final size; creating a zombie stream (last size \(lastSize))"
        )

        let zombie = QUICStreamZombie(
            streamID: streamID,
            lastSize: lastSize,
            localMaxStreamData: localMaxStreamData,
            logIDString: logIDString
        )
        zombies.append(zombie)
    }

    func find(streamID: QUICStreamID) -> QUICStreamZombie? {
        zombies.first(where: { $0.streamID == streamID })
    }

    /*
     * Called when we received the final size for this zombie stream.
     * We calculate the offset between the last received offset and
     * the final size and account that in the connection level flow
     * control.
     */
    mutating func finalSizeReceived(
        logIDString: String,
        streamID: QUICStreamID,
        finalSize: UInt64,
        connection: QUICConnection
    ) {
        let zombie = find(streamID: streamID)
        zombies.removeAll(where: { $0.streamID == streamID })
        let lastSize = zombie?.lastSize

        guard let zombie, let lastSize else {
            connection.log.debug(
                "[S\(streamID)] Received final size of \(finalSize) but zombie not found or last size unknown"
            )
            return
        }
        connection.log.debug(
            "Received final size of \(finalSize) (previous received size \(lastSize)"
        )

        let newLastOffset = finalSize == 0 ? 0 : finalSize - 1
        let prevLastOffset = zombie.lastSize == 0 ? 0 : zombie.lastSize - 1

        // Similarly to receiving a RESET_STREAM, simulate the consumption
        // of the bytes.
        if zombie.lastSize < finalSize {
            connection.updateFlowControlWithFinalSizeForZombieStream(
                finalSize: finalSize,
                lastSize: zombie.lastSize
            )
        }

        guard
            let updatedLastOffsetDelta = zombie.updateLastOffset(
                connection: connection,
                newLastOffset: newLastOffset,
                newFinalSize: finalSize,
                lastOffset: prevLastOffset
            )
        else {
            connection.log.error(
                "Final size invariants violated (final size \(finalSize))"
            )
            return
        }
        if updatedLastOffsetDelta != 0 {
            connection.sendInboundFlowControlCredit()
        }
    }

    mutating func flush() {
        zombies.removeAll()
    }
}
#endif
