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

    public var buffer: Buffer

    var _bytes: NetworkUniqueArray<UInt8> = .init()

    private var _startOffset: UInt32 = 0
    @usableFromInline var startOffset: Int {
        get { Int(_startOffset) }
        set { _startOffset = UInt32(newValue) }
    }
    private var _endOffset: UInt32 = 0
    @usableFromInline var endOffset: Int {
        get { Int(_endOffset) }
        set { _endOffset = UInt32(newValue) }
    }
    private var _effectiveBufferLength: UInt32 = 0
    var effectiveBufferLength: Int {
        get { Int(_effectiveBufferLength) }
        set { _effectiveBufferLength = UInt32(newValue) }
    }
    private var _aggregateBufferLength: UInt32 = 0
    var aggregateBufferLength: Int {
        get { Int(_aggregateBufferLength) }
        set { _aggregateBufferLength = UInt32(newValue) }
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

    init(bytes: consuming NetworkUniqueArray<UInt8>) {
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

    @inline(__always)
    public var unclaimedLength: Int {
        if effectiveBufferLength == 0 { return 0 }
        return effectiveBufferLength - (startOffset + endOffset)
    }

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

    // Only unclaimed bytes in frame, for unsafe types
    private var unsafeUnclaimedBuffer: UnsafeMutableRawBufferPointer? {
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
    private var unsafeBuffer: UnsafeMutableRawBufferPointer? {
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

    public mutating func claim(fromStart: Int, fromEnd: Int = 0, adjustSingleIPAggregate: Bool = true) -> Bool {
        if adjustSingleIPAggregate && isSingleIPAggregate {
            guard fromEnd == 0 else {
                Logger.proto.fault("Trying to claim at the end \(fromEnd) bytes from a single-IP aggregate")
                return false
            }
            aggregateBufferLength -= fromStart
        }

        let newStart = startOffset + fromStart
        let newEnd = endOffset + fromEnd
        guard newStart <= effectiveBufferLength - newEnd else {
            let effectiveLength = effectiveBufferLength
            Logger.proto.error(
                "Claiming bytes failed because start (\(newStart)) is beyond end (\(effectiveLength) - \(newEnd))"
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
                Logger.proto.fault("Trying to unclaim at the end \(fromEnd) bytes from a single-IP aggregate")
                return false
            }
            aggregateBufferLength += fromStart
        }

        guard fromStart <= startOffset else {
            let startOffset = startOffset
            Logger.proto.error("Frame cannot unclaim \(fromStart) start bytes (has \(startOffset) left)")
            return false
        }

        guard fromEnd <= endOffset else {
            let endOffset = endOffset
            Logger.proto.error("Frame cannot unclaim \(fromEnd) end bytes (has \(endOffset) left)")
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
            aggregateBufferLength -= unclaimedLength
            if aggregateBufferLength < 0 {
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

    private mutating func _extractBytes() -> NetworkUniqueArray<UInt8> {
        // First, copy into _bytes if needed
        ensureStorageAsBytes()

        let effectiveBufferLength = self.effectiveBufferLength
        var extractedBytes = NetworkUniqueArray<UInt8>()
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
        static let isSingleIPAggregate = Frame.Flags(rawValue: 1 << 0)
        static let isPacketChainMember = Frame.Flags(rawValue: 1 << 1)
        static let isWakePacket = Frame.Flags(rawValue: 1 << 2)
        static let isKeepalive = Frame.Flags(rawValue: 1 << 3)
        static let isRetransmit = Frame.Flags(rawValue: 1 << 4)
        static let isBackground = Frame.Flags(rawValue: 1 << 5)
        static let isRealtime = Frame.Flags(rawValue: 1 << 6)
    }
    var flags: Flags = Flags()

    struct IPPacketValues {
        struct Flags: OptionSet {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            var rawValue: UInt8
            static let isLastPacket = Flags(rawValue: 1 << 0)
            static let isChecksumIPChecked = Flags(rawValue: 1 << 1)
            static let isChecksumIPValid = Flags(rawValue: 1 << 2)
            static let fragmentationOverride = Flags(rawValue: 1 << 3)
        }
        var flags: Flags = Flags()
        var serviceClass = Parameters.ServiceClass.bestEffort
        var ecnFlag: IPProtocol.ECN = .nonECT
        var dscpValue: UInt8?
        var hopLimit: UInt8 = 0
        var checksumOffloadFlags: UInt8 = 0
        var departureTime: UInt64 = 0  // departure time at which kernel should send the packet, used for kernel pacing
        var isLastPacket: Bool {
            get { flags.contains(.isLastPacket) }
            set { if newValue { flags.insert(.isLastPacket) } else { flags.remove(.isLastPacket) } }
        }
        var isChecksumIPChecked: Bool {
            get { flags.contains(.isChecksumIPChecked) }
            set { if newValue { flags.insert(.isChecksumIPChecked) } else { flags.remove(.isChecksumIPChecked) } }
        }
        var isChecksumIPValid: Bool {
            get { flags.contains(.isChecksumIPValid) }
            set { if newValue { flags.insert(.isChecksumIPValid) } else { flags.remove(.isChecksumIPValid) } }
        }
        var fragmentationOverride: Bool? {
            get { flags.contains(.fragmentationOverride) ? true : nil }
            set {
                if let newValue = newValue, newValue {
                    flags.insert(.fragmentationOverride)
                } else {
                    flags.remove(.fragmentationOverride)
                }
            }
        }
    }
    var ipPacketValues: IPPacketValues? = nil

    struct AppMetadata: ~Copyable {
        let appType: UInt8
        let appMetadata: UInt8
    }
    var appMetadata: AppMetadata? = nil

    var isSingleIPAggregate: Bool {
        get { flags.contains(.isSingleIPAggregate) }
        set { if newValue { flags.insert(.isSingleIPAggregate) } else { flags.remove(.isSingleIPAggregate) } }
    }

    var isPacketChainMember: Bool {
        get { flags.contains(.isPacketChainMember) }
        set { if newValue { flags.insert(.isPacketChainMember) } else { flags.remove(.isPacketChainMember) } }
    }

    var isWakePacket: Bool {
        get { flags.contains(.isWakePacket) }
        set { if newValue { flags.insert(.isWakePacket) } else { flags.remove(.isWakePacket) } }
    }

    var isKeepalive: Bool {
        get { flags.contains(.isKeepalive) }
        set { if newValue { flags.insert(.isKeepalive) } else { flags.remove(.isKeepalive) } }
    }

    var isRetransmit: Bool {
        get { flags.contains(.isRetransmit) }
        set { if newValue { flags.insert(.isRetransmit) } else { flags.remove(.isRetransmit) } }
    }

    var isBackground: Bool {
        get { flags.contains(.isBackground) }
        set { if newValue { flags.insert(.isBackground) } else { flags.remove(.isBackground) } }
    }

    var isRealtime: Bool {
        get { flags.contains(.isRealtime) }
        set { if newValue { flags.insert(.isRealtime) } else { flags.remove(.isRealtime) } }
    }

    var packetChainTotalLength: Int {
        get {
            guard !isSingleIPAggregate else {
                Logger.proto.fault("Attempt to get aggregate buffer length on a non-single IP aggregate")
                return 0
            }
            return aggregateBufferLength
        }
        set {
            guard !isSingleIPAggregate else {
                Logger.proto.fault("Attempt to get aggregate buffer length on a non-single IP aggregate")
                return
            }
            aggregateBufferLength = newValue
        }
    }

    var dscpValue: UInt8? {
        get { ipPacketValues?.dscpValue }
        set {
            guard let newValue else {
                if ipPacketValues != nil {
                    ipPacketValues!.dscpValue = nil
                }
                return
            }
            guard newValue < 64 else {
                Logger.proto.fault("Cannot set DSCP value of \(newValue)")
                return
            }
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.dscpValue = newValue
        }
    }

    var hopLimit: UInt8 {
        get { ipPacketValues?.hopLimit ?? 0 }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.hopLimit = newValue
        }
    }

    var ecnFlag: IPProtocol.ECN {
        get { ipPacketValues?.ecnFlag ?? .nonECT }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.ecnFlag = newValue
        }
    }

    var isLastPacket: Bool {
        get { ipPacketValues?.isLastPacket ?? false }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.isLastPacket = newValue
        }
    }

    var fragmentationOverride: Bool? {
        get { ipPacketValues?.fragmentationOverride }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.fragmentationOverride = newValue
        }
    }

    var departureTime: UInt64 {
        get { ipPacketValues?.departureTime ?? 0 }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.departureTime = newValue
        }
    }

    var checksumOffloadFlags: UInt8 {
        get { ipPacketValues?.checksumOffloadFlags ?? 0 }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.checksumOffloadFlags = newValue
        }
    }
    var isChecksumIPChecked: Bool {
        get { ipPacketValues?.isChecksumIPChecked ?? false }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.isChecksumIPChecked = newValue
        }
    }

    var isChecksumIPValid: Bool {
        get { ipPacketValues?.isChecksumIPValid ?? false }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.isChecksumIPValid = newValue
        }
    }

    struct FrameProtocolMetadata: ~Copyable {
        var uuid: SystemUUID
        var metadata: AbstractProtocolMetadata
        var metadataComplete: Bool = false
    }
    var protocolMetadatas: NetworkUniqueDeque<FrameProtocolMetadata> = .init(minimumCapacity: 0)

    public var firstMetadata: AbstractProtocolMetadata? {
        guard protocolMetadatas.count > 0 else {
            return nil
        }
        return protocolMetadatas[0].metadata
    }
    var _metadataComplete: Bool = false
    var metadataComplete: Bool {
        get {
            if protocolMetadatas.count > 0 {
                return protocolMetadatas[0].metadataComplete
            }
            return _metadataComplete
        }
        set { _metadataComplete = newValue }
    }
    public var connectionComplete: Bool = false

    enum FrameTimestamp {
        case receiveTime(_ timestamp: NetworkClock.Instant)
        case expireTime(_ timestamp: NetworkClock.Instant)
    }
    var timestamp: FrameTimestamp? = nil

    mutating func reduceAggregateBufferLength(by length: Int) {
        if isSingleIPAggregate {
            guard aggregateBufferLength < length else {
                let existingLength = aggregateBufferLength
                Logger.proto.fault("Aggregate buffer length \(existingLength) cannot remove \(length)")
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
            self._metadataComplete = from._metadataComplete
            self.connectionComplete = from.connectionComplete
        }
    }
    #endif
}

@available(Network 0.1.0, *)
extension Frame {
    var serviceClass: Parameters.ServiceClass {
        get { ipPacketValues?.serviceClass ?? .bestEffort }
        set {
            if ipPacketValues == nil {
                ipPacketValues = IPPacketValues()
            }
            ipPacketValues!.serviceClass = newValue
        }
    }
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
