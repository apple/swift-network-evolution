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
// RFC 9297, Section 2.1: the flow ID in front of each DATAGRAM frame's payload is the Quarter Stream
// ID, the ID of the client-initiated bidirectional stream the datagram is associated with, divided
// by four. The allocated flow IDs of earlier drafts are not supported.
@available(Network 0.1.0, *)
struct QUICDatagramFlowID: Hashable {
    private(set) var value: UInt64

    // The largest stream ID is 2^62-1, so the largest Quarter Stream ID is 2^60-1.
    static let maxValid: UInt64 = QUICStreamID.maxValid / 4

    init?(_ value: UInt64) {
        guard value <= QUICDatagramFlowID.maxValid else {
            return nil
        }
        self.value = value
    }

    init?(associatedStreamID: QUICStreamID) {
        guard associatedStreamID.isClientInitiated, associatedStreamID.isBidirectional else {
            return nil
        }
        self.value = associatedStreamID.value / 4
    }

    var variableLengthSize: Int {
        value.variableLengthSize
    }
}

@available(Network 0.1.0, *)
extension QUICDatagramFlowID: CustomStringConvertible {
    var description: String {
        String(value)
    }
}
#endif
