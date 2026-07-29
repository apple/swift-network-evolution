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

@available(Network 0.1.0, *)
final class SwiftNetworkFrameDeserializerTests: NetTestCase {

    func testUInt8InlineValue() throws {
        var frame = Frame(copyBuffer: [0xAB] as [UInt8])
        defer { frame.finalize(success: false) }
        do throws(DeserializationError) {
            let value = try FrameDeserializer.uint8(frame: &frame, claim: true)
            XCTAssertEqual(value, 0xAB)
        } catch {
            XCTFail("Unexpected deserialization error: \(error)")
        }
    }

    func testUInt8PeekDoesNotAdvanceOffset() throws {
        var frame = Frame(copyBuffer: [0xCD, 0xEF] as [UInt8])
        defer { frame.finalize(success: false) }
        do throws(DeserializationError) {
            let firstUnclaimed = try FrameDeserializer.uint8(frame: &frame, claim: false)
            let nextClaimed = try FrameDeserializer.uint8(frame: &frame, claim: true)
            XCTAssertEqual(firstUnclaimed, 0xCD)
            XCTAssertEqual(nextClaimed, 0xCD)
            XCTAssertEqual(frame.unclaimedLength, 1)
        } catch {
            XCTFail("Unexpected deserialization error: \(error)")
        }
    }

    func testUInt64InlineValue() throws {
        let bytes: [UInt8] = [0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41]
        var frame = Frame(copyBuffer: bytes)
        defer { frame.finalize(success: false) }
        do throws(DeserializationError) {
            let value = try FrameDeserializer.uint64(frame: &frame, claim: true)
            XCTAssertEqual(value, 0x4141_4141_4141_4141)
            XCTAssertEqual(frame.unclaimedLength, 0)
        } catch {
            XCTFail("Unexpected deserialization error: \(error)")
        }
    }

    func testUInt64NetworkByteOrderInlineValue() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        var frame = Frame(copyBuffer: bytes)
        defer { frame.finalize(success: false) }
        do throws(DeserializationError) {
            let value = try FrameDeserializer.uint64NetworkByteOrder(frame: &frame, claim: true)
            XCTAssertEqual(value, 0x0102_0304_0506_0708)
            XCTAssertEqual(frame.unclaimedLength, 0)
        } catch {
            XCTFail("Unexpected deserialization error: \(error)")
        }
    }

    func testUInt64NetworkByteOrderThenUInt8Sequential() throws {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x42]
        var frame = Frame(copyBuffer: bytes)
        defer { frame.finalize(success: false) }
        do throws(DeserializationError) {
            let high = try FrameDeserializer.uint64NetworkByteOrder(frame: &frame, claim: true)
            let low = try FrameDeserializer.uint8(frame: &frame, claim: true)
            XCTAssertEqual(high, 0x0000_0000_0000_00FF)
            XCTAssertEqual(low, 0x42)
            XCTAssertEqual(frame.unclaimedLength, 0)
        } catch {
            XCTFail("Unexpected deserialization error: \(error)")
        }
    }

}
