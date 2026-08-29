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
    private var span: MutableSpan<UInt8>
    private var consumed: Bool = false

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
        // Check if we're out of spans
        guard spanIndex < spanCount else {
            return nil
        }

        let currentIndex = spanIndex

        // Advance to the next span
        spanIndex += 1

        // `bytes(at:)` is mutating: only the mutable span reliably addresses the
        // frame array's inline storage. The returned span's lifetime already
        // derives from `self.frameArray`, which satisfies this method's
        // `@_lifetime(&self)`, so no override is needed.
        return frameArray.bytes(at: currentIndex)
    }
}

#endif
