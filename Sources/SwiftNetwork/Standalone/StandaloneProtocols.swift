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

#if !NETWORK_EMBEDDED && !NETWORK_PRIVATE && !NETWORK_STANDALONE && canImport(Synchronization) && canImport(Dispatch)

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// The surface of a protocol that its owner drives directly.
//
// A protocol normally runs between a protocol above and a protocol below, joined by linkages, on a
// context that schedules for it. Some clients hold exactly one protocol and want to be that
// protocol's neighbours and its scheduler: they inject data from the application above and the
// network below, set the timers the protocol asks for, and collect its events. These protocols
// describe that surface generically, so a client written against `StandaloneManyToManyProtocol`
// works with QUIC or with any other protocol that multiplexes flows over paths.
//
// A conforming type is a concrete value that owns its protocol instance. Nothing here names a
// linkage; how events and data are collected is the conforming type's business.

/// What the application reads from a stream: bytes, and whether the peer finished sending.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct StandaloneStreamRead {
    public var bytes: [UInt8]
    /// The peer sent FIN with this data.
    public var isFinal: Bool
}

/// The surface every standalone protocol has.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StandaloneProtocol: ~Copyable {
    /// The owner's clock, timers, asyncs and event queue.
    var environment: StandaloneEnvironment { get }

    /// Asks the protocol to connect. Connection results arrive as events.
    func connect()

    /// Asks the protocol to disconnect.
    func disconnect(error: NetworkError?)

    /// Sends an event from the application to the protocol.
    func applicationEvent(_ event: ApplicationEvent)

    func getMetrics(_ requested: RequestedNetworkMetrics) -> NetworkMetrics?

    /// Detaches everything and releases the protocol. A protocol that is dropped without being
    /// closed is closed on the way out.
    consuming func close()
}

// MARK: - One-to-one

/// A protocol with one protocol above and one below, such as UDP or TLS record.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StandaloneOneToOneProtocol: StandaloneProtocol, ~Copyable {
    /// Hands the protocol data that arrived from the network below.
    ///
    /// The protocol is told the data is available, so an `inboundDataAvailable` event follows for
    /// the application.
    func receiveFromBelow(_ frames: consuming FrameArray)

    /// Collects what the protocol queued to send below, in order.
    func takeOutbound() -> FrameArray

    /// Tells the protocol about a change in the network below, such as viability.
    func deliverNetworkEvent(_ event: NetworkProtocolEvent)
}

/// A one-to-one protocol that carries datagrams to the application.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StandaloneOneToOneDatagramProtocol: StandaloneOneToOneProtocol, ~Copyable {
    func getDatagramsToSend(maximumDatagramCount: Int, minimumDatagramSize: Int) throws(NetworkError) -> FrameArray?
    func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError)
    func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray?
}

/// A one-to-one protocol that carries a stream to the application.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StandaloneOneToOneStreamProtocol: StandaloneOneToOneProtocol, ~Copyable {
    func sendStreamData(_ streamData: consuming FrameArray, early: Bool) throws(NetworkError)
    func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray?
    func outboundRoomAvailable() throws(NetworkError) -> Int
    func abortInbound(error: NetworkError?) throws(NetworkError)
    func abortOutbound(error: NetworkError?) throws(NetworkError)
}

// MARK: - Many-to-many

/// A protocol that multiplexes flows (streams and datagram flows) over one or more paths, such as
/// QUIC.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol StandaloneManyToManyProtocol: StandaloneProtocol, ~Copyable {
    // MARK: Flows

    /// Creates a stream. The stream is not connected until `connect(flow:)`.
    func openStream() throws(NetworkError) -> StandaloneFlowID

    /// Creates a datagram flow. Throws `ENOTSUP` for a protocol without datagram flows.
    func openDatagramFlow() throws(NetworkError) -> StandaloneFlowID

    func connect(flow: StandaloneFlowID)
    func disconnect(flow: StandaloneFlowID, error: NetworkError?)

    /// Detaches the flow from the protocol. The flow cannot be used afterwards.
    func teardown(flow: StandaloneFlowID)

    func applicationEvent(flow: StandaloneFlowID, _ event: ApplicationEvent)

    func getMetadata<P: NetworkProtocol>(flow: StandaloneFlowID) -> ProtocolMetadata<P>?

    // MARK: From the application, per flow

    func sendStreamData(
        flow: StandaloneFlowID,
        _ streamData: consuming FrameArray,
        early: Bool
    ) throws(NetworkError)
    func receiveStreamData(
        flow: StandaloneFlowID,
        minimumBytes: Int,
        maximumBytes: Int
    ) throws(NetworkError) -> FrameArray?
    func abortInbound(flow: StandaloneFlowID, error: NetworkError?) throws(NetworkError)
    func abortOutbound(flow: StandaloneFlowID, error: NetworkError?) throws(NetworkError)

    func getDatagramsToSend(
        flow: StandaloneFlowID,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray?
    func sendDatagrams(flow: StandaloneFlowID, _ datagrams: consuming FrameArray) throws(NetworkError)
    func receiveDatagrams(flow: StandaloneFlowID, maximumDatagramCount: Int) throws(NetworkError) -> FrameArray?

    // MARK: Paths and the network below

    /// Adds a path. The first path is the primary one.
    mutating func addPath(local: Endpoint, remote: Endpoint) throws(NetworkError) -> StandalonePathID

    /// Hands the protocol datagrams that arrived on a path.
    func receiveFromBelow(path: StandalonePathID, _ frames: consuming FrameArray)

    /// Collects what the protocol queued to send on a path, in order.
    func takeOutbound(path: StandalonePathID) -> FrameArray

    /// Tells the protocol about a change to a path, such as viability.
    func deliverNetworkEvent(path: StandalonePathID, _ event: NetworkProtocolEvent)

    /// Whether every flow has been torn down.
    var isFullyDetached: Bool { get }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension StandaloneManyToManyProtocol where Self: ~Copyable {
    public func openDatagramFlow() throws(NetworkError) -> StandaloneFlowID {
        throw .posix(ENOTSUP)
    }

    public func getDatagramsToSend(
        flow: StandaloneFlowID,
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        throw .posix(ENOTSUP)
    }

    public func sendDatagrams(flow: StandaloneFlowID, _ datagrams: consuming FrameArray) throws(NetworkError) {
        datagrams.finalizeAllFramesAsFailed()
        throw .posix(ENOTSUP)
    }

    public func receiveDatagrams(
        flow: StandaloneFlowID,
        maximumDatagramCount: Int
    ) throws(NetworkError) -> FrameArray? {
        throw .posix(ENOTSUP)
    }
}

// MARK: - Byte-array conveniences

@available(Network 0.1.0, *)
extension FrameArray {
    /// Copies each frame's bytes out and finalizes the frames as successful.
    fileprivate mutating func standaloneExtractDatagrams() -> [[UInt8]] {
        var datagrams: [[UInt8]] = []
        iterateMutableFrames { frame in
            var buffer = [UInt8]()
            let length = frame.unclaimedLength
            if length > 0 {
                _ = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                    try read.buffer(&buffer, length: length)
                }
            }
            datagrams.append(buffer)
            frame.finalize(success: true)
            return true
        }
        return datagrams
    }

    fileprivate mutating func standaloneExtractStream() -> StandaloneStreamRead {
        var bytes = [UInt8]()
        var isFinal = false
        iterateMutableFrames { frame in
            let length = frame.unclaimedLength
            if length > 0 {
                var chunk = [UInt8]()
                _ = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                    try read.buffer(&chunk, length: length)
                }
                bytes.append(contentsOf: chunk)
            }
            if frame.connectionComplete {
                isFinal = true
            }
            frame.finalize(success: true)
            return true
        }
        return StandaloneStreamRead(bytes: bytes, isFinal: isFinal)
    }

    fileprivate static func standaloneDatagram(_ bytes: [UInt8]) -> FrameArray {
        FrameArray(frame: Frame(copyBuffer: bytes))
    }

    fileprivate static func standaloneStream(_ bytes: [UInt8], sendFIN: Bool) -> FrameArray? {
        var frame = Frame(count: bytes.count)
        let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
            try write.span(bytes.span.bytes)
        }
        guard result.isValid else { return nil }
        if sendFIN {
            frame.metadataComplete = true
            frame.connectionComplete = true
        }
        return FrameArray(frame: frame)
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension StandaloneOneToOneProtocol where Self: ~Copyable {
    /// Hands the protocol one packet that arrived from the network below.
    public func receiveFromBelow(_ bytes: [UInt8]) {
        receiveFromBelow(FrameArray(frame: Frame(copyBuffer: bytes)))
    }

    /// Collects what the protocol queued to send below as byte arrays.
    public func takeOutboundPackets() -> [[UInt8]] {
        var frames = takeOutbound()
        return frames.standaloneExtractDatagrams()
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension StandaloneOneToOneDatagramProtocol where Self: ~Copyable {
    /// Writes one datagram. Returns whether the protocol accepted it.
    @discardableResult
    public func write(_ datagram: [UInt8]) -> Bool {
        do throws(NetworkError) {
            guard var frames = try getDatagramsToSend(maximumDatagramCount: 1, minimumDatagramSize: datagram.count)
            else { return false }
            frames.iterateMutableFrames { frame in
                _ = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.buffer(datagram)
                }
                frame.collapse()
                _ = frame.unclaim(fromStart: datagram.count)
                return false
            }
            try sendDatagrams(frames)
            return true
        } catch {
            return false
        }
    }

    /// Reads one datagram, if one is waiting.
    public func read() -> [UInt8]? {
        do throws(NetworkError) {
            guard var frames = try receiveDatagrams(maximumDatagramCount: 1) else { return nil }
            return frames.standaloneExtractDatagrams().first
        } catch {
            return nil
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension StandaloneOneToOneStreamProtocol where Self: ~Copyable {
    /// Writes bytes to the stream. Returns whether the protocol accepted them.
    @discardableResult
    public func write(_ bytes: [UInt8], sendFIN: Bool = false, early: Bool = false) -> Bool {
        guard let frames = FrameArray.standaloneStream(bytes, sendFIN: sendFIN) else { return false }
        do throws(NetworkError) {
            try sendStreamData(frames, early: early)
            return true
        } catch {
            return false
        }
    }

    /// Reads whatever is waiting, up to `maximumBytes`.
    public func read(upTo maximumBytes: Int = Int.max) -> StandaloneStreamRead? {
        do throws(NetworkError) {
            guard var frames = try receiveStreamData(minimumBytes: 1, maximumBytes: maximumBytes) else { return nil }
            return frames.standaloneExtractStream()
        } catch {
            return nil
        }
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension StandaloneManyToManyProtocol where Self: ~Copyable {
    /// Hands the protocol one datagram that arrived on a path.
    public func receiveFromBelow(path: StandalonePathID, _ datagram: [UInt8]) {
        receiveFromBelow(path: path, FrameArray(frame: Frame(copyBuffer: datagram)))
    }

    /// Collects what the protocol queued to send on a path as byte arrays.
    public func takeOutboundDatagrams(path: StandalonePathID) -> [[UInt8]] {
        var frames = takeOutbound(path: path)
        return frames.standaloneExtractDatagrams()
    }

    @discardableResult
    public func writeStream(
        flow: StandaloneFlowID,
        _ bytes: [UInt8],
        sendFIN: Bool = false,
        early: Bool = false
    )
        -> Bool
    {
        guard let frames = FrameArray.standaloneStream(bytes, sendFIN: sendFIN) else { return false }
        do throws(NetworkError) {
            try sendStreamData(flow: flow, frames, early: early)
            return true
        } catch {
            return false
        }
    }

    public func readStream(flow: StandaloneFlowID, upTo maximumBytes: Int = Int.max) -> StandaloneStreamRead? {
        do throws(NetworkError) {
            guard var frames = try receiveStreamData(flow: flow, minimumBytes: 1, maximumBytes: maximumBytes)
            else { return nil }
            return frames.standaloneExtractStream()
        } catch {
            return nil
        }
    }

    @discardableResult
    public func writeDatagram(flow: StandaloneFlowID, _ datagram: [UInt8]) -> Bool {
        do throws(NetworkError) {
            guard
                var frames = try getDatagramsToSend(
                    flow: flow,
                    maximumDatagramCount: 1,
                    minimumDatagramSize: datagram.count
                )
            else { return false }
            frames.iterateMutableFrames { frame in
                _ = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.buffer(datagram)
                }
                frame.collapse()
                _ = frame.unclaim(fromStart: datagram.count)
                return false
            }
            try sendDatagrams(flow: flow, frames)
            return true
        } catch {
            return false
        }
    }

    public func readDatagram(flow: StandaloneFlowID) -> [UInt8]? {
        do throws(NetworkError) {
            guard var frames = try receiveDatagrams(flow: flow, maximumDatagramCount: 1) else { return nil }
            return frames.standaloneExtractDatagrams().first
        } catch {
            return nil
        }
    }
}

#endif
