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

enum MultipathVersion: UInt8 {
    case version_0 = 0
    case version_1 = 1
}

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct TCPProtocol: NetworkProtocol {
    public typealias Options = TCPOptions
    public typealias Metadata = TCPMetadata
    typealias Instance = TCPInstance

    static public var headerLength: Int {
        MemoryLayout<UInt8>.size * 20
        // TCP Header
        // Source Port: UInt16
        // Destination Port: UInt16
        // Sequence Number: UInt32
        // ACK Number: UInt32
        // Offset and Flags: UInt15
        // Window: UInt16
        // Checksum: UInt16
        // Urgent Pointer: UInt16
    }

    public struct TCPOptions: PerProtocolOptions {

        internal var _maximumSegmentSize: UInt32 = 0
        public var maximumSegmentSize: UInt32 {
            get { self._maximumSegmentSize }
            set { self._maximumSegmentSize = newValue }
        }

        internal var _connectionTimeout: UInt32 = 0
        public var connectionTimeout: UInt32 {
            get { self._connectionTimeout }
            set { self._connectionTimeout = newValue }
        }

        internal var _persistTimeout: UInt32 = 0
        public var persistTimeout: UInt32 {
            get { self._persistTimeout }
            set { self._persistTimeout = newValue }
        }

        internal var _retransmitConnectionDropTime: UInt32 = 0
        public var retransmitConnectionDropTime: UInt32 {
            get { self._retransmitConnectionDropTime }
            set { self._retransmitConnectionDropTime = newValue }
        }

        internal var _keepaliveIdleTime: UInt32 = 0
        public var keepaliveIdleTime: UInt32 {
            get { self._keepaliveIdleTime }
            set { self._keepaliveIdleTime = newValue }
        }

        internal var _keepaliveInterval: UInt32 = 0
        public var keepaliveInterval: UInt32 {
            get { self._keepaliveInterval }
            set { self._keepaliveInterval = newValue }
        }

        internal var _keepaliveCount: UInt32 = 0
        public var keepaliveCount: UInt32 {
            get { self._keepaliveCount }
            set { self._keepaliveCount = newValue }
        }

        internal var _maxPacingRate: UInt64 = 0
        public var maxPacingRate: UInt64 {
            get { self._maxPacingRate }
            set { self._maxPacingRate = newValue }
        }

        internal var multipathVersion: MultipathVersion = .version_1
        // nil = default
        // true = enabled
        // false = disabled
        public var enableL4S: Bool?

        // Flag setters / getters

        public var reduceBuffering: Bool {
            get { flags.contains(.reduceBuffering) }
            set { if newValue { flags.insert(.reduceBuffering) } else { flags.remove(.reduceBuffering) } }
        }
        public var noDelay: Bool {
            get { flags.contains(.noDelay) }
            set { if newValue { flags.insert(.noDelay) } else { flags.remove(.noDelay) } }
        }
        public var noTimewait: Bool {
            get { flags.contains(.noTimewait) }
            set { if newValue { flags.insert(.noTimewait) } else { flags.remove(.noTimewait) } }
        }
        public var noPush: Bool {
            get { flags.contains(.noPush) }
            set { if newValue { flags.insert(.noPush) } else { flags.remove(.noPush) } }
        }
        public var noOptions: Bool {
            get { flags.contains(.noOptions) }
            set { if newValue { flags.insert(.noOptions) } else { flags.remove(.noOptions) } }
        }
        public var enableKeepalive: Bool {
            get { flags.contains(.enableKeepalive) }
            set { if newValue { flags.insert(.enableKeepalive) } else { flags.remove(.enableKeepalive) } }
        }
        public var enableKeepaliveOffload: Bool {
            get { flags.contains(.enableKeepaliveOffload) }
            set { if newValue { flags.insert(.enableKeepaliveOffload) } else { flags.remove(.enableKeepaliveOffload) } }
        }
        public var disableAckStretching: Bool {
            get { flags.contains(.disableAckStretching) }
            set { if newValue { flags.insert(.disableAckStretching) } else { flags.remove(.disableAckStretching) } }
        }
        public var disableBlackholeDetection: Bool {
            get { flags.contains(.noOptions) }
            set {
                if newValue {
                    flags.insert(.disableBlackholeDetection)
                } else {
                    flags.remove(.disableBlackholeDetection)
                }
            }
        }
        public var enableBackgroundTrafficManagement: Bool {
            get { flags.contains(.enableBackgroundTrafficManagement) }
            set {
                if newValue {
                    flags.insert(.enableBackgroundTrafficManagement)
                } else {
                    flags.remove(.enableBackgroundTrafficManagement)
                }
            }
        }
        public var retransmitFinDrop: Bool {
            get { flags.contains(.retransmitFinDrop) }
            set { if newValue { flags.insert(.retransmitFinDrop) } else { flags.remove(.retransmitFinDrop) } }
        }
        public var enableFastOpen: Bool {
            get { flags.contains(.enableFastOpen) }
            set { if newValue { flags.insert(.enableFastOpen) } else { flags.remove(.enableFastOpen) } }
        }
        public var noFastOpenCookie: Bool {
            get { flags.contains(.noFastOpenCookie) }
            set { if newValue { flags.insert(.noFastOpenCookie) } else { flags.remove(.noFastOpenCookie) } }
        }
        public var fastOpenForceEnable: Bool {
            get { flags.contains(.fastOpenForceEnable) }
            set { if newValue { flags.insert(.fastOpenForceEnable) } else { flags.remove(.fastOpenForceEnable) } }
        }
        public var disableECN: Bool {
            get { flags.contains(.disableECN) }
            set { if newValue { flags.insert(.disableECN) } else { flags.remove(.disableECN) } }
        }
        public var resetLocalPort: Bool {
            get { flags.contains(.resetLocalPort) }
            set { if newValue { flags.insert(.resetLocalPort) } else { flags.remove(.resetLocalPort) } }
        }

        struct Flags: OptionSet {
            public init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            public var rawValue: UInt32
            static public let reduceBuffering = TCPOptions.Flags(rawValue: 1 << 0)
            static public let noDelay = TCPOptions.Flags(rawValue: 1 << 1)
            static public let noTimewait = TCPOptions.Flags(rawValue: 1 << 2)
            static public let noPush = TCPOptions.Flags(rawValue: 1 << 3)
            static public let noOptions = TCPOptions.Flags(rawValue: 1 << 4)
            static public let enableKeepalive = TCPOptions.Flags(rawValue: 1 << 5)
            static public let enableKeepaliveOffload = TCPOptions.Flags(rawValue: 1 << 6)
            static public let disableAckStretching = TCPOptions.Flags(rawValue: 1 << 7)
            static public let disableBlackholeDetection = TCPOptions.Flags(rawValue: 1 << 8)
            static public let enableBackgroundTrafficManagement = TCPOptions.Flags(rawValue: 1 << 9)
            static public let retransmitFinDrop = TCPOptions.Flags(rawValue: 1 << 10)
            static public let enableFastOpen = TCPOptions.Flags(rawValue: 1 << 11)
            static public let useTFOHasBeenSet = TCPOptions.Flags(rawValue: 1 << 12)
            static public let noFastOpenCookie = TCPOptions.Flags(rawValue: 1 << 13)
            static public let fastOpenForceEnable = TCPOptions.Flags(rawValue: 1 << 14)
            static public let disableECN = TCPOptions.Flags(rawValue: 1 << 15)
            static public let resetLocalPort = TCPOptions.Flags(rawValue: 1 << 16)

        }
        var flags: Flags = Flags()

        public init() {
            // Create with reduceBuffering enabled
            flags.insert(.reduceBuffering)
        }

        public func serialize() -> [UInt8]? {
            nil
        }
        public var serializeInParameters: Bool {
            false
        }
        public func deepCopy() -> TCPOptions {
            self
        }
        public func isEqual(to other: TCPOptions, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    public class TCPMetadata: PerProtocolMetadata {
        struct TCPOptionCallbacks: Equatable {
            let get_receive_buffer_size: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
            let get_send_buffer_size: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
            let reset_keepalives: (@convention(c) (UnsafeMutableRawPointer?, Bool, UInt32, UInt32, UInt32) -> Int32)?
            let set_no_delay: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32)?
            let set_no_push: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32)?
            let set_no_wake_from_sleep: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32)?
            let set_max_pacing_rate: (@convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32)?

            static func == (
                lhs: TCPProtocol.TCPMetadata.TCPOptionCallbacks,
                rhs: TCPProtocol.TCPMetadata.TCPOptionCallbacks
            ) -> Bool {
                // Equatable for structs with C-callbacks will not work.
                // TCPMetadata needs to conform to Equatable though because PerProtocolMetadata does.
                false
            }
        }

        let mutex = NetworkMutex(())
        var callbacks: TCPOptionCallbacks?
        var handle: UnsafeMutableRawPointer?

        public init() {}

        public func isEqual(to other: TCPMetadata, for: ProtocolCompareMode) -> Bool { true }

        public static func == (lhs: borrowing TCPProtocol.TCPMetadata, rhs: borrowing TCPProtocol.TCPMetadata) -> Bool {
            lhs.isEqual(to: rhs, for: .equal)
        }

        public func getReceiveBufferSize() -> UInt32 {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let get_receive_buffer_size = tcpCallbacks.get_receive_buffer_size
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for getReceiveBufferSize")
                return 0
            }
            var receiveBuffersize: UInt32 = 0
            mutex.withLock { _ in
                receiveBuffersize = get_receive_buffer_size(tcpHandle)
            }
            return receiveBuffersize
        }

        public func getSendBufferSize() -> UInt32 {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let get_send_buffer_size = tcpCallbacks.get_send_buffer_size
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for getSendBufferSize")
                return 0
            }
            var sendBuffersize: UInt32 = 0
            mutex.withLock { _ in
                sendBuffersize = get_send_buffer_size(tcpHandle)
            }
            return sendBuffersize
        }

        public func resetKeepalives(enableKeepalives: Bool, count: UInt32, idleTime: UInt32, interval: UInt32) -> Int32
        {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let reset_keepalives = tcpCallbacks.reset_keepalives
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for resetKeepalives")
                return 0
            }
            var ret: Int32 = 0
            mutex.withLock { _ in
                ret = reset_keepalives(tcpHandle, enableKeepalives, count, idleTime, interval)
            }
            return ret
        }

        public func setNoDelay(noDelay: Bool) -> Int32 {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let set_no_delay = tcpCallbacks.set_no_delay
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for setNoDelay")
                return 0
            }
            var ret: Int32 = 0
            mutex.withLock { _ in
                ret = set_no_delay(tcpHandle, noDelay)
            }
            return ret
        }

        public func setNoPush(noPush: Bool) -> Int32 {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let set_no_push = tcpCallbacks.set_no_push
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for setNoPush")
                return 0
            }
            var ret: Int32 = 0
            mutex.withLock { _ in
                ret = set_no_push(tcpHandle, noPush)
            }
            return ret
        }

        public func setNoWakeFromSleep(noWakeFromSleep: Bool) -> Int32 {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let set_no_wake_from_sleep = tcpCallbacks.set_no_wake_from_sleep
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for setNoWakeFromSleep")
                return 0
            }
            var ret: Int32 = 0
            mutex.withLock { _ in
                ret = set_no_wake_from_sleep(tcpHandle, noWakeFromSleep)
            }
            return ret
        }

        public func setMaxPacingRate(maxPacingRate: UInt64) -> Int32 {
            guard let tcpCallbacks = self.callbacks,
                let tcpHandle = self.handle,
                let set_max_pacing_rate = tcpCallbacks.set_max_pacing_rate
            else {
                Logger.proto.error("TCPMetadata callbacks not setup for setMaxPacingRate")
                return 0
            }
            var ret: Int32 = 0
            mutex.withLock { _ in
                ret = set_max_pacing_rate(tcpHandle, maxPacingRate)
            }
            return ret
        }
    }

    final class TCPInstance: OneToOneStreamToDatagramProtocol, TimerSchedulable {
        var upper = InboundStreamLinkage()
        var lower = OutboundDatagramLinkage()

        private(set) var context: NetworkContext
        init(context: NetworkContext) { self.context = context }
        var reference: ProtocolInstanceReference { ProtocolInstanceReference(tcp: self) }
        var passthroughEvents = false
        var log = NetworkLoggerState()
        var eventManager = ProtocolEventManager()
        let timerReference = TimerReference()
        func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            throw NetworkError.posix(ENOTSUP)
        }
        func wakeup() {}
        func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? { nil }
        func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int { 0 }
        func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {}
        #if !NETWORK_EMBEDDED
        var metadata: AbstractProtocolMetadata? { nil }
        #endif
    }

    public init() {}
    public func newPerProtocolOptions() -> TCPOptions? { TCPOptions() }
    public func newPerProtocolOptions(from existing: TCPOptions) -> TCPOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> TCPOptions? { nil }
    public func newPerProtocolMetadata() -> TCPMetadata? { TCPMetadata() }
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? { nil }

    static let identifier = ProtocolIdentifier(name: "tcp", level: .transport, mapping: .oneToOne)

    #if !NETWORK_PRIVATE
    static public let definition = ProtocolDefinition<TCPProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<TCPProtocol> { TCPProtocol.definition.protocolOptions() }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        TCPProtocol().newProtocolInstance(context: context)!
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension ProtocolOptions<TCPProtocol> {
    public var reduceBuffering: Bool {
        get { perProtocolOptions!.reduceBuffering }
        set { perProtocolOptions!.reduceBuffering = newValue }
    }
    public var noDelay: Bool {
        get { perProtocolOptions!.noDelay }
        set { perProtocolOptions!.noDelay = newValue }
    }
    public var noTimewait: Bool {
        get { perProtocolOptions!.noTimewait }
        set { perProtocolOptions!.noTimewait = newValue }
    }
    public var noPush: Bool {
        get { perProtocolOptions!.noPush }
        set { perProtocolOptions!.noPush = newValue }
    }
    public var noOptions: Bool {
        get { perProtocolOptions!.noOptions }
        set { perProtocolOptions!.noOptions = newValue }
    }
    public var enableKeepalive: Bool {
        get { perProtocolOptions!.enableKeepalive }
        set { perProtocolOptions!.enableKeepalive = newValue }
    }
    public var enableKeepaliveOffload: Bool {
        get { perProtocolOptions!.enableKeepaliveOffload }
        set { perProtocolOptions!.enableKeepaliveOffload = newValue }
    }
    public var disableAckStretching: Bool {
        get { perProtocolOptions!.disableAckStretching }
        set { perProtocolOptions!.disableAckStretching = newValue }
    }
    public var disableBlackholeDetection: Bool {
        get { perProtocolOptions!.disableBlackholeDetection }
        set { perProtocolOptions!.disableBlackholeDetection = newValue }
    }
    public var enableBackgroundTrafficManagement: Bool {
        get { perProtocolOptions!.enableBackgroundTrafficManagement }
        set { perProtocolOptions!.enableBackgroundTrafficManagement = newValue }
    }
    public var retransmitFinDrop: Bool {
        get { perProtocolOptions!.retransmitFinDrop }
        set { perProtocolOptions!.retransmitFinDrop = newValue }
    }
    public var enableFastOpen: Bool {
        get { perProtocolOptions!.enableFastOpen }
        set { perProtocolOptions!.enableFastOpen = newValue }
    }
    public var noFastOpenCookie: Bool {
        get { perProtocolOptions!.noFastOpenCookie }
        set { perProtocolOptions!.noFastOpenCookie = newValue }
    }
    public var fastOpenForceEnable: Bool {
        get { perProtocolOptions!.fastOpenForceEnable }
        set { perProtocolOptions!.fastOpenForceEnable = newValue }
    }
    public var disableECN: Bool {
        get { perProtocolOptions!.disableECN }
        set { perProtocolOptions!.disableECN = newValue }
    }
    public var resetLocalPort: Bool {
        get { perProtocolOptions!.resetLocalPort }
        set { perProtocolOptions!.resetLocalPort = newValue }
    }
    public var keepaliveIdleTime: UInt32 {
        get { perProtocolOptions!.keepaliveIdleTime }
        set { perProtocolOptions!.keepaliveIdleTime = newValue }
    }
    public var keepaliveInterval: UInt32 {
        get { perProtocolOptions!.keepaliveInterval }
        set { perProtocolOptions!.keepaliveInterval = newValue }
    }
}
