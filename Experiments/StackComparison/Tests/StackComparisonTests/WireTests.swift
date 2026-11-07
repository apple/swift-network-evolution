import Testing

@testable import StackCommon

@Suite struct WireTests {
    @Test func frameRoundTrip() {
        let base = UnsafeMutableRawPointer.allocate(byteCount: Wire.packetSize, alignment: 16)
        defer { base.deallocate() }
        var packet = Packet(base: base)
        var writer = PacketWriter(packet)

        let a = writer.appendStream(id: 7, fin: false, length: 5)
        a.copyMemory(from: [1, 2, 3, 4, 5] as [UInt8], byteCount: 5)
        writer.appendMaxStreamData(id: 9, limit: 0x1_0000_0001)
        _ = writer.appendStream(id: 0xABCD_0001, fin: true, length: 0)
        packet.count = writer.count
        #expect(writer.count == 7 + 5 + 13 + 7)

        var reader = FrameReader(packet)
        guard case .stream(let id1, let fin1, let data1)? = reader.next() else { Issue.record("frame 1"); return }
        #expect(id1 == 7 && !fin1 && Array(data1) == [1, 2, 3, 4, 5])
        guard case .maxStreamData(let id2, let limit)? = reader.next() else { Issue.record("frame 2"); return }
        #expect(id2 == 9 && limit == 0x1_0000_0001)
        guard case .stream(let id3, let fin3, let data3)? = reader.next() else { Issue.record("frame 3"); return }
        #expect(id3 == 0xABCD_0001 && fin3 && data3.isEmpty)
        #expect(reader.next() == nil)
        #expect(!reader.malformed)
    }

    @Test func truncatedFrameIsMalformed() {
        let base = UnsafeMutableRawPointer.allocate(byteCount: Wire.packetSize, alignment: 16)
        defer { base.deallocate() }
        var writer = PacketWriter(Packet(base: base))
        _ = writer.appendStream(id: 1, fin: false, length: 10)
        var reader = FrameReader(Packet(base: base, count: writer.count - 3))
        #expect(reader.next() == nil)
        #expect(reader.malformed)
    }

    @Test func tlvParsing() {
        let base = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { base.deallocate() }
        TLV.writeHeader(base, type: 0x0102, length: 4)
        base.storeBytes(of: 0xDEAD_BEEF, toByteOffset: 6, as: UInt32.self)

        var needed = 0
        let partial = UnsafeRawBufferPointer(start: base, count: 3)
        #expect(TLV.parse(partial, needed: &needed) == nil)
        #expect(needed == Wire.tlvHeader)
        let short = UnsafeRawBufferPointer(start: base, count: 8)
        #expect(TLV.parse(short, needed: &needed) == nil)
        #expect(needed == 10)
        let whole = UnsafeRawBufferPointer(start: base, count: 12)  // extra trailing bytes are fine
        let m = TLV.parse(whole, needed: &needed)
        #expect(m?.type == 0x0102 && m?.length == 4)
    }

    @Test func linearBufferKeepsBytesAcrossCompactionAndGrowth() {
        var buffer = LinearBuffer()
        var expected: [UInt8] = []
        var next: UInt8 = 0
        for round in 0..<2000 {
            let n = 1 + (round * 37) % 700
            let p = buffer.reserve(n)
            for i in 0..<n { p.storeBytes(of: next &+ UInt8(truncatingIfNeeded: i), toByteOffset: i, as: UInt8.self) }
            expected.append(contentsOf: (0..<n).map { next &+ UInt8(truncatingIfNeeded: $0) })
            next &+= UInt8(truncatingIfNeeded: n)
            buffer.commit(n)
            if round % 3 != 0 {
                let take = min(buffer.count, 1 + (round * 53) % 900)
                #expect(Array(buffer.bytes.prefix(take)) == Array(expected.prefix(take)))
                buffer.consume(take)
                expected.removeFirst(take)
            }
        }
        #expect(Array(buffer.bytes) == expected)
        buffer.deallocate()
    }

    @Test func ringQueueOrdering() {
        var q = RingQueue<Int>(minimumCapacity: 2)
        for i in 0..<100 { q.pushBack(i) }
        q.pushFront(-1)
        #expect(q.popFront() == -1)
        for i in 0..<100 { #expect(q.popFront() == i) }
        #expect(q.popFront() == nil)
        q.deallocate()
    }

    @Test func streamCoreHonoursCreditAndFin() {
        var core = StreamCore(window: 100)
        let src = UnsafeMutableRawPointer.allocate(byteCount: 300, alignment: 16)
        defer { src.deallocate() }
        src.initializeMemory(as: UInt8.self, repeating: 9, count: 300)
        core.sendBuf.append(src, count: 250)
        core.finQueued = true

        let base = UnsafeMutableRawPointer.allocate(byteCount: Wire.packetSize, alignment: 16)
        defer { base.deallocate() }
        var writer = PacketWriter(Packet(base: base))
        #expect(core.isSendable)
        _ = core.emit(id: 3, window: 100, into: &writer)
        #expect(core.sent == 100)  // limited by credit, not by data or room
        #expect(!core.isSendable)  // out of credit, FIN must wait for the data
        core.sendLimit = 1000
        #expect(core.isSendable)
        writer = PacketWriter(Packet(base: base))
        _ = core.emit(id: 3, window: 100, into: &writer)
        #expect(core.sent == 250 && core.finSent)
        core.deallocate()
    }
}
