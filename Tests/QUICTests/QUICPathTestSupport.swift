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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
extension QUICConnection {
    /// Lends out a path the test knows is in the connection's paths, and stops the test if it is not.
    ///
    /// Paths are non-copyable and live in the connection's path entries, so a test reads and changes one inside `body`.
    @discardableResult
    func testPath<R: ~Copyable>(
        _ pathID: MultiplexingPathIdentifier,
        _ body: (inout QUICPath) -> R
    ) -> R {
        guard let result = withPath(pathID, body) else {
            fatalError("Path \(pathID) is not in the path entries, or is checked out")
        }
        return result
    }

    /// Lends out the current path, and stops the test if there is none.
    @discardableResult
    func testCurrentPath<R: ~Copyable>(_ body: (inout QUICPath) -> R) -> R {
        guard let result = withCurrentPath(body) else {
            fatalError("There is no current path in the path entries")
        }
        return result
    }

    /// Adds a path built with `QUICPath.makeFromExternalTest(parent:)` to the entries and returns its identifier.
    @discardableResult
    func addTestPath(_ path: consuming QUICPath) -> MultiplexingPathIdentifier {
        let pathID = path.pathIdentifier
        insertPath(path, for: pathID)
        return pathID
    }

    /// Builds a path on the connection's queue, lets `configure` set it up, and adds it to the entries.
    func makeTestPath(configure: (inout QUICPath) -> Void = { _ in }) -> MultiplexingPathIdentifier {
        context.onQueue {
            var path = QUICPath.makeFromExternalTest(parent: self)
            configure(&path)
            return addTestPath(path)
        }
    }

    /// Does for a sent packet what the packet builder does as it builds the packet: tells the path about
    /// the packet. Recovery records the packet afterwards and does not look the path up again, so a test
    /// that records packets straight into Recovery calls this first.
    func notePathSent(_ packet: inout SentPacketRecord) {
        let sentLength = packet.totalLength
        let isInFlightEligible = packet.isInFlightEligible
        let qLog = self.qLog
        let larger: Bool =
            withPath(packet.sentPath) { (path: inout QUICPath) -> Bool in
                if isInFlightEligible {
                    path.congestionControlPacketsSent(bytesSent: sentLength, qlog: qLog)
                }
                return sentLength > path.minimumMSS && sentLength <= path.mss
            } ?? false
        if larger {
            packet.largerPacket = true
        }
    }

    /// Adds a path to the entries, makes it the current path and refreshes what the rest of the connection
    /// reads about the current path, so a test that has set up the path's MSS or window sees it used.
    @discardableResult
    func installCurrentPath(_ path: consuming QUICPath) -> MultiplexingPathIdentifier {
        let pathID = addTestPath(path)
        currentPathID = pathID
        testCurrentPath { (_: inout QUICPath) in }
        return pathID
    }
}

#endif
