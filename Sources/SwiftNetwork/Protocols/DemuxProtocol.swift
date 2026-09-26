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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Synchronization)
internal import Synchronization
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum DemuxError: Error, CustomStringConvertible {
    case patternTooLong
    case invalidMask

    public var description: String {
        switch self {
        case .patternTooLong: return "Pattern Too Long"
        case .invalidMask: return "Invalid Mask"
        }
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct DemuxPattern: Sendable, Hashable {
    static let maxPatternLength = 30
    let patternRange: Range<Int>  // Range of bytes in frame that the pattern must match
    let pattern: [30 of UInt8]  // Content of the pattern
    let mask: [30 of UInt8]  // Mask for the pattern

    public static func == (lhs: borrowing DemuxPattern, rhs: borrowing DemuxPattern) -> Bool {
        guard lhs.patternRange == rhs.patternRange else { return false }
        for i in 0..<maxPatternLength {
            guard lhs.pattern[i] == rhs.pattern[i],
                lhs.mask[i] == rhs.mask[i]
            else {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for i in 0..<pattern.count {
            hasher.combine(pattern[i])
        }
    }

    var isEmpty: Bool {
        patternRange.isEmpty
    }

    init(_ pattern: RawSpan, at offset: Int, mask: RawSpan? = nil) throws(DemuxError) {
        let patternLength = pattern.byteCount
        guard patternLength <= Self.maxPatternLength else { throw .patternTooLong }

        self.patternRange = offset..<offset + patternLength
        var tempPattern = [30 of UInt8](repeating: 0)
        var tempMask = [30 of UInt8](repeating: 0xff)

        if let mask {
            guard mask.byteCount == patternLength else { throw .invalidMask }
            for i in 0..<patternLength {
                tempPattern[i] = pattern[i]
                tempMask[i] = mask[i]
            }
        } else {
            for i in 0..<patternLength {
                tempPattern[i] = pattern[i]
            }
        }
        self.pattern = tempPattern
        self.mask = tempMask
    }

    func matchesFrame(_ frame: borrowing Frame) -> Bool {
        guard !patternRange.isEmpty else { return false }
        guard let bytes = frame.bytes else { return false }
        guard bytes.byteCount >= patternRange.upperBound else { return false }
        let startOffset = patternRange.lowerBound
        let patternLength = patternRange.count
        for byteIndex in 0..<patternLength {
            if bytes[startOffset + byteIndex] & self.mask[byteIndex] != self.pattern[byteIndex] & self.mask[byteIndex] {
                // Mismatch in some byte
                return false
            }
        }
        return true
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct DemuxProtocol: NetworkProtocol {
    public typealias Options = DemuxOptions
    public typealias Metadata = DemuxMetadata

    public struct DemuxOptions: PerProtocolOptions {
        var demuxPatterns = Deque<DemuxPattern>()

        init() {}

        init?(from serializedBytes: [UInt8]) {
            // Ignore content
        }

        public func serialize() -> [UInt8]? {
            var hasPatterns = false
            for demuxPattern in demuxPatterns {
                if !demuxPattern.isEmpty {
                    hasPatterns = true
                    break
                }
            }
            return Serializer.serialize { write in
                write.uint8(hasPatterns ? 1 : 0)
            }
        }
        public var serializeInParameters: Bool {
            true
        }
        public func deepCopy() -> DemuxOptions {
            self
        }
        public func isEqual(to other: DemuxOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }

        public mutating func addPattern(_ pattern: RawSpan, at offset: Int, mask: RawSpan? = nil) throws(DemuxError) {
            demuxPatterns.append(try DemuxPattern(pattern, at: offset, mask: mask))
        }
    }

    // TODO: Add a way to dynamically add patterns to an existing upper protocol
    public struct DemuxMetadata: PerProtocolMetadata {
        var isStatic: Bool = false

        init() {}
        public func isEqual(to other: DemuxMetadata, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    public final class DemuxInstance: OutboundDatagramHandler, InboundDatagramHandler, LoggableProtocol {
        public typealias UpperProtocol = BaseInboundDatagramLinkage
        public typealias LowerProtocol = BaseOutboundDatagramLinkage

        var defaultUpper = UpperProtocol()
        var defaultInboundFrames = FrameArray()

        struct DemuxEntry: ~Copyable {
            var upper: UpperProtocol
            var inboundFrames = FrameArray()
            var demuxPatterns = Deque<DemuxPattern>()
        }
        var demuxEntries = NetworkUniqueArray<DemuxEntry>()

        var lower = LowerProtocol()

        public private(set) var context: NetworkContext
        init(context: NetworkContext) {
            self.context = context
            self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
        }
        public var identifier: InstanceIdentifier
        public var log = NetworkLoggerState()
        public var eventManager = ProtocolEventManager()

        internal func validate(
            upper upperProtocol: InstanceIdentifier,
            _ label: String
        ) throws(ProtocolInstanceError) {
            #if DEBUG
            if upperProtocol == defaultUpper.identifier { return }
            for i in 0..<demuxEntries.count {
                if demuxEntries[i].upper.identifier == upperProtocol { return }
            }
            if !defaultUpper.isDetached || !demuxEntries.isEmpty {
                Logger.proto.fault("Received \'\(label)\' from incorrect upper protocol")
            }
            throw ProtocolInstanceError.invalidUpperProtocol

            #endif
        }

        internal func validate(
            lower lowerProtocol: InstanceIdentifier,
            _ label: String
        ) throws(ProtocolInstanceError) {
            #if DEBUG
            guard !lowerProtocol.isNone else {
                Logger.proto.fault("Received \'\(label)\' from incorrect lower protocol")
                throw ProtocolInstanceError.invalidLowerProtocol
            }
            #endif
        }

        public func attachUpperProtocol(
            _ upperProtocol: UpperProtocol,
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            if defaultUpper.isDetached {
                // Set up default
                defaultUpper = upperProtocol
                #if !NETWORK_EMBEDDED
                if let parameters {
                    if let options = parameters.protocolOptions(for: self.identifier) {
                        self.log.logPrefix = options.logIDString ?? ""
                    }
                }
                #endif
            } else if defaultUpper != upperProtocol {
                #if !NETWORK_EMBEDDED
                if let parameters {
                    if let demuxOptions: ProtocolOptions<DemuxProtocol> = parameters.protocolOptions(
                        for: self.identifier
                    ) {
                        demuxEntries.append(
                            DemuxEntry(
                                upper: upperProtocol,
                                demuxPatterns: demuxOptions.perProtocolOptions!.demuxPatterns
                            )
                        )
                    }
                }
                #endif
            }
        }

        /// Whether every upper protocol has detached, so the instance's storage can be released.
        ///
        /// A demux instance is shared by its default upper and one upper per pattern set, each of
        /// which detaches separately, so storage may only be released once the last one has gone.
        public var isFullyDetached: Bool {
            defaultUpper.isDetached && demuxEntries.isEmpty
        }

        public func attachLowerProtocol(
            _ lowerProtocol: LowerProtocol,
        ) throws(NetworkError) -> LowerProtocol.PairedUpperLinkage? {
            guard lower.isDetached else {
                throw NetworkError.posix(EALREADY)
            }
            lower = lowerProtocol
            return nil
        }

        func addInboundDatagram(_ datagram: consuming Frame) -> Int? {
            for entryIndex in 0..<demuxEntries.count {
                for patternIndex in 0..<demuxEntries[entryIndex].demuxPatterns.count {
                    if demuxEntries[entryIndex].demuxPatterns[patternIndex].matchesFrame(datagram) {
                        // Found a match!
                        demuxEntries[entryIndex].inboundFrames.add(frame: datagram)
                        return entryIndex
                    }
                }
            }

            // Add to default
            defaultInboundFrames.add(frame: datagram)
            return nil
        }

        func serviceInboundFrames(
            maximumDatagramCount: Int,
            requestingIndex: inout Int?,
            for instance: InstanceIdentifier
        ) -> FrameArray? {
            if instance == defaultUpper.identifier {
                // Look for pending frames for default
                if !defaultInboundFrames.isEmpty {
                    return defaultInboundFrames.drainArray(maximumFrameCount: maximumDatagramCount)
                }
            } else {
                for i in 0..<demuxEntries.count {
                    if demuxEntries[i].upper.identifier == instance {
                        if !demuxEntries[i].inboundFrames.isEmpty {
                            return demuxEntries[i].inboundFrames.drainArray(maximumFrameCount: maximumDatagramCount)
                        }
                        requestingIndex = i
                        break
                    }
                }
            }
            return nil
        }

        public func receiveDatagrams(
            maximumDatagramCount: Int,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
            var requestingIndex: Int? = nil

            let returnArray = serviceInboundFrames(
                maximumDatagramCount: maximumDatagramCount,
                requestingIndex: &requestingIndex,
                for: instance
            )
            if let returnArray {
                return returnArray
            }

            guard !demuxEntries.isEmpty else {
                // No patterns, just go direct
                return try lower.invokeReceiveDatagrams(
                    maximumDatagramCount: maximumDatagramCount,
                    for: self.identifier,
                    in: &eventContext
                )
            }

            // Read datagrams out and categorize them based on patterns
            let inboundDatagrams = try lower.invokeReceiveDatagrams(
                maximumDatagramCount: maximumDatagramCount,
                for: self.identifier,
                in: &eventContext
            )
            guard var inboundDatagrams, !inboundDatagrams.isEmpty else {
                return nil
            }

            var signalInboundDataAvailableToPatterns = false
            var signalInboundDataAvailableToDefault = false

            while let datagram = inboundDatagrams.popFirst() {
                let matchingIndex = self.addInboundDatagram(datagram)
                if matchingIndex != requestingIndex {
                    if matchingIndex != nil {
                        signalInboundDataAvailableToPatterns = true
                    } else {
                        signalInboundDataAvailableToDefault = true
                    }
                }
            }

            if signalInboundDataAvailableToPatterns {
                for i in 0..<demuxEntries.count {
                    if !demuxEntries[i].inboundFrames.isEmpty {
                        demuxEntries[i].upper.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
                    }
                }
            }

            if signalInboundDataAvailableToDefault {
                defaultUpper.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
            }

            // Return frames for the requesting index
            return serviceInboundFrames(
                maximumDatagramCount: maximumDatagramCount,
                requestingIndex: &requestingIndex,
                for: instance
            )
        }

        public func getDatagramsToSend(
            maximumDatagramCount: Int,
            minimumDatagramSize: Int,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
            return try lower.invokeGetDatagramsToSend(
                maximumDatagramCount: maximumDatagramCount,
                minimumDatagramSize: minimumDatagramSize,
                for: self.identifier,
                in: &eventContext
            )
        }

        public func sendDatagrams(
            _ datagrams: consuming FrameArray,
            from instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            do { try validate(upper: instance, #function) } catch {
                datagrams.finalizeAllFramesAsFailed()
                throw NetworkError.posix(EINVAL)
            }
            try lower.invokeSendDatagrams(datagrams, from: self.identifier, in: &eventContext)
        }

        public func detach(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            do { try validate(upper: instance, #function) } catch { throw NetworkError.posix(EINVAL) }
            if instance == defaultUpper.identifier {
                defaultUpper = .init()
                defaultInboundFrames.finalizeAllFramesAsFailed()
            } else {
                for i in 0..<demuxEntries.count {
                    if demuxEntries[i].upper.identifier == instance {
                        demuxEntries[i].upper = .init()
                        demuxEntries[i].inboundFrames.finalizeAllFramesAsFailed()
                        demuxEntries.remove(at: i)
                        break
                    }
                }
            }

            // The remaining uppers still share this instance's lower protocol, so only detach it
            // once every upper has gone.
            guard isFullyDetached else { return }

            // Ensure any frames that may still be sitting in the default queue are finalized
            defaultInboundFrames.finalizeAllFramesAsFailed()

            try lower.invokeDetach(for: self.identifier, in: &eventContext)
            lower = .init()
        }

        public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
            do { try validate(upper: instance, #function) } catch { return }
            if instance == defaultUpper.identifier {

                if lower.protocolIsConnected(in: &eventContext) {
                    if canCallConnect(requested: true, in: &eventContext) {
                        defaultUpper.deliverConnectedEvent(from: self.identifier, in: &eventContext)
                    }
                } else {
                    connectRequested(in: &eventContext)
                    lower.invokeConnect(for: self.identifier, in: &eventContext)
                }
            } else {
                // Just reply connected to the non-default cases
                for i in 0..<demuxEntries.count {
                    if demuxEntries[i].upper.identifier == instance {
                        demuxEntries[i].upper.deliverConnectedEvent(from: self.identifier, in: &eventContext)
                        break
                    }
                }
            }
        }

        public func disconnect(
            error: NetworkError?,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            do { try validate(upper: instance, #function) } catch { return }

            if instance == defaultUpper.identifier {
                if canCallDisconnect(in: &eventContext) {
                    lower.invokeDisconnect(error: error, for: self.identifier, in: &eventContext)
                }
            } else {
                // Just reply disconnected to the non-default cases
                for i in 0..<demuxEntries.count {
                    if demuxEntries[i].upper.identifier == instance {
                        demuxEntries[i].upper.deliverDisconnectedEvent(
                            error: error,
                            from: self.identifier,
                            in: &eventContext
                        )
                        break
                    }
                }
            }
        }

        public func handleApplicationEvent(
            event: ApplicationEvent,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            // Don't validate upper, can pass through
            lower.invokeApplicationEvent(event: event, for: instance, in: &eventContext)
        }

        public func getMetadata<P>(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) -> ProtocolMetadata<P>? where P: NetworkProtocol {
            do { try validate(upper: instance, #function) } catch { return nil }
            return lower.invokeGetMetadata(for: self.identifier, in: &eventContext)
        }

        public func getMetrics(
            requestedNetworkMetric: RequestedNetworkMetrics,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) -> NetworkMetrics? {
            lower.invokeGetMetrics(
                requestedNetworkMetric: requestedNetworkMetric,
                for: self.identifier,
                in: &eventContext
            )
        }

        // Events from lower

        public func handleConnectedEvent(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            do { try validate(lower: instance, #function) } catch { return }
            if canCallConnect(requested: false, in: &eventContext) {
                defaultUpper.deliverConnectedEvent(from: self.identifier, in: &eventContext)
            }
        }

        public func handleDisconnectedEvent(
            error: NetworkError?,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            do { try validate(lower: instance, #function) } catch { return }
            for i in 0..<demuxEntries.count {
                demuxEntries[i].upper.deliverDisconnectedEvent(error: error, from: self.identifier, in: &eventContext)
            }

            // Pass through disconnected up to the default protocol
            defaultUpper.deliverDisconnectedEvent(error: error, from: self.identifier, in: &eventContext)
        }

        public func handleInboundDataAvailableEvent(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            do { try validate(lower: instance, #function) } catch { return }

            defaultUpper.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
            for i in 0..<demuxEntries.count {
                demuxEntries[i].upper.deliverInboundDataAvailableEvent(from: self.identifier, in: &eventContext)
            }
        }

        public func handleOutboundRoomAvailableEvent(
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            do { try validate(lower: instance, #function) } catch { return }
            defaultUpper.deliverOutboundRoomAvailableEvent(from: self.identifier, in: &eventContext)
            for i in 0..<demuxEntries.count {
                demuxEntries[i].upper.deliverOutboundRoomAvailableEvent(from: self.identifier, in: &eventContext)
            }
        }

        public func handleNetworkProtocolEvent(
            event: NetworkProtocolEvent,
            for instance: InstanceIdentifier,
            in eventContext: inout NetworkContext.EventContext
        ) {
            // Don't validate lower, can pass through
            defaultUpper.deliverNetworkProtocolEvent(
                originalInstance: instance,
                selfInstance: self.identifier,
                event: event,
                in: &eventContext
            )
            for i in 0..<demuxEntries.count {
                demuxEntries[i].upper.deliverNetworkProtocolEvent(
                    originalInstance: instance,
                    selfInstance: self.identifier,
                    event: event,
                    in: &eventContext
                )
            }
        }
    }

    public init() {}
    public func newPerProtocolOptions() -> DemuxOptions? { DemuxOptions() }
    public func newPerProtocolOptions(from existing: DemuxOptions) -> DemuxOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> DemuxOptions? {
        DemuxOptions(from: serializedBytes)
    }
    public func newPerProtocolMetadata() -> DemuxMetadata? { DemuxMetadata() }

    static let identifier = ProtocolIdentifier(name: "demux", level: .link, mapping: .oneToOne)
    static let definition = ProtocolDefinition<DemuxProtocol>(identifier: identifier)

    static public func options() -> ProtocolOptions<DemuxProtocol> {
        DemuxProtocol.definition.protocolOptions()
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension ProtocolOptions<DemuxProtocol> {
    public func addPattern(_ pattern: RawSpan, at offset: Int, mask: RawSpan? = nil) throws(DemuxError) {
        try perProtocolOptions!.addPattern(pattern, at: offset, mask: mask)
    }
}
