import Dispatch
import StackCommon

/// What the async stack needs from the network: waiting for a packet to arrive, or
/// for room to build one, is an `await`.
public protocol AsyncLinkProtocol: AnyObject, Sendable {
    func allocate(from side: Side) async -> Packet?
    func send(_ packet: Packet, from side: Side)
    func receive(at side: Side) async -> Packet?
    func release(_ packet: Packet, receivedAt side: Side)
    func releaseUnsent(_ packet: Packet, from side: Side)
    /// Number of times a caller had to suspend on this link.
    var suspensions: Int { get }
    /// Sends that found the network full (socket links only).
    var blockedSends: Int { get }
    func close()
}

/// The simulated network as seen by the async stack: the same bounded packet
/// channels as the sync stack, but waiting for a packet to arrive or for room to
/// send is an `await` on a continuation that the other side resumes.
public final class AsyncLink: AsyncLinkProtocol, @unchecked Sendable {
    public var blockedSends: Int { 0 }
    // Index 0 carries a -> b, index 1 carries b -> a.
    private let channels: UnsafeMutablePointer<PacketChannel>
    private let rxWaiter: UnsafeMutablePointer<UnsafeContinuation<Packet?, Never>?>
    private let allocWaiter: UnsafeMutablePointer<UnsafeContinuation<Packet?, Never>?>
    private var closed = false
    public var suspensions = 0

    public init(packetsPerDirection: Int) {
        channels = .allocate(capacity: 2)
        channels.initialize(to: PacketChannel(packets: packetsPerDirection))
        (channels + 1).initialize(to: PacketChannel(packets: packetsPerDirection))
        rxWaiter = .allocate(capacity: 2)
        rxWaiter.initialize(repeating: nil, count: 2)
        allocWaiter = .allocate(capacity: 2)
        allocWaiter.initialize(repeating: nil, count: 2)
    }

    deinit {
        channels.deinitialize(count: 2)
        channels.deallocate()
        rxWaiter.deallocate()
        allocWaiter.deallocate()
    }

    @inline(__always) private func tx(_ side: Side) -> Int { side == .a ? 0 : 1 }
    @inline(__always) private func rx(_ side: Side) -> Int { side == .a ? 1 : 0 }

    /// A packet buffer to build an outgoing packet in; waits while the link is full.
    public func allocate(from side: Side) async -> Packet? {
        let i = tx(side)
        if let packet = channels[i].allocate() { return packet }
        if closed { return nil }
        suspensions += 1
        return await withUnsafeContinuation { allocWaiter[i] = $0 }
    }

    public func send(_ packet: Packet, from side: Side) {
        let i = tx(side)
        if let waiter = rxWaiter[i] {
            rxWaiter[i] = nil
            waiter.resume(returning: packet)
        } else {
            channels[i].enqueue(packet)
        }
    }

    /// The next incoming packet; waits while none has arrived.
    public func receive(at side: Side) async -> Packet? {
        let i = rx(side)
        if let packet = channels[i].dequeue() { return packet }
        if closed { return nil }
        suspensions += 1
        return await withUnsafeContinuation { rxWaiter[i] = $0 }
    }

    public func release(_ packet: Packet, receivedAt side: Side) {
        giveBack(packet, direction: rx(side))
    }

    public func releaseUnsent(_ packet: Packet, from side: Side) {
        giveBack(packet, direction: tx(side))
    }

    private func giveBack(_ packet: Packet, direction i: Int) {
        if let waiter = allocWaiter[i] {
            allocWaiter[i] = nil
            waiter.resume(returning: packet)
        } else {
            channels[i].release(packet)
        }
    }

    /// Wakes everything waiting on the link with nil so the pumps can exit.
    public func close() {
        closed = true
        for i in 0..<2 {
            if let w = rxWaiter[i] { rxWaiter[i] = nil; w.resume(returning: nil) }
            if let w = allocWaiter[i] { allocWaiter[i] = nil; w.resume(returning: nil) }
        }
    }
}

/// One end of a datagram socketpair for the async stack. Receiving with nothing
/// queued suspends on a continuation that the dispatch read source resumes; building
/// a packet while the last one is still stuck in a full socket suspends on one that
/// the write source resumes. Both sources run on the same serial queue as every task.
public final class AsyncSocketLink: AsyncLinkProtocol, @unchecked Sendable {
    var port: DatagramPort
    var watcher: FDWatcher!
    var readWaiter: UnsafeContinuation<Packet?, Never>?
    var allocWaiter: UnsafeContinuation<Packet?, Never>?
    var closed = false
    public var suspensions = 0
    public var blockedSends: Int { port.blockedSends }

    init(port: DatagramPort, queue: DispatchQueue) {
        self.port = port
        watcher = FDWatcher(
            fd: port.fd, queue: queue, onReadable: { [unowned self] in self.readable() },
            onWritable: { [unowned self] in self.writable() })
    }

    deinit { port.freeBuffers() }

    private func readable() {
        if let waiter = readWaiter, let packet = port.receive() {
            readWaiter = nil
            waiter.resume(returning: packet)
        }
        RunLoop.shared.drain()
    }

    private func writable() {
        if port.retryPending() {
            watcher.disarmWrite()
            if let waiter = allocWaiter {
                allocWaiter = nil
                waiter.resume(returning: port.txPacket)
            }
        }
        RunLoop.shared.drain()
    }

    public func allocate(from side: Side) async -> Packet? {
        if !port.hasPending { return port.txPacket }
        if closed { return nil }
        suspensions += 1
        return await withUnsafeContinuation { allocWaiter = $0 }
    }

    public func send(_ packet: Packet, from side: Side) {
        if !port.send(packet) { watcher.armWrite() }
    }

    public func receive(at side: Side) async -> Packet? {
        if let packet = port.receive() { return packet }
        if closed { return nil }
        suspensions += 1
        return await withUnsafeContinuation { readWaiter = $0 }
    }

    public func release(_ packet: Packet, receivedAt side: Side) {}
    public func releaseUnsent(_ packet: Packet, from side: Side) {}

    public func close() {
        closed = true
        if let w = readWaiter { readWaiter = nil; w.resume(returning: nil) }
        if let w = allocWaiter { allocWaiter = nil; w.resume(returning: nil) }
        watcher.cancel()
    }
}
