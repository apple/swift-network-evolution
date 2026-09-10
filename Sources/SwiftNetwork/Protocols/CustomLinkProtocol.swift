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
        public var rx: ((@escaping ([UInt8]) -> Void) -> Void)? = nil
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

    public final class CustomLinkInstance: BottomStreamProtocol, ProtocolInstanceContainer {
        public var upper = InboundStreamLinkage()
        var lower = OutboundStreamLinkage()

        public private(set) var context: NetworkContext
        init(context: NetworkContext) { self.context = context }
        public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
        var log = NetworkLoggerState()
        public var eventManager = ProtocolEventManager()
        private var incomingFrames = FrameArray()
        public var tx: ((Span<UInt8>) -> Void)? = nil
        public var rx: ((@escaping ([UInt8]) -> Void) -> Void)? = nil

        public func setup(
            remote: Endpoint?,
            local: Endpoint?,
            parameters: Parameters?,
            path: PathProperties?
        ) throws(NetworkError) {
            #if !NETWORK_EMBEDDED
            if let parameters, let CustomLinkOptions: ProtocolOptions<CustomLinkProtocol> = getOptions(from: parameters)
            {
                self.tx = CustomLinkOptions.tx
                self.rx = CustomLinkOptions.rx
            }
            if let rx = self.rx {
                rx { bytes in
                    self.context.async {
                        self.incomingFrames.add(frames: FrameArray(frame: Frame(copyBuffer: bytes)))
                        self.deliverInboundDataAvailableEvent()
                    }
                }
            }
            #endif
        }

        public func teardown() {
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
    public func newProtocolInstance(context: NetworkContext) -> ProtocolInstanceReference? {
        CustomLinkInstance(context: context).reference
    }

    static let identifier = ProtocolIdentifier(name: "CustomLink", level: .link, mapping: .oneToOne)
    static let definition = ProtocolDefinition<CustomLinkProtocol>(identifier: identifier)

    static public func options() -> ProtocolOptions<CustomLinkProtocol> {
        CustomLinkProtocol.definition.protocolOptions()
    }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        CustomLinkProtocol().newProtocolInstance(context: context)!
    }
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension ProtocolOptions<CustomLinkProtocol> {
    public var tx: ((Span<UInt8>) -> Void)? {
        get { perProtocolOptions!.tx }
        set { perProtocolOptions!.tx = newValue }
    }

    public var rx: ((@escaping ([UInt8]) -> Void) -> Void)? {
        get { perProtocolOptions!.rx }
        set { perProtocolOptions!.rx = newValue }
    }
}
