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
public struct CustomLinkProtocol: NetworkProtocol {
    public typealias Options = CustomLinkOptions
    public typealias Metadata = CustomLinkMetadata
    public typealias Instance = CustomLinkInstance

    public struct CustomLinkOptions: PerProtocolOptions {
        public var tx: ((Span<UInt8>) -> Void)? = nil
        public var rx: ((@escaping (Span<UInt8>) -> Void) -> Void)? = nil
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
        public func deepCopy() -> CustomLinkOptions {
            self
        }
        public func isEqual(to other: CustomLinkOptions, for: ProtocolCompareMode) -> Bool {
            true
        }
        public static func == (lhs: borrowing CustomLinkOptions, rhs: borrowing CustomLinkOptions) -> Bool {
            true
        }

        var isDefault: Bool {
            self == CustomLinkOptions()
        }
    }

    public struct CustomLinkMetadata: PerProtocolMetadata {
        var isStatic: Bool = false

        init() {}
        public func isEqual(to other: CustomLinkMetadata, for: ProtocolCompareMode) -> Bool {
            self == other
        }
    }

    public final class CustomLinkInstance: BottomStreamProtocol {
        public typealias LinkageType = BaseOutboundStreamLinkage
        public typealias UpperProtocol = BaseInboundStreamLinkage

        public var upper = UpperProtocol()

        public private(set) var context: NetworkContext
        init(context: NetworkContext) {
            self.context = context
            self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
        }
        public var identifier: InstanceIdentifier
        var log = NetworkLoggerState()
        public var eventManager = ProtocolEventManager()
        private var incomingFrames = FrameArray()
        public var tx: ((Span<UInt8>) -> Void)? = nil
        public var rx: ((@escaping (Span<UInt8>) -> Void) -> Void)? = nil

        public func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            if let parameters, let customLinkOptions = parameters.customLinkOptions(for: self.identifier) {
                self.tx = customLinkOptions.tx
                self.rx = customLinkOptions.rx
            }
            if let rx = self.rx {
                rx { bytes in
                    self.context.assert()
                    self.incomingFrames.add(frames: FrameArray(frame: Frame(copyBuffer: bytes)))
                    // The read handler is an entry point into the stack, so acquire the event
                    // state here rather than assuming the caller holds it.
                    self.fromExternal { eventContext in
                        self.upper.deliverInboundDataAvailableEvent(
                            from: self.identifier,
                            in: &eventContext
                        )
                    }
                }
            }
        }

        public func teardown() {
            incomingFrames.finalizeAllFramesAsFailed()
        }

        deinit {
            incomingFrames.finalizeAllFramesAsFailed()
        }

        public func connect(for instance: InstanceIdentifier, in eventContext: inout NetworkContext.EventContext) {
            upper.deliverConnectedEvent(from: identifier, in: &eventContext)
        }

        public func receiveStreamData(
            minimumBytes: Int,
            maximumBytes: Int,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> FrameArray? {
            incomingFrames.drainArray(maximumByteCount: maximumBytes)
        }

        public func getOutboundStreamDataRoomAvailable(
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) -> Int {
            Int.max
        }

        public func sendStreamData(
            _ streamData: consuming FrameArray,
            in eventContext: inout NetworkContext.EventContext
        ) throws(NetworkError) {
            streamData.iterateMutableFrames { frame in
                if let tx, let span = frame.span {
                    tx(span)
                }
                frame.finalize(success: true)
                return true
            }
        }

        #if !NETWORK_EMBEDDED
        public var metadata: AbstractProtocolMetadata? { nil }
        #endif
    }

    public init() {}
    public func newPerProtocolOptions() -> CustomLinkOptions? { CustomLinkOptions() }
    public func newPerProtocolOptions(from existing: CustomLinkOptions) -> CustomLinkOptions { existing }
    public func newPerProtocolOptions(from serializedBytes: [UInt8]) -> CustomLinkOptions? {
        CustomLinkOptions(from: serializedBytes)
    }
    public func newPerProtocolMetadata() -> CustomLinkMetadata? { CustomLinkMetadata() }

    static let identifier = ProtocolIdentifier(name: "CustomLink", level: .link, mapping: .oneToOne)
    static let definition = ProtocolDefinition<CustomLinkProtocol>(identifier: identifier)

    static public func options() -> ProtocolOptions<CustomLinkProtocol> {
        CustomLinkProtocol.definition.protocolOptions()
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension ProtocolOptions<CustomLinkProtocol> {
    public var tx: ((Span<UInt8>) -> Void)? {
        get { perProtocolOptions!.tx }
        set { perProtocolOptions!.tx = newValue }
    }

    public var rx: ((@escaping (Span<UInt8>) -> Void) -> Void)? {
        get { perProtocolOptions!.rx }
        set { perProtocolOptions!.rx = newValue }
    }
}
