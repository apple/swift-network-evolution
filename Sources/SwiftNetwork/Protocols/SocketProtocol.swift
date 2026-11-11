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
#elseif canImport(Android)
import Android
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
public final class SocketDatagramProtocol: BottomDatagramProtocol {
    public typealias UpperProtocol = BaseInboundDatagramLinkage
    public typealias LinkageType = BaseOutboundDatagramLinkage

    public private(set) var context: NetworkContext
    public var identifier: InstanceIdentifier
    public var eventManager = ProtocolEventManager()
    public var upper = UpperProtocol()
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
    // setup fills this from Endpoint.sourceInterfaceIndex(parameters:), and connect passes it to
    // connectx.
    private var sourceInterfaceIndex = 0
    private var isUnixDomain = false

    private var counts = SocketTransferCounts()
    // configuredDSCP is the DSCP from the IP options. lastTypeOfService holds the ECN and DSCP bits
    // that IP_TOS or IPV6_TCLASS last set. A frame that carries no DSCP of its own keeps the
    // configured one, so a protocol that marks only ECN, such as QUIC, doesn't clear it.
    private var configuredDSCP: UInt8 = 0
    private var lastTypeOfService: UInt8 = 0

    // This is the kernel's default maximum datagram size. It sizes both input and output frames,
    // whatever the path MTU, and IP fragments a datagram larger than the MTU. A smaller read buffer
    // truncates the datagram.
    private static let maximumDatagramSize = 9216

    init(context: NetworkContext) {
        self.context = context
        self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
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
        self.sourceInterfaceIndex = remote.sourceInterfaceIndex(parameters: parameters)

        guard case .address(let address) = remote.type else {
            throw NetworkError.posix(EINVAL)
        }
        guard let family = address.addressFamily else {
            throw NetworkError.posix(EAFNOSUPPORT)
        }
        let socket = try SystemSocket(
            protocolFamily: family,
            sockType: .datagram,
            protocolSubType: 0,
            nonBlocking: true
        )
        self.socket = socket
        // Reset what belongs to the previous socket, in case setup runs again.
        isUnixDomain = family == .unix
        configuredDSCP = 0
        lastTypeOfService = 0

        applyDefaultSocketOptions(socket: socket)
        if let parameters {
            applyParameterOptions(socket: socket, parameters: parameters)
        }

        setupReadSource()
        setupWriteSource()
    }

    public func teardown() {
        cancelReadSource()
        cancelWriteSource()
        socket = nil
        incomingFrames.finalizeAllFramesAsFailed()
        pendingOutputFrames.finalizeAllFramesAsFailed()
    }

    public func connect(in eventContext: inout NetworkContext.EventContext) {
        guard let socket, let remoteEndpoint,
            case .address(let address) = remoteEndpoint.type
        else {
            log.error("Cannot connect: no socket or remote endpoint")
            deliverDisconnectedEvent(error: .posix(ENOTCONN), in: &eventContext)
            return
        }

        do {
            // A Unix-domain socket has no local IP address to bind.
            if !isUnixDomain, let localEndpoint, case .address(let localAddress) = localEndpoint.type {
                try socket.bind(to: localAddress, port: localEndpoint.port)
            }
            _ = try socket.connect(to: remoteEndpoint, address: address, sourceInterfaceIndex: sourceInterfaceIndex)
        } catch {
            log.error("Failed to connect: \(error)")
            deliverDisconnectedEvent(error: error, in: &eventContext)
            return
        }

        deliverConnectedEvent(in: &eventContext)
    }

    // MARK: - Socket options

    private func applyDefaultSocketOptions(socket: SystemSocket) {
        #if canImport(Darwin)
        do { try socket.setNoSigPipe(true) } catch { log.info("Failed to set SO_NOSIGPIPE: \(error)") }
        #endif
    }

    // This applies the options from the parameters to a datagram socket. It logs a failure and
    // goes on.
    private func applyParameterOptions(socket: SystemSocket, parameters: Parameters) {
        socket.applySocketOptions(from: parameters, log)

        let stack = parameters.defaultStack
        let ipOptions = stack.internetOptionsAsIPOptions(mutable: false)?.perProtocolOptions
        let isQUIC =
            switch stack.transport {
            case .quic, .quicConnection: true
            default: false
            }
        if let isIPv6 = remoteEndpoint?.isIPv6Address, ipOptions != nil || isQUIC {
            var options = ipOptions ?? IPProtocol.Options()
            if isQUIC {
                // QUIC discovers the path MTU itself, so its datagrams must not be fragmented.
                options.fragmentationEnabled = false
            }
            socket.applyIPOptions(options, isIPv6: isIPv6, log)
            if let dscpValue = options.dscpValue {
                configuredDSCP = dscpValue
                lastTypeOfService = dscpValue << 2
            }
        }

        #if canImport(Darwin)
        if let isIPv6 = remoteEndpoint?.isIPv6Address {
            // Always receive the ECN bits, and receive the hop limit when the IP options ask for
            // it.
            let wantsHopLimit = ipOptions?.receiveHopLimit == true
            var receiveOptions: [(level: CInt, name: CInt, label: String)]
            if isIPv6 {
                receiveOptions = [(CInt(IPPROTO_IPV6), IPV6_RECVTCLASS, "IPV6_RECVTCLASS")]
                if wantsHopLimit {
                    let name = SystemSocket.socketOptionIPV6ReceiveHopLimit
                    receiveOptions.append((CInt(IPPROTO_IPV6), name, "IPV6_RECVHOPLIMIT"))
                }
            } else {
                receiveOptions = [(CInt(IPPROTO_IP), IP_RECVTOS, "IP_RECVTOS")]
                if wantsHopLimit {
                    receiveOptions.append((CInt(IPPROTO_IP), IP_RECVTTL, "IP_RECVTTL"))
                }
            }
            for option in receiveOptions {
                do {
                    try socket.setSocketOption(level: option.level, name: option.name, value: CInt(1))
                } catch {
                    log.info("Failed to set \(option.label): \(error)")
                }
            }
        }

        if case .udp(let options) = stack.transport, let udpOptions = options.perProtocolOptions,
            udpOptions.contains(.preferNoChecksum)
        {
            do {
                try socket.setSocketOption(level: CInt(IPPROTO_UDP), name: UDP_NOCKSUM, value: CInt(1))
            } catch {
                log.info("Failed to set UDP_NOCKSUM: \(error)")
            }
        }
        #endif
    }

    // MARK: - BottomDatagramProtocol

    public func receiveDatagrams(
        maximumDatagramCount: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
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
        minimumDatagramSize: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
        // If prior writes are still pending, return nil to apply backpressure
        guard pendingOutputFrames.isEmpty else { return nil }
        let frameSize = min(minimumDatagramSize, SocketDatagramProtocol.maximumDatagramSize)
        var frameArray = FrameArray(capacity: maximumDatagramCount)
        for _ in 0..<maximumDatagramCount {
            frameArray.add(frame: Frame(count: frameSize))
        }
        return frameArray
    }

    public func sendDatagrams(
        _ datagrams: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        pendingOutputFrames.add(frames: datagrams)
        serviceWrites(in: &eventContext)
    }

    #if !NETWORK_EMBEDDED
    public var metadata: AbstractProtocolMetadata? { nil }
    #endif

    // MARK: - Metrics

    public func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot) {
        counts.fill(&snapshot, includingPackets: true)
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
        let readSize = SocketDatagramProtocol.maximumDatagramSize
        withUnsafeTemporaryAllocation(byteCount: readSize, alignment: 1) { buffer in
            let readBuffer = buffer.baseAddress!
            var receivedAny = false
            var readError: NetworkError? = nil
            repeat {
                guard let socket else { break }
                let result: IOResult<Int>
                let packetInfo: ReceivedPacketInfo
                do throws(NetworkError) {
                    #if canImport(Darwin)
                    (result, packetInfo) = try receiveDatagram(on: socket, into: readBuffer, size: readSize)
                    #else
                    result = try socket.readIOResult(buffer: readBuffer, size: readSize)
                    packetInfo = ReceivedPacketInfo()
                    #endif
                } catch {
                    readError = error
                    break
                }
                guard case .processed(let bytesRead) = result else {
                    break
                }
                var frame = Frame(copyBuffer: UnsafeRawBufferPointer(start: readBuffer, count: bytesRead))
                // Set only the values the kernel reported.
                if let ecn = packetInfo.ecn, ecn != .nonECT {
                    frame.ecnFlag = ecn
                }
                if let hopLimit = packetInfo.hopLimit, hopLimit != 0 {
                    frame.hopLimit = hopLimit
                }
                incomingFrames.add(frame: frame)
                counts.receivedBytes += bytesRead
                counts.receivedDatagrams += 1
                receivedAny = true
            } while true

            if receivedAny {
                inputUnacknowledged = true
                fromExternal { eventContext in
                    upper.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
                }
                // If the upper protocol consumed data synchronously during the
                // notification (via receiveDatagrams clearing inputUnacknowledged),
                // don't suspend. Only suspend if still unacknowledged.
                if inputUnacknowledged && !inputSourceSuspended {
                    inputSourceSuspended = true
                    dispatchReadSource?.suspend()
                }
            }

            if let readError {
                // A connected UDP socket reports an ICMP error, such as ECONNREFUSED after a port
                // unreachable, on its next read. The read consumes the error, so the source doesn't
                // fire again for it. The flow and its input source stay up, because UDP can recover
                // once the peer comes back. Bottom protocols have no event for an error that doesn't
                // disconnect, so this only logs.
                log.error("Datagram read failed: \(readError)")
            }
        }
    }

    private func cancelReadSource() {
        guard let dispatchReadSource else { return }
        // A suspended source must be resumed before it is cancelled.
        if inputSourceSuspended {
            dispatchReadSource.resume()
            inputSourceSuspended = false
        }
        inputUnacknowledged = false
        dispatchReadSource.setEventHandler(handler: nil)
        // The cancel handler releases the shared source fd once libdispatch is done.
        dispatchReadSource.cancel()
        self.dispatchReadSource = nil
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
        fromExternal { eventContext in
            triggerOutboundRoomAvailable(in: &eventContext)
        }
    }

    private func triggerOutboundRoomAvailable(in eventContext: inout NetworkContext.EventContext) {
        upper.deliverOutboundRoomAvailableEvent(from: identifier, in: &eventContext)
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
    // Callers that already hold the event context must use `serviceWrites(in:)`. This variant is
    // for the external entry points -- the write source -- which have no state yet.
    private func serviceWrites() {
        fromExternal { eventContext in
            serviceWrites(in: &eventContext)
        }
    }

    private func serviceWrites(in eventContext: inout NetworkContext.EventContext) {
        var fatalError: NetworkError? = nil
        var remaining = FrameArray()

        while var frame = pendingOutputFrames.popFirst() {
            if fatalError != nil {
                frame.finalize(success: false)
                continue
            }

            let length = frame.unclaimedLength
            switch writeFrameToSocket(&frame) {
            case .written:
                counts.sentBytes += length
                counts.sentDatagrams += 1
                frame.finalize(success: true)
            case .wouldBlock:
                // Keep this datagram and every one after it, in order, for the next writable
                // event.
                self.log.datapath("Send buffer full, waiting for writable event")
                remaining.add(frame: frame)
                while let next = pendingOutputFrames.popFirst() {
                    remaining.add(frame: next)
                }
            case .failed(let error) where error == .posix(EMSGSIZE):
                // The socket can't send a datagram this large, for example one larger than its
                // send buffer. Drop it and keep the flow. The peer never receives it.
                self.log.info("Datagram too large to send, dropping it: \(error)")
                frame.finalize(success: false)
            case .failed(let error):
                self.log.datapath("Datagram write failed: \(error)")
                fatalError = error
                frame.finalize(success: false)
            }
        }

        pendingOutputFrames = remaining

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
        if let fatalError {
            deliverDisconnectedEvent(error: fatalError, in: &eventContext)
        }
    }

    private enum DatagramWriteResult {
        case written
        case wouldBlock
        case failed(NetworkError)
    }

    // A datagram write is atomic, so it sends the whole datagram or nothing.
    private func writeFrameToSocket(_ frame: inout Frame) -> DatagramWriteResult {
        guard let socket else { return .failed(.posix(ENOTCONN)) }
        let length = frame.unclaimedLength
        var send: (UnsafeRawPointer) throws(NetworkError) -> IOResult<Int> = { buffer throws(NetworkError) in
            try socket.writeIOResult(buffer: buffer, size: length)
        }
        #if canImport(Darwin)
        updateTypeOfService(on: socket, for: frame)
        if let serviceType = frame.serviceClass.networkServiceType {
            // A datagram that isn't best effort carries its service type in a control message.
            send = { buffer throws(NetworkError) in
                try self.sendDatagram(on: socket, from: buffer, size: length, serviceType: serviceType)
            }
        }
        #endif

        var result: Result<IOResult<Int>, NetworkError> = .failure(.posix(EINVAL))
        if length == 0 {
            // Writing a zero-length datagram is a valid operation.
            var empty: UInt8 = 0
            result = Result { () throws(NetworkError) in try send(&empty) }
        } else if let bytes = frame.bytes {
            bytes.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress else { return }
                result = Result { () throws(NetworkError) in try send(baseAddress) }
            }
        }

        switch result {
        case .success(.wouldBlock):
            return .wouldBlock
        case .success(.processed(let written)):
            if written == length {
                return .written
            }
            // A short write means something is badly wrong. Report EIO, which fails the flow.
            // EMSGSIZE would make serviceWrites drop the datagram and go on.
            log.error("Datagram write sent \(written) of \(length) bytes")
            return .failed(.posix(EIO))
        case .failure(let error):
            if error == .posix(ENOBUFS) {
                // The interface queue is full. Wait for room, as for EAGAIN.
                return .wouldBlock
            }
            return .failed(error)
        }
    }

    // MARK: - Per-packet metadata

    #if canImport(Darwin)
    // This sets IP_TOS or IPV6_TCLASS to the frame's ECN and DSCP bits when they differ from the
    // bits it last set. It logs a failure, and the next frame tries again.
    private func updateTypeOfService(on socket: SystemSocket, for frame: borrowing Frame) {
        let typeOfService = frame.ecnFlag.rawValue | ((frame.dscpValue ?? configuredDSCP) << 2)
        guard typeOfService != lastTypeOfService, let isIPv6 = remoteEndpoint?.isIPv6Address else { return }
        do {
            try socket.setIPOption(isIPv6: isIPv6, v4: IP_TOS, v6: IPV6_TCLASS, value: CInt(typeOfService))
            lastTypeOfService = typeOfService
        } catch {
            log.info("Failed to set \(isIPv6 ? "IPV6_TCLASS" : "IP_TOS") to \(typeOfService): \(error)")
        }
    }

    private func sendDatagram(
        on socket: SystemSocket,
        from buffer: UnsafeRawPointer,
        size: Int,
        serviceType: CInt
    ) throws(NetworkError) -> IOResult<Int> {
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: buffer), iov_len: size)
        return try ControlMessages.withServiceType(serviceType) { control, controlLength throws(NetworkError) in
            try withUnsafeMutablePointer(to: &iov) { iovPointer throws(NetworkError) in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = controlLength
                return try socket.sendmsgIOResult(msgHdr: &message)
            }
        }
    }

    // Reads one datagram with recvmsg, and reads the ECN bits and hop limit from its control
    // messages.
    private func receiveDatagram(
        on socket: SystemSocket,
        into buffer: UnsafeMutableRawPointer,
        size: Int
    ) throws(NetworkError) -> (IOResult<Int>, ReceivedPacketInfo) {
        var iov = iovec(iov_base: buffer, iov_len: size)
        let controlSize = 128
        return try withUnsafeTemporaryAllocation(byteCount: controlSize, alignment: 8) {
            control throws(NetworkError) -> (IOResult<Int>, ReceivedPacketInfo) in
            try withUnsafeMutablePointer(to: &iov) {
                iovPointer throws(NetworkError) -> (IOResult<Int>, ReceivedPacketInfo) in
                var message = msghdr()
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control.baseAddress
                message.msg_controllen = socklen_t(controlSize)
                let result = try socket.recvmsgIOResult(msgHdr: &message)
                guard case .processed = result else { return (result, ReceivedPacketInfo()) }
                let control = UnsafeRawBufferPointer(start: control.baseAddress, count: Int(message.msg_controllen))
                return (result, ControlMessages.packetInfo(control))
            }
        }
    }
    #endif
}

// MARK: - SocketStreamProtocol

@_spi(Essentials)
@available(Network 0.1.0, *)
public final class SocketStreamProtocol: BottomStreamProtocol {
    public typealias UpperProtocol = BaseInboundStreamLinkage
    public typealias LinkageType = BaseOutboundStreamLinkage

    public private(set) var context: NetworkContext
    public var identifier: InstanceIdentifier
    public var eventManager = ProtocolEventManager()
    public var upper = UpperProtocol()
    var log = NetworkLoggerState()

    private var socket: SystemSocket? = nil
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
    // setup fills this from Endpoint.sourceInterfaceIndex(parameters:), and connect passes it to
    // connectx.
    private var sourceInterfaceIndex = 0
    private var isUnixDomain = false

    // updateDataTransferSnapshot reports these when the kernel's TCP statistics aren't available.
    private var counts = SocketTransferCounts()
    // connectStartTime records when the connect started, and handshakeDuration records how long it
    // took. The establishment report gives that duration as both the handshake duration and the
    // handshake RTT.
    private var connectStartTime: NetworkClock.Instant? = nil
    private var handshakeDuration: NetworkDuration? = nil
    // isConnected stays set until teardown, even after an error.
    private var isConnected = false
    private var isDisconnectRequested = false
    // sendLowWaterMark tracks the socket's SO_SNDLOWAT. See setSendLowWaterMark(_:).
    private var sendLowWaterMark: UInt32 = 1

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
        self.identifier = InstanceIdentifier(context: context, eventManager: &self.eventManager)
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
        self.sourceInterfaceIndex = remote.sourceInterfaceIndex(parameters: parameters)

        guard case .address(let address) = remote.type else {
            throw NetworkError.posix(EINVAL)
        }
        guard let family = address.addressFamily else {
            throw NetworkError.posix(EAFNOSUPPORT)
        }
        let socket = try SystemSocket(
            protocolFamily: family,
            sockType: .stream,
            protocolSubType: 0,
            nonBlocking: true
        )
        self.socket = socket
        isUnixDomain = family == .unix
        sendLowWaterMark = 1

        applyDefaultSocketOptions(socket: socket)
        if let parameters {
            socket.applySocketOptions(from: parameters, log)
        }

        if let stack = parameters?.defaultStack {
            if let ipOptions = stack.internetOptionsAsIPOptions(mutable: false)?.perProtocolOptions,
                let isIPv6 = remote.isIPv6Address
            {
                socket.applyIPOptions(ipOptions, isIPv6: isIPv6, log)
            }
            // A Unix-domain socket skips the TCP options. Setting them would fail on it.
            if !isUnixDomain, case .tcp(let options) = stack.transport, let tcpOptions = options.perProtocolOptions {
                applyTCPOptions(socket: socket, opts: tcpOptions)
            }
        }

        setupProtocolMetadata(socket: socket)

        setupReadSource()
        setupWriteSource()
    }

    public func teardown() {
        if isConnected && !isDisconnectRequested, let socket {
            // Nothing asked for a graceful disconnect, so this is a forced cancel. Linger 0 makes
            // the close discard any unsent data and send an RST.
            do {
                try socket.setSocketOption(level: SOL_SOCKET, name: SO_LINGER, value: linger(l_onoff: 1, l_linger: 0))
            } catch {
                log.info("Failed to set SO_LINGER: \(error)")
            }
        }
        cancelReadSource()
        cancelWriteSource()
        releaseSocketHandle()
        socket = nil
        incomingFrames.finalizeAllFramesAsFailed()
        pendingOutputFrames.finalizeAllFramesAsFailed()
    }

    public func connect(in eventContext: inout NetworkContext.EventContext) {
        guard let socket, let remoteEndpoint,
            case .address(let address) = remoteEndpoint.type
        else {
            log.error("Cannot connect: no socket or remote endpoint")
            deliverDisconnectedEvent(error: .posix(ENOTCONN), in: &eventContext)
            return
        }

        connectStartTime = context.now
        do {
            let isIPv6Dst = address.addressFamily == .ipv6
            if !isUnixDomain, let localEndpoint, case .address(let localAddress) = localEndpoint.type,
                !isIPv6Dst || localAddress.addressFamily == .ipv6
            {
                try socket.bind(to: localAddress, port: localEndpoint.port)
            }
            if case .v6 = address.type {
                // connectx(2) on Darwin requires the socket to be bound before
                // connecting an IPv6 socket with no explicit source address.
                try socket.bindSocket(address: IPv6Address.any, port: 0)
            }

            // A non-blocking connect returns false on EINPROGRESS. Wait for the socket to
            // become writable, then treat it as connected.
            let connectedNow = try socket.connect(
                to: remoteEndpoint,
                address: address,
                sourceInterfaceIndex: sourceInterfaceIndex
            )
            if connectedNow {
                markConnected()
                deliverConnectedEvent(in: &eventContext)
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
            // SystemSocket.bindSocket throws an untyped error, but every error it throws is a
            // NetworkError.
            deliverDisconnectedEvent(error: (error as? NetworkError) ?? .posix(EINVAL), in: &eventContext)
        }
    }

    public func disconnect(in eventContext: inout NetworkContext.EventContext) {
        isDisconnectRequested = true
        if pendingOutputFrames.isEmpty {
            shutdownWrites()
            deliverDisconnectedEvent(error: nil, in: &eventContext)
            return
        }
        pendingDisconnect = true
        serviceWrites(in: &eventContext)
    }

    // MARK: - BottomStreamProtocol

    public func receiveStreamData(
        minimumBytes: Int,
        maximumBytes: Int,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> FrameArray? {
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

    public func getOutboundStreamDataRoomAvailable(
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) -> Int {
        let pending = pendingOutputFrames.unclaimedLength
        if pending >= maximumOutputSize { return 0 }
        return maximumOutputSize - pending
    }

    public func sendStreamData(
        _ streamData: consuming FrameArray,
        in eventContext: inout NetworkContext.EventContext
    ) throws(NetworkError) {
        pendingOutputFrames.add(frames: streamData)
        serviceWrites(in: &eventContext)
    }

    #if !NETWORK_EMBEDDED
    public var metadata: AbstractProtocolMetadata? { protocolMetadata }
    #endif

    // MARK: - Metrics

    private func markConnected() {
        isConnected = true
        if let connectStartTime {
            handshakeDuration = connectStartTime.duration(to: context.now)
        }
    }

    // On Darwin, TCP_CONNECTION_INFO fills the snapshot, because TCP_INFO is private there. It has
    // no minimum RTT, duplicate byte count or ECN packet counts, so those stay at zero. On Linux
    // and Android, TCP_INFO fills it. When the call fails, the snapshot has the byte counts this
    // protocol keeps.
    public func updateDataTransferSnapshot(_ snapshot: inout DataTransferSnapshot) {
        #if canImport(Darwin)
        if let socket, !isUnixDomain {
            do {
                let info = try socket.getSocketOption(
                    level: CInt(IPPROTO_TCP),
                    name: TCP_CONNECTION_INFO,
                    defaultValue: tcp_connection_info()
                )
                snapshot.receivedTransportByteCount = info.tcpi_rxbytes
                snapshot.sentTransportByteCount = info.tcpi_txbytes
                snapshot.receivedTransportOutOfOrderByteCount = info.tcpi_rxoutoforderbytes
                snapshot.sentTransportRetransmittedByteCount = info.tcpi_txretransmitbytes
                snapshot.receivedIPPacketCount = info.tcpi_rxpackets
                snapshot.sentIPPacketCount = info.tcpi_txpackets
                snapshot.transportSmoothedRTT = .milliseconds(info.tcpi_srtt)
                snapshot.transportCurrentRTT = .milliseconds(info.tcpi_rttcur)
                snapshot.transportRTTVariance = .milliseconds(info.tcpi_rttvar)
                snapshot.transportCongestionWindow = UInt64(info.tcpi_snd_cwnd)
                snapshot.transportSlowStartThreshold = UInt64(info.tcpi_snd_ssthresh)
                return
            } catch {
                log.info("Failed to get TCP_CONNECTION_INFO: \(error)")
            }
        }
        #endif
        counts.fill(&snapshot, includingPackets: false)
        #if os(Linux) || os(Android)
        if let socket, !isUnixDomain {
            do {
                try LinuxTCPInfo(socket: socket).fill(&snapshot)
            } catch {
                log.info("Failed to get TCP_INFO: \(error)")
            }
        }
        #endif
    }

    // The time the connect took stands in for both the handshake duration and the handshake RTT.
    // TCP_CONNECTION_INFO has no accurate ECN states, so this report leaves them unset.
    public var protocolEstablishmentReport: ProtocolEstablishmentReport? {
        guard let handshakeDuration else { return nil }
        return ProtocolEstablishmentReport(
            handshakeDuration: handshakeDuration,
            handshakeRTT: handshakeDuration,
            protocolIdentifier: TCPProtocol.identifier
        )
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
            readSize = min(max(pending, maximumInputSize), SocketStreamProtocol.maximumDynamicInputSize)
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
                        counts.receivedBytes += bytesRead
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
                // A read error finishes the input and stops the read source. A reset socket stays
                // readable and returns EOF next, which would deliver input after the disconnect.
                inputFinished = true
                cancelReadSource()
                deliverDisconnectedEvent(error: fatalError)
                return
            }

            if receivedAny {
                fromExternal { eventContext in
                    upper.deliverInboundDataAvailableEvent(from: identifier, in: &eventContext)
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

    // A stalled write raises SO_SNDLOWAT to the bytes still to send, so the writable event waits
    // until they fit. The mark is capped at a third of SO_SNDBUF, so the event can still fire. The
    // next full write lowers it to 1. SO_SNDLOWAT can only be set on Darwin, so elsewhere this does
    // nothing.
    private func setSendLowWaterMark(_ lowWater: UInt32) {
        #if canImport(Darwin)
        guard let socket else { return }
        var mark = max(lowWater, 1)
        guard mark != sendLowWaterMark else { return }
        if mark > sendLowWaterMark {
            do {
                let sendBufferSize = try socket.getSocketOption(
                    level: SOL_SOCKET,
                    name: SO_SNDBUF,
                    defaultValue: CInt(0)
                )
                if sendBufferSize > 0 {
                    mark = min(mark, max(UInt32(sendBufferSize) / 3, 1))
                }
            } catch {
                log.info("Failed to get SO_SNDBUF: \(error)")
            }
        }
        do {
            try socket.setSocketOption(level: SOL_SOCKET, name: SO_SNDLOWAT, value: CInt(clamping: mark))
            sendLowWaterMark = mark
        } catch {
            log.info("Failed to set SO_SNDLOWAT to \(mark): \(error)")
        }
        #endif
    }

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
            markConnected()
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
        fromExternal { eventContext in
            triggerOutboundRoomAvailable(in: &eventContext)
        }
    }

    private func triggerOutboundRoomAvailable(in eventContext: inout NetworkContext.EventContext) {
        upper.deliverOutboundRoomAvailableEvent(from: identifier, in: &eventContext)
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
    // Callers that already hold the event context must use `serviceWrites(in:)`. This variant is
    // for the external entry points -- the write source -- which have no state yet.
    private func serviceWrites() {
        fromExternal { eventContext in
            serviceWrites(in: &eventContext)
        }
    }

    private func serviceWrites(in eventContext: inout NetworkContext.EventContext) {
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
                if bytesWritten > 0 {
                    counts.sentBytes += bytesWritten
                }
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
                // Wait until the socket has room for the rest of this frame.
                setSendLowWaterMark(UInt32(clamping: frame.unclaimedLength))
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
            // The frame went out in full, so lower the mark if a stall raised it.
            setSendLowWaterMark(1)
            frame.finalize(success: true)
        }

        pendingOutputFrames = remaining

        if let fatalError {
            if waitingForWritable {
                waitingForWritable = false
                dispatchWriteSource?.suspend()
            }
            deliverDisconnectedEvent(error: fatalError, in: &eventContext)
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
            deliverDisconnectedEvent(error: nil, in: &eventContext)
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
    //
    // SO_NOSIGPIPE makes a write to a closed peer fail with EPIPE instead of raising
    // SIGPIPE, which terminates the process by default.
    private func applyDefaultSocketOptions(socket: SystemSocket) {
        do { try socket.setReceiveLowWatermark(1) } catch { log.info("Failed to set SO_RCVLOWAT: \(error)") }
        #if canImport(Darwin)
        do { try socket.setSendLowWatermark(1) } catch { log.info("Failed to set SO_SNDLOWAT: \(error)") }
        do { try socket.setNoSigPipe(true) } catch { log.info("Failed to set SO_NOSIGPIPE: \(error)") }
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
        #if NETWORK_PRIVATE
        socket.applyPrivateTCPOptions(from: opts, log)
        #endif
        // Zero means the option isn't set, so the kernel default applies.
        let timeouts: [(name: CInt, label: String, seconds: UInt32)] = [
            (TCP_CONNECTIONTIMEOUT, "TCP_CONNECTIONTIMEOUT", opts.connectionTimeout),
            (TCP_RXT_CONNDROPTIME, "TCP_RXT_CONNDROPTIME", opts.retransmitConnectionDropTime),
            (PERSIST_TIMEOUT, "PERSIST_TIMEOUT", opts.persistTimeout),
        ]
        for timeout in timeouts where timeout.seconds != 0 {
            do {
                try socket.setSocketOption(
                    level: CInt(IPPROTO_TCP),
                    name: timeout.name,
                    value: CInt(clamping: timeout.seconds)
                )
            } catch {
                log.info("Failed to set \(timeout.label): \(error)")
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
            get_receive_buffer_size: socketGetUnreadByteCount,
            get_send_buffer_size: socketGetUnsentByteCount,
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
}

// MARK: - Per-packet metadata

/// ReceivedPacketInfo holds what the kernel reported about one received datagram in its control
/// messages.
@available(Network 0.1.0, *)
struct ReceivedPacketInfo {
    var ecn: IPProtocol.ECN?
    var hopLimit: UInt8?
}

#if canImport(Darwin)
@available(Network 0.1.0, *)
extension Parameters.ServiceClass {
    /// This is the SO_NET_SERVICE_TYPE value to send for the class. It's nil for best effort,
    /// which needs no control message.
    var networkServiceType: CInt? {
        switch self {
        case .bestEffort: return nil
        case .background: return NET_SERVICE_TYPE_BK
        case .interactiveVideo: return NET_SERVICE_TYPE_VI
        case .interactiveVoice: return NET_SERVICE_TYPE_VO
        case .responsiveData: return NET_SERVICE_TYPE_RD
        case .signaling: return NET_SERVICE_TYPE_SIG
        }
    }
}

/// ControlMessages builds and reads Darwin control messages. Swift can't use the CMSG_* macros, so
/// this follows their layout: each header and its data start on a 4-byte boundary
/// (__DARWIN_ALIGN32).
@available(Network 0.1.0, *)
enum ControlMessages {
    private static func aligned(_ length: Int) -> Int { (length + 3) & ~3 }
    private static let headerLength = aligned(MemoryLayout<cmsghdr>.size)

    /// Calls `body` with one SOL_SOCKET/SO_NET_SERVICE_TYPE control message.
    static func withServiceType<R, E: Error>(
        _ serviceType: CInt,
        _ body: (UnsafeMutableRawPointer, socklen_t) throws(E) -> R
    ) throws(E) -> R {
        let dataLength = MemoryLayout<CInt>.size
        let space = headerLength + aligned(dataLength)
        return try withUnsafeTemporaryAllocation(byteCount: space, alignment: 8) { buffer throws(E) -> R in
            let base = buffer.baseAddress!
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            var header = cmsghdr()
            header.cmsg_len = socklen_t(headerLength + dataLength)
            header.cmsg_level = SOL_SOCKET
            header.cmsg_type = SO_NET_SERVICE_TYPE
            base.storeBytes(of: header, as: cmsghdr.self)
            base.storeBytes(of: serviceType, toByteOffset: headerLength, as: CInt.self)
            return try body(base, socklen_t(space))
        }
    }

    /// Reads the ECN bits and hop limit from the control messages recvmsg returned. It reads every
    /// message, so a hop limit that follows the traffic class isn't lost. It keeps only the two ECN
    /// bits of the traffic class.
    static func packetInfo(_ control: UnsafeRawBufferPointer) -> ReceivedPacketInfo {
        var info = ReceivedPacketInfo()
        guard let base = control.baseAddress else { return info }
        var offset = 0
        while offset + MemoryLayout<cmsghdr>.size <= control.count {
            let header = base.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerLength, offset + length <= control.count else { break }
            let dataOffset = offset + headerLength
            let dataLength = length - headerLength
            // IP_RECVTOS and IP_RECVTTL carry one byte. IPV6_TCLASS and IPV6_HOPLIMIT carry an int.
            func value() -> Int? {
                switch dataLength {
                case MemoryLayout<UInt8>.size:
                    return Int(base.load(fromByteOffset: dataOffset, as: UInt8.self))
                case MemoryLayout<CInt>.size:
                    return Int(base.loadUnaligned(fromByteOffset: dataOffset, as: CInt.self))
                default:
                    return nil
                }
            }
            switch (header.cmsg_level, header.cmsg_type) {
            case (CInt(IPPROTO_IP), IP_RECVTOS), (CInt(IPPROTO_IPV6), IPV6_TCLASS):
                if let typeOfService = value() { info.ecn = IPProtocol.ECN(rawValue: UInt8(typeOfService & 0x3)) }
            case (CInt(IPPROTO_IP), IP_RECVTTL), (CInt(IPPROTO_IPV6), SystemSocket.socketOptionIPV6HopLimit):
                if let hopLimit = value() { info.hopLimit = UInt8(truncatingIfNeeded: hopLimit) }
            default:
                break
            }
            offset += aligned(length)
        }
        return info
    }
}
#endif

#if os(Linux) || os(Android)
// MARK: - Linux TCP statistics

/// LinuxTCPInfo reads the kernel's struct tcp_info. The C libraries declare different subsets of
/// it, so this reads the fields at their offsets in the kernel's layout, which only grows. It
/// reads a field only when the kernel returned that much of the struct.
@available(Network 0.1.0, *)
struct LinuxTCPInfo {
    // TCP_INFO from the kernel's linux/tcp.h. It's 11 in every Linux and Android ABI.
    private static let option: CInt = 11
    // This is larger than any kernel's struct so far. The kernel copies no more than the struct.
    private static let capacity = 512

    private let bytes: [UInt8]

    init(socket: SystemSocket) throws(NetworkError) {
        var buffer = [UInt8](repeating: 0, count: Self.capacity)
        var length = socklen_t(Self.capacity)
        let result = socket.withFileDescriptor { descriptor in
            buffer.withUnsafeMutableBytes {
                getsockopt(descriptor, CInt(IPPROTO_TCP), Self.option, $0.baseAddress, &length)
            }
        }
        if result != 0 {
            throw NetworkError.posix(errno)
        }
        bytes = Array(buffer.prefix(Int(length)))
    }

    private func value<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T? {
        guard offset + MemoryLayout<T>.size <= bytes.count else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    /// Fills the snapshot with the fields the kernel reported. Linux gives RTTs in microseconds,
    /// and the congestion window and slow-start threshold in segments.
    func fill(_ snapshot: inout DataTransferSnapshot) {
        let segmentSize = UInt64(value(at: 16, as: UInt32.self) ?? 0)
        if let rtt = value(at: 68, as: UInt32.self) {
            snapshot.transportSmoothedRTT = .microseconds(rtt)
        }
        if let rttVariance = value(at: 72, as: UInt32.self) {
            snapshot.transportRTTVariance = .microseconds(rttVariance)
        }
        // The threshold is TCP_INFINITE_SSTHRESH until the first loss, and that has no size.
        if let threshold = value(at: 76, as: UInt32.self), threshold < 0x7fff_ffff {
            snapshot.transportSlowStartThreshold = UInt64(threshold) * segmentSize
        }
        if let window = value(at: 80, as: UInt32.self) {
            snapshot.transportCongestionWindow = UInt64(window) * segmentSize
        }
        if let received = value(at: 128, as: UInt64.self) {
            snapshot.receivedTransportByteCount = received
        }
        if let segmentsOut = value(at: 136, as: UInt32.self), let segmentsIn = value(at: 140, as: UInt32.self) {
            snapshot.sentIPPacketCount = UInt64(segmentsOut)
            snapshot.receivedIPPacketCount = UInt64(segmentsIn)
        }
        // The kernel reports UINT32_MAX until it has an RTT sample.
        if let minimumRTT = value(at: 148, as: UInt32.self), minimumRTT != .max {
            snapshot.transportMinimumRTT = .microseconds(minimumRTT)
        }
        if let sent = value(at: 200, as: UInt64.self) {
            snapshot.sentTransportByteCount = sent
        }
        if let retransmitted = value(at: 208, as: UInt64.self) {
            snapshot.sentTransportRetransmittedByteCount = retransmitted
        }
    }
}
#endif

// MARK: - Transfer counts

/// SocketTransferCounts counts what a socket protocol sends and receives, for the data transfer
/// snapshot.
@available(Network 0.1.0, *)
struct SocketTransferCounts {
    var receivedBytes = 0
    var sentBytes = 0
    var receivedDatagrams = 0
    var sentDatagrams = 0

    /// Fills the snapshot's byte counts, and its packet counts when the socket counts datagrams.
    func fill(_ snapshot: inout DataTransferSnapshot, includingPackets: Bool) {
        snapshot.receivedTransportByteCount = UInt64(receivedBytes)
        snapshot.sentTransportByteCount = UInt64(sentBytes)
        if includingPackets {
            snapshot.receivedIPPacketCount = UInt64(receivedDatagrams)
            snapshot.sentIPPacketCount = UInt64(sentDatagrams)
        }
    }
}

// MARK: - Connect addressing

@available(Network 0.1.0, *)
extension Endpoint {
    /// Returns the source interface to pass to connectx, or 0 for any interface. It's the required
    /// interface, or else this endpoint's interface.
    fileprivate func sourceInterfaceIndex(parameters: Parameters?) -> Int {
        if let interface = parameters?.requiredInterface ?? self.interface {
            return interface.index
        }
        return 0
    }

    /// This is the IPv6 scope ID for the endpoint's address. It's the index of the endpoint's
    /// interface when the address is link-local or interface-local, and 0 otherwise. Without it, a
    /// link-local destination is unreachable.
    fileprivate var socketScopeID: UInt32 {
        guard case .address(let address) = self.type, case .v6(let v6Address, _) = address.type,
            v6Address.isScopeEmbedded, let interface = self.interface
        else { return 0 }
        return UInt32(clamping: interface.index)
    }

    /// This is true for an IPv6 address, false for an IPv4 address, and nil for any other endpoint.
    fileprivate var isIPv6Address: Bool? {
        guard case .address(let address) = self.type else { return nil }
        switch address.type {
        case .v6: return true
        case .v4: return false
        default: return nil
        }
    }
}

// MARK: - Socket helpers shared by both protocols

/// SocketOption describes one integer socket option to set. The label names the option in the
/// log.
typealias SocketOption = (level: CInt, name: CInt, value: CInt, label: String)

@available(Network 0.1.0, *)
extension SystemSocket {
    #if canImport(Darwin)
    // The Swift Darwin overlay doesn't surface these options. Their values match <netinet6/in6.h>
    // and the xnu socket headers.
    fileprivate static let socketOptionIPV6UseMinMTU: CInt = 42  // IPV6_USE_MIN_MTU
    fileprivate static let socketOptionIPV6DontFrag: CInt = 62  // IPV6_DONTFRAG
    // <netinet6/in6.h> defines these two only with __APPLE_USE_RFC_3542.
    fileprivate static let socketOptionIPV6ReceiveHopLimit: CInt = 37  // IPV6_RECVHOPLIMIT
    fileprivate static let socketOptionIPV6HopLimit: CInt = 47  // IPV6_HOPLIMIT (IPV6_3542HOPLIMIT)
    #endif

    /// Connects to `address`, which belongs to `remote`. Returns false when the connect is still
    /// in progress.
    fileprivate func connect(
        to remote: Endpoint,
        address: AddressEndpoint,
        sourceInterfaceIndex: Int
    ) throws(NetworkError) -> Bool {
        switch address.type {
        case .v4(let ip, _):
            return try connectSocket(to: ip, port: remote.port, interfaceIndex: sourceInterfaceIndex, scopeID: 0)
        case .v6(let ip, _):
            return try connectSocket(
                to: ip,
                port: remote.port,
                interfaceIndex: sourceInterfaceIndex,
                scopeID: remote.socketScopeID
            )
        case .unix(let path):
            return try connectSocket(toPath: path)
        default:
            throw NetworkError.posix(EAFNOSUPPORT)
        }
    }

    /// Binds to a local IP address and port. Any other kind of address is left unbound.
    fileprivate func bind(to address: AddressEndpoint, port: UInt16) throws(NetworkError) {
        do {
            switch address.type {
            case .v4(let ip, _):
                try bindSocket(address: ip, port: port)
            case .v6(let ip, _):
                try bindSocket(address: ip, port: port)
            default:
                break
            }
        } catch {
            // Report what bind returned, such as EADDRINUSE.
            throw (error as? NetworkError) ?? .posix(EADDRNOTAVAIL)
        }
    }

    /// Sets the socket-level options from the parameters, and logs each one it couldn't set.
    fileprivate func applySocketOptions(from parameters: Parameters, _ log: borrowing NetworkLoggerState) {
        var options: [SocketOption] = []
        if parameters.reuseLocalAddress {
            options.append((SOL_SOCKET, SO_REUSEADDR, 1, "SO_REUSEADDR"))
            options.append((SOL_SOCKET, SO_REUSEPORT, 1, "SO_REUSEPORT"))
        }
        apply(options, log)
        #if NETWORK_PRIVATE
        // SocketProtocol_C.swift supplies this helper on the internal side of the mirror.
        applyPrivateSocketOptions(from: parameters, log)
        #endif
    }

    /// Sets each option, and logs each one it couldn't set.
    func apply(_ options: [SocketOption], _ log: borrowing NetworkLoggerState) {
        for option in options {
            do {
                try setSocketOption(level: option.level, name: option.name, value: option.value)
            } catch {
                log.info("Failed to set \(option.label): \(error)")
            }
        }
    }

    /// Sets an IP-level option to `value`, at the IPv6 level with `v6` or the IPv4 level with
    /// `v4`.
    fileprivate func setIPOption(isIPv6: Bool, v4: CInt, v6: CInt, value: CInt) throws(NetworkError) {
        try setSocketOption(level: CInt(isIPv6 ? IPPROTO_IPV6 : IPPROTO_IP), name: isIPv6 ? v6 : v4, value: value)
    }

    /// Applies the IP options to the socket, and logs each option it couldn't set.
    fileprivate func applyIPOptions(_ opts: IPProtocol.Options, isIPv6: Bool, _ log: borrowing NetworkLoggerState) {
        if let hopLimit = opts.hopLimit {
            do {
                try setIPOption(isIPv6: isIPv6, v4: IP_TTL, v6: IPV6_UNICAST_HOPS, value: CInt(hopLimit))
            } catch {
                log.info("Failed to set hop limit: \(error)")
            }
        }

        if let dscpValue = opts.dscpValue {
            // DSCP occupies the upper 6 bits of the IPv4 ToS / IPv6 Traffic Class byte.
            do {
                try setIPOption(isIPv6: isIPv6, v4: IP_TOS, v6: IPV6_TCLASS, value: CInt(dscpValue) << 2)
            } catch {
                log.info("Failed to set DSCP: \(error)")
            }
        }

        #if canImport(Darwin)
        if isIPv6 && opts.flags.contains(.useMinimumMTU) {
            do {
                try setSocketOption(
                    level: CInt(IPPROTO_IPV6),
                    name: SystemSocket.socketOptionIPV6UseMinMTU,
                    value: CInt(1)
                )
            } catch {
                log.info("Failed to set IPV6_USE_MIN_MTU: \(error)")
            }
        }

        if let fragmentationEnabled = opts.fragmentationEnabled {
            do {
                try setIPOption(
                    isIPv6: isIPv6,
                    v4: IP_DONTFRAG,
                    v6: SystemSocket.socketOptionIPV6DontFrag,
                    value: fragmentationEnabled ? 0 : 1
                )
            } catch {
                log.info("Failed to set DONTFRAG: \(error)")
            }
        }
        #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
        if let fragmentationEnabled = opts.fragmentationEnabled {
            let discovery = CInt(fragmentationEnabled ? IP_PMTUDISC_DONT : IP_PMTUDISC_DO)
            do {
                try setIPOption(isIPv6: isIPv6, v4: IP_MTU_DISCOVER, v6: IPV6_MTU_DISCOVER, value: discovery)
            } catch {
                log.info("Failed to set MTU_DISCOVER: \(error)")
            }
        }
        #endif
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

// These report the bytes waiting to be read (SO_NREAD) and the bytes still in the send buffer
// (SO_NWRITE). Linux has neither option, so there they report the buffer sizes. This protocol
// reads data as soon as it arrives, into incomingFrames, so SO_NREAD leaves out the bytes it
// holds. The callbacks run off the context queue and can't read incomingFrames safely.
@available(Network 0.1.0, *)
private let socketGetUnreadByteCount: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { handle in
    guard let handle else { return 0 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    #if canImport(Darwin)
    return (try? box.socket.getSocketOption(level: SOL_SOCKET, name: SO_NREAD, defaultValue: UInt32(0))) ?? 0
    #else
    return UInt32(max(0, Int(box.socket.getReceiveBufferSize())))
    #endif
}

@available(Network 0.1.0, *)
private let socketGetUnsentByteCount: @convention(c) (UnsafeMutableRawPointer?) -> UInt32 = { handle in
    guard let handle else { return 0 }
    let box = Unmanaged<SocketHandleBox>.fromOpaque(handle).takeUnretainedValue()
    #if canImport(Darwin)
    return (try? box.socket.getSocketOption(level: SOL_SOCKET, name: SO_NWRITE, defaultValue: UInt32(0))) ?? 0
    #else
    return UInt32(max(0, Int(box.socket.getSendBufferSize())))
    #endif
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
