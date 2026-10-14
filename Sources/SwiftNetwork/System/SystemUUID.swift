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

#if canImport(Synchronization)
internal import Synchronization
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct SystemUUID: Hashable, Equatable, CustomStringConvertible, Sendable, BitwiseCopyable {

    internal typealias UUIDStorage = [16 of UInt8]

    internal let storage: UUIDStorage

    internal init(_ storage: UUIDStorage) {
        self.storage = storage
    }

    static public let empty = SystemUUID(UUIDStorage(repeating: 0x00))

    static public func == (lhs: SystemUUID, rhs: SystemUUID) -> Bool {
        for i in 0..<lhs.storage.count {
            if lhs.storage[i] != rhs.storage[i] {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for i in 0..<storage.count {
            hasher.combine(storage[i])
        }
    }

    public var span: Span<UInt8> {
        @_lifetime(borrow self)
        get {
            storage.span
        }
    }

    public init(_ span: Span<UInt8>) throws(NetworkError) {
        guard span.count == 16 else { throw NetworkError.posix(EINVAL) }
        var storage = UUIDStorage(repeating: 0x00)
        for i in 0..<16 {
            storage[i] = span[i]
        }
        self.storage = storage
    }

    /// Returns a string representation of the UUID.
    ///
    /// For example, `E621E1F8-C36C-495A-93FC-0C247A3E6E5F`.
    public var description: String {
        var result = ""
        for i in 0..<storage.count {
            if i == 4 || i == 6 || i == 8 || i == 10 {
                result.append("-")
            }
            let string = String(storage[i], radix: 16, uppercase: true)
            if string.utf8.count == 1 {
                result.append("0")
            }
            result.append(string)
        }
        return result
    }

    public var uuidString: String {
        description
    }

    /// Creates a UUID from its canonical hyphenated string form (e.g.
    /// `E621E1F8-C36C-495A-93FC-0C247A3E6E5F`), or nil when `uuidString` is not 36
    /// characters in the 8-4-4-4-12 hexadecimal layout.
    public init?(uuidString: String) {
        let ascii = Array(uuidString.utf8)
        guard ascii.count == 36 else { return nil }
        var storage = UUIDStorage(repeating: 0x00)
        var byteIndex = 0
        var i = 0
        while i < 36 {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                guard ascii[i] == UInt8(ascii: "-") else { return nil }
                i += 1
                continue
            }
            guard let high = SystemUUID.hexNibble(ascii[i]),
                let low = SystemUUID.hexNibble(ascii[i + 1])
            else { return nil }
            storage[byteIndex] = (high << 4) | low
            byteIndex += 1
            i += 2
        }
        self.storage = storage
    }

    private static func hexNibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return ascii - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return ascii - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    static internal let insecureUUIDValue = NetworkMutex<UInt128>(0)
    static var nextInsecureUUIDValue: UInt128 {
        var value: UInt128 = 0
        insecureUUIDValue.withLock {
            if $0 == 0 || $0 == UInt128.max {
                $0 = UInt128.randomUUIDValue
            }
            value = $0
            $0 += 1
        }
        return value
    }

    public init(insecure: Bool = false) {
        var storage = UUIDStorage(repeating: 0x00)

        let uuidValueNumber: UInt128
        if insecure {
            uuidValueNumber = SystemUUID.nextInsecureUUIDValue
        } else {
            uuidValueNumber = UInt128.randomUUIDValue
        }
        for i in (0..<16).reversed() {
            let byte = UInt8((uuidValueNumber >> (i * 8)) & 0xFF)
            storage[i] = byte
        }

        self.storage = storage
    }

    public var isUUIDNULL: Bool {
        self == Self.empty
    }
}

// Availability due to Swift's `UInt128.random(in:)` (introduced in Swift 6.0 / iOS 18 / macOS 15)
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension UInt128 {
    static var randomUUIDValue: UInt128 {
        let random = UInt128.random(in: 1...UInt128.max)
        return random.withUUIDMaskApplied
    }

    var withUUIDMaskApplied: UInt128 {
        let originalValue = self

        // Apply UUID version 4 format (byte 6) and variant (byte 8) directly on UInt128
        // Byte 6 is at bits 48-55 (from LSB): Clear upper 4 bits and set to 0x4
        let intermediateValue = (originalValue & ~(UInt128(0xF0) << 48)) | (UInt128(0x40) << 48)

        // Byte 8 is at bits 64-71 (from LSB): Clear upper 2 bits and set to 0b10
        return (intermediateValue & ~(UInt128(0xC0) << 64)) | (UInt128(0x80) << 64)
    }
}

#if !NETWORK_STANDALONE
@available(Network 0.1.0, *)
extension SystemUUID: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let array = [UInt8](copying: self.span, maxCount: 16)
        try container.encode(array)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let array = try container.decode(Array<UInt8>.self)
        self = try SystemUUID(array.span)
    }
}
#endif
