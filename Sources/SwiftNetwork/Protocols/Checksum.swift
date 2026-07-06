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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

extension UInt64 {
    func foldTo16() -> UInt16 {
        var sum = self
        sum = (sum >> 32) &+ (sum & 0xffff_ffff)  // 33-bit
        sum = (sum >> 16) &+ (sum & 0xffff)  // 17-bit + carry
        sum = (sum >> 16) &+ (sum & 0xffff)  // 16-bit + carry
        sum = (sum >> 16) &+ (sum & 0xffff)  // final carry
        return UInt16(sum & 0xffff)
    }
}

extension UInt32 {
    func foldTo16() -> UInt16 {
        var sum = self
        sum = (sum >> 16) &+ (sum & 0xffff)  // 17-bit + carry
        sum = (sum >> 16) &+ (sum & 0xffff)  // 16-bit + carry
        sum = (sum >> 16) &+ (sum & 0xffff)  // final carry
        return UInt16(sum & 0xffff)
    }
}

extension UInt32 {
    mutating func appendingIPv6AddressElement(_ element: UInt32, dropLowerBytes: Bool = false) {
        self &+= UInt32(UInt16(truncatingIfNeeded: element))
        if !dropLowerBytes {
            self &+= UInt32(UInt16(truncatingIfNeeded: element >> 16))
        }
    }
}

enum ChecksumError: Error {
    case invalidLength
    case invalidBuffer
}

struct ChecksumFlags: OptionSet {
    let rawValue: UInt8
    static let partial = ChecksumFlags(rawValue: 0x01)
    static let zeroInvert = ChecksumFlags(rawValue: 0x02)
    static let ip = ChecksumFlags(rawValue: 0x04)
    static let tcpIPv4 = ChecksumFlags(rawValue: 0x08)
    static let udpIPv4 = ChecksumFlags(rawValue: 0x10)
    static let tcpIPv6 = ChecksumFlags(rawValue: 0x20)
    static let udpIPv6 = ChecksumFlags(rawValue: 0x40)
}

struct InterfaceChecksumFlags: OptionSet {
    let rawValue: UInt32
    static let csumUDPIPv4 = InterfaceChecksumFlags(rawValue: 0x0000_0004)
    static let csumUDPIPv6 = InterfaceChecksumFlags(rawValue: 0x0000_0040)
}

@available(Network 0.1.0, *)
extension IPv6Address {
    func checksum() -> UInt32 {
        let address = self.addressValue
        var sum: UInt32 = 0
        sum.appendingIPv6AddressElement(address.0, dropLowerBytes: self.isScopeEmbedded)
        sum.appendingIPv6AddressElement(address.1)
        sum.appendingIPv6AddressElement(address.2)
        sum.appendingIPv6AddressElement(address.3)
        return sum
    }
}

@available(Network 0.1.0, *)
struct Checksum: ~Copyable {

    // Compute IPv6 pseudo-header checksum
    static func ipv6PseudoHeader(
        source: IPv6Address,
        dest: IPv6Address,
        length: UInt32,
        ipProtocolNumber: UInt32,
        existingChecksum: UInt32 = 0
    ) -> UInt16 {
        let checksum = source.checksum() &+ dest.checksum() &+ (length + ipProtocolNumber).bigEndian &+ existingChecksum
        return checksum.foldTo16()
    }

    // Compute IPv4 pseudo-header checksum
    static func ipv4PseudoHeader(
        source: IPv4Address,
        dest: IPv4Address,
        length: UInt32,
        ipProtocolNumber: UInt32,
        existingChecksum: UInt32 = 0
    ) -> UInt16 {
        var firstSum =
            UInt64(source.addressValue) &+ UInt64(dest.addressValue) &+ UInt64((length &+ ipProtocolNumber).bigEndian)
            &+ UInt64(existingChecksum)
        // Reduce to 16-bit and return to caller
        var secondSum = withUnsafeBytes(of: &firstSum) {
            let uint16Array = $0.bindMemory(to: UInt16.self)
            return UInt32(uint16Array[0]) &+ UInt32(uint16Array[1]) &+ UInt32(uint16Array[2]) &+ UInt32(uint16Array[3])
        }
        let thirdSum = withUnsafeBytes(of: &secondSum) {
            let uint16Array = $0.bindMemory(to: UInt16.self)
            return UInt64(uint16Array[0]) &+ UInt64(uint16Array[1])
        }
        return thirdSum.foldTo16()
    }
}

@available(Network 0.1.0, *)
extension Frame {
    func checksum16(offset: Int, length: Int) throws(ChecksumError) -> UInt16 {
        let frameLength = self.unclaimedLength
        guard offset <= frameLength else {
            Logger.proto.fault("Offset \(offset) > frame length \(frameLength) in checksum16")
            throw ChecksumError.invalidLength
        }

        guard length <= (frameLength - offset) else {
            Logger.proto.fault(
                "Checksum length \(length) > effective frame length \(frameLength - offset) in checksum16"
            )
            throw ChecksumError.invalidLength
        }

        guard let buffer = self.bytes else {
            Logger.proto.info("Frame is no longer valid in checksum16")
            throw ChecksumError.invalidBuffer
        }

        return buffer.withUnsafeBytes { buffer in
            let offsetBuffer = UnsafeRawBufferPointer(start: buffer.baseAddress!.advanced(by: offset), count: length)
            return offsetBuffer.checksum16()
        }
    }

    func ipChecksum(offset: Int, length: Int) throws(ChecksumError) -> UInt16 {
        let value = try self.checksum16(offset: offset, length: length)
        return ((~value) & 0xffff)
    }

    mutating func setInternetChecksum(flags: ChecksumFlags, startOffset: UInt16, checksumOffset: UInt16) -> Bool {
        checksumOffloadFlags |= flags.rawValue
        return false
    }

    mutating func finalizeIPChecksum(checksumOffset: Int, zeroInvert: Bool) throws(ChecksumError) {
        let unclaimedLength = self.unclaimedLength
        if unclaimedLength == 0 {
            throw ChecksumError.invalidBuffer
        }
        var checksum = try self.ipChecksum(offset: 0, length: self.unclaimedLength)
        if checksum == 0 && zeroInvert {
            checksum = 0xffff
        }
        let result = Serializer.serialize(&self, claim: false) { write throws(SerializationError) in
            try write.skip(checksumOffset)
            try write.uint16(checksum)
        }
        guard result.isValid else {
            throw ChecksumError.invalidBuffer
        }
    }
}

extension UnsafeRawBufferPointer {
    func checksum16() -> UInt16 {
        let divisibleBuffer: UnsafeRawBufferPointer
        let remainderBuffer: UnsafeRawBufferPointer?
        if self.count % MemoryLayout<UInt32>.size != 0 {
            // Need to extract a remainder
            let divisibleCount = (self.count / MemoryLayout<UInt32>.size) * MemoryLayout<UInt32>.size
            let remainder = self.count - divisibleCount
            divisibleBuffer = UnsafeRawBufferPointer(start: self.baseAddress!, count: divisibleCount)
            remainderBuffer = UnsafeRawBufferPointer(
                start: self.baseAddress!.advanced(by: divisibleCount),
                count: remainder
            )
        } else {
            divisibleBuffer = self
            remainderBuffer = nil
        }
        var partial = divisibleBuffer.withMemoryRebound(to: UInt32.self) { elements in
            elements.reduce(into: UInt64(0)) { $0 &+= UInt64($1) }
        }

        if let remainderBuffer = remainderBuffer {
            if remainderBuffer.count == 3 {
                partial &+= UInt64(remainderBuffer.load(as: UInt16.self))
                partial &+= UInt64(remainderBuffer[2])
            } else if remainderBuffer.count == 2 {
                partial &+= UInt64(remainderBuffer.load(as: UInt16.self))
            } else {
                partial &+= UInt64(remainderBuffer[0])
            }
        }
        var sum: UInt64 = (UInt64(partial) >> 32) &+ UInt64(partial & 0xffff_ffff)
        sum = (sum >> 32) &+ (sum & 0xffff_ffff)

        var finalAccumulator: UInt32 =
            UInt32(sum >> 48) &+ UInt32((sum >> 32) & 0xffff) &+ UInt32((sum >> 16) & 0xffff) &+ UInt32(sum & 0xffff)
        finalAccumulator = (finalAccumulator >> 16) &+ (finalAccumulator & 0xffff)
        finalAccumulator = (finalAccumulator >> 16) &+ (finalAccumulator & 0xffff)

        return UInt16(truncatingIfNeeded: finalAccumulator)
    }
}
