import StackCommon

/// The multiplexing layer, synchronous and event-driven.
///
/// Everything is a plain call: the layer above reads and writes with calls that
/// either succeed or report "would block", and the layer below hands packets in with
/// `receive` and takes them out with `flush`. When a would-block condition clears
/// the mux appends an event to `events`; it never calls upward. The owner drains
/// the events at a point of its choosing, which is what guarantees the layers above
/// are never re-entered from underneath.
public struct SyncMux: ~Copyable {
    public enum Event {
        case readable(stream: Int)
        case writable(stream: Int)

        @inline(__always)
        init(raw: UInt32) {
            self = raw & 1 == 0 ? .readable(stream: Int(raw >> 1)) : .writable(stream: Int(raw >> 1))
        }
    }

    let streams: UnsafeMutablePointer<StreamCore>
    /// Bytes the reader needs buffered before it wants a `readable` event; 0 = none wanted.
    let readWait: UnsafeMutablePointer<Int>
    /// Bytes of send room the writer is waiting for; 0 = none wanted.
    let writeWait: UnsafeMutablePointer<Int>
    let streamCount: Int
    let window: Int
    let sendCapacity: Int
    var ready = RingQueue<UInt32>()
    var events = RingQueue<UInt32>()
    public var counters = StackCounters()

    public init(streams count: Int, window: Int, sendBuffer: Int) {
        streamCount = count
        self.window = window
        sendCapacity = sendBuffer
        streams = .allocate(capacity: count)
        readWait = .allocate(capacity: count)
        writeWait = .allocate(capacity: count)
        for i in 0..<count {
            (streams + i).initialize(to: StreamCore(window: window))
            readWait[i] = 1
            writeWait[i] = 0
        }
    }

    deinit {
        for i in 0..<streamCount { streams[i].deallocate() }
        streams.deallocate()
        readWait.deallocate()
        writeWait.deallocate()
        ready.deallocate()
        events.deallocate()
    }

    // MARK: Events up

    @inline(__always)
    public mutating func nextEvent() -> Event? {
        guard let raw = events.popFront() else { return nil }
        counters.wakeups += 1
        return Event(raw: raw)
    }

    @inline(__always)
    public var hasEvents: Bool { !events.isEmpty }

    // MARK: Read side (called by the layer above)

    /// The bytes currently buffered for `stream`, valid until the next `receive`.
    @inline(__always)
    public func peek(_ stream: Int) -> UnsafeRawBufferPointer { streams[stream].recvBuf.bytes }

    @inline(__always)
    public func finReceived(_ stream: Int) -> Bool { streams[stream].finReceived }

    @inline(__always)
    public func atEnd(_ stream: Int) -> Bool { streams[stream].atEnd }

    @inline(__always)
    public mutating func consume(_ stream: Int, _ n: Int) {
        if streams[stream].consume(n, window: window) { schedule(stream) }
    }

    /// Asks for a `readable` event once at least `bytes` are buffered (or the
    /// stream ends).
    @inline(__always)
    public mutating func waitForRead(_ stream: Int, atLeast bytes: Int) {
        readWait[stream] = bytes
    }

    // MARK: Write side

    /// Reserves `n` contiguous bytes in the stream's send buffer, or returns nil
    /// and arranges a `writable` event for when there is room.
    @inline(__always)
    public mutating func reserveWrite(_ stream: Int, _ n: Int) -> UnsafeMutableRawPointer? {
        if streams[stream].sendBuf.count + n > sendCapacity {
            writeWait[stream] = n
            return nil
        }
        return streams[stream].sendBuf.reserve(n)
    }

    @inline(__always)
    public mutating func commitWrite(_ stream: Int, _ n: Int) {
        streams[stream].sendBuf.commit(n)
        schedule(stream)
    }

    public mutating func finish(_ stream: Int) {
        streams[stream].finQueued = true
        schedule(stream)
    }

    @inline(__always)
    mutating func schedule(_ stream: Int) {
        if !streams[stream].queued && streams[stream].isSendable {
            streams[stream].queued = true
            ready.pushBack(UInt32(truncatingIfNeeded: stream))
        }
    }

    // MARK: Network side

    public var hasSendable: Bool { !ready.isEmpty }

    /// Processes one incoming packet.
    public mutating func receive(_ packet: Packet) {
        counters.packetsReceived += 1
        var reader = FrameReader(packet)
        while let frame = reader.next() {
            switch frame {
            case .stream(let id, let fin, let data):
                let s = Int(id)
                guard s < streamCount else { counters.flowViolations += 1; continue }
                if !streams[s].receive(data, fin: fin) { counters.flowViolations += 1 }
                let need = readWait[s]
                if need > 0 && (streams[s].recvBuf.count >= need || fin) {
                    readWait[s] = 0
                    events.pushBack(UInt32(truncatingIfNeeded: s) << 1)
                }
            case .maxStreamData(let id, let limit):
                let s = Int(id)
                guard s < streamCount else { counters.flowViolations += 1; continue }
                if limit > streams[s].sendLimit { streams[s].sendLimit = limit }
                schedule(s)
            }
        }
        if reader.malformed { counters.flowViolations += 1 }
    }

    /// Packs as many packets as the link has room for from the streams that are
    /// ready to send, round-robin. Returns true if any packet was sent.
    public mutating func flush(_ link: inout SyncLink, side: Side) -> Bool {
        var sentAny = false
        while !ready.isEmpty {
            guard var packet = link.allocate(from: side) else { break }
            var writer = PacketWriter(packet)
            while writer.space > Wire.streamFrameHeader, let id = ready.popFront() {
                let s = Int(id)
                if !streams[s].isSendable {
                    streams[s].queued = false
                    continue
                }
                let hadCredit = streams[s].creditPending
                let frames = streams[s].emit(id: id, window: window, into: &writer)
                if frames == 0 {
                    ready.pushFront(id)
                    break
                }
                if hadCredit && !streams[s].creditPending {
                    counters.creditFrames += 1
                    counters.streamFrames += frames - 1
                } else {
                    counters.streamFrames += frames
                }
                let wait = writeWait[s]
                if wait > 0 && streams[s].sendBuf.count + wait <= sendCapacity {
                    writeWait[s] = 0
                    events.pushBack(UInt32(truncatingIfNeeded: s) << 1 | 1)
                }
                if streams[s].isSendable {
                    ready.pushBack(id)
                } else {
                    streams[s].queued = false
                }
            }
            if writer.count == 0 {
                link.releaseUnsent(packet, from: side)
                break
            }
            packet.count = writer.count
            link.send(packet, from: side)
            counters.packetsSent += 1
            sentAny = true
        }
        return sentAny
    }
}
