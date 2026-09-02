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
final class SwiftNetworkSerializerTests: NetTestCase {

    let arrayCount = 10

    struct TestStruct {
        var oneByte: UInt8 = 0
        var twoBytes: UInt16 = 0
        var twoBytesSigned: Int16 = 0
        var fourBytes: UInt32 = 0
        var eightBytes: UInt64 = 0
        var uuidBytes: SystemUUID = SystemUUID.empty
        var string: String = ""
    }

    func testSerializeUInt8() {
        var toWrite = TestStruct()
        toWrite.oneByte = 42

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uint8(toWrite.oneByte)
        }

        XCTAssertEqual(buffer.count, 1, "Invalid buffer length")
        XCTAssertEqual(buffer[0], toWrite.oneByte, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(expect: toWrite.oneByte)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Validate incorrect
        let validateResult2 = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(expect: 13)
        }
        XCTAssertEqual(validateResult2, .error(.validationFailed), "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt8 = 0
        let readResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&toRead)
        }

        XCTAssertEqual(readResult.remainingBytes, 0, "Invalid result \(readResult)")
        XCTAssertEqual(toRead, toWrite.oneByte, "Failed to deserialize")
    }

    func testSerializeInPlaceUInt8() {
        var toWrite = TestStruct()
        toWrite.oneByte = 42

        let mallocedBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1)

        // Serialize
        let writeResult = Serializer.serialize(mallocedBuffer.mutableSpan) { write throws(SerializationError) in
            try write.uint8(toWrite.oneByte)
        }
        XCTAssertEqual(writeResult.remainingBytes, 0, "Invalid write result \(writeResult)")
        XCTAssertEqual(mallocedBuffer[0], toWrite.oneByte, "Invalid buffer value")

        let readBuffer = UnsafeRawBufferPointer(mallocedBuffer)

        // Validate
        let validateResult = Deserializer.deserialize(readBuffer.bytes) { read throws(DeserializationError) in
            try read.uint8(expect: toWrite.oneByte)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt8 = 0
        let readResult = Deserializer.deserialize(readBuffer.bytes) { read throws(DeserializationError) in
            try read.uint8(&toRead)
        }

        XCTAssertEqual(readResult.remainingBytes, 0, "Invalid read result \(readResult)")
        XCTAssertEqual(toRead, toWrite.oneByte, "Failed to deserialize")

        mallocedBuffer.deallocate()
    }

    func testSerializeUInt8Array() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint8(UInt8(i))
            }
        }

        XCTAssertEqual(buffer.count, arrayCount, "Invalid buffer length")

        let length = Serializer.length { write in
            for i in 0..<arrayCount {
                write.uint8(UInt8(i))
            }
        }
        XCTAssertEqual(length, arrayCount, "Invalid buffer length")

        for i in 0..<arrayCount {
            XCTAssertEqual(buffer[i], UInt8(i), "Invalid buffer value")
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint8(expect: UInt8(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt8](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint8(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt8(i), "Invalid buffer value")
        }
    }

    func testSerializeMixedUInt8Array() {
        // Serialize
        let testUInt64Value: UInt64 = 0x1111_2222_3333_4444
        let buffer = Serializer.serialize { write in
            write.uint64(testUInt64Value)
            for i in 0..<arrayCount {
                write.uint8(UInt8(i))
                write.uint8(UInt8(i))
            }
        }

        XCTAssertEqual(buffer.count, (arrayCount * 2) + MemoryLayout<UInt64>.size, "Invalid buffer length")

        let length = Serializer.length { write in
            write.uint64(testUInt64Value)
            for i in 0..<arrayCount {
                write.uint8(UInt8(i))
                write.uint8(UInt8(i))
            }
        }
        XCTAssertEqual(length, (arrayCount * 2) + MemoryLayout<UInt64>.size, "Invalid buffer length")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint64(expect: testUInt64Value)
            for i in 0..<arrayCount {
                try read.uint8(expect: UInt8(i))
                try read.uint8(expect: UInt8(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt8](repeating: 0, count: arrayCount)
        var uint64Value: UInt64 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint64(&uint64Value)
            for i in 0..<arrayCount {
                try read.uint8(&toRead[i])
                try read.uint8(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(uint64Value, testUInt64Value, "Invalid buffer value")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt8(i), "Invalid buffer value")
        }
    }

    func testSerializeUInt16() {
        var toWrite = TestStruct()
        toWrite.twoBytes = 1042

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uint16(toWrite.twoBytes)
        }

        XCTAssertEqual(buffer.count, 2, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0x12, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0x04, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint16(expect: toWrite.twoBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt16 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint16(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.twoBytes, "Failed to deserialize")
    }

    func testSerializeInt16NegativeValue() {
        var toWrite = TestStruct()
        toWrite.twoBytesSigned = -1

        // Serialize
        let buffer = Serializer.serialize { write in
            write.int16(toWrite.twoBytesSigned)
        }

        XCTAssertEqual(buffer.count, 2, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0xff, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0xff, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.int16(expect: toWrite.twoBytesSigned)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: Int16 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.int16(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.twoBytesSigned, "Failed to deserialize")
    }

    func testSerializeInt16PositiveValue() {
        var toWrite = TestStruct()
        toWrite.twoBytesSigned = 0x2a2a

        // Serialize
        let buffer = Serializer.serialize { write in
            write.int16(toWrite.twoBytesSigned)
        }

        XCTAssertEqual(buffer.count, 2, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 42, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 42, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.int16(expect: toWrite.twoBytesSigned)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: Int16 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.int16(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.twoBytesSigned, "Failed to deserialize")
    }

    func testSerializeUInt16Array() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint16(UInt16(i))
            }
        }

        let byteCount = UInt16.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(buffer[i * byteCount], UInt8(i), "Invalid buffer value")
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint16(expect: UInt16(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt16](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint16(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt16(i), "Invalid buffer value")
        }
    }

    func testSerializeUInt16NBO() {
        // Serialize
        var toWrite = TestStruct()
        toWrite.twoBytes = 1042

        let buffer = Serializer.serialize { write in
            write.uint16NetworkByteOrder(toWrite.twoBytes)
        }

        XCTAssertEqual(buffer.count, 2, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0x04, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0x12, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint16NetworkByteOrder(expect: toWrite.twoBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt16 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint16NetworkByteOrder(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.twoBytes, "Failed to deserialize")
    }

    func testSerializeUInt16NBOArray() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint16NetworkByteOrder(UInt16(i))
            }
        }

        let byteCount = UInt16.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(
                buffer[(i * byteCount) + (byteCount - 1)],
                UInt8(i),
                "Invalid buffer value"
            )
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint16NetworkByteOrder(expect: UInt16(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt16](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint16NetworkByteOrder(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt16(i), "Invalid buffer value")
        }
    }

    func testSerializeUInt32() {
        var toWrite = TestStruct()
        toWrite.fourBytes = 101042

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uint32(toWrite.fourBytes)
        }

        XCTAssertEqual(buffer.count, 4, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0xb2, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0x8a, "Invalid buffer value")
        XCTAssertEqual(buffer[2], 0x01, "Invalid buffer value")
        XCTAssertEqual(buffer[3], 0x00, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint32(expect: toWrite.fourBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt32 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint32(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.fourBytes, "Failed to deserialize")
    }

    func testSerializeUInt32Array() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint32(UInt32(i))
            }
        }

        let byteCount = UInt32.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(buffer[i * byteCount], UInt8(i), "Invalid buffer value")
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint32(expect: UInt32(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt32](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint32(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt32(i), "Invalid buffer value")
        }
    }

    func testSerializeUInt32NBO() {
        var toWrite = TestStruct()
        toWrite.fourBytes = 101042

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uint32NetworkByteOrder(toWrite.fourBytes)
        }

        XCTAssertEqual(buffer.count, 4, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0x01, "Invalid buffer value")
        XCTAssertEqual(buffer[2], 0x8a, "Invalid buffer value")
        XCTAssertEqual(buffer[3], 0xb2, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(expect: toWrite.fourBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt32 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.fourBytes, "Failed to deserialize")
    }

    func testSerializeUInt32NBOArray() {
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint32NetworkByteOrder(UInt32(i))
            }
        }

        let byteCount = UInt32.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(
                buffer[i * byteCount + (byteCount - 1)],
                UInt8(i),
                "Invalid buffer value"
            )
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint32NetworkByteOrder(expect: UInt32(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt32](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint32NetworkByteOrder(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt32(i), "Invalid buffer value")
        }
    }

    func testSerializeUInt64() {
        var toWrite = TestStruct()
        toWrite.eightBytes = 101_010_101_042

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uint64(toWrite.eightBytes)
        }

        XCTAssertEqual(buffer.count, 8, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0x32, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0xd3, "Invalid buffer value")
        XCTAssertEqual(buffer[2], 0xab, "Invalid buffer value")
        XCTAssertEqual(buffer[3], 0x84, "Invalid buffer value")
        XCTAssertEqual(buffer[4], 0x17, "Invalid buffer value")
        XCTAssertEqual(buffer[5], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[6], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[7], 0x00, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint64(expect: toWrite.eightBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint64(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.eightBytes, "Failed to deserialize")
    }

    func testSerializeUInt64Array() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint64(UInt64(i))
            }
        }

        let byteCount = UInt64.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(buffer[i * byteCount], UInt8(i), "Invalid buffer value")
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint64(expect: UInt64(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt64](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint64(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt64(i), "Invalid buffer value")
        }
    }

    func testSerializeUInt64NBO() {
        var toWrite = TestStruct()
        toWrite.eightBytes = 101_010_101_042

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uint64NetworkByteOrder(toWrite.eightBytes)
        }

        XCTAssertEqual(buffer.count, 8, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[2], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[3], 0x17, "Invalid buffer value")
        XCTAssertEqual(buffer[4], 0x84, "Invalid buffer value")
        XCTAssertEqual(buffer[5], 0xab, "Invalid buffer value")
        XCTAssertEqual(buffer[6], 0xd3, "Invalid buffer value")
        XCTAssertEqual(buffer[7], 0x32, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint64NetworkByteOrder(expect: toWrite.eightBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt64 = 0
        let readResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint64NetworkByteOrder(&toRead)
        }
        XCTAssertEqual(readResult.remainingBytes, 0, "Invalid result \(readResult)")
        XCTAssertEqual(toRead, toWrite.eightBytes, "Failed to deserialize")
    }

    func testSerializeUInt64NBOArray() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uint64NetworkByteOrder(UInt64(i))
            }
        }

        let byteCount = UInt64.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(
                buffer[(i * byteCount) + (byteCount - 1)],
                UInt8(i),
                "Invalid buffer value"
            )
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint64NetworkByteOrder(expect: UInt64(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt64](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint64NetworkByteOrder(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt64(i), "Invalid buffer value")
        }
    }

    #if !NETWORK_NO_SWIFT_QUIC
    func testSerializeConnectionIDs() {
        let scid = QUICConnectionID(8)
        let dcid = QUICConnectionID(12)

        let buffer = Serializer.serialize { write in
            write.connectionID(scid)
            write.connectionID(dcid)
        }

        XCTAssertEqual(buffer.count, 22, "Invalid buffer length")

        var scidLength: UInt8 = 0
        var scidBuffer: [UInt8] = []
        var dcidLength: UInt8 = 0
        var dcidBuffer: [UInt8] = []

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&scidLength)
            try read.buffer(&scidBuffer, length: Int(scidLength))
            try read.uint8(&dcidLength)
            try read.buffer(&dcidBuffer, length: Int(dcidLength))
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(UInt8(scid.length), scidLength, "Invalid SCID length")
        XCTAssertEqual(UInt8(dcid.length), dcidLength, "Invalid DCID length")
        XCTAssertEqual(scid.connectionID, scidBuffer, "Invalid SCID buffer")
        XCTAssertEqual(dcid.connectionID, dcidBuffer, "Invalid SCID buffer")
    }

    func testSerializeFrameConnectionIDs() {
        let scid = QUICConnectionID(8)
        let dcid = QUICConnectionID(12)

        var frame = Frame(count: 22)
        defer {
            frame.finalize(success: true)
        }
        XCTAssertEqual(22, frame.unclaimedLength, "Frame length incorrect")

        let writeResult = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.connectionID(scid)
            try write.connectionID(dcid)
        }

        XCTAssertEqual(writeResult.remainingBytes, 0, "Invalid result \(writeResult)")
        XCTAssertEqual(22, frame.unclaimedLength, "Frame length incorrect")

        var scidLength: UInt8 = 0
        var scidBuffer: [UInt8] = []
        var dcidLength: UInt8 = 0
        var dcidBuffer: [UInt8] = []

        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.uint8(&scidLength)
            try read.buffer(&scidBuffer, length: Int(scidLength))
            try read.uint8(&dcidLength)
            try read.buffer(&dcidBuffer, length: Int(dcidLength))
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(UInt8(scid.length), scidLength, "Invalid SCID length")
        XCTAssertEqual(UInt8(dcid.length), dcidLength, "Invalid DCID length")
        XCTAssertEqual(scid.connectionID, scidBuffer, "Invalid SCID buffer")
        XCTAssertEqual(dcid.connectionID, dcidBuffer, "Invalid SCID buffer")
    }

    func testSerializeEncodedPacketNumber() {
        let vectors: [(EncodedPacketNumber, [UInt8])] = [
            (.init(number: 1, size: .oneByte), [1]),
            (.init(number: 2, size: .twoBytes), [0, 2]),
            (.init(number: 3, size: .threeBytes), [0, 0, 3]),
            (.init(number: 4, size: .fourBytes), [0, 0, 0, 4]),
        ]

        for vector in vectors {
            let frameLength = vector.1.count
            var frame = Frame(count: frameLength)
            XCTAssertEqual(frameLength, frame.unclaimedLength, "Frame length incorrect")

            var result = [UInt8](repeating: 0xff, count: vector.1.count)
            let writeResult = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.encodedPacketNumber(vector.0)
            }
            XCTAssertEqual(writeResult.remainingBytes, 0, "Failed to serialize")
            let deserializeResult = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
                for i in 0..<vector.1.count {
                    try read.uint8(&result[i])
                }
            }
            XCTAssertEqual(deserializeResult.remainingBytes, 0, "Failed to deserialize")
            XCTAssertEqual(vector.1, result)
            frame.finalize(success: true)
        }

    }
    #endif

    func testSerializeVLEShort() {
        var toWrite = TestStruct()
        toWrite.eightBytes = 42

        // Serialize
        let buffer = Serializer.serialize { write in
            write.vle(toWrite.eightBytes)
        }

        XCTAssertEqual(buffer.count, 1, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0x2a, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vle(expect: toWrite.eightBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.eightBytes, "Failed to deserialize")
    }

    func testSerializeVLEShortArray() {
        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.vle(UInt64(i))
            }
        }

        XCTAssertEqual(buffer.count, arrayCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(buffer[i], UInt8(i), "Invalid buffer value")
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.vle(expect: UInt64(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt64](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.vle(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], UInt64(i), "Invalid buffer value")
        }
    }

    func testSerializeVLELong() {
        var toWrite = TestStruct()
        toWrite.eightBytes = 101_010_101_042

        // Serialize
        let buffer = Serializer.serialize { write in
            write.vle(toWrite.eightBytes)
        }

        XCTAssertEqual(buffer.count, 8, "Invalid buffer length")
        XCTAssertEqual(buffer[0], 0xc0, "Invalid buffer value")
        XCTAssertEqual(buffer[1], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[2], 0x00, "Invalid buffer value")
        XCTAssertEqual(buffer[3], 0x17, "Invalid buffer value")
        XCTAssertEqual(buffer[4], 0x84, "Invalid buffer value")
        XCTAssertEqual(buffer[5], 0xab, "Invalid buffer value")
        XCTAssertEqual(buffer[6], 0xd3, "Invalid buffer value")
        XCTAssertEqual(buffer[7], 0x32, "Invalid buffer value")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vle(expect: toWrite.eightBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead: UInt64 = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vle(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.eightBytes, "Failed to deserialize")
    }

    func testSerializeVLELongArray() {
        let initial: UInt64 = 100_000_000_000

        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.vle(initial + UInt64(i))
            }
        }

        let byteCount = UInt64.bitWidth / UInt8.bitWidth
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")
        for i in 0..<arrayCount {
            XCTAssertEqual(
                buffer[i * byteCount + (byteCount - 1)],
                UInt8(i),
                "Invalid buffer value"
            )
        }

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.vle(expect: initial + UInt64(i))
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [UInt64](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.vle(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], initial + UInt64(i), "Invalid buffer value")
        }
    }

    func testDeserializeVLEWithSizeOverflowsTargetType() {
        // 300 requires the 2-byte VLE encoding but doesn't fit in UInt8.
        let buffer = Serializer.serialize { write in
            write.vle(UInt64(300))
        }
        var value: UInt8 = 0
        var size = 0
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vleWithSize(&value, &size)
        }
        XCTAssertEqual(result, .error(.parsingFailed), "Should fail with parsingFailed instead of trapping")
    }

    func testSerializeUUID() {
        var toWrite = TestStruct()
        toWrite.uuidBytes = SystemUUID()

        // Serialize
        let buffer = Serializer.serialize { write in
            write.uuid(toWrite.uuidBytes)
        }

        XCTAssertEqual(buffer.count, 16, "Invalid buffer length")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uuid(expect: toWrite.uuidBytes)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = SystemUUID.empty
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uuid(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite.uuidBytes, "Failed to deserialize")
    }

    func testSerializeUUIDArray() {
        var uuidBytes = [SystemUUID]()
        for _ in 0..<arrayCount {
            uuidBytes.append(SystemUUID())
        }

        // Serialize
        let buffer = Serializer.serialize { write in
            for i in 0..<arrayCount {
                write.uuid(uuidBytes[i])
            }
        }

        let byteCount = 16
        XCTAssertEqual(buffer.count, arrayCount * byteCount, "Invalid buffer length")

        // Validate
        let validateResult = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uuid(expect: uuidBytes[i])
            }
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")

        // Deserialize
        var toRead = [SystemUUID](repeating: SystemUUID(), count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uuid(&toRead[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], uuidBytes[i], "Invalid buffer value")
        }
    }

    func testSerializeFixedString() {
        let toWrite = "hello world"

        let buffer = Serializer.serialize { write in
            write.fixedLengthUTF8(toWrite, byteCount: 12)
        }

        XCTAssertEqual(buffer.count, 12, "Invalid buffer length")

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 12)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite, "Failed to deserialize")
    }

    func testSerializeFixedStringArray() {
        let toWrite = "hello world"
        let buffer = Serializer.serialize { write in
            for _ in 0..<arrayCount {
                write.fixedLengthUTF8(toWrite, byteCount: 12)
            }
        }

        XCTAssertEqual(buffer.count, arrayCount * 12, "Invalid buffer length")

        var toRead = [String](repeating: String(), count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.fixedLengthUTF8(&toRead[i], byteCount: 12)
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], toWrite, "Invalid buffer value")
        }
    }

    func testSerializeFixedStringTruncate() {
        let toWrite = "hello world"

        let buffer = Serializer.serialize { write in
            write.fixedLengthUTF8(toWrite, byteCount: 8)
        }

        XCTAssertEqual(buffer.count, 8, "Invalid buffer length")

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 8)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, "hello wo", "Failed to deserialize")
    }

    func testSerializeFixedStringExtraSpace() {
        let toWrite = "hello world"

        let buffer = Serializer.serialize { write in
            write.fixedLengthUTF8(toWrite, byteCount: 32)
        }

        XCTAssertEqual(buffer.count, 32, "Invalid buffer length")

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 32)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, "hello world", "Failed to deserialize")
    }

    func testSerializeFixedEmptyString() {
        let buffer: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer.span) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 32)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, "", "Failed to deserialize")
    }

    func testSerializeStringWithInteriorNullBytes() {
        let buffer: [UInt8] = [
            0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x00,
            0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x00,
            0x68, 0x65, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72,
        ]

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer.span) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 32)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, "hello world", "Failed to deserialize")
    }

    func testDeserializeInvalidFixedString() {
        let buffer = Serializer.serialize { write in
            UInt8(0xf9)
            UInt8(0xf6)
            UInt8(0xf9)
            UInt8(0xf6)
        }

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 4)
        }

        XCTAssertEqual(result, .error(.parsingFailed), "Invalid result \(result)")
        XCTAssertEqual(toRead, "", "String was updated")
    }

    func testDeserializeMultiByteFixedString() {
        let buffer: [UInt8] = [0x48, 0x65, 0x6c, 0x61, 0x6e, 0x20, 0x67, 0xc3, 0xa5, 0x72, 0x21]

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 11)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, "Helan går!", "String was not parsed")
    }

    func testDeserializeTruncatedMultiByteFixedString() {
        let buffer: [UInt8] = [0x48, 0x65, 0x6c, 0x61, 0x6e, 0x20, 0x67, 0xc3, 0xa5, 0x72, 0x21]

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&toRead, byteCount: 8)
        }

        XCTAssertEqual(result, .error(.parsingFailed), "Invalid result \(result)")
        XCTAssertEqual(toRead, "", "String was updated")
    }

    func testSerializeLengthPrefixedString() {
        let string = "hello world"
        let length = string.count

        let buffer = Serializer.serialize { write in
            write.vle(length)
            write.fixedLengthUTF8(string, byteCount: length)
        }

        XCTAssertEqual(buffer.count, 12, "Invalid buffer length")

        var readLength: Int = 0
        var readString: String = ""

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.vle(&readLength)
            try read.fixedLengthUTF8(&readString, byteCount: readLength)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(string, readString, "Failed to deserialize")
    }

    func testSerializeLengthPrefixedStringArray() {
        let toWrite = "hello world"
        let length = toWrite.count

        let buffer = Serializer.serialize { write in
            for _ in 0..<arrayCount {
                write.vle(length)
                write.fixedLengthUTF8(toWrite, byteCount: length)
            }
        }

        XCTAssertEqual(buffer.count, arrayCount * 12, "Invalid buffer length")

        var readLength = [Int](repeating: Int(), count: arrayCount)
        var toRead = [String](repeating: String(), count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.vle(&readLength[i])
                try read.fixedLengthUTF8(&toRead[i], byteCount: readLength[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], toWrite, "Invalid buffer value")
        }
    }

    func testSerializeAutoString() {
        let toWrite = "hello world"

        let buffer = Serializer.serialize { write in
            write.string(toWrite)
        }

        var toRead: String = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.string(&toRead)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead, toWrite, "Failed to deserialize")
    }

    func testSerializeAutoStringArray() {
        let toWrite = "hello world"
        let buffer = Serializer.serialize { write in
            for _ in 0..<arrayCount {
                write.string(toWrite)
            }
        }

        var toRead = [String]()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for _ in 0..<arrayCount {
                try read.string(appendTo: &toRead)
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(toRead[i], toWrite, "Invalid buffer value")
        }
    }

    func testSerializeLengthPrefixedBuffer() {
        let toWrite: [UInt8] = [1, 2, 3, 4]
        let length = toWrite.count
        let sentinel: UInt8 = 42

        let buffer = Serializer.serialize { write in
            write.uint8(UInt8(length))
            write.buffer(toWrite)
            write.uint8(sentinel)
        }

        XCTAssertEqual(buffer.count, 6, "Invalid buffer length")

        var readLength: UInt8 = 0
        var readSentinel: UInt8 = 0
        var toRead = [UInt8]()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&readLength)
            try read.buffer(&toRead, length: Int(readLength))
            try read.uint8(&readSentinel)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(readLength, 4, "Failed to deserialize")
        XCTAssertEqual(toRead, toWrite, "Failed to deserialize")
        XCTAssertEqual(readSentinel, sentinel, "Failed to deserialize")
    }

    func testSerializeLengthPrefixedBufferArray() {
        let toWrite: [UInt8] = [1, 2, 3, 4]
        let length = toWrite.count
        let sentinel: UInt8 = 42

        let buffer = Serializer.serialize { write in
            for _ in 0..<arrayCount {
                write.uint8(UInt8(length))
                write.buffer(toWrite)
                write.uint8(sentinel)
            }
        }

        XCTAssertEqual(buffer.count, arrayCount * 6, "Invalid buffer length")

        var readLength = [UInt8](repeating: 0, count: arrayCount)
        var toRead = [[UInt8]](repeating: [UInt8](), count: arrayCount)
        var readSentinel = [UInt8](repeating: 0, count: arrayCount)
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            for i in 0..<arrayCount {
                try read.uint8(&readLength[i])
                try read.buffer(&toRead[i], length: Int(readLength[i]))
                try read.uint8(&readSentinel[i])
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        for i in 0..<arrayCount {
            XCTAssertEqual(readLength[i], 4, "Failed to deserialize")
            XCTAssertEqual(toRead[i], toWrite, "Failed to deserialize")
            XCTAssertEqual(readSentinel[i], sentinel, "Failed to deserialize")
        }
    }

    func testSerializeStruct() {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.eightBytes = 100024
        toWrite.uuidBytes = SystemUUID()
        toWrite.string = "hello world"

        let length = Serializer.length { write in
            write.uint8(toWrite.oneByte)
            write.vle(toWrite.eightBytes)
            write.uint16NetworkByteOrder(toWrite.twoBytes)
            write.uuid(toWrite.uuidBytes)
            write.fixedLengthUTF8(toWrite.string, byteCount: 20)
        }
        XCTAssertEqual(length, 43, "Invalid counter length")

        let buffer = Serializer.serialize { write in
            write.uint8(toWrite.oneByte)
            write.vle(toWrite.eightBytes)
            write.uint16NetworkByteOrder(toWrite.twoBytes)
            write.uuid(toWrite.uuidBytes)
            write.fixedLengthUTF8(toWrite.string, byteCount: 20)
        }

        XCTAssertEqual(buffer.count, 43, "Invalid buffer length")

        var toRead = TestStruct()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&toRead.oneByte)
            try read.vle(&toRead.eightBytes)
            try read.uint16NetworkByteOrder(&toRead.twoBytes)
            try read.uuid(&toRead.uuidBytes)
            try read.fixedLengthUTF8(&toRead.string, byteCount: 20)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead.oneByte, toWrite.oneByte, "Failed to deserialize uint8")
        XCTAssertEqual(toRead.twoBytes, toWrite.twoBytes, "Failed to deserialize uint16nbo")
        XCTAssertEqual(toRead.eightBytes, toWrite.eightBytes, "Failed to deserialize vle")
        XCTAssertEqual(toRead.uuidBytes, toWrite.uuidBytes, "Failed to deserialize uuid")
        XCTAssertEqual(toRead.string, toWrite.string, "Failed to deserialize string")
    }

    func runTestSerializeOptional(flag: Bool) {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.fourBytes = 10024
        toWrite.eightBytes = 100024
        toWrite.string = "hello world"
        let toWriteBuffer: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

        let buffer = Serializer.serialize { write in
            if flag {
                write.uint8(toWrite.oneByte)
                write.uint16(toWrite.twoBytes)
                write.uint32(toWrite.fourBytes)
                write.uint64(toWrite.eightBytes)
                write.fixedLengthUTF8(toWrite.string, byteCount: 20)
            } else {
                write.vle(toWrite.oneByte)
                write.uint16NetworkByteOrder(toWrite.twoBytes)
                write.uint32NetworkByteOrder(toWrite.fourBytes)
                write.uint64NetworkByteOrder(toWrite.eightBytes)
                write.buffer(toWriteBuffer)
            }
        }
        if flag {
            XCTAssertEqual(buffer.count, 35, "Invalid buffer length")
        } else {
            XCTAssertEqual(buffer.count, 25, "Invalid buffer length")
        }

        var toRead = TestStruct()
        var toReadBuffer = [UInt8]()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            if flag {
                try read.uint8(&toRead.oneByte)
                try read.uint16(&toRead.twoBytes)
                try read.uint32(&toRead.fourBytes)
                try read.uint64(&toRead.eightBytes)
                try read.fixedLengthUTF8(&toRead.string, byteCount: 20)
            } else {
                try read.vle(&toRead.oneByte)
                try read.uint16NetworkByteOrder(&toRead.twoBytes)
                try read.uint32NetworkByteOrder(&toRead.fourBytes)
                try read.uint64NetworkByteOrder(&toRead.eightBytes)
                try read.buffer(&toReadBuffer, length: 10)
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead.oneByte, toWrite.oneByte, "Failed to deserialize uint8")
        XCTAssertEqual(toRead.twoBytes, toWrite.twoBytes, "Failed to deserialize uint16")
        XCTAssertEqual(toRead.fourBytes, toWrite.fourBytes, "Failed to deserialize uint32")
        XCTAssertEqual(toRead.eightBytes, toWrite.eightBytes, "Failed to deserialize uint64")

        if flag {
            XCTAssertEqual(toRead.string, toWrite.string, "Failed to deserialize string")
        } else {
            XCTAssertEqual(toReadBuffer, toWriteBuffer, "Failed to deserialize string")
        }
    }

    func testSerializeOptionalTrue() {
        runTestSerializeOptional(flag: true)
    }

    func testSerializeOptionalFalse() {
        runTestSerializeOptional(flag: false)
    }

    func testSerializeStructConditional() {
        var toWrite = TestStruct()
        toWrite.oneByte = 2
        toWrite.twoBytes = 1024
        toWrite.eightBytes = 100024
        toWrite.uuidBytes = SystemUUID()

        let buffer = Serializer.serialize { write in
            write.uint8(toWrite.oneByte)
            write.uuid(toWrite.uuidBytes)
            write.vle(toWrite.eightBytes)
            write.uint16NetworkByteOrder(toWrite.twoBytes)
        }

        XCTAssertEqual(buffer.count, 23, "Invalid buffer length")

        var toRead = TestStruct()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&toRead.oneByte)
            if toRead.oneByte == 1 {
                try read.vle(&toRead.eightBytes)
                try read.uint16NetworkByteOrder(&toRead.twoBytes)
                try read.uuid(&toRead.uuidBytes)
            } else {
                try read.uuid(&toRead.uuidBytes)
                try read.vle(&toRead.eightBytes)
                try read.uint16NetworkByteOrder(&toRead.twoBytes)
            }
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead.oneByte, toWrite.oneByte, "Failed to deserialize uint8")
        XCTAssertEqual(toRead.twoBytes, toWrite.twoBytes, "Failed to deserialize uint16nbo")
        XCTAssertEqual(toRead.eightBytes, toWrite.eightBytes, "Failed to deserialize vle")
        XCTAssertEqual(toRead.uuidBytes, toWrite.uuidBytes, "Failed to deserialize uuid")
    }

    func testSerializeTooShort() {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.eightBytes = 100024
        toWrite.uuidBytes = SystemUUID()

        let buffer = Serializer.serialize { write in
            write.uint8(toWrite.oneByte)
        }

        var toRead = TestStruct()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&toRead.oneByte)
            try read.uint16NetworkByteOrder(&toRead.twoBytes)
            try read.uuid(&toRead.uuidBytes)
            try read.vle(&toRead.eightBytes)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Invalid result \(result)")
    }

    func testSerializeValidationFailed() {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.eightBytes = 100024
        toWrite.uuidBytes = SystemUUID()

        let buffer = Serializer.serialize { write in
            write.uint8(toWrite.oneByte)
            write.uint16NetworkByteOrder(toWrite.twoBytes)
            write.uuid(toWrite.uuidBytes)
            write.vle(toWrite.eightBytes)
        }

        // Bad value at front
        var toRead = TestStruct()
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(expect: 123)  // Bad value
            try read.uint16NetworkByteOrder(&toRead.twoBytes)
            try read.uuid(&toRead.uuidBytes)
            try read.vle(&toRead.eightBytes)
        }
        XCTAssertEqual(result, .error(.validationFailed), "Invalid result \(result)")

        // Bad value at end
        var toRead2 = TestStruct()
        let result2 = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.uint8(&toRead2.oneByte)
            try read.uint16NetworkByteOrder(&toRead2.twoBytes)
            try read.uuid(&toRead2.uuidBytes)
            try read.vle(expect: 12_354_152)  // Bad value
        }
        XCTAssertEqual(result2, .error(.validationFailed), "Invalid result \(result)")
    }

    func testDeserializeSkip() {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.uuidBytes = SystemUUID()
        toWrite.string = "hello world"

        let buffer = Serializer.serialize { write in
            write.uint8(toWrite.oneByte)
            write.uint16NetworkByteOrder(toWrite.twoBytes)
            write.uuid(toWrite.uuidBytes)
            write.fixedLengthUTF8(toWrite.string, byteCount: 20)
        }

        XCTAssertEqual(buffer.count, 39, "Invalid buffer length")

        var readString = ""
        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.skip(19)
            try read.fixedLengthUTF8(&readString, byteCount: 20)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(readString, toWrite.string, "Failed to deserialize string")
    }

    func testSerializeFrame() {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.eightBytes = 100024
        toWrite.uuidBytes = SystemUUID()
        toWrite.string = "hello world"

        var frame = Frame(count: 43)
        defer {
            frame.finalize(success: true)
        }
        XCTAssertEqual(43, frame.unclaimedLength, "Frame length incorrect")

        // Serialize
        let writeResult = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.uint8(toWrite.oneByte)
            try write.vle(toWrite.eightBytes)
            try write.uint16NetworkByteOrder(toWrite.twoBytes)
            try write.uuid(toWrite.uuidBytes)
            try write.fixedLengthUTF8(toWrite.string, byteCount: 20)
        }

        XCTAssertEqual(writeResult.remainingBytes, 0, "Invalid result \(writeResult)")
        XCTAssertEqual(43, frame.unclaimedLength, "Frame length incorrect")

        // Validate & Deserialize mix
        var toValidateAndRead = TestStruct()
        let validateResult = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
            try read.uint8(expect: toWrite.oneByte)
            try read.vle(expect: toWrite.eightBytes)
            try read.uint16NetworkByteOrder(expect: toWrite.twoBytes)
            try read.uuid(expect: toWrite.uuidBytes)
            try read.fixedLengthUTF8(&toValidateAndRead.string, byteCount: 20)
        }
        XCTAssertEqual(validateResult.remainingBytes, 0, "Invalid result \(validateResult)")
        XCTAssertEqual(toValidateAndRead.string, toWrite.string, "Failed to deserialize string")

        // Deserialize
        var toRead = TestStruct()
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.uint8(&toRead.oneByte)
            try read.vle(&toRead.eightBytes)
            try read.uint16NetworkByteOrder(&toRead.twoBytes)
            try read.uuid(&toRead.uuidBytes)
            try read.fixedLengthUTF8(&toRead.string, byteCount: 20)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead.oneByte, toWrite.oneByte, "Failed to deserialize uint8")
        XCTAssertEqual(toRead.twoBytes, toWrite.twoBytes, "Failed to deserialize uint16nbo")
        XCTAssertEqual(toRead.eightBytes, toWrite.eightBytes, "Failed to deserialize vle")
        XCTAssertEqual(toRead.uuidBytes, toWrite.uuidBytes, "Failed to deserialize uuid")
        XCTAssertEqual(toRead.string, toWrite.string, "Failed to deserialize string")

        XCTAssertEqual(0, frame.unclaimedLength, "Failed to claim all bytes")
    }

    func testSerializeFramePiecemeal() {
        var toWrite = TestStruct()
        toWrite.oneByte = 1
        toWrite.twoBytes = 1024
        toWrite.eightBytes = 100024
        toWrite.uuidBytes = SystemUUID()
        toWrite.string = "hello world"

        var frame = Frame(count: 43)
        defer {
            frame.finalize(success: true)
        }
        XCTAssertEqual(43, frame.unclaimedLength, "Frame length incorrect")

        let originalOffset = frame.startOffset
        let writeResult = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
            try write.uint8(toWrite.oneByte)
            try write.vle(toWrite.eightBytes)
        }

        let writeResult2 = Serializer.serialize(
            &frame,
            claim: true
        ) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(toWrite.twoBytes)
            try write.uuid(toWrite.uuidBytes)
            try write.fixedLengthUTF8(toWrite.string, byteCount: 20)
        }
        let currentOffset = frame.startOffset

        // we expect to have consumed all of the frame
        XCTAssertEqual(0, frame.unclaimedLength)

        let claimedLength = currentOffset - originalOffset

        XCTAssertEqual(writeResult.remainingBytes, 38, "Invalid result \(writeResult)")
        XCTAssertEqual(writeResult2.remainingBytes, 0, "Invalid result \(writeResult)")

        // unclaim amount written from the start
        XCTAssertTrue(frame.unclaim(fromStart: claimedLength))
        XCTAssertEqual(43, frame.unclaimedLength, "Frame length incorrect")

        var toRead = TestStruct()
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.uint8(&toRead.oneByte)
            try read.vle(&toRead.eightBytes)
            try read.uint16NetworkByteOrder(&toRead.twoBytes)
            try read.uuid(&toRead.uuidBytes)
            try read.fixedLengthUTF8(&toRead.string, byteCount: 20)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(toRead.oneByte, toWrite.oneByte, "Failed to deserialize uint8")
        XCTAssertEqual(toRead.twoBytes, toWrite.twoBytes, "Failed to deserialize uint16nbo")
        XCTAssertEqual(toRead.eightBytes, toWrite.eightBytes, "Failed to deserialize vle")
        XCTAssertEqual(toRead.uuidBytes, toWrite.uuidBytes, "Failed to deserialize uuid")
        XCTAssertEqual(toRead.string, toWrite.string, "Failed to deserialize string")

        XCTAssertEqual(0, frame.unclaimedLength, "Failed to claim all bytes")
    }

    func testSerializeFrameLengthPrefixedBuffer() {
        let toWrite: [UInt8] = [1, 2, 3, 4]
        let length = toWrite.count
        let sentinel: UInt8 = 42

        var frame = Frame(count: 6)
        defer {
            frame.finalize(success: true)
        }
        XCTAssertEqual(6, frame.unclaimedLength, "Frame length incorrect")

        let writeResult = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.uint8(UInt8(length))
            try write.buffer(toWrite)
            try write.uint8(sentinel)
        }

        XCTAssertEqual(writeResult.remainingBytes, 0, "Invalid result \(writeResult)")
        XCTAssertEqual(6, frame.unclaimedLength, "Frame length incorrect")

        var readLength: UInt8 = 0
        var readSentinel: UInt8 = 0
        var toRead = [UInt8]()
        let result = Deserializer.deserialize(&frame, claim: true) { read throws(DeserializationError) in
            try read.uint8(&readLength)
            try read.buffer(&toRead, length: Int(readLength))
            try read.uint8(&readSentinel)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(readLength, 4, "Failed to deserialize")
        XCTAssertEqual(toRead, toWrite, "Failed to deserialize")
        XCTAssertEqual(readSentinel, sentinel, "Failed to deserialize")

        XCTAssertEqual(0, frame.unclaimedLength, "Failed to claim all bytes")
    }

    struct TestSpanFactory: ~Copyable, DeserializerSpanFactory {
        let buffers: [[UInt8]]
        var index = 0

        init(_ buffers: [[UInt8]]) {
            self.buffers = buffers
        }

        mutating func nextSpan() -> RawSpan? {
            guard index < buffers.count else { return nil }
            let buffer = buffers[index]
            index += 1
            return _overrideLifetime(buffer.span.bytes, borrowing: self)
        }

        var availableByteCount: Int {
            buffers.reduce(0) { $0 + $1.count }
        }
    }

    func testDeserializeStream() {
        let completeBuffer: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x01, 0x02, 0x03,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        ]

        let buffer1: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let buffer2: [UInt8] = [0x01, 0x02, 0x03]
        let buffer3: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var array = [8 of UInt16](repeating: 0)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16(&array[0])
            try read.uint16(&array[1])
            try read.uint16(&array[2])
            try read.uint16(&array[3])
            try read.uint16(&array[4])
            try read.uint16(&array[5])
            try read.uint16(&array[6])
            try read.uint16(&array[7])
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(completeBuffer, [UInt8](copying: array.span.bytes), "Failed to deserialize")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamTrickle() {
        let completeBuffer: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]

        var factory = TestSpanFactory([[0x01], [0x02], [0x03], [0x04], [0x05], [0x06], [0x07], [0x08]])

        var array = [4 of UInt16](repeating: 0)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16(&array[0])
            try read.uint16(&array[1])
            try read.uint16(&array[2])
            try read.uint16(&array[3])
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(completeBuffer, [UInt8](copying: array.span.bytes), "Failed to deserialize")
        XCTAssertEqual(factory.index, 8)
    }

    // MARK: - Mixed type fragmented stream tests

    func testDeserializeStreamMixedUInt8AndUInt32() {
        // 1 byte + 4 bytes + 1 byte + 4 bytes = 10 bytes
        // Split across spans so the UInt32 straddles a boundary
        let buffer1: [UInt8] = [0xAA, 0x01, 0x02]  // uint8 + first 2 bytes of uint32
        let buffer2: [UInt8] = [0x03, 0x04, 0xBB, 0x05]  // last 2 bytes of uint32 + uint8 + first byte of uint32
        let buffer3: [UInt8] = [0x06, 0x07, 0x08]  // last 3 bytes of uint32

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var u8_1: UInt8 = 0
        var u32_1: UInt32 = 0
        var u8_2: UInt8 = 0
        var u32_2: UInt32 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8_1)
            try read.uint32(&u32_1)
            try read.uint8(&u8_2)
            try read.uint32(&u32_2)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8_1, 0xAA)
        XCTAssertEqual(u32_1, 0x0403_0201)
        XCTAssertEqual(u8_2, 0xBB)
        XCTAssertEqual(u32_2, 0x0807_0605)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamUInt64AcrossSpans() {
        // 8 bytes split across 3 spans
        let buffer1: [UInt8] = [0x01, 0x02, 0x03]
        let buffer2: [UInt8] = [0x04, 0x05]
        let buffer3: [UInt8] = [0x06, 0x07, 0x08]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var value: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint64(&value)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(value, 0x0807_0605_0403_0201)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamNetworkByteOrderUInt16() {
        // Two UInt16 values in network byte order, split across spans
        // 0x0102 and 0x0304 in big-endian
        let buffer1: [UInt8] = [0x01]
        let buffer2: [UInt8] = [0x02, 0x03]
        let buffer3: [UInt8] = [0x04]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var val1: UInt16 = 0
        var val2: UInt16 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16NetworkByteOrder(&val1)
            try read.uint16NetworkByteOrder(&val2)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(val1, 0x0102)
        XCTAssertEqual(val2, 0x0304)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamNetworkByteOrderUInt32() {
        // 0x01020304 in big-endian, split across spans
        let buffer1: [UInt8] = [0x01, 0x02]
        let buffer2: [UInt8] = [0x03, 0x04]

        var factory = TestSpanFactory([buffer1, buffer2])

        var value: UInt32 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(&value)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(value, 0x0102_0304)
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamNetworkByteOrderUInt64() {
        // 0x0102030405060708 in big-endian, trickled one byte at a time
        var factory = TestSpanFactory([
            [0x01], [0x02], [0x03], [0x04],
            [0x05], [0x06], [0x07], [0x08],
        ])

        var value: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint64NetworkByteOrder(&value)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(value, 0x0102_0304_0506_0708)
        XCTAssertEqual(factory.index, 8)
    }

    func testDeserializeStreamMixedHostAndNetworkByteOrder() {
        // uint8 (host) + uint16 NBO + uint32 (host) + uint16 NBO = 1 + 2 + 4 + 2 = 9 bytes
        let buffer1: [UInt8] = [0xFF, 0x00, 0x01]  // uint8 + uint16 NBO (0x0001)
        let buffer2: [UInt8] = [0x04, 0x03, 0x02, 0x01]  // uint32 host (0x01020304)
        let buffer3: [UInt8] = [0xAB, 0xCD]  // uint16 NBO (0xABCD)

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var u8: UInt8 = 0
        var u16nbo1: UInt16 = 0
        var u32: UInt32 = 0
        var u16nbo2: UInt16 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint16NetworkByteOrder(&u16nbo1)
            try read.uint32(&u32)
            try read.uint16NetworkByteOrder(&u16nbo2)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xFF)
        XCTAssertEqual(u16nbo1, 0x0001)
        XCTAssertEqual(u32, 0x0102_0304)
        XCTAssertEqual(u16nbo2, 0xABCD)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamUUIDAcrossSpans() {
        // A UUID is 16 bytes, split across 3 spans
        let buffer1: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let buffer2: [UInt8] = [0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B]
        let buffer3: [UInt8] = [0x0C, 0x0D, 0x0E, 0x0F, 0x10]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var value = SystemUUID.empty
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uuid(&value)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        let expectedBytes: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        ]
        withUnsafeBytes(of: value) { uuidBytes in
            XCTAssertEqual([UInt8](uuidBytes), expectedBytes, "UUID bytes mismatch")
        }
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamUUIDTrickle() {
        // UUID trickled one byte at a time
        let buffers: [[UInt8]] = (1...16).map { [$0] }
        var factory = TestSpanFactory(buffers)

        var value = SystemUUID.empty
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uuid(&value)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        let expectedBytes: [UInt8] = Array(1...16)
        withUnsafeBytes(of: value) { uuidBytes in
            XCTAssertEqual([UInt8](uuidBytes), expectedBytes, "UUID bytes mismatch")
        }
        XCTAssertEqual(factory.index, 16)
    }

    func testDeserializeStreamMixedAllTypes() {
        // uint8 + uint16 NBO + uuid + uint32 NBO + uint64 = 1 + 2 + 16 + 4 + 8 = 31 bytes
        // Split into awkward spans to force fragmentation everywhere
        var fullBuffer: [UInt8] = []
        fullBuffer.append(0x42)  // uint8: 0x42
        fullBuffer.append(contentsOf: [0x00, 0x80])  // uint16 NBO: 0x0080 = 128
        fullBuffer.append(contentsOf: Array(0xA0...0xAF))  // uuid: 16 bytes
        fullBuffer.append(contentsOf: [0x00, 0x00, 0x01, 0x00])  // uint32 NBO: 0x00000100 = 256
        fullBuffer.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])  // uint64 host: 1

        // Split into spans of 3 bytes each (forces every multi-byte read to fragment)
        var buffers: [[UInt8]] = []
        var i = 0
        while i < fullBuffer.count {
            let end = min(i + 3, fullBuffer.count)
            buffers.append(Array(fullBuffer[i..<end]))
            i = end
        }

        var factory = TestSpanFactory(buffers)

        var u8: UInt8 = 0
        var u16nbo: UInt16 = 0
        var uuid = SystemUUID.empty
        var u32nbo: UInt32 = 0
        var u64: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint16NetworkByteOrder(&u16nbo)
            try read.uuid(&uuid)
            try read.uint32NetworkByteOrder(&u32nbo)
            try read.uint64(&u64)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0x42)
        XCTAssertEqual(u16nbo, 0x0080)
        let expectedUUIDBytes: [UInt8] = Array(0xA0...0xAF)
        withUnsafeBytes(of: uuid) { uuidBytes in
            XCTAssertEqual([UInt8](uuidBytes), expectedUUIDBytes, "UUID bytes mismatch")
        }
        XCTAssertEqual(u32nbo, 0x0000_0100)
        XCTAssertEqual(u64, 1)
        XCTAssertEqual(factory.index, 11)
    }

    func testDeserializeStreamFragmentedRunsOutOfData() {
        // Only 3 bytes available but we try to read a UInt32 (4 bytes)
        var factory = TestSpanFactory([[0x01, 0x02], [0x03]])

        var value: UInt32 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint32(&value)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        XCTAssertEqual(factory.index, 2)
    }

    // MARK: - Fragmented expect/validate tests

    func testDeserializeStreamExpectUInt8Fragmented() {
        // uint8 expect at a span boundary: first span empty triggers refill
        var factory = TestSpanFactory([[], [0x42]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(expect: 0x42)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamExpectUInt16Fragmented() {
        // UInt16 0x0201 in little-endian: bytes [0x01, 0x02] split across spans
        var factory = TestSpanFactory([[0x01], [0x02]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16(expect: 0x0201)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamExpectUInt16FragmentedMismatch() {
        var factory = TestSpanFactory([[0x01], [0x02]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16(expect: 0xFFFF)
        }

        XCTAssertEqual(result, .error(.validationFailed), "Should fail with validationFailed")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamExpectUInt32Fragmented() {
        // UInt32 0x04030201 in little-endian: bytes [0x01, 0x02, 0x03, 0x04]
        var factory = TestSpanFactory([[0x01, 0x02], [0x03], [0x04]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint32(expect: 0x0403_0201)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamExpectUInt64Trickle() {
        // UInt64 trickled one byte at a time
        var factory = TestSpanFactory([
            [0x01], [0x02], [0x03], [0x04],
            [0x05], [0x06], [0x07], [0x08],
        ])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint64(expect: 0x0807_0605_0403_0201)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 8)
    }

    func testDeserializeStreamExpectUInt16NBOFragmented() {
        // Network byte order: expect 0x0102, bytes in buffer are [0x01, 0x02]
        var factory = TestSpanFactory([[0x01], [0x02]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16NetworkByteOrder(expect: 0x0102)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamExpectUInt32NBOFragmented() {
        // Network byte order: expect 0x01020304, bytes [0x01, 0x02, 0x03, 0x04]
        var factory = TestSpanFactory([[0x01, 0x02], [0x03, 0x04]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint32NetworkByteOrder(expect: 0x0102_0304)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamExpectUInt64NBOFragmented() {
        var factory = TestSpanFactory([
            [0x01, 0x02, 0x03], [0x04, 0x05],
            [0x06, 0x07, 0x08],
        ])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint64NetworkByteOrder(expect: 0x0102_0304_0506_0708)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamExpectMixedReadAndValidate() {
        // Mix of read + expect across fragmented spans:
        // uint8 read + uint16 expect + uint32 read + uint16 NBO expect
        // = 1 + 2 + 4 + 2 = 9 bytes in 3-byte spans
        let buffer1: [UInt8] = [0xAA, 0x01, 0x02]
        let buffer2: [UInt8] = [0x04, 0x03, 0x02]
        let buffer3: [UInt8] = [0x01, 0xCA, 0xFE]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var u8: UInt8 = 0
        var u32: UInt32 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint16(expect: 0x0201)
            try read.uint32(&u32)
            try read.uint16NetworkByteOrder(expect: 0xCAFE)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xAA)
        XCTAssertEqual(u32, 0x0102_0304)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamExpectFragmentedRunsOutOfData() {
        // Only 3 bytes but expect a UInt32
        var factory = TestSpanFactory([[0x01], [0x02, 0x03]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint32(expect: 0x0403_0201)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamExpectUUIDFragmented() {
        // UUID split across spans
        let buffer1: [UInt8] = Array(0x01...0x06)
        let buffer2: [UInt8] = Array(0x07...0x0C)
        let buffer3: [UInt8] = Array(0x0D...0x10)

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        let expectedUUID: SystemUUID = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { buf in
            for i in 0..<16 { buf[i] = UInt8(i + 1) }
            return buf.baseAddress!.withMemoryRebound(to: SystemUUID.self, capacity: 1) { $0.pointee }
        }

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uuid(expect: expectedUUID)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeSpanExpectSingleSpan() {
        // All bytes available in one span
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let buffer: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
    }

    func testDeserializeSpanExpectSingleSpanWithRemainder() {
        // All expected bytes in one span, with extra bytes after
        let expected: [UInt8] = [0x01, 0x02, 0x03]
        let buffer: [UInt8] = [0x01, 0x02, 0x03, 0xAA, 0xBB]

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 2, "Invalid result \(result)")
    }

    func testDeserializeSpanExpectMismatchSingleSpan() {
        // Bytes don't match in single span
        let expected: [UInt8] = [0x01, 0x02, 0xFF]
        let buffer: [UInt8] = [0x01, 0x02, 0x03]

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result, .error(.validationFailed), "Should fail with validationFailed")
    }

    func testDeserializeSpanExpectBufferTooShort() {
        // Not enough bytes available
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let buffer: [UInt8] = [0x01, 0x02, 0x03]

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
    }

    func testDeserializeSpanExpectEmpty() {
        // Empty span should succeed without consuming bytes
        let expected: [UInt8] = []
        let buffer: [UInt8] = [0x01, 0x02]

        let result = Deserializer.deserialize(buffer) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 2, "Invalid result \(result)")
    }

    func testDeserializeStreamSpanExpectFragmented() {
        // Span expect split across two underlying spans
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        var factory = TestSpanFactory([[0x01, 0x02], [0x03, 0x04, 0x05]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamSpanExpectFragmentedThreeSpans() {
        // Span expect split across three underlying spans
        let expected: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        var factory = TestSpanFactory([[0xAA, 0xBB], [0xCC, 0xDD], [0xEE, 0xFF]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamSpanExpectFragmentedTrickle() {
        // One byte per span
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var factory = TestSpanFactory([[0x01], [0x02], [0x03], [0x04]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 4)
    }

    func testDeserializeStreamSpanExpectFragmentedMismatch() {
        // Bytes match in first span but mismatch in second
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var factory = TestSpanFactory([[0x01, 0x02], [0xFF, 0x04]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result, .error(.validationFailed), "Should fail with validationFailed")
    }

    func testDeserializeStreamSpanExpectFragmentedMismatchFirstByte() {
        // Mismatch right at the start of the second span
        let expected: [UInt8] = [0x01, 0x02, 0x03]
        var factory = TestSpanFactory([[0x01], [0xFF, 0x03]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result, .error(.validationFailed), "Should fail with validationFailed")
    }

    func testDeserializeStreamSpanExpectFragmentedRunsOutOfData() {
        // Total bytes across spans are insufficient
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        var factory = TestSpanFactory([[0x01, 0x02], [0x03]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
    }

    func testDeserializeStreamSpanExpectAfterPartialRead() {
        // Read some bytes first, then span expect crosses the boundary
        let expected: [UInt8] = [0xCC, 0xDD, 0xEE]
        var factory = TestSpanFactory([[0xAA, 0xBB, 0xCC], [0xDD, 0xEE]])

        var u8_1: UInt8 = 0
        var u8_2: UInt8 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8_1)
            try read.uint8(&u8_2)
            try read.span(expect: expected.span.bytes)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8_1, 0xAA)
        XCTAssertEqual(u8_2, 0xBB)
        XCTAssertEqual(factory.index, 2)
    }

    // MARK: - Fragmented VLE tests

    func testDeserializeStreamVLE1ByteAtSpanBoundary() {
        // 1-byte VLE value 44 = 0x2c (top 2 bits = 00)
        // Preceded by a uint8 that consumes the first span
        var factory = TestSpanFactory([[0xFF], [0x2c]])

        var u8: UInt8 = 0
        var vleValue: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.vle(&vleValue)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xFF)
        XCTAssertEqual(vleValue, 44)
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamVLE2ByteFragmented() {
        // 2-byte VLE value 12381 = [0x70, 0x5d] (top 2 bits = 01)
        // Split across spans
        var factory = TestSpanFactory([[0x70], [0x5d]])

        var vleValue: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(&vleValue)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(vleValue, 12381)
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamVLE4ByteFragmented() {
        // 4-byte VLE value 268435456 = [0x90, 0x00, 0x00, 0x00] (top 2 bits = 10)
        // Split across 3 spans
        var factory = TestSpanFactory([[0x90], [0x00, 0x00], [0x00]])

        var vleValue: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(&vleValue)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(vleValue, 268_435_456)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamVLE8ByteTrickle() {
        // 8-byte VLE value 57849345434345 = [0xc0, 0x00, 0x34, 0x9d, 0x19, 0xaf, 0x62, 0xe9]
        // (top 2 bits = 11), trickled one byte at a time
        var factory = TestSpanFactory([
            [0xc0], [0x00], [0x34], [0x9d],
            [0x19], [0xaf], [0x62], [0xe9],
        ])

        var vleValue: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(&vleValue)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(vleValue, 57_849_345_434_345)
        XCTAssertEqual(factory.index, 8)
    }

    func testDeserializeStreamVLEExpectFragmented() {
        // 2-byte VLE expect 12381 = [0x70, 0x5d], split across spans
        var factory = TestSpanFactory([[0x70], [0x5d]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(expect: UInt64(12381))
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamVLEExpectFragmentedMismatch() {
        // 2-byte VLE [0x70, 0x5d] = 12381, but expect 9999
        var factory = TestSpanFactory([[0x70], [0x5d]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(expect: UInt64(9999))
        }

        XCTAssertEqual(result, .error(.validationFailed), "Should fail with validationFailed")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamMultipleVLEFragmented() {
        // Three VLE values split across awkward spans:
        // VLE 0 = [0x00] (1 byte)
        // VLE 12381 = [0x70, 0x5d] (2 bytes)
        // VLE 268435456 = [0x90, 0x00, 0x00, 0x00] (4 bytes)
        // Total: 7 bytes in 3-byte spans
        var factory = TestSpanFactory([
            [0x00, 0x70, 0x5d],
            [0x90, 0x00, 0x00],
            [0x00],
        ])

        var v1: UInt64 = 0
        var v2: UInt64 = 0
        var v3: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(&v1)
            try read.vle(&v2)
            try read.vle(&v3)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(v1, 0)
        XCTAssertEqual(v2, 12381)
        XCTAssertEqual(v3, 268_435_456)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamVLEMixedWithFixedTypes() {
        // uint8 + VLE 2-byte + uint32 NBO + VLE 1-byte
        // = 1 + 2 + 4 + 1 = 8 bytes in 3-byte spans
        var factory = TestSpanFactory([
            [0xAA, 0x70, 0x5d],  // uint8(0xAA) + VLE(12381) first 2 bytes
            [0x01, 0x02, 0x03],  // uint32 NBO bytes
            [0x04, 0x2c],
        ])  // uint32 last byte + VLE(44)

        var u8: UInt8 = 0
        var vle1: UInt64 = 0
        var u32: UInt32 = 0
        var vle2: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.vle(&vle1)
            try read.uint32NetworkByteOrder(&u32)
            try read.vle(&vle2)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xAA)
        XCTAssertEqual(vle1, 12381)
        XCTAssertEqual(u32, 0x0102_0304)
        XCTAssertEqual(vle2, 44)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamVLERunsOutOfData() {
        // 2-byte VLE prefix [0x70] but no second byte
        var factory = TestSpanFactory([[0x70]])

        var vleValue: UInt64 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.vle(&vleValue)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        XCTAssertEqual(factory.index, 1)
    }

    // MARK: - Fragmented MutableSpan tests

    func testDeserializeStreamSpanFragmented() {
        // Read 8 bytes into a MutableSpan, split across 3 spans
        let buffer1: [UInt8] = [0x01, 0x02, 0x03]
        let buffer2: [UInt8] = [0x04, 0x05]
        let buffer3: [UInt8] = [0x06, 0x07, 0x08]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var dest = [UInt8](repeating: 0, count: 8)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            var ms = dest.mutableSpan
            try read.span(&ms)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        XCTAssertEqual(dest, expected, "Span bytes mismatch")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamSpanTrickle() {
        // Read 6 bytes into a MutableSpan, trickled one byte at a time
        var factory = TestSpanFactory([[0xA1], [0xA2], [0xA3], [0xA4], [0xA5], [0xA6]])

        var dest = [UInt8](repeating: 0, count: 6)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            var ms = dest.mutableSpan
            try read.span(&ms)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        let expected: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]
        XCTAssertEqual(dest, expected, "Span bytes mismatch")
        XCTAssertEqual(factory.index, 6)
    }

    func testDeserializeStreamSpanWithLengthFragmented() {
        // Read only 4 bytes into a 6-byte MutableSpan, fragmented
        var factory = TestSpanFactory([[0x01, 0x02], [0x03, 0x04, 0x05, 0x06]])

        var dest = [UInt8](repeating: 0, count: 6)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            var ms = dest.mutableSpan
            try read.span(&ms, length: 4)
        }

        XCTAssertEqual(result.remainingBytes, 2, "Invalid result \(result)")
        let expected: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x00, 0x00]
        XCTAssertEqual(dest, expected, "Span bytes mismatch")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamSpanAfterFixedTypes() {
        // uint8 + uint16 + span(4 bytes) across fragmented spans
        // = 1 + 2 + 4 = 7 bytes in 3-byte spans
        let buffer1: [UInt8] = [0xAA, 0x01, 0x02]
        let buffer2: [UInt8] = [0x10, 0x20, 0x30]
        let buffer3: [UInt8] = [0x40]

        var factory = TestSpanFactory([buffer1, buffer2, buffer3])

        var u8: UInt8 = 0
        var u16: UInt16 = 0
        var dest = [UInt8](repeating: 0, count: 4)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint16(&u16)
            var ms = dest.mutableSpan
            try read.span(&ms)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xAA)
        XCTAssertEqual(u16, 0x0201)
        let expected: [UInt8] = [0x10, 0x20, 0x30, 0x40]
        XCTAssertEqual(dest, expected, "Span bytes mismatch")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamSpanFragmentedRunsOutOfData() {
        // Only 3 bytes available but try to read 5
        var factory = TestSpanFactory([[0x01, 0x02], [0x03]])

        var dest = [UInt8](repeating: 0, count: 5)
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            var ms = dest.mutableSpan
            try read.span(&ms)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        XCTAssertEqual(factory.index, 2)
    }

    // MARK: - Fragmented buffer tests

    func testDeserializeStreamBufferWithLengthFragmented() {
        // Read 6 bytes with explicit length, split across 3 spans
        var factory = TestSpanFactory([[0x01, 0x02], [0x03, 0x04], [0x05, 0x06]])

        var dest = [UInt8]()
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.buffer(&dest, length: 6)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(dest, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamBufferWithLengthTrickle() {
        // Read 4 bytes trickled one at a time
        var factory = TestSpanFactory([[0xA1], [0xA2], [0xA3], [0xA4]])

        var dest = [UInt8]()
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.buffer(&dest, length: 4)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(dest, [0xA1, 0xA2, 0xA3, 0xA4])
        XCTAssertEqual(factory.index, 4)
    }

    func testDeserializeStreamBufferWithLengthAfterFixedTypes() {
        // uint8 + VLE(2-byte) + buffer(3) across fragmented spans
        // = 1 + 2 + 3 = 6 bytes in 2-byte spans
        var factory = TestSpanFactory([[0xFF, 0x70], [0x5d, 0x10], [0x20, 0x30]])

        var u8: UInt8 = 0
        var vleVal: UInt64 = 0
        var dest = [UInt8]()
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.vle(&vleVal)
            try read.buffer(&dest, length: 3)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xFF)
        XCTAssertEqual(vleVal, 12381)
        XCTAssertEqual(dest, [0x10, 0x20, 0x30])
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamBufferWithLengthRunsOutOfData() {
        // Only 3 bytes but try to read 5
        var factory = TestSpanFactory([[0x01, 0x02], [0x03]])

        var dest = [UInt8]()
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.buffer(&dest, length: 5)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamBufferDrainAllFragmented() {
        // buffer() with no length drains all remaining spans
        var factory = TestSpanFactory([[0x01, 0x02], [0x03, 0x04], [0x05]])

        var dest = [UInt8]()
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.buffer(&dest)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(dest, [0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamBufferDrainAfterPartialRead() {
        // Read a uint16 first, then drain the rest
        var factory = TestSpanFactory([[0x01, 0x02, 0x03], [0x04, 0x05]])

        var u16: UInt16 = 0
        var dest = [UInt8]()
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint16(&u16)
            try read.buffer(&dest)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u16, 0x0201)
        XCTAssertEqual(dest, [0x03, 0x04, 0x05])
        XCTAssertEqual(factory.index, 2)
    }

    // MARK: - Fragmented fixedLengthUTF8 / string tests

    func testDeserializeStreamFixedLengthUTF8Fragmented() {
        // "Hello" = [0x48, 0x65, 0x6c, 0x6c, 0x6f] split across spans
        var factory = TestSpanFactory([[0x48, 0x65], [0x6c, 0x6c], [0x6f]])

        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&str, byteCount: 5)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(str, "Hello")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamFixedLengthUTF8Trickle() {
        // "ABC" trickled one byte at a time
        var factory = TestSpanFactory([[0x41], [0x42], [0x43]])

        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&str, byteCount: 3)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(str, "ABC")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamFixedLengthUTF8WithNullFragmented() {
        // "Hi\0\0" — null-padded, split across spans. Should truncate at first null.
        var factory = TestSpanFactory([[0x48, 0x69], [0x00, 0x00]])

        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&str, byteCount: 4)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(str, "Hi")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamFixedLengthUTF8AfterFixedTypes() {
        // uint8 + fixedLengthUTF8(4) across fragmented spans
        // = 1 + 4 = 5 bytes in 2-byte spans
        var factory = TestSpanFactory([[0xFF, 0x54], [0x65, 0x73], [0x74]])

        var u8: UInt8 = 0
        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.fixedLengthUTF8(&str, byteCount: 4)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xFF)
        XCTAssertEqual(str, "Test")
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamFixedLengthUTF8RunsOutOfData() {
        // Only 3 bytes but try to read 5
        var factory = TestSpanFactory([[0x41, 0x42], [0x43]])

        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&str, byteCount: 5)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        // The total-available check fails before a second span is pulled.
        XCTAssertEqual(factory.index, 1)
    }

    func testDeserializeStreamFixedLengthUTF8InsaneAsk() {
        // Make sure a request for an insane amount of bytes doesn't cause an alloc that would lead to a crash
        var factory = TestSpanFactory([[0x41, 0x42], [0x43]])

        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.fixedLengthUTF8(&str, byteCount: Int.max)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail fast instead of allocating byteCount bytes")
    }

    func testDeserializeStreamStringFragmented() {
        // string() reads a uint16 length prefix then fixedLengthUTF8
        // Length prefix 0x0005 (big endian? no, host order) = 5, then "Hello"
        // uint16 is host byte order, so on little-endian: [0x05, 0x00]
        var factory = TestSpanFactory([[0x05, 0x00, 0x48], [0x65, 0x6c], [0x6c, 0x6f]])

        var str = ""
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.string(&str)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(str, "Hello")
        XCTAssertEqual(factory.index, 3)
    }

    // MARK: - Fragmented skip tests

    func testDeserializeStreamSkipFragmented() {
        // Skip 4 bytes across spans, then read a uint8
        var factory = TestSpanFactory([[0x01, 0x02], [0x03, 0x04], [0xAA]])

        var u8: UInt8 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.skip(4)
            try read.uint8(&u8)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xAA)
        XCTAssertEqual(factory.index, 3)
    }

    func testDeserializeStreamSkipTrickle() {
        // Skip 4 bytes trickled one at a time, then read uint16
        var factory = TestSpanFactory([[0x01], [0x02], [0x03], [0x04], [0x10, 0x20]])

        var u16: UInt16 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.skip(4)
            try read.uint16(&u16)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u16, 0x2010)
        XCTAssertEqual(factory.index, 5)
    }

    func testDeserializeStreamSkipEntireSpan() {
        // Skip exactly one full span, then read from the next
        var factory = TestSpanFactory([[0x01, 0x02, 0x03], [0xBB]])

        var u8: UInt8 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.skip(3)
            try read.uint8(&u8)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xBB)
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamSkipRunsOutOfData() {
        // Only 3 bytes available but try to skip 5
        var factory = TestSpanFactory([[0x01, 0x02], [0x03]])

        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.skip(5)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
        XCTAssertEqual(factory.index, 2)
    }

    func testDeserializeStreamSkipBetweenReads() {
        // uint8 + skip(3) + uint16 NBO across fragmented spans
        // = 1 + 3 + 2 = 6 bytes in 2-byte spans
        var factory = TestSpanFactory([[0xAA, 0x00], [0x00, 0x00], [0xCA, 0xFE]])

        var u8: UInt8 = 0
        var u16: UInt16 = 0
        let result = Deserializer<TestSpanFactory>.deserialize(&factory) { read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.skip(3)
            try read.uint16NetworkByteOrder(&u16)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xAA)
        XCTAssertEqual(u16, 0xCAFE)
        XCTAssertEqual(factory.index, 3)
    }

    // MARK: - FrameArray deserialization tests

    private func makeFrame(bytes: [UInt8]) -> Frame {
        var frame = Frame(count: bytes.count)
        _ = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.buffer(bytes)
        }
        return frame
    }

    func testDeserializeFrameArrayNoClaim() {
        // Two frames: [0x01, 0x02, 0x03] and [0x04, 0x05]
        // Read a uint8 + uint32 across the frame boundary, no claim
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02, 0x03]))
        frameArray.add(frame: makeFrame(bytes: [0x04, 0x05]))
        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        var u8: UInt8 = 0
        var u32: UInt32 = 0
        let result = Deserializer.deserialize(&frameArray, claim: false, removeClaimedFrames: false) {
            read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint32(&u32)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0x01)
        XCTAssertEqual(u32, 0x0504_0302)
        // No claim: all bytes should remain unclaimed
        XCTAssertEqual(frameArray.unclaimedLength, 5)
    }

    func testDeserializeFrameArrayWithClaim() {
        // Two frames: [0x01, 0x02, 0x03] and [0x04, 0x05]
        // Read a uint8 + uint32 across the frame boundary, with claim
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02, 0x03]))
        frameArray.add(frame: makeFrame(bytes: [0x04, 0x05]))

        var u8: UInt8 = 0
        var u32: UInt32 = 0
        let result = Deserializer.deserialize(&frameArray, claim: true, removeClaimedFrames: true) {
            read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint32(&u32)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0x01)
        XCTAssertEqual(u32, 0x0504_0302)
        // Both frames fully consumed: popped and finalized
        XCTAssertEqual(frameArray.count, 0)
    }

    func testDeserializeFrameArrayClaimPartialLastFrame() {
        // Three frames: [0xAA] [0x01, 0x02] [0x03, 0x04, 0x05]
        // Read uint8 + uint16, consuming first frame fully and all of second
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0xAA]))
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02]))
        frameArray.add(frame: makeFrame(bytes: [0x03, 0x04, 0x05]))
        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        var u8: UInt8 = 0
        var u16: UInt16 = 0
        let result = Deserializer.deserialize(&frameArray, claim: true, removeClaimedFrames: true) {
            read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint16(&u16)
        }

        XCTAssertEqual(result.remainingBytes, 3, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xAA)
        XCTAssertEqual(u16, 0x0201)
        // First frame popped+finalized, second frame fully consumed and popped+finalized,
        // third frame untouched remains
        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 3)
    }

    func testDeserializeFrameArrayClaimMultipleFullFrames() {
        // Three frames each 2 bytes: [0x01, 0x02] [0x03, 0x04] [0x05, 0x06]
        // Read all 6 bytes as uint16s, claiming everything
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02]))
        frameArray.add(frame: makeFrame(bytes: [0x03, 0x04]))
        frameArray.add(frame: makeFrame(bytes: [0x05, 0x06]))

        var v1: UInt16 = 0
        var v2: UInt16 = 0
        var v3: UInt16 = 0
        let result = Deserializer.deserialize(&frameArray, claim: true, removeClaimedFrames: true) {
            read throws(DeserializationError) in
            try read.uint16(&v1)
            try read.uint16(&v2)
            try read.uint16(&v3)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(v1, 0x0201)
        XCTAssertEqual(v2, 0x0403)
        XCTAssertEqual(v3, 0x0605)
        // All frames popped and finalized
        XCTAssertEqual(frameArray.count, 0)
    }

    func testDeserializeFrameArrayMixedTypes() {
        // Four frames: [0xFF] [0x00, 0x80] [0x01, 0x02, 0x03] [0x04]
        // Read uint8 + uint16 NBO + uint32 across all frames
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0xFF]))
        frameArray.add(frame: makeFrame(bytes: [0x00, 0x80]))
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02, 0x03]))
        frameArray.add(frame: makeFrame(bytes: [0x04]))
        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        var u8: UInt8 = 0
        var u16nbo: UInt16 = 0
        var u32: UInt32 = 0
        let result = Deserializer.deserialize(&frameArray, claim: true, removeClaimedFrames: true) {
            read throws(DeserializationError) in
            try read.uint8(&u8)
            try read.uint16NetworkByteOrder(&u16nbo)
            try read.uint32(&u32)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(u8, 0xFF)
        XCTAssertEqual(u16nbo, 0x0080)
        XCTAssertEqual(u32, 0x0403_0201)
        // All frames popped and finalized
        XCTAssertEqual(frameArray.count, 0)
    }

    func testDeserializeFrameArrayBufferTooShort() {
        // Two frames with 3 total bytes, try to read 4
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02]))
        frameArray.add(frame: makeFrame(bytes: [0x03]))
        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        var value: UInt32 = 0
        let result = Deserializer.deserialize(&frameArray, claim: true, removeClaimedFrames: true) {
            read throws(DeserializationError) in
            try read.uint32(&value)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort")
    }

    func testDeserializeFrameArrayEmpty() {
        var frameArray = FrameArray()

        var u8: UInt8 = 0
        let result = Deserializer.deserialize(&frameArray, claim: false, removeClaimedFrames: false) {
            read throws(DeserializationError) in
            try read.uint8(&u8)
        }

        XCTAssertEqual(result, .error(.bufferTooShort), "Should fail with bufferTooShort for empty array")
    }

    func testDeserializeFrameArrayNoClaimPreservesFrames() {
        // Verify that without claim, all frame bytes remain intact
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0xAA, 0xBB]))
        frameArray.add(frame: makeFrame(bytes: [0xCC, 0xDD, 0xEE]))
        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        let totalBefore = frameArray.unclaimedLength

        var buf = [UInt8]()
        let result = Deserializer.deserialize(&frameArray, claim: false, removeClaimedFrames: false) {
            read throws(DeserializationError) in
            try read.buffer(&buf, length: 5)
        }

        XCTAssertEqual(result.remainingBytes, 0, "Invalid result \(result)")
        XCTAssertEqual(buf, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        // No claim: total unclaimed length should be unchanged
        XCTAssertEqual(frameArray.unclaimedLength, totalBefore)
    }

    func testDeserializeFrameArrayClaimPartiallyConsumedLastFrame() {
        // Two frames: [0x01, 0x02, 0x03] [0x04, 0x05, 0x06, 0x07]
        // Read uint32 (4 bytes), consuming first frame fully + 1 byte of second
        var frameArray = FrameArray()
        frameArray.add(frame: makeFrame(bytes: [0x01, 0x02, 0x03]))
        frameArray.add(frame: makeFrame(bytes: [0x04, 0x05, 0x06, 0x07]))
        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        var u32: UInt32 = 0
        let result = Deserializer.deserialize(&frameArray, claim: true, removeClaimedFrames: true) {
            read throws(DeserializationError) in
            try read.uint32(&u32)
        }

        XCTAssertEqual(result.remainingBytes, 3, "Invalid result \(result)")
        XCTAssertEqual(u32, 0x0403_0201)
        // First frame popped+finalized, second frame partially claimed (1 of 4 bytes)
        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 3)
    }

    // MARK: - InPlaceSerializer factory tests

    struct TestMutableSpanFactory: ~Copyable, SerializerSpanFactory {
        var allocations: [UnsafeMutableBufferPointer<UInt8>]
        var index = 0

        init(_ sizes: [Int]) {
            self.allocations = sizes.map { size in
                let ptr = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: size)
                ptr.update(repeating: 0)
                return ptr
            }
        }

        deinit {
            for alloc in allocations {
                alloc.deallocate()
            }
        }

        mutating func nextMutableSpan() -> MutableRawSpan? {
            guard index < allocations.count else { return nil }
            let alloc = allocations[index]
            index += 1
            let span = MutableRawSpan(_unsafeBytes: UnsafeMutableRawBufferPointer(alloc))
            return _overrideLifetime(span, borrowing: self)
        }

        var availableByteCount: Int {
            allocations.reduce(0) { $0 + $1.count }
        }

        var buffers: [[UInt8]] {
            allocations.map { Array($0) }
        }

        /// Concatenate all buffers into a single byte array for verification.
        var allBytes: [UInt8] {
            allocations.flatMap { Array($0) }
        }
    }

    func testInPlaceSerializerStreamUInt16AcrossSpans() {
        // 4 bytes total, split across 2 spans of 3 and 3 bytes
        // Write two UInt16s (4 bytes total): first fits, second straddles boundary
        var factory = TestMutableSpanFactory([3, 3])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint16(0x0102)
            try write.uint16(0x0304)
        }

        XCTAssertEqual(result.remainingBytes, 2)
        // Verify the bytes were written correctly
        let allBytes = factory.allBytes
        // UInt16 0x0102 is stored as [0x02, 0x01] on little-endian
        XCTAssertEqual(allBytes[0], 0x02)
        XCTAssertEqual(allBytes[1], 0x01)
        // UInt16 0x0304 straddles: [0x04] in first span, [0x03] in second span
        XCTAssertEqual(allBytes[2], 0x04)
        XCTAssertEqual(allBytes[3], 0x03)
    }

    func testInPlaceSerializerStreamUInt32AcrossSpans() {
        // Write a UInt32 across 3 spans
        var factory = TestMutableSpanFactory([2, 1, 3])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint32(0x0403_0201)
        }

        XCTAssertEqual(result.remainingBytes, 2)
        let allBytes = factory.allBytes
        XCTAssertEqual(allBytes[0], 0x01)
        XCTAssertEqual(allBytes[1], 0x02)
        XCTAssertEqual(allBytes[2], 0x03)
        XCTAssertEqual(allBytes[3], 0x04)
    }

    func testInPlaceSerializerStreamTrickle() {
        // Write 4 uint8 values into 1-byte spans
        var factory = TestMutableSpanFactory([1, 1, 1, 1])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint8(0xAA)
            try write.uint8(0xBB)
            try write.uint8(0xCC)
            try write.uint8(0xDD)
        }

        XCTAssertEqual(result.remainingBytes, 0)
        XCTAssertEqual(factory.allBytes, [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testInPlaceSerializerStreamNetworkByteOrder() {
        // Write a UInt16 NBO across span boundary
        var factory = TestMutableSpanFactory([1, 3])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(0xCAFE)
        }

        XCTAssertEqual(result.remainingBytes, 2)
        let allBytes = factory.allBytes
        // Big-endian: 0xCA, 0xFE
        XCTAssertEqual(allBytes[0], 0xCA)
        XCTAssertEqual(allBytes[1], 0xFE)
    }

    func testInPlaceSerializerStreamUInt64Trickle() {
        // Write a UInt64 across 8 single-byte spans
        var factory = TestMutableSpanFactory([1, 1, 1, 1, 1, 1, 1, 1])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint64(0x0807_0605_0403_0201)
        }

        XCTAssertEqual(result.remainingBytes, 0)
        XCTAssertEqual(factory.allBytes, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    func testInPlaceSerializerStreamBufferAcrossSpans() {
        // Write a 5-byte buffer across 2 spans
        var factory = TestMutableSpanFactory([3, 4])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.buffer([0x01, 0x02, 0x03, 0x04, 0x05])
        }

        XCTAssertEqual(result.remainingBytes, 2)
        let allBytes = factory.allBytes
        XCTAssertEqual(allBytes[0...4], [0x01, 0x02, 0x03, 0x04, 0x05][0...4])
    }

    func testInPlaceSerializerStreamBufferTooShort() {
        // Try to write 5 bytes into only 3 bytes of total space
        var factory = TestMutableSpanFactory([2, 1])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint32(0x0102_0304)
            try write.uint8(0xFF)
        }

        XCTAssertEqual(result, .error(.bufferTooShort))
    }

    func testInPlaceSerializerStreamMixedTypes() {
        // uint8 + uint32 NBO across fragmented spans
        var factory = TestMutableSpanFactory([2, 2, 2])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.uint8(0xAA)
            try write.uint32NetworkByteOrder(0x0102_0304)
        }

        XCTAssertEqual(result.remainingBytes, 1)
        let allBytes = factory.allBytes
        XCTAssertEqual(allBytes[0], 0xAA)
        // NBO uint32: 0x01, 0x02, 0x03, 0x04
        XCTAssertEqual(allBytes[1], 0x01)
        XCTAssertEqual(allBytes[2], 0x02)
        XCTAssertEqual(allBytes[3], 0x03)
        XCTAssertEqual(allBytes[4], 0x04)
    }

    func testInPlaceSerializerStreamRoundTrip() {
        // Write and then read back across fragmented spans

        // Write
        var writeFactory = TestMutableSpanFactory([3, 2, 3])
        let writeResult = Serializer.serialize(&writeFactory) { write throws(SerializationError) in
            try write.uint8(0xAA)
            try write.uint32(0xDEAD_BEEF)
            try write.uint16NetworkByteOrder(0xCAFE)
            try write.uint8(0xBB)
        }
        XCTAssertEqual(writeResult.remainingBytes, 0)

        // Read back
        var readFactory = TestSpanFactory(writeFactory.buffers)
        var u8_1: UInt8 = 0
        var u32: UInt32 = 0
        var u16: UInt16 = 0
        var u8_2: UInt8 = 0
        let readResult = Deserializer<TestSpanFactory>.deserialize(&readFactory) { read throws(DeserializationError) in
            try read.uint8(&u8_1)
            try read.uint32(&u32)
            try read.uint16NetworkByteOrder(&u16)
            try read.uint8(&u8_2)
        }

        XCTAssertEqual(readResult.remainingBytes, 0)
        XCTAssertEqual(u8_1, 0xAA)
        XCTAssertEqual(u32, 0xDEAD_BEEF)
        XCTAssertEqual(u16, 0xCAFE)
        XCTAssertEqual(u8_2, 0xBB)
    }

    func testInPlaceSerializerStreamVLE() {
        // Write a 2-byte VLE value across span boundary
        var factory = TestMutableSpanFactory([1, 3])

        let result = Serializer.serialize(&factory) { write throws(SerializationError) in
            try write.vle(UInt64(500))  // 500 encodes as 2-byte VLE: 0x41F4
        }

        XCTAssertEqual(result.remainingBytes, 2)
        // Verify by reading back
        var readFactory = TestSpanFactory(factory.buffers)
        var value: UInt64 = 0
        let readResult = Deserializer<TestSpanFactory>.deserialize(&readFactory) { read throws(DeserializationError) in
            try read.vle(&value)
        }
        XCTAssertEqual(readResult.remainingBytes, 2)
        XCTAssertEqual(value, 500)
    }

    // MARK: - FrameSerializer tests

    private func makeEmptyFrame(size: Int) -> Frame {
        Frame(count: size)
    }

    /// Extract all bytes from a FrameArray by reading allBytes from each frame, then finalize.
    func extractBytes(from frameArray: inout FrameArray) -> [UInt8] {
        var bytes = [UInt8]()
        frameArray.iterateMutableFrames { frame in
            if let allBytes = frame.bytes {
                allBytes.withUnsafeBytes { buffer in
                    bytes.append(contentsOf: buffer)
                }
            }
            frame.finalize(success: true)
            return true
        }
        return bytes
    }

    func testSerializeFrameArrayWithIntegers() {
        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.uint8(0xAA)
            write.uint32(0x0403_0201)
        }

        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 5)

        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xAA, 0x01, 0x02, 0x03, 0x04])
    }

    func testSerializeFrameArrayWithFrames() {
        var frame1 = makeEmptyFrame(size: 2)
        _ = Serializer.serialize(&frame1, claim: false) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(0x0102)
        }
        var frame2 = makeEmptyFrame(size: 8)
        _ = Serializer.serialize(&frame2, claim: false) { write throws(SerializationError) in
            try write.uint32NetworkByteOrder(0x0403_0201)
            try write.uint32NetworkByteOrder(0x0102_0304)
        }
        _ = frame2.claim(fromStart: 4)

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.frame(&frame1)
            write.frame(&frame2)
        }

        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        XCTAssertEqual(frameArray.count, 2)
        XCTAssertEqual(frameArray.unclaimedLength, 6)

        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x02, 0x01, 0x02, 0x03, 0x04])
    }

    func testSerializeFrameArrayWithFrameArray() {
        var frame1 = makeEmptyFrame(size: 2)
        _ = Serializer.serialize(&frame1, claim: false) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(0x0102)
        }
        var frame2 = makeEmptyFrame(size: 8)
        _ = Serializer.serialize(&frame2, claim: false) { write throws(SerializationError) in
            try write.uint32NetworkByteOrder(0x0403_0201)
            try write.uint32NetworkByteOrder(0x0102_0304)
        }
        _ = frame2.claim(fromStart: 4)

        var frameArray1 = FrameArray()
        frameArray1.add(frame: frame1)
        frameArray1.add(frame: frame2)

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.frameArray(&frameArray1)
        }

        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        XCTAssertEqual(frameArray.count, 2)
        XCTAssertEqual(frameArray.unclaimedLength, 6)

        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x02, 0x01, 0x02, 0x03, 0x04])
    }

    func testSerializeFrameArrayWithIntegersAndFrames() {
        var frame1 = makeEmptyFrame(size: 2)
        _ = Serializer.serialize(&frame1, claim: false) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(0x0102)
        }
        var frame2 = makeEmptyFrame(size: 8)
        _ = Serializer.serialize(&frame2, claim: false) { write throws(SerializationError) in
            try write.uint32NetworkByteOrder(0x0403_0201)
            try write.uint32NetworkByteOrder(0x0102_0304)
        }
        _ = frame2.claim(fromStart: 4)

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.uint8(0xAA)
            write.frame(&frame1)
            write.frame(&frame2)
            write.uint32NetworkByteOrder(0x0403_0201)
        }

        defer {
            frameArray.finalizeAllFramesAsFailed()
        }

        XCTAssertEqual(frameArray.count, 4)
        XCTAssertEqual(frameArray.unclaimedLength, 11)

        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xAA, 0x01, 0x02, 0x01, 0x02, 0x03, 0x04, 0x04, 0x03, 0x02, 0x01])
    }

    func testSerializeFrameArrayUInt16() {
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.uint16(0x0102)
            write.uint16NetworkByteOrder(0x0304)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)
        // uint16 is little-endian; uint16NetworkByteOrder is big-endian
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x02, 0x01, 0x03, 0x04])
    }

    func testSerializeFrameArrayInt16() {
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.int16(-1)  // 0xFFFF little-endian
            write.int16(0x0102)  // 0x0201 little-endian
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xFF, 0xFF, 0x02, 0x01])
    }

    func testSerializeFrameArrayUInt32() {
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.uint32(0x0403_0201)
            write.uint32NetworkByteOrder(0x0403_0201)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        // Little-endian: 01 02 03 04; Big-endian: 04 03 02 01
        XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04, 0x04, 0x03, 0x02, 0x01])
    }

    func testSerializeFrameArrayInt32() {
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.int32(-1)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testSerializeFrameArrayUInt64() {
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            write.uint64(0x0807_0605_0403_0201)
            write.uint64NetworkByteOrder(0x0807_0605_0403_0201)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 16)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(
            bytes,
            [
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,  // Little-endian
                0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,  // Big-endian
            ]
        )
    }

    func testSerializeFrameArrayVLE() {
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            write.vle(UInt64(42))  // 1-byte VLE: 0x2a
            write.vle(UInt64(200))  // 2-byte VLE: 0x40c8
            write.vle(UInt64(16384))  // 4-byte VLE: 0x80004000
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 7)  // 1 + 2 + 4
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(
            bytes,
            [
                0x2a,  // 42 in 1-byte VLE
                0x40, 0xc8,  // 200 in 2-byte VLE
                0x80, 0x00, 0x40, 0x00,  // 16384 in 4-byte VLE
            ]
        )
    }

    func testSerializeFrameArrayVLE8Byte() {
        // Values > 1073741823 require 8-byte VLE encoding
        // 8-byte VLE prefix is 0xC0 (bits 11 in top 2 bits)
        // Value 1073741824 (one above 4-byte max) encodes as:
        //   0xC000000000000000 | 1073741824 = 0xC000000040000000 big-endian
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            write.vle(UInt64(1_073_741_824))
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xC0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00])
    }

    func testSerializeFrameArrayVLEMaxUInt62() {
        // Max encodable VLE value: 2^62 - 1 = 4611686018427387903 (0x3FFFFFFFFFFFFFFF)
        // Encoded as: 0xC000000000000000 | 0x3FFFFFFFFFFFFFFF = 0xFFFFFFFFFFFFFFFF big-endian
        let maxUInt62: UInt64 = 4_611_686_018_427_387_903
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.vle(maxUInt62)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testSerializeFrameArrayVLEOverflowTruncatesToMax() {
        // Values > max UInt62 are truncated to max UInt62 (4611686018427387903)
        // UInt64.max = 0xFFFFFFFFFFFFFFFF is too large, gets clamped
        // Result should be identical to encoding max UInt62
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.vle(UInt64.max)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        // Same encoding as max UInt62
        XCTAssertEqual(bytes, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testSerializeFrameArrayVLEJustAboveMaxUInt62() {
        // 2^62 = 4611686018427387904, one above max encodable value
        // Should be truncated to max UInt62
        let justAboveMax: UInt64 = 4_611_686_018_427_387_904
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.vle(justAboveMax)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testSerializeFrameArrayVLEBoundaryValues() {
        // Test values at each VLE size boundary
        var frameArray = Serializer.serialize(frameCapacity: 64) { write in
            write.vle(UInt64(63))  // Max 1-byte: 0x3F
            write.vle(UInt64(64))  // Min 2-byte: 0x4040
            write.vle(UInt64(16383))  // Max 2-byte: 0x7FFF
            write.vle(UInt64(16384))  // Min 4-byte: 0x80004000
            write.vle(UInt64(1_073_741_823))  // Max 4-byte: 0xBFFFFFFF
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        // 1 + 2 + 2 + 4 + 4 = 13 bytes
        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 13)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(
            bytes,
            [
                0x3F,  // 63: max 1-byte
                0x40, 0x40,  // 64: min 2-byte (0x4000 | 64)
                0x7F, 0xFF,  // 16383: max 2-byte (0x4000 | 16383)
                0x80, 0x00, 0x40, 0x00,  // 16384: min 4-byte (0x80000000 | 16384)
                0xBF, 0xFF, 0xFF, 0xFF,  // 1073741823: max 4-byte (0x80000000 | 1073741823)
            ]
        )
    }

    func testSerializeFrameArrayUUID() {
        let uuid = SystemUUID([
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C,
            0x0D, 0x0E, 0x0F, 0x10,
        ])
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            write.uuid(uuid)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 16)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(
            bytes,
            [
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            ]
        )
    }

    func testSerializeFrameArrayFixedLengthUTF8() {
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            // Write "Hello" exactly (5 bytes, no padding)
            write.fixedLengthUTF8("Hello", byteCount: 5)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 5)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x48, 0x65, 0x6c, 0x6c, 0x6f])  // "Hello"
    }

    func testSerializeFrameArrayFixedLengthUTF8Truncated() {
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            // Write "Hello" into 3 bytes (truncated)
            write.fixedLengthUTF8("Hello", byteCount: 3)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 3)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x48, 0x65, 0x6c])  // "Hel"
    }

    func testSerializeFrameArrayString() {
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            // string writes uint16(length) + UTF8 bytes
            write.string("AB")
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)  // 2 bytes length + 2 bytes content
        let bytes = extractBytes(from: &frameArray)
        // uint16 length 2 in little-endian = 0x02, 0x00
        XCTAssertEqual(bytes, [0x02, 0x00, 0x41, 0x42])
    }

    func testSerializeFrameArraySpan() {
        let source: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        var resultFrameArray: FrameArray?
        source.withUnsafeBytes { ptr in
            let rawSpan = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(ptr))
            resultFrameArray = Serializer.serialize(frameCapacity: 16) { write in
                write.span(rawSpan)
            }
        }
        guard var frameArray = resultFrameArray else {
            XCTFail("No frame array created by serializer")
            return
        }
        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testSerializeFrameArrayBuffer() {
        var frameArray = Serializer.serialize(frameCapacity: 16) { write in
            write.buffer([0x01, 0x02, 0x03])
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 3)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x02, 0x03])
    }

    func testSerializeFrameArrayAllFixedTypes() {
        // Combine all fixed-size types in one serialization
        let uuid = SystemUUID([
            0xA0, 0xA1, 0xA2, 0xA3,
            0xA4, 0xA5, 0xA6, 0xA7,
            0xA8, 0xA9, 0xAA, 0xAB,
            0xAC, 0xAD, 0xAE, 0xAF,
        ])
        var frameArray = Serializer.serialize(frameCapacity: 64) { write in
            write.uint8(0x42)
            write.uint16(0x0201)
            write.int16(-256)  // 0xFF00 little-endian = 0x00, 0xFF
            write.uint32(0x0403_0201)
            write.int32(-1)
            write.uint64(0x0807_0605_0403_0201)
            write.uuid(uuid)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        // 1 + 2 + 2 + 4 + 4 + 8 + 16 = 37 bytes
        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 37)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(
            bytes,
            [
                0x42,  // uint8
                0x01, 0x02,  // uint16 LE
                0x00, 0xFF,  // int16 LE (-256)
                0x01, 0x02, 0x03, 0x04,  // uint32 LE
                0xFF, 0xFF, 0xFF, 0xFF,  // int32 LE (-1)
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,  // uint64 LE
                0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,  // UUID
                0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
            ]
        )
    }

    func testSerializeFrameArrayNetworkByteOrderTypes() {
        var frameArray = Serializer.serialize(frameCapacity: 32) { write in
            write.uint16NetworkByteOrder(0x0102)
            write.uint32NetworkByteOrder(0x0102_0304)
            write.uint64NetworkByteOrder(0x0102_0304_0506_0708)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        // 2 + 4 + 8 = 14
        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 14)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(
            bytes,
            [
                0x01, 0x02,  // uint16 NBO
                0x01, 0x02, 0x03, 0x04,  // uint32 NBO
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,  // uint64 NBO
            ]
        )
    }

    func testSerializeFrameArraySingleFrameFullyClaimed() {
        // Pass a frame where all bytes are already claimed (no unclaimed bytes)
        var frame = makeFrame(bytes: [0xAA, 0xBB, 0xCC])
        _ = frame.claim(fromStart: 3)

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.uint8(0x01)
            write.frame(&frame)
            write.uint8(0x02)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        // Frame with 0 unclaimed bytes is still added, but contributes no bytes to output
        // Pre-frame uint8 in one frame, the empty frame, post-frame uint8 in another
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x02])
    }

    func testSerializeFrameArrayFrameWithClaimedPrefix() {
        // Frame has 6 bytes, first 2 claimed, leaving 4 unclaimed
        var frame = makeEmptyFrame(size: 6)
        _ = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(0xAABB)
            try write.uint32NetworkByteOrder(0x0102_0304)
        }
        _ = frame.claim(fromStart: 2)

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.frame(&frame)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)
        let bytes = extractBytes(from: &frameArray)
        // Only the unclaimed portion: 0x01, 0x02, 0x03, 0x04
        XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04])
    }

    func testSerializeFrameArrayFrameWithClaimedSuffix() {
        // Frame has 6 bytes, last 2 claimed, leaving 4 unclaimed
        var frame = makeEmptyFrame(size: 6)
        _ = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.uint32NetworkByteOrder(0x0102_0304)
            try write.uint16NetworkByteOrder(0xCCDD)
        }
        _ = frame.claim(fromStart: 0, fromEnd: 2)

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.frame(&frame)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 4)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04])
    }

    func testSerializeFrameArrayMultipleFramesWithClaims() {
        // First frame: 4 bytes written, first 1 claimed from start
        var frame1 = makeEmptyFrame(size: 4)
        _ = Serializer.serialize(&frame1, claim: false) { write throws(SerializationError) in
            try write.uint32NetworkByteOrder(0xAABB_CCDD)
        }
        _ = frame1.claim(fromStart: 1)  // 3 unclaimed: BB CC DD

        // Second frame: 6 bytes written, last 2 claimed from end
        var frame2 = makeEmptyFrame(size: 6)
        _ = Serializer.serialize(&frame2, claim: false) { write throws(SerializationError) in
            try write.uint16NetworkByteOrder(0x0102)
            try write.uint16NetworkByteOrder(0x0304)
            try write.uint16NetworkByteOrder(0xEEFF)
        }
        _ = frame2.claim(fromStart: 0, fromEnd: 2)  // 4 unclaimed: 01 02 03 04

        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.uint8(0xFF)
            write.frame(&frame1)
            write.frame(&frame2)
            write.uint8(0x00)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        // Frame layout: [0xFF] [0xBB, 0xCC, 0xDD] [0x01, 0x02, 0x03, 0x04] [0x00]
        XCTAssertEqual(frameArray.count, 4)
        XCTAssertEqual(frameArray.unclaimedLength, 9)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xFF, 0xBB, 0xCC, 0xDD, 0x01, 0x02, 0x03, 0x04, 0x00])
    }

    func testSerializeFrameArrayMixedTypesAndFrames() {
        // Mix integers, VLE, string, buffer, span, and frames
        var innerFrame = makeEmptyFrame(size: 3)
        _ = Serializer.serialize(&innerFrame, claim: false) { write throws(SerializationError) in
            try write.buffer([0xDE, 0xAD, 0xBE])
        }

        let spanSource: [UInt8] = [0xCA, 0xFE]
        var resultFrameArray: FrameArray?
        spanSource.withUnsafeBytes { ptr in
            let rawSpan = RawSpan(_unsafeBytes: UnsafeRawBufferPointer(ptr))
            resultFrameArray = Serializer.serialize(frameCapacity: 32) { write in
                write.uint8(0x01)
                write.vle(UInt64(63))  // 1-byte VLE: 0x3F
                write.frame(&innerFrame)
                write.span(rawSpan)
                write.fixedLengthUTF8("Z", byteCount: 1)
            }
        }
        guard var frameArray = resultFrameArray else {
            XCTFail("No frame array created by serializer")
            return
        }
        defer { frameArray.finalizeAllFramesAsFailed() }

        // Layout: [0x01, 0x3F] (integers in buffer) + [0xDE, 0xAD, 0xBE] (frame)
        //       + [0xCA, 0xFE, 0x5A] (span + fixedLengthUTF8 in new buffer)
        XCTAssertEqual(frameArray.count, 3)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x3F, 0xDE, 0xAD, 0xBE, 0xCA, 0xFE, 0x5A])
    }

    func testSerializeFrameArraySingleByte() {
        var frameArray = Serializer.serialize(frameCapacity: 10) { write in
            write.uint8(0x00)  // Need at least something for result builder
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 1)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x00])
    }

    func testSerializeFrameArrayLargeBuffer() {
        // Write more than frameCapacity to verify buffer expansion
        var frameArray = Serializer.serialize(frameCapacity: 4) { write in
            write.buffer([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 1)
        XCTAssertEqual(frameArray.unclaimedLength, 8)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    func testSerializeFrameArrayConsecutiveFrames() {
        // Multiple frames passed consecutively — each becomes its own entry
        var f1 = makeFrame(bytes: [0x11])
        var f2 = makeFrame(bytes: [0x22, 0x33])
        var f3 = makeFrame(bytes: [0x44, 0x55, 0x66])

        var frameArray = Serializer.serialize(frameCapacity: 8) { write in
            write.frame(&f1)
            write.frame(&f2)
            write.frame(&f3)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        XCTAssertEqual(frameArray.count, 3)
        XCTAssertEqual(frameArray.unclaimedLength, 6)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
    }

    func testSerializeFrameArrayFrameBetweenData() {
        // Data, then frame, then more data — should produce 3 frames
        var innerFrame = makeFrame(bytes: [0xBB])

        var frameArray = Serializer.serialize(frameCapacity: 8) { write in
            write.uint16NetworkByteOrder(0xAAAA)
            write.frame(&innerFrame)
            write.uint16NetworkByteOrder(0xCCCC)
        }

        defer { frameArray.finalizeAllFramesAsFailed() }

        // [AA AA] from buffer, [BB] from frame, [CC CC] from new buffer
        XCTAssertEqual(frameArray.count, 3)
        XCTAssertEqual(frameArray.unclaimedLength, 5)
        let bytes = extractBytes(from: &frameArray)
        XCTAssertEqual(bytes, [0xAA, 0xAA, 0xBB, 0xCC, 0xCC])
    }
}
