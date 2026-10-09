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
final class VLESize: XCTestCase {
    func test0() {
        let n: UInt64 = 0
        XCTAssertEqual(n.variableLengthSize, 1)
        XCTAssertEqual(n.variableLengthSize, n.safeVariableLengthSize)
    }
    func test1() {
        let n: UInt64 = 12
        XCTAssertEqual(n.variableLengthSize, 1)
        XCTAssertEqual(n.variableLengthSize, n.safeVariableLengthSize)
    }
    func test2() {
        let n: UInt64 = 3456
        XCTAssertEqual(n.variableLengthSize, 2)
        XCTAssertEqual(n.variableLengthSize, n.safeVariableLengthSize)
    }
    func test4() {
        let n: UInt64 = 27_491_766
        XCTAssertEqual(n.variableLengthSize, 4)
        XCTAssertEqual(n.variableLengthSize, n.safeVariableLengthSize)
    }
    func test8() {
        let n: UInt64 = 7_712_995_762_552
        XCTAssertEqual(n.variableLengthSize, 8)
        XCTAssertEqual(n.variableLengthSize, n.safeVariableLengthSize)
    }
    func testInvalid() {
        let n: UInt64 = 9_223_372_036_854_775_808
        // NOTE: n.variableLengthSize calls fatalError. Use safeVariableLengthSize instead
        XCTAssertNil(n.safeVariableLengthSize)
    }
    #if NETWORK_PERF_TESTS
    func testPerformance() {
        let n: [UInt64] = Array(repeating: 4_611_686_018_427_387_903, count: 1_000_000)
        var size: [Int] = [0]
        measure {
            size = n.map { $0.variableLengthSize }
        }
        XCTAssertTrue(size.allSatisfy { $0 == 8 })
    }
    #endif
}

@available(Network 0.1.0, *)
final class VLEEncoding: XCTestCase {
    func test0() throws {
        let n: UInt64 = 0
        let c = [UInt8]([0x00])
        var d = [UInt8]()
        n.variableLengthEncodeInto(&d)
        XCTAssertEqual(d, c)
    }

    func test1() throws {
        let n: UInt64 = 44
        let c = [UInt8]([0x2c])
        var d = [UInt8]()
        n.variableLengthEncodeInto(&d)
        XCTAssertEqual(d, c)
    }

    func test2() throws {
        let n: UInt64 = 12381
        let c = [UInt8]([0x70, 0x5d])
        var d = [UInt8]()
        n.variableLengthEncodeInto(&d)
        XCTAssertEqual(d, c)
    }

    func test4() throws {
        let n: UInt64 = 268_435_456
        let c = [UInt8]([0x90, 0x00, 0x00, 0x00])
        var d = [UInt8]()
        n.variableLengthEncodeInto(&d)
        XCTAssertEqual(d, c)
    }

    func test8() throws {
        let n: UInt64 = 57_849_345_434_345
        let c = [UInt8]([0xc0, 0x00, 0x34, 0x9d, 0x19, 0xaf, 0x62, 0xe9])
        var d = [UInt8]()
        n.variableLengthEncodeInto(&d)
        XCTAssertEqual(d, c)
    }

    func testMax() throws {
        // Max gets capped at UInt62-max
        let n: UInt64 = .max
        let c = [UInt8]([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        var d = [UInt8]()
        n.variableLengthEncodeInto(&d)
        XCTAssertEqual(d, c)
    }
}

@available(Network 0.1.0, *)
final class VLEDecoding: XCTestCase {
    func testEmpty() throws {
        let c = [UInt8]()
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result, .error(.bufferTooShort), "Invalid result \(result)")
    }

    func test0() throws {
        let n: UInt64 = 0
        let c = [UInt8]([0x00])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, n, "Failed to deserialize")
    }

    func test1() throws {
        let n: UInt64 = 44
        let c = [UInt8]([0x2c])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, n, "Failed to deserialize")
    }

    func test2() throws {
        let n: UInt64 = 12381
        let c = [UInt8]([0x70, 0x5d])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, n, "Failed to deserialize")
    }

    func testSmall2() throws {
        let c = [UInt8]([0x70])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result, .error(.bufferTooShort), "Invalid result \(result)")
    }

    func test4() throws {
        let n: UInt64 = 268_435_456
        let c = [UInt8]([0x90, 0x00, 0x00, 0x00])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, n, "Failed to deserialize")
    }

    func testSmall4() throws {
        let c = [UInt8]([0x90, 0x00, 0x00])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result, .error(.bufferTooShort), "Invalid result \(result)")
    }

    func test8() throws {
        let n: UInt64 = 57_849_345_434_345
        let c = [UInt8]([0xc0, 0x00, 0x34, 0x9d, 0x19, 0xaf, 0x62, 0xe9])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, n, "Failed to deserialize")
    }

    func testSmall8() throws {
        let c = [UInt8]([0xc0, 0x00, 0x34, 0x9d, 0x19, 0xaf, 0x62])
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }
        XCTAssertEqual(result, .error(.bufferTooShort), "Invalid result \(result)")
    }
}

@available(Network 0.1.0, *)
final class VLEValidation: XCTestCase {
    func test0() throws {
        let n: UInt64 = 0
        let c = [UInt8]([0x00])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
    }

    func test1() throws {
        let n: UInt64 = 44
        let c = [UInt8]([0x2c])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
    }

    func test1Invalid() throws {
        let n: UInt64 = 44
        let c = [UInt8]([0x00])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result, .error(.validationFailed), "Invalid result \(result)")
    }

    func test2() throws {
        let n: UInt64 = 12381
        let c = [UInt8]([0x70, 0x5d])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
    }

    func test2Invalid() throws {
        let n: UInt64 = 10000
        let c = [UInt8]([0x70, 0x5d])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result, .error(.validationFailed), "Invalid result \(result)")
    }

    func test4() throws {
        let n: UInt64 = 268_435_456
        let c = [UInt8]([0x90, 0x00, 0x00, 0x00])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
    }

    func test4Invalid() throws {
        let n: UInt64 = 268_000_000
        let c = [UInt8]([0x90, 0x00, 0x00, 0x00])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result, .error(.validationFailed), "Invalid result \(result)")
    }

    func test8() throws {
        let n: UInt64 = 57_849_345_434_345
        let c = [UInt8]([0xc0, 0x00, 0x34, 0x9d, 0x19, 0xaf, 0x62, 0xe9])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
    }

    func test8Invalid() throws {
        let n: UInt64 = 57_849_345_000_000
        let c = [UInt8]([0xc0, 0x00, 0x34, 0x9d, 0x19, 0xaf, 0x62, 0xe9])
        let result = Deserializer.deserialize(c) { read throws(DeserializationError) in
            try read.vle(expect: n)
        }
        XCTAssertEqual(result, .error(.validationFailed), "Invalid result \(result)")
    }
}

#endif
