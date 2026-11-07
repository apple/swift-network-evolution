import Darwin
import Dispatch

/// Which network the endpoints are connected by.
public enum LinkKind: Sendable {
    /// An in-memory packet queue polled by the driver. No signalling, no syscalls.
    case memory
    /// A non-blocking datagram socketpair. Readiness is signalled by dispatch read
    /// and write sources, and a full socket buffer (EAGAIN) is the backpressure.
    case socket
}

/// One end of a non-blocking `AF_UNIX`/`SOCK_DGRAM` socketpair. A datagram socket
/// preserves packet boundaries and order and, unlike UDP loopback, never drops: when
/// the peer's buffer is full `send` fails with EAGAIN, which is what gives the stacks
/// something real to wait on. Only the syscalls live here; waiting is up to the stack.
public struct DatagramPort {
    public let fd: Int32
    let rxBuffer: UnsafeMutableRawPointer
    let txBuffer: UnsafeMutableRawPointer
    var pendingCount = 0
    /// A packet was built and could not be sent yet; no new one may be built until
    /// `retryPending` succeeds.
    public private(set) var hasPending = false
    /// How many sends found the socket full.
    public private(set) var blockedSends = 0

    init(fd: Int32) {
        self.fd = fd
        rxBuffer = .allocate(byteCount: Wire.packetSize, alignment: 16)
        txBuffer = .allocate(byteCount: Wire.packetSize, alignment: 16)
    }

    /// The single buffer outgoing packets are built in.
    public var txPacket: Packet { Packet(base: txBuffer) }

    /// The next datagram, or nil if none is waiting. The packet is only valid until
    /// the next call.
    public mutating func receive() -> Packet? {
        let n = recv(fd, rxBuffer, Wire.packetSize, 0)
        if n >= 0 { return Packet(base: rxBuffer, count: n) }
        precondition(errno == EAGAIN || errno == EWOULDBLOCK, "recv failed: \(errno)")
        return nil
    }

    /// Sends a packet built in `txPacket`. Returns false if the socket was full; the
    /// packet is kept and `hasPending` is set.
    public mutating func send(_ packet: Packet) -> Bool {
        let n = Darwin.send(fd, packet.base, packet.count, 0)
        if n == packet.count { return true }
        precondition(n < 0 && (errno == EAGAIN || errno == ENOBUFS), "send failed: \(errno)")
        pendingCount = packet.count
        hasPending = true
        blockedSends += 1
        return false
    }

    /// Tries again to send the packet that was held back.
    public mutating func retryPending() -> Bool {
        guard hasPending else { return true }
        let n = Darwin.send(fd, txBuffer, pendingCount, 0)
        if n == pendingCount {
            hasPending = false
            return true
        }
        precondition(n < 0 && (errno == EAGAIN || errno == ENOBUFS), "send failed: \(errno)")
        return false
    }

    /// Frees the buffers. The descriptor is closed by `FDWatcher` once its sources
    /// are cancelled.
    public func freeBuffers() {
        rxBuffer.deallocate()
        txBuffer.deallocate()
    }
}

/// A connected pair of ports whose socket buffers hold about `packets` packets.
public func makeDatagramPorts(packets: Int) -> (DatagramPort, DatagramPort) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0, "socketpair failed")
    for fd in fds {
        var size = Int32(packets * (Wire.packetSize + 256))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        precondition(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
    }
    return (DatagramPort(fd: fds[0]), DatagramPort(fd: fds[1]))
}

/// Dispatch read and write sources for one descriptor, with the write source only
/// armed while there is something waiting to be written. Both stacks use this, so the
/// cost of delivering readiness is the same for each.
public final class FDWatcher: @unchecked Sendable {
    let fd: Int32
    let readSource: any DispatchSourceRead
    let writeSource: any DispatchSourceWrite
    var writeArmed = false
    var cancelled = false
    var remaining = 2

    public init(
        fd: Int32, queue: DispatchQueue, onReadable: @escaping () -> Void,
        onWritable: @escaping () -> Void
    ) {
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler(handler: onReadable)
        writeSource.setEventHandler(handler: onWritable)
        readSource.setCancelHandler { self.sourceCancelled() }
        writeSource.setCancelHandler { self.sourceCancelled() }
        readSource.resume()
    }

    private func sourceCancelled() {
        remaining -= 1
        if remaining == 0 { close(fd) }
    }

    /// Ask for a callback when the socket can take more data.
    public func armWrite() {
        if !writeArmed && !cancelled {
            writeArmed = true
            writeSource.resume()
        }
    }

    public func disarmWrite() {
        if writeArmed {
            writeArmed = false
            writeSource.suspend()
        }
    }

    /// Stops both sources; the descriptor is closed when both have finished.
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if !writeArmed { writeSource.resume() }  // a suspended source cannot be cancelled cleanly
        writeArmed = true
        readSource.cancel()
        writeSource.cancel()
    }
}
