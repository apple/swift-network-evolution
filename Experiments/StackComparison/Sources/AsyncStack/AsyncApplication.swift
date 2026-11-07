import StackCommon

/// Signals that every application task on both endpoints has finished.
final class Completion: @unchecked Sendable {
    private var remaining: Int
    private var waiter: UnsafeContinuation<Void, Never>?
    private(set) var endTime: UInt64 = 0
    private(set) var endCPU = CPUCost.zero

    init(tasks: Int) { remaining = tasks }

    func taskFinished() {
        remaining -= 1
        if remaining == 0 {
            endTime = monotonicNanoseconds()
            endCPU = CPUCost.now()
            if let w = waiter {
                waiter = nil
                w.resume()
            }
        }
    }

    func wait() async {
        if remaining == 0 { return }
        await withUnsafeContinuation { waiter = $0 }
    }
}

/// The workload application, written as straight-line async code: one task per
/// stream (two for bidirectional), each of which just reads and writes and lets
/// `await` deal with waiting. There is no per-stream state to save and restore;
/// the task's own frame holds it.
public final class AsyncApplication: @unchecked Sendable {
    let spec: RoleSpec
    let verify: VerifyLevel
    let mux: AsyncMux
    let completion: Completion
    public var counters = AppCounters()

    init(spec: RoleSpec, verify: VerifyLevel, mux: AsyncMux, completion: Completion) {
        self.spec = spec
        self.verify = verify
        self.mux = mux
        self.completion = completion
    }

    static func tasksPerStream(_ spec: RoleSpec) -> Int { spec.needsSeparateReader ? 2 : 1 }

    func start() {
        for s in 0..<spec.scenario.streams {
            if spec.needsSeparateReader {
                spawn { await self.runSender(s) }
                spawn { await self.runReceiver(s) }
            } else {
                spawn { await self.runStream(s) }
            }
        }
    }

    // MARK: Per-stream scripts

    func runStream(_ s: Int) async {
        var tlv = AsyncTLV(mux: mux, stream: s)
        let n = spec.scenario.messagesPerStream
        if spec.responds {
            var received = 0
            while let m = await tlv.receive() {
                check(m, s, received)
                received += 1
                if !(await send(&tlv, s, received - 1)) { break }
                if received % spec.scenario.receiveBudget == 0 { await Task.yield() }
            }
            if received != spec.expects { counters.verifyFailures += 1 }
            tlv.finish()
        } else if spec.awaitsResponses {
            var sent = 0
            var received = 0
            let window = spec.scenario.outstanding
            while sent < n || received < n {
                while sent < n && sent - received < window {
                    if !(await send(&tlv, s, sent)) { break }
                    sent += 1
                }
                guard received < n, let m = await tlv.receive() else { break }
                check(m, s, received)
                received += 1
            }
            tlv.finish()
            await drain(&tlv, s, received: received)
        } else {
            // One-way sender (client) or pure receiver (server).
            var sent = 0
            while sent < spec.originates {
                if !(await send(&tlv, s, sent)) { break }
                sent += 1
            }
            tlv.finish()
            await drain(&tlv, s, received: 0)
        }
        completion.taskFinished()
    }

    func runSender(_ s: Int) async {
        var tlv = AsyncTLV(mux: mux, stream: s)
        for seq in 0..<spec.originates {
            if !(await send(&tlv, s, seq)) { break }
        }
        tlv.finish()
        completion.taskFinished()
    }

    func runReceiver(_ s: Int) async {
        var tlv = AsyncTLV(mux: mux, stream: s)
        await drain(&tlv, s, received: 0)
        completion.taskFinished()
    }

    /// Receives until the stream ends, checking each message against the script.
    func drain(_ tlv: inout AsyncTLV, _ s: Int, received start: Int) async {
        var received = start
        let budget = spec.scenario.receiveBudget
        while let m = await tlv.receive() {
            check(m, s, received)
            received += 1
            if received % budget == 0 { await Task.yield() }
        }
        if received != spec.expects { counters.verifyFailures += 1 }
    }

    @inline(__always)
    func send(_ tlv: inout AsyncTLV, _ s: Int, _ seq: Int) async -> Bool {
        let size = spec.sendSize(stream: s, seq: seq)
        let ok = await tlv.send(type: spec.sendType, length: size) {
            Payload.fill($0, stream: s, seq: seq)
        }
        if ok {
            counters.messagesSent += 1
            counters.bytesSent += size
        }
        return ok
    }

    @inline(__always)
    func check(_ m: TLVMessage, _ s: Int, _ seq: Int) {
        let size = spec.expectedSize(stream: s, seq: seq)
        if !Payload.verify(m, stream: s, seq: seq, type: spec.expectedType, length: size, level: verify) {
            counters.verifyFailures += 1
        }
        counters.messagesReceived += 1
        counters.bytesReceived += m.length
    }
}
