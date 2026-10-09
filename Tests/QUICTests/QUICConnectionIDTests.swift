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

import Dispatch
import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
class QUICConnectionIDTests: XCTestCase {
    func testEmptyConnectionID() {
        let connectionID = QUICConnectionID([])
        XCTAssertNotNil(connectionID)
        guard let connectionID else { return }
        XCTAssertEqual(connectionID.length, 0)
        XCTAssertEqual(connectionID.connectionID, [])
        XCTAssertEqual(connectionID.description, "")
        XCTAssertEqual(connectionID.description.count, 0)
    }

    func testOneByteConnectionID() {
        let connectionID = QUICConnectionID([1])
        XCTAssertNotNil(connectionID)
        guard let connectionID else { return }
        XCTAssertEqual(connectionID.length, 1)
        XCTAssertEqual(connectionID.connectionID, [1])
        XCTAssertEqual(connectionID.description, "01")
        XCTAssertEqual(connectionID.description.count, 2)
    }

    func test20ByteConnectionID() {
        let twentyByteArray: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 0x10, 0x11, 0x12, 0x13, 0x14,
        ]
        let twentyByteArrayCopy = twentyByteArray
        let connectionID = QUICConnectionID(twentyByteArray)
        XCTAssertNotNil(connectionID)
        guard let connectionID else { return }
        XCTAssertEqual(connectionID.length, 20)
        XCTAssertEqual(connectionID.connectionID, twentyByteArrayCopy)
        XCTAssertEqual(connectionID.description, "0102030405060708090a0b0c0d0e0f1011121314")
        XCTAssertEqual(connectionID.description.count, 40)
    }

    func test21ByteConnectionID() {
        let twentyOneByteArray: [UInt8] = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 0x10, 0x11, 0x12, 0x13, 0x14,
            0x15,
        ]
        let connectionID = QUICConnectionID(twentyOneByteArray)
        XCTAssertNil(connectionID)
    }

    func testCompareConnectionIDs() {
        let a = QUICConnectionID([1, 2])
        let equal = QUICConnectionID([1, 2])
        let notEqual = QUICConnectionID([0xff, 0xff])
        XCTAssertTrue(a == equal)
        XCTAssertFalse(a == notEqual)
    }

    func testRandomInit() {
        let c1 = QUICConnectionID(10)
        let c2 = QUICConnectionID(20)

        XCTAssertEqual(c1.length, 10)
        XCTAssertEqual(c2.length, 20)
        XCTAssertNotEqual(c1, c2)
    }

    func testBufferInit() {
        let c1 = QUICConnectionID([1, 2, 3, 4, 55], size: 4)!

        XCTAssertEqual(c1.connectionID, [1, 2, 3, 4])
    }

    func testUninitialized() {
        let c1 = QUICConnectionID(5)
        XCTAssertFalse(c1.isUninitialized)
        XCTAssertEqual(c1.length, 5)

        let cidBytes = [UInt8](repeating: 0, count: 8)
        let c2 = QUICConnectionID(cidBytes)
        XCTAssertNotNil(c2)
        guard let c2 else { return }
        XCTAssertTrue(c2.isUninitialized)
        XCTAssertEqual(c2.length, 8)
    }

    func testStorageInit() {
        let c1 = QUICConnectionID(10)
        let storage = c1.connectionIDStorage
        let c2 = QUICConnectionID(storage: storage, size: 10)

        XCTAssertEqual(c1, c2)
    }

    #if !NETWORK_PRIVATE
    func testStorageInitInvalidLength() {
        let c1 = QUICConnectionID(10)
        let storage = c1.connectionIDStorage
        let c2 = QUICConnectionID(storage: storage, size: 255)

        XCTAssertNotEqual(c1, c2)
        XCTAssertEqual(c2.length, 20)
    }
    #endif

    func testDeserializerInit() {
        let c1 = QUICConnectionID([1, 2, 3, 4], size: 4)
        var frame = Frame(copyBuffer: [1, 2, 3, 4])
        defer {
            frame.finalize(success: true)
        }
        var c2Storage = QUICConnectionIDStorage.empty
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.connectionID(&c2Storage, length: 4)
        }
        XCTAssertEqual(result, .success(parsedBytes: 4, remainingBytes: 0))
        let c2 = QUICConnectionID(storage: c2Storage, size: 4)
        XCTAssertEqual(c1, c2)
    }

    func testDeserializerInitFailure() {
        var frame = Frame(copyBuffer: [1, 2, 3, 4])
        defer {
            frame.finalize(success: true)
        }
        var cidStorage = QUICConnectionIDStorage.empty
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.connectionID(&cidStorage, length: 255)
        }
        XCTAssertEqual(result, .error(.parsingFailed))
    }
}

#endif
