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

// MARK: - DeserializerSpanFactory

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol DeserializerSpanFactory: ~Copyable, ~Escapable {
    /// Returns the next span from the factory.
    @_lifetime(&self)
    mutating func nextSpan() -> RawSpan?

    /// The total available byte count across all spans this factory can emit.
    var availableByteCount: Int { get }
}

/// A factory that stores no spans.
///
/// Use this factory when initializing a `Deserializer` directly from a `RawSpan`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct EmptySpanFactory: ~Escapable, DeserializerSpanFactory {
    @_lifetime(immortal)
    init() {}

    @_lifetime(&self)
    public mutating func nextSpan() -> RawSpan? {
        nil
    }

    public var availableByteCount: Int {
        0
    }
}

// `EmptySpanFactory` also serves as the placeholder factory for `InPlaceSerializer`
// when it is constructed directly from a single span, bypassing Span factories for the fast path.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension EmptySpanFactory: SerializerSpanFactory {
    @_lifetime(&self)
    public mutating func nextMutableSpan() -> MutableRawSpan? {
        nil
    }
}

// MARK: - SerializerSpanFactory

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol SerializerSpanFactory: ~Copyable, ~Escapable {
    /// Returns the next mutable span from the factory.
    @_lifetime(&self)
    mutating func nextMutableSpan() -> MutableRawSpan?

    /// The total available byte count across all spans this factory can emit.
    var availableByteCount: Int { get }
}

/// A factory that stores a single mutable span.
///
/// Use this factory when initializing a `Serializer` directly from a `MutableRawSpan`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct SingleMutableSpanFactory: ~Copyable, ~Escapable, SerializerSpanFactory {
    @usableFromInline
    var span: MutableSpan<UInt8>
    private var consumed: Bool = false

    @inline(always)
    @inlinable
    @_lifetime(copy span)
    init(_ span: consuming MutableSpan<UInt8>) {
        self.span = span
    }

    @_lifetime(&self)
    public mutating func nextMutableSpan() -> MutableRawSpan? {
        guard !consumed else { return nil }
        consumed = true
        return span.mutableBytes
    }

    public var availableByteCount: Int {
        span.count
    }
}

#if !NETWORK_EMBEDDED

// MARK: - FrameArraySpanFactory

/// A span factory that walks the frames in a frame array.
///
/// Provides each frame's bytes as a span and optionally claims consumed bytes from each frame.
/// Walks the frames in a `FrameArray`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct FrameArraySpanFactory: ~Copyable, ~Escapable, DeserializerSpanFactory {
    private var frameArray: FrameArray
    private var spanIndex = 0
    private var spanCount: Int
    public private(set) var availableByteCount: Int

    /// Extracts the frame array from the factory, consuming the factory in the process.
    @usableFromInline
    consuming func takeFrameArray() -> FrameArray {
        frameArray
    }

    public mutating func drainArray(maximumByteCount: Int) -> FrameArray {
        let removedFrames = frameArray.drainArray(maximumByteCount: maximumByteCount)

        // Reset internal counters
        spanCount = frameArray.count
        availableByteCount = frameArray.unclaimedLength
        spanIndex = 0

        return removedFrames
    }

    // The factory owns the FrameArray (consumed in), so it has no external
    // lifetime dependency. @_lifetime(immortal) is correct for a self-contained
    // ~Escapable type whose data is fully owned.
    @_lifetime(immortal)
    @usableFromInline
    init(_ frameArray: consuming FrameArray) {
        self.spanCount = frameArray.count
        self.availableByteCount = frameArray.unclaimedLength
        self.frameArray = frameArray
    }

    @_lifetime(&self)
    public mutating func nextSpan() -> RawSpan? {
        // Frames without bytes are skipped, rather than ending the walk early
        while spanIndex < spanCount {
            let currentIndex = spanIndex
            spanIndex += 1
            if let span = frameArray.bytes(at: currentIndex) {
                return _overrideLifetime(span, borrowing: self)
            }
        }
        return nil
    }
}

#endif

// MARK: - Small fixed-size copies

extension MutableRawSpan {
    /// Copies `count` bytes from `source` into this span using unaligned loads and stores of 8, 4, 2 and 1 bytes,
    /// avoiding a variable-length memmove for small copies such as connection IDs.
    ///
    /// Only reachable through `copyIfInBounds`, which has already validated that `count` bytes are available at
    /// both offsets.
    @inline(always)
    private mutating func copyUnchecked(
        from source: RawSpan,
        sourceOffset: Int = 0,
        toByteOffset destinationOffset: Int = 0,
        count: Int
    ) {
        assert(
            count >= 0 && sourceOffset >= 0 && destinationOffset >= 0
                && sourceOffset &+ count <= source.byteCount
                && destinationOffset &+ count <= byteCount,
            "copyUnchecked requires `count` bytes to be available at both offsets"
        )
        var offset = 0
        while count &- offset >= 8 {
            storeBytes(
                of: source.unsafeLoadUnaligned(fromUncheckedByteOffset: sourceOffset &+ offset, as: UInt64.self),
                toUncheckedByteOffset: destinationOffset &+ offset,
                as: UInt64.self
            )
            offset &+= 8
        }
        if count & 4 != 0 {
            storeBytes(
                of: source.unsafeLoadUnaligned(fromUncheckedByteOffset: sourceOffset &+ offset, as: UInt32.self),
                toUncheckedByteOffset: destinationOffset &+ offset,
                as: UInt32.self
            )
            offset &+= 4
        }
        if count & 2 != 0 {
            storeBytes(
                of: source.unsafeLoadUnaligned(fromUncheckedByteOffset: sourceOffset &+ offset, as: UInt16.self),
                toUncheckedByteOffset: destinationOffset &+ offset,
                as: UInt16.self
            )
            offset &+= 2
        }
        if count & 1 != 0 {
            storeBytes(
                of: source.unsafeLoadUnaligned(fromUncheckedByteOffset: sourceOffset &+ offset, as: UInt8.self),
                toUncheckedByteOffset: destinationOffset &+ offset,
                as: UInt8.self
            )
        }
    }

    /// Takes the fast `copyUnchecked` path only when `count` bytes are available at both offsets.
    /// Returns `false` without copying anything otherwise, so the caller can fall back to its general path.
    @inline(always)
    @discardableResult
    mutating func copyIfInBounds(
        from source: RawSpan,
        sourceOffset: Int = 0,
        toByteOffset destinationOffset: Int = 0,
        count: Int
    ) -> Bool {
        // Offsets are checked as non-negative first, so the subtractions below cannot overflow.
        guard count >= 0, sourceOffset >= 0, destinationOffset >= 0,
            sourceOffset <= source.byteCount, destinationOffset <= byteCount,
            count <= source.byteCount &- sourceOffset,
            count <= byteCount &- destinationOffset
        else {
            return false
        }
        copyUnchecked(from: source, sourceOffset: sourceOffset, toByteOffset: destinationOffset, count: count)
        return true
    }
}
