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

#if canImport(SwiftNetwork)
#if !NETWORK_NO_SWIFT_QUIC
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

// A path is stored inline in its connection's path entries and cannot be copied, so the tests look at one
// by borrowing it. These read the few things tests ask of a path by its identifier.
@available(Network 0.1.0, *)
extension QUICConnection {
    func pathState(_ pathID: MultiplexingPathIdentifier) -> QUICPathState? {
        withPath(pathID) { (path: inout QUICPath) in path.state }
    }

    func pathStatistic(_ pathID: MultiplexingPathIdentifier, _ statistic: QUICStatistic) -> Int {
        withPath(pathID) { (path: inout QUICPath) in path.pathStatistics[statistic] } ?? 0
    }

    func pathIdentifier(localPort: UInt16) -> MultiplexingPathIdentifier? {
        var found: MultiplexingPathIdentifier?
        applyToAllPaths { (path: inout QUICPath) in
            if found == nil, path.localEndpoint?.port == localPort {
                found = path.pathIdentifier
            }
        }
        return found
    }
}
#endif
#endif
