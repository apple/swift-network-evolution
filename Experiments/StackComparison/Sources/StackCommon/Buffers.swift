import Darwin

/// A byte buffer with a contiguous readable region, used for both stream send
/// and receive buffers. Consumed bytes are dropped from the front; the region is
/// compacted (or grown) only when the tail runs out of room, which amortises to
/// O(1) per byte. Storage is freed explicitly with `deallocate()` so that arrays of
/// streams can hold it by value.
public struct LinearBuffer {
    @usableFromInline var storage: UnsafeMutableRawPointer?
    @usableFromInline var capacity = 0
    @usableFromInline var head = 0
    @usableFromInline var tail = 0

    public init() {}

    @inlinable @inline(__always)
    public var count: Int { tail - head }

    @inlinable @inline(__always)
    public var bytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: storage.map { UnsafeRawPointer($0 + head) }, count: tail - head)
    }

    @inlinable @inline(__always)
    public mutating func consume(_ n: Int) {
        head += n
        if head == tail { head = 0; tail = 0 }
    }

    /// Returns a pointer to `n` writable contiguous bytes at the tail. Call
    /// `commit` with the number actually written.
    @inlinable @inline(__always)
    public mutating func reserve(_ n: Int) -> UnsafeMutableRawPointer {
        if capacity - tail < n { makeRoom(n) }
        return storage! + tail
    }

    @inlinable @inline(__always)
    public mutating func commit(_ n: Int) { tail += n }

    @inlinable @inline(__always)
    public mutating func append(_ p: UnsafeRawPointer, count n: Int) {
        let dst = reserve(n)
        dst.copyMemory(from: p, byteCount: n)
        tail += n
    }

    @usableFromInline @inline(never)
    mutating func makeRoom(_ n: Int) {
        let live = tail - head
        if let storage, head >= capacity / 2, live + n <= capacity {
            // At least half the buffer is dead space at the front: slide down.
            (storage).copyMemory(from: storage + head, byteCount: live)
            head = 0
            tail = live
            return
        }
        var newCapacity = max(capacity * 2, 256)
        while newCapacity < live + n { newCapacity *= 2 }
        let new = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
        if let storage {
            new.copyMemory(from: storage + head, byteCount: live)
            storage.deallocate()
        }
        storage = new
        capacity = newCapacity
        head = 0
        tail = live
    }

    public mutating func deallocate() {
        storage?.deallocate()
        storage = nil
        capacity = 0
        head = 0
        tail = 0
    }
}

/// A growable FIFO of trivial values. Supports pushing at the front so a stream
/// that could not fit in a packet keeps its place in line.
public struct RingQueue<Element> {
    @usableFromInline var storage: UnsafeMutablePointer<Element>
    @usableFromInline var mask: Int
    @usableFromInline var head = 0
    public var count = 0

    public init(minimumCapacity: Int = 64) {
        var c = 16
        while c < minimumCapacity { c *= 2 }
        storage = .allocate(capacity: c)
        mask = c - 1
    }

    @inlinable @inline(__always)
    public var isEmpty: Bool { count == 0 }

    @inlinable @inline(__always)
    public mutating func pushBack(_ e: Element) {
        if count == mask + 1 { grow() }
        (storage + ((head + count) & mask)).initialize(to: e)
        count += 1
    }

    @inlinable @inline(__always)
    public mutating func pushFront(_ e: Element) {
        if count == mask + 1 { grow() }
        head = (head - 1) & mask
        (storage + head).initialize(to: e)
        count += 1
    }

    @inlinable @inline(__always)
    public mutating func popFront() -> Element? {
        if count == 0 { return nil }
        let e = (storage + head).move()
        head = (head + 1) & mask
        count -= 1
        return e
    }

    @usableFromInline @inline(never)
    mutating func grow() {
        let old = mask + 1
        let new = UnsafeMutablePointer<Element>.allocate(capacity: old * 2)
        for i in 0..<count { (new + i).moveInitialize(from: storage + ((head + i) & mask), count: 1) }
        storage.deallocate()
        storage = new
        mask = old * 2 - 1
        head = 0
    }

    /// Frees the storage. Elements must be trivial.
    public func deallocate() { storage.deallocate() }
}

/// A fixed-size datagram buffer. A packet is a handle onto slab memory owned by
/// a `PacketChannel`; it is allocated from, and released back to, that channel.
public struct Packet {
    public var base: UnsafeMutableRawPointer
    public var count: Int

    @inlinable @inline(__always)
    public init(base: UnsafeMutableRawPointer, count: Int = 0) {
        self.base = base
        self.count = count
    }
}

/// One direction of the simulated network: a pool of packet buffers and the
/// FIFO of those currently in flight. The pool size is the link's capacity - when
/// it is exhausted the sender is flow controlled by the network.
public struct PacketChannel: ~Copyable {
    @usableFromInline let slab: UnsafeMutableRawPointer
    @usableFromInline var free: UnsafeMutablePointer<UnsafeMutableRawPointer>
    @usableFromInline var freeCount: Int
    @usableFromInline var inFlight: RingQueue<Packet>

    public init(packets: Int) {
        slab = .allocate(byteCount: packets * Wire.packetSize, alignment: 64)
        free = .allocate(capacity: packets)
        for i in 0..<packets { free[i] = slab + i * Wire.packetSize }
        freeCount = packets
        inFlight = RingQueue(minimumCapacity: packets)
    }

    deinit {
        slab.deallocate()
        free.deallocate()
        inFlight.deallocate()
    }

    @inlinable @inline(__always)
    public var hasFree: Bool { freeCount > 0 }

    @inlinable @inline(__always)
    public var hasPackets: Bool { !inFlight.isEmpty }

    @inlinable @inline(__always)
    public mutating func allocate() -> Packet? {
        if freeCount == 0 { return nil }
        freeCount -= 1
        return Packet(base: free[freeCount])
    }

    @inlinable @inline(__always)
    public mutating func enqueue(_ p: Packet) { inFlight.pushBack(p) }

    @inlinable @inline(__always)
    public mutating func dequeue() -> Packet? { inFlight.popFront() }

    @inlinable @inline(__always)
    public mutating func release(_ p: Packet) {
        free[freeCount] = p.base
        freeCount += 1
    }
}

/// Which end of the simulated link an endpoint is attached to.
public enum Side: Sendable {
    case a, b
}

// A packet is a handle onto slab memory; ownership is handed between the layers
// by convention (allocate -> send -> receive -> release), which the async stack
// has to assert to the compiler because the handle crosses continuations.
extension Packet: @unchecked Sendable {}
