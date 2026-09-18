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

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness

#if canImport(Foundation)
import Foundation
#endif

#if canImport(Glibc)
import Glibc
internal import SwiftNetworkLinuxShim
#elseif canImport(Musl)
import Musl
internal import SwiftNetworkLinuxShim
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkUUIDTests: NetTestCase {

    func testUUIDCreation() {
        let uuid1 = SystemUUID()
        let uuid2 = SystemUUID()
        XCTAssertFalse(uuid1.isUUIDNULL)
        XCTAssertFalse(uuid2.isUUIDNULL)

        // Validate UUID has correctly masked bytes
        let span = uuid1.span
        XCTAssertEqual((span[6] & 0xF0), 0x40)
        XCTAssertEqual((span[8] & 0xC0), 0x80)
    }

    func testUUIDCreationInsecure() throws {
        let uuid1 = SystemUUID(insecure: true)
        let uuid1Copy = try SystemUUID(uuid1.span)
        XCTAssertEqual(uuid1, uuid1Copy)
    }

    func testUUIDComparison() throws {
        let uuid1 = SystemUUID()
        let uuid2 = try SystemUUID(uuid1.span)
        XCTAssertTrue(uuid1 == uuid2)
        let uuid3 = SystemUUID()
        XCTAssertFalse(uuid2 == uuid3)
    }

    func testUUIDString() throws {
        let uuid = SystemUUID()
        XCTAssertNotNil(uuid.description)
        XCTAssertTrue(uuid.description.count > 0)

        let uuid2 = try SystemUUID(uuid.span)
        XCTAssertEqual(uuid.description, uuid2.description)
    }

    func testUUIDDynamicCreation() throws {
        var front = UInt64.random(in: 0...UInt64.max)
        var back = UInt64.random(in: 0...UInt64.max)
        let firstHalf = withUnsafePointer(to: &front) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<UInt64>.size) {
                UnsafeBufferPointer(start: $0, count: MemoryLayout<UInt64>.size)
            }
        }
        let secondHalf = withUnsafePointer(to: &back) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<UInt64>.size) {
                UnsafeBufferPointer(start: $0, count: MemoryLayout<UInt64>.size)
            }
        }
        let complete: [UInt8] = Array(firstHalf) + Array(secondHalf)
        let uuid1 = try SystemUUID(complete.span)
        let uuid2 = try SystemUUID(uuid1.span)
        XCTAssertEqual(uuid1, uuid2)
    }

    func testSystemUUIDNULLCopying() throws {
        let emptyBytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let converted = try SystemUUID(emptyBytes.span)
        XCTAssertNotNil(converted)
        XCTAssertTrue(converted.isUUIDNULL)
        XCTAssertEqual(converted.description, "00000000-0000-0000-0000-000000000000")
    }

    #if canImport(Foundation)
    func testSystemUUIDCreationFromFoundation() throws {
        let foundationUUID = UUID()
        let cUUID = foundationUUID.uuid

        var originalArray: [UInt8] {
            withUnsafeBytes(of: cUUID) { buf in
                [UInt8](buf)
            }
        }

        let systemUUID = try SystemUUID(originalArray.span)
        let derivedArray = [UInt8](copying: systemUUID.span, maxCount: 16)

        XCTAssertTrue(originalArray == derivedArray)
        XCTAssertEqual(systemUUID.description, foundationUUID.description)

        let derivedFoundationUUID = UUID(uuidString: systemUUID.description)
        XCTAssertEqual(foundationUUID, derivedFoundationUUID)
        XCTAssertEqual(foundationUUID.description, derivedFoundationUUID?.description)
    }
    #endif
}
