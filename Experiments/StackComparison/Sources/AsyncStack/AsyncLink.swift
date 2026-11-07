import StackCommon

/// The simulated network as seen by the async stack: the same bounded packet
/// channels as the sync stack, but waiting for a packet to arrive or for room to
/// send is an `await` on a continuation that the other side resumes.
@StackActor
public final class AsyncLink {
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

    isolated deinit {
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
