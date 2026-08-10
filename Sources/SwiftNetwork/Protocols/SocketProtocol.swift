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

#if canImport(Dispatch)
import Dispatch

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class SocketDatagramProtocol: BottomDatagramProtocol, ProtocolInstanceContainer {

    public private(set) var context: NetworkContext
    public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    public var eventManager = ProtocolEventManager()
    public var upper = InboundDatagramLinkage()
    var log = NetworkLoggerState()

    private var socket: SystemSocket? = nil
    private var dispatchReadSource: NetworkQueueSource? = nil
    private var dispatchWriteSource: NetworkQueueSource? = nil
    private var waitingForWritable = false
    private var inputUnacknowledged = false
    private var inputSourceSuspended = false
    private var incomingFrames = FrameArray()
    private var pendingOutputFrames = FrameArray()
    var localEndpoint: Endpoint?
    var remoteEndpoint: Endpoint?
    private(set) var maximumOutputSize = 1500

    init(context: NetworkContext) {
        self.context = context
    }

    deinit {
        socket = nil
        incomingFrames.finalizeAllFramesAsFailed()
        pendingOutputFrames.finalizeAllFramesAsFailed()
    }

    public func setup(
        remote: Endpoint?,
        local: Endpoint?,
        parameters: Parameters?,
        path: PathProperties?
    ) throws(NetworkError) {
        guard let remote else {
            throw NetworkError.posix(EINVAL)
        }

        self.localEndpoint = local
        self.remoteEndpoint = remote

        guard case .address(let address) = remote.type else {
            throw NetworkError.posix(EINVAL)
        }
        socket = try createSocket(for: address)

        // Use the path MTU if available
        if let path, path.maximumPacketSize > 0 {
            maximumOutputSize = path.maximumPacketSize
        }

        setupReadSource()
        setupWriteSource()
    }

    public func teardown() {
        // Resume suspended sources before cancelling
        if inputSourceSuspended {
            dispatchReadSource?.resume()
            inputSourceSuspended = false
        }
        inputUnacknowledged = false
        dispatchReadSource?.cancel()
        dispatchReadSource = nil
        cancelWriteSource()
        socket = nil
        incomingFrames.finalizeAllFramesAsFailed()
        pendingOutputFrames.finalizeAllFramesAsFailed()
    }

    public func connect() {
        guard let socket, let remoteEndpoint,
            case .address(let address) = remoteEndpoint.type
        else {
            log.error("Cannot connect: no socket or remote endpoint")
            deliverDisconnectedEvent(error: .posix(ENOTCONN))
            return
        }

        do {
            // Bind to local address and port before connecting
            if let localEndpoint, case .address(let localAddress) = localEndpoint.type {
                try bindSocket(to: localAddress, port: localEndpoint.port)
            }

            let ip: any IPAddress
            switch address.type {
            case .v4(let addr, _): ip = addr
            case .v6(let addr, _): ip = addr
            default:
                log.error("Unsupported address family for connect")
                deliverDisconnectedEvent(error: .posix(EAFNOSUPPORT))
                return
            }

            _ = try socket.connectSocket(to: ip, port: remoteEndpoint.port)
        } catch {
            log.error("Failed to connect: \(error)")
            deliverDisconnectedEvent(error: .posix(ECONNREFUSED))
            return
        }

        deliverConnectedEvent()
    }

    // MARK: - BottomDatagramProtocol

    public func receiveDatagrams(maximumDatagramCount: Int) throws(NetworkError) -> FrameArray? {
        let result = incomingFrames.drainArray(maximumFrameCount: maximumDatagramCount)
        inputUnacknowledged = false
        if inputSourceSuspended {
            inputSourceSuspended = false
            dispatchReadSource?.resume()
        }
        return result
    }

    public func getDatagramsToSend(
        maximumDatagramCount: Int,
        minimumDatagramSize: Int
    ) throws(NetworkError) -> FrameArray? {
        // If prior writes are still pending, return nil to apply backpressure
        guard pendingOutputFrames.isEmpty else { return nil }
        let frameSize = min(minimumDatagramSize, maximumOutputSize)
        var frameArray = FrameArray(capacity: maximumDatagramCount)
        for _ in 0..<maximumDatagramCount {
            frameArray.add(frame: Frame(count: frameSize))
        }
        return frameArray
    }

    public func sendDatagrams(_ datagrams: consuming FrameArray) throws(NetworkError) {
        pendingOutputFrames.add(frames: datagrams)
        serviceWrites()
    }

    #if !NETWORK_EMBEDDED
    public var metadata: AbstractProtocolMetadata? { nil }
    #endif

    // MARK: - Private helpers

    private func createSocket(for address: AddressEndpoint) throws(NetworkError) -> SystemSocket {
        switch address.type {
        case .v4:
            return try SystemSocket(
                protocolFamily: .ipv4,
                sockType: .datagram,
                protocolSubType: 0,
                nonBlocking: true
            )
        case .v6:
            return try SystemSocket(
                protocolFamily: .ipv6,
                sockType: .datagram,
                protocolSubType: 0,
                nonBlocking: true
            )
        default:
            throw NetworkError.posix(EAFNOSUPPORT)
        }
    }

    private func bindSocket(to address: AddressEndpoint, port: UInt16) throws(NetworkError) {
        do {
            switch address.type {
            case .v4(let ip, _):
                try socket?.bindSocket(address: ip, port: port)
            case .v6(let ip, _):
                try socket?.bindSocket(address: ip, port: port)
            default:
                break
            }
        } catch {
            throw NetworkError.posix(EADDRNOTAVAIL)
        }
    }

    // MARK: - Read source

    private func setupReadSource() {
        socket?.withFileDescriptor { fileDescriptor in
            dispatchReadSource = context.queue.createSource(.read, fileDescriptor: fileDescriptor) {
                self.handleSocketReadEvent()
            }
            dispatchReadSource?.resume()
        }
    }

    private func handleSocketReadEvent() {
        withUnsafeTemporaryAllocation(byteCount: maximumOutputSize, alignment: 1) { buffer in
            let readBuffer = buffer.baseAddress!
            var receivedAny = false
            repeat {
                guard let result = try? socket?.readIOResult(buffer: readBuffer, size: maximumOutputSize) else {
                    break
                }
                guard case .processed(let bytesRead) = result else {
                    break
                }
                let frame = Frame(copyBuffer: UnsafeRawBufferPointer(start: readBuffer, count: bytesRead))
                incomingFrames.add(frame: frame)
                receivedAny = true
            } while true

            if receivedAny {
                inputUnacknowledged = true
                fromExternal {
                    upper.deliverInboundDataAvailableEvent(reference)
                }
                // If the upper protocol consumed data synchronously during the
                // notification (via receiveDatagrams clearing inputUnacknowledged),
                // don't suspend. Only suspend if still unacknowledged.
                if inputUnacknowledged && !inputSourceSuspended {
                    inputSourceSuspended = true
                    dispatchReadSource?.suspend()
                }
            }
        }
    }

    //
    // - sendDatagrams queues frames into pendingOutputFrames and calls serviceWrites
    // - serviceWrites drains the queue synchronously via sendmsg/write
    // - On EAGAIN: stop draining, resume the write source to wait for writable
    // - When the write source fires: call serviceWrites again to retry
    // - When all writes succeed: suspend the write source, notify upper protocol

    private func setupWriteSource() {
        socket?.withFileDescriptor { fileDescriptor -> Void in
            dispatchWriteSource = context.queue.createSource(.write, fileDescriptor: fileDescriptor) {
                self.serviceWrites()
                self.triggerOutboundRoomAvailable()
            }
            // Starts suspended — only resumed when we get EAGAIN
        }
    }

    private func triggerOutboundRoomAvailable() {
        // Notify upper protocol that output room is available
        fromExternal {
            upper.deliverOutboundRoomAvailableEvent(reference)
        }
    }

    private func cancelWriteSource() {
        guard let dispatchWriteSource else { return }
        if !waitingForWritable {
            // DispatchSource must be resumed before cancel
            dispatchWriteSource.resume()
        }
        dispatchWriteSource.cancel()
        self.dispatchWriteSource = nil
        waitingForWritable = false
    }

    // Drains pendingOutputFrames synchronously. On EAGAIN/ENOBUFS,
    // stops draining, resumes the write source to retry when writable.
    // On fatal errors (EPIPE, etc.), delivers a disconnected event.
    private func serviceWrites() {
        var needsWriteSource = false
        var fatalError: NetworkError? = nil

        pendingOutputFrames.iterateMutableFrames { frame in
            let length = frame.unclaimedLength

            let bytesWritten = writeFrameToSocket(&frame, length: length)

            if bytesWritten == length {
                frame.finalize(success: true)
                return true
            }

            // Datagram writes are atomic — partial writes can't happen.
            // Any failure (bytesWritten < 0 or != length) is an error.
            let err = bytesWritten < 0 ? errno : EIO
            switch err {
            case EAGAIN, EWOULDBLOCK, ENOBUFS:
                self.log.datapath("Send buffer full, waiting for writable event")
                needsWriteSource = true
            case EPIPE:
                self.log.info("Socket has been closed")
                fatalError = .posix(EPIPE)
            default:
                self.log.datapath("sendmsg failed: \(err)")
                fatalError = .posix(err)
            }
            frame.finalize(success: false)
            return false
        }

        if needsWriteSource {
            if !waitingForWritable {
                waitingForWritable = true
                dispatchWriteSource?.resume()
            }
        } else {
            pendingOutputFrames = FrameArray()
            if waitingForWritable {
                waitingForWritable = false
                dispatchWriteSource?.suspend()
            }
            if let fatalError {
                deliverDisconnectedEvent(error: fatalError)
            }
        }
    }

    private func writeFrameToSocket(_ frame: inout Frame, length: Int) -> Int {
        guard let socket else { return -1 }
        // Writing a zero-length datagram is a valid operation.
        if length == 0 {
            var empty: UInt8 = 0
            return (try? socket.write(buffer: &empty, size: 0)) ?? -1
        }
        guard let bytes = frame.bytes else { return -1 }
        var result: Int = -1
        bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            result = (try? socket.write(buffer: baseAddress, size: length)) ?? -1
        }
        return result
    }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        SocketDatagramProtocol(context: context).reference
    }
}
#endif  // canImport(Dispatch)
