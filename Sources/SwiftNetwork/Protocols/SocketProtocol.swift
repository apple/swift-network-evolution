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

// MARK: - SocketDatagramProtocol

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class SocketDatagramProtocol: BottomDatagramProtocol, ProtocolInstanceContainer {

    public private(set) var context: NetworkContext
    public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    public var eventManager = ProtocolEventManager()
    public var upper = InboundDatagramLinkage()
    var log = NetworkLoggerState()

    private var socket: SystemSocket? = nil
    private var dispatchReadSource: (any DispatchSourceRead)? = nil
    private var dispatchWriteSource: (any DispatchSourceWrite)? = nil
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
        dispatchReadSource?.setEventHandler(handler: nil)
        // The cancel handler releases the shared source fd once libdispatch is done.
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

    // Read and write sources share one dup'd fd, closed once both have cancelled.
    // See the note in SocketStreamProtocol for why (Linux epoll fd-keying + EPOLLFREE).
    private var sourceFD: CInt = -1
    private var sourceFDRefCount = 0

    private func makeSharedSourceFDIfNeeded() -> CInt {
        if sourceFD >= 0 { return sourceFD }
        let dupFD = socket?.withFileDescriptor { dup($0) } ?? -1
        guard dupFD >= 0 else {
            log.error("Failed to dup fd for dispatch sources: \(errno)")
            return -1
        }
        sourceFD = dupFD
        return dupFD
    }

    private func releaseSharedSourceFD(_ fd: CInt) {
        sourceFDRefCount -= 1
        if sourceFDRefCount <= 0 {
            close(fd)
            sourceFD = -1
            sourceFDRefCount = 0
        }
    }

    private func setupReadSource() {
        let fd = makeSharedSourceFDIfNeeded()
        guard fd >= 0 else { return }
        sourceFDRefCount += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: context.queue)
        source.setEventHandler {
            self.handleSocketReadEvent()
        }
        source.setCancelHandler {
            self.releaseSharedSourceFD(fd)
        }
        dispatchReadSource = source
        source.resume()
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

    // MARK: - Write source

    // Shares the read source's dup'd fd.
    private func setupWriteSource() {
        let fd = makeSharedSourceFDIfNeeded()
        guard fd >= 0 else { return }
        sourceFDRefCount += 1
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: context.queue)
        source.setEventHandler {
            self.serviceWrites()
            self.triggerOutboundRoomAvailable()
        }
        source.setCancelHandler {
            self.releaseSharedSourceFD(fd)
        }
        dispatchWriteSource = source
        // Starts suspended — only resumed when we get EAGAIN
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
        dispatchWriteSource.setEventHandler(handler: nil)
        // The cancel handler releases the shared source fd once libdispatch is done.
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

// MARK: - SocketStreamProtocol

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class SocketStreamProtocol: BottomStreamProtocol, ProtocolInstanceContainer {

    public private(set) var context: NetworkContext
    public var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }
    public var eventManager = ProtocolEventManager()
    public var upper = InboundStreamLinkage()
    var log = NetworkLoggerState()

    private var socket: SystemSocket? = nil
    #if canImport(Darwin)
    // Socket option constants that the Swift Darwin overlay does not surface.
    // Values match <netinet6/in6.h> and the Darwin xnu socket headers.
    private static let socketOptionIPV6UseMinMTU: CInt = 42  // IPV6_USE_MIN_MTU
    private static let socketOptionIPV6DontFrag: CInt = 62  // IPV6_DONTFRAG
    #endif
    private var dispatchReadSource: (any DispatchSourceRead)? = nil
    private var dispatchWriteSource: (any DispatchSourceWrite)? = nil
    private var waitingForWritable = false
    private var isConnecting = false
    private var inputSourceSuspended = false
    private var inputFinished = false
    private var outputFinished = false
    private var pendingDisconnect = false
    private var incomingFrames = FrameArray()
    private var pendingOutputFrames = FrameArray()
    var localEndpoint: Endpoint?
    var remoteEndpoint: Endpoint?

    private let maximumInputSize = 65536
    private let maximumOutputSize = 65536

    // Cap dynamic input sizing so a flood of pending bytes can't make us
    // allocate an arbitrarily large temporary buffer.
    private static let maximumDynamicInputSize = 256 * 1024

    // TCPMetadata wired up so the upper layer can query and modify socket
    // state via the standard TCP option callbacks.
    private var protocolMetadata: ProtocolMetadata<TCPProtocol>? = nil
    private var socketHandle: UnsafeMutableRawPointer? = nil

    init(context: NetworkContext) {
        self.context = context
    }

    deinit {
        releaseSocketHandle()
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
        let socket = try createSocket(for: address)
        self.socket = socket

        applyDefaultSocketOptions(socket: socket)

        if let stack = parameters?.defaultStack {
            if let ipOptions = stack.internetOptionsAsIPOptions(mutable: false)?.perProtocolOptions {
                applyIPOptions(socket: socket, opts: ipOptions)
            }
            if let tcpOptions = stack.transport?.options as? TCPProtocol.Options {
                applyTCPOptions(socket: socket, opts: tcpOptions)
            }
        }

        setupProtocolMetadata(socket: socket)

        setupReadSource()
        setupWriteSource()
    }

    public func teardown() {
        cancelReadSource()
        cancelWriteSource()
        releaseSocketHandle()
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
            let isIPv6Dst = {
                if case .v6 = address.type { return true }
                return false
            }()
            if let localEndpoint, case .address(let localAddress) = localEndpoint.type,
                !isIPv6Dst || localAddress.addressFamily == .ipv6
            {
                try bindSocket(to: localAddress, port: localEndpoint.port)
            }
            if case .v6 = address.type {
                // connectx(2) on Darwin requires the socket to be bound before
                // connecting an IPv6 socket with no explicit source address.
                try socket.bindSocket(address: IPv6Address.any, port: 0)
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

            // For non-blocking TCP, connectSocket returns false on EINPROGRESS.
            // Wait for the socket to become writable, then treat as connected.
            let connectedNow = try socket.connectSocket(to: ip, port: remoteEndpoint.port)
            if connectedNow {
                deliverConnectedEvent()
                startReadSource()
            } else {
                isConnecting = true
                if !waitingForWritable {
                    waitingForWritable = true
                    dispatchWriteSource?.resume()
                }
            }
        } catch let error {
            log.error("Failed to connect: \(error)")
            deliverDisconnectedEvent(error: .posix(ECONNREFUSED))
        }
    }

    public func disconnect() {
        if pendingOutputFrames.isEmpty {
            shutdownWrites()
            deliverDisconnectedEvent(error: nil)
            return
        }
        pendingDisconnect = true
        serviceWrites()
    }

    // MARK: - BottomStreamProtocol

    public func receiveStreamData(minimumBytes: Int, maximumBytes: Int) throws(NetworkError) -> FrameArray? {
        guard !incomingFrames.isEmpty,
            incomingFrames.unclaimedLength >= minimumBytes || incomingFrames.connectionComplete
        else {
            // We don't have enough buffered to satisfy the consumer yet. If we
            // had suspended on the high-water mark, resume — the consumer needs
            // more than we're currently holding, so reading must continue even
            // past the soft cap. Otherwise a large minimum would deadlock.
            if inputSourceSuspended && !inputFinished {
                inputSourceSuspended = false
                dispatchReadSource?.resume()
            }
            return nil
        }
        let result = incomingFrames.drainArray(maximumByteCount: maximumBytes)
        if inputSourceSuspended, incomingFrames.unclaimedLength < maximumInputSize {
            inputSourceSuspended = false
            dispatchReadSource?.resume()
        }
        return result
    }

    public func getOutboundStreamDataRoomAvailable() throws(NetworkError) -> Int {
        let pending = pendingOutputFrames.unclaimedLength
        if pending >= maximumOutputSize { return 0 }
        return maximumOutputSize - pending
    }

    public func sendStreamData(_ streamData: consuming FrameArray) throws(NetworkError) {
        pendingOutputFrames.add(frames: streamData)
        serviceWrites()
    }

    #if !NETWORK_EMBEDDED
    public var metadata: AbstractProtocolMetadata? { protocolMetadata }
    #endif

    private func createSocket(for address: AddressEndpoint) throws(NetworkError) -> SystemSocket {
        switch address.type {
        case .v4:
            return try SystemSocket(
                protocolFamily: .ipv4,
                sockType: .stream,
                protocolSubType: 0,
                nonBlocking: true
            )
        case .v6:
            return try SystemSocket(
                protocolFamily: .ipv6,
                sockType: .stream,
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

    // Read and write sources share ONE dup'd fd, closed only after both have
    // cancelled (tracked by sourceFDRefCount). Two reasons, both Linux/epoll:
    //  - Two separate dups alias the same socket as distinct epoll registrations,
    //    which drop events (the read source silently stops delivering).
    //  - The socket's own fd must not be registered: cancel() unregisters
    //    asynchronously, so if SystemSocket.deinit closes it first, libdispatch
    //    hits EPOLLFREE and aborts.
    // Darwin doesn't need this but is unaffected. I/O always uses the SystemSocket's
    // own fd; the shared dup only arms the sources.
    private var sourceFD: CInt = -1
    private var sourceFDRefCount = 0

    // Lazily create the single shared dup fd used by both sources, if not already
    // created. Returns -1 on failure.
    private func makeSharedSourceFDIfNeeded() -> CInt {
        if sourceFD >= 0 { return sourceFD }
        let dupFD = socket?.withFileDescriptor { dup($0) } ?? -1
        guard dupFD >= 0 else {
            log.error("Failed to dup fd for dispatch sources: \(errno)")
            return -1
        }
        sourceFD = dupFD
        return dupFD
    }

    // Called from each source's cancel handler; closes the shared fd once the
    // last source has released it (so libdispatch is done with it).
    private func releaseSharedSourceFD(_ fd: CInt) {
        sourceFDRefCount -= 1
        if sourceFDRefCount <= 0 {
            close(fd)
            sourceFD = -1
            sourceFDRefCount = 0
        }
    }

    // Created in setup() but resumed only after connect completes: arming the read
    // source on a still-connecting socket yields a spurious readable edge that, on
    // Linux, leaves it permanently silent. We drain the read side manually at
    // connect-completion, so nothing is missed by waiting.
    private var readSourceStarted = false

    private func setupReadSource() {
        let fd = makeSharedSourceFDIfNeeded()
        guard fd >= 0 else { return }
        sourceFDRefCount += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: context.queue)
        source.setEventHandler {
            self.handleSocketReadEvent()
        }
        source.setCancelHandler {
            self.releaseSharedSourceFD(fd)
        }
        dispatchReadSource = source
        // Starts suspended — resumed by startReadSource() once connect completes.
    }

    // Resume the read source once connect has completed. Idempotent.
    private func startReadSource() {
        guard !readSourceStarted, let dispatchReadSource else { return }
        readSourceStarted = true
        dispatchReadSource.resume()
    }

    private func cancelReadSource() {
        // A source must be resumed before cancelling. It may be suspended either
        // because it was never started (connect never completed) or on backpressure.
        if !readSourceStarted {
            readSourceStarted = true
            dispatchReadSource?.resume()
        } else if inputSourceSuspended {
            dispatchReadSource?.resume()
        }
        inputSourceSuspended = false
        dispatchReadSource?.setEventHandler(handler: nil)
        dispatchReadSource?.cancel()
        dispatchReadSource = nil
    }

    private func handleSocketReadEvent() {
        guard !inputFinished else { return }

        let pending = socket?.availableBytesToRead() ?? 0
        let readSize: Int
        if pending > 0 {
            readSize = min(max(pending, maximumInputSize), Self.maximumDynamicInputSize)
        } else {
            readSize = maximumInputSize
        }

        withUnsafeTemporaryAllocation(byteCount: readSize, alignment: 1) { buffer in
            let readBuffer = buffer.baseAddress!
            var receivedAny = false
            var reachedEOF = false
            var fatalError: NetworkError? = nil

            repeat {
                let result: IOResult<Int>?
                do {
                    result = try socket?.readIOResult(buffer: readBuffer, size: readSize)
                } catch let error as NetworkError {
                    fatalError = error
                    break
                } catch {
                    fatalError = .posix(EIO)
                    break
                }
                guard let result else { break }
                switch result {
                case .processed(let bytesRead):
                    if bytesRead == 0 {
                        // Stream EOF — mark the next frame as connectionComplete.
                        reachedEOF = true
                    } else {
                        let frame = Frame(copyBuffer: UnsafeRawBufferPointer(start: readBuffer, count: bytesRead))
                        incomingFrames.add(frame: frame)
                        receivedAny = true
                    }
                case .wouldBlock:
                    break
                }
                if reachedEOF { break }
                if case .wouldBlock = result { break }
                if incomingFrames.unclaimedLength >= maximumInputSize { break }
            } while true

            if reachedEOF {
                inputFinished = true
                // Tag the last incoming frame (or an empty one) with connectionComplete
                // so the upper protocol sees stream completion.
                var sentinel = Frame(count: 0)
                sentinel.connectionComplete = true
                incomingFrames.add(frame: sentinel)
                receivedAny = true
                // The stream is finished; stop the read source. EOF keeps the
                // descriptor readable, so leaving it armed would spin forever.
                cancelReadSource()
            }

            if let fatalError {
                deliverDisconnectedEvent(error: fatalError)
                return
            }

            if receivedAny {
                fromExternal {
                    upper.deliverInboundDataAvailableEvent(reference)
                }
            }
            // Backpressure on buffered volume: suspend whenever we're over the
            // limit, regardless of whether new frames arrived this call. The
            // read source is level-triggered, so if we exit the loop due to the
            // cap without suspending, it would fire again immediately.
            if !inputFinished,
                !inputSourceSuspended,
                incomingFrames.unclaimedLength >= maximumInputSize
            {
                inputSourceSuspended = true
                dispatchReadSource?.suspend()
            }
        }
    }

    // MARK: - Write source

    // Shares the read source's dup'd fd (see note above).
    private func setupWriteSource() {
        let fd = makeSharedSourceFDIfNeeded()
        guard fd >= 0 else { return }
        sourceFDRefCount += 1
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: context.queue)
        source.setEventHandler {
            self.handleSocketWriteEvent()
        }
        source.setCancelHandler {
            self.releaseSharedSourceFD(fd)
        }
        dispatchWriteSource = source
        // Starts suspended — resumed on EINPROGRESS connect or EAGAIN on write.
    }

    private func handleSocketWriteEvent() {
        if isConnecting {
            isConnecting = false
            if waitingForWritable {
                waitingForWritable = false
                dispatchWriteSource?.suspend()
            }
            let connectError = socket?.getSocketError() ?? 0
            if connectError != 0 {
                log.error("Async connect failed: \(connectError)")
                deliverDisconnectedEvent(error: .posix(connectError))
                return
            }
            deliverConnectedEvent()

            // Connected now — arm the read source (deferred to avoid the spurious
            // pre-connect edge; see startReadSource).
            startReadSource()

            // Try any pending writes that arrived before connect completed.
            serviceWrites()
            triggerOutboundRoomAvailable()
            // Drain the read side once: a readable edge during connect→ready may
            // already have been consumed and won't necessarily re-fire.
            handleSocketReadEvent()
            return
        }
        serviceWrites()
        triggerOutboundRoomAvailable()
    }

    private func triggerOutboundRoomAvailable() {
        fromExternal {
            upper.deliverOutboundRoomAvailableEvent(reference)
        }
    }

    private func cancelWriteSource() {
        guard let dispatchWriteSource else { return }
        if !waitingForWritable {
            dispatchWriteSource.resume()
        }
        dispatchWriteSource.setEventHandler(handler: nil)
        // The cancel handler releases the shared source fd once libdispatch is done.
        dispatchWriteSource.cancel()
        self.dispatchWriteSource = nil
        waitingForWritable = false
    }

    // Drains pendingOutputFrames, includes partial writes (unlike the datagram
    // version). On EAGAIN, resumes the write source to retry when writable.
    // On fatal errors (EPIPE, ECONNRESET, etc.), delivers a disconnected event.
    // When a frame with connectionComplete is fully written, issues SHUT_WR.
    private func serviceWrites() {
        guard !isConnecting else { return }

        var shouldShutdownWrite = false
        var fatalError: NetworkError? = nil
        var remaining = FrameArray()

        while var frame = pendingOutputFrames.popFirst() {
            // Once we've hit backpressure or a fatal error, preserve the remaining
            // frames in order for retry (on EAGAIN) or failure (on a fatal error).
            if fatalError != nil {
                frame.finalize(success: false)
                continue
            }

            var madeProgress = true
            while frame.unclaimedLength > 0 {
                let length = frame.unclaimedLength
                let bytesWritten = writeFrameToSocket(&frame, length: length)
                if bytesWritten == length {
                    break
                }
                if bytesWritten > 0 {
                    // Partial write — claim the bytes that made it out and retry.
                    _ = frame.claim(fromStart: bytesWritten)
                    continue
                }
                if bytesWritten == 0 {
                    // A non-blocking write that would block is surfaced as a
                    // zero-byte result (EWOULDBLOCK is mapped to .wouldBlock(0)).
                    // The frame still has unclaimed bytes (length > 0), so this
                    // is backpressure, not a fatal error — keep the frame and
                    // wait for the next writable event.
                    self.log.datapath("Send buffer full, waiting for writable event")
                    madeProgress = false
                    break
                }
                let err = CInt(-bytesWritten)
                switch err {
                case EAGAIN, EWOULDBLOCK, ENOBUFS:
                    self.log.datapath("Send buffer full, waiting for writable event")
                    madeProgress = false
                case EPIPE:
                    self.log.info("Socket has been closed")
                    fatalError = .posix(EPIPE)
                case ECONNRESET:
                    self.log.info("Connection reset")
                    fatalError = .posix(ECONNRESET)
                default:
                    self.log.datapath("write failed: \(err)")
                    fatalError = .posix(err)
                }
                break
            }

            if fatalError != nil {
                frame.finalize(success: false)
                continue
            }

            if !madeProgress {
                // Keep this frame (and any still-queued frames) for a later attempt.
                remaining.add(frame: frame)
                while let next = pendingOutputFrames.popFirst() {
                    remaining.add(frame: next)
                }
                break
            }

            if frame.connectionComplete {
                shouldShutdownWrite = true
            }
            frame.finalize(success: true)
        }

        pendingOutputFrames = remaining

        if let fatalError {
            if waitingForWritable {
                waitingForWritable = false
                dispatchWriteSource?.suspend()
            }
            deliverDisconnectedEvent(error: fatalError)
            return
        }

        if !pendingOutputFrames.isEmpty {
            if !waitingForWritable {
                waitingForWritable = true
                dispatchWriteSource?.resume()
            }
            return
        }

        if waitingForWritable {
            waitingForWritable = false
            dispatchWriteSource?.suspend()
        }
        if shouldShutdownWrite {
            shutdownWrites()
        }
        if pendingDisconnect {
            pendingDisconnect = false
            shutdownWrites()
            deliverDisconnectedEvent(error: nil)
        }
    }

    // Returns bytes written on success (≥ 0), or -errno on failure (< 0).
    // Using a negative errno avoids relying on the C errno global after Swift
    // error-handling boundaries, which can clobber it.
    private func writeFrameToSocket(_ frame: inout Frame, length: Int) -> Int {
        guard let socket else { return -Int(EINVAL) }
        if length == 0 { return 0 }
        guard let bytes = frame.bytes else { return -Int(EINVAL) }
        var result: Int = 0
        bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else {
                result = -Int(EINVAL)
                return
            }
            do {
                result = try socket.write(buffer: baseAddress, size: length)
            } catch let error as NetworkError {
                switch error.domainSpecificError {
                case .some(let (_, code)):
                    result = -Int(code)
                case .none:
                    result = -Int(EIO)
                }
            } catch {
                result = -Int(EIO)
            }
        }
        return result
    }

    private func shutdownWrites() {
        guard !outputFinished, let socket else { return }
        outputFinished = true
        socket.withFileDescriptor { fd in
            #if canImport(Glibc)
            _ = Glibc.shutdown(fd, CInt(SHUT_WR))
            #else
            _ = shutdown(fd, CInt(SHUT_WR))
            #endif
        }
    }

    // MARK: - Socket option / metadata wiring

    // Defaults applied to every stream socket. SO_RCVLOWAT / SO_SNDLOWAT are
    // dropped to 1 byte so the read/write dispatch sources fire as soon as any
    // data or any send-buffer space is available — the default macOS kernel
    // values are larger and would delay async-connect completion behind the
    // write low-watermark.
    //
    // SO_SNDLOWAT is Darwin-only: on Linux it is read-only (fixed at 1, which is
    // already the value we want), and attempting to set it fails with ENOPROTOOPT.
    private func applyDefaultSocketOptions(socket: SystemSocket) {
        do { try socket.setReceiveLowWatermark(1) } catch { log.info("Failed to set SO_RCVLOWAT: \(error)") }
        #if canImport(Darwin)
        do { try socket.setSendLowWatermark(1) } catch { log.info("Failed to set SO_SNDLOWAT: \(error)") }
        #endif
    }

    private func applyTCPOptions(socket: SystemSocket, opts: TCPProtocol.Options) {
        if opts.noDelay {
            do { try socket.setNoDelay(true) } catch { log.info("Failed to set TCP_NODELAY: \(error)") }
        }
        if opts.enableKeepalive {
            do {
                try socket.setKeepalive(
                    enabled: true,
                    idleTime: opts.keepaliveIdleTime,
                    interval: opts.keepaliveInterval,
                    count: opts.keepaliveCount
                )
            } catch {
                log.info("Failed to enable keepalive: \(error)")
            }
        }
        if opts.maximumSegmentSize > 0 {
            do { try socket.setMaximumSegmentSize(opts.maximumSegmentSize) } catch {
                log.info("Failed to set TCP_MAXSEG: \(error)")
            }
        }
        if opts.reduceBuffering {
            // Match the C++ reduce_buffering behavior: cap unsent bytes at 16 KiB.
            do { try socket.setNotSentLowWatermark(16 * 1024) } catch {
                log.info("Failed to set TCP_NOTSENT_LOWAT: \(error)")
            }
        }
        if opts.resetLocalPort {
            do { try socket.setReusableLocalPort(true) } catch { log.info("Failed to set SO_REUSEPORT: \(error)") }
        }
        #if canImport(Darwin)
        if opts.noPush {
            do { try socket.setNoPush(true) } catch { log.info("Failed to set TCP_NOPUSH: \(error)") }
        }
        if opts.noOptions {
            do { try socket.setNoOptions(true) } catch { log.info("Failed to set TCP_NOOPT: \(error)") }
        }
        if opts.disableAckStretching {
            do { try socket.setSendMoreAcks(true) } catch { log.info("Failed to set TCP_SENDMOREACKS: \(error)") }
        }
        if opts.retransmitFinDrop {
            do { try socket.setRetransmitFinDrop(true) } catch { log.info("Failed to set TCP_RXT_FINDROP: \(error)") }
        }
        #endif
    }

    private func applyIPOptions(socket: SystemSocket, opts: IPProtocol.Options) {
        guard let remoteEndpoint, case .address(let address) = remoteEndpoint.type else {
            return
        }
        let isIPv6: Bool
        switch address.type {
        case .v6: isIPv6 = true
        case .v4: isIPv6 = false
        default: return
        }

        if let hopLimit = opts.hopLimit {
            do {
                if isIPv6 {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IPV6),
                        name: IPV6_UNICAST_HOPS,
                        value: CInt(hopLimit)
                    )
                } else {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IP),
                        name: IP_TTL,
                        value: CInt(hopLimit)
                    )
                }
            } catch {
                log.info("Failed to set hop limit: \(error)")
            }
        }

        if let dscpValue = opts.dscpValue {
            // DSCP occupies the upper 6 bits of the IPv4 ToS / IPv6 Traffic Class byte.
            let tos = CInt(dscpValue) << 2
            do {
                if isIPv6 {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IPV6),
                        name: IPV6_TCLASS,
                        value: tos
                    )
                } else {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IP),
                        name: IP_TOS,
                        value: tos
                    )
                }
            } catch {
                log.info("Failed to set DSCP: \(error)")
            }
        }

        #if canImport(Darwin)
        if isIPv6 && opts.flags.contains(.useMinimumMTU) {
            do {
                try socket.setSocketOption(
                    level: CInt(IPPROTO_IPV6),
                    name: Self.socketOptionIPV6UseMinMTU,
                    value: CInt(1)
                )
            } catch {
                log.info("Failed to set IPV6_USE_MIN_MTU: \(error)")
            }
        }

        if let fragmentationEnabled = opts.fragmentationEnabled {
            let dontFragment: CInt = fragmentationEnabled ? 0 : 1
            do {
                if isIPv6 {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IPV6),
                        name: Self.socketOptionIPV6DontFrag,
                        value: dontFragment
                    )
                } else {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IP),
                        name: IP_DONTFRAG,
                        value: dontFragment
                    )
                }
            } catch {
                log.info("Failed to set DONTFRAG: \(error)")
            }
        }
        #elseif canImport(Glibc) || canImport(Musl)
        if let fragmentationEnabled = opts.fragmentationEnabled {
            let disc: CInt = fragmentationEnabled ? CInt(IP_PMTUDISC_DONT) : CInt(IP_PMTUDISC_DO)
            do {
                if isIPv6 {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IPV6),
                        name: IPV6_MTU_DISCOVER,
                        value: disc
                    )
                } else {
                    try socket.setSocketOption(
                        level: CInt(IPPROTO_IP),
                        name: IP_MTU_DISCOVER,
                        value: disc
                    )
                }
            } catch {
                log.info("Failed to set MTU_DISCOVER: \(error)")
            }
        }
        #endif
    }

    // Wires up TCPMetadata so the upper layer can query buffer sizes and modify
    // socket state through the standard TCP option callbacks. Only callbacks
    // that map to public socket APIs are populated.
    private func setupProtocolMetadata(socket: SystemSocket) {
        let box = SocketHandleBox(socket: socket)
        let handle = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
        socketHandle = handle

        let metadata = TCPProtocol.TCPMetadata()
        metadata.handle = handle
        metadata.callbacks = TCPProtocol.TCPMetadata.TCPOptionCallbacks(
            get_receive_buffer_size: socketGetReceiveBufferSize,
            get_send_buffer_size: socketGetSendBufferSize,
            reset_keepalives: socketResetKeepalives,
            set_no_delay: socketSetNoDelay,
            set_no_push: socketSetNoPush,
            set_no_wake_from_sleep: nil,
            set_max_pacing_rate: socketSetMaxPacingRate
        )
        protocolMetadata = ProtocolMetadata<TCPProtocol>(
            protocolIdentifier: TCPProtocol.identifier,
            perProtocolMetadata: metadata,
            messageIdentifier: SystemUUID()
        )
    }

    private func releaseSocketHandle() {
        if let perMetadata = protocolMetadata?.perProtocolMetadata {
            perMetadata.handle = nil
            perMetadata.callbacks = nil
        }
        protocolMetadata = nil
        if let handle = socketHandle {
            Unmanaged<SocketHandleBox>.fromOpaque(handle).release()
            socketHandle = nil
        }
    }

    static public func instance(context: NetworkContext) -> ProtocolInstanceReference {
        SocketStreamProtocol(context: context).reference
    }
}

// MARK: - SocketHandleBox (private helpers for TCPMetadata callbacks)

// Strong-reference holder bridged through an opaque pointer so the C-convention
// TCPMetadata callbacks can reach back to the SystemSocket. The protocol owns
// the box's lifetime via Unmanaged.passRetained / .release in setup/teardown.
@available(Network 0.1.0, *)
private final class SocketHandleBox {
    let socket: SystemSocket
    init(socket: SystemSocket) { self.socket = socket }
}

@available(Network 0.1.0, *)
private let socketGetReceiveBufferSize: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { handle in
    guard let handle else { return 0 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    return UInt32(max(0, Int(box.socket.getReceiveBufferSize())))
}

@available(Network 0.1.0, *)
private let socketGetSendBufferSize: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { handle in
    guard let handle else { return 0 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    return UInt32(max(0, Int(box.socket.getSendBufferSize())))
}

@available(Network 0.1.0, *)
private let socketResetKeepalives: @convention(c) (UnsafeMutableRawPointer?, Bool, UInt32, UInt32, UInt32) -> Int32 = {
    handle,
    enabled,
    count,
    idleTime,
    interval in
    guard let handle else { return -1 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    do {
        try box.socket.setKeepalive(enabled: enabled, idleTime: idleTime, interval: interval, count: count)
        return 0
    } catch {
        return -1
    }
}

@available(Network 0.1.0, *)
private let socketSetNoDelay: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32 = { handle, enabled in
    guard let handle else { return -1 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    do {
        try box.socket.setNoDelay(enabled)
        return 0
    } catch {
        return -1
    }
}

@available(Network 0.1.0, *)
private let socketSetNoPush: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32 = { handle, enabled in
    guard let handle else { return -1 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    #if canImport(Darwin)
    do {
        try box.socket.setNoPush(enabled)
        return 0
    } catch {
        return -1
    }
    #else
    _ = box
    return -1
    #endif
}

@available(Network 0.1.0, *)
private let socketSetMaxPacingRate: @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32 = { handle, rate in
    guard let handle else { return -1 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    #if canImport(Glibc)
    do {
        try box.socket.setSocketOption(
            level: SOL_SOCKET,
            name: SO_MAX_PACING_RATE,
            value: UInt32(min(rate, UInt64(UInt32.max)))
        )
        return 0
    } catch {
        return -1
    }
    #else
    _ = (box, rate)
    return -1
    #endif
}
#endif
