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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkStreamDeserializationTests: NetTestCase {

    // Simple TLV protocol that uses variable-length integers
    struct TLVProtocol: ~Copyable {

        // MARK: - Deserialize

        struct TLVState: ~Copyable, StreamDeserializerState {
            typealias StateMachineStepIdentifier = TLVStateMachineStep
            enum TLVStateMachineStep: Hashable {
                case readingType
                case readingLength
                case readingValue
            }

            var type: UInt64?
            var length: Int?
            var value = FrameArray()
        }

        // Define a shared parser definition for TLV messages
        static let parser = FrameArrayStreamDeserializer<TLVState>.parser { stream in
            // 1) Parse the type
            stream.parsePartialMessage { read, state throws(DeserializationError) in
                try read.vle(&state.type)
            }

            // 2) Parse the length
            stream.parsePartialMessage { read, state throws(DeserializationError) in
                try read.vle(&state.length)
            }

            // 3) Forward the content
            stream.forwardPartialMessage(byteCount: { $0.length ?? 0 }) { byteCount, factory, state in
                let drainedFrames = factory.drainArray(maximumByteCount: byteCount)
                let drainedByteCount = drainedFrames.unclaimedLength
                state.value.add(frames: drainedFrames)
                return drainedByteCount
            }

            stream.finalizeMessage()
        }

        // Instantiate the parser
        var parser = StreamDeserializer(parser: TLVProtocol.parser)

        mutating func parse(from frames: inout FrameArray) -> TLVState? {
            try? parser.handleFrames(&frames)
        }

        // MARK: - Serialize

        static func write(type: UInt64, value: consuming FrameArray, into frames: inout FrameArray) {
            let valueLength = value.unclaimedLength
            let message = Serializer.serialize(frameCapacity: 8) { write in
                write.vle(type)
                write.vle(valueLength)
                write.frameArray(&value)
            }
            frames.add(frames: message)
        }
    }

    /// Extract all bytes from a FrameArray by reading allBytes from each frame, then finalize.
    func extractBytes(from frameArray: borrowing FrameArray) -> [UInt8] {
        var bytes = [UInt8]()
        frameArray.iterateImmutableFrames { frame in
            if let allBytes = frame.bytes {
                allBytes.withUnsafeBytes { buffer in
                    bytes.append(contentsOf: buffer)
                }
            }
            return true
        }
        return bytes
    }

    func testTLVSerialization() {
        let value = Serializer.serialize(frameCapacity: 256) { write in
            write.uint8(1)
            write.uint8(2)
            write.uint8(3)
            write.uint8(4)
        }
        var tlvFrames = FrameArray()
        TLVProtocol.write(type: 0x01, value: value, into: &tlvFrames)

        let tlvRawBytes = extractBytes(from: tlvFrames)

        // Capsule wire format: VLE(type) | VLE(length) | value
        // Type 0x01 = ADDRESS_ASSIGN (RFC 9484)
        // Value: VLE(request_id=0) | uint8(ip_version=4) | uint32(127.0.0.1) | uint8(prefix=32)
        let expectedTLVBytes: [UInt8] = [
            0x01,  // TLV Type (VLE, 1 byte for value < 64)
            0x04,  // TLV Value Length (VLE, 4 bytes of content)
            0x01, 0x02, 0x03, 0x04,  // Value
        ]
        XCTAssertEqual(tlvRawBytes, expectedTLVBytes)

        var tlvParser = TLVProtocol()
        let parsedTLV = tlvParser.parse(from: &tlvFrames)
        XCTAssertTrue(parsedTLV != nil)
        if var parsedTLV {
            XCTAssertEqual(parsedTLV.type, 0x01)

            let contentRawBytes = extractBytes(from: parsedTLV.value)

            // Parsed content should match the TLV value (without type and length prefix)
            let expectedContentBytes: [UInt8] = [
                0x01, 0x02, 0x03, 0x04,  // Value
            ]
            XCTAssertEqual(contentRawBytes, expectedContentBytes)

            parsedTLV.value.finalizeAllFramesAsFailed()

        }
        tlvFrames.finalizeAllFramesAsFailed()
    }

    // MARK: - Multiple TLV Deserialization

    func testMultipleTLVsDifferentSizes() {
        // Write several TLVs of different sizes into one frame array
        var tlvFrames = FrameArray()

        // TLV 1: type=0x01, 0 bytes of value
        TLVProtocol.write(type: 0x01, value: FrameArray(), into: &tlvFrames)

        // TLV 2: type=0x02, 1 byte of value
        let value2 = Serializer.serialize(frameCapacity: 8) { write in
            write.uint8(0xAA)
        }
        TLVProtocol.write(type: 0x02, value: value2, into: &tlvFrames)

        // TLV 3: type=0x03, 10 bytes of value
        let value3 = Serializer.serialize(frameCapacity: 16) { write in
            for i: UInt8 in 0..<10 { write.uint8(i) }
        }
        TLVProtocol.write(type: 0x03, value: value3, into: &tlvFrames)

        // TLV 4: type=0x04, 100 bytes of value (needs 2-byte VLE for length)
        let value4 = Serializer.serialize(frameCapacity: 128) { write in
            for i in 0..<100 { write.uint8(UInt8(i & 0xFF)) }
        }
        TLVProtocol.write(type: 0x04, value: value4, into: &tlvFrames)

        // TLV 5: type=0x05, 3 bytes of value
        let value5 = Serializer.serialize(frameCapacity: 8) { write in
            write.uint8(0xFF)
            write.uint8(0xFE)
            write.uint8(0xFD)
        }
        TLVProtocol.write(type: 0x05, value: value5, into: &tlvFrames)

        // Now deserialize them one at a time
        var tlvParser = TLVProtocol()

        // TLV 1: type=0x01, empty value
        guard var parsed1 = tlvParser.parse(from: &tlvFrames) else {
            XCTFail("Failed to parse TLV 1")
            tlvFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed1.type, 0x01)
        XCTAssertEqual(parsed1.length, 0)
        XCTAssertEqual(extractBytes(from: parsed1.value), [])
        parsed1.value.finalizeAllFramesAsFailed()

        // TLV 2: type=0x02, value=[0xAA]
        guard var parsed2 = tlvParser.parse(from: &tlvFrames) else {
            XCTFail("Failed to parse TLV 2")
            tlvFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed2.type, 0x02)
        XCTAssertEqual(extractBytes(from: parsed2.value), [0xAA])
        parsed2.value.finalizeAllFramesAsFailed()

        // TLV 3: type=0x03, value=[0..9]
        guard var parsed3 = tlvParser.parse(from: &tlvFrames) else {
            XCTFail("Failed to parse TLV 3")
            tlvFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed3.type, 0x03)
        let expected3: [UInt8] = (0..<10).map { UInt8($0) }
        XCTAssertEqual(extractBytes(from: parsed3.value), expected3)
        parsed3.value.finalizeAllFramesAsFailed()

        // TLV 4: type=0x04, value=[0..99]
        guard var parsed4 = tlvParser.parse(from: &tlvFrames) else {
            XCTFail("Failed to parse TLV 4")
            tlvFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed4.type, 0x04)
        let expected4: [UInt8] = (0..<100).map { UInt8($0 & 0xFF) }
        XCTAssertEqual(extractBytes(from: parsed4.value), expected4)
        parsed4.value.finalizeAllFramesAsFailed()

        // TLV 5: type=0x05, value=[0xFF, 0xFE, 0xFD]
        guard var parsed5 = tlvParser.parse(from: &tlvFrames) else {
            XCTFail("Failed to parse TLV 5")
            tlvFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed5.type, 0x05)
        XCTAssertEqual(extractBytes(from: parsed5.value), [0xFF, 0xFE, 0xFD])
        parsed5.value.finalizeAllFramesAsFailed()

        // No more TLVs
        if var parsedNone = tlvParser.parse(from: &tlvFrames) {
            XCTFail("Should not have parsed any more TLVs")
            parsedNone.value.finalizeAllFramesAsFailed()
        }

        tlvFrames.finalizeAllFramesAsFailed()
    }

    // MARK: - Partial Message Feeding

    /// Helper: serialize TLVs into raw bytes for controlled partial feeding.
    func serializeTLVBytes(type: UInt64, value: [UInt8]) -> [UInt8] {
        var frames = FrameArray()
        let valueFrames: FrameArray
        if value.isEmpty {
            valueFrames = FrameArray()
        } else {
            valueFrames = FrameArray(frame: Frame(copyBuffer: value))
        }
        TLVProtocol.write(type: type, value: valueFrames, into: &frames)
        let bytes = extractBytes(from: frames)
        frames.finalizeAllFramesAsFailed()
        return bytes
    }

    func testPartialFeedingOneByteAtATime() {
        // Serialize a TLV: type=0x01, value=[0x0A, 0x0B, 0x0C]
        let tlvBytes = serializeTLVBytes(type: 0x01, value: [0x0A, 0x0B, 0x0C])
        // Wire: [0x01, 0x03, 0x0A, 0x0B, 0x0C]
        XCTAssertEqual(tlvBytes, [0x01, 0x03, 0x0A, 0x0B, 0x0C])

        var tlvParser = TLVProtocol()
        var feedFrames = FrameArray()

        // Feed one byte at a time; parse should return nil until all bytes are present
        for i in 0..<tlvBytes.count {
            let byteFrame = FrameArray(frame: Frame(copyBuffer: [tlvBytes[i]]))
            feedFrames.add(frames: byteFrame)

            if i < tlvBytes.count - 1 {
                // Not enough data yet
                if var result = tlvParser.parse(from: &feedFrames) {
                    XCTFail("Should not parse with only \(i + 1) of \(tlvBytes.count) bytes")
                    result.value.finalizeAllFramesAsFailed()
                }
            }
        }

        // Now we have all bytes, should parse successfully
        guard var parsed = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse complete TLV")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, 0x01)
        XCTAssertEqual(extractBytes(from: parsed.value), [0x0A, 0x0B, 0x0C])
        parsed.value.finalizeAllFramesAsFailed()
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testPartialFeedingSplitInTypeField() {
        // Use a type that requires 2-byte VLE: type=100 (0x40, 0x64)
        // value=[0x01, 0x02]
        let tlvBytes = serializeTLVBytes(type: 100, value: [0x01, 0x02])
        // Wire: [0x40, 0x64, 0x02, 0x01, 0x02]
        XCTAssertEqual(tlvBytes, [0x40, 0x64, 0x02, 0x01, 0x02])

        var tlvParser = TLVProtocol()

        // Feed just the first byte of the 2-byte VLE type
        var feedFrames = FrameArray(frame: Frame(copyBuffer: [0x40]))
        if var result1 = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse with partial type VLE")
            result1.value.finalizeAllFramesAsFailed()
        }

        // Feed the rest of the message
        let remaining = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[1...])))
        feedFrames.add(frames: remaining)

        guard var parsed = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse after completing type VLE")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, 100)
        XCTAssertEqual(extractBytes(from: parsed.value), [0x01, 0x02])
        parsed.value.finalizeAllFramesAsFailed()
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testPartialFeedingSplitInLengthField() {
        // type=0x01, value=200 bytes (length needs 2-byte VLE: 0x40, 0xC8)
        let valueBytes = [UInt8](repeating: 0x42, count: 200)
        let tlvBytes = serializeTLVBytes(type: 0x01, value: valueBytes)
        // Wire: [0x01, 0x40, 0xC8, <200 bytes of 0x42>]
        XCTAssertEqual(tlvBytes.count, 203)
        XCTAssertEqual(tlvBytes[0], 0x01)  // type
        XCTAssertEqual(tlvBytes[1], 0x40)  // length high byte
        XCTAssertEqual(tlvBytes[2], 0xC8)  // length low byte

        var tlvParser = TLVProtocol()

        // Feed type + first byte of 2-byte VLE length
        var feedFrames = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[0..<2])))
        if var result1 = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse with partial length VLE")
            result1.value.finalizeAllFramesAsFailed()
        }

        // Feed the rest
        let remaining = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[2...])))
        feedFrames.add(frames: remaining)

        guard var parsed = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse after completing length VLE")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, 0x01)
        XCTAssertEqual(extractBytes(from: parsed.value), valueBytes)
        parsed.value.finalizeAllFramesAsFailed()
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testPartialFeedingSplitInValueField() {
        // type=0x01, value=[0x0A, 0x0B, 0x0C, 0x0D, 0x0E]
        let valueBytes: [UInt8] = [0x0A, 0x0B, 0x0C, 0x0D, 0x0E]
        let tlvBytes = serializeTLVBytes(type: 0x01, value: valueBytes)
        // Wire: [0x01, 0x05, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E]

        var tlvParser = TLVProtocol()

        // Feed type + length + partial value (2 of 5 bytes)
        var feedFrames = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[0..<4])))
        if var result1 = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse with partial value")
            result1.value.finalizeAllFramesAsFailed()
        }

        // Feed 2 more value bytes (still 1 short)
        let moreBytes = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[4..<6])))
        feedFrames.add(frames: moreBytes)
        if var result2 = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse with 4 of 5 value bytes")
            result2.value.finalizeAllFramesAsFailed()
        }

        // Feed the last value byte
        let lastByte = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[6..<7])))
        feedFrames.add(frames: lastByte)

        guard var parsed = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse after completing value")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, 0x01)
        XCTAssertEqual(extractBytes(from: parsed.value), valueBytes)
        parsed.value.finalizeAllFramesAsFailed()
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testPartialFeedingMultipleMessages() {
        // Serialize two TLVs and feed each in parts, verifying partial parsing across messages
        let tlv1Bytes = serializeTLVBytes(type: 0x01, value: [0xAA, 0xBB])
        // Wire: [0x01, 0x02, 0xAA, 0xBB]
        let tlv2Bytes = serializeTLVBytes(type: 0x02, value: [0xCC, 0xDD, 0xEE])
        // Wire: [0x02, 0x03, 0xCC, 0xDD, 0xEE]

        var tlvParser = TLVProtocol()
        var feedFrames = FrameArray()

        // Feed partial TLV 1: type + length + 1 of 2 value bytes
        let tlv1Part1 = FrameArray(frame: Frame(copyBuffer: Array(tlv1Bytes[0..<3])))
        feedFrames.add(frames: tlv1Part1)
        if var unexpected = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse TLV 1 with partial value")
            unexpected.value.finalizeAllFramesAsFailed()
        }

        // Feed remaining TLV 1: last value byte
        let tlv1Part2 = FrameArray(frame: Frame(copyBuffer: Array(tlv1Bytes[3...])))
        feedFrames.add(frames: tlv1Part2)

        // Should parse TLV 1
        guard var parsed1 = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse TLV 1")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed1.type, 0x01)
        XCTAssertEqual(extractBytes(from: parsed1.value), [0xAA, 0xBB])
        parsed1.value.finalizeAllFramesAsFailed()

        // Feed partial TLV 2: type + length only (no value bytes)
        let tlv2Part1 = FrameArray(frame: Frame(copyBuffer: Array(tlv2Bytes[0..<2])))
        feedFrames.add(frames: tlv2Part1)
        if var unexpected = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse TLV 2 with only type + length")
            unexpected.value.finalizeAllFramesAsFailed()
        }

        // Feed remaining TLV 2: all value bytes
        let tlv2Part2 = FrameArray(frame: Frame(copyBuffer: Array(tlv2Bytes[2...])))
        feedFrames.add(frames: tlv2Part2)

        guard var parsed2 = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse TLV 2")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed2.type, 0x02)
        XCTAssertEqual(extractBytes(from: parsed2.value), [0xCC, 0xDD, 0xEE])
        parsed2.value.finalizeAllFramesAsFailed()

        feedFrames.finalizeAllFramesAsFailed()
    }

    func testPartialFeedingEmptyThenNonEmpty() {
        // First TLV has empty value, second has data
        let tlv1Bytes = serializeTLVBytes(type: 0x0A, value: [])
        // Wire: [0x0A, 0x00]
        let tlv2Bytes = serializeTLVBytes(type: 0x0B, value: [0x01, 0x02, 0x03, 0x04, 0x05])
        // Wire: [0x0B, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05]
        let allBytes = tlv1Bytes + tlv2Bytes

        var tlvParser = TLVProtocol()

        // Feed just the type of TLV 1
        var feedFrames = FrameArray(frame: Frame(copyBuffer: [allBytes[0]]))
        if var result1 = tlvParser.parse(from: &feedFrames) {
            XCTFail("Should not parse with only type byte")
            result1.value.finalizeAllFramesAsFailed()
        }

        // Feed the length (0x00) of TLV 1 - this completes TLV 1 since value is empty
        let lengthByte = FrameArray(frame: Frame(copyBuffer: [allBytes[1]]))
        feedFrames.add(frames: lengthByte)

        guard var parsed1 = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse empty-value TLV")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed1.type, 0x0A)
        XCTAssertEqual(parsed1.length, 0)
        XCTAssertEqual(extractBytes(from: parsed1.value), [])
        parsed1.value.finalizeAllFramesAsFailed()

        // Feed TLV 2 all at once
        let tlv2Frame = FrameArray(frame: Frame(copyBuffer: Array(allBytes[2...])))
        feedFrames.add(frames: tlv2Frame)

        guard var parsed2 = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse second TLV")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed2.type, 0x0B)
        XCTAssertEqual(extractBytes(from: parsed2.value), [0x01, 0x02, 0x03, 0x04, 0x05])
        parsed2.value.finalizeAllFramesAsFailed()

        feedFrames.finalizeAllFramesAsFailed()
    }

    func testPartialFeedingLargeValueInSmallChunks() {
        // TLV with 50-byte value, fed in 10-byte chunks
        let valueBytes = (0..<50).map { UInt8($0 & 0xFF) }
        let tlvBytes = serializeTLVBytes(type: 0x03, value: valueBytes)
        // Wire: [0x03, 0x32, <50 bytes>] = 52 bytes total
        XCTAssertEqual(tlvBytes.count, 52)

        var tlvParser = TLVProtocol()
        var feedFrames = FrameArray()

        let chunkSize = 10
        var offset = 0
        var parseAttempts = 0

        // Feed all but the last chunk, verifying parse returns nil each time
        while offset + chunkSize < tlvBytes.count {
            let end = offset + chunkSize
            let chunk = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[offset..<end])))
            feedFrames.add(frames: chunk)
            offset = end
            parseAttempts += 1

            if var unexpectedResult = tlvParser.parse(from: &feedFrames) {
                XCTFail("Should not parse after \(offset) of \(tlvBytes.count) bytes")
                unexpectedResult.value.finalizeAllFramesAsFailed()
                feedFrames.finalizeAllFramesAsFailed()
                return
            }
        }

        // Feed the final chunk
        let lastChunk = FrameArray(frame: Frame(copyBuffer: Array(tlvBytes[offset...])))
        feedFrames.add(frames: lastChunk)
        parseAttempts += 1

        XCTAssertTrue(parseAttempts > 1, "Should have taken multiple parse attempts")

        guard var finalParsed = tlvParser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse large TLV")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(finalParsed.type, 0x03)
        XCTAssertEqual(extractBytes(from: finalParsed.value), valueBytes)
        finalParsed.value.finalizeAllFramesAsFailed()
        feedFrames.finalizeAllFramesAsFailed()
    }

    // MARK: - Complex Protocol State

    // More complex protocol
    // - VLE type (must be 1 or 2)
    // - For type 1:
    //      - VLE length of string
    //      - String value
    // - For type 2:
    //      - VLE count of strings
    //      - Pairs of VLE length of string followed by string
    struct StringArrayProtocol: ~Copyable {

        enum StringArrayType: UInt8 {
            case singleString = 1
            case multipleStrings = 2
        }

        // MARK: - Deserialize

        struct StringArrayState: ~Copyable, StreamDeserializerState {
            typealias StateMachineStepIdentifier = StringArrayStateMachineStep
            enum StringArrayStateMachineStep: Hashable {
                case readingType
                case readingCount
                case readingString
                case complete
            }

            var type: StringArrayType = .singleString
            var count = 0
            var strings = [String]()
        }

        // Define a shared parser definition for TLV messages
        static let parser = FrameArrayStreamDeserializer<StringArrayState>.parser { stream in
            // 1) Parse the type
            stream.beginState(.readingType)
            stream.parsePartialMessage { read, state throws(DeserializationError) in
                var type = 0
                try read.vle(&type)

                if type == 1 {
                    state.type = .singleString
                } else if type == 2 {
                    state.type = .multipleStrings
                } else {
                    throw DeserializationError.parsingFailed
                }
            }

            // 2) Parse the count of string, if necessary
            stream.beginState(.readingCount)
            stream.parsePartialMessage(if: { $0.type == .multipleStrings }) {
                read,
                state throws(DeserializationError) in
                try read.vle(&state.count)
            }
            stream.jumpToState(.complete, if: { $0.type == .multipleStrings && $0.count == 0 })

            // 3) Parse a single string at a time
            stream.beginState(.readingString)
            stream.parsePartialMessage { read, state throws(DeserializationError) in
                var stringLength = 0
                var string = ""
                try read.vle(&stringLength)
                try read.fixedLengthUTF8(&string, byteCount: stringLength)
                state.strings.append(string)
            }
            stream.jumpToState(.readingString, if: { $0.type == .multipleStrings && $0.strings.count < $0.count })

            stream.beginState(.complete)
            stream.finalizeMessage()
        }

        // Instantiate the parser
        var parser = StreamDeserializer(parser: StringArrayProtocol.parser)

        mutating func parse(from frames: inout FrameArray) -> StringArrayState? {
            try? parser.handleFrames(&frames)
        }

        // MARK: - Serialize

        static func write(_ string: String, into frames: inout FrameArray) {
            let message = Serializer.serialize(frameCapacity: 8) { write in
                write.vle(StringArrayType.singleString.rawValue)
                write.vle(string.count)
                write.fixedLengthUTF8(string, byteCount: string.count)
            }
            frames.add(frames: message)
        }

        static func write(_ strings: [String], into frames: inout FrameArray) {
            let message = Serializer.serialize(frameCapacity: 8) { write in
                write.vle(StringArrayType.multipleStrings.rawValue)
                write.vle(strings.count)
                for string in strings {
                    write.vle(string.count)
                    write.fixedLengthUTF8(string, byteCount: string.count)
                }
            }
            frames.add(frames: message)
        }
    }

    // MARK: - StringArrayProtocol Single String Tests

    func testStringArraySingleStringBasic() {
        var frames = FrameArray()
        StringArrayProtocol.write("hello", into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse single string")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .singleString)
        XCTAssertEqual(parsed.strings, ["hello"])
        frames.finalizeAllFramesAsFailed()
    }

    func testStringArraySingleStringEmpty() {
        var frames = FrameArray()
        StringArrayProtocol.write("", into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse empty single string")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .singleString)
        XCTAssertEqual(parsed.strings, [""])
        frames.finalizeAllFramesAsFailed()
    }

    func testStringArraySingleStringLong() {
        let longString = String(repeating: "abcdefghij", count: 20)  // 200 chars
        var frames = FrameArray()
        StringArrayProtocol.write(longString, into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse long single string")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .singleString)
        XCTAssertEqual(parsed.strings, [longString])
        frames.finalizeAllFramesAsFailed()
    }

    // MARK: - StringArrayProtocol String Array Tests

    func testStringArrayEmptyArray() {
        var frames = FrameArray()
        StringArrayProtocol.write([], into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse empty string array")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 0)
        XCTAssertEqual(parsed.strings, [])
        frames.finalizeAllFramesAsFailed()
    }

    func testStringArrayOneString() {
        var frames = FrameArray()
        StringArrayProtocol.write(["world"], into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse single-element string array")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.strings, ["world"])
        frames.finalizeAllFramesAsFailed()
    }

    func testStringArrayMultipleStrings() {
        let strings = ["alpha", "beta", "gamma", "delta"]
        var frames = FrameArray()
        StringArrayProtocol.write(strings, into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse multi-string array")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed.strings, strings)
        frames.finalizeAllFramesAsFailed()
    }

    func testStringArrayMultipleStringsIncludingEmpty() {
        let strings = ["first", "", "third", ""]
        var frames = FrameArray()
        StringArrayProtocol.write(strings, into: &frames)

        var parser = StringArrayProtocol()
        guard let parsed = parser.parse(from: &frames) else {
            XCTFail("Failed to parse string array with empties")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed.strings, strings)
        frames.finalizeAllFramesAsFailed()
    }

    // MARK: - StringArrayProtocol Multiple Messages At Once

    func testStringArrayMultipleMessagesAtOnce() {
        // Write several different message types into one frame array
        var frames = FrameArray()
        StringArrayProtocol.write("solo", into: &frames)
        StringArrayProtocol.write([], into: &frames)
        StringArrayProtocol.write(["one"], into: &frames)
        StringArrayProtocol.write(["x", "y", "z"], into: &frames)
        StringArrayProtocol.write("last", into: &frames)

        var parser = StringArrayProtocol()

        // Message 1: single string "solo"
        guard let parsed1 = parser.parse(from: &frames) else {
            XCTFail("Failed to parse message 1")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed1.type, .singleString)
        XCTAssertEqual(parsed1.strings, ["solo"])

        // Message 2: empty array
        guard let parsed2 = parser.parse(from: &frames) else {
            XCTFail("Failed to parse message 2")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed2.type, .multipleStrings)
        XCTAssertEqual(parsed2.count, 0)
        XCTAssertEqual(parsed2.strings, [])

        // Message 3: array of one string
        guard let parsed3 = parser.parse(from: &frames) else {
            XCTFail("Failed to parse message 3")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed3.type, .multipleStrings)
        XCTAssertEqual(parsed3.count, 1)
        XCTAssertEqual(parsed3.strings, ["one"])

        // Message 4: array of three strings
        guard let parsed4 = parser.parse(from: &frames) else {
            XCTFail("Failed to parse message 4")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed4.type, .multipleStrings)
        XCTAssertEqual(parsed4.count, 3)
        XCTAssertEqual(parsed4.strings, ["x", "y", "z"])

        // Message 5: single string "last"
        guard let parsed5 = parser.parse(from: &frames) else {
            XCTFail("Failed to parse message 5")
            frames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed5.type, .singleString)
        XCTAssertEqual(parsed5.strings, ["last"])

        // No more messages
        if var unexpected = parser.parse(from: &frames) {
            XCTFail("Should not have parsed any more messages")
            unexpected.strings.removeAll()
        }

        frames.finalizeAllFramesAsFailed()
    }

    // MARK: - StringArrayProtocol Partial Feeding

    func testStringArraySingleStringPartialOneByteAtATime() {
        // Single string "abc": type=1, VLE(3), "abc"
        // Wire: [0x01, 0x03, 0x61, 0x62, 0x63]
        var serialized = FrameArray()
        StringArrayProtocol.write("abc", into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        XCTAssertEqual(msgBytes, [0x01, 0x03, 0x61, 0x62, 0x63])

        var parser = StringArrayProtocol()
        var feedFrames = FrameArray()

        // Feed one byte at a time
        for i in 0..<msgBytes.count {
            let byteFrame = FrameArray(frame: Frame(copyBuffer: [msgBytes[i]]))
            feedFrames.add(frames: byteFrame)

            if i < msgBytes.count - 1 {
                if var unexpected = parser.parse(from: &feedFrames) {
                    XCTFail("Should not parse with only \(i + 1) of \(msgBytes.count) bytes")
                    unexpected.strings.removeAll()
                }
            }
        }

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse complete single string")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .singleString)
        XCTAssertEqual(parsed.strings, ["abc"])
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayEmptyArrayPartial() {
        // Empty array: type=2, VLE(0)
        // Wire: [0x02, 0x00]
        var serialized = FrameArray()
        StringArrayProtocol.write([], into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        XCTAssertEqual(msgBytes, [0x02, 0x00])

        var parser = StringArrayProtocol()

        // Feed just the type byte
        var feedFrames = FrameArray(frame: Frame(copyBuffer: [msgBytes[0]]))
        if var unexpected = parser.parse(from: &feedFrames) {
            XCTFail("Should not parse with only type byte")
            unexpected.strings.removeAll()
        }

        // Feed the count byte
        let countByte = FrameArray(frame: Frame(copyBuffer: [msgBytes[1]]))
        feedFrames.add(frames: countByte)

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse empty array")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 0)
        XCTAssertEqual(parsed.strings, [])
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayMultipleStringsPartialOneByteAtATime() {
        // Array of ["hi", "there"]:
        // Wire: type=2, count=2, VLE(2) "hi", VLE(5) "there"
        // [0x02, 0x02, 0x02, 0x68, 0x69, 0x05, 0x74, 0x68, 0x65, 0x72, 0x65]
        var serialized = FrameArray()
        StringArrayProtocol.write(["hi", "there"], into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        XCTAssertEqual(msgBytes, [0x02, 0x02, 0x02, 0x68, 0x69, 0x05, 0x74, 0x68, 0x65, 0x72, 0x65])

        var parser = StringArrayProtocol()
        var feedFrames = FrameArray()

        // Feed one byte at a time
        for i in 0..<msgBytes.count {
            let byteFrame = FrameArray(frame: Frame(copyBuffer: [msgBytes[i]]))
            feedFrames.add(frames: byteFrame)

            if i < msgBytes.count - 1 {
                if var unexpected = parser.parse(from: &feedFrames) {
                    XCTFail("Should not parse with only \(i + 1) of \(msgBytes.count) bytes")
                    unexpected.strings.removeAll()
                }
            }
        }

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse string array")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.strings, ["hi", "there"])
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayPartialSplitBetweenStrings() {
        // Array of ["AB", "CD"]:
        // Wire: [0x02, 0x02, 0x02, 0x41, 0x42, 0x02, 0x43, 0x44]
        var serialized = FrameArray()
        StringArrayProtocol.write(["AB", "CD"], into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        XCTAssertEqual(msgBytes, [0x02, 0x02, 0x02, 0x41, 0x42, 0x02, 0x43, 0x44])

        var parser = StringArrayProtocol()

        // Feed type + count + first string (5 bytes: type, count, len, 'A', 'B')
        var feedFrames = FrameArray(frame: Frame(copyBuffer: Array(msgBytes[0..<5])))
        if var unexpected = parser.parse(from: &feedFrames) {
            XCTFail("Should not parse with only first string")
            unexpected.strings.removeAll()
        }

        // Feed second string
        let rest = FrameArray(frame: Frame(copyBuffer: Array(msgBytes[5...])))
        feedFrames.add(frames: rest)

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse after feeding second string")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.strings, ["AB", "CD"])
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayPartialSplitWithinStringContent() {
        // Single string "hello":
        // Wire: [0x01, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f]
        var serialized = FrameArray()
        StringArrayProtocol.write("hello", into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        XCTAssertEqual(msgBytes, [0x01, 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f])

        var parser = StringArrayProtocol()

        // Feed type + length + partial string content ("hel" = 3 of 5 bytes)
        var feedFrames = FrameArray(frame: Frame(copyBuffer: Array(msgBytes[0..<5])))
        if var unexpected = parser.parse(from: &feedFrames) {
            XCTFail("Should not parse with partial string content")
            unexpected.strings.removeAll()
        }

        // Feed remaining string content ("lo")
        let rest = FrameArray(frame: Frame(copyBuffer: Array(msgBytes[5...])))
        feedFrames.add(frames: rest)

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse after completing string")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .singleString)
        XCTAssertEqual(parsed.strings, ["hello"])
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayPartialMultipleMessagesSequential() {
        // Feed a single-string message and a string-array message sequentially, each partially
        var msg1Serialized = FrameArray()
        StringArrayProtocol.write("one", into: &msg1Serialized)
        let msg1Bytes = extractBytes(from: msg1Serialized)
        msg1Serialized.finalizeAllFramesAsFailed()
        // Wire: [0x01, 0x03, 0x6f, 0x6e, 0x65]

        var msg2Serialized = FrameArray()
        StringArrayProtocol.write(["two", "three"], into: &msg2Serialized)
        let msg2Bytes = extractBytes(from: msg2Serialized)
        msg2Serialized.finalizeAllFramesAsFailed()
        // Wire: [0x02, 0x02, 0x03, 0x74, 0x77, 0x6f, 0x05, 0x74, 0x68, 0x72, 0x65, 0x65]

        var parser = StringArrayProtocol()
        var feedFrames = FrameArray()

        // Feed partial msg1: type + length only
        let msg1Part1 = FrameArray(frame: Frame(copyBuffer: Array(msg1Bytes[0..<2])))
        feedFrames.add(frames: msg1Part1)
        if var unexpected = parser.parse(from: &feedFrames) {
            XCTFail("Should not parse msg1 with only type + length")
            unexpected.strings.removeAll()
        }

        // Feed rest of msg1: string content
        let msg1Part2 = FrameArray(frame: Frame(copyBuffer: Array(msg1Bytes[2...])))
        feedFrames.add(frames: msg1Part2)

        guard let parsed1 = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse msg1")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed1.type, .singleString)
        XCTAssertEqual(parsed1.strings, ["one"])

        // Feed partial msg2: type + count + first string length only
        let msg2Part1 = FrameArray(frame: Frame(copyBuffer: Array(msg2Bytes[0..<3])))
        feedFrames.add(frames: msg2Part1)
        if var unexpected = parser.parse(from: &feedFrames) {
            XCTFail("Should not parse msg2 with only header")
            unexpected.strings.removeAll()
        }

        // Feed rest of msg2
        let msg2Part2 = FrameArray(frame: Frame(copyBuffer: Array(msg2Bytes[3...])))
        feedFrames.add(frames: msg2Part2)

        guard let parsed2 = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse msg2")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed2.type, .multipleStrings)
        XCTAssertEqual(parsed2.count, 2)
        XCTAssertEqual(parsed2.strings, ["two", "three"])

        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayPartialLargeStringInChunks() {
        // Single string of 100 characters, fed in 15-byte chunks
        let longString = String(repeating: "x", count: 100)
        var serialized = FrameArray()
        StringArrayProtocol.write(longString, into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        // Wire: [0x01, 0x40, 0x64, <100 bytes of 'x'>] = 103 bytes
        XCTAssertEqual(msgBytes.count, 103)

        var parser = StringArrayProtocol()
        var feedFrames = FrameArray()

        let chunkSize = 15
        var offset = 0

        // Feed all but the last chunk
        while offset + chunkSize < msgBytes.count {
            let end = offset + chunkSize
            let chunk = FrameArray(frame: Frame(copyBuffer: Array(msgBytes[offset..<end])))
            feedFrames.add(frames: chunk)
            offset = end

            if var unexpected = parser.parse(from: &feedFrames) {
                XCTFail("Should not parse after \(offset) of \(msgBytes.count) bytes")
                unexpected.strings.removeAll()
                feedFrames.finalizeAllFramesAsFailed()
                return
            }
        }

        // Feed the final chunk
        let lastChunk = FrameArray(frame: Frame(copyBuffer: Array(msgBytes[offset...])))
        feedFrames.add(frames: lastChunk)

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse large string")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .singleString)
        XCTAssertEqual(parsed.strings, [longString])
        feedFrames.finalizeAllFramesAsFailed()
    }

    func testStringArrayPartialManyStringsOneByteAtATime() {
        // Array of ["a", "bb", "ccc"]:
        // Wire: [0x02, 0x03, 0x01, 0x61, 0x02, 0x62, 0x62, 0x03, 0x63, 0x63, 0x63]
        let strings = ["a", "bb", "ccc"]
        var serialized = FrameArray()
        StringArrayProtocol.write(strings, into: &serialized)
        let msgBytes = extractBytes(from: serialized)
        serialized.finalizeAllFramesAsFailed()
        XCTAssertEqual(msgBytes, [0x02, 0x03, 0x01, 0x61, 0x02, 0x62, 0x62, 0x03, 0x63, 0x63, 0x63])

        var parser = StringArrayProtocol()
        var feedFrames = FrameArray()

        for i in 0..<msgBytes.count {
            let byteFrame = FrameArray(frame: Frame(copyBuffer: [msgBytes[i]]))
            feedFrames.add(frames: byteFrame)

            if i < msgBytes.count - 1 {
                if var unexpected = parser.parse(from: &feedFrames) {
                    XCTFail("Should not parse with only \(i + 1) of \(msgBytes.count) bytes")
                    unexpected.strings.removeAll()
                }
            }
        }

        guard let parsed = parser.parse(from: &feedFrames) else {
            XCTFail("Failed to parse string array")
            feedFrames.finalizeAllFramesAsFailed()
            return
        }
        XCTAssertEqual(parsed.type, .multipleStrings)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.strings, strings)
        feedFrames.finalizeAllFramesAsFailed()
    }
}
