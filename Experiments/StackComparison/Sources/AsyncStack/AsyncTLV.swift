import StackCommon

/// The TLV protocol for one stream, over the multiplexer. Each stream's
/// application task owns one; it is a noncopyable value, but the state it
/// manipulates (the stream's buffers) lives in the shared `AsyncMux`.
@StackActor
public struct AsyncTLV: ~Copyable {
    let mux: AsyncMux
    let stream: Int

    public init(mux: AsyncMux, stream: Int) {
        self.mux = mux
        self.stream = stream
    }

    /// The next message, or nil when the stream has ended. The message points
    /// into the stream's receive buffer and is only valid until the caller next
    /// suspends.
    public mutating func receive() async -> TLVMessage? {
        var needed = 0
        while true {
            if let message = TLV.parse(mux.peek(stream), needed: &needed) {
                mux.consume(stream, Wire.tlvHeader + message.length)
                return message
            }
            if !(await mux.waitReadable(stream, atLeast: needed)) { return nil }
        }
    }

    /// Encodes a message directly into the stream's send buffer, waiting for room.
    /// Returns false if the connection closed first.
    public mutating func send(
        type: UInt16, length: Int, fill: (UnsafeMutableRawBufferPointer) -> Void
    ) async -> Bool {
        let total = Wire.tlvHeader + length
        guard await mux.waitWritable(stream, total) else { return false }
        let dst = mux.reserveWrite(stream, total)
        TLV.writeHeader(dst, type: type, length: length)
        fill(UnsafeMutableRawBufferPointer(start: dst + Wire.tlvHeader, count: length))
        mux.commitWrite(stream, total)
        return true
    }

    public mutating func finish() {
        mux.finish(stream)
    }
}
