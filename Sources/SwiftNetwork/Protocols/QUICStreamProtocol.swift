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
#elseif canImport(os)
internal import os
#endif

#if canImport(Synchronization)
internal import Synchronization
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias QUICProtocol = QUICStreamProtocol

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICStreamProtocol: NetworkProtocol {
    public typealias Options = QUICStreamOptions
    public typealias Metadata = QUICStreamMetadata
    public typealias Instance = QUICConnection

    #if !NETWORK_EMBEDDED
    public typealias QUICMetadataSetterHandler = (@convention(block) (UInt64) -> Void)
    public typealias QUICMetadataSetterHandlerBlock = (@convention(block) () -> Void)
    #endif

    // QUICStreamOptions -

    public final class QUICStreamOptions: PerProtocolOptions {
        internal typealias BytesCount = UInt32

        public var associatedStreamID: UInt64?
        var datagramContextID: UInt64?

        public var quicConnectionOptions = QUICConnectionProtocol.QUICConnectionOptions()

        #if NETWORK_PRIVATE
        var privateStorage = QUICStreamOptionsPrivateStorage()
        #endif

        public var isUnidirectional: Bool {
            get { flags.contains(.isUnidirectional) }
            set { if newValue { flags.insert(.isUnidirectional) } else { flags.remove(.isUnidirectional) } }
        }
        public var isDatagram: Bool {
            get { flags.contains(.isDatagram) }
            set { if newValue { flags.insert(.isDatagram) } else { flags.remove(.isDatagram) } }
        }

        struct Flags: OptionSet {
            public init(rawValue: Self.RawValue) {
                self.rawValue = rawValue
            }
            public var rawValue: UInt8
            static public let isUnidirectional = QUICStreamOptions.Flags(rawValue: 1 << 0)
            static public let isDatagram = QUICStreamOptions.Flags(rawValue: 1 << 1)
        }
        var flags: Flags = Flags()

        public init() {
            // Ensure that the connection protocol definition is registered
            // Otherwise, we can end up registering only when we start a connection,
            // which can deadlock
            _ = QUICConnectionProtocol.definition
        }

        init?(from serializedBytes: [UInt8]) {
            // stream options
            var associatedStreamID: UInt64 = 0
            var datagramContextID: UInt64 = 0
            var flagsByte: UInt8 = 0
            // connection options
            var maxUDPPayloadSize: UInt16 = 0
            var idleTimeout: UInt32 = 0
            var maxDatagramFrameSize: UInt16 = 0
            var initialPacketSize: UInt16 = 0
            var keepaliveCount: UInt16 = 0
            var enableL4S: UInt8 = 0
            var pqtlsMode: UInt16 = 0
            var connectionFlags: UInt64 = 0

            // Connection IDs
            var destinationConnectionIDLength: UInt8 = 0
            var destinationConnectionIDData: [UInt8] = []
            var sourceConnectionIDLength: UInt8 = 0
            var sourceConnectionIDData: [UInt8] = []

            // Step 1: Extract all of the values
            let result = Deserializer.deserialize(serializedBytes.span) { read throws(DeserializationError) in
                try read.uint16(&maxUDPPayloadSize)
                try read.uint32(&idleTimeout)
                try read.uint16(&maxDatagramFrameSize)
                try read.uint16(&initialPacketSize)
                try read.uint16(&keepaliveCount)
                try read.uint64(&connectionFlags)
                try read.uint8(&enableL4S)
                try read.uint16(&pqtlsMode)
                try read.uint64(&associatedStreamID)
                try read.uint64(&datagramContextID)
                try read.uint8(&flagsByte)

                // Read connection IDs
                try read.uint8(&destinationConnectionIDLength)
                try read.buffer(&destinationConnectionIDData, length: Int(destinationConnectionIDLength))
                try read.uint8(&sourceConnectionIDLength)
                try read.buffer(&sourceConnectionIDData, length: Int(sourceConnectionIDLength))
            }
            guard result.isValid else {
                Logger.proto.error("Deserialize result: \(result)")
                return
            }
            // Step 2: Set the QUICConnectionOptions values
            self.quicConnectionOptions.maxUDPPayloadSize = maxUDPPayloadSize
            self.quicConnectionOptions.idleTimeout = .milliseconds(idleTimeout)
            self.quicConnectionOptions.maxDatagramFrameSize = maxDatagramFrameSize
            self.quicConnectionOptions.initialPacketSize = initialPacketSize
            self.quicConnectionOptions.keepaliveCount = keepaliveCount
            self.quicConnectionOptions.pqtlsMode = pqtlsMode

            // Set connection IDs
            if destinationConnectionIDLength > 0 {
                self.quicConnectionOptions.destinationConnectionID = destinationConnectionIDData
            }
            if sourceConnectionIDLength > 0 {
                self.quicConnectionOptions.sourceConnectionID = sourceConnectionIDData
            }
            // Step 3: Set the QUICConnectionOptions flags to a local variable so that internal state can be setup correctly
            let parsedConnectionFlags: QUICConnectionProtocol.QUICConnectionOptions.Flags = QUICConnectionProtocol
                .QUICConnectionOptions.Flags(rawValue: connectionFlags)
            // nil = default = 0
            // true = enabled = 1
            // false = disabled = 2
            if enableL4S == 0 {
                self.quicConnectionOptions.enableL4S = nil
            } else {
                self.quicConnectionOptions.enableL4S = enableL4S == 1 ? true : false
            }
            // Step 4: Set the QUICStreamOptions values
            self.associatedStreamID = associatedStreamID
            self.datagramContextID = datagramContextID
            self.flags = Flags(rawValue: flagsByte)

            // Set the QUICConnectionOptions flags
            self.quicConnectionOptions.flags = parsedConnectionFlags

            #if NETWORK_PRIVATE
            if case .remaining(let left) = result {
                let count = serializedBytes.count
                let offset = count - left
                updatePrivateStorage(from: [UInt8](serializedBytes[offset..<count]))
            }
            #endif
        }

        // Serializing StreamOptions is very important functionality in the codebase because it provides support
        // setting up a proxy config with key and certificate information when connecting to products like EdgeRelay or PrivateRelay.
        public func serialize() -> [UInt8]? {
            let connectionOptions = self.quicConnectionOptions

            // Connection IDs data
            let destinationConnectionIDData = connectionOptions.destinationConnectionID ?? []
            let sourceConnectionIDData = connectionOptions.sourceConnectionID ?? []
            let destinationConnectionIDLength = UInt8(destinationConnectionIDData.count)
            let sourceConnectionIDLength = UInt8(sourceConnectionIDData.count)

            // nil = default = 0
            // true = enabled = 1
            // false = disabled = 2
            var enableL4S: UInt8 = 0
            if let enablel4s = connectionOptions.enableL4S {
                if enablel4s == true { enableL4S = 1 } else { enableL4S = 2 }
            }

            #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
            let privateStorageData = serializePrivate()
            #endif

            return Serializer.serialize { write in
                write.uint16(connectionOptions.maxUDPPayloadSize)
                write.uint32(UInt32(truncatingIfNeeded: connectionOptions.idleTimeout.milliseconds))
                write.uint16(connectionOptions.maxDatagramFrameSize)
                write.uint16(connectionOptions.initialPacketSize)
                write.uint16(connectionOptions.keepaliveCount)
                write.uint64(connectionOptions.flags.rawValue)
                write.uint8(enableL4S)
                write.uint16(connectionOptions.pqtlsMode)
                write.uint64(associatedStreamID ?? 0)
                write.uint64(datagramContextID ?? 0)
                write.uint8(flags.rawValue)

                // Write connection IDs
                write.uint8(destinationConnectionIDLength)
                write.buffer(destinationConnectionIDData)
                write.uint8(sourceConnectionIDLength)
                write.buffer(sourceConnectionIDData)

                #if NETWORK_PRIVATE || NETWORK_DRIVERKIT
                write.buffer(privateStorageData)
                #endif
            }
        }

        public var serializeInParameters: Bool {
            true
        }
        public func deepCopy() -> Self {
            // NOTE: This is a class so we need to make an explicit copy here.
            // StreamOptions is used to make important decisions about unidirectional/bidirectional streams.
            // And these options are often used at the same time in different places in the code.  So a new object is created here.
            let streamOptions = Self()
            streamOptions.associatedStreamID = self.associatedStreamID
            streamOptions.quicConnectionOptions = self.quicConnectionOptions.deepCopy()
            streamOptions.datagramContextID = self.datagramContextID
            streamOptions.isDatagram = self.isDatagram
            streamOptions.isUnidirectional = self.isUnidirectional
            streamOptions.flags = self.flags

            #if NETWORK_PRIVATE
            streamOptions.privateStorage = self.privateStorage.deepCopy()
            #endif
            return streamOptions
        }

        public func isEqual(to other: QUICStreamOptions, for compareMode: ProtocolCompareMode) -> Bool {
            #if NETWORK_PRIVATE
            guard self.privateStorage == other.privateStorage else { return false }
            #endif
            let connectionOptions = self.quicConnectionOptions
            let otherConnectionOptions = other.quicConnectionOptions
            return connectionOptions.isEqual(to: otherConnectionOptions, for: compareMode)
        }

        static public func == (lhs: QUICStreamOptions, rhs: QUICStreamOptions) -> Bool {
            #if NETWORK_PRIVATE
            guard lhs.privateStorage == rhs.privateStorage else { return false }
            #endif
            if lhs.associatedStreamID == rhs.associatedStreamID && lhs.datagramContextID == rhs.datagramContextID
                && lhs.quicConnectionOptions == rhs.quicConnectionOptions
                && lhs.isUnidirectional == rhs.isUnidirectional && lhs.isDatagram == rhs.isDatagram
            {
                return true
            }
            return false
        }

        func copySharedConnectionOptions() -> ProtocolOptions<QUICConnectionProtocol> {
            let connectionOptions = self.quicConnectionOptions
            return ProtocolOptions<QUICConnectionProtocol>(
                protocolIdentifier: QUICConnectionProtocol.identifier,
                perProtocolOptions: connectionOptions
            )
        }
    }

    // QUICStreamMetadata -

    public struct QUICStreamMetadata: ~Copyable, PerProtocolMetadata {

        var streamID: UInt64 = 0

        var datagramFlowID: UInt64?

        var applicationError: UInt64?

        var reliableSize: UInt64 = 0

        #if !NETWORK_EMBEDDED
        var setApplicationErrorHandler: QUICMetadataSetterHandler?
        #endif
        var quicConnectionMetadata: QUICConnectionProtocol.QUICConnectionMetadata?

        var usableDatagramFrameSize: UInt16 = 0

        var streamType: QUICStreamType = .bidirectional
        var isDatagramFlow = false

        var hasDatagramFlowID: Bool {
            datagramFlowID != nil
        }

        public init() {}

        public func isEqual(to other: borrowing QUICStreamMetadata, for: ProtocolCompareMode) -> Bool {
            true
        }

        func deepCopy() -> Self {
            var explicitCopy = QUICStreamMetadata()
            explicitCopy.streamID = self.streamID
            explicitCopy.datagramFlowID = self.datagramFlowID
            explicitCopy.applicationError = self.applicationError
            explicitCopy.reliableSize = self.reliableSize
            #if !NETWORK_EMBEDDED
            explicitCopy.setApplicationErrorHandler = self.setApplicationErrorHandler
            #endif
            explicitCopy.quicConnectionMetadata = self.quicConnectionMetadata
            explicitCopy.usableDatagramFrameSize = self.usableDatagramFrameSize
            explicitCopy.streamType = self.streamType
            explicitCopy.isDatagramFlow = self.isDatagramFlow
            return explicitCopy
        }

        static public func == (lhs: borrowing QUICStreamMetadata, rhs: borrowing QUICStreamMetadata) -> Bool {
            if lhs.streamID == rhs.streamID && lhs.datagramFlowID == rhs.datagramFlowID
                && lhs.applicationError == rhs.applicationError
                && lhs.quicConnectionMetadata == rhs.quicConnectionMetadata
                && lhs.usableDatagramFrameSize == rhs.usableDatagramFrameSize && lhs.streamType == rhs.streamType
            {
                return true
            }
            return false
        }
        #if !NETWORK_EMBEDDED
        func copyConnectionMetadata() -> ProtocolMetadata<QUICConnectionProtocol>? {
            mutex.withLock { _ in
                guard let connectionMetadata = self.quicConnectionMetadata else {
                    return nil
                }
                var protocolMetadata: ProtocolMetadata<QUICConnectionProtocol>
                protocolMetadata = ProtocolMetadata<QUICConnectionProtocol>(
                    protocolIdentifier: QUICConnectionProtocol.identifier,
                    perProtocolMetadata: connectionMetadata,
                    messageIdentifier: SystemUUID()
                )
                return protocolMetadata
            }
        }

        mutating func setConnectionMetadata(connectionMetadata: QUICConnectionProtocol.QUICConnectionMetadata) {
            mutex.withLock { _ in
                self.quicConnectionMetadata = connectionMetadata
            }
        }

        func setApplicationError(_ applicationError: UInt64) {
            mutex.withLock { _ in
                guard let setApplicationError = self.setApplicationErrorHandler else {
                    return
                }
                setApplicationError(applicationError)
            }
        }

        mutating func setApplicationError(handler: @escaping QUICMetadataSetterHandler) {
            mutex.withLock { _ in
                self.setApplicationErrorHandler = handler
            }
        }

        func executeLocked(block: (@convention(c) () -> Void)) {
            mutex.withLock { _ in
                block()
            }
        }

        let mutex = NetworkMutex(())
        #endif
    }

    public init() {}

    public func newPerProtocolOptions() -> QUICStreamOptions? { QUICStreamOptions() }
    public func newPerProtocolOptions(from existing: QUICStreamOptions) -> QUICStreamOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> QUICStreamOptions? {
        QUICStreamOptions(from: serializedBytes)
    }
    public func newPerProtocolMetadata() -> QUICStreamMetadata? { QUICStreamMetadata() }
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        QUICConnection(context: context).reference
    }

    static let identifier = ProtocolIdentifier(name: "quic", level: .transport, mapping: .manyToOne)

    #if !NETWORK_PRIVATE
    public static let definition = ProtocolDefinition<QUICStreamProtocol>(identifier: identifier)
    #endif

    static public func options() -> ProtocolOptions<QUICStreamProtocol> {
        QUICStreamProtocol.definition.protocolOptions()
    }
    static public func metadata() -> ProtocolMetadata<QUICStreamProtocol> {
        QUICStreamProtocol.definition.protocolMetadata()
    }
    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        QUICStreamProtocol().newProtocolInstance(context: context)!
    }
}

extension ProtocolOptions<QUICProtocol> {
    var isDatagram: Bool {
        get { perProtocolOptions!.isDatagram }
        set { perProtocolOptions!.isDatagram = newValue }
    }

    public var isUnidirectional: Bool {
        get { perProtocolOptions!.isUnidirectional }
        set { perProtocolOptions!.isUnidirectional = newValue }
    }
    public var connectionOptions: QUICConnectionProtocol.QUICConnectionOptions {
        get { perProtocolOptions!.quicConnectionOptions }
        set { perProtocolOptions!.quicConnectionOptions = newValue }
    }

    #if !NETWORK_PRIVATE
    public var tlsOptions: TLSProtocol.Options {
        get { perProtocolOptions!.quicConnectionOptions.tlsOptions!.perProtocolOptions! }
        set { perProtocolOptions!.quicConnectionOptions.tlsOptions!.perProtocolOptions = newValue }
    }
    #endif
}

extension ProtocolMetadata<QUICProtocol> {
    public internal(set) var streamID: UInt64? {
        get { mutablePerProtocolMetadata { $0?.streamID } }
        set {
            mutablePerProtocolMetadata {
                guard let newValue else { return }
                $0?.streamID = newValue
            }
        }
    }
    public var applicationError: UInt64? {
        get { mutablePerProtocolMetadata { $0?.applicationError } }
        set { mutablePerProtocolMetadata { $0?.applicationError = newValue } }
    }
    public var isBidirectional: Bool {
        !isDatagram && (mutablePerProtocolMetadata { $0?.streamType == .bidirectional })
    }
    public var isUnidirectional: Bool {
        !isDatagram && (mutablePerProtocolMetadata { $0?.streamType == .unidirectional })
    }
    public internal(set) var connectionMetadata: QUICConnectionProtocol.QUICConnectionMetadata? {
        get { mutablePerProtocolMetadata { $0?.quicConnectionMetadata } }
        set { mutablePerProtocolMetadata { $0?.quicConnectionMetadata = newValue } }
    }
    public internal(set) var streamType: QUICStreamType {
        get { mutablePerProtocolMetadata { $0?.streamType ?? .bidirectional } }
        set { mutablePerProtocolMetadata { $0?.streamType = newValue } }
    }
    public internal(set) var datagramFlowID: UInt64? {
        get { mutablePerProtocolMetadata { $0?.datagramFlowID } }
        set { mutablePerProtocolMetadata { $0?.datagramFlowID = newValue } }
    }
    public internal(set) var usableDatagramFrameSize: UInt16 {
        get { mutablePerProtocolMetadata { $0?.usableDatagramFrameSize ?? 0 } }
        set { mutablePerProtocolMetadata { $0?.usableDatagramFrameSize = newValue } }
    }
    public internal(set) var isDatagram: Bool {
        get { mutablePerProtocolMetadata { $0?.isDatagramFlow ?? false } }
        set { mutablePerProtocolMetadata { $0?.isDatagramFlow = newValue } }
    }
}
