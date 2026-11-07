import StackCommon

/// The workload application, written as a per-stream state machine: it runs
/// when told there is something to do, does everything it can, and when it hits a
/// would-block it records why and returns. All of the "where was I" state lives in
/// `StreamProgress`.
public struct SyncApplication: ~Copyable {
    struct StreamProgress {
        var sent = 0
        var received = 0
        var owed = 0  // responses still to send (server, echo)
        var writeBlocked = false
        var finQueued = false
        var ended = false
        var done = false
    }

    let spec: RoleSpec
    let verify: VerifyLevel
    let streamCount: Int
    let progress: UnsafeMutablePointer<StreamProgress>
    var deferred: [Int] = []
    public var counters = AppCounters()
    public private(set) var doneStreams = 0

    public init(spec: RoleSpec, verify: VerifyLevel) {
        self.spec = spec
        self.verify = verify
        streamCount = spec.scenario.streams
        progress = .allocate(capacity: streamCount)
        progress.initialize(repeating: StreamProgress(), count: streamCount)
    }

    deinit { progress.deallocate() }

    public var isFinished: Bool { doneStreams == streamCount }
    public var hasDeferred: Bool { !deferred.isEmpty }

    public mutating func start(tlv: inout SyncTLV, mux: inout SyncMux) {
        for s in 0..<streamCount { pump(s, &tlv, &mux) }
    }

    public mutating func handle(_ event: SyncMux.Event, tlv: inout SyncTLV, mux: inout SyncMux) {
        switch event {
        case .readable(let s):
            pump(s, &tlv, &mux)
        case .writable(let s):
            progress[s].writeBlocked = false
            pump(s, &tlv, &mux)
        }
    }

    /// Resumes streams that stopped reading only because they used up their
    /// per-turn budget.
    public mutating func runDeferred(tlv: inout SyncTLV, mux: inout SyncMux) {
        let streams = deferred
        deferred.removeAll(keepingCapacity: true)
        for s in streams { pump(s, &tlv, &mux) }
    }

    mutating func pump(_ s: Int, _ tlv: inout SyncTLV, _ mux: inout SyncMux) {
        var p = progress[s]
        var budget = spec.scenario.receiveBudget
        let originates = spec.originates
        let outstanding = spec.scenario.outstanding

        loop: while true {
            // Send whatever we can.
            if !p.writeBlocked {
                if spec.responds {
                    while p.owed > 0 {
                        if !sendOne(s, p.sent, &tlv, &mux) { p.writeBlocked = true; break }
                        p.sent += 1
                        p.owed -= 1
                    }
                } else {
                    while p.sent < originates && (!spec.awaitsResponses || p.sent - p.received < outstanding) {
                        if !sendOne(s, p.sent, &tlv, &mux) { p.writeBlocked = true; break }
                        p.sent += 1
                    }
                }
            }
            if !p.finQueued {
                let sendsDone = spec.responds ? (p.ended && p.owed == 0) : p.sent == originates
                if sendsDone {
                    tlv.finish(s, mux: &mux)
                    p.finQueued = true
                }
            }
            // Do not read more requests while a response is stuck waiting for room.
            if p.ended || (spec.responds && p.owed > 0) { break }

            switch tlv.read(s, mux: &mux) {
            case .message(let m):
                let size = spec.expectedSize(stream: s, seq: p.received)
                if !Payload.verify(m, stream: s, seq: p.received, type: spec.expectedType, length: size, level: verify) {
                    counters.verifyFailures += 1
                }
                counters.messagesReceived += 1
                counters.bytesReceived += m.length
                p.received += 1
                if spec.responds { p.owed += 1 }
                budget -= 1
                if budget == 0 {
                    deferred.append(s)
                    break loop
                }
            case .wouldBlock:
                break loop
            case .end:
                p.ended = true
                if p.received != spec.expects { counters.verifyFailures += 1 }
            }
        }

        if !p.done && p.finQueued && p.ended {
            p.done = true
            doneStreams += 1
        }
        progress[s] = p
    }

    @inline(__always)
    mutating func sendOne(_ s: Int, _ seq: Int, _ tlv: inout SyncTLV, _ mux: inout SyncMux) -> Bool {
        let size = spec.sendSize(stream: s, seq: seq)
        let ok = tlv.send(s, type: spec.sendType, length: size, mux: &mux) {
            Payload.fill($0, stream: s, seq: seq)
        }
        if ok {
            counters.messagesSent += 1
            counters.bytesSent += size
        }
        return ok
    }
}
