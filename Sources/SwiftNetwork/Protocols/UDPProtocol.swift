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
public struct UDPProtocol: NetworkProtocol {
    public typealias Options = UDPOptions
    public typealias Metadata = UDPMetadata
    typealias Instance = UDPInstance

    static public var headerLength: Int {
        MemoryLayout<UInt16>.size * 4
        // UDP Header
        // sourcePort: UInt16
        // destPort: UInt16
        // length: UInt16
        // checksum: UInt16
    }

    public struct UDPOptions: OptionSet, PerProtocolOptions, Sendable {
        public init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        public let rawValue: UInt8

        static public let preferNoChecksum = UDPOptions(rawValue: 1 << 0)
        static public let noMetadata = UDPOptions(rawValue: 1 << 1)
        static public let ignoreInboundChecksum = UDPOptions(rawValue: 1 << 2)
        static public let useQUICStats = UDPOptions(rawValue: 1 << 3)
        static public let fullChecksumOffload = UDPOptions(rawValue: 1 << 4)

        #if NETWORK_PRIVATE
        var privateStorage = UDPProtocolOptionsPrivateStorage()
        #endif

        init?(from serializedBytes: [UInt8]) {
            guard serializedBytes.count == 1 else {
                Logger.proto.error("Serialized bytes for UDP have unexpected length \(serializedBytes.count)")
                return nil
            }
            self.init(rawValue: serializedBytes[0])
        }
        public func serialize() -> [UInt8]? {
            Serializer.serialize { write in
                write.uint8(rawValue)
            }
        }
        public var serializeInParameters: Bool {
            false
        }
        public func deepCopy() -> UDPOptions {
            self
        }
        public func isEqual(to other: UDPOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    public struct UDPMetadata: PerProtocolMetadata {
        init() {}
        public func isEqual(to other: UDPMetadata, for: ProtocolCompareMode) -> Bool { true }
    }

    struct UDPInstance: ~Copyable, OneToOneDatagramProtocol {
        var upper = InboundDatagramLinkage()
        var lower = OutboundDatagramLinkage()

        var udpInstanceIndex: NetworkStateIndex? = nil

        private(set) var context: NetworkContext
        init(context: NetworkContext) { self.context = context }

        private(set) var reference: ProtocolInstanceReference = .init()

        var log = NetworkLoggerState()

        var eventManager = ProtocolEventManager()

        // Only called by newProtocolInstance()
        fileprivate static func registerNewUDP(
            on context: NetworkContext,
        ) -> ProtocolInstanceReference {
            let udp = UDPInstance(context: context)
            let registeredIndex = context.registerUDPInstance(udp)
            context.udpInstances[registeredIndex].udpInstanceIndex = registeredIndex
            context.udpInstances[registeredIndex].reference = ProtocolInstanceReference(
                udp: &context.udpInstances[registeredIndex]
            )
            return context.udpInstances[registeredIndex].reference
        }

        var passthroughEvents = true

        enum UDPStats {
            case inboundPackets
            case outboundPackets
            case headerDrops
            case badlength
            case badChecksum
            case softwareChecksumReceive
            case softwareChecksumSend
            case addNetControlProtocolBytesReceived
            case addNetControlProtocolBytesSent
            case clear
        }

        var ipv4Local: IPv4Address = IPv4Address.any
        var ipv4Remote: IPv4Address = IPv4Address.any
        var ipv6Local: IPv6Address = IPv6Address.any
        var ipv6Remote: IPv6Address = IPv6Address.any
        var localPort: UInt16 = 0
        var remotePort: UInt16 = 0

        var transmitByteCount: Int = 0
        var receiveByteCount: Int = 0

        var serviceClass = Parameters.ServiceClass.bestEffort
        var maximumDatagramSize: Int = 0
        var isIPv4: Bool {
            flags.contains(.isIPv4)
        }

        struct Flags: OptionSet {
            init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            var rawValue: UInt16
            static let isIPv4 = Flags(rawValue: 1 << 0)
            static let flowControlled = Flags(rawValue: 1 << 1)
            static let outputPending = Flags(rawValue: 1 << 2)
            static let partialChecksumOffload = Flags(rawValue: 1 << 3)
            static let noChecksum = Flags(rawValue: 1 << 4)
            static let noMetadata = Flags(rawValue: 1 << 5)
            static let ignoreInboundChecksum = Flags(rawValue: 1 << 6)
            static let upperTransportIsQUIC = Flags(rawValue: 1 << 7)
            static let fullChecksumOffload = Flags(rawValue: 1 << 8)
            static let reportedReceiveError = Flags(rawValue: 1 << 9)
            static let gotPathAttributes = Flags(rawValue: 1 << 10)
        }
        var flags: Flags = Flags()

        var gotPathAttributes: Bool {
            get { flags.contains(.gotPathAttributes) }
            set { if newValue { flags.insert(.gotPathAttributes) } else { flags.remove(.gotPathAttributes) } }
        }

        mutating func filloutPathAttributes(_ path: PathProperties) {
            self.gotPathAttributes = true
            self.serviceClass = path.effectiveServiceClass
            self.maximumDatagramSize = path.maximumPacketSize
            if self.maximumDatagramSize > UDPProtocol.headerLength {
                self.maximumDatagramSize -= UDPProtocol.headerLength
            }
            let udpChecksumOffload: UInt32 = path.hardwareChecksumFlags
            if isIPv4 && ((udpChecksumOffload & InterfaceChecksumFlags.udpIPv4.rawValue) != 0)
                || !isIPv4 && ((udpChecksumOffload & InterfaceChecksumFlags.udpIPv6.rawValue) != 0)
            {
                self.flags.insert(.fullChecksumOffload)
                self.flags.remove(.partialChecksumOffload)
            }
        }

        mutating func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            if let path {
                filloutPathAttributes(path)
            }

            guard let local, let remote,
                case .address(let localAddress) = local.type,
                case .address(let remoteAddress) = remote.type
            else {
                log.error("Invalid endpoints for UDP")
                throw NetworkError.posix(EINVAL)
            }

            if case let .v4(local, localPort) = localAddress.type,
                case let .v4(remote, remotePort) = remoteAddress.type
            {
                self.ipv4Local = local
                self.ipv4Remote = remote
                self.localPort = localPort
                self.remotePort = remotePort
                self.flags.insert(.isIPv4)
            } else if case let .v6(local, localPort) = localAddress.type,
                case let .v6(remote, remotePort) = remoteAddress.type
            {
                self.ipv6Local = local
                self.ipv6Remote = remote
                self.localPort = localPort
                self.remotePort = remotePort
            } else {
                log.error("Invalid addresses for UDP")
            }

            if let parameters, let udpOptions = udpOptions(from: parameters) {
                if udpOptions.noMetadata {
                    self.flags.insert(.noMetadata)
                }
                if udpOptions.preferNoChecksum {
                    self.flags.insert(.noChecksum)
                }
                if udpOptions.ignoreInboundChecksum {
                    self.flags.insert(.ignoreInboundChecksum)
                }
                if udpOptions.fullChecksumOffload {
                    self.flags.insert(.fullChecksumOffload)
                }
                #if !NETWORK_EMBEDDED
                if let transport = parameters.defaultStack.transport {
                    if transport.options == udpOptions, udpOptions.useQUICStats {
                        self.flags.insert(.upperTransportIsQUIC)
                    } else if let quicOptions = transport.options,
                        quicOptions.matches(identifier: QUICStreamProtocol.identifier)
                            || quicOptions.matches(identifier: QUICConnectionProtocol.identifier)
                    {
                        self.flags.insert(.upperTransportIsQUIC)
                    }
                }
                #endif
            }
        }

        static var ipProtocolNumber: Int {
            17  // IPPROTO_UDP
        }

        func pseudoHeaderChecksum(inboundChecksum: UInt16?, length: Int) -> UInt16 {
            let inbound = (inboundChecksum != nil)
            let existingChecksum: UInt16 = inboundChecksum ?? 0
            var checksumValue: UInt16 = 0
            if isIPv4 {
                checksumValue = Checksum.ipv4PseudoHeader(
                    source: inbound ? ipv4Remote : ipv4Local,
                    dest: inbound ? ipv4Local : ipv4Remote,
                    length: UInt32(length),
                    ipProtocolNumber: UInt32(UDPInstance.ipProtocolNumber),
                    existingChecksum: UInt32(existingChecksum)
                )
            } else {
                checksumValue = Checksum.ipv6PseudoHeader(
                    source: inbound ? ipv6Remote : ipv6Local,
                    dest: inbound ? ipv6Local : ipv6Remote,
                    length: UInt32(length),
                    ipProtocolNumber: UInt32(UDPInstance.ipProtocolNumber),
                    existingChecksum: UInt32(existingChecksum)
                )
            }
            return checksumValue
        }

        func validateChecksum(frame: borrowing Frame) -> Bool {
            let length = frame.unclaimedLength
            do {
                var checksum = try frame.ipChecksum(offset: 0, length: length)
                checksum = ~checksum

                checksum = pseudoHeaderChecksum(inboundChecksum: checksum, length: length)

                checksum = checksum ^ 0xffff

                guard checksum == 0 else {
                    log.error("Incorrect UDP checksum")
                    return false
                }

                return true
            } catch {
                log.error("Failed to calculate checksum: \(error)")
                return false
            }
        }

        mutating func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
            repeat {
                guard var frameArray = try invokeReceiveDatagrams(maximumDatagramCount: maximumDatagramCount),
                    frameArray.count > 0
                else {
                    return nil
                }

                var totalReceivedBytes: Int = 0
                frameArray.iterateMutableFrames { frame in
                    guard frame.isValid else {
                        log.info("UDP frame is no longer valid")
                        frame.finalize(success: false)
                        recordStatsEvent(stat: .clear)
                        return .removeFrameAndContinue
                    }

                    let frameLength = frame.unclaimedLength

                    recordStatsEvent(stat: .inboundPackets)
                    var length: UInt16 = 0
                    var checksum: UInt16 = 0
                    let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                        try read.uint16NetworkByteOrder(expect: remotePort)
                        try read.uint16NetworkByteOrder(expect: localPort)
                        try read.uint16NetworkByteOrder(&length)
                        try read.uint16(&checksum)
                    }

                    guard result.isValid else {
                        log.info("Failed to parse UDP header: \(result)")
                        recordStatsEvent(stat: .headerDrops)
                        // Keep processing other frames even if some are invalid.
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    guard length <= frameLength else {
                        log.error("Received length \(length) > \(frameLength)")
                        recordStatsEvent(stat: .badlength)
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    guard isIPv4 || checksum != 0 else {
                        log.error("Received an IPv6 packet with zero checksum")
                        recordStatsEvent(stat: .badChecksum)
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    if !self.flags.contains(.ignoreInboundChecksum) {
                        guard checksum == 0 || validateChecksum(frame: frame) else {
                            frame.finalize(success: false)
                            return .removeFrameAndContinue
                        }
                        recordStatsEvent(stat: .softwareChecksumReceive, value: frame.unclaimedLength)
                    }

                    #if !NETWORK_EMBEDDED
                    // Create protocol metadata
                    if self.flags.contains(.noMetadata) {
                        frame.setMetadata(metadata: nil, isInput: true, isComplete: true)
                    } else {
                        frame.setMetadata(
                            metadata: UDPProtocol.definition.protocolMetadata(),
                            isInput: true,
                            isComplete: true
                        )
                    }
                    #endif

                    _ = frame.claim(fromStart: UDPProtocol.headerLength)
                    if frameLength > length {
                        _ = frame.claim(fromStart: 0, fromEnd: frameLength - Int(length))
                    }

                    self.receiveByteCount += (frameLength - UDPProtocol.headerLength)
                    totalReceivedBytes += frameLength
                    return .continueIterating
                }

                recordStatsEvent(stat: .addNetControlProtocolBytesReceived, value: totalReceivedBytes)
                guard !frameArray.isEmpty else {
                    log.error("Dropped inbound packets, checking for more")
                    continue
                }
                return frameArray
            } while true
        }

        func incrementByUDPHeaderLength(_ value: Int) -> Int {
            if Int.max - value < UDPProtocol.headerLength {
                return Int.max
            }
            return value + UDPProtocol.headerLength
        }

        mutating func getDatagramsToSend(
            maximumDatagramCount: Int,
            minimumDatagramSize: Int
        ) throws(NetworkError) -> FrameArray? {
            if self.flags.contains(.flowControlled) {
                // Wait until UDP flow is allowed
                self.flags.insert(.outputPending)
                return nil
            }

            var outputFrames = try invokeGetDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: incrementByUDPHeaderLength(minimumDatagramSize)
            )
            outputFrames?.iterateMutableFrames { frame in
                _ = frame.claim(fromStart: UDPProtocol.headerLength)
                return true
            }

            return outputFrames
        }

        mutating func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
            datagrams.iterateMutableFrames { frame in
                recordStatsEvent(stat: .outboundPackets)
                guard frame.unclaim(fromStart: UDPProtocol.headerLength) else {
                    frame.finalize(success: false)
                    return .removeFrameAndContinue
                }

                let length = frame.unclaimedLength
                let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                    try write.uint16NetworkByteOrder(localPort)
                    try write.uint16NetworkByteOrder(remotePort)
                    try write.uint16NetworkByteOrder(UInt16(length))
                }

                guard result.isValid else {
                    log.error("UDP frame is no longer valid")
                    frame.finalize(success: false)
                    return .removeFrameAndContinue
                }

                if self.serviceClass != .bestEffort, frame.serviceClass != .bestEffort {
                    frame.serviceClass = self.serviceClass
                }

                if !isIPv4 || !self.flags.contains(.noChecksum) {
                    // Always insert pseudo header checksum
                    let checksumValue = pseudoHeaderChecksum(inboundChecksum: nil, length: length)

                    let checksumOffset = MemoryLayout<UInt16>.size * 3
                    let checksumValueWriteResult = Serializer.serialize(&frame, claim: false) {
                        write throws(SerializationError) in
                        try write.skip(checksumOffset)
                        try write.uint16(checksumValue)
                    }
                    if !checksumValueWriteResult.isValid {
                        log.error("Failed to serialize checksum value")
                        frame.finalize(success: false)
                        return .removeFrameAndContinue
                    }

                    if self.flags.contains(.fullChecksumOffload) {
                        let csumFlags: ChecksumFlags =
                            isIPv4
                            ? [.udpIPv4, .zeroInvert]
                            : [.udpIPv6, .zeroInvert]
                        frame.checksumOffloadFlags |= csumFlags.rawValue
                    }

                    if !self.flags.contains(.fullChecksumOffload) {
                        var checksumOffloadDisabled = !self.flags.contains(.partialChecksumOffload)
                        if !checksumOffloadDisabled {
                            let csumStart = UInt16(isIPv4 ? IPProtocol.ipv4HeaderLength : IPProtocol.ipv6HeaderLength)
                            let csumWrite = csumStart + UInt16(checksumOffset)
                            let csumFlags: ChecksumFlags = [.partial, .zeroInvert]
                            if !frame.setInternetChecksum(
                                flags: csumFlags,
                                startOffset: csumStart,
                                checksumOffset: csumWrite
                            ) {
                                checksumOffloadDisabled = true
                            }
                        }

                        if checksumOffloadDisabled {
                            do throws(ChecksumError) {
                                try frame.finalizeIPChecksum(checksumOffset: checksumOffset, zeroInvert: true)
                                recordStatsEvent(stat: .softwareChecksumSend, value: frame.unclaimedLength)
                            } catch {
                                log.error("Failed to finalize UDP checksum")
                                recordStatsEvent(stat: .clear)
                                frame.finalize(success: false)
                                return .removeFrameAndContinue
                            }
                        }
                    }
                }
                transmitByteCount += length - UDPProtocol.headerLength
                recordStatsEvent(stat: .addNetControlProtocolBytesSent, value: frame.unclaimedLength)

                return .continueIterating
            }

            return try invokeSendDatagrams(datagrams)
        }

        #if !NETWORK_EMBEDDED
        var metadata: AbstractProtocolMetadata? { nil }
        #endif

        func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot) {
            snapshot.receivedTransportByteCount = UInt64(receiveByteCount)
            snapshot.sentTransportByteCount = UInt64(transmitByteCount)
        }

        mutating func handleDisconnectedEvent(_ from: ProtocolInstanceReference, error: NetworkError?) {
            recordStatsEvent(stat: .clear)
        }

        mutating func recordStatsEvent(stat: UDPStats, value: Int? = nil) {}
    }

    public init() {}
    public func newPerProtocolOptions() -> UDPOptions? { UDPOptions() }
    public func newPerProtocolOptions(from existing: UDPOptions) -> UDPOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> UDPOptions? {
        UDPOptions(from: serializedBytes)
    }
    public func newPerProtocolMetadata() -> UDPMetadata? { UDPMetadata() }

    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        UDPInstance.registerNewUDP(on: context)
    }

    static public let identifier = ProtocolIdentifier(name: "udp", level: .transport, mapping: .oneToOne)

    #if !NETWORK_PRIVATE
    static let definition = ProtocolDefinition<UDPProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<UDPProtocol> { UDPProtocol.definition.protocolOptions() }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        UDPProtocol().newProtocolInstance(context: context)!
    }
}

@available(Network 0.1.0, *)
extension ProtocolOptions<UDPProtocol> {
    public var preferNoChecksum: Bool {
        get { perProtocolOptions!.contains(.preferNoChecksum) }
        set {
            if newValue {
                perProtocolOptions!.insert(.preferNoChecksum)
            } else {
                perProtocolOptions!.remove(.preferNoChecksum)
            }
        }
    }

    public var noMetadata: Bool {
        get { perProtocolOptions!.contains(.noMetadata) }
        set {
            if newValue {
                perProtocolOptions!.insert(.noMetadata)
            } else {
                perProtocolOptions!.remove(.noMetadata)
            }
        }
    }

    public var ignoreInboundChecksum: Bool {
        get { perProtocolOptions!.contains(.ignoreInboundChecksum) }
        set {
            if newValue {
                perProtocolOptions!.insert(.ignoreInboundChecksum)
            } else {
                perProtocolOptions!.remove(.ignoreInboundChecksum)
            }
        }
    }

    public var useQUICStats: Bool {
        get { perProtocolOptions!.contains(.useQUICStats) }
        set {
            if newValue {
                perProtocolOptions!.insert(.useQUICStats)
            } else {
                perProtocolOptions!.remove(.useQUICStats)
            }
        }
    }

    public var fullChecksumOffload: Bool {
        get { perProtocolOptions!.contains(.fullChecksumOffload) }
        set {
            if newValue {
                perProtocolOptions!.insert(.fullChecksumOffload)
            } else {
                perProtocolOptions!.remove(.fullChecksumOffload)
            }
        }
    }
}
