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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum SerializationError: Error, CustomStringConvertible {
    case bufferTooShort
    case invalidParameter

    public var description: String {
        switch self {
        case .bufferTooShort: return "Buffer Too Short"
        case .invalidParameter: return "Invalid Parameter"
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum SerializationResult: CustomStringConvertible, Equatable, Sendable {
    case success(writtenBytes: Int, remainingBytes: Int)
    case error(SerializationError)

    @usableFromInline
    static let success: Self = .success(writtenBytes: 0, remainingBytes: 0)

    public var description: String {
        switch self {
        case .success(let writtenBytes, let remainingBytes):
            return "Wrote \(writtenBytes) Bytes, \(remainingBytes) Bytes Remaining"
        case .error(let error): return "Error: \(error)"
        }
    }

    @usableFromInline
    var isValid: Bool {
        if case .error = self { return false }
        return true
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
public enum Serializable {
    case uint8(_ value: UInt8)
    case uint16(_ value: UInt16)
    case int16(_ value: Int16)
    case uint32(_ value: UInt32)
    case int32(_ value: Int32)
    case uint64(_ value: UInt64)
    case uint16NetworkByteOrder(_ value: UInt16)
    case uint32NetworkByteOrder(_ value: UInt32)
    case uint64NetworkByteOrder(_ value: UInt64)
    case vle(_ value: UInt64)
    case uuid(_ value: SystemUUID)
    case fixedLengthUTF8(_ value: String, byteCount: Int)
    case buffer(_ value: [UInt8])
    case string(_ value: String)
    #if !NETWORK_EMBEDDED && canImport(Foundation) && !NETWORK_DRIVERKIT
    case data(_ value: any DataProtocol)
    #endif

    func serialize(into buffer: inout [UInt8]) {
        switch self {
        case .uint8(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .uint16(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .int16(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .uint32(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .int32(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .uint64(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .uint16NetworkByteOrder(let value):
            withUnsafeBytes(of: value.bigEndian) { buffer.append(contentsOf: $0) }
        case .uint32NetworkByteOrder(let value):
            withUnsafeBytes(of: value.bigEndian) { buffer.append(contentsOf: $0) }
        case .uint64NetworkByteOrder(let value):
            withUnsafeBytes(of: value.bigEndian) { buffer.append(contentsOf: $0) }
        case .vle(let value):
            value.variableLengthEncodeInto(&buffer)
        case .uuid(let value):
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        case .fixedLengthUTF8(let value, let byteCount):
            let utf8 = value.utf8
            let utf8Length = utf8.count
            if byteCount < utf8Length {
                buffer.append(contentsOf: utf8.dropLast(utf8Length - byteCount))
            } else {
                buffer.append(contentsOf: utf8)
                let extra = byteCount - utf8Length
                if extra > 0 {
                    buffer.append(contentsOf: [UInt8](repeating: 0, count: extra))
                }
            }
        case .buffer(let value):
            buffer.append(contentsOf: value)
        case .string(let value):
            let utf8 = value.utf8
            withUnsafeBytes(of: UInt16(utf8.count).littleEndian) { buffer.append(contentsOf: $0) }
            buffer.append(contentsOf: utf8)
        #if !NETWORK_EMBEDDED && !NETWORK_DRIVERKIT
        case .data(let value):
            buffer.append(contentsOf: value)
        #endif
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
@resultBuilder
public struct Serializer {
    public static func buildExpression(_ expression: UInt8) -> Serializable {
        .uint8(expression)
    }
    public static func buildExpression(_ expression: UInt16) -> Serializable {
        .uint16(expression)
    }
    public static func buildExpression(_ expression: Int16) -> Serializable {
        .int16(expression)
    }
    public static func buildExpression(_ expression: UInt32) -> Serializable {
        .uint32(expression)
    }
    public static func buildExpression(_ expression: Int32) -> Serializable {
        .int32(expression)
    }
    public static func buildExpression(_ expression: UInt64) -> Serializable {
        .uint64(expression)
    }
    public static func buildExpression(_ expression: SystemUUID) -> Serializable {
        .uuid(expression)
    }
    public static func buildExpression(_ expression: [UInt8]) -> Serializable {
        .buffer(expression)
    }
    public static func buildExpression(_ expression: Serializable) -> Serializable {
        expression
    }

    public static func buildOptional(_ components: Serializable?) -> Serializable {
        components ?? .buffer([])
    }
    public static func buildEither(first component: Serializable) -> Serializable {
        component
    }
    public static func buildEither(second component: Serializable) -> Serializable {
        component
    }
    public static func buildEither(first component: [UInt8]) -> Serializable {
        .buffer(component)
    }
    public static func buildEither(second component: [UInt8]) -> Serializable {
        .buffer(component)
    }

    public static func buildArray(_ components: [[UInt8]]) -> Serializable {
        .buffer(components.flatMap { $0 })
    }
    public static func buildArray(_ components: [Serializable]) -> Serializable {
        .buffer(buildSerializable(components))
    }

    public static func buildBlock(_ components: Serializable...) -> [UInt8] {
        buildSerializable(components)
    }
    public static func buildBlock(_ components: Serializable) -> Serializable {
        components
    }

    private static func buildSerializable(_ components: [Serializable]) -> [UInt8] {
        var buffer = [UInt8]()
        for component in components {
            component.serialize(into: &buffer)
        }
        return buffer
    }

    public func uint8(_ value: UInt8) -> Serializable {
        .uint8(value)
    }
    public func uint16(_ value: UInt16) -> Serializable {
        .uint16(value)
    }
    public func int16(_ value: Int16) -> Serializable {
        .int16(value)
    }
    public func uint32(_ value: UInt32) -> Serializable {
        .uint32(value)
    }
    public func int32(_ value: Int32) -> Serializable {
        .int32(value)
    }
    public func uint64(_ value: UInt64) -> Serializable {
        .uint64(value)
    }
    public func uint16NetworkByteOrder(_ value: UInt16) -> Serializable {
        .uint16NetworkByteOrder(value)
    }
    public func uint32NetworkByteOrder(_ value: UInt32) -> Serializable {
        .uint32NetworkByteOrder(value)
    }
    public func uint64NetworkByteOrder(_ value: UInt64) -> Serializable {
        .uint64NetworkByteOrder(value)
    }
    public func vle<T: FixedWidthInteger>(_ value: T) -> Serializable {
        .vle(UInt64(value))
    }
    public func uuid(_ value: SystemUUID) -> Serializable {
        .uuid(value)
    }
    public func fixedLengthUTF8(_ value: String, byteCount: Int) -> Serializable {
        .fixedLengthUTF8(value, byteCount: byteCount)
    }
    func string(_ value: String) -> Serializable {
        .string(value)
    }
    public func buffer(_ value: [UInt8]) -> Serializable {
        .buffer(value)
    }
    #if !NETWORK_EMBEDDED && canImport(Foundation) && !NETWORK_DRIVERKIT
    public func buffer(_ value: any DataProtocol) -> Serializable {
        .data(value)
    }
    #endif

    public static func length(@SerializeCounter _ builder: (_ serializer: inout SerializeCounter) -> Int) -> Int {
        var counter = SerializeCounter()
        return builder(&counter)
    }

    public static func serialize(@Serializer _ builder: (_ serializer: inout Serializer) -> [UInt8]) -> [UInt8] {
        var serializer = Serializer()
        return builder(&serializer)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
@resultBuilder
public struct SerializeCounter {
    public static func buildExpression(_ expression: Int) -> Int {
        expression
    }

    public static func buildOptional(_ components: Int?) -> Int {
        components ?? 0
    }
    public static func buildEither(first component: Int) -> Int {
        component
    }
    public static func buildEither(second component: Int) -> Int {
        component
    }

    public static func buildArray(_ components: [Int]) -> Int {
        components.reduce(into: Int(0)) { $0 += $1 }
    }
    public static func buildBlock() -> Int {
        0
    }

    public static func buildPartialBlock(first: Int) -> Int {
        first
    }

    public static func buildPartialBlock(accumulated: Int, next: Int) -> Int {
        accumulated + next
    }

    public func uint8(_ value: UInt8) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func uint16(_ value: UInt16) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func int16(_ value: Int16) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func uint32(_ value: UInt32) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func int32(_ value: Int32) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func uint64(_ value: UInt64) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func uint16NetworkByteOrder(_ value: UInt16) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func uint32NetworkByteOrder(_ value: UInt32) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func uint64NetworkByteOrder(_ value: UInt64) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func vle<T: FixedWidthInteger>(_ value: T) -> Int {
        value.variableLengthSize
    }

    public func vle(_ value: UInt64) -> Int {
        value.variableLengthSize
    }
    public func uuid(_ value: SystemUUID) -> Int {
        MemoryLayout.size(ofValue: value)
    }
    public func fixedLengthUTF8(_ value: String, byteCount: Int) -> Int {
        byteCount
    }
    public func buffer(_ value: [UInt8]) -> Int {
        value.count
    }
    public func buffer(length: Int) -> Int {
        length
    }
    public func string(_ value: String) -> Int {
        MemoryLayout<UInt16>.size + value.utf8.count
    }
    #if !NETWORK_EMBEDDED && canImport(Foundation)
    public func buffer(_ value: any DataProtocol) -> Int {
        value.count
    }
    #endif
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct InPlaceSerializer<Factory: SerializerSpanFactory & ~Copyable & ~Escapable>: ~Escapable, ~Copyable {
    @usableFromInline
    var factory: Factory
    @usableFromInline
    var currentSpan: MutableRawSpan
    @usableFromInline
    var currentSpanByteCount = 0
    @usableFromInline
    var availableByteCount: Int
    @usableFromInline
    var scratchSpace = [16 of UInt8](repeating: 0)
    @usableFromInline
    var cursor = 0
    @usableFromInline
    var previousSpanAggregateByteCount = 0
    @usableFromInline
    var internalResult: SerializationResult = .success

    /// Extracts the factory from the serializer, consuming the serializer in the process.
    @_lifetime(copy self)
    consuming func takeFactory() -> Factory {
        factory
    }

    @inline(always)
    @inlinable
    @_lifetime(copy factory)
    init(_ factory: consuming Factory) {
        self.availableByteCount = factory.availableByteCount
        self.factory = factory
        self.currentSpan = MutableRawSpan()
        self.refill()
    }

    /// Refills the serializer with the next span from the factory, and resets the cursor and internal result so serialization can continue.
    ///
    /// - Returns: A Boolean value that indicates whether the factory had another span available; returns `false` when no more spans remain.
    @discardableResult
    @inline(always)
    @inlinable
    mutating func refill() -> Bool {
        guard let span = factory.nextMutableSpan() else {
            return false
        }
        previousSpanAggregateByteCount &+= cursor
        currentSpan = span
        cursor = 0
        currentSpanByteCount = currentSpan.byteCount
        return true
    }
    @usableFromInline
    var totalBytesWritten: Int {
        previousSpanAggregateByteCount &+ cursor
    }
    @inline(always)
    @inlinable
    var finalResult: SerializationResult {
        switch internalResult {
        case .success:
            let totalRemaining: Int
            if availableByteCount >= totalBytesWritten {
                totalRemaining = availableByteCount - totalBytesWritten
            } else {
                totalRemaining = remaining
                precondition(remaining >= 0)
            }
            return .success(writtenBytes: totalBytesWritten, remainingBytes: totalRemaining)
        case .error: return internalResult
        }
    }
    @usableFromInline
    var remaining: Int {
        #if DEBUG
        precondition(currentSpanByteCount >= cursor)
        #endif
        return currentSpanByteCount &- cursor
    }
    @inlinable
    @inline(always)
    func hasRoom(_ length: Int) -> Bool {
        internalResult.isValid && remaining >= length
    }
    @usableFromInline
    mutating func invalidate(_ error: SerializationError) throws(SerializationError) -> Never {
        internalResult = .error(error)
        throw error
    }

    @usableFromInline
    mutating func moveCursor(_ amount: Int) throws(SerializationError) {
        guard amount <= remaining else {
            try invalidate(.bufferTooShort)
        }
        cursor &+= amount
    }

    /// Writes a fixed-size value, choosing the fast or fragmented path.
    ///
    /// Uses the fast path when the current span has enough room, or falls back to `writeFragmented(_:)`.
    @inlinable
    @inline(always)
    mutating func writeFixedSize<T: BitwiseCopyable>(_ value: T) throws(SerializationError) {
        let length = MemoryLayout<T>.size
        guard hasRoom(length) else {
            try writeFragmented(value)
            return
        }

        currentSpan.storeBytes(of: value, toByteOffset: cursor, as: T.self)
        try moveCursor(length)
    }

    /// Writes a fixed-size value across span boundaries.
    @usableFromInline
    mutating func writeFragmented<T: BitwiseCopyable>(_ value: T) throws(SerializationError) {
        let length = MemoryLayout<T>.size
        precondition(length <= 16)
        // Copy value bytes into scratch space
        withUnsafeBytes(of: value) { src in
            for i in 0..<length {
                scratchSpace[i] = src[i]
            }
        }
        // Write from scratch space across spans
        var written = 0
        while written < length {
            let available = min(remaining, length - written)
            if available > 0 {
                for i in 0..<available {
                    currentSpan.storeBytes(of: scratchSpace[written + i], toByteOffset: cursor + i, as: UInt8.self)
                }
                try moveCursor(available)
                written += available
            }
            if written < length {
                guard refill() else {
                    try invalidate(.bufferTooShort)
                }
            }
        }
    }

    @inlinable
    @inline(always)
    mutating public func uint8(_ value: UInt8) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    public mutating func uint16(_ value: UInt16) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    public mutating func int16(_ value: Int16) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    public mutating func uint32(_ value: UInt32) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    public mutating func int32(_ value: Int32) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    public mutating func uint64(_ value: UInt64) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    public mutating func uint16NetworkByteOrder(_ value: UInt16) throws(SerializationError) {
        try writeFixedSize(value.bigEndian)
    }

    @inlinable
    @inline(always)
    public mutating func uint32NetworkByteOrder(_ value: UInt32) throws(SerializationError) {
        try writeFixedSize(value.bigEndian)
    }

    @inlinable
    @inline(always)
    public mutating func uint64NetworkByteOrder(_ value: UInt64) throws(SerializationError) {
        try writeFixedSize(value.bigEndian)
    }

    @inlinable
    @inline(always)
    public mutating func vle<T: FixedWidthInteger>(_ value: T) throws(SerializationError) {
        try self.vle(UInt64(value))
    }

    @inlinable
    @inline(always)
    public mutating func vle(_ value: UInt64) throws(SerializationError) {
        var encodedValue = [1 of UInt64](repeating: 0)
        var encodedValueSpan = encodedValue.mutableSpan
        var encodedValueBytes = encodedValueSpan.mutableBytes
        var length = 0
        do throws(VariableLengthEncodingError) {
            // variableLengthEncodeInto checks for room
            length = try value.variableLengthEncodeInto(&encodedValueBytes)
        } catch {
            switch error {
            case .bufferTooShort:
                try invalidate(.bufferTooShort)
            case .invalidValue:
                try invalidate(.invalidParameter)
            }
        }
        try span(encodedValueBytes.bytes.extracting(first: length))
    }

    @inlinable
    @inline(always)
    public mutating func uuid(_ value: SystemUUID) throws(SerializationError) {
        try writeFixedSize(value)
    }

    @inlinable
    @inline(always)
    mutating public func fixedLengthUTF8(_ value: String, byteCount: Int) throws(SerializationError) {
        guard byteCount > 0 else {
            return
        }

        #if os(watchOS) && (arch(arm64_32) || arch(arm))
        // Fix for Span not being available on 32-bit watchOS
        // This surfaces when build with the arm64_32 toolchain
        // https://github.com/swiftlang/swift/blob/51b0b4aa41f28eae7d96af6f98c1fbd2b4b63958/stdlib/public/core/StringUTF8View.swift#L386
        let utf8Bytes = Array(value.utf8).span.bytes
        #else
        // Builds for watchOS 64 bit variants and all other platforms
        let utf8Bytes = value.utf8.span.bytes
        #endif
        let utf8ByteCount = utf8Bytes.byteCount
        if byteCount <= utf8ByteCount {
            try span(utf8Bytes.extracting(first: byteCount))
        } else {
            // Write string
            try span(utf8Bytes)

            // Pad with zeros
            let paddingCount = byteCount - utf8ByteCount
            let padding = [UInt8](repeating: 0, count: paddingCount)
            try span(padding.span.bytes)
        }
    }

    @inlinable
    @inline(always)
    mutating public func string(_ value: String) throws(SerializationError) {
        let utf8 = value.utf8
        try uint16(UInt16(utf8.count))
        try fixedLengthUTF8(value, byteCount: utf8.count)
    }

    @inlinable
    @inline(always)
    public mutating func span(_ source: RawSpan) throws(SerializationError) {
        let length = source.byteCount
        guard length > 0 else {
            return
        }

        var written = 0
        while written < length {
            let available = min(remaining, length - written)
            if available > 0 {
                source.withUnsafeBytes { srcBuffer in
                    currentSpan.withUnsafeMutableBytes { dstBuffer in
                        let dst = UnsafeMutableRawBufferPointer(
                            start: dstBuffer.baseAddress! + cursor,
                            count: available
                        )
                        let src = UnsafeRawBufferPointer(
                            start: srcBuffer.baseAddress! + written,
                            count: available
                        )
                        dst.copyMemory(from: src)
                    }
                }
                try moveCursor(available)
                written += available
            }
            if written < length {
                guard refill() else {
                    try invalidate(.bufferTooShort)
                }
            }
        }
    }

    @inlinable
    @inline(always)
    public mutating func buffer(_ value: [UInt8]) throws(SerializationError) {
        try span(value.span.bytes)
    }

    #if !NETWORK_EMBEDDED && canImport(Foundation)
    @inlinable
    @inline(always)
    public mutating func buffer(_ value: any DataProtocol) throws(SerializationError) {
        let array = [UInt8](value)
        try span(array.span.bytes)
    }
    #endif

    @inlinable
    @inline(always)
    public mutating func skip(_ length: Int) throws(SerializationError) {
        try moveCursor(length)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct FrameSerializer: ~Copyable {
    private var currentBuffer: NetworkUniqueArray<UInt8>? = nil
    private var cursor = 0
    private var currentBufferByteCount = 0

    private var frameArray = FrameArray()
    private let capacity: Int
    private var internalResult: SerializationResult = .success

    private mutating func convertBufferToFrame() {
        cursor = 0
        currentBufferByteCount = 0
        if currentBuffer != nil {
            var swapBuffer: NetworkUniqueArray<UInt8>?
            swapBuffer = nil
            swap(&swapBuffer, &currentBuffer)
            frameArray.add(frame: .init(bytes: swapBuffer!))
        }
    }

    /// Extracts the frame array from the serializer, consuming the serializer in the process.
    fileprivate consuming func extractFrames() -> FrameArray {
        convertBufferToFrame()
        return frameArray
    }

    private mutating func addFrame(_ frame: consuming Frame) {
        convertBufferToFrame()
        frameArray.add(frame: frame)
    }

    private mutating func withOutputSpan(length: Int, _ body: (inout OutputRawSpan) -> Void) {
        if currentBuffer == nil {
            currentBuffer = .init(minimumCapacity: capacity)
            currentBufferByteCount = capacity
            cursor = 0
        }

        currentBuffer?.append(addingCount: length) { outputSpan in
            outputSpan.append(repeating: 0, count: length)
            var mutableSpan = outputSpan.mutableSpan
            var mutableBytes = mutableSpan.mutableBytes
            mutableBytes.withUnsafeMutableBytes { buffer in
                var outputRawSpan = OutputRawSpan(buffer: buffer, initializedCount: 0)
                body(&outputRawSpan)
                cursor = outputRawSpan.byteCount
            }
        }
    }

    private var remaining: Int {
        #if DEBUG
        precondition(currentBufferByteCount >= cursor)
        #endif
        return currentBufferByteCount - cursor
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Writes a fixed-size value into an output span.
    private mutating func writeFixedSize<T: BitwiseCopyable>(_ value: T) {
        withOutputSpan(length: MemoryLayout<T>.size) { outputSpan in
            outputSpan.append(value, as: T.self)
        }
    }

    public mutating func uint8(_ value: UInt8) {
        writeFixedSize(value)
    }

    public mutating func uint16(_ value: UInt16) {
        writeFixedSize(value)
    }

    public mutating func int16(_ value: Int16) {
        writeFixedSize(value)
    }

    public mutating func uint32(_ value: UInt32) {
        writeFixedSize(value)
    }

    public mutating func int32(_ value: Int32) {
        writeFixedSize(value)
    }

    public mutating func uint64(_ value: UInt64) {
        writeFixedSize(value)
    }

    public mutating func uint16NetworkByteOrder(_ value: UInt16) {
        writeFixedSize(value.bigEndian)
    }

    public mutating func uint32NetworkByteOrder(_ value: UInt32) {
        writeFixedSize(value.bigEndian)
    }

    public mutating func uint64NetworkByteOrder(_ value: UInt64) {
        writeFixedSize(value.bigEndian)
    }

    public mutating func vle<T: FixedWidthInteger>(_ value: T) {
        self.vle(UInt64(value))
    }

    public mutating func vle(_ value: UInt64) {
        var value = value
        let length: Int
        if let fitLength = value.safeVariableLengthSize {
            length = fitLength
        } else {
            // Too big, encode the max UInt62 value instead
            value = UInt64(4_611_686_018_427_387_903)
            length = 8
        }

        withOutputSpan(length: length) { outputSpan in
            switch length {
            case 1:
                outputSpan.append(UInt8(value), as: UInt8.self)
            case 2:
                outputSpan.append(UInt16(1 << 14 | value).bigEndian, as: UInt16.self)
            case 4:
                outputSpan.append(UInt32(1 << 31 | value).bigEndian, as: UInt32.self)
            default:
                outputSpan.append(UInt64(3 << 62 | value).bigEndian, as: UInt64.self)
            }
        }
    }

    public mutating func uuid(_ value: SystemUUID) {
        writeFixedSize(value)
    }

    mutating public func fixedLengthUTF8(_ value: String, byteCount: Int) {
        guard byteCount > 0 else {
            return
        }

        #if os(watchOS) && (arch(arm64_32) || arch(arm))
        // Fix for Span not being available on 32-bit watchOS
        // This surfaces when build with the arm64_32 toolchain
        // https://github.com/swiftlang/swift/blob/51b0b4aa41f28eae7d96af6f98c1fbd2b4b63958/stdlib/public/core/StringUTF8View.swift#L386
        let utf8Bytes = Array(value.utf8).span.bytes.extracting(first: byteCount)
        #else
        // Builds for watchOS 64 bit variants and all other platforms
        let utf8Bytes = value.utf8.span.bytes.extracting(first: byteCount)
        #endif
        let extraBytes = byteCount - utf8Bytes.byteCount

        withOutputSpan(length: byteCount) { outputSpan in
            outputSpan.withUnsafeMutableBytes { mutableBuffer, _ in
                utf8Bytes.withUnsafeBytes { utf8Buffer in
                    mutableBuffer.copyMemory(from: utf8Buffer)
                }
            }
            if extraBytes > 0 {
                // Pad with zeros
                outputSpan.append(repeating: 0, count: extraBytes, as: UInt8.self)
            }
        }
    }

    public mutating func string(_ value: String) {
        let utf8 = value.utf8
        uint16(UInt16(utf8.count))
        fixedLengthUTF8(value, byteCount: utf8.count)
    }

    public mutating func span(_ value: RawSpan) {
        withOutputSpan(length: value.byteCount) { outputSpan in
            outputSpan.withUnsafeMutableBytes { toBuffer, _ in
                value.withUnsafeBytes { fromBuffer in
                    toBuffer.copyMemory(from: fromBuffer)
                }
            }
        }
    }

    public mutating func buffer(_ value: [UInt8]) {
        span(value.span.bytes)
    }

    public mutating func frame(_ frame: inout Frame) {
        addFrame(frame)
        frame = .init()
    }

    public mutating func frameArray(_ frames: inout FrameArray) {
        while let frame = frames.popFirst() {
            addFrame(frame)
        }
    }

    public mutating func frameArray(_ frames: inout FrameArray?) {
        while let frame = frames?.popFirst() {
            addFrame(frame)
        }
    }

    #if !NETWORK_EMBEDDED && canImport(Foundation)
    public mutating func buffer(_ value: any DataProtocol) {
        let array = [UInt8](value)
        span(array.span.bytes)
    }
    #endif
}

@available(Network 0.1.0, *)
extension Serializer {

    @inline(always)
    @inlinable
    public static func serialize<T: SerializerSpanFactory & ~Copyable & ~Escapable>(
        _ factory: consuming T,
        _ builder: (_ buffer: inout InPlaceSerializer<T>) throws(SerializationError) -> Void
    ) -> SerializationResult {
        var serializer = InPlaceSerializer<T>(consume factory)
        do {
            try builder(&serializer)
        } catch {
            // Error already recorded in internalResult via invalidate
        }
        return serializer.finalResult
    }

    public static func serialize<T: SerializerSpanFactory & ~Copyable & ~Escapable>(
        _ factory: inout T,
        _ builder: (_ buffer: inout InPlaceSerializer<T>) throws(SerializationError) -> Void
    ) -> SerializationResult {
        var serializer = InPlaceSerializer<T>(consume factory)
        do {
            try builder(&serializer)
        } catch {
            // Error already recorded in internalResult via invalidate
        }
        let result = serializer.finalResult
        factory = serializer.takeFactory()
        return result
    }

    public static func serialize(
        _ span: consuming MutableSpan<UInt8>,
        _ builder: (_ buffer: inout InPlaceSerializer<SingleMutableSpanFactory>) throws(SerializationError) -> Void
    ) -> SerializationResult {
        serialize(SingleMutableSpanFactory(span), builder)
    }

    @inline(always)
    @inlinable
    public static func serialize(
        _ frame: inout Frame,
        claim: Bool,
        _ builder: (_ serializer: inout InPlaceSerializer<SingleMutableSpanFactory>) throws(SerializationError) -> Void
    ) -> SerializationResult {

        var result: SerializationResult = .success
        if let mutableBytes = frame.mutableSpan {
            result = serialize(SingleMutableSpanFactory(mutableBytes), builder)
        }
        if claim, case .success(let writtenBytes, _) = result {
            guard frame.claim(fromStart: writtenBytes) else {
                return .error(.bufferTooShort)
            }
        }
        return result
    }

    public static func serialize(frameCapacity: Int, _ builder: (_ buffer: inout FrameSerializer) -> Void) -> FrameArray
    {
        var serializer = FrameSerializer(capacity: frameCapacity)
        _ = builder(&serializer)
        return serializer.extractFrames()
    }
}
