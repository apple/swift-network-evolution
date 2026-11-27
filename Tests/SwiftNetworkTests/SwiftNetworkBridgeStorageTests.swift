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

import Testing

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#endif

#if canImport(SwiftNetwork)
private struct NoDatagramsError: Error {}

/// Two bridges wired to each other, used from the context's own queue, which is where a protocol
/// instance must be built and entered.
@available(Network 0.1.0, *)
private struct BridgePair {
    let sender: BridgeDatagramProtocol.BridgeInstance
    let receiver: BridgeDatagramProtocol.BridgeInstance

    /// Runs `body` on a new context's queue with a connected pair, then tears the pair down.
    static func run(_ body: @escaping (BridgePair) throws -> Void) async throws {
        let context = NetworkContext(identifier: "BridgeStorageTests")
        var failure: (any Error)?
        await context.fromExternal {
            do {
                let senderPort = BridgeDatagramProtocol.BridgeInstance.nextGeneratedPort
                let receiverPort = BridgeDatagramProtocol.BridgeInstance.nextGeneratedPort
                let senderEndpoint = Endpoint(address: IPv4Address([0x0a, 0x00, 0x00, 0x14])!, port: senderPort)
                let receiverEndpoint = Endpoint(address: IPv4Address([0x0a, 0x00, 0x00, 0x75])!, port: receiverPort)
                let pair = BridgePair(
                    sender: BridgeDatagramProtocol.BridgeInstance(context: context),
                    receiver: BridgeDatagramProtocol.BridgeInstance(context: context)
                )
                try pair.sender.setup(remote: receiverEndpoint, local: senderEndpoint, parameters: nil, path: nil)
                try pair.receiver.setup(remote: senderEndpoint, local: receiverEndpoint, parameters: nil, path: nil)
                defer { pair.tearDown() }
                try body(pair)
            } catch {
                failure = error
            }
        }
        if let failure {
            throw failure
        }
    }

    /// Mirrors what the linkage layer does when it tears a protocol instance down; an instance
    /// built directly has to do this itself, or its event manager's `deinit` check fires.
    private func tearDown() {
        for instance in [sender, receiver] {
            instance.fromExternal { eventContext in
                instance.unregisterEventManager(in: &eventContext)
            }
            instance.teardown()
        }
    }

    func getDatagrams(count: Int) throws -> FrameArray {
        let frames = try sender.fromExternal { eventContext throws(NetworkError) -> FrameArray? in
            try sender.getDatagramsToSend(maximumDatagramCount: count, minimumDatagramSize: 100, in: &eventContext)
        }
        guard let frames else { throw NoDatagramsError() }
        return frames
    }

    func send(_ datagrams: consuming FrameArray) throws {
        var pending: FrameArray? = datagrams
        try sender.fromExternal { eventContext throws(NetworkError) in
            try sender.sendDatagrams(pending.take()!, in: &eventContext)
        }
    }

    func receiveAndFinalizeAll() throws {
        let frames = try receiver.fromExternal { eventContext throws(NetworkError) -> FrameArray? in
            try receiver.receiveDatagrams(maximumDatagramCount: 64, in: &eventContext)
        }
        guard var received = frames else { throw NoDatagramsError() }
        received.finalizeAllFramesAsFailed()
    }
}
#endif

// Swift Testing rejects `@available` on a suite or a test function, so each test narrows
// availability in its own body instead.
@Suite("Bridge send storage", .serialized)
struct SwiftNetworkBridgeStorageTests {
    /// A bridge must size the array it hands out for the largest batch the upper protocol has
    /// sent; otherwise a protocol that adopts that array as its send queue's storage finds it too
    /// small, and allocates a replacement on every send.
    @Test("The next array holds as many datagrams as the largest batch sent")
    func nextArrayHoldsLargestBatchSent() async throws {
        guard #available(Network 0.1.0, *) else { return }

        try await BridgePair.run { pair in
            let large = try pair.getDatagrams(count: 12)
            try pair.send(large)
            try pair.receiveAndFinalizeAll()

            var next = try pair.getDatagrams(count: 2)
            defer { next.finalizeAllFramesAsFailed() }

            #expect(next.count == 2)
            #expect(next.capacity >= 12, "expected room for the 12 datagrams sent earlier")
        }
    }

    /// Before anything is sent, the array holds what was asked for and no more.
    @Test("The first array holds the datagrams asked for")
    func firstArrayHoldsRequestedDatagrams() async throws {
        guard #available(Network 0.1.0, *) else { return }

        try await BridgePair.run { pair in
            var first = try pair.getDatagrams(count: 3)
            defer { first.finalizeAllFramesAsFailed() }

            #expect(first.count == 3)
            #expect(first.capacity < 12)
        }
    }
}
