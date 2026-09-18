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

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

// Shorthand spellings of the generic QUIC types bound to the base linkage families. These exist
// only for the tests: production code names its linkage families explicitly.

@available(Network 0.1.0, *)
typealias QUICTestPath = QUICPath<TestLinkageFamilyGroup>

@available(Network 0.1.0, *)
typealias QUICTestStream = QUICStreamInstance<TestLinkageFamilyGroup>

@available(Network 0.1.0, *)
typealias QUICTestAck = Ack<TestLinkageFamilyGroup>

@available(Network 0.1.0, *)
typealias QUICTestRecovery = Recovery<TestLinkageFamilyGroup>

@available(Network 0.1.0, *)
typealias QUICTestStreamIDState = QUICStreamIDState<TestLinkageFamilyGroup>

#endif
