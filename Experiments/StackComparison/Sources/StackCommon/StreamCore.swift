/// Per-stream multiplexer state and the pure (style-independent) flow-control and
/// framing logic that operates on it. Both stacks use this identically; what
/// differs between them is how they schedule work and wake the layers above and
/// below (events vs. continuations).
public struct StreamCore {
    // Send half
    public var sendBuf = LinearBuffer()
    public var sent: UInt64 = 0
    public var sendLimit: UInt64
    public var finQueued = false
    public var finSent = false
    public var queued = false  // on the mux's ready-to-send list

    // Receive half
    public var recvBuf = LinearBuffer()
    public var received: UInt64 = 0
    public var consumed: UInt64 = 0
    public var advertised: UInt64
    public var finReceived = false
    public var creditPending = false

    public init(window: Int) {
        sendLimit = UInt64(window)
        advertised = UInt64(window)
    }

    public mutating func deallocate() {
        sendBuf.deallocate()
        recvBuf.deallocate()
    }

    // MARK: Sending

    @inlinable @inline(__always)
    public var isSendable: Bool {
        creditPending
            || (sendBuf.count > 0 && sent < sendLimit)
            || (finQueued && !finSent && sendBuf.count == 0)
    }

    /// Writes as much of this stream's pending frames as fit in `writer`, but at
    /// most `quantum` bytes of stream data so that other ready streams get a share
    /// of the packet. Returns the number of frames written.
    @inlinable
    public mutating func emit(
        id: UInt32, window: Int, quantum: Int = Int.max, into writer: inout PacketWriter
    ) -> Int {
        var frames = 0
        if creditPending && writer.space >= Wire.creditFrameSize {
            let limit = consumed &+ UInt64(window)
            writer.appendMaxStreamData(id: id, limit: limit)
            advertised = limit
            creditPending = false
            frames += 1
        }
        let pending = sendBuf.count
        let credit = Int(truncatingIfNeeded: min(sendLimit &- sent, UInt64(Int32.max)))
        let room = writer.space - Wire.streamFrameHeader
        if room >= 0 {
            let n = min(pending, credit, room, quantum)
            let fin = finQueued && !finSent && n == pending
            if n > 0 || fin {
                let dst = writer.appendStream(id: id, fin: fin, length: n)
                if n > 0 {
                    dst.copyMemory(from: sendBuf.bytes.baseAddress!, byteCount: n)
                    sendBuf.consume(n)
                    sent &+= UInt64(n)
                }
                if fin { finSent = true }
                frames += 1
            }
        }
        return frames
    }

    // MARK: Receiving

    /// Appends received stream data. Returns false if the peer violated the
    /// advertised flow-control limit.
    @inlinable
    public mutating func receive(_ data: UnsafeRawBufferPointer, fin: Bool) -> Bool {
        let n = data.count
        var ok = true
        if n > 0 {
            received &+= UInt64(n)
            if received > advertised { ok = false }
            recvBuf.append(data.baseAddress!, count: n)
        }
        if fin { finReceived = true }
        return ok
    }

    /// Records that the application consumed `n` bytes. Returns true if this newly
    /// makes a MAX_STREAM_DATA update due (the stream then needs to be scheduled).
    @inlinable
    public mutating func consume(_ n: Int, window: Int) -> Bool {
        recvBuf.consume(n)
        consumed &+= UInt64(n)
        if !creditPending && (consumed &+ UInt64(window)) &- advertised >= UInt64(window / 2) {
            creditPending = true
            return true
        }
        return false
    }

    @inlinable @inline(__always)
    public var atEnd: Bool { finReceived && recvBuf.count == 0 }
}

/// Counters both stacks keep, so a run can be sanity-checked beyond its result.
public struct StackCounters: Sendable {
    public var packetsSent = 0
    public var packetsReceived = 0
    public var streamFrames = 0
    public var creditFrames = 0
    /// Upward notifications (sync: events delivered) or suspensions (async).
    public var wakeups = 0
    public var flowViolations = 0
    /// Sends that found the socket full and had to wait for a write-ready signal.
    public var linkBlocked = 0

    public init() {}

    public static func + (a: StackCounters, b: StackCounters) -> StackCounters {
        var r = StackCounters()
        r.packetsSent = a.packetsSent + b.packetsSent
        r.packetsReceived = a.packetsReceived + b.packetsReceived
        r.streamFrames = a.streamFrames + b.streamFrames
        r.creditFrames = a.creditFrames + b.creditFrames
        r.wakeups = a.wakeups + b.wakeups
        r.flowViolations = a.flowViolations + b.flowViolations
        r.linkBlocked = a.linkBlocked + b.linkBlocked
        return r
    }
}
