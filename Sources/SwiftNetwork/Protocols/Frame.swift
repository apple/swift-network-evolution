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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct Frame: ~Copyable {
    public enum Buffer: ~Copyable {
        case empty
        case bytes  // Stored in _bytes, a UniqueArray
        case customOwner(buffer: UnsafeMutableRawBufferPointer, owner: AnyObject)
        case customFinalizer(buffer: UnsafeMutableRawBufferPointer, finalizer: (UnsafeMutableRawBufferPointer) -> Void)
    }

    @usableFromInline
    var _bytes: UniqueArray<UInt8> = .init()
    var protocolMetadatas: UniqueArray<FrameProtocolMetadata> = .init(minimumCapacity: 0)
    /// Values few frames carry, kept out of line (see `PacketExtras`) so the common frame stays small.
    var extras = PacketExtras()
    public var buffer: Buffer

    // The fields below are in this order on purpose. `buffer` ends at an odd offset, and everything after it
    // is no bigger than a 4-byte value, so the one-byte flags and the two-byte packet info sit in the padding
    // `buffer` leaves, and the checksum, which only needs two-byte alignment, ends the frame without more.
    var flags: Flags = Flags()

    /// Service class (bits 0-2), ECN (bits 3-4), DSCP (bits 5-10), whether a DSCP is set (bit 11) and the kernel's
    /// own name for the service class if it has one (bits 12-15): what IP sets or reads on every packet.
    private var _packetInfo: UInt16 = 0

    private var _startOffset: UInt32 = 0
    private var _endOffset: UInt32 = 0
    private var _effectiveBufferLength: UInt32 = 0

    /// What the NIC is asked to do (TX) or reports it did (RX), as one or the other.
    private var _checksum: ChecksumOffload = .none

    @usableFromInline var startOffset: Int {
        @inline(always)
        get { Int(_startOffset) }
        @inline(always)
        set { _startOffset = UInt32(newValue) }
    }
    @usableFromInline var endOffset: Int {
        @inline(always)
        get { Int(_endOffset) }
        @inline(always)
        set { _endOffset = UInt32(newValue) }
    }
    @usableFromInline
    var effectiveBufferLength: Int {
        @inline(always)
        get { Int(_effectiveBufferLength) }
        @inline(always)
        set { _effectiveBufferLength = UInt32(newValue) }
    }
    /// The length of the whole packet a single-IP aggregate (LRO) frame is the head of. Only those frames
    /// carry one, so it is kept with the values that few frames carry.
    @usableFromInline
    var aggregateBufferLength: Int {
        @inline(always)
        get {
            Int(extras.read(default: 0) { $0.aggregateBufferLength })
        }
        @inline(always)
        set {
            extras.write(setsNonDefault: newValue != 0) {
                $0.aggregateBufferLength = UInt32(truncatingIfNeeded: newValue)
            }
        }
    }

    // MARK: - Initializers

    init() {
        self.buffer = .empty
        self.effectiveBufferLength = 0
    }

    public init(customBuffer: UnsafeMutableRawBufferPointer, owner: AnyObject) {
        self.buffer = .customOwner(buffer: customBuffer, owner: owner)
        self.effectiveBufferLength = self.bufferLength
    }

    public init(
        buffer: UnsafeMutableRawBufferPointer,
        finalizer: @escaping (UnsafeMutableRawBufferPointer) -> Void
    ) {
        self.buffer = .customFinalizer(buffer: buffer, finalizer: finalizer)
        self.effectiveBufferLength = self.bufferLength
    }

    public init(copyBuffer: [UInt8]) {
        self._bytes = .init(minimumCapacity: copyBuffer.count)
        self._bytes.append(copying: copyBuffer.span)
        self.buffer = .bytes
        self.effectiveBufferLength = self.bufferLength
    }

    public init(copyBuffer: Span<UInt8>) {
        self._bytes = .init(minimumCapacity: copyBuffer.count)
        self._bytes.append(copying: copyBuffer)
        self.buffer = .bytes
        self.effectiveBufferLength = self.bufferLength
    }

    init(copyBuffer: UnsafeRawBufferPointer) {
        self._bytes = .init(minimumCapacity: copyBuffer.count)
        self._bytes.append(copying: copyBuffer)
        self.buffer = .bytes
        self.effectiveBufferLength = self.bufferLength
    }

    public init(count: Int) {
        var count = count
        if count < 0 {
            // Ensure count is never negative
            count = 0
        }
        self._bytes = .init(repeating: 0, count: count)
        self.buffer = .bytes
        self.effectiveBufferLength = self.bufferLength
    }

    /// Builds a frame that takes ownership of an existing buffer.
    ///
    /// This is the counterpart to `extractBytes()`, so a protocol outside the framework can take
    /// bytes out of one frame and put them into another without copying.
    public init(bytes: consuming UniqueArray<UInt8>) {
        self._bytes = bytes
        self.buffer = .bytes
        self.effectiveBufferLength = self.bufferLength
    }

    deinit {
        guard case .empty = buffer else {
            preconditionFailure("Frame was released without being finalized")
        }
    }

    // MARK: - Byte access

    @inlinable
    @inline(always)
    public var unclaimedLength: Int {
        if effectiveBufferLength == 0 { return 0 }
        return effectiveBufferLength - (startOffset + endOffset)
    }

    @inlinable
    @inline(always)
    public var span: Span<UInt8>? {
        @_lifetime(borrow self)
        get {
            guard isValid else { return nil }
            switch buffer {
            case .bytes:
                return _bytes.span.extracting(startOffset..<(effectiveBufferLength - endOffset))
            default:
                guard let unsafeUnclaimedBuffer else {
                    return nil
                }
                let unsafeUnclaimedBytes = unsafeUnclaimedBuffer.bindMemory(to: UInt8.self)
                return _overrideLifetime(unsafeUnclaimedBytes.span, borrowing: self)
            }
        }
    }

    @inlinable
    @inline(always)
    public var bytes: RawSpan? {
        @_lifetime(borrow self)
        get {
            guard isValid else { return nil }
            switch buffer {
            case .bytes:
                return _bytes.span.extracting(startOffset..<(effectiveBufferLength - endOffset)).bytes
            default:
                guard let unsafeUnclaimedBuffer else {
                    return nil
                }
                return _overrideLifetime(unsafeUnclaimedBuffer.bytes, borrowing: self)
            }
        }
    }

    @inlinable
    @inline(always)
    public var mutableSpan: MutableSpan<UInt8>? {
        @_lifetime(&self)
        mutating get {
            guard isValid else { return nil }
            switch buffer {
            case .bytes:
                let start = startOffset
                let end = effectiveBufferLength - endOffset
                return _bytes.mutableSpan._consumingExtracting(start..<end)
            default:
                break
            }
            guard let unsafeUnclaimedBuffer else {
                return nil
            }
            let unsafeUnclaimedBytes = unsafeUnclaimedBuffer.bindMemory(to: UInt8.self)
            return _overrideLifetime(unsafeUnclaimedBytes.mutableSpan, mutating: &self)
        }
    }

    @inlinable
    @inline(always)
    var allBytes: RawSpan? {
        guard isValid else { return nil }
        switch buffer {
        case .bytes:
            return _bytes.span.bytes
        default:
            guard let unsafeBuffer else {
                return nil
            }
            return _overrideLifetime(unsafeBuffer.bytes, borrowing: self)
        }
    }

    public var bufferLength: Int {
        switch buffer {
        case .bytes:
            return _bytes.count
        default:
            guard let unsafeBuffer else {
                return 0
            }
            return unsafeBuffer.count
        }
    }

    /// Claims the first `length` unclaimed bytes into a frame of their own that shares this frame's
    /// storage, so nothing is copied; the storage stays alive as long as either frame does.
    ///
    /// Only a frame whose storage has a custom owner can share it: `nil` for any other, and for a
    /// frame with fewer than `length` unclaimed bytes.
    mutating func claimSharedBytes(_ length: Int) -> Frame? {
        guard length >= 0, length <= unclaimedLength else { return nil }
        var shared: Frame
        switch buffer {
        case .customOwner(let storage, let owner):
            shared = Frame(customBuffer: storage, owner: owner)
        default:
            return nil
        }
        let behindTheBytes = endOffset + unclaimedLength - length
        guard shared.claim(fromStart: startOffset, fromEnd: behindTheBytes, adjustSingleIPAggregate: false),
            claim(fromStart: length)
        else {
            shared.finalize(success: false)
            return nil
        }
        return shared
    }

    // Only unclaimed bytes in frame, for unsafe types
    @usableFromInline
    var unsafeUnclaimedBuffer: UnsafeMutableRawBufferPointer? {
        switch buffer {
        case .empty:
            return nil
        case .bytes:
            return nil
        case .customOwner(let buffer, _):
            return UnsafeMutableRawBufferPointer(
                start: buffer.baseAddress!.advanced(by: startOffset),
                count: unclaimedLength
            )
        case .customFinalizer(let buffer, _):
            return UnsafeMutableRawBufferPointer(
                start: buffer.baseAddress!.advanced(by: startOffset),
                count: unclaimedLength
            )
        }
    }

    // All bytes in frame, including claimed bytes, for unsafe types
    @usableFromInline
    var unsafeBuffer: UnsafeMutableRawBufferPointer? {
        switch buffer {
        case .empty:
            return nil
        case .bytes:
            return nil
        case .customOwner(let buffer, _):
            return buffer
        case .customFinalizer(let buffer, _):
            return buffer
        }
    }

    @inline(always)
    public var isValid: Bool {
        switch buffer {
        default: return true
        }
    }

    var bufferTypeDescription: String {
        switch buffer {
        case .empty: return "empty"
        case .bytes: return "bytes"
        case .customOwner: return "customOwner"
        case .customFinalizer: return "customFinalizer"
        }
    }

    @_optimize(speed)
    public mutating func claim(fromStart: Int, fromEnd: Int = 0, adjustSingleIPAggregate: Bool = true) -> Bool {
        if adjustSingleIPAggregate && isSingleIPAggregate {
            guard fromEnd == 0 else {
                outlinedProtoLogError("Trying to claim bytes at the end of a single-IP aggregate", fromEnd)
                return false
            }
            aggregateBufferLength -= fromStart
        }

        let newStart = startOffset + fromStart
        let newEnd = endOffset + fromEnd
        guard newStart <= effectiveBufferLength - newEnd else {
            let effectiveLength = effectiveBufferLength
            outlinedProtoLogError(
                "Claiming bytes failed, start is beyond end; start, effective length, end",
                newStart,
                effectiveLength,
                newEnd
            )
            return false
        }

        startOffset = newStart
        endOffset = newEnd
        return true
    }

    mutating func resetClaims() {
        startOffset = 0
        endOffset = 0
    }

    public mutating func unclaim(fromStart: Int, fromEnd: Int = 0, adjustSingleIPAggregate: Bool = true) -> Bool {
        if adjustSingleIPAggregate && isSingleIPAggregate {
            guard fromEnd == 0 else {
                outlinedProtoLogError("Trying to unclaim bytes at the end of a single-IP aggregate", fromEnd)
                return false
            }
            aggregateBufferLength += fromStart
        }

        guard fromStart <= startOffset else {
            let startOffset = startOffset
            outlinedProtoLogError("Frame cannot unclaim start bytes; requested, remaining", fromStart, startOffset)
            return false
        }

        guard fromEnd <= endOffset else {
            let endOffset = endOffset
            outlinedProtoLogError("Frame cannot unclaim end bytes; requested, remaining", fromEnd, endOffset)
            return false
        }

        startOffset -= fromStart
        endOffset -= fromEnd
        return true
    }

    public mutating func collapse() {
        let unclaimedLength = self.unclaimedLength
        let startOffset = startOffset
        guard unclaimedLength > 0 else {
            // Ignore if there are no unclaimed bytes
            return
        }

        let endOffset = endOffset
        if endOffset > 0 {
            var unsafeBuffer: UnsafeMutableRawBufferPointer?
            var accessBytes = false
            switch buffer {
            case .bytes:
                accessBytes = true
            default:
                unsafeBuffer = self.unsafeBuffer
            }

            if accessBytes {
                var mutableSpan = _bytes.mutableSpan
                unsafeBuffer = mutableSpan.withUnsafeMutableBytes {
                    $0
                }
            }

            guard let unsafeBuffer else {
                return
            }

            // Move end bytes by unclaimedLength to meet the start bytes
            let startBuffer = UnsafeRawPointer(unsafeBuffer.baseAddress!).advanced(by: startOffset + unclaimedLength)
            unsafeBuffer.baseAddress?.advanced(by: startOffset).copyMemory(from: startBuffer, byteCount: endOffset)
        }

        // Reset effective length
        effectiveBufferLength -= unclaimedLength

        if self.isSingleIPAggregate {
            if aggregateBufferLength >= unclaimedLength {
                aggregateBufferLength -= unclaimedLength
            } else {
                aggregateBufferLength = 0
            }
        }
    }

    public mutating func collapse(to unclaimedLength: Int) -> Bool {
        guard claim(fromStart: unclaimedLength) else {
            return false
        }
        collapse()
        return unclaim(fromStart: unclaimedLength)
    }

    private mutating func ensureStorageAsBytes() {
        switch buffer {
        case .bytes:
            // Already stored as bytes!
            return
        default:
            break
        }

        if let unsafeUnclaimedBuffer {
            _bytes = .init(minimumCapacity: unsafeUnclaimedBuffer.count)
            _bytes.append(copying: unsafeUnclaimedBuffer)
        }
        finalizeBufferOnly(success: true)
        buffer = .bytes
        startOffset = 0
        endOffset = 0
        effectiveBufferLength = _bytes.count
    }

    // Copies if necessary into local storage. Custom owner bytes is allowed.
    // This may lose any claimed bytes.
    mutating func takeOwnershipOfBytes() {
        switch buffer {
        case .bytes:
            // Already owned bytes!
            return
        case .customOwner:
            // Already owned bytes!
            return
        case .customFinalizer:
            // Already owned bytes!
            return
        default:
            // Other types will copy
            break
        }
        ensureStorageAsBytes()
    }

    private mutating func _extractBytes() -> UniqueArray<UInt8> {
        // First, copy into _bytes if needed
        ensureStorageAsBytes()

        let effectiveBufferLength = self.effectiveBufferLength
        var extractedBytes = UniqueArray<UInt8>()
        swap(&_bytes, &extractedBytes)
        buffer = .empty

        if extractedBytes.count > effectiveBufferLength {
            extractedBytes.removeLast(extractedBytes.count - effectiveBufferLength)
        }
        return extractedBytes
    }

    public mutating func extractBytes() -> UniqueArray<UInt8> {
        _extractBytes()
    }

    private mutating func finalizeBufferOnly(success: Bool) {
        switch buffer {
        case .empty:
            // Already empty!
            break
        case .bytes:
            break
        case .customOwner:
            break
        case .customFinalizer(let buffer, let finalizer):
            finalizer(buffer)
        }
        self.buffer = .empty
    }

    public mutating func finalize(success: Bool) {
        finalizeBufferOnly(success: success)
        self = .init()
    }

    // MARK: - Flags and IP packet values

    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let metadataComplete = Frame.Flags(rawValue: 1 << 0)
        static let connectionComplete = Frame.Flags(rawValue: 1 << 1)
    }

    /// The checksum work for a frame. A frame is on its way out or on its way in, so the one field serves
    /// both: the transmit case says what the NIC is asked to compute, the receive case what it reported.
    enum ChecksumOffload {
        struct ReceiveFlags: OptionSet {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            var rawValue: UInt8
            // The hardware checked the IP header checksum, and found it valid.
            static let ipChecked = ReceiveFlags(rawValue: 1 << 0)
            static let ipValid = ReceiveFlags(rawValue: 1 << 1)
            // The hardware validated the transport (TCP/UDP) checksum.
            static let dataValid = ReceiveFlags(rawValue: 1 << 2)
            // The validated checksum value already folds in the pseudo-header.
            static let pseudoHeader = ReceiveFlags(rawValue: 1 << 3)
            // The value is a partial checksum, to be completed from `startOffset`.
            static let partial = ReceiveFlags(rawValue: 1 << 4)
        }

        case none
        /// TX: where the NIC begins the 1's-complement sum and where it stores the result (both zero for the
        /// IP-header-only case, which it locates itself), and which checksums it computes.
        case transmit(startOffset: UInt16, storeOffset: UInt16, flags: UInt8)
        /// RX: the final or partial transport checksum the hardware reported, where a partial one begins, and
        /// what it validated.
        case receive(value: UInt16, startOffset: UInt16, flags: ReceiveFlags)
    }

    // MARK: - Rarely set values, kept out of line

    /// Values that few frames carry, because they take an opt-in (a receive time or hop limit that the app
    /// asked for, an expiry, kernel pacing, packet IDs for failure reports, TSO, LRO aggregation) or only come
    /// up for certain packets (wake, keepalive, last packet, retransmit). Each is read or written only by the
    /// protocols at the bottom of a stack, down to the channel. The fields are ordered to leave no padding.
    struct ExtraValues {
        struct Flags: OptionSet {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            var rawValue: UInt16
            // TX: the TSO segment size describes an IPv6 super-packet.
            static let isTSOIPv6 = Flags(rawValue: 1 << 0)
            static let fragmentationOverride = Flags(rawValue: 1 << 1)
            static let isLastPacket = Flags(rawValue: 1 << 2)
            static let isKeepalive = Flags(rawValue: 1 << 3)
            static let isRetransmit = Flags(rawValue: 1 << 4)
            static let isBackground = Flags(rawValue: 1 << 5)
            static let isRealtime = Flags(rawValue: 1 << 6)
            static let isWakePacket = Flags(rawValue: 1 << 7)
            // RX: the frame is the head of a single-IP aggregate (LRO), or a later buflet of one.
            static let isSingleIPAggregate = Flags(rawValue: 1 << 8)
            static let isPacketChainMember = Flags(rawValue: 1 << 9)
            // TX: the IP fragmentation setting was overridden to disabled (the override flag means enabled).
            static let fragmentationDisabled = Flags(rawValue: 1 << 10)
            // RX: the link layer addressed the frame to a multicast or broadcast address.
            static let isLinkMulticast = Flags(rawValue: 1 << 11)
            static let isLinkBroadcast = Flags(rawValue: 1 << 12)
        }

        /// The time at which the kernel should send the packet, for kernel pacing.
        var departureTime: UInt64 = 0
        /// The time a packet was received, or the time after which it should be dropped.
        var timestamp: FrameTimestamp?
        /// The ID the kernel names this packet by when it reports that sending it failed.
        var packetID: SystemUUID?
        var appMetadata: AppMetadata?
        var hopLimit: UInt8 = 0
        /// RX: how many segments the kernel coalesced into this frame, or 0 if it did not say.
        var segmentCount: UInt8 = 0
        /// The generation of the header compression state this packet was compressed against.
        var compressionGenerationCount: UInt32 = 0
        /// The length of the whole packet a single-IP aggregate frame is the head of.
        var aggregateBufferLength: UInt32 = 0
        /// TX segmentation offload: the per-segment TCP payload size the hardware should cut this frame
        /// into, or 0 for an ordinary single-segment frame. Non-zero means the payload deliberately exceeds
        /// the path MTU.
        var tsoSegmentSize: UInt16 = 0
        var flags = Flags()
    }

    /// The frame's `ExtraValues`, behind a reference that is only there once something is set. It behaves as a
    /// value: copying it shares the storage, and the first write to a copy gives that copy its own.
    struct PacketExtras {
        private final class Storage {
            var values: ExtraValues
            init(_ values: ExtraValues) {
                self.values = values
            }
        }

        private var storage: Storage?

        init() {}

        /// Something has been set, and the values have storage.
        var isAllocated: Bool { storage != nil }

        /// The value `get` reads from the extras, or `defaultValue` while nothing has been set. Passing the default
        /// in, rather than returning an optional, saves each accessor from unwrapping with the same default.
        @inline(always)
        func read<T>(default defaultValue: T, _ get: (ExtraValues) -> T) -> T {
            guard let storage else { return defaultValue }
            return get(storage.values)
        }

        /// Applies `change`. With no storage yet, a write of a value that is the default allocates nothing and
        /// changes nothing, so `setsNonDefault` says whether `change` writes something other than the default.
        @inline(always)
        mutating func write(setsNonDefault: Bool, _ change: (inout ExtraValues) -> Void) {
            if storage == nil {
                guard setsNonDefault else { return }
                storage = Storage(ExtraValues())
            } else if !isKnownUniquelyReferenced(&storage) {
                storage = Storage(storage!.values)
            }
            change(&storage!.values)
        }
    }

    struct AppMetadata {
        let appType: UInt8
        let appMetadata: UInt8
    }

    private func extraFlag(_ flag: ExtraValues.Flags) -> Bool {
        extras.read(default: false) { $0.flags.contains(flag) }
    }

    private mutating func setExtraFlag(_ flag: ExtraValues.Flags, _ value: Bool) {
        extras.write(setsNonDefault: value) {
            if value { $0.flags.insert(flag) } else { $0.flags.remove(flag) }
        }
    }

    var isSingleIPAggregate: Bool {
        get {
            extraFlag(.isSingleIPAggregate)
        }
        set {
            setExtraFlag(.isSingleIPAggregate, newValue)
        }
    }

    var isPacketChainMember: Bool {
        get {
            extraFlag(.isPacketChainMember)
        }
        set {
            setExtraFlag(.isPacketChainMember, newValue)
        }
    }

    var isWakePacket: Bool {
        get {
            extraFlag(.isWakePacket)
        }
        set {
            setExtraFlag(.isWakePacket, newValue)
        }
    }

    var isKeepalive: Bool {
        get {
            extraFlag(.isKeepalive)
        }
        set {
            setExtraFlag(.isKeepalive, newValue)
        }
    }

    var isRetransmit: Bool {
        get {
            extraFlag(.isRetransmit)
        }
        set {
            setExtraFlag(.isRetransmit, newValue)
        }
    }

    var isBackground: Bool {
        get {
            extraFlag(.isBackground)
        }
        set {
            setExtraFlag(.isBackground, newValue)
        }
    }

    var isRealtime: Bool {
        get {
            extraFlag(.isRealtime)
        }
        set {
            setExtraFlag(.isRealtime, newValue)
        }
    }

    var isLastPacket: Bool {
        get {
            extraFlag(.isLastPacket)
        }
        set {
            setExtraFlag(.isLastPacket, newValue)
        }
    }

    var isLinkMulticast: Bool {
        get {
            extraFlag(.isLinkMulticast)
        }
        set {
            setExtraFlag(.isLinkMulticast, newValue)
        }
    }

    var isLinkBroadcast: Bool {
        get {
            extraFlag(.isLinkBroadcast)
        }
        set {
            setExtraFlag(.isLinkBroadcast, newValue)
        }
    }

    var isTSOIPv6: Bool {
        get {
            extraFlag(.isTSOIPv6)
        }
        set {
            setExtraFlag(.isTSOIPv6, newValue)
        }
    }

    /// Whether IP fragmentation is forced on (true) or off (false) for this frame, or nil to leave it to the
    /// protocol.
    var fragmentationOverride: Bool? {
        get {
            if extraFlag(.fragmentationOverride) { return true }
            return extraFlag(.fragmentationDisabled) ? false : nil
        }
        set {
            setExtraFlag(.fragmentationOverride, newValue == true)
            setExtraFlag(.fragmentationDisabled, newValue == false)
        }
    }

    var timestamp: FrameTimestamp? {
        get {
            extras.read(default: nil) { $0.timestamp }
        }
        set {
            extras.write(setsNonDefault: newValue != nil) { $0.timestamp = newValue }
        }
    }

    /// The time at which the kernel should send the packet, in nanoseconds of the absolute clock.
    var departureTime: UInt64 {
        get {
            extras.read(default: 0) { $0.departureTime }
        }
        set {
            extras.write(setsNonDefault: newValue != 0) { $0.departureTime = newValue }
        }
    }

    var packetID: SystemUUID? {
        get {
            extras.read(default: nil) { $0.packetID }
        }
        set {
            extras.write(setsNonDefault: newValue != nil) { $0.packetID = newValue }
        }
    }

    var compressionGenerationCount: UInt32 {
        get {
            extras.read(default: 0) { $0.compressionGenerationCount }
        }
        set {
            extras.write(setsNonDefault: newValue != 0) { $0.compressionGenerationCount = newValue }
        }
    }

    var appMetadata: AppMetadata? {
        get {
            extras.read(default: nil) { $0.appMetadata }
        }
        set {
            extras.write(setsNonDefault: newValue != nil) { $0.appMetadata = newValue }
        }
    }

    var tsoSegmentSize: UInt16 {
        get {
            extras.read(default: 0) { $0.tsoSegmentSize }
        }
        set {
            extras.write(setsNonDefault: newValue != 0) { $0.tsoSegmentSize = newValue }
        }
    }

    var hopLimit: UInt8 {
        get {
            extras.read(default: 0) { $0.hopLimit }
        }
        set {
            extras.write(setsNonDefault: newValue != 0) { $0.hopLimit = newValue }
        }
    }

    /// RX: how many segments the kernel coalesced into this frame, or 0 if it did not say.
    var segmentCount: UInt8 {
        get {
            extras.read(default: 0) { $0.segmentCount }
        }
        set {
            extras.write(setsNonDefault: newValue != 0) { $0.segmentCount = newValue }
        }
    }

    /// Whether the metadata attached to this frame is complete.
    ///
    /// Protocols outside the framework set this to signal that a frame carries the last of its
    /// data, so it is part of the public surface a protocol author writes against.
    public var metadataComplete: Bool {
        get {
            if protocolMetadatas.count > 0 {
                return protocolMetadatas[0].metadataComplete
            }
            return flags.contains(.metadataComplete)
        }
        set {
            if protocolMetadatas.count > 0 {
                protocolMetadatas[0].metadataComplete = newValue
            } else {
                if newValue { flags.insert(.metadataComplete) } else { flags.remove(.metadataComplete) }
            }
        }
    }

    public var connectionComplete: Bool {
        get { flags.contains(.connectionComplete) }
        set { if newValue { flags.insert(.connectionComplete) } else { flags.remove(.connectionComplete) } }
    }

    var packetChainTotalLength: Int {
        get {
            guard isSingleIPAggregate else {
                outlinedProtoLogFault("Attempt to get aggregate buffer length on a non-single IP aggregate")
                return 0
            }
            return aggregateBufferLength
        }
        set {
            guard isSingleIPAggregate else {
                outlinedProtoLogFault("Attempt to set aggregate buffer length on a non-single IP aggregate")
                return
            }
            aggregateBufferLength = newValue
        }
    }

    var serviceClass: Parameters.ServiceClass {
        get {
            Parameters.ServiceClass(rawValue: UInt8(_packetInfo & 0x7)) ?? .bestEffort
        }
        set {
            // A class set this way is a network service class, and replaces any the kernel's own was kept for
            _packetInfo = (_packetInfo & ~0x7 & ~(0xf << 12)) | UInt16(newValue.rawValue & 0x7)
        }
    }

    /// The kernel's own name for this frame's service class, or 0 if it has none and `serviceClass` stands. A
    /// network service class cannot name every packet class (control, OAM, system background, audio/video and
    /// real-time video fold into the nearest), so a frame that arrives with one keeps it and goes out as it came
    /// in. Setting it also sets the `serviceClass` it folds into.
    var packetServiceClassCode: UInt8 {
        get {
            UInt8((_packetInfo >> 12) & 0xf)
        }
        set {
            guard newValue != 0 else {
                _packetInfo &= ~(0xf << 12)
                return
            }
            let folded: Parameters.ServiceClass
            switch newValue {
            case 1, 2: folded = .background  // system background, background
            case 4, 5, 10: folded = .responsiveData  // responsive data, OAM, control
            case 6, 7, 8: folded = .interactiveVideo  // audio/video, real-time video, video
            case 9: folded = .interactiveVoice
            case 11: folded = .signaling
            default: folded = .bestEffort
            }
            _packetInfo =
                (_packetInfo & ~0x7 & ~(0xf << 12)) | UInt16(folded.rawValue & 0x7) | (UInt16(newValue & 0xf) << 12)
        }
    }

    var ecnFlag: IPProtocol.ECN {
        get {
            IPProtocol.ECN(rawValue: UInt8((_packetInfo >> 3) & 0x3)) ?? .nonECT
        }
        set {
            _packetInfo = (_packetInfo & ~(0x3 << 3)) | (UInt16(newValue.rawValue & 0x3) << 3)
        }
    }

    /// The DSCP, which is six bits wide, or nil if none has been set.
    var dscpValue: UInt8? {
        get {
            _packetInfo & (1 << 11) != 0 ? UInt8((_packetInfo >> 5) & 0x3f) : nil
        }
        set {
            let cleared = _packetInfo & ~(0x3f << 5) & ~(1 << 11)
            guard let newValue else {
                _packetInfo = cleared
                return
            }
            _packetInfo = cleared | (UInt16(newValue & 0x3f) << 5) | (1 << 11)
        }
    }

    private var transmitChecksum: (startOffset: UInt16, storeOffset: UInt16, flags: UInt8) {
        if case .transmit(let start, let store, let flags) = _checksum {
            return (start, store, flags)
        }
        return (0, 0, 0)
    }

    private var receiveChecksum: (value: UInt16, startOffset: UInt16, flags: ChecksumOffload.ReceiveFlags) {
        if case .receive(let value, let start, let flags) = _checksum {
            return (value, start, flags)
        }
        return (0, 0, [])
    }

    /// Changes what the NIC is asked to compute. Writing nothing in particular to a frame that carries what
    /// the NIC reported leaves that alone.
    private mutating func updateTransmitChecksum(
        _ change: (inout (startOffset: UInt16, storeOffset: UInt16, flags: UInt8)) -> Void
    ) {
        var values = transmitChecksum
        change(&values)
        if values.startOffset == 0 && values.storeOffset == 0 && values.flags == 0 {
            if case .transmit = _checksum { _checksum = .none }
            return
        }
        _checksum = .transmit(startOffset: values.startOffset, storeOffset: values.storeOffset, flags: values.flags)
    }

    /// Changes what the NIC reported, and likewise leaves what it was asked to do alone when there is
    /// nothing to report.
    private mutating func updateReceiveChecksum(
        _ change: (inout (value: UInt16, startOffset: UInt16, flags: ChecksumOffload.ReceiveFlags)) -> Void
    ) {
        var values = receiveChecksum
        change(&values)
        if values.value == 0 && values.startOffset == 0 && values.flags.isEmpty {
            if case .receive = _checksum { _checksum = .none }
            return
        }
        _checksum = .receive(value: values.value, startOffset: values.startOffset, flags: values.flags)
    }

    private func receiveChecksumFlag(_ flag: ChecksumOffload.ReceiveFlags) -> Bool {
        receiveChecksum.flags.contains(flag)
    }

    private mutating func setReceiveChecksumFlag(_ flag: ChecksumOffload.ReceiveFlags, _ value: Bool) {
        updateReceiveChecksum { if value { $0.flags.insert(flag) } else { $0.flags.remove(flag) } }
    }

    /// TX: which checksums the NIC computes.
    var checksumOffloadFlags: UInt8 {
        get { transmitChecksum.flags }
        set { updateTransmitChecksum { $0.flags = newValue } }
    }

    /// TX: where the NIC begins the sum.
    var checksumStartOffset: UInt16 {
        get { transmitChecksum.startOffset }
        set { updateTransmitChecksum { $0.startOffset = newValue } }
    }

    /// TX: where the NIC stores the result.
    var checksumStoreOffset: UInt16 {
        get { transmitChecksum.storeOffset }
        set { updateTransmitChecksum { $0.storeOffset = newValue } }
    }

    /// RX: the checksum value the hardware reported.
    var hardwareChecksumValue: UInt16 {
        get { receiveChecksum.value }
        set { updateReceiveChecksum { $0.value = newValue } }
    }

    var isChecksumIPChecked: Bool {
        get { receiveChecksumFlag(.ipChecked) }
        set { setReceiveChecksumFlag(.ipChecked, newValue) }
    }

    var isChecksumIPValid: Bool {
        get { receiveChecksumFlag(.ipValid) }
        set { setReceiveChecksumFlag(.ipValid, newValue) }
    }

    var isChecksumDataValid: Bool {
        get { receiveChecksumFlag(.dataValid) }
        set { setReceiveChecksumFlag(.dataValid, newValue) }
    }

    var isChecksumPseudoHeader: Bool {
        get { receiveChecksumFlag(.pseudoHeader) }
        set { setReceiveChecksumFlag(.pseudoHeader, newValue) }
    }

    /// RX: the hardware's checksum is a partial one, to be completed from `hardwareChecksumStart`.
    var isChecksumPartial: Bool {
        get { receiveChecksumFlag(.partial) }
        set { setReceiveChecksumFlag(.partial, newValue) }
    }

    /// RX: where a partial hardware checksum begins.
    var hardwareChecksumStart: UInt16 {
        get { receiveChecksum.startOffset }
        set { updateReceiveChecksum { $0.startOffset = newValue } }
    }

    struct FrameProtocolMetadata: ~Copyable {
        var uuid: SystemUUID
        var metadata: AbstractProtocolMetadata
        var metadataComplete: Bool = false
    }

    /// Whether the first metadata belongs to a specific protocol
    @inline(always)
    func firstMetadataMatches(protocolIdentifier: ProtocolIdentifier) -> Bool {
        protocolMetadatas.count > 0
            && protocolMetadatas[0].metadata.protocolIdentifier == protocolIdentifier
    }

    public var firstMetadata: AbstractProtocolMetadata? {
        guard protocolMetadatas.count > 0 else {
            return nil
        }
        return protocolMetadatas[0].metadata
    }

    enum FrameTimestamp {
        case receiveTime(_ timestamp: NetworkClock.Instant)
        case expireTime(_ timestamp: NetworkClock.Instant)
    }

    /// Copies every per-packet value `source` carries onto this frame, leaving a value alone where the source has
    /// none.
    ///
    /// Not copied: protocol metadata and completion flags, which `inheritMetadata` handles.
    mutating func copyValues(from source: borrowing Frame) {
        if let packetID = source.packetID { self.packetID = packetID }
        if let timestamp = source.timestamp { self.timestamp = timestamp }
        let departureTime = source.departureTime
        if departureTime != 0 { self.departureTime = departureTime }
        if let appMetadata = source.appMetadata { self.appMetadata = appMetadata }

        let serviceClass = source.serviceClass
        if serviceClass != .bestEffort { self.serviceClass = serviceClass }
        // The kernel's own class, where the network one folded it. 3 is best effort, which a frame has by default.
        let packetServiceClassCode = source.packetServiceClassCode
        if packetServiceClassCode != 0 && packetServiceClassCode != 3 {
            self.packetServiceClassCode = packetServiceClassCode
        }
        let ecnFlag = source.ecnFlag
        if ecnFlag != .nonECT { self.ecnFlag = ecnFlag }
        if let dscpValue = source.dscpValue { self.dscpValue = dscpValue }
        let hopLimit = source.hopLimit
        if hopLimit != 0 { self.hopLimit = hopLimit }
        if let fragmentationOverride = source.fragmentationOverride {
            self.fragmentationOverride = fragmentationOverride
        }

        if source.isRetransmit { isRetransmit = true }
        if source.isLastPacket { isLastPacket = true }
        if source.isBackground { isBackground = true }
        if source.isRealtime { isRealtime = true }
        if source.isKeepalive { isKeepalive = true }
        if source.isWakePacket { isWakePacket = true }
        if source.isLinkMulticast { isLinkMulticast = true }
        if source.isLinkBroadcast { isLinkBroadcast = true }

        let tsoSegmentSize = source.tsoSegmentSize
        if tsoSegmentSize != 0 { self.tsoSegmentSize = tsoSegmentSize }
        if source.isTSOIPv6 { isTSOIPv6 = true }

        // What the hardware reported on the way in, or what the protocols above asked of it on the way out.
        let received = source.receiveChecksum
        if received.value != 0 || received.startOffset != 0 || !received.flags.isEmpty {
            updateReceiveChecksum { $0 = received }
        }
        let requested = source.transmitChecksum
        if requested.flags != 0 {
            updateTransmitChecksum { $0 = requested }
        }

        // A packet chain member carries none of the values that belong to the packet as a whole.
        let isChainMember = source.isPacketChainMember
        if !isChainMember {
            let compressionGenerationCount = source.compressionGenerationCount
            if compressionGenerationCount != 0 { self.compressionGenerationCount = compressionGenerationCount }
            let segmentCount = source.segmentCount
            if segmentCount != 0 { self.segmentCount = segmentCount }
        }
        if source.isSingleIPAggregate {
            isSingleIPAggregate = true
            let aggregateBufferLength = source.aggregateBufferLength
            if aggregateBufferLength != 0 { self.aggregateBufferLength = aggregateBufferLength }
        }
        if isChainMember { isPacketChainMember = true }
    }

    mutating func reduceAggregateBufferLength(by length: Int) {
        if isSingleIPAggregate {
            guard length >= 0 else { return }
            guard length <= aggregateBufferLength else {
                let existingLength = aggregateBufferLength
                outlinedProtoLogFault(
                    "Aggregate buffer length cannot remove requested bytes; existing, requested",
                    existingLength,
                    length
                )
                aggregateBufferLength = 0
                return
            }
            aggregateBufferLength -= length
        }
    }

    #if !NETWORK_EMBEDDED
    public mutating func setMetadata(metadata: AbstractProtocolMetadata?, isInput: Bool, isComplete: Bool) {
        if let metadata = metadata as? ProtocolMetadata<IPProtocol>, let ipMetadata = metadata.perProtocolMetadata {
            ecnFlag = ipMetadata.ecnFlag
            dscpValue = ipMetadata.dscpValue
            serviceClass = ipMetadata.serviceClass
            fragmentationOverride = ipMetadata.fragmentationEnabled
        }

        if protocolMetadatas.isEmpty {
            // If there have not been any protocol metadatas set so far, use the complete marking for the frame overall
            metadataComplete = isComplete
        }

        if let metadata = metadata {
            let metadataUUID: SystemUUID = metadata.messageIdentifier
            var foundMatching = false
            for i in protocolMetadatas.indices {
                if protocolMetadatas[i].uuid == metadataUUID,
                    protocolMetadatas[i].metadata.matches(protocolIdentifier: metadata.protocolIdentifier)
                {
                    protocolMetadatas[i].metadata = metadata
                    protocolMetadatas[i].metadataComplete = isComplete
                    foundMatching = true
                    break
                }
            }
            if !foundMatching {
                let newProtocolMetadata = FrameProtocolMetadata(
                    uuid: metadataUUID,
                    metadata: metadata,
                    metadataComplete: isComplete
                )
                if isInput {
                    protocolMetadatas.insert(newProtocolMetadata, at: 0)
                } else {
                    protocolMetadatas.append(newProtocolMetadata)
                }
            }
        }
    }

    mutating func inheritMetadata(from: borrowing Frame, inheritComplete: Bool) {
        var index = 0
        while index < from.protocolMetadatas.count {
            // Set input to false to preserve the existing order of metadata
            self.setMetadata(
                metadata: from.protocolMetadatas[index].metadata,
                isInput: false,
                isComplete: inheritComplete ? from.protocolMetadatas[index].metadataComplete : false
            )
            index += 1
        }

        if inheritComplete {
            self.metadataComplete = from.metadataComplete
            self.connectionComplete = from.connectionComplete
        }
    }
    #endif
}

@available(Network 0.1.0, *)
extension Frame {
    // Copy length bytes from offset in this Frame into destination Frame.
    // checking the source offset, length and destination fit.
    // Return the length that it was able to copy into destination.
    func copyInto(
        _ destination: inout Frame,
        atOffset destinationOffset: Int = 0,
        fromOffset requestedOffset: Int = 0,
        length maxRequestedLength: Int
    ) -> Int {
        // Ensure the request offsets are positive
        guard requestedOffset >= 0, maxRequestedLength > 0, destinationOffset >= 0 else {
            return 0
        }

        guard let sourceBytes = self.span else {
            return 0
        }

        // Ensure the requestedOffset is within this frame
        let thisFrameLength = sourceBytes.count
        guard thisFrameLength > requestedOffset else {
            return 0
        }
        let remainingLengthInThisFrame = thisFrameLength - requestedOffset
        guard var destinationBytes = destination.mutableSpan else {
            return 0
        }

        let destinationLength = destinationBytes.count
        let requestLength = min(maxRequestedLength, remainingLengthInThisFrame, destinationLength)
        guard requestLength > 0 else { return 0 }

        destinationBytes.withUnsafeMutableBytes { destinationBaseAddress in
            sourceBytes.withUnsafeBytes { sourceBaseAddress in
                destinationBaseAddress.baseAddress!.advanced(by: destinationOffset).copyMemory(
                    from: sourceBaseAddress.baseAddress!.advanced(by: requestedOffset),
                    byteCount: requestLength
                )
            }
        }

        return requestLength
    }
}
