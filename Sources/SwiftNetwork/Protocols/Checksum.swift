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

@usableFromInline
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
    static let udpIPv4 = InterfaceChecksumFlags(rawValue: 0x0000_0004)
    static let udpIPv6 = InterfaceChecksumFlags(rawValue: 0x0000_0040)
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
    @usableFromInline
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

    @inlinable
    @inline(always)
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
    /// The one's-complement sum of the buffer's 16-bit words in native byte order, folded to 16 bits. An odd final
    /// byte is padded with a zero byte after it.
    @available(Network 0.1.0, *)
    @inlinable
    @inline(always)
    func checksum16() -> UInt16 {
        guard let baseAddress else { return 0 }
        let byteCount = count

        // `x + rotate(x, half)` leaves the end-around-carry sum of the two halves in the top half.
        @inline(always)
        func fold(_ sum: UInt64) -> UInt16 {
            let sum32 = UInt32(truncatingIfNeeded: (sum &+ ((sum &<< 32) | (sum &>> 32))) &>> 32)
            return UInt16(truncatingIfNeeded: (sum32 &+ ((sum32 &<< 16) | (sum32 &>> 16))) &>> 16)
        }

        if byteCount < 8 {
            // Two overlapping loads, assembled into one little-endian word.
            var word: UInt64 = 0
            if byteCount >= 4 {
                let low = UInt32(littleEndian: baseAddress.loadUnaligned(as: UInt32.self))
                let high = UInt32(
                    littleEndian: baseAddress.loadUnaligned(fromByteOffset: byteCount &- 4, as: UInt32.self)
                )
                word = UInt64(low) | ((UInt64(high) &>> UInt64(truncatingIfNeeded: (8 &- byteCount) &* 8)) &<< 32)
            } else if byteCount >= 2 {
                let low = UInt16(littleEndian: baseAddress.loadUnaligned(as: UInt16.self))
                let high = UInt16(
                    littleEndian: baseAddress.loadUnaligned(fromByteOffset: byteCount &- 2, as: UInt16.self)
                )
                word = UInt64(low) | ((UInt64(high) &>> UInt64(truncatingIfNeeded: (4 &- byteCount) &* 8)) &<< 16)
            } else if byteCount == 1 {
                word = UInt64(baseAddress.load(as: UInt8.self))
            }
            return fold(word.littleEndian)
        }

        var sum: UInt64 = 0
        var carry: UInt64 = 0
        var cursor = baseAddress

        // Adds the word at `offset` from `cursor` and the incoming carry, at 128 bits; the high word is the carry out.
        // A run of these compiles to one add-with-carry chain.
        @inline(always)
        func addWord(at offset: Int) {
            let word = cursor.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            let total = UInt128(sum) &+ UInt128(word) &+ UInt128(carry)
            sum = UInt64(truncatingIfNeeded: total)
            carry = UInt64(truncatingIfNeeded: total &>> 64)
        }

        // Ends a chain. A chain that carries out leaves at most 2^64 - 2 behind, so adding the carry back cannot wrap.
        @inline(always)
        func addCarry() {
            sum &+= carry
            carry = 0
        }

        // Within each block the words at offsets 0 and 8 are read last, so the pointer bump folds into their load.
        let blockEnd = baseAddress + (byteCount & ~63)
        while cursor != blockEnd {
            addWord(at: 16)
            addWord(at: 24)
            addWord(at: 32)
            addWord(at: 40)
            addWord(at: 48)
            addWord(at: 56)
            addWord(at: 0)
            addWord(at: 8)
            addCarry()
            cursor += 64
        }
        if byteCount & 32 != 0 {
            addWord(at: 16)
            addWord(at: 24)
            addWord(at: 0)
            addWord(at: 8)
            addCarry()
            cursor += 32
        }
        if byteCount & 16 != 0 {
            addWord(at: 0)
            addWord(at: 8)
            addCarry()
            cursor += 16
        }
        if byteCount & 8 != 0 {
            addWord(at: 0)
            addCarry()
        }

        // The last `byteCount % 8` bytes are the top of the buffer's last eight and start a multiple of eight bytes
        // from the start, so shifting them to the bottom of a little-endian word keeps their 16-bit pairing.
        let trailingCount = byteCount & 7
        if trailingCount != 0 {
            cursor = baseAddress + (byteCount &- 8)
            let last = UInt64(littleEndian: cursor.loadUnaligned(as: UInt64.self))
            let trailing = (last &>> UInt64(truncatingIfNeeded: (8 &- trailingCount) &* 8)).littleEndian
            let (partial, overflow) = sum.addingReportingOverflow(trailing)
            sum = partial &+ (overflow ? 1 : 0)
        }
        return fold(sum)
    }
}

// Hardware assist flags from xnu.
enum IfnetHardwareAssistFlags {
    static let ifnetIPHeader: UInt32 = 0x0001  // IFNET_CSUM_IP
    static let ifnetTCP: UInt32 = 0x0002  // IFNET_CSUM_TCP
    static let ifnetTCPIPv6: UInt32 = 0x0020  // IFNET_CSUM_TCPIPV6
    static let ifnetPartial: UInt32 = 0x1000  // IFNET_CSUM_PARTIAL
}
