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

@available(Network 0.1.0, *)
struct ShorthandPacket: ShorthandLogEntry {
    enum Kind {
        case versionNegotiation
        case retry
        case failedDecryption
        case protected(keyState: PacketKeyState, number: PacketNumber, longHeader: Bool)
    }

    let delta: NetworkDuration
    let outgoing: Bool
    let kind: Kind

    // For outgoing packets.
    init(packet: borrowing Packet, delta: NetworkDuration) {
        self.outgoing = true
        self.delta = delta
        self.kind = .protected(keyState: packet.keyState, number: packet.number, longHeader: packet.longHeader)
    }

    // For incoming packets.
    init(parsedPacket: borrowing PacketParser.ParsedPacket, delta: NetworkDuration) {
        self.outgoing = false
        self.delta = delta
        switch parsedPacket {
        case .versionNegotiation:
            self.kind = .versionNegotiation
        case .retry:
            self.kind = .retry
        case .failedDecryption:
            self.kind = .failedDecryption
        case .protected(let packet):
            self.kind = .protected(keyState: packet.keyState, number: packet.number, longHeader: packet.longHeader)
        }
    }

    var description: String {
        let duration = Double(delta.milliseconds) / 1000.0
        let prefix = "\(outgoing ? "snd" : "rcv") \(duration)s "
        switch kind {
        case .versionNegotiation:
            return prefix + "LH<vn>"
        case .retry:
            return prefix + "LH<retry>"
        case .failedDecryption:
            return prefix + "<undecryptable>"
        case .protected(let keyState, let number, let longHeader):
            if longHeader {
                return prefix + "LH<\(keyState.description), \(number.value)>"
            }
            return prefix + "SH<\(number.value)>"
        }
    }
}
#endif
