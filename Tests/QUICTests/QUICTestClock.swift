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

@available(Network 0.1.0, *)
extension NetworkClock.Instant {
    /// A fixed instant to seed tests that need one.
    ///
    /// The congestion controllers only order instants and measure durations between
    /// them, so the absolute value is arbitrary, but it has to be *fixed*. Seeding from
    /// the real clock makes every duration depend on how long the test itself took to run.
    ///
    /// Non-zero because much of the stack treats `.zero` as "unset".
    static var testBase: NetworkClock.Instant {
        NetworkClock.Instant(milliseconds: 1000)
    }
}

/// Test-only conveniences that supply a fixed time.
///
/// The production signatures deliberately require a time, so that datapath code cannot
/// silently reach for the real clock. Most ACK tests are about packet-number bookkeeping
/// and not about time at all, so restating `now:` several hundred times would be noise.
/// The default here is a *fixed* instant, so those tests stay deterministic. A test
/// whose premise is timing calls the full form and passes its own instant.
@available(Network 0.1.0, *)
extension Ack {
    func append(packetNumberSpace: PacketNumberSpace, packetNumber: PacketNumber) {
        self.append(
            packetNumberSpace: packetNumberSpace,
            packetNumber: packetNumber,
            now: .testBase
        )
    }

    func buildForTesting(
        for packetNumberSpace: PacketNumberSpace,
        setAckFrame: (PacketNumberSpace, consuming QUICFrame, Bool) -> Void,
        ecnCounter: ECNCounter? = nil
    ) -> Int {
        self.buildForTesting(
            for: packetNumberSpace,
            setAckFrame: setAckFrame,
            ecnCounter: ecnCounter,
            now: .testBase
        )
    }
}
#endif
