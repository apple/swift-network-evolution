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
@_spi(Essentials) import SwiftNetworkTestSupport
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(CollectionsInternal)
import CollectionsInternal
#elseif canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

@available(Network 0.1.0, *)
final class PMTUDTests: XCTestCase {
    private let maximumSegmentSize = 1200

    /// The bytes counted for one application packet of `totalLength` bytes sent on a path with a
    /// maximum segment size of `maximumSegmentSize`, in a round of probing that has just begun.
    private func bytesCounted(totalLength: Int, carriesStreamData: Bool) -> UInt64 {
        let clock = TestClockContext("test context")
        let connection = clock.onQueue {
            QUICConnection(context: clock.context)
        }
        defer { clock.onQueue { connection.destroyFromExternalTest() } }

        return clock.onQueue {
            let path = QUICPath.makeFromExternalTest(parent: connection)
            defer {
                connection.currentPath = nil
                path.destroyFromExternalTest()
            }

            path.mss = maximumSegmentSize
            connection.currentPath = path
            path.pmtudState.enabled = true

            var packet = SentPacketRecord()
            packet.identifier = .init(space: .applicationData, number: 1)
            packet.totalLength = totalLength
            packet.sentPath = path.pathIdentifier
            if carriesStreamData {
                packet.transmittedItems.sentStreams.append(
                    .init(
                        flowID: .allFlows,
                        streamID: QUICStreamID(0),
                        offset: 0,
                        length: UInt64(totalLength),
                        isFinal: false
                    )
                )
            }
            var sentPackets = NetworkUniqueDeque<SentPacketRecord>(minimumCapacity: 1)
            sentPackets.append(packet)

            path.pmtudState.countFullSizePackets(in: sentPackets, on: path)
            return path.pmtudState.fullSizeBytesSentInRound
        }
    }

    func testFullSizePacketWithStreamDataIsCounted() {
        XCTAssertEqual(
            bytesCounted(totalLength: maximumSegmentSize, carriesStreamData: true),
            UInt64(maximumSegmentSize)
        )
    }

    func testFullSizePacketWithoutStreamDataIsNotCounted() {
        // A full-size packet of acknowledgments or control frames says nothing about whether the
        // application would send more at a larger MTU; counting it would make a connection that
        // sends little probe.
        XCTAssertEqual(bytesCounted(totalLength: maximumSegmentSize, carriesStreamData: false), 0)
    }

    func testPacketWithRoomForAnotherStreamFrameIsNotCounted() {
        // The largest STREAM frame header is 25 bytes, so 26 unused bytes could still carry data.
        XCTAssertEqual(bytesCounted(totalLength: maximumSegmentSize - 26, carriesStreamData: true), 0)
    }

    func testPacketWithoutRoomForAnotherStreamFrameIsCounted() {
        XCTAssertEqual(
            bytesCounted(totalLength: maximumSegmentSize - 25, carriesStreamData: true),
            UInt64(maximumSegmentSize - 25)
        )
    }
}

#endif
