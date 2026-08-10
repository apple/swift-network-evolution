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

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct IPProtocol: NetworkProtocol {
    public typealias Options = IPOptions
    public typealias Metadata = IPMetadata
    typealias Instance = IPInstance

    static public var ipv4HeaderLength: Int {
        MemoryLayout<UInt8>.size * 20
        // IPv4 Header
        // Version / Header Length: UInt8
        // DiffServ / ECN : UInt8
        // Total Length: UInt16
        // Identification: UInt16
        // Fragment offset: UInt16
        // TTL: UInt8
        // Next protocol: UInt8
        // Checksum: UInt16
        // Source Address: UInt32
        // Destination Address: UInt32
    }

    static public var ipv6HeaderLength: Int {
        MemoryLayout<UInt8>.size * 40
        // IPv6 Header
        // Version / Traffic Class / Flow Label: UInt32
        // Payload Length: UInt16
        // Next Header: UInt8
        // Hop Limit: UInt8
        // Source Address: UInt128
        // Destination Address: UInt128
    }

    public enum Version: UInt8 {
        /// Allows any IP version.
        case any = 0
        /// Uses only IP version 4 (IPv4).
        case v4 = 4
        /// Uses only IP version 6 (IPv6).
        case v6 = 6
    }

    public enum AddressPreference: UInt8 {
        case any = 0
        case temporary = 1
        case stable = 2
    }

    public enum ECN: UInt8 {
        /// Non-ECN-capable transport.
        case nonECT = 0
        /// ECN-capable transport (0).
        case ect0 = 1
        /// ECN-capable transport (1).
        case ect1 = 2
        /// Congestion experienced.
        case ce = 3

        init(_ rawValue: UInt8) {
            switch rawValue {
            case 0:
                self = .nonECT
            case 1:
                self = .ect0
            case 2:
                self = .ect1
            case 3:
                self = .ce
            default:
                self = .nonECT
            }
        }
    }

    public struct IPOptions: PerProtocolOptions {
        var version: Version = .any
        var localAddressPreference: AddressPreference = .any

        var _hopLimit: UInt8 = 0
        public var hopLimit: UInt8? {
            get {
                guard flags.contains(.hopLimitSet) else {
                    return nil
                }
                return _hopLimit
            }
            set {
                guard let newValue = newValue else {
                    flags.remove(.hopLimitSet)
                    _hopLimit = 0
                    return
                }
                flags.insert(.hopLimitSet)
                _hopLimit = newValue
            }
        }

        var fragmentationEnabled: Bool? {
            get {
                guard flags.contains(.fragmentationEnabledOverridden) else {
                    return nil
                }
                return flags.contains(.fragmentationEnabled)
            }
            set {
                guard let newValue = newValue else {
                    flags.remove(.fragmentationEnabledOverridden)
                    flags.remove(.fragmentationEnabled)
                    return
                }
                flags.insert(.fragmentationEnabledOverridden)
                if newValue {
                    flags.insert(.fragmentationEnabled)
                } else {
                    flags.remove(.fragmentationEnabled)
                }
            }
        }
        var useMinimumMTU: Bool {
            get { flags.contains(.useMinimumMTU) }
            set { if newValue { flags.insert(.useMinimumMTU) } else { flags.remove(.useMinimumMTU) } }
        }
        var calculateReceiveTime: Bool {
            get { flags.contains(.calculateReceiveTime) }
            set { if newValue { flags.insert(.calculateReceiveTime) } else { flags.remove(.calculateReceiveTime) } }
        }
        var disableMulticastLoopback: Bool {
            get { flags.contains(.disableMulticastLoopback) }
            set {
                if newValue { flags.insert(.disableMulticastLoopback) } else { flags.remove(.disableMulticastLoopback) }
            }
        }
        var corruptChecksums: Bool {
            get { flags.contains(.corruptChecksums) }
            set { if newValue { flags.insert(.corruptChecksums) } else { flags.remove(.corruptChecksums) } }
        }
        var receiveHopLimit: Bool {
            get { flags.contains(.receiveHopLimit) }
            set { if newValue { flags.insert(.receiveHopLimit) } else { flags.remove(.receiveHopLimit) } }
        }

        var _dscpValue: UInt8 = 0
        var dscpValue: UInt8? {
            get {
                guard flags.contains(.dscpValueSet) else {
                    return nil
                }
                return _dscpValue
            }
            set {
                guard let newValue = newValue else {
                    flags.remove(.dscpValueSet)
                    _dscpValue = 0
                    return
                }
                flags.insert(.dscpValueSet)
                _dscpValue = newValue
            }
        }

        public struct Flags: OptionSet, Sendable {
            public init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            public var rawValue: UInt8
            static public let useMinimumMTU = IPOptions.Flags(rawValue: 1 << 0)
            static public let calculateReceiveTime = IPOptions.Flags(rawValue: 1 << 1)
            static public let disableMulticastLoopback = IPOptions.Flags(rawValue: 1 << 2)
            static public let corruptChecksums = IPOptions.Flags(rawValue: 1 << 3)
            static public let receiveHopLimit = IPOptions.Flags(rawValue: 1 << 4)
            static public let fragmentationEnabledOverridden = IPOptions.Flags(rawValue: 1 << 5)
            static public let fragmentationEnabled = IPOptions.Flags(rawValue: 1 << 6)
            static public let hopLimitSet = IPOptions.Flags(rawValue: 1 << 7)
            static public let dscpValueSet = IPOptions.Flags(rawValue: 1 << 8)
        }
        var flags: Flags = Flags()

        #if NETWORK_PRIVATE
        var privateStorage = IPProtocolOptionsPrivateStorage()
        #endif

        init() {}

        init?(from serializedBytes: [UInt8]) {
            var versionByte: UInt8 = 0
            var localAddressPreferenceByte: UInt8 = 0
            var flagsByte: UInt8 = 0
            var dscpValueByte: UInt8 = 0
            let result = Deserializer.deserialize(serializedBytes.span) { read throws(DeserializationError) in
                try read.uint8(&versionByte)
                try read.uint8(&localAddressPreferenceByte)
                try read.uint8(&_hopLimit)
                try read.uint8(&flagsByte)
                try read.uint8(&dscpValueByte)
            }
            guard case .success = result else {
                Logger.proto.error("Failed to deserialize: \(result)")
                return nil
            }
            self.version = Version(rawValue: versionByte) ?? .any
            self.localAddressPreference = AddressPreference(rawValue: localAddressPreferenceByte) ?? .any
            self.dscpValue = dscpValueByte
            self.flags = Flags(rawValue: flagsByte)
        }
        public func serialize() -> [UInt8]? {
            Serializer.serialize { write in
                write.uint8(version.rawValue)
                write.uint8(localAddressPreference.rawValue)
                write.uint8(_hopLimit)
                write.uint8(flags.rawValue)
                write.uint8(_dscpValue)
            }
        }
        public var serializeInParameters: Bool {
            false
        }
        public func deepCopy() -> IPOptions {
            self
        }
        public func isEqual(to other: IPOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }

        var isDefault: Bool {
            self == IPOptions()
        }
    }

    public struct IPMetadata: PerProtocolMetadata {
        internal var _receiveTime: UInt64? = nil
        var receiveTime: UInt64? {
            get { _receiveTime }
            set {
                guard !isStatic else {
                    Logger.proto.error("Cannot modify static metadata")
                    return
                }
                _receiveTime = newValue
            }
        }
        internal var _ecnFlag: ECN = .nonECT
        var ecnFlag: ECN {
            get { _ecnFlag }
            set {
                guard !isStatic else {
                    Logger.proto.error("Cannot modify static metadata")
                    return
                }
                _ecnFlag = newValue
            }
        }
        internal var _serviceClass: Parameters.ServiceClass = .bestEffort
        var serviceClass: Parameters.ServiceClass {
            get { _serviceClass }
            set {
                guard !isStatic else {
                    Logger.proto.error("Cannot modify static metadata")
                    return
                }
                _serviceClass = newValue
            }
        }
        internal var _fragmentationEnabled: Bool? = nil
        var fragmentationEnabled: Bool? {
            get { _fragmentationEnabled }
            set {
                guard !isStatic else {
                    Logger.proto.error("Cannot modify static metadata")
                    return
                }
                _fragmentationEnabled = newValue
            }
        }
        internal var _dscpValue: UInt8? = nil
        var dscpValue: UInt8? {
            get { _dscpValue }
            set {
                guard !isStatic else {
                    Logger.proto.error("Cannot modify static metadata")
                    return
                }
                _dscpValue = newValue
            }
        }
        internal var _hopLimit: UInt8? = nil
        var hopLimit: UInt8? {
            get { _hopLimit }
            set {
                guard !isStatic else {
                    Logger.proto.error("Cannot modify static metadata")
                    return
                }
                _hopLimit = newValue
            }
        }
        var isStatic: Bool = false

        init() {}
        public func isEqual(to other: IPMetadata, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    struct IPInstance: ~Copyable, OneToOneDatagramProtocol {
        var upper = InboundDatagramLinkage()
        var lower = OutboundDatagramLinkage()

        var ipInstanceIndex: NetworkStateIndex? = nil

        private(set) var context: NetworkContext
        init(context: NetworkContext) { self.context = context }

        private(set) var reference: ProtocolInstanceReference = .init()

        var log = NetworkLoggerState()
        var eventManager = ProtocolEventManager()

        static let IPMoreFragmentsFlag: UInt16 = 0x2000
        static let IPFragmentOffsetMask: UInt16 = 0x1FFF
        static let IPMaxFragmentCount: Int = 32

        // Only called by newProtocolInstance()
        fileprivate static func registerNewIP(on context: NetworkContext) -> ProtocolInstanceReference {
            let ip = IPInstance(context: context)
            let registeredIndex = context.registerIPInstance(ip)
            context.ipInstances[registeredIndex].ipInstanceIndex = registeredIndex
            context.ipInstances[registeredIndex].reference = ProtocolInstanceReference(
                ip: &context.ipInstances[registeredIndex]
            )
            return context.ipInstances[registeredIndex].reference
        }

        var passthroughEvents = true

        struct IPCounters: ~Copyable {
            var txPackets = 0
            var rxPackets = 0
            var rxECT0Packets = 0
            var rxECT1Packets = 0
            var rxCEPackets = 0
        }

        struct IPPathProperties {
            var maximumMessageSize = 0
            var mtu = 0
            var outputHandlerMessageSize = 0
            var dscpValue: UInt8?
        }

        struct IPInstanceFlags: OptionSet {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            var rawValue: UInt16
            static let suppressLogging = IPInstance.IPInstanceFlags(rawValue: 1 << 0)
            static let calculateReceiveTime = IPInstance.IPInstanceFlags(rawValue: 1 << 1)
            static let segmentationOffloadInUse = IPInstance.IPInstanceFlags(rawValue: 1 << 2)
            static let enableFragmentation = IPInstance.IPInstanceFlags(rawValue: 1 << 3)
            static let csumOffload = IPInstance.IPInstanceFlags(rawValue: 1 << 4)
            static let corruptChecksums = IPInstance.IPInstanceFlags(rawValue: 1 << 5)
            static let didCorruptChecksum = IPInstance.IPInstanceFlags(rawValue: 1 << 6)
            static let receiveHopLimit = IPInstance.IPInstanceFlags(rawValue: 1 << 7)
            static let useMinimumMTU = IPInstance.IPInstanceFlags(rawValue: 1 << 8)

            var suppressLogging: Bool {
                get { self.contains(.suppressLogging) }
                set { if newValue { self.insert(.suppressLogging) } else { self.remove(.suppressLogging) } }
            }
            var calculateReceiveTime: Bool {
                get { self.contains(.calculateReceiveTime) }
                set { if newValue { self.insert(.calculateReceiveTime) } else { self.remove(.calculateReceiveTime) } }
            }
            var segmentationOffloadInUse: Bool {
                get { self.contains(.segmentationOffloadInUse) }
                set {
                    if newValue {
                        self.insert(.segmentationOffloadInUse)
                    } else {
                        self.remove(.segmentationOffloadInUse)
                    }
                }
            }
            var enableFragmentation: Bool {
                get { self.contains(.enableFragmentation) }
                set { if newValue { self.insert(.enableFragmentation) } else { self.remove(.enableFragmentation) } }
            }
            var csumOffload: Bool {
                get { self.contains(.csumOffload) }
                set { if newValue { self.insert(.csumOffload) } else { self.remove(.csumOffload) } }
            }
            var corruptChecksums: Bool {
                get { self.contains(.corruptChecksums) }
                set { if newValue { self.insert(.corruptChecksums) } else { self.remove(.corruptChecksums) } }
            }
            var didCorruptChecksum: Bool {
                get { self.contains(.didCorruptChecksum) }
                set { if newValue { self.insert(.didCorruptChecksum) } else { self.remove(.didCorruptChecksum) } }
            }
            var receiveHopLimit: Bool {
                get { self.contains(.receiveHopLimit) }
                set { if newValue { self.insert(.receiveHopLimit) } else { self.remove(.receiveHopLimit) } }
            }
            var useMinimumMTU: Bool {
                get { self.contains(.useMinimumMTU) }
                set { if newValue { self.insert(.useMinimumMTU) } else { self.remove(.useMinimumMTU) } }
            }
        }

        struct IPv4Instance: ~Copyable {
            var ipProtocolNumber: UInt8 = 0
            var localAddress = IPv4Address.any
            var remoteAddress = IPv4Address.any

            var netmask = IPv4Address.any
            var broadcast = IPv4Address.any
            var ttl: UInt8 = 64
            var dscpValue: UInt8 = 0

            var flags = IPInstanceFlags()
            var counters = IPCounters()
            var pathProperties = IPPathProperties()
            var reassemblyState: IPv4ReassemblyState?

            struct IPv4ReassemblyState: ~Copyable {
                var reassemblyID: UInt16
                var inputReassemblyFrames = FrameArray()
            }

            static var headerLength: Int {
                MemoryLayout<UInt32>.size * 5
            }

            func incrementByHeaderLength(_ value: Int) -> Int {
                if Int.max - value < IPv4Instance.headerLength {
                    return Int.max
                }
                return value + IPv4Instance.headerLength
            }

            mutating func appendReassembledPackets(
                _ log: borrowing NetworkLoggerState,
                reassembled: inout FrameArray
            ) {
                guard let empty = reassemblyState?.inputReassemblyFrames.isEmpty, !empty else {
                    return
                }
                guard let reassemblyID = reassemblyState?.reassemblyID else {
                    return
                }
                var complete = false
                var expectedOffset: UInt16 = 0
                var tos: UInt8 = 0
                var ttl: UInt8 = 0
                reassemblyState?.inputReassemblyFrames.iterateMutableFrames { frame in
                    guard frame.bufferLength >= IPv4Instance.headerLength else {
                        log.info("Reassembly frame is no longer valid")
                        complete = false
                        return false
                    }
                    var offset: UInt16 = 0
                    var length: UInt16 = 0
                    let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                        try read.skip(1)
                        try read.uint8(&tos)
                        try read.uint16NetworkByteOrder(&length)
                        try read.skip(2)
                        try read.uint16NetworkByteOrder(&offset)
                        try read.uint8(&ttl)
                    }
                    guard result.isValid else {
                        complete = false
                        return false
                    }
                    // Fragment offset is in 8 byte increments
                    let fragmentByteOffset = (offset & IPFragmentOffsetMask) * 8
                    guard fragmentByteOffset == expectedOffset else {
                        complete = false
                        return false
                    }
                    let payloadLength = length - UInt16(IPv4Instance.headerLength)
                    let (next, overflow) = expectedOffset.addingReportingOverflow(payloadLength)
                    guard !overflow else {
                        log.error("Fragment offset overflow for IP ID \(reassemblyID)")
                        complete = false
                        return false
                    }
                    // Found the next fragment
                    expectedOffset = next
                    if offset & IPMoreFragmentsFlag == 0 {
                        // No more fragments, we're complete
                        complete = true
                        return false
                    }
                    return true
                }
                guard complete else {
                    log.debug("Fragments for IP ID \(reassemblyID) incomplete")
                    return
                }
                // Create a new frame with the complete length for reassembly
                // Guard against the max value of UInt16
                let rawLength = UInt32(IPv4Instance.headerLength) + UInt32(expectedOffset)
                guard rawLength <= UInt16.max else {
                    log.error("Reassembled IP length overflows for IP ID \(reassemblyID)")
                    return
                }
                let newIPFrameLength = UInt16(rawLength)
                var newFrame = Frame(count: Int(newIPFrameLength))

                // Fillout the IP header
                let headerCopied = reassemblyState?.inputReassemblyFrames.peekFirstFrame { first in
                    first.copyInto(&newFrame, length: IPv4Instance.headerLength)
                }
                guard headerCopied == IPv4Instance.headerLength else {
                    log.error("Failed to copy IP header from first fragment (IP ID \(reassemblyID))")
                    newFrame.finalize(success: false)
                    return
                }
                let result = Serializer.serialize(&newFrame, claim: false) { write throws(SerializationError) in
                    try write.skip(2)
                    try write.uint16NetworkByteOrder(newIPFrameLength)
                    try write.skip(2)
                    try write.uint16NetworkByteOrder(0)
                }
                guard result.isValid else {
                    log.error("Failed to write the updated IP header")
                    newFrame.finalize(success: false)
                    return
                }
                guard newFrame.claim(fromStart: IPv4Instance.headerLength) else {
                    log.error("Failed to claim the updated IP header")
                    newFrame.finalize(success: false)
                    return
                }
                // Copy each fragment's payload into the new frame sequentially.
                var writeOffset = 0
                var copyFailed = false
                reassemblyState?.inputReassemblyFrames.iterateMutableFrames { fragment in
                    guard fragment.bufferLength >= IPv4Instance.headerLength else {
                        log.error("Fragment became invalid during reassembly copy")
                        copyFailed = true
                        return false
                    }
                    var ipLength: UInt16 = 0
                    let result = Deserializer.deserialize(&fragment, claim: false) {
                        read throws(DeserializationError) in
                        try read.skip(2)
                        try read.uint16NetworkByteOrder(&ipLength)
                    }
                    guard result.isValid else {
                        copyFailed = true
                        return false
                    }
                    guard ipLength >= IPv4Instance.headerLength else {
                        copyFailed = true
                        return false
                    }
                    guard fragment.bufferLength >= Int(ipLength) else {
                        log.error(
                            "Fragment buffer \(fragment.bufferLength) < ip_len \(ipLength) for IP ID \(reassemblyID)"
                        )
                        copyFailed = true
                        return false
                    }
                    let totalIPLength = Int(ipLength)
                    let payloadLength = totalIPLength - IPv4Instance.headerLength
                    let payloadEnd = writeOffset + payloadLength
                    guard payloadEnd <= Int(newIPFrameLength) - IPv4Instance.headerLength else {
                        log.error("Writing fragment payload overflows the new IP frame")
                        copyFailed = true
                        return false
                    }
                    let copied = fragment.copyInto(
                        &newFrame,
                        atOffset: writeOffset,
                        fromOffset: IPv4Instance.headerLength,
                        length: payloadLength
                    )
                    guard copied == payloadLength else {
                        log.error("Payload copy mismatch for IP ID \(reassemblyID): \(copied) != \(payloadLength)")
                        copyFailed = true
                        return false
                    }
                    writeOffset += payloadLength
                    return true
                }

                guard !copyFailed else {
                    newFrame.finalize(success: false)
                    return
                }

                log.debug("Reassembly complete for IP ID \(reassemblyID), total length \(newIPFrameLength)")

                let dscpValue = tos >> 2  // IPTOS_DSCP_SHIFT
                newFrame.dscpValue = dscpValue
                if self.flags.receiveHopLimit {
                    newFrame.hopLimit = ttl
                }
                newFrame.metadataComplete = true
                if self.flags.calculateReceiveTime {
                    newFrame.timestamp = Frame.FrameTimestamp.receiveTime(.now)
                }
                reassembled.add(frame: newFrame)

                // Finalize the original fragment frames
                while var fragment = reassemblyState?.inputReassemblyFrames.popFirst() {
                    fragment.finalize(success: true)
                }
            }

            mutating func processReassembly(
                _ log: borrowing NetworkLoggerState,
                ipID: UInt16,
                reassembled: inout FrameArray,
                forceFlush: Bool
            ) {
                let hasAccumulatedFragments = reassemblyState?.inputReassemblyFrames.isEmpty == false
                let isNewID = reassemblyState?.reassemblyID != ipID

                if hasAccumulatedFragments && (isNewID || forceFlush) {
                    appendReassembledPackets(log, reassembled: &reassembled)
                    // Only discard buffered fragments when the IP ID changes
                    if isNewID && !forceFlush {
                        var dropped = 0
                        while var fragment = reassemblyState?.inputReassemblyFrames.popFirst() {
                            fragment.finalize(success: false)
                            dropped += 1
                        }
                        if dropped > 0 {
                            log.error(
                                "Dropping \(dropped) incomplete fragments for IP ID \(reassemblyState?.reassemblyID ?? 0)"
                            )
                        }
                    } else if forceFlush && reassemblyState?.inputReassemblyFrames.count == 0 {
                        // If all of our fragments have been processed wipe out the reassemblyState
                        reassemblyState = nil
                    }
                }
                // Only update the stored reassembly ID when processing a real fragment and not on force flush
                if !forceFlush {
                    if reassemblyState == nil {
                        reassemblyState = IPv4ReassemblyState(reassemblyID: ipID)
                    } else {
                        reassemblyState?.reassemblyID = ipID
                    }
                }
            }

            mutating func processInboundFrames(_ log: borrowing NetworkLoggerState, _ inboundFrames: inout FrameArray) {
                let localAddress: UInt32 = self.localAddress.addressValue
                let remoteAddress: UInt32 = self.remoteAddress.addressValue
                let mask = (0xF000_0000 as UInt32).bigEndian
                let subnet = (0xE000_0000 as UInt32).bigEndian

                // IP fragments are not common so preserve a fast-path that just loops inboundFrames in-place
                var hadFragments = false
                // If fragments are present, hadFragments will be set and metadataComplete will not be set on the frame.
                inboundFrames.iterateMutableFrames { frame in
                    let originalFrameLength = frame.unclaimedLength
                    var versionAndHeaderLength: UInt8 = 0
                    var tos: UInt8 = 0
                    var totalLength: UInt16 = 0
                    var ttl: UInt8 = 0
                    var destinationAddressValue: UInt32 = 0
                    var checksum: UInt16 = 0
                    var identifier: UInt16 = 0
                    var offset: UInt16 = 0

                    let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                        try read.uint8(&versionAndHeaderLength)
                        try read.uint8(&tos)
                        try read.uint16NetworkByteOrder(&totalLength)
                        try read.uint16NetworkByteOrder(&identifier)
                        try read.uint16NetworkByteOrder(&offset)
                        try read.uint8(&ttl)
                        try read.uint8(expect: self.ipProtocolNumber)
                        try read.uint16(&checksum)
                        try read.uint32(expect: remoteAddress)
                        try read.uint32(&destinationAddressValue)
                    }

                    guard result.isValid else {
                        log.info("Failed to parse IPv4 header: \(result)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    guard originalFrameLength >= IPv4Instance.headerLength else {
                        log.error("Received IPv4 packet with incorrect length \(originalFrameLength)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    let version = UInt8(versionAndHeaderLength >> 4)
                    guard version == Version.v4.rawValue else {
                        log.error("Invalid IPv4 version: \(version)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    let headerLengthLastFour = UInt8(versionAndHeaderLength & 0x0F)
                    let headerLength = UInt32(headerLengthLastFour << 2)

                    guard headerLength >= IPv4Instance.headerLength else {
                        log.error("Invalid header length: \(headerLength)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    guard headerLength <= originalFrameLength else {
                        log.error("Invalid header length: \(headerLength) > \(originalFrameLength)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    guard
                        destinationAddressValue == localAddress || (destinationAddressValue & mask == subnet)
                            || destinationAddressValue == IPv4Address.broadcast.addressValue
                            || (self.broadcast.addressValue != 0
                                && destinationAddressValue == self.broadcast.addressValue)
                            || ((self.broadcast.addressValue != 0 && self.netmask.addressValue != 0)
                                && destinationAddressValue == (self.broadcast.addressValue & self.netmask.addressValue))
                    else {
                        log.error("Received local address \(destinationAddressValue) != \(localAddress)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    guard totalLength == originalFrameLength else {
                        log.error(
                            "Received length mismatch with IP total length \(totalLength) != \(originalFrameLength)"
                        )
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    guard headerLength <= totalLength else {
                        log.error("Invalid header length (greater than IP length): \(headerLength) > \(totalLength)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    // IP fragment detected, set hadFragments for future reassembly processing
                    if offset & UInt16(IPMoreFragmentsFlag | IPFragmentOffsetMask) != 0 {
                        if frame.isSingleIPAggregate {
                            log.fault("Received fragment on a super-packet with length: \(originalFrameLength)")
                            return .removeFrameAndContinue
                        }
                        hadFragments = true
                        return .continueIterating
                    }

                    let ipECN = IPProtocol.ECN(tos)
                    frame.ecnFlag = ipECN
                    switch ipECN {
                    case .ce:
                        self.counters.rxCEPackets += 1
                    case .ect0:
                        self.counters.rxECT0Packets += 1
                    case .ect1:
                        self.counters.rxECT1Packets += 1
                    default:
                        /* Do nothing */
                        break
                    }
                    if self.flags.calculateReceiveTime {
                        frame.timestamp = Frame.FrameTimestamp.receiveTime(.now)
                    }
                    if self.flags.receiveHopLimit {
                        frame.hopLimit = ttl
                    }
                    let dscpValue = tos >> 2  // IPTOS_DSCP_SHIFT
                    frame.dscpValue = dscpValue
                    frame.metadataComplete = true

                    if frame.isChecksumIPChecked {
                        guard frame.isChecksumIPValid else {
                            log.error("Invalid checksum \(checksum)")
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                    } else {
                        guard let frameChecksum = try? frame.ipChecksum(offset: 0, length: Int(headerLength)),
                            frameChecksum == 0
                        else {
                            log.error("Invalid checksum \(checksum)")
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                    }
                    _ = frame.claim(fromStart: Int(headerLength), fromEnd: originalFrameLength - Int(totalLength))
                    self.counters.rxPackets += 1
                    return .continueIterating
                }

                // No fragments, just return here as normal
                guard hadFragments || reassemblyState != nil else { return }

                // Reassembly path, build out a processedFrames array to combine both the reassembled fragments and the inbound frames.
                var processedFrames = FrameArray(capacity: inboundFrames.count)
                var reassembledFragments = FrameArray()

                while var frame = inboundFrames.popFirst() {
                    // metadataComplete signals that the frame does not need to be processed
                    guard !frame.metadataComplete else {
                        processedFrames.add(frame: frame)
                        continue
                    }
                    var identifier: UInt16 = 0
                    var offset: UInt16 = 0
                    let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                        try read.skip(4)
                        try read.uint16NetworkByteOrder(&identifier)
                        try read.uint16NetworkByteOrder(&offset)
                        try read.skip(1)
                        try read.uint8(expect: self.ipProtocolNumber)
                        try read.skip(2)
                        try read.uint32(expect: remoteAddress)
                    }
                    guard result.isValid else {
                        frame.finalize(success: false)
                        continue
                    }

                    processReassembly(log, ipID: identifier, reassembled: &reassembledFragments, forceFlush: false)
                    let currentFragmentCount = reassemblyState?.inputReassemblyFrames.count ?? 0
                    guard currentFragmentCount < IPMaxFragmentCount else {
                        frame.finalize(success: false)
                        continue
                    }

                    let fragmentByteOffset = (offset & IPFragmentOffsetMask) * 8
                    if fragmentByteOffset == 0 {
                        reassemblyState?.inputReassemblyFrames.prepend(frame: frame)
                    } else if offset & IPMoreFragmentsFlag == 0 {
                        reassemblyState?.inputReassemblyFrames.add(frame: frame)
                    } else {
                        var sorted = FrameArray()
                        var frameOffsetFound = false
                        while var existing = reassemblyState?.inputReassemblyFrames.popFirst() {
                            if !frameOffsetFound, existing.bufferLength >= IPv4Instance.headerLength {
                                var existingOffset: UInt16 = 0
                                var existingLength: UInt16 = 0
                                let result = Deserializer.deserialize(&existing, claim: false) {
                                    read throws(DeserializationError) in
                                    try read.skip(1)
                                    try read.skip(1)
                                    try read.uint16NetworkByteOrder(&existingLength)
                                    try read.skip(2)
                                    try read.uint16NetworkByteOrder(&existingOffset)
                                }
                                guard result.isValid else {
                                    sorted.add(frame: existing)
                                    continue
                                }
                                existingOffset = existingOffset & IPFragmentOffsetMask
                                let existingByteOffset = existingOffset * 8
                                let predecessorEnd =
                                    UInt32(existingByteOffset) + UInt32(existingLength)
                                    - UInt32(IPv4Instance.headerLength)
                                if UInt32(fragmentByteOffset) == predecessorEnd {
                                    sorted.add(frame: existing)
                                    frameOffsetFound = true
                                    break
                                }
                            }
                            sorted.add(frame: existing)
                        }
                        sorted.add(frame: frame)
                        if frameOffsetFound {
                            while let remaining = reassemblyState?.inputReassemblyFrames.popFirst() {
                                sorted.add(frame: remaining)
                            }
                        }
                        reassemblyState?.inputReassemblyFrames.add(frames: sorted)
                    }
                    self.counters.rxPackets += 1
                }
                processReassembly(log, ipID: 0, reassembled: &reassembledFragments, forceFlush: true)
                processedFrames.add(frames: reassembledFragments)
                inboundFrames.add(frames: processedFrames)
            }

            func prepareOutboundFrames(_ outboundFrames: inout FrameArray) {
                outboundFrames.iterateMutableFrames { frame in
                    _ = frame.claim(fromStart: IPv4Instance.headerLength)
                    return true
                }
            }

            func setChecksumValue(frame: inout Frame, value: UInt16) {
                let checksumResult = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                    try write.skip(10)
                    try write.uint16(value)
                }
                if !checksumResult.isValid {
                    Logger.proto.error("Serializing IPv4 checksum failed with result: \(checksumResult)")
                }
            }

            mutating func writeOutboundFrames(
                _ frames: inout FrameArray,
                lower: OutboundDatagramLinkage,
                selfReference: ProtocolInstanceReference
            ) {
                frames.iterateMutableFrames { frame in
                    guard frame.unclaim(fromStart: IPv4Instance.headerLength) else {
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    let totalLength = UInt16(frame.unclaimedLength)
                    let localAddressValue = self.localAddress.addressValue
                    let remoteAddressValue = self.remoteAddress.addressValue
                    let versionAndHeaderLength: UInt8 = 0x45
                    var tos: UInt8 = frame.ecnFlag.rawValue

                    var dscpValue = frame.dscpValue ?? 0
                    if dscpValue == 0, let pathDSCP = self.pathProperties.dscpValue {
                        dscpValue = pathDSCP
                    }
                    if dscpValue != 0 {
                        tos |= (dscpValue << 2)  // IPTOS_DSCP_SHIFT
                    }

                    let enableFragmentation: Bool
                    if let fragmentationOverride = frame.fragmentationOverride {
                        enableFragmentation = fragmentationOverride
                    } else {
                        enableFragmentation = self.flags.enableFragmentation
                    }

                    // Payload is the unclaimed bytes beyond the IPv4 header.
                    let payloadLength = frame.unclaimedLength - IPv4Instance.headerLength
                    // MTU minus the header gives the correct fragment payload room
                    let mtu = self.pathProperties.mtu
                    var maxPayloadPerFragment = 0
                    if mtu > IPv4Instance.headerLength {
                        maxPayloadPerFragment = mtu - IPv4Instance.headerLength
                    }
                    // Handle fragmentation if payloadLength is greater than maxPayloadPerFragment and enableFragmentation is enabled
                    if enableFragmentation && maxPayloadPerFragment > 0 && payloadLength > maxPayloadPerFragment {
                        // MTU-splitting path: fragment the oversized datagram.
                        var randomNumber = SystemRandomNumberGenerator()
                        let identifier = UInt16(truncatingIfNeeded: randomNumber.next())
                        // Align fragment payload to blocks of 8 bytes - RFC 791.
                        let fragmentRoom = maxPayloadPerFragment - (maxPayloadPerFragment % 8)
                        guard fragmentRoom > 0 else {
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                        // Make sure the count of fragments is correctly accounted for
                        let fragmentCount = (payloadLength + fragmentRoom - 1) / fragmentRoom
                        // Will trim down later to the actual size
                        let maxFragmentFrameSize = IPv4Instance.headerLength + fragmentRoom
                        guard
                            var allocatedFrames = try? lower.invokeGetDatagramsToSend(
                                selfReference,
                                maximumDatagramCount: fragmentCount,
                                minimumDatagramSize: maxFragmentFrameSize
                            )
                        else {
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                        var cursor = 0
                        var fragmentationSucceeded = true
                        var fragmentFrames = FrameArray()
                        while cursor < payloadLength {
                            // Determine if last or how large the chunk length is
                            let remaining = payloadLength - cursor
                            let isLast = remaining <= fragmentRoom
                            let chunkLength = isLast ? remaining : fragmentRoom
                            // Create the fragment frame with this chunk length
                            let fragmentFrameSize = IPv4Instance.headerLength + chunkLength
                            guard var fragmentFrame = allocatedFrames.popFirst() else {
                                fragmentationSucceeded = false
                                break
                            }
                            if fragmentFrameSize < maxFragmentFrameSize {
                                // Trim the frame allocated at the max fragment size down to this (smaller, final) fragment's actual size.
                                guard fragmentFrame.collapse(to: fragmentFrameSize) else {
                                    fragmentFrame.finalize(success: false)
                                    fragmentationSucceeded = false
                                    break
                                }
                            }
                            // MF bit is always set except for the last fragment
                            let ipOff = UInt16(isLast ? 0 : 0x2000) | UInt16(cursor / 8)
                            let fragmentTotalLength = UInt16(IPv4Instance.headerLength + chunkLength)
                            let result = Serializer.serialize(&fragmentFrame, claim: false) {
                                write throws(SerializationError) in
                                try write.uint8(versionAndHeaderLength)
                                try write.uint8(tos)
                                try write.uint16NetworkByteOrder(fragmentTotalLength)
                                try write.uint16NetworkByteOrder(identifier)
                                try write.uint16NetworkByteOrder(ipOff)
                                try write.uint8(self.ttl)
                                try write.uint8(self.ipProtocolNumber)
                                try write.uint16(0)  // Checksum
                                try write.uint32(localAddressValue)
                                try write.uint32(remoteAddressValue)
                            }
                            guard result.isValid else {
                                Logger.proto.error("Serializing IPv4 fragment failed with result: \(result)")
                                fragmentFrame.finalize(success: false)
                                fragmentationSucceeded = false
                                break
                            }
                            let copied = frame.copyInto(
                                &fragmentFrame,
                                atOffset: IPv4Instance.headerLength,
                                fromOffset: IPv4Instance.headerLength + cursor,
                                length: chunkLength
                            )
                            guard copied == chunkLength else {
                                fragmentFrame.finalize(success: false)
                                fragmentationSucceeded = false
                                break
                            }
                            do throws(ChecksumError) {
                                if self.flags.csumOffload {
                                    fragmentFrame.checksumOffloadFlags = ChecksumFlags.ip.rawValue
                                } else {
                                    let checksumValue = try fragmentFrame.ipChecksum(offset: 0, length: 20)
                                    self.setChecksumValue(frame: &fragmentFrame, value: checksumValue)
                                }
                            } catch {
                                Logger.proto.error("Failed to compute IPv4 fragment checksum")
                                fragmentFrame.finalize(success: false)
                                fragmentationSucceeded = false
                                break
                            }
                            self.counters.txPackets += 1
                            fragmentFrames.add(frame: fragmentFrame)
                            cursor += chunkLength
                        }
                        frame.finalize(success: fragmentationSucceeded)
                        if fragmentationSucceeded {
                            return .replaceWithFramesAndContinue(fragmentFrames)
                        }
                        if !allocatedFrames.isEmpty {
                            allocatedFrames.finalizeAllFramesAsFailed()
                        }
                        // This is a case where something went wrong on fragmentation and we need to remove any fragments that were created
                        fragmentFrames.finalizeAllFramesAsFailed()
                        return .removeFrameAndContinue
                    }

                    // No fragmentation, standard outbound path
                    let offset: UInt16 = 0x4000  // Don't Fragment (IP_DF)
                    let identifier: UInt16 = 0

                    let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                        try write.uint8(versionAndHeaderLength)
                        try write.uint8(tos)
                        try write.uint16NetworkByteOrder(totalLength)
                        try write.uint16NetworkByteOrder(identifier)
                        try write.uint16NetworkByteOrder(offset)
                        try write.uint8(self.ttl)
                        try write.uint8(self.ipProtocolNumber)
                        try write.uint16(0)  // Checksum
                        try write.uint32(localAddressValue)
                        try write.uint32(remoteAddressValue)
                    }
                    if !result.isValid {
                        Logger.proto.error("Serializing IPv4 packet failed with result: \(result)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    do throws(ChecksumError) {
                        if self.flags.corruptChecksums {
                            if !self.flags.didCorruptChecksum {
                                // Invalid checksum
                                self.setChecksumValue(frame: &frame, value: UInt16(0xbeef))
                                self.flags.didCorruptChecksum = true
                            } else {
                                // Real checksum
                                let checksumValue = try frame.ipChecksum(offset: 0, length: 20)
                                self.setChecksumValue(frame: &frame, value: checksumValue)
                                self.flags.didCorruptChecksum = false
                            }
                        } else {
                            if self.flags.csumOffload {
                                frame.checksumOffloadFlags = 0x04  // CSUM_IP
                            } else {
                                let checksumValue = try frame.ipChecksum(offset: 0, length: 20)
                                self.setChecksumValue(frame: &frame, value: checksumValue)
                            }
                        }
                    } catch {
                        Logger.proto.error("Failed to finalize IP checksum")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    self.counters.txPackets += 1
                    return .continueIterating
                }
            }
        }

        struct IPv6Instance: ~Copyable {
            var ipProtocolNumber: UInt8 = 0
            var localAddress = IPv6Address.any
            var remoteAddress = IPv6Address.any

            var flowLabel: UInt32 = 0
            var hopLimit: UInt8 = 64

            var flags = IPInstanceFlags()
            var counters = IPCounters()
            var pathProperties = IPPathProperties()
            var reassemblyState: IPv6ReassemblyState?

            static let fragmentExtensionHeader: UInt8 = 44
            static let hopByHopExtensionHeader: UInt8 = 0
            static let routingExtensionHeader: UInt8 = 43
            static let destinationOptionsExtensionHeader: UInt8 = 60
            static let fragmentExtensionHeaderLength = 8
            static let ip6fOffMask: UInt16 = 0xFFF8
            static let ip6fMoreFragmentMask: UInt16 = 0x0001

            struct IPv6ReassemblyState: ~Copyable {
                var reassemblyID: UInt32
                var inputReassemblyFrames = FrameArray()
            }

            struct IPv6FragmentValues {
                var fragmentOffset: UInt16
                var moreFragments: Bool
                var payloadOffset: Int
                var innerLength: Int
                var nextProtocol: UInt8
            }

            static var minimalMTU: Int {
                1280
            }

            static var headerLength: Int {
                MemoryLayout<UInt32>.size * 10
            }

            func incrementByHeaderLength(_ value: Int) -> Int {
                if Int.max - value < IPv6Instance.headerLength {
                    return Int.max
                }
                return value + IPv6Instance.headerLength
            }

            static func parseFragmentValues(
                _ frame: inout Frame,
                ipProtocolNumber: UInt8
            ) -> IPv6FragmentValues? {
                var payloadLength: UInt16 = 0
                var firstProto: UInt8 = 0
                var fragmentOffset: UInt16 = 0
                var moreFragments = false
                var headerOffset = IPv6Instance.headerLength
                var nextProtocol: UInt8 = 0
                var foundFragment = false

                let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                    try read.skip(4)
                    try read.uint16NetworkByteOrder(&payloadLength)
                    try read.uint8(&firstProto)
                    try read.skip(1)
                    try read.skip(32)  // src and dst addresses
                    var currentProto = firstProto
                    extensionHeaderLoop: while currentProto != ipProtocolNumber {
                        switch currentProto {
                        case IPv6Instance.fragmentExtensionHeader:
                            var nextProto: UInt8 = 0
                            var offsetAndFlags: UInt16 = 0
                            try read.uint8(&nextProto)
                            try read.skip(1)
                            try read.uint16NetworkByteOrder(&offsetAndFlags)
                            try read.skip(4)
                            fragmentOffset = offsetAndFlags & IPv6Instance.ip6fOffMask
                            moreFragments = (offsetAndFlags & IPv6Instance.ip6fMoreFragmentMask) != 0
                            nextProtocol = nextProto
                            headerOffset += IPv6Instance.fragmentExtensionHeaderLength
                            currentProto = nextProto
                            foundFragment = true
                            break extensionHeaderLoop
                        case IPv6Instance.hopByHopExtensionHeader,
                            IPv6Instance.routingExtensionHeader,
                            IPv6Instance.destinationOptionsExtensionHeader:
                            var extensionNext: UInt8 = 0
                            var extensionLength: UInt8 = 0
                            try read.uint8(&extensionNext)
                            try read.uint8(&extensionLength)
                            let extensionTotal = (Int(extensionLength) + 1) * 8
                            try read.skip(extensionTotal - 2)
                            headerOffset += extensionTotal
                            currentProto = extensionNext
                        default:
                            break extensionHeaderLoop
                        }
                    }
                }

                guard result.isValid && foundFragment else { return nil }
                let innerLength = Int(payloadLength) - (headerOffset - IPv6Instance.headerLength)
                guard innerLength >= 0 else { return nil }
                return IPv6FragmentValues(
                    fragmentOffset: fragmentOffset,
                    moreFragments: moreFragments,
                    payloadOffset: headerOffset,
                    innerLength: innerLength,
                    nextProtocol: nextProtocol
                )
            }

            mutating func appendReassembledPackets(
                _ log: borrowing NetworkLoggerState,
                reassembled: inout FrameArray
            ) {
                guard let empty = reassemblyState?.inputReassemblyFrames.isEmpty, !empty else {
                    return
                }
                guard let reassemblyID = reassemblyState?.reassemblyID else {
                    return
                }
                // Overlapping IPv6 fragments are not allowed due [RFC 5722]
                // Verify all stored fragments are contiguous and in offset order
                var complete = false
                var expectedOffset: UInt16 = 0
                var firstTrafficClass: UInt8 = 0
                var firstHopLimit: UInt8 = 0
                var firstNextProtocol: UInt8 = 0
                var isFirstFragment = true
                reassemblyState?.inputReassemblyFrames.iterateMutableFrames { fragment in
                    guard
                        let values = IPv6Instance.parseFragmentValues(
                            &fragment,
                            ipProtocolNumber: self.ipProtocolNumber
                        )
                    else {
                        log.info("Reassembly frame is no longer valid for ID \(reassemblyID)")
                        return false
                    }
                    if isFirstFragment {
                        // Read traffic class and hop limit directly from the IPv6 base header
                        let result = Deserializer.deserialize(&fragment, claim: false) {
                            read throws(DeserializationError) in
                            var flow: UInt32 = 0
                            try read.uint32NetworkByteOrder(&flow)
                            firstTrafficClass = UInt8((flow >> 20) & 0xFF)
                            try read.skip(3)  // payload length + next header
                            try read.uint8(&firstHopLimit)
                        }
                        guard result.isValid else {
                            return false
                        }
                        firstNextProtocol = values.nextProtocol
                        isFirstFragment = false
                    }
                    guard values.fragmentOffset == expectedOffset else {
                        log.debug("IPv6 fragment out of order for ID \(reassemblyID)")
                        return false
                    }
                    let (next, overflow) = expectedOffset.addingReportingOverflow(UInt16(values.innerLength))
                    guard !overflow else {
                        log.error("Fragment offset overflow for IPv6 ID \(reassemblyID)")
                        return false
                    }
                    expectedOffset = next
                    if !values.moreFragments {
                        complete = true
                        return false
                    }
                    return true
                }
                guard complete else {
                    log.debug("Fragments for IPv6 ID \(reassemblyID) incomplete")
                    return
                }
                // Create a new frame for reassembly
                let newFrameLength = IPv6Instance.headerLength + Int(expectedOffset)
                var newFrame = Frame(count: newFrameLength)

                // Copy the IPv6 header from the first fragment
                let headerCopied = reassemblyState?.inputReassemblyFrames.peekFirstFrame { first in
                    first.copyInto(&newFrame, length: IPv6Instance.headerLength)
                }
                guard headerCopied == IPv6Instance.headerLength else {
                    log.error("Failed to copy IPv6 header from first fragment (ID \(reassemblyID))")
                    newFrame.finalize(success: false)
                    return
                }
                // Update payload length and next header based on the first fragments values
                let headerUpdateResult = Serializer.serialize(&newFrame, claim: false) {
                    write throws(SerializationError) in
                    try write.skip(4)
                    try write.uint16NetworkByteOrder(expectedOffset)
                    try write.uint8(firstNextProtocol)
                }
                guard headerUpdateResult.isValid else {
                    log.error("Failed to update IPv6 header in reassembled frame (ID \(reassemblyID))")
                    newFrame.finalize(success: false)
                    return
                }
                // Claim the IPv6 header so subsequent payload writes target the payload region
                guard newFrame.claim(fromStart: IPv6Instance.headerLength) else {
                    log.error("Failed to claim IPv6 header in reassembled frame (ID \(reassemblyID))")
                    newFrame.finalize(success: false)
                    return
                }
                // Copy each fragments inner payload contiguously into the new frame
                var writeOffset = 0
                var copyFailed = false
                reassemblyState?.inputReassemblyFrames.iterateMutableFrames { fragment in
                    guard
                        let values = IPv6Instance.parseFragmentValues(
                            &fragment,
                            ipProtocolNumber: self.ipProtocolNumber
                        )
                    else {
                        log.error("Failed to re-parse fragment during copy for IPv6 ID \(reassemblyID)")
                        copyFailed = true
                        return false
                    }
                    let copied = fragment.copyInto(
                        &newFrame,
                        atOffset: writeOffset,
                        fromOffset: values.payloadOffset,
                        length: values.innerLength
                    )
                    guard copied == values.innerLength else {
                        log.error(
                            "Fragment payload copy mismatch for IPv6 ID \(reassemblyID): \(copied) != \(values.innerLength)"
                        )
                        copyFailed = true
                        return false
                    }
                    writeOffset += values.innerLength
                    return true
                }

                guard !copyFailed else {
                    newFrame.finalize(success: false)
                    return
                }

                log.debug("IPv6 reassembly complete for ID \(reassemblyID), total length \(newFrameLength)")

                newFrame.dscpValue = firstTrafficClass >> 2
                if self.flags.receiveHopLimit {
                    newFrame.hopLimit = firstHopLimit
                }
                if self.flags.calculateReceiveTime {
                    newFrame.timestamp = Frame.FrameTimestamp.receiveTime(.now)
                }
                newFrame.metadataComplete = true
                reassembled.add(frame: newFrame)

                // Finalize the original fragment frames.
                while var fragment = reassemblyState?.inputReassemblyFrames.popFirst() {
                    fragment.finalize(success: true)
                }
            }

            mutating func processReassembly(
                _ log: borrowing NetworkLoggerState,
                fragmentID: UInt32,
                reassembled: inout FrameArray,
                forceFlush: Bool
            ) {
                let hasAccumulatedFragments = reassemblyState?.inputReassemblyFrames.isEmpty == false
                let isNewID = reassemblyState?.reassemblyID != fragmentID

                if hasAccumulatedFragments && (isNewID || forceFlush) {
                    appendReassembledPackets(log, reassembled: &reassembled)
                    // Only discard buffered fragments when the IP ID change
                    if isNewID && !forceFlush {
                        var dropped = 0
                        while var fragment = reassemblyState?.inputReassemblyFrames.popFirst() {
                            fragment.finalize(success: false)
                            dropped += 1
                        }
                        if dropped > 0 {
                            log.error(
                                "Dropping \(dropped) incomplete IPv6 fragments for ID \(reassemblyState?.reassemblyID ?? 0)"
                            )
                        }
                    }
                }
                if !forceFlush {
                    if reassemblyState == nil {
                        reassemblyState = IPv6ReassemblyState(reassemblyID: fragmentID)
                    } else {
                        reassemblyState?.reassemblyID = fragmentID
                    }
                }
            }

            mutating func processInboundFrames(_ log: borrowing NetworkLoggerState, _ inboundFrames: inout FrameArray) {

                let localAddress = self.localAddress.addressValue
                let remoteAddress = self.remoteAddress.addressValue
                // IP fragments are not common so preserve a fast-path that just loops inboundFrames in-place
                var hadFragments = false
                // If fragments are present, hadFragments will be set and metadataComplete will not be set on the frame.
                inboundFrames.iterateMutableFrames { frame in
                    let originalFrameLength = frame.unclaimedLength
                    var flow: UInt32 = 0
                    var payloadLength: UInt16 = 0
                    var hopLimit: UInt8 = 0
                    var nextProtocol: UInt8 = 0

                    // Do not completely claim the header so any future parsing
                    let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                        try read.uint32NetworkByteOrder(&flow)
                        try read.uint16NetworkByteOrder(&payloadLength)
                        try read.uint8(&nextProtocol)
                        try read.uint8(&hopLimit)
                        try read.uint32(expect: remoteAddress.0)
                        try read.uint32(expect: remoteAddress.1)
                        try read.uint32(expect: remoteAddress.2)
                        try read.uint32(expect: remoteAddress.3)
                        try read.uint32(expect: localAddress.0)
                        try read.uint32(expect: localAddress.1)
                        try read.uint32(expect: localAddress.2)
                        try read.uint32(expect: localAddress.3)
                    }

                    guard result.isValid else {
                        log.info("Failed to parse IPv6 header: \(result)")

                        // Keep processing other frames even if some are invalid.
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    guard originalFrameLength >= IPv6Instance.headerLength else {
                        log.error("Received IPv6 packet with incorrect length \(originalFrameLength)")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    let version = UInt8(flow >> 28)  // Get the first 4 high order bits for version
                    guard version == Version.v6.rawValue else {
                        log.error("Not an IPv6 packet")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    let ipv6Length = (payloadLength + UInt16(IPv6Instance.headerLength))
                    guard ipv6Length == originalFrameLength else {
                        log.error(
                            "Received IPv6 packet with incorrect length, expected \(ipv6Length) received \(originalFrameLength)"
                        )
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    var currentProto = nextProtocol
                    var headerOffset = IPv6Instance.headerLength
                    var isFragment = false
                    var parseError = false
                    if currentProto != self.ipProtocolNumber {
                        if frame.isSingleIPAggregate {
                            log.fault(
                                "Received IPv6 extension-headers on a super-packet with length \(originalFrameLength)"
                            )
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                        let extensionResult = Deserializer.deserialize(&frame, claim: false) {
                            read throws(DeserializationError) in
                            try read.skip(IPv6Instance.headerLength)
                            extensionHeaderLoop: while currentProto != self.ipProtocolNumber {
                                switch currentProto {
                                case IPv6Instance.fragmentExtensionHeader:
                                    var nextProto: UInt8 = 0
                                    try read.uint8(&nextProto)
                                    try read.skip(1)
                                    try read.skip(2)
                                    try read.skip(4)
                                    headerOffset += IPv6Instance.fragmentExtensionHeaderLength
                                    currentProto = nextProto
                                    isFragment = true
                                    break extensionHeaderLoop
                                case IPv6Instance.hopByHopExtensionHeader,
                                    IPv6Instance.routingExtensionHeader,
                                    IPv6Instance.destinationOptionsExtensionHeader:
                                    var extensionNext: UInt8 = 0
                                    var extensionLength: UInt8 = 0
                                    try read.uint8(&extensionNext)
                                    try read.uint8(&extensionLength)
                                    let extensionTotal = (Int(extensionLength) + 1) * 8
                                    try read.skip(extensionTotal - 2)
                                    headerOffset += extensionTotal
                                    currentProto = extensionNext
                                default:
                                    break extensionHeaderLoop
                                }
                            }
                        }
                        if !extensionResult.isValid {
                            log.info("Failed to parse IPv6 extension headers: \(extensionResult)")
                            parseError = true
                        }
                    }
                    guard !parseError && currentProto == self.ipProtocolNumber else {
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }
                    // Fragment detected, leave the fraim unclaimed and defer to the reassembly path
                    if isFragment {
                        hadFragments = true
                        return .continueIterating
                    }

                    let trafficClassShift = flow >> 4
                    let trafficClass = UInt8(trafficClassShift & 0xFF)
                    let ipECN = IPProtocol.ECN(UInt8(trafficClass))
                    frame.ecnFlag = ipECN
                    switch ipECN {
                    case .ce:
                        self.counters.rxCEPackets += 1
                    case .ect0:
                        self.counters.rxECT0Packets += 1
                    case .ect1:
                        self.counters.rxECT1Packets += 1
                    default:
                        /* Do nothing */
                        break
                    }
                    if self.flags.calculateReceiveTime {
                        frame.timestamp = Frame.FrameTimestamp.receiveTime(.now)
                    }
                    if self.flags.receiveHopLimit {
                        frame.hopLimit = hopLimit
                    }
                    frame.dscpValue = trafficClass >> 2
                    frame.metadataComplete = true

                    _ = frame.claim(
                        fromStart: headerOffset,
                        fromEnd: originalFrameLength - (Int(payloadLength) + IPv6Instance.headerLength)
                    )
                    self.counters.rxPackets += 1
                    return .continueIterating
                }

                // Fast path: no fragments and no prior reassembly state, return here
                guard hadFragments || reassemblyState != nil else { return }

                // Fragment reassembly path, this is not common so reparse and build up the reassembly queue
                var processedFrames = FrameArray(capacity: inboundFrames.count)
                var reassembledFragments = FrameArray()

                while var frame = inboundFrames.popFirst() {
                    // metadataComplete signals that the frame does not need to be processed
                    guard !frame.metadataComplete else {
                        processedFrames.add(frame: frame)
                        continue
                    }

                    var fragmentID: UInt32 = 0
                    var fragmentOffset: UInt16 = 0
                    var moreFragments = false
                    var foundFragment = false
                    let parseResult = Deserializer.deserialize(&frame, claim: false) {
                        read throws(DeserializationError) in
                        try read.skip(4)
                        try read.skip(2)
                        var firstProto: UInt8 = 0
                        try read.uint8(&firstProto)
                        try read.skip(1)
                        try read.skip(32)  // source and destination address
                        var currentProto = firstProto
                        extensionHeaderLoop: while currentProto != self.ipProtocolNumber {
                            switch currentProto {
                            case IPv6Instance.fragmentExtensionHeader:
                                var nextProto: UInt8 = 0
                                var offsetFlags: UInt16 = 0
                                var identifier: UInt32 = 0
                                try read.uint8(&nextProto)
                                try read.skip(1)
                                try read.uint16NetworkByteOrder(&offsetFlags)
                                try read.uint32(&identifier)
                                fragmentOffset = offsetFlags & IPv6Instance.ip6fOffMask
                                moreFragments = (offsetFlags & IPv6Instance.ip6fMoreFragmentMask) != 0
                                fragmentID = identifier
                                currentProto = nextProto
                                foundFragment = true
                                break extensionHeaderLoop
                            case IPv6Instance.hopByHopExtensionHeader,
                                IPv6Instance.routingExtensionHeader,
                                IPv6Instance.destinationOptionsExtensionHeader:
                                var extensionNext: UInt8 = 0
                                var extensionLength: UInt8 = 0
                                try read.uint8(&extensionNext)
                                try read.uint8(&extensionLength)
                                try read.skip((Int(extensionLength) + 1) * 8 - 2)
                                currentProto = extensionNext
                            default:
                                break extensionHeaderLoop
                            }
                        }
                    }
                    guard parseResult.isValid && foundFragment else {
                        frame.finalize(success: false)
                        continue
                    }
                    processReassembly(
                        log,
                        fragmentID: fragmentID,
                        reassembled: &reassembledFragments,
                        forceFlush: false
                    )

                    let currentFragmentCount = reassemblyState?.inputReassemblyFrames.count ?? 0
                    guard currentFragmentCount < IPMaxFragmentCount else {
                        log.error("Too many fragments for IPv6 ID \(fragmentID)")
                        frame.finalize(success: false)
                        continue
                    }

                    // Insert fragment in offset order, if not, sort them
                    if fragmentOffset == 0 {
                        reassemblyState?.inputReassemblyFrames.prepend(frame: frame)
                    } else if !moreFragments {
                        reassemblyState?.inputReassemblyFrames.add(frame: frame)
                    } else {
                        // Sort the fragments in offset order
                        var sorted = FrameArray()
                        var predecessorFound = false
                        while var existing = reassemblyState?.inputReassemblyFrames.popFirst() {
                            if !predecessorFound,
                                let existingValue = IPv6Instance.parseFragmentValues(
                                    &existing,
                                    ipProtocolNumber: self.ipProtocolNumber
                                )
                            {
                                let predecessorEnd =
                                    UInt32(existingValue.fragmentOffset) + UInt32(existingValue.innerLength)
                                if UInt32(fragmentOffset) == predecessorEnd {
                                    sorted.add(frame: existing)
                                    predecessorFound = true
                                    break
                                }
                            }
                            sorted.add(frame: existing)
                        }
                        sorted.add(frame: frame)
                        if predecessorFound {
                            while let remaining = reassemblyState?.inputReassemblyFrames.popFirst() {
                                sorted.add(frame: remaining)
                            }
                        }
                        reassemblyState?.inputReassemblyFrames.add(frames: sorted)
                    }
                    self.counters.rxPackets += 1
                }
                processReassembly(log, fragmentID: 0, reassembled: &reassembledFragments, forceFlush: true)
                processedFrames.add(frames: reassembledFragments)
                inboundFrames.add(frames: processedFrames)
            }

            func prepareOutboundFrames(_ outboundFrames: inout FrameArray) {
                outboundFrames.iterateMutableFrames { frame in
                    if flags.useMinimumMTU {
                        var trailerClaim = 0
                        let frameLength = frame.unclaimedLength
                        if frameLength > IPv6Instance.minimalMTU {
                            trailerClaim = frameLength - IPv6Instance.minimalMTU
                        }
                        _ = frame.claim(fromStart: IPv6Instance.headerLength, fromEnd: trailerClaim)
                    } else {
                        _ = frame.claim(fromStart: IPv6Instance.headerLength)
                    }
                    return true
                }
            }

            mutating func writeOutboundFrames(
                _ frames: inout FrameArray,
                lower: OutboundDatagramLinkage,
                selfReference: ProtocolInstanceReference
            ) {
                frames.iterateMutableFrames { (frame: inout Frame) -> FrameArray.FrameIterationResult in
                    _ = frame.unclaim(fromStart: IPv6Instance.headerLength)

                    let payloadLength = frame.unclaimedLength - IPv6Instance.headerLength
                    let localAddressValue = self.localAddress.addressValue
                    let remoteAddressValue = self.remoteAddress.addressValue

                    var flow: UInt32 = 0x0000_0060 | (self.flowLabel & UInt32(0xffff_0f00))

                    switch frame.ecnFlag {
                    case .ect0: flow |= 0x0000_1000
                    case .ect1: flow |= 0x0000_2000
                    case .ce: flow |= 0x0000_3000
                    default: break
                    }
                    var dscpValue = frame.dscpValue ?? 0
                    if dscpValue == 0, let pathDSCP = self.pathProperties.dscpValue {
                        dscpValue = pathDSCP
                    }
                    if dscpValue != 0 {
                        flow |= UInt32(bigEndian: (UInt32(dscpValue) << 22) & 0x0fc0_0000)  // IP6FLOW_DSCP_SHIFT
                    }

                    let enableFragmentation: Bool
                    if let fragmentationOverride = frame.fragmentationOverride {
                        enableFragmentation = fragmentationOverride
                    } else {
                        enableFragmentation = self.flags.enableFragmentation
                    }

                    // IPv6 header + Fragment Extension Header
                    let ipv6CompleteHeaderLength =
                        IPv6Instance.headerLength + IPv6Instance.fragmentExtensionHeaderLength
                    let mtu = self.pathProperties.mtu
                    var maxPayloadPerFragment = 0
                    if mtu > ipv6CompleteHeaderLength {
                        maxPayloadPerFragment = mtu - ipv6CompleteHeaderLength
                    }

                    // Handle fragmentation if payloadLength is greater than maxPayloadPerFragment and enableFragmentation is enabled
                    if enableFragmentation && maxPayloadPerFragment > 0 && payloadLength > maxPayloadPerFragment {
                        var randomNumber = SystemRandomNumberGenerator()
                        let fragmentID = UInt32(truncatingIfNeeded: randomNumber.next())
                        // Align fragment payload to blocks of 8 bytes - RFC 2460
                        let fragmentRoom = maxPayloadPerFragment - (maxPayloadPerFragment % 8)
                        guard fragmentRoom > 0 else {
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                        // Make sure the count of fragments is correctly accounted for
                        let fragmentCount = (payloadLength + fragmentRoom - 1) / fragmentRoom
                        // Will trim down later to the actual size
                        let maxFragmentFrameSize = ipv6CompleteHeaderLength + fragmentRoom
                        guard
                            var allocatedFrames = try? lower.invokeGetDatagramsToSend(
                                selfReference,
                                maximumDatagramCount: fragmentCount,
                                minimumDatagramSize: maxFragmentFrameSize
                            )
                        else {
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                        var cursor = 0
                        var fragmentationSucceeded = true
                        var fragmentFrames = FrameArray()
                        while cursor < payloadLength {
                            // Determine if last or how large the chunk length is
                            let remaining = payloadLength - cursor
                            let isLast = remaining <= fragmentRoom
                            let chunkLength = isLast ? remaining : fragmentRoom
                            // Fragment Extension Header + this chunk's payload.
                            let fragmentLength = UInt16(chunkLength + IPv6Instance.fragmentExtensionHeaderLength)
                            // Fragment offset flags
                            let offsetFlags = UInt16(cursor) | (isLast ? 0 : UInt16(IPv6Instance.ip6fMoreFragmentMask))
                            let fragmentFrameSize = ipv6CompleteHeaderLength + chunkLength
                            guard var fragmentFrame = allocatedFrames.popFirst() else {
                                fragmentationSucceeded = false
                                break
                            }
                            if fragmentFrameSize < maxFragmentFrameSize {
                                // Trim the frame allocated at the max fragment size down to this (smaller, final) fragment's actual size.
                                guard fragmentFrame.collapse(to: fragmentFrameSize) else {
                                    fragmentFrame.finalize(success: false)
                                    fragmentationSucceeded = false
                                    break
                                }
                            }
                            let result = Serializer.serialize(&fragmentFrame, claim: false) {
                                write throws(SerializationError) in
                                // IPv6 base header
                                try write.uint32(flow)
                                try write.uint16NetworkByteOrder(fragmentLength)
                                try write.uint8(IPv6Instance.fragmentExtensionHeader)
                                try write.uint8(self.hopLimit)
                                try write.uint32(localAddressValue.0)
                                try write.uint32(localAddressValue.1)
                                try write.uint32(localAddressValue.2)
                                try write.uint32(localAddressValue.3)
                                try write.uint32(remoteAddressValue.0)
                                try write.uint32(remoteAddressValue.1)
                                try write.uint32(remoteAddressValue.2)
                                try write.uint32(remoteAddressValue.3)
                                // Fragment Extension Header
                                try write.uint8(self.ipProtocolNumber)
                                try write.uint8(0)
                                try write.uint16NetworkByteOrder(offsetFlags)
                                try write.uint32(fragmentID)
                            }
                            guard result.isValid else {
                                Logger.proto.error("Serializing IPv6 fragment failed with result: \(result)")
                                fragmentFrame.finalize(success: false)
                                fragmentationSucceeded = false
                                break
                            }
                            let copied = frame.copyInto(
                                &fragmentFrame,
                                atOffset: ipv6CompleteHeaderLength,
                                fromOffset: IPv6Instance.headerLength + cursor,
                                length: chunkLength
                            )
                            guard copied == chunkLength else {
                                fragmentFrame.finalize(success: false)
                                fragmentationSucceeded = false
                                break
                            }
                            self.counters.txPackets += 1
                            fragmentFrames.add(frame: fragmentFrame)
                            cursor += chunkLength
                        }
                        frame.finalize(success: fragmentationSucceeded)
                        if fragmentationSucceeded {
                            return .replaceWithFramesAndContinue(fragmentFrames)
                        }
                        if !allocatedFrames.isEmpty {
                            allocatedFrames.finalizeAllFramesAsFailed()
                        }
                        fragmentFrames.finalizeAllFramesAsFailed()
                        return .removeFrameAndContinue
                    }
                    // Standard path
                    let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                        try write.uint32(flow)
                        try write.uint16NetworkByteOrder(UInt16(payloadLength))
                        try write.uint8(self.ipProtocolNumber)
                        try write.uint8(self.hopLimit)
                        try write.uint32(localAddressValue.0)
                        try write.uint32(localAddressValue.1)
                        try write.uint32(localAddressValue.2)
                        try write.uint32(localAddressValue.3)
                        try write.uint32(remoteAddressValue.0)
                        try write.uint32(remoteAddressValue.1)
                        try write.uint32(remoteAddressValue.2)
                        try write.uint32(remoteAddressValue.3)
                    }
                    if !result.isValid {
                        Logger.proto.error("Serializing IPv6 packet failed with result: \(result)")
                        return .continueIterating
                    }
                    self.counters.txPackets += 1
                    return .continueIterating
                }
            }
        }

        enum IPInstanceType: ~Copyable {
            case ipv4(IPv4Instance)
            case ipv6(IPv6Instance)
        }
        var instanceType: IPInstanceType = .ipv4(IPv4Instance())

        mutating func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            guard let localEndpoint = local,
                let remoteEndpoint = remote,
                case .address(let localAddress) = localEndpoint.type,
                case .address(let remoteAddress) = remoteEndpoint.type
            else {
                log.error("Invalid endpoints for IP")
                throw NetworkError.posix(EINVAL)
            }

            var ipProtocolNumber: UInt8 = 0
            var dscpValue: UInt8?
            var maximumMessageSize = 0
            var calculateReceiveTime: Bool = false
            var receiveHopLimit: Bool = false
            var enableFragmentation: Bool = false
            var corruptChecksums: Bool = false
            var useMinimumMTU: Bool = false
            var suppressLogging: Bool = false
            var netmask: UInt32 = 0
            var broadcast: UInt32 = 0
            var mtu = 0
            var ttl: UInt8 = 64
            if let parameters {
                ipProtocolNumber = parameters.ipProtocolNumber ?? 0
                if let ipOptions: ProtocolOptions<IPProtocol> = ipOptions(from: parameters) {
                    dscpValue = ipOptions.dscpValue
                    if let perProtocolOptions = ipOptions.perProtocolOptions {
                        calculateReceiveTime = perProtocolOptions.calculateReceiveTime
                        receiveHopLimit = perProtocolOptions.receiveHopLimit
                        enableFragmentation = perProtocolOptions.fragmentationEnabled ?? false
                        corruptChecksums = perProtocolOptions.corruptChecksums
                        useMinimumMTU = perProtocolOptions.useMinimumMTU
                    }
                    ttl = ipOptions.hopLimit ?? 64  // Just set the default back to 64 if not present
                }
                suppressLogging = parameters.disableLogging
            }
            var flags = IPInstanceFlags()
            flags.calculateReceiveTime = calculateReceiveTime
            flags.corruptChecksums = corruptChecksums
            flags.enableFragmentation = enableFragmentation
            flags.useMinimumMTU = useMinimumMTU
            flags.suppressLogging = suppressLogging
            flags.receiveHopLimit = receiveHopLimit

            if let path {
                maximumMessageSize = path.maximumPacketSize
                mtu = path.mtu
                flags.csumOffload = (path.hardwareChecksumFlags & 0x0000_0001) != 0
                if let interface = path.directInterface {
                    netmask = interface.ipv4Netmask?.addressValue ?? 0
                    broadcast = interface.ipv4Broadcast?.addressValue ?? 0
                }
            }

            if case .v4(let localIPv4Address, _) = localAddress.type {
                guard case .v4(let remoteIPv4Address, _) = remoteAddress.type else {
                    log.error("Local endpoint is IPv4, but remote endpoint is not IPv4")
                    throw NetworkError.posix(EINVAL)
                }

                var instance = IPv4Instance()
                instance.localAddress = localIPv4Address
                instance.remoteAddress = remoteIPv4Address
                instance.netmask = IPv4Address(netmask.bigEndian)
                instance.broadcast = IPv4Address(broadcast.bigEndian)
                instance.ipProtocolNumber = ipProtocolNumber
                instance.ipProtocolNumber = ipProtocolNumber
                instance.pathProperties.dscpValue = dscpValue
                instance.pathProperties.maximumMessageSize = maximumMessageSize
                instance.pathProperties.mtu = mtu
                instance.flags = flags
                instance.ttl = ttl
                instanceType = .ipv4(instance)
            } else if case .v6(let localIPv6Address, _) = localAddress.type {
                guard case .v6(let remoteIPv6Address, _) = remoteAddress.type else {
                    log.error("Local endpoint is IPv6, but remote endpoint is not IPv6")
                    throw NetworkError.posix(EINVAL)
                }

                var instance = IPv6Instance()
                instance.localAddress = localIPv6Address
                instance.remoteAddress = remoteIPv6Address
                instance.ipProtocolNumber = ipProtocolNumber
                instance.pathProperties.dscpValue = dscpValue
                instance.pathProperties.maximumMessageSize = maximumMessageSize
                instance.pathProperties.mtu = mtu
                instance.flags = flags
                instance.hopLimit = ttl
                var generator = SystemRandomNumberGenerator()
                instance.flowLabel = UInt32(generator.next() >> 32)
                instanceType = .ipv6(instance)
            } else {
                log.error("Unsupported address type")
                throw NetworkError.posix(ENOTSUP)
            }
        }

        mutating func teardown() {
            IPInstance.drainReassemblyQueue(&instanceType)
        }

        @inline(__always)
        private static func drainReassemblyQueue(_ instanceType: inout IPInstanceType) {
            // Make sure that there are no left over frames stranded in the reassembly queue
            switch instanceType {
            case .ipv4(var instance):
                while var fragment = instance.reassemblyState?.inputReassemblyFrames.popFirst() {
                    fragment.finalize(success: false)
                }
                instance.reassemblyState = nil
                instanceType = .ipv4(instance)
            case .ipv6(var instance):
                while var fragment = instance.reassemblyState?.inputReassemblyFrames.popFirst() {
                    fragment.finalize(success: false)
                }
                instance.reassemblyState = nil
                instanceType = .ipv6(instance)
            }
        }

        mutating func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
            repeat {
                let inboundFrames = try invokeReceiveDatagrams(maximumDatagramCount: maximumDatagramCount)
                guard var inboundFrames, !inboundFrames.isEmpty else {
                    return nil
                }
                IPInstance.processInbound(&self.instanceType, log: self.log, frames: &inboundFrames)
                guard !inboundFrames.isEmpty else {
                    log.error("Dropped inbound packets, checking for more")
                    continue
                }
                return inboundFrames
            } while true
        }

        func getDatagramsToSend(maximumDatagramCount: Int, minimumDatagramSize: Int) throws(NetworkError) -> FrameArray?
        {
            switch self.instanceType {
            case .ipv4(let instance):
                let minimumDatagramSize = instance.incrementByHeaderLength(minimumDatagramSize)
                let outboundFrames = try invokeGetDatagramsToSend(
                    maximumDatagramCount: maximumDatagramCount,
                    minimumDatagramSize: minimumDatagramSize
                )
                guard var outboundFrames else { return nil }
                instance.prepareOutboundFrames(&outboundFrames)
                return outboundFrames
            case .ipv6(let instance):
                let minimumDatagramSize = instance.incrementByHeaderLength(minimumDatagramSize)
                let outboundFrames = try invokeGetDatagramsToSend(
                    maximumDatagramCount: maximumDatagramCount,
                    minimumDatagramSize: minimumDatagramSize
                )
                guard var outboundFrames else { return nil }
                instance.prepareOutboundFrames(&outboundFrames)
                return outboundFrames
            }
        }

        mutating func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
            let lower = self.lower
            let selfReference = self.effectiveSelfReference
            IPInstance.processOutbound(
                &self.instanceType,
                lower: lower,
                selfReference: selfReference,
                datagrams: &datagrams
            )
            try invokeSendDatagrams(datagrams)
        }

        @inline(__always)
        private static func processInbound(
            _ instanceType: inout IPInstanceType,
            log: borrowing NetworkLoggerState,
            frames: inout FrameArray
        ) {
            switch instanceType {
            case .ipv4(var instance):
                instance.processInboundFrames(log, &frames)
                instanceType = .ipv4(instance)
            case .ipv6(var instance):
                instance.processInboundFrames(log, &frames)
                instanceType = .ipv6(instance)
            }
        }

        @inline(__always)
        private static func processOutbound(
            _ instanceType: inout IPInstanceType,
            lower: OutboundDatagramLinkage,
            selfReference: ProtocolInstanceReference,
            datagrams: inout FrameArray
        ) {
            switch instanceType {
            case .ipv4(var instance):
                instance.writeOutboundFrames(&datagrams, lower: lower, selfReference: selfReference)
                instanceType = .ipv4(instance)
            case .ipv6(var instance):
                instance.writeOutboundFrames(&datagrams, lower: lower, selfReference: selfReference)
                instanceType = .ipv6(instance)
            }
        }

        #if !NETWORK_EMBEDDED
        var metadata: AbstractProtocolMetadata? { nil }
        #endif
    }

    public init() {}
    public func newPerProtocolOptions() -> IPOptions? { IPOptions() }
    public func newPerProtocolOptions(from existing: IPOptions) -> IPOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> IPOptions? { IPOptions(from: serializedBytes) }
    public func newPerProtocolMetadata() -> IPMetadata? { IPMetadata() }
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        IPInstance.registerNewIP(on: context)
    }

    static let identifier = ProtocolIdentifier(name: "ip", level: .internet, mapping: .oneToOne)

    #if !NETWORK_PRIVATE
    static let definition = ProtocolDefinition<IPProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<IPProtocol> { IPProtocol.definition.protocolOptions() }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        IPProtocol().newProtocolInstance(context: context)!
    }

    #if !NETWORK_EMBEDDED
    internal static func _staticMetadata(ecnFlag: ECN) -> ProtocolMetadata<IPProtocol> {
        let metadata = IPProtocol.definition.protocolMetadata()
        metadata.perProtocolMetadata?.ecnFlag = ecnFlag
        metadata.perProtocolMetadata?.isStatic = true
        return metadata
    }

    static let nonECTMetadata = IPProtocol._staticMetadata(ecnFlag: .nonECT)
    static let ect0Metadata = IPProtocol._staticMetadata(ecnFlag: .ect0)
    static let ect1Metadata = IPProtocol._staticMetadata(ecnFlag: .ect1)
    static let ceMetadata = IPProtocol._staticMetadata(ecnFlag: .ce)

    static func staticMetadata(ecnFlag: ECN) -> ProtocolMetadata<IPProtocol> {
        switch ecnFlag {
        case .nonECT: return nonECTMetadata
        case .ect0: return ect0Metadata
        case .ect1: return ect1Metadata
        case .ce: return ceMetadata
        }
    }
    #endif
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension ProtocolOptions<IPProtocol> {
    var version: IPProtocol.Version {
        get { perProtocolOptions!.version }
        set { perProtocolOptions!.version = newValue }
    }
    var localAddressPreference: IPProtocol.AddressPreference {
        get { perProtocolOptions!.localAddressPreference }
        set { perProtocolOptions!.localAddressPreference = newValue }
    }
    public var dscpValue: UInt8? {
        get { perProtocolOptions!.dscpValue }
        set { perProtocolOptions!.dscpValue = newValue }
    }
    public var flags: IPProtocol.IPOptions.Flags {
        get { perProtocolOptions!.flags }
        set { perProtocolOptions!.flags = newValue }
    }
    public var hopLimit: UInt8? {
        get { perProtocolOptions!.hopLimit }
        set { perProtocolOptions!.hopLimit = newValue }
    }
}
