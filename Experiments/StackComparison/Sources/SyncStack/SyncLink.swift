import StackCommon

/// The simulated network as seen by the synchronous stack: two bounded packet
/// channels and non-blocking operations on them. Whoever drives the stack polls
/// it; there is nothing to wait on.
public struct SyncLink: ~Copyable {
    var toB: PacketChannel
    var toA: PacketChannel

    public init(packetsPerDirection: Int) {
        toB = PacketChannel(packets: packetsPerDirection)
        toA = PacketChannel(packets: packetsPerDirection)
    }

    /// A packet buffer to build an outgoing packet in, or nil if the link is full.
    @inline(__always)
    public mutating func allocate(from side: Side) -> Packet? {
        switch side {
        case .a: return toB.allocate()
        case .b: return toA.allocate()
        }
    }

    @inline(__always)
    public mutating func send(_ packet: Packet, from side: Side) {
        switch side {
        case .a: toB.enqueue(packet)
        case .b: toA.enqueue(packet)
        }
    }

    @inline(__always)
    public mutating func receive(at side: Side) -> Packet? {
        switch side {
        case .a: return toA.dequeue()
        case .b: return toB.dequeue()
        }
    }

    /// Returns a received packet's buffer to the sender's pool.
    @inline(__always)
    public mutating func release(_ packet: Packet, receivedAt side: Side) {
        switch side {
        case .a: toA.release(packet)
        case .b: toB.release(packet)
        }
    }

    /// Gives back a buffer that was allocated but not used.
    @inline(__always)
    public mutating func releaseUnsent(_ packet: Packet, from side: Side) {
        switch side {
        case .a: toB.release(packet)
        case .b: toA.release(packet)
        }
    }
}
