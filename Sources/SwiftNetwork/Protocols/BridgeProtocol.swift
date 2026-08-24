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
public struct DatagramDrops: Equatable {
    private var dropRanges: [ClosedRange<Int>]
    private var datagramCount = 0
    public var blockPacketGeneration = false

    public init(_ ranges: [ClosedRange<Int>]) {
        dropRanges = ranges
    }

    public init(_ range: ClosedRange<Int>) {
        dropRanges = [range]
    }

    public init(_ index: Int) {
        dropRanges = [index...index]
    }

    mutating func shouldDropPacket() -> Bool {
        guard !dropRanges.isEmpty else {
            return false
        }

        defer {
            datagramCount += 1
        }
        if datagramCount > dropRanges[0].upperBound {
            dropRanges.removeFirst()
        }

        guard !dropRanges.isEmpty else {
            return false
        }

        // Drop if contained in range
        return dropRanges[0].contains(datagramCount)
    }
}

public typealias BridgeObserveFirstByteHandler = ((UInt8) -> Void)?

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct BridgeDatagramProtocol: NetworkProtocol {
    public typealias Options = BridgeOptions
    public typealias Metadata = BridgeMetadata
    public typealias Instance = BridgeInstance

    public struct BridgeOptions: PerProtocolOptions {
        public var linkDelay: NetworkDuration = .zero
        public var observeFirstByteHandler: BridgeObserveFirstByteHandler = nil
        var datagramDrops: DatagramDrops?

        init() {}

        init?(from serializedBytes: [UInt8]) {
        }

        public func serialize() -> [UInt8]? {
            Serializer.serialize { write in
            }
        }
        public var serializeInParameters: Bool {
            false
        }
        public func deepCopy() -> BridgeOptions {
            self
        }
        public func isEqual(to other: BridgeOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }

        static public func == (lhs: BridgeOptions, rhs: BridgeOptions) -> Bool {
            lhs.linkDelay == rhs.linkDelay && lhs.datagramDrops == rhs.datagramDrops
        }

        var isDefault: Bool {
            self == BridgeOptions()
        }
    }

    public struct BridgeMetadata: PerProtocolMetadata {
        var isStatic: Bool = false

        init() {}
        public func isEqual(to other: BridgeMetadata, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    public final class BridgeInstance: BottomDatagramProtocol, ProtocolInstanceContainer, TimerSchedulable {

        var maximumOutputSize = 1500
        public var upper = InboundDatagramLinkage()
        var lower = OutboundDatagramLinkage()

        public private(set) var context: NetworkContext
        init(context: NetworkContext) { self.context = context }
        public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
        var log = NetworkLoggerState()
        public var eventManager = ProtocolEventManager()
        public let timerReference = TimerReference()

        var localEndpoint: Endpoint?
        var remoteEndpoint: Endpoint?
        private var incomingFrames = FrameArray()
        static nonisolated(unsafe) private var instances = [UInt16: BridgeInstance]()

        static private let generatedPort = NetworkMutex<UInt16>(1024)  // Run 1024 through UInt16.max
        public static var nextGeneratedPort: UInt16 {
            var port: UInt16 = 0
            generatedPort.withLock {
                port = $0
                if $0 == UInt16.max {
                    $0 = 1024
                } else {
                    $0 += 1
                }
            }
            return port
        }

        var linkDelay: NetworkDuration = .zero
        var datagramDrops: DatagramDrops? = nil
        var observeFirstByteHandler: BridgeObserveFirstByteHandler = nil

        private var timerSet = false
        func deliverInboundDataAvailableEvent() {
            if linkDelay == .zero {
                self.async {
                    self.upper.deliverInboundDataAvailableEvent(self.reference)
                }
            } else {
                guard !timerSet else { return }
                timerSet = true
                self.scheduleWakeup(after: linkDelay)
            }
        }

        public func wakeup() {
            timerSet = false
            self.upper.deliverInboundDataAvailableEvent(self.reference)
        }

        public func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            guard let local else {
                fatalError("Must use well defined local address with bridge protocol")
            }

            guard let remote else {
                fatalError("Must use well defined local address with bridge protocol")
            }

            self.localEndpoint = local
            self.remoteEndpoint = remote

            #if !NETWORK_EMBEDDED
            if let parameters, let bridgeOptions: ProtocolOptions<BridgeDatagramProtocol> = getOptions(from: parameters)
            {
                self.linkDelay = bridgeOptions.linkDelay
                self.datagramDrops = bridgeOptions.datagramDrops
                self.observeFirstByteHandler = bridgeOptions.observeFirstByteHandler
            }
            #endif

            BridgeInstance.instances[local.port] = self
        }

        public func teardown() {
            if let localPort = localEndpoint?.port {
                BridgeInstance.instances[localPort] = nil
            }
            incomingFrames.finalizeAllFramesAsFailed()
        }

        deinit {
            incomingFrames.finalizeAllFramesAsFailed()
        }

        public var connectionIsIdle = false
        public func handleApplicationEvent(_ event: ApplicationEvent) {
            if event == .connectionIdle {
                if !connectionIsIdle {
                    log.debug(
                        "Bridge protocol is idle for ports \(localEndpoint?.port ?? 0) - \(remoteEndpoint?.port ?? 0)"
                    )
                    connectionIsIdle = true
                }
            } else if event == .connectionReused {
                if connectionIsIdle {
                    log.debug(
                        "Bridge protocol is reused for ports \(localEndpoint?.port ?? 0) - \(remoteEndpoint?.port ?? 0)"
                    )
                    connectionIsIdle = false
                }
            }
        }

        public func connect(_ from: ProtocolInstanceReference) {
            fromExternal {
                upper.deliverConnectedEvent(reference)
            }
        }

        public func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
            incomingFrames.drainArray(maximumFrameCount: maximumDatagramCount)
        }

        public func getDatagramsToSend(
            maximumDatagramCount: Int,
            minimumDatagramSize: Int
        ) throws(NetworkError) -> FrameArray? {
            if datagramDrops?.blockPacketGeneration ?? false {
                if datagramDrops?.shouldDropPacket() ?? false {
                    log.datapath("blocking \(maximumDatagramCount) datagrams to port: \(self.remoteEndpoint!.port)")
                    self.async {
                        self.log.datapath("unblocking outbound data")
                        self.upper.deliverOutboundRoomAvailableEvent(self.reference)
                    }
                    return nil
                }
            }

            let frameSize = min(minimumDatagramSize, self.maximumOutputSize)
            var frameArray = FrameArray(capacity: maximumDatagramCount)
            for _ in 0..<maximumDatagramCount {
                let frame = Frame(count: frameSize)
                frameArray.add(frame: frame)
            }
            return frameArray
        }

        public func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
            let remotePort = remoteEndpoint!.port
            guard let remoteInstance = BridgeInstance.instances[remotePort] else {
                log.error("Unable to find instance for port: \(remotePort)")
                datagrams.finalizeAllFramesAsFailed()
                return
            }
            if datagramDrops != nil, !(datagramDrops?.blockPacketGeneration ?? false) {
                var remainingDatagrams = FrameArray()
                let datagramCount = datagrams.count
                for _ in 0..<datagramCount {
                    if datagramDrops?.shouldDropPacket() ?? false {
                        log.datapath("dropping 1 datagram to port: \(remotePort)")
                        var dropped = datagrams.popFirst()
                        dropped?.finalize(success: false)
                    } else if let datagram = datagrams.popFirst() {
                        remainingDatagrams.add(frame: datagram)
                    }
                }
                datagrams = remainingDatagrams
            }
            log.datapath("forwarding \(datagrams.count) datagrams to port: \(remotePort)")
            if let observeFirstByteHandler {
                datagrams.iterateMutableFrames { frame in
                    if let bytes = frame.bytes, bytes.byteCount > 0 {
                        observeFirstByteHandler(bytes[0])
                    }
                    return true
                }
            }
            remoteInstance.incomingFrames.add(frames: datagrams)
            remoteInstance.deliverInboundDataAvailableEvent()
        }

        public static func injectDatagram(_ datagram: consuming Frame, to remotePort: UInt16) {
            guard let remoteInstance = BridgeInstance.instances[remotePort] else {
                return
            }
            remoteInstance.incomingFrames.add(frames: .init(frame: datagram))
            remoteInstance.deliverInboundDataAvailableEvent()
        }

        #if !NETWORK_EMBEDDED
        public var metadata: AbstractProtocolMetadata? { nil }
        #endif
    }

    public init() {}
    public func newPerProtocolOptions() -> BridgeOptions? { BridgeOptions() }
    public func newPerProtocolOptions(from existing: BridgeOptions) -> BridgeOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> BridgeOptions? {
        BridgeOptions(from: serializedBytes)
    }
    public func newPerProtocolMetadata() -> BridgeMetadata? { BridgeMetadata() }
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        BridgeInstance(context: context).reference
    }

    static let identifier = ProtocolIdentifier(name: "bridge-datagram", level: .link, mapping: .oneToOne)
    static let definition = ProtocolDefinition<BridgeDatagramProtocol>(identifier: identifier)

    static public func options() -> ProtocolOptions<BridgeDatagramProtocol> {
        BridgeDatagramProtocol.definition.protocolOptions()
    }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        BridgeDatagramProtocol().newProtocolInstance(context: context)!
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension ProtocolOptions<BridgeDatagramProtocol> {
    public var linkDelay: NetworkDuration {
        get { perProtocolOptions!.linkDelay }
        set { perProtocolOptions!.linkDelay = newValue }
    }

    public var observeFirstByteHandler: BridgeObserveFirstByteHandler {
        get { perProtocolOptions!.observeFirstByteHandler }
        set { perProtocolOptions!.observeFirstByteHandler = newValue }
    }

    public var datagramDrops: DatagramDrops? {
        get { perProtocolOptions!.datagramDrops }
        set { perProtocolOptions!.datagramDrops = newValue }
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct BridgeStreamProtocol: NetworkProtocol {
    public typealias Options = BridgeOptions
    public typealias Metadata = BridgeMetadata
    public typealias Instance = BridgeInstance

    public struct BridgeOptions: PerProtocolOptions {
        init() {}

        init?(from serializedBytes: [UInt8]) {
        }

        public func serialize() -> [UInt8]? {
            Serializer.serialize { write in
            }
        }
        public var serializeInParameters: Bool {
            false
        }
        public func deepCopy() -> BridgeOptions {
            self
        }
        public func isEqual(to other: BridgeOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }

        var isDefault: Bool {
            self == BridgeOptions()
        }
    }

    public struct BridgeMetadata: PerProtocolMetadata {
        var isStatic: Bool = false

        init() {}
        public func isEqual(to other: BridgeMetadata, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    public final class BridgeInstance: BottomStreamProtocol, ProtocolInstanceContainer {
        var maximumOutputSize = 1500
        public var upper = InboundStreamLinkage()
        var lower = OutboundStreamLinkage()

        public private(set) var context: NetworkContext
        init(context: NetworkContext) { self.context = context }
        public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
        var log = NetworkLoggerState()
        public var eventManager = ProtocolEventManager()
        var localEndpoint: Endpoint?
        var remoteEndpoint: Endpoint?
        private var incomingFrames = FrameArray()
        static nonisolated(unsafe) private var instances: [UInt16: BridgeInstance] = [:]

        public func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            guard let local else {
                fatalError("Must use well defined local address with bridge protocol")
            }

            guard let remote else {
                fatalError("Must use well defined local address with bridge protocol")
            }

            self.localEndpoint = local
            self.remoteEndpoint = remote

            BridgeInstance.instances[local.port] = self
        }

        public func teardown() {
            if let localPort = localEndpoint?.port {
                BridgeInstance.instances[localPort] = nil
            }
            incomingFrames.finalizeAllFramesAsFailed()
        }

        deinit {
            incomingFrames.finalizeAllFramesAsFailed()
        }

        public func connect(_ from: ProtocolInstanceReference) {
            fromExternal {
                upper.deliverConnectedEvent(reference)
            }
        }

        public func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
            incomingFrames.drainArray(maximumByteCount: maximumBytes)
        }

        public func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
            Int.max
        }

        public func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
            let remotePort = remoteEndpoint!.port
            guard let remoteInstance = BridgeInstance.instances[remotePort] else {
                log.error("Unable to find instance for port: \(remotePort)")
                streamData.finalizeAllFramesAsFailed()
                return
            }
            remoteInstance.incomingFrames.add(frames: streamData)
            remoteInstance.async {
                remoteInstance.upper.deliverInboundDataAvailableEvent(remoteInstance.reference)
            }
        }

        #if !NETWORK_EMBEDDED
        public var metadata: AbstractProtocolMetadata? { nil }
        #endif
    }

    public init() {}
    public func newPerProtocolOptions() -> BridgeOptions? { BridgeOptions() }
    public func newPerProtocolOptions(from existing: BridgeOptions) -> BridgeOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> BridgeOptions? {
        BridgeOptions(from: serializedBytes)
    }
    public func newPerProtocolMetadata() -> BridgeMetadata? { BridgeMetadata() }
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        BridgeInstance(context: context).reference
    }

    static let identifier = ProtocolIdentifier(name: "bridge-stream", level: .link, mapping: .oneToOne)
    static let definition = ProtocolDefinition<BridgeStreamProtocol>(identifier: identifier)

    static public func options() -> ProtocolOptions<BridgeStreamProtocol> {
        BridgeStreamProtocol.definition.protocolOptions()
    }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        BridgeStreamProtocol().newProtocolInstance(context: context)!
    }
}
