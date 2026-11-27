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

#if SignpostOutput && canImport(os)

internal import os

@available(Network 0.1.0, *)
struct QUICSignpost {
    typealias IntervalState = OSSignpostIntervalState
    private static let signposter = OSSignposter(logger: Logger.proto)

    static func makeSignpostID() -> OSSignpostID {
        signposter.makeSignpostID()
    }

    static func connectBegin(id: OSSignpostID) -> IntervalState {
        signposter.beginInterval("connect", id: id)
    }

    static func connectEnd(_ intervalState: IntervalState) {
        signposter.endInterval("connect", intervalState)
    }

    static func disconnect(id: OSSignpostID) {
        signposter.emitEvent("disconnect", id: id)
    }

    static func draining(id: OSSignpostID) {
        signposter.emitEvent("draining", id: id)
    }

    static func inbound(id: OSSignpostID, length: Int) {
        signposter.emitEvent("inboundPacket", id: id, "\(length) bytes")
    }

    static func inboundStarting(id: OSSignpostID) -> IntervalState {
        signposter.beginInterval("inboundProcessing", id: id)
    }

    static func inboundStopping(_ intervalState: IntervalState) {
        signposter.endInterval("inboundProcessing", intervalState)
    }

    static func outbound(id: OSSignpostID, length: Int) {
        signposter.emitEvent("outboundPacket", id: id, "\(length) bytes")
    }

    static func outboundStarting(id: OSSignpostID) -> IntervalState {
        signposter.beginInterval("outboundProcessing", id: id)
    }

    static func outboundStopping(_ intervalState: IntervalState) {
        signposter.endInterval("outboundProcessing", intervalState)
    }

    static func dataReceived(id: OSSignpostID, streamID: QUICStreamID, nbytes: Int) {
        signposter.emitEvent("dataReceived", id: id, "Stream \(streamID.value) received \(nbytes) bytes")
    }

    static func dataDelivered(id: OSSignpostID, streamID: QUICStreamID, nbytes: Int) {
        signposter.emitEvent("dataDelivered", id: id, "Stream \(streamID.value) read \(nbytes) bytes")
    }

    // Crypto signposts.
    static func sealBegin(keyState: String, packetNumber: PacketNumber) -> IntervalState {
        signposter.beginInterval("sealPacket", "\(keyState) #\(packetNumber)")
    }

    static func sealEnd(_ intervalState: IntervalState) {
        signposter.endInterval("sealPacket", intervalState)
    }

    static func openBegin(keyState: String, packetNumber: PacketNumber) -> IntervalState {
        signposter.beginInterval("openPacket", "\(keyState) #\(packetNumber)")
    }

    static func openEnd(_ intervalState: IntervalState) {
        signposter.endInterval("openPacket", intervalState)
    }

    // Congestion control signposts.
    static func congestionWindow(congestionWindow: Int) {
        signposter.emitEvent("congestionWindow", "\(congestionWindow) bytes")
    }

    static func bytesInFlight(bytesInFlight: Int) {
        signposter.emitEvent("bytesInFlight", "\(bytesInFlight) bytes")
    }

    static func congestionWindowLimited(bytesInFlight: Int, congestionWindow: Int) {
        signposter.emitEvent(
            "congestionWindowLimited",
            "Window: \(congestionWindow) bytes, bytes in flight: \(bytesInFlight)"
        )
    }
}
#else
// Signposts are not enabled unless the `SignpostOutput` package trait is
// enabled and the target platform supports Apple's OS signposting APIs.
@available(Network 0.1.0, *)
struct QUICSignpost {
    typealias IntervalState = Int
    static func makeSignpostID() -> Int { 0 }

    static func connectBegin(id: Int) -> IntervalState { 0 }
    static func connectEnd(_ intervalState: IntervalState) {}
    static func disconnect(id: Int) {}
    static func draining(id: Int) {}
    static func inbound(id: Int, length: Int) {}
    static func inboundStarting(id: Int) -> IntervalState { 0 }
    static func inboundStopping(_ intervalState: IntervalState) {}
    static func outbound(id: Int, length: Int) {}
    static func outboundStarting(id: Int) -> IntervalState { 0 }
    static func outboundStopping(_ intervalState: IntervalState) {}
    static func dataReceived(id: Int, streamID: QUICStreamID, nbytes: Int) {}
    static func dataDelivered(id: Int, streamID: QUICStreamID, nbytes: Int) {}
    static func sealBegin(keyState: String, packetNumber: PacketNumber) -> IntervalState { 0 }
    static func sealEnd(_ intervalState: IntervalState) {}
    static func openBegin(keyState: String, packetNumber: PacketNumber) -> IntervalState { 0 }
    static func openEnd(_ intervalState: IntervalState) {}
    static func congestionWindow(congestionWindow: Int) {}
    static func bytesInFlight(bytesInFlight: Int) {}
    static func congestionWindowLimited(bytesInFlight: Int, congestionWindow: Int) {}
}
#endif
#endif
