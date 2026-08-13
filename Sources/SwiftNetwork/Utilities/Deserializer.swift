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

#if !NETWORK_EMBEDDED && canImport(Foundation)
import Foundation
#endif

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum DeserializationError: Error, CustomStringConvertible {
    case bufferTooShort
    case parsingFailed
    case validationFailed

    public var description: String {
        switch self {
        case .bufferTooShort: return "Buffer Too Short"
        case .parsingFailed: return "Parsing Failed"
        case .validationFailed: return "Validation Failed"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum DeserializationResult: CustomStringConvertible, Equatable, Sendable {
    case success(parsedBytes: Int, remainingBytes: Int)
    case error(DeserializationError)

    static let success: Self = .success(parsedBytes: 0, remainingBytes: 0)

    public var description: String {
        switch self {
        case .success(let parsedBytes, let remainingBytes):
            return "Parsed \(parsedBytes) Bytes, \(remainingBytes) Bytes Remaining"
        case .error(let error): return "Error: \(error)"
        }
    }

    var isValid: Bool {
        if case .error = self { return false }
        return true
    }

    var hasRemainingBytes: Bool {
        switch self {
        case .success(_, let remainingBytes): return remainingBytes > 0
        default: return false
        }
    }

    var remainingBytes: Int? {
        switch self {
        case .success(_, let remainingBytes): return remainingBytes
        default: return nil
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct Deserializer<Factory: DeserializerSpanFactory & ~Copyable & ~Escapable>: ~Copyable, ~Escapable {
    private var factory: Factory
    @usableFromInline var currentSpan: RawSpan
    private var availableByteCount: Int
    private var scratchSpace: [16 of UInt8]?  // Initialized lazily
    @usableFromInline var cursor = 0
    private var previousSpanAggregateByteCount = 0
    private(set) var internalResult: DeserializationResult = .success

    /// Extracts the factory from the deserializer, consuming the deserializer in the process.
    @_lifetime(copy self)
    consuming func takeFactory() -> Factory {
        factory
    }

    @_lifetime(copy factory)
    init(_ factory: consuming Factory) {
        self.availableByteCount = factory.availableByteCount
        self.factory = factory
        self.currentSpan = RawSpan()
        self.refill()
    }

    // Simple initializer for single span case with empty span factory
    @_lifetime(copy span)
    init(_ span: RawSpan) where Factory == EmptySpanFactory {
        let byteCount = span.byteCount
        self.availableByteCount = byteCount
        self.currentSpan = span
        self.factory = EmptySpanFactory()
    }

    /// Refills the deserializer with the next span from the factory, and resets the cursor and internal result so deserialization can continue.
    ///
    /// - Returns: A Boolean value that indicates whether the factory had another span available; returns `false` when no more spans remain.
    @discardableResult
    @usableFromInline
    mutating func refill() -> Bool {
        guard let span = factory.nextSpan() else {
            return false
        }
        previousSpanAggregateByteCount += cursor
        currentSpan = span
        cursor = 0
        return true
    }
    @usableFromInline
    var remaining: Int {
        // This will never be negative since cursor is only advanced
        // by moveCursor, which checks to ensure that cursor never
        // moves beyond the remaining length
        #if DEBUG
        precondition(currentSpan.byteCount >= cursor)
        #endif
        return currentSpan.byteCount - cursor
    }
    private var totalBytesParsed: Int {
        previousSpanAggregateByteCount + cursor
    }
    var finalResult: DeserializationResult {
        switch internalResult {
        case .success:
            let totalRemaining: Int
            if availableByteCount >= totalBytesParsed {
                totalRemaining = availableByteCount - totalBytesParsed
            } else {
                totalRemaining = remaining
                precondition(remaining >= 0)
            }
            return .success(parsedBytes: totalBytesParsed, remainingBytes: totalRemaining)
        case .error: return internalResult
        }
    }

    @usableFromInline
    func hasRoom(_ length: Int) -> Bool {
        (currentSpan.byteCount - cursor) >= length
    }

    @usableFromInline
    mutating func invalidate(_ error: DeserializationError) throws(DeserializationError) -> Never {
        internalResult = .error(error)
        throw error
    }

    @usableFromInline
    mutating func moveCursorUnchecked(_ amount: Int) {
        // It is safe to always add the amount to the cursor, since the length
        // was already checked. So, we use &+= which skips the more expensive
        // overflow check.
        cursor &+= amount
    }

    @usableFromInline
    mutating func moveCursor(_ amount: Int) throws(DeserializationError) {
        guard amount <= remaining else {
            try invalidate(.bufferTooShort)
        }
        moveCursorUnchecked(amount)
    }

    /// Reads a fixed-size value across span boundaries, using the stored scratch space and refilling as needed.
    ///
    /// Call this method when `hasRoom` fails but `internalResult` is still valid.
    private mutating func readFragmented<T: BitwiseCopyable>(_ value: inout T) throws(DeserializationError) {
        let length = MemoryLayout<T>.size
        precondition(length <= 16)
        if scratchSpace == nil {
            // Lazy initialize on first use
            scratchSpace = .init(repeating: 0)
        }
        var filled = 0
        while filled < length {
            let available = min(remaining, length - filled)
            for i in 0..<available {
                scratchSpace![filled + i] = currentSpan[cursor + i]
            }
            try moveCursor(available)
            filled += available
            if filled < length {
                guard refill() else {
                    try invalidate(.bufferTooShort)
                }
            }
        }
        value = scratchSpace!.span.bytes.unsafeLoadUnaligned(as: T.self)
    }

    /// Reads a fixed-size value across span boundaries, with optional network-to-host byte order conversion.
    @inline(always)
    private mutating func readFragmented<T: BitwiseCopyable & FixedWidthInteger>(
        _ value: inout T,
        networkByteOrder: Bool
    ) throws(DeserializationError) {
        try readFragmented(&value)
        if networkByteOrder {
            value = T(bigEndian: value)
        }
    }

    /// Reads a fixed-size, bitwise-copyable value, choosing the fast or fragmented path.
    ///
    /// Reads a fixed-size `BitwiseCopyable` value, using the fast path when the current
    /// span has enough data, or falling back to `readFragmented(_:)`.
    @inline(always)
    private mutating func readFixedSize<T: BitwiseCopyable>(_ value: inout T) throws(DeserializationError) {
        let length = MemoryLayout<T>.size
        guard hasRoom(length) else {
            try readFragmented(&value)
            return
        }
        value = currentSpan.unsafeLoadUnaligned(fromByteOffset: cursor, as: T.self)
        moveCursorUnchecked(length)
    }

    /// Reads an optional fixed-size, bitwise-copyable value.
    ///
    /// Reads an optional fixed-size `BitwiseCopyable` value.
    @inline(always)
    private mutating func readFixedSize<T: BitwiseCopyable & FixedWidthInteger>(
        _ value: inout T?
    ) throws(DeserializationError) {
        var tempValue: T = 0
        try readFixedSize(&tempValue)
        value = tempValue
    }

    /// Reads a fixed-size integer value with optional network-to-host byte order conversion.
    @inline(always)
    private mutating func readFixedSize<T: BitwiseCopyable & FixedWidthInteger>(
        _ value: inout T,
        networkByteOrder: Bool
    ) throws(DeserializationError) {
        try readFixedSize(&value)
        if networkByteOrder {
            value = T(bigEndian: value)
        }
    }

    /// Reads an optional fixed-size integer value with optional network-to-host byte order conversion.
    @inline(always)
    private mutating func readFixedSize<T: BitwiseCopyable & FixedWidthInteger>(
        _ value: inout T?,
        networkByteOrder: Bool
    ) throws(DeserializationError) {
        var tempValue: T = 0
        try readFixedSize(&tempValue, networkByteOrder: networkByteOrder)
        value = tempValue
    }

    @_optimize(speed)
    mutating func decodeVariableLength() throws(DeserializationError) -> (UInt64, Int) {
        // Ensure at least 1 byte is available to peek at the length prefix
        if !hasRoom(MemoryLayout<UInt8>.size) {
            guard refill() else {
                try invalidate(.bufferTooShort)
            }
        }
        let firstBits = currentSpan[cursor] >> 6
        switch firstBits {
        case 0:
            let value = UInt64(currentSpan[cursor])
            moveCursorUnchecked(MemoryLayout<UInt8>.size)
            return (value, 1)
        case 1:
            var raw: UInt16 = 0
            try readFixedSize(&raw, networkByteOrder: true)
            return (UInt64(raw & ~(1 << 14)), 2)
        case 2:
            var raw: UInt32 = 0
            try readFixedSize(&raw, networkByteOrder: true)
            return (UInt64(raw & ~(1 << 31)), 4)
        default:
            var raw: UInt64 = 0
            try readFixedSize(&raw, networkByteOrder: true)
            return (raw & ~(3 << 62), 8)
        }
    }

    static func valueMatches(lhs: UnsafeRawBufferPointer, rhs: RawSpan, rhsOffset: Int, count: Int) -> Bool {
        #if !NETWORK_EMBEDDED
        return rhs.withUnsafeBytes { rhs in
            guard let lhsBytes = lhs.baseAddress,
                let rhsBytes = rhs.baseAddress?.advanced(by: rhsOffset)
            else {
                return false
            }
            return memcmp(lhsBytes, rhsBytes, count) == 0

        }
        #else
        return rhs.withUnsafeBytes { rhs in
            lhs[0..<count].elementsEqual(rhs[rhsOffset..<rhsOffset + count])
        }
        #endif
    }

    fileprivate mutating func validateValue<T: BitwiseCopyable>(expect value: T) throws(DeserializationError) {
        let length = MemoryLayout<T>.size
        guard hasRoom(length) else {
            // Read fragmented bytes into scratch space, then compare
            var actual = value
            try readFragmented(&actual)
            let matches = withUnsafeBytes(of: value) { expectedBytes in
                withUnsafeBytes(of: actual) { actualBytes in
                    expectedBytes.elementsEqual(actualBytes)
                }
            }
            guard matches else {
                try invalidate(.validationFailed)
            }
            return
        }

        let matches = withUnsafeBytes(of: value) { expectedBytes in
            Deserializer.valueMatches(lhs: expectedBytes, rhs: currentSpan, rhsOffset: cursor, count: length)
        }
        guard matches else {
            try invalidate(.validationFailed)
        }

        moveCursorUnchecked(length)
    }

    public mutating func uint8(_ value: inout UInt8) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint8(_ value: inout UInt8?) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint8(expect value: UInt8) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func int8(_ value: inout Int8) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func int8(_ value: inout Int8?) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func int8(expect value: Int8) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func uint16(_ value: inout UInt16) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint16(_ value: inout UInt16?) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint16(expect value: UInt16) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func int16(_ value: inout Int16) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func int16(_ value: inout Int16?) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func int16(expect value: Int16) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func uint32(_ value: inout UInt32) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint32(_ value: inout UInt32?) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint32(expect value: UInt32) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func uint64(_ value: inout UInt64) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint64(_ value: inout UInt64?) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uint64(expect value: UInt64) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func uint16NetworkByteOrder(_ value: inout UInt16) throws(DeserializationError) {
        try readFixedSize(&value, networkByteOrder: true)
    }

    public mutating func uint16NetworkByteOrder(_ value: inout UInt16?) throws(DeserializationError) {
        try readFixedSize(&value, networkByteOrder: true)
    }

    public mutating func uint16NetworkByteOrder(expect value: UInt16) throws(DeserializationError) {
        try validateValue(expect: value.bigEndian)
    }

    public mutating func uint32NetworkByteOrder(_ value: inout UInt32) throws(DeserializationError) {
        try readFixedSize(&value, networkByteOrder: true)
    }

    public mutating func uint32NetworkByteOrder(_ value: inout UInt32?) throws(DeserializationError) {
        try readFixedSize(&value, networkByteOrder: true)
    }

    public mutating func uint32NetworkByteOrder(expect value: UInt32) throws(DeserializationError) {
        try validateValue(expect: value.bigEndian)
    }

    public mutating func uint64NetworkByteOrder(_ value: inout UInt64) throws(DeserializationError) {
        try readFixedSize(&value, networkByteOrder: true)
    }

    public mutating func uint64NetworkByteOrder(_ value: inout UInt64?) throws(DeserializationError) {
        try readFixedSize(&value, networkByteOrder: true)
    }

    public mutating func uint64NetworkByteOrder(expect value: UInt64) throws(DeserializationError) {
        try validateValue(expect: value.bigEndian)
    }

    public mutating func vle<T: FixedWidthInteger>(_ value: inout T) throws(DeserializationError) {
        guard let parsedValue = T(exactly: try decodeVariableLength().0) else {
            throw .parsingFailed
        }
        value = parsedValue
    }

    public mutating func vle<T: FixedWidthInteger>(_ value: inout T?) throws(DeserializationError) {
        guard let parsedValue = T(exactly: try decodeVariableLength().0) else {
            throw .parsingFailed
        }
        value = parsedValue
    }

    public mutating func vle(_ value: inout UInt64) throws(DeserializationError) {
        value = try decodeVariableLength().0
    }

    public mutating func vle(_ value: inout UInt64?) throws(DeserializationError) {
        value = try decodeVariableLength().0
    }

    public mutating func vle(expect value: UInt64) throws(DeserializationError) {
        let (decoded, _) = try decodeVariableLength()
        guard decoded == value else {
            try invalidate(.validationFailed)
        }
    }

    public mutating func vle<T: FixedWidthInteger>(expect value: T) throws(DeserializationError) {
        try vle(expect: UInt64(value))
    }

    public mutating func vleWithSize<T: FixedWidthInteger>(
        _ value: inout T,
        _ size: inout Int
    ) throws(DeserializationError) {
        let variable = try decodeVariableLength()
        value = T(variable.0)
        size = variable.1
    }

    public mutating func uuid(_ value: inout SystemUUID) throws(DeserializationError) {
        try readFixedSize(&value)
    }

    public mutating func uuid(_ value: inout SystemUUID?) throws(DeserializationError) {
        var tempValue = SystemUUID.empty
        try readFixedSize(&tempValue)
        value = tempValue
    }

    public mutating func uuid(expect value: SystemUUID) throws(DeserializationError) {
        try validateValue(expect: value)
    }

    public mutating func fixedLengthUTF8(_ value: inout String, byteCount: Int) throws(DeserializationError) {
        guard byteCount > 0 else {
            return
        }

        guard hasRoom(byteCount) else {
            // Allocate scratch space and read across spans
            var scratch = [UInt8](repeating: 0, count: byteCount)
            var filled = 0
            while filled < byteCount {
                let available = min(remaining, byteCount - filled)
                if available > 0 {
                    for i in 0..<available {
                        scratch[filled + i] = currentSpan[cursor + i]
                    }
                    try moveCursor(available)
                    filled += available
                }
                if filled < byteCount {
                    guard refill() else {
                        try invalidate(.bufferTooShort)
                    }
                }
            }
            let scratchSpan = Span<UInt8>(_bytes: scratch.span.bytes)
            guard let utf8Span = try? UTF8Span(validating: scratchSpan) else {
                try invalidate(.parsingFailed)
            }
            value = String(copying: utf8Span)

            // Treat as a C string: truncate at the first null byte
            let utf8 = value.utf8
            if let firstNull = utf8.firstIndex(of: 0),
                let truncatedString = String(utf8[..<firstNull])
            {
                value = truncatedString
            }
            return
        }

        let span = Span<UInt8>(_bytes: currentSpan.extracting(cursor..<(cursor + byteCount)))
        guard let utf8Span = try? UTF8Span(validating: span) else {
            try invalidate(.parsingFailed)
        }
        value = String(copying: utf8Span)

        // Treat as a C string: truncate at the first null byte
        let utf8 = value.utf8
        if let firstNull = utf8.firstIndex(of: 0),
            let truncatedString = String(utf8[..<firstNull])
        {
            value = truncatedString
        }

        moveCursorUnchecked(byteCount)
    }

    public mutating func fixedLengthUTF8(_ value: inout String?, byteCount: Int) throws(DeserializationError) {
        var tempValue = ""
        try fixedLengthUTF8(&tempValue, byteCount: byteCount)
        value = tempValue.isEmpty ? nil : tempValue
    }

    @_optimize(speed)
    @inline(always)
    public mutating func buffer(_ value: inout [UInt8], length: Int) throws(DeserializationError) {
        guard length > 0 else {
            return
        }

        guard hasRoom(length) else {
            // Append across spans directly into the array
            var filled = 0
            while filled < length {
                let available = min(remaining, length - filled)
                if available > 0 {
                    let source = currentSpan.extracting(unchecked: cursor..<(cursor + available))
                    source.withUnsafeBytes { buffer in
                        value.append(contentsOf: buffer)
                    }
                    try moveCursor(available)
                    filled += available
                }
                if filled < length {
                    guard refill() else {
                        try invalidate(.bufferTooShort)
                    }
                }
            }
            return
        }

        let source = currentSpan.extracting(unchecked: cursor..<(cursor + length))
        source.withUnsafeBytes { buffer in
            value.append(contentsOf: buffer)
        }
        moveCursorUnchecked(length)
    }

    public mutating func span(expect value: RawSpan) throws(DeserializationError) {
        let length = value.byteCount
        guard length > 0 else {
            return
        }

        // Fast fail if total available bytes across all spans is insufficient
        guard availableByteCount - totalBytesParsed >= length else {
            try invalidate(.bufferTooShort)
        }

        guard hasRoom(length) else {
            // Compare across span boundaries
            var matched = 0
            while matched < length {
                let available = min(remaining, length - matched)
                if available > 0 {
                    let matches = value.withUnsafeBytes { expectedBytes in
                        let slice = UnsafeRawBufferPointer(
                            start: expectedBytes.baseAddress! + matched,
                            count: available
                        )
                        return Deserializer.valueMatches(
                            lhs: slice,
                            rhs: currentSpan,
                            rhsOffset: cursor,
                            count: available
                        )
                    }
                    guard matches else {
                        try invalidate(.validationFailed)
                    }
                    try moveCursor(available)
                    matched += available
                }
                if matched < length {
                    guard refill() else {
                        try invalidate(.bufferTooShort)
                    }
                }
            }
            return
        }

        let matches = value.withUnsafeBytes { expectedBytes in
            Deserializer.valueMatches(lhs: expectedBytes, rhs: currentSpan, rhsOffset: cursor, count: length)
        }
        guard matches else {
            try invalidate(.validationFailed)
        }

        moveCursorUnchecked(length)
    }

    @_optimize(speed)
    public mutating func span(_ value: inout MutableSpan<UInt8>, length: Int? = nil) throws(DeserializationError) {
        let lengthToCopy: Int
        if let length {
            guard length <= value.count else {
                try invalidate(.parsingFailed)
            }
            lengthToCopy = length
        } else {
            lengthToCopy = value.count
        }

        guard lengthToCopy > 0 else {
            return
        }

        guard hasRoom(lengthToCopy) else {
            // Read across spans directly into the destination
            var filled = 0
            while filled < lengthToCopy {
                let available = min(remaining, lengthToCopy - filled)
                if available > 0 {
                    let source = currentSpan.extracting(unchecked: cursor..<(cursor + available))
                    source.withUnsafeBytes { fromBuffer in
                        value.withUnsafeMutableBytes { toBuffer in
                            let dest = UnsafeMutableRawBufferPointer(
                                start: toBuffer.baseAddress! + filled,
                                count: available
                            )
                            dest.copyMemory(from: fromBuffer)
                        }
                    }
                    try moveCursor(available)
                    filled += available
                }
                if filled < lengthToCopy {
                    guard refill() else {
                        try invalidate(.bufferTooShort)
                    }
                }
            }
            return
        }

        let source = currentSpan.extracting(unchecked: cursor..<(cursor + lengthToCopy))
        source.withUnsafeBytes { fromBuffer in
            value.withUnsafeMutableBytes { toBuffer in
                toBuffer.copyMemory(from: fromBuffer)
            }
        }

        moveCursorUnchecked(lengthToCopy)
    }

    public mutating func string(_ value: inout String) throws(DeserializationError) {
        var byteCount: UInt16 = 0
        try self.uint16(&byteCount)
        try self.fixedLengthUTF8(&value, byteCount: Int(byteCount))
    }

    public mutating func string(appendTo value: inout [String]) throws(DeserializationError) {
        var byteCount: UInt16 = 0
        try self.uint16(&byteCount)

        var string = ""
        try self.fixedLengthUTF8(&string, byteCount: Int(byteCount))

        value.append(string)
    }

    @_optimize(speed)
    @inline(always)
    public mutating func buffer(_ value: inout [UInt8]) throws(DeserializationError) {
        // Drain the current span and all subsequent spans
        repeat {
            if remaining > 0 {
                let source = currentSpan.extracting(droppingFirst: cursor)
                source.withUnsafeBytes { buffer in
                    value.append(contentsOf: buffer)
                }
                cursor = currentSpan.byteCount
            }
        } while refill()
    }

    public mutating func skip(_ length: Int) throws(DeserializationError) {
        guard hasRoom(length) else {
            var skipped = 0
            while skipped < length {
                let available = min(remaining, length - skipped)
                try moveCursor(available)
                skipped += available
                if skipped < length {
                    guard refill() else {
                        try invalidate(.bufferTooShort)
                    }
                }
            }
            return
        }

        moveCursorUnchecked(length)
    }

    private static func deserialize(
        _ factory: consuming Factory,
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult {
        var deserializer = Deserializer(factory)
        do {
            try builder(&deserializer)
        } catch {
            // Error already recorded in internalResult via invalidate
        }
        return deserializer.finalResult
    }

    public static func deserialize(
        _ factory: inout Factory,
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult {
        var deserializer = Deserializer(factory)
        do {
            try builder(&deserializer)
        } catch {
            // Error already recorded in internalResult via invalidate
        }
        let result = deserializer.finalResult
        factory = deserializer.takeFactory()
        return result
    }

    public static func deserialize(
        _ span: RawSpan,
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult where Factory == EmptySpanFactory {
        var deserializer = Deserializer(span)
        do {
            try builder(&deserializer)
        } catch {
            // Error already recorded in internalResult via invalidate
        }
        return deserializer.finalResult
    }

    public static func deserialize(
        _ buffer: Span<UInt8>,
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult where Factory == EmptySpanFactory {
        deserialize(buffer.bytes, builder)
    }

    public static func deserialize(
        _ bytes: [UInt8],
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult where Factory == EmptySpanFactory {
        deserialize(bytes.span.bytes, builder)
    }

    static func deserialize(
        _ bytes: inout [UInt8],
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult where Factory == EmptySpanFactory {
        let result = deserialize(bytes.span.bytes, builder)
        if case .success(let parsedBytes, _) = result {
            bytes = Array(bytes[parsedBytes...])
        }
        return result
    }

    @_optimize(speed)
    public static func deserialize(
        _ frame: inout Frame,
        claim: Bool,
        _ builder: (_ buffer: inout Deserializer) throws(DeserializationError) -> Void
    ) -> DeserializationResult where Factory == EmptySpanFactory {
        var result: DeserializationResult = .success
        if let bytes = frame.bytes {
            result = deserialize(bytes, builder)
        }
        if claim, case .success(let parsedBytes, _) = result {
            guard frame.claim(fromStart: parsedBytes) else {
                return .error(.bufferTooShort)
            }
        }
        return result
    }

    #if !NETWORK_EMBEDDED
    @_optimize(speed)
    public static func deserialize(
        _ frameArray: inout FrameArray,
        claim: Bool,
        removeClaimedFrames: Bool,
        _ builder: (_ buffer: inout Deserializer<FrameArraySpanFactory>) throws(DeserializationError) -> Void
    ) -> DeserializationResult where Factory == FrameArraySpanFactory {
        guard frameArray.count > 0 else {
            return .error(.bufferTooShort)
        }

        var factory = FrameArraySpanFactory(consume frameArray)
        let result = deserialize(&factory, builder)
        frameArray = factory.takeFrameArray()

        if claim, case .success(let parsedBytes, _) = result {
            guard frameArray.claim(fromStart: parsedBytes, removeClaimedFrames: removeClaimedFrames) else {
                return .error(.bufferTooShort)
            }
        }

        return result
    }
    #endif
}
