import StackCommon

/// The TLV layer over the multiplexer's streams, synchronous. It keeps no
/// per-message state: a message is parsed in place out of the stream's receive
/// buffer once the whole of it has arrived, and written in place into the send
/// buffer. When a read cannot complete it tells the mux how many bytes it needs
/// and returns `.wouldBlock`; an event comes up when they are there.
public struct SyncTLV: ~Copyable {
    public enum ReadResult {
        case message(TLVMessage)
        case wouldBlock
        case end
    }

    public init() {}

    @inline(__always)
    public mutating func read(_ stream: Int, mux: inout SyncMux) -> ReadResult {
        var needed = 0
        if let message = TLV.parse(mux.peek(stream), needed: &needed) {
            mux.consume(stream, Wire.tlvHeader + message.length)
            return .message(message)
        }
        if mux.finReceived(stream) { return .end }
        mux.waitForRead(stream, atLeast: needed)
        return .wouldBlock
    }

    /// Encodes a message directly into the stream's send buffer. Returns false,
    /// with a `writable` event arranged, if there is no room yet.
    @inline(__always)
    public mutating func send(
        _ stream: Int, type: UInt16, length: Int, mux: inout SyncMux,
        fill: (UnsafeMutableRawBufferPointer) -> Void
    ) -> Bool {
        let total = Wire.tlvHeader + length
        guard let dst = mux.reserveWrite(stream, total) else { return false }
        TLV.writeHeader(dst, type: type, length: length)
        fill(UnsafeMutableRawBufferPointer(start: dst + Wire.tlvHeader, count: length))
        mux.commitWrite(stream, total)
        return true
    }

    @inline(__always)
    public mutating func finish(_ stream: Int, mux: inout SyncMux) {
        mux.finish(stream)
    }
}
