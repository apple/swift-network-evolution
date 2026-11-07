import StackCommon

/// The multiplexing layer, written for async/await.
///
/// It is shared by the receive pump, the send pump and every stream's reader and
/// writer, which are separate tasks, so it must be a reference type isolated to the
/// stack's actor rather than a noncopyable value. Waiting for data, for send room,
/// or for work to send is an `await` on a continuation stored here and resumed
/// when the condition arises.
public final class AsyncMux: @unchecked Sendable {
    let streams: UnsafeMutablePointer<StreamCore>
    let readWaiter: UnsafeMutablePointer<UnsafeContinuation<Bool, Never>?>
    let readNeed: UnsafeMutablePointer<Int>
    let writeWaiter: UnsafeMutablePointer<UnsafeContinuation<Bool, Never>?>
    let writeNeed: UnsafeMutablePointer<Int>
    let streamCount: Int
    let window: Int
    let sendCapacity: Int
    var ready = RingQueue<UInt32>()
    var pumpWaiter: UnsafeContinuation<Bool, Never>?
    var closed = false
    public var counters = StackCounters()

    public init(streams count: Int, window: Int, sendBuffer: Int) {
        streamCount = count
        self.window = window
        sendCapacity = sendBuffer
        streams = .allocate(capacity: count)
        readWaiter = .allocate(capacity: count)
        readNeed = .allocate(capacity: count)
        writeWaiter = .allocate(capacity: count)
        writeNeed = .allocate(capacity: count)
        for i in 0..<count {
            (streams + i).initialize(to: StreamCore(window: window))
            readWaiter[i] = nil
            writeWaiter[i] = nil
            readNeed[i] = 0
            writeNeed[i] = 0
        }
    }

    deinit {
        for i in 0..<streamCount { streams[i].deallocate() }
        streams.deallocate()
        readWaiter.deallocate()
        readNeed.deallocate()
        writeWaiter.deallocate()
        writeNeed.deallocate()
        ready.deallocate()
    }

    // MARK: Read side

    /// Waits until at least `bytes` are buffered for `stream`. Returns false if the
    /// stream ended before that many arrived.
    public func waitReadable(_ stream: Int, atLeast bytes: Int) async -> Bool {
        if streams[stream].recvBuf.count >= bytes { return true }
        if streams[stream].finReceived || closed { return false }
        readNeed[stream] = bytes
        counters.wakeups += 1
        return await withUnsafeContinuation { readWaiter[stream] = $0 }
    }

    @inline(__always)
    public func peek(_ stream: Int) -> UnsafeRawBufferPointer { streams[stream].recvBuf.bytes }

    @inline(__always)
    public func consume(_ stream: Int, _ n: Int) {
        if streams[stream].consume(n, window: window) { schedule(stream) }
    }

    // MARK: Write side

    /// Waits until the stream's send buffer has room for `n` more bytes.
    public func waitWritable(_ stream: Int, _ n: Int) async -> Bool {
        if streams[stream].sendBuf.count + n <= sendCapacity { return true }
        if closed { return false }
        writeNeed[stream] = n
        counters.wakeups += 1
        return await withUnsafeContinuation { writeWaiter[stream] = $0 }
    }

    @inline(__always)
    public func reserveWrite(_ stream: Int, _ n: Int) -> UnsafeMutableRawPointer {
        streams[stream].sendBuf.reserve(n)
    }

    @inline(__always)
    public func commitWrite(_ stream: Int, _ n: Int) {
        streams[stream].sendBuf.commit(n)
        schedule(stream)
    }

    public func finish(_ stream: Int) {
        streams[stream].finQueued = true
        schedule(stream)
    }

    @inline(__always)
    func schedule(_ stream: Int) {
        if !streams[stream].queued && streams[stream].isSendable {
            streams[stream].queued = true
            ready.pushBack(UInt32(truncatingIfNeeded: stream))
            if let waiter = pumpWaiter {
                pumpWaiter = nil
                waiter.resume(returning: true)
            }
        }
    }

    // MARK: Network side

    /// Reads packets from the link until it closes.
    public func runReceivePump(link: AsyncLink, side: Side) async {
        while let packet = await link.receive(at: side) {
            receive(packet)
            link.release(packet, receivedAt: side)
        }
    }

    /// Packs streams that are ready to send into packets until the link closes.
    public func runSendPump(link: AsyncLink, side: Side) async {
        while true {
            if ready.isEmpty {
                if closed { return }
                counters.wakeups += 1
                guard await withUnsafeContinuation({ pumpWaiter = $0 }) else { return }
                continue
            }
            guard var packet = await link.allocate(from: side) else { return }
            var writer = PacketWriter(packet)
            fill(&writer)
            if writer.count == 0 {
                link.releaseUnsent(packet, from: side)
                continue
            }
            packet.count = writer.count
            link.send(packet, from: side)
            counters.packetsSent += 1
        }
    }

    func receive(_ packet: Packet) {
        counters.packetsReceived += 1
        var reader = FrameReader(packet)
        while let frame = reader.next() {
            switch frame {
            case .stream(let id, let fin, let data):
                let s = Int(id)
                guard s < streamCount else { counters.flowViolations += 1; continue }
                if !streams[s].receive(data, fin: fin) { counters.flowViolations += 1 }
                if let waiter = readWaiter[s] {
                    let have = streams[s].recvBuf.count
                    if have >= readNeed[s] || fin {
                        readWaiter[s] = nil
                        waiter.resume(returning: have >= readNeed[s])
                    }
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

    /// Fills one packet round-robin from the ready streams.
    func fill(_ writer: inout PacketWriter) {
        while writer.space > Wire.streamFrameHeader, let id = ready.popFront() {
            let s = Int(id)
            if !streams[s].isSendable {
                streams[s].queued = false
                continue
            }
            let hadCredit = streams[s].creditPending
            let frames = streams[s].emit(
                id: id, window: window, quantum: ready.isEmpty ? Int.max : Wire.streamQuantum, into: &writer)
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
            if let waiter = writeWaiter[s], streams[s].sendBuf.count + writeNeed[s] <= sendCapacity {
                writeWaiter[s] = nil
                waiter.resume(returning: true)
            }
            if streams[s].isSendable {
                ready.pushBack(id)
            } else {
                streams[s].queued = false
            }
        }
    }

    /// Wakes everything waiting on the mux so tasks and pumps can exit.
    public func close() {
        closed = true
        if let w = pumpWaiter { pumpWaiter = nil; w.resume(returning: false) }
        for s in 0..<streamCount {
            if let w = readWaiter[s] { readWaiter[s] = nil; w.resume(returning: false) }
            if let w = writeWaiter[s] { writeWaiter[s] = nil; w.resume(returning: false) }
        }
    }
}
