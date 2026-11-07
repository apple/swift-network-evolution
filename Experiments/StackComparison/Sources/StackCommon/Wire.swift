// Wire format shared by both stacks.
//
// Datagram "packets" of at most `Wire.packetSize` bytes travel between the two
// endpoints. The link is reliable and ordered, so there are no packet numbers,
// offsets or acknowledgements; what remains of a QUIC-like multiplexing layer is
// stream multiplexing and per-stream credit-based flow control.
//
//   packet := frame*                       (no packet header)
//
//   STREAM        := 0x01 | id:u32 | len:u16 | data[len]
//   STREAM_FIN    := 0x02 | id:u32 | len:u16 | data[len]     (last data of the stream)
//   MAX_STREAM_DATA := 0x10 | id:u32 | limit:u64             (absolute byte credit)
//
// All integers are big endian. Several frames, from different streams, share a
// packet. On each stream the byte stream is a sequence of TLV messages:
//
//   message := type:u16 | length:u32 | value[length]
//
// A receiver never lets a peer send beyond the limit it last advertised; the
// initial limit is the scenario's receive window.

public enum Wire {
    public static let packetSize = 1200

    public static let streamFrameHeader = 7
    public static let creditFrameSize = 13
    public static let tlvHeader = 6

    @usableFromInline static let typeStream: UInt8 = 0x01
    @usableFromInline static let typeStreamFin: UInt8 = 0x02
    @usableFromInline static let typeMaxStreamData: UInt8 = 0x10
}

@inlinable @inline(__always)
public func loadBE16(_ p: UnsafeRawPointer) -> UInt16 {
    UInt16(bigEndian: p.loadUnaligned(as: UInt16.self))
}

@inlinable @inline(__always)
public func loadBE32(_ p: UnsafeRawPointer) -> UInt32 {
    UInt32(bigEndian: p.loadUnaligned(as: UInt32.self))
}

@inlinable @inline(__always)
public func loadBE64(_ p: UnsafeRawPointer) -> UInt64 {
    UInt64(bigEndian: p.loadUnaligned(as: UInt64.self))
}

@inlinable @inline(__always)
public func storeBE16(_ v: UInt16, _ p: UnsafeMutableRawPointer) {
    p.storeBytes(of: v.bigEndian, as: UInt16.self)
}

@inlinable @inline(__always)
public func storeBE32(_ v: UInt32, _ p: UnsafeMutableRawPointer) {
    p.storeBytes(of: v.bigEndian, as: UInt32.self)
}

@inlinable @inline(__always)
public func storeBE64(_ v: UInt64, _ p: UnsafeMutableRawPointer) {
    p.storeBytes(of: v.bigEndian, as: UInt64.self)
}

public enum Frame {
    case stream(id: UInt32, fin: Bool, data: UnsafeRawBufferPointer)
    case maxStreamData(id: UInt32, limit: UInt64)
}

/// Iterates the frames of a received packet without allocating.
public struct FrameReader {
    @usableFromInline var cursor: UnsafeRawPointer
    @usableFromInline var remaining: Int
    public var malformed = false

    @inlinable @inline(__always)
    public init(_ packet: Packet) {
        cursor = UnsafeRawPointer(packet.base)
        remaining = packet.count
    }

    @inlinable
    public mutating func next() -> Frame? {
        guard remaining > 0 else { return nil }
        let type = cursor.load(as: UInt8.self)
        switch type {
        case Wire.typeStream, Wire.typeStreamFin:
            guard remaining >= Wire.streamFrameHeader else { malformed = true; return nil }
            let id = loadBE32(cursor + 1)
            let length = Int(loadBE16(cursor + 5))
            guard remaining >= Wire.streamFrameHeader + length else { malformed = true; return nil }
            let data = UnsafeRawBufferPointer(start: cursor + Wire.streamFrameHeader, count: length)
            cursor += Wire.streamFrameHeader + length
            remaining -= Wire.streamFrameHeader + length
            return .stream(id: id, fin: type == Wire.typeStreamFin, data: data)
        case Wire.typeMaxStreamData:
            guard remaining >= Wire.creditFrameSize else { malformed = true; return nil }
            let frame = Frame.maxStreamData(id: loadBE32(cursor + 1), limit: loadBE64(cursor + 5))
            cursor += Wire.creditFrameSize
            remaining -= Wire.creditFrameSize
            return frame
        default:
            malformed = true
            return nil
        }
    }
}

/// Appends frames to a packet buffer.
public struct PacketWriter {
    public let base: UnsafeMutableRawPointer
    public var count = 0

    @inlinable @inline(__always)
    public init(_ packet: Packet) {
        base = packet.base
    }

    @inlinable @inline(__always)
    public var space: Int { Wire.packetSize - count }

    /// Writes a STREAM frame header and returns where the `length` data bytes go.
    @inlinable @inline(__always)
    public mutating func appendStream(id: UInt32, fin: Bool, length: Int) -> UnsafeMutableRawPointer {
        let p = base + count
        p.storeBytes(of: fin ? Wire.typeStreamFin : Wire.typeStream, as: UInt8.self)
        storeBE32(id, p + 1)
        storeBE16(UInt16(truncatingIfNeeded: length), p + 5)
        count += Wire.streamFrameHeader + length
        return p + Wire.streamFrameHeader
    }

    @inlinable @inline(__always)
    public mutating func appendMaxStreamData(id: UInt32, limit: UInt64) {
        let p = base + count
        p.storeBytes(of: Wire.typeMaxStreamData, as: UInt8.self)
        storeBE32(id, p + 1)
        storeBE64(limit, p + 5)
        count += Wire.creditFrameSize
    }
}

/// A TLV message as seen by the application: a view into the stream's receive
/// buffer, valid until the stack next receives packets (sync) or the caller
/// next suspends (async).
public struct TLVMessage {
    public var type: UInt16
    public var value: UnsafeRawPointer
    public var length: Int

    @inlinable @inline(__always)
    public init(type: UInt16, value: UnsafeRawPointer, length: Int) {
        self.type = type
        self.value = value
        self.length = length
    }
}

public enum TLV {
    /// Parses one complete message from the front of `bytes`. Returns nil when
    /// `bytes` does not yet hold it, with `needed` set to the total bytes required.
    @inlinable @inline(__always)
    public static func parse(_ bytes: UnsafeRawBufferPointer, needed: inout Int) -> TLVMessage? {
        guard bytes.count >= Wire.tlvHeader else {
            needed = Wire.tlvHeader
            return nil
        }
        let base = bytes.baseAddress!
        let length = Int(loadBE32(base + 2))
        let total = Wire.tlvHeader + length
        guard bytes.count >= total else {
            needed = total
            return nil
        }
        return TLVMessage(type: loadBE16(base), value: base + Wire.tlvHeader, length: length)
    }

    @inlinable @inline(__always)
    public static func writeHeader(_ p: UnsafeMutableRawPointer, type: UInt16, length: Int) {
        storeBE16(type, p)
        storeBE32(UInt32(truncatingIfNeeded: length), p + 2)
    }
}
