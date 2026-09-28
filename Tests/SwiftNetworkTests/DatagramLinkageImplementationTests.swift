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

@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
import XCTest

// The datagram linkages hold their implementation in an existential, whose inline value buffer is
// three words. An implementation larger than that is heap-boxed on every copy of the linkage, which
// would cost more than the switch dispatch this replaced -- so the sizes below are load-bearing, not
// incidental. See `DatagramLinkageImplementations.swift`.
@available(anyAppleOS 27, *)
final class DatagramLinkageImplementationTests: XCTestCase {

    // The inline value buffer of any existential, in bytes.
    private static let inlineBufferSize = 24

    func testStorageBackedImplementationsFitInline() {
        // A storage reference, an event state index, and a slot index: exactly three words.
        XCTAssertEqual(MemoryLayout<UDPInboundLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<UDPOutboundLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<IPInboundLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<IPOutboundLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<DemuxInboundLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<DemuxOutboundLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<TCPInboundDatagramLinkage>.size, Self.inlineBufferSize)
        XCTAssertEqual(MemoryLayout<BridgeDatagramOutboundLinkage>.size, Self.inlineBufferSize)
        #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
        XCTAssertEqual(MemoryLayout<SocketDatagramOutboundLinkage>.size, Self.inlineBufferSize)
        #endif
    }

    func testExistentialsAreNotBoxed() {
        // 40 bytes is an unboxed existential: the 24-byte value buffer plus a metadata pointer and a
        // witness table pointer. `Optional` is free here, because the existential has spare bits.
        XCTAssertEqual(MemoryLayout<any InboundDatagramLinkageImplementation>.size, 40)
        XCTAssertEqual(MemoryLayout<any OutboundDatagramLinkageImplementation>.size, 40)
        XCTAssertEqual(MemoryLayout<(any OutboundDatagramLinkageImplementation)?>.size, 40)

        // The linkages themselves are just the optional existential.
        XCTAssertEqual(MemoryLayout<BaseInboundDatagramLinkage>.size, 40)
        XCTAssertEqual(MemoryLayout<BaseOutboundDatagramLinkage>.size, 40)
    }

    // Size alone does not prove the value is stored inline, so confirm the implementation's own
    // fields live inside the existential rather than in a box it points at. This has to open the
    // existential in place: a non-mutating probe measures a copy and always reads as boxed.
    func testStoredImplementationIsInlineNotBoxed() {
        let context = NetworkContext(identifier: "DatagramLinkageImplementationTests")
        context.activate()
        let storage = BaseNetworkProtocolStorage(context: context)

        // No instance is created: only the implementation's layout is under test, and nothing here
        // calls through to one.
        var implementation: any OutboundDatagramLinkageImplementation = IPOutboundLinkage(
            storage: storage,
            eventStateIndex: .none,
            index: .none
        )

        let existentialAddress = withUnsafeMutableBytes(of: &implementation) { UInt(bitPattern: $0.baseAddress) }
        let valueAddress = implementation.addressOfSelfForTesting()
        XCTAssertEqual(valueAddress, existentialAddress, "Implementation was heap-boxed instead of stored inline")
    }
}

@available(Network 0.1.0, *)
extension OutboundDatagramLinkageImplementation {
    // `mutating` so the existential is opened in place and this sees the stored value, not a copy.
    fileprivate mutating func addressOfSelfForTesting() -> UInt {
        withUnsafeMutableBytes(of: &self) { UInt(bitPattern: $0.baseAddress) }
    }
}
