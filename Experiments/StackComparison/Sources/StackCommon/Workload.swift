/// The workload both stacks run. The scenario, message sizes, payload contents and
/// verification are shared; only how an application is *written* against each
/// stack differs.
public struct Scenario: Sendable {
    public enum Mode: Sendable {
        /// Client sends `messagesPerStream` messages per stream; server only receives.
        case oneWay
        /// Client sends requests, keeping at most `outstanding` unanswered per stream;
        /// the server answers each with a `responseSize` byte response.
        case echo
        /// Both sides send `messagesPerStream` messages per stream independently.
        case bidirectional
    }

    public enum Sizes: Sendable {
        case fixed(Int)
        case uniform(ClosedRange<Int>)
        /// `small` bytes, except every `largeEvery`th message is `large` bytes.
        case bimodal(small: Int, large: Int, largeEvery: Int)
    }

    public var name: String
    public var summary: String
    public var streams: Int
    public var messagesPerStream: Int
    public var sizes: Sizes
    public var mode: Mode
    public var outstanding = 1
    public var responseSize = 64
    /// Per-stream receive window (initial flow-control credit) in bytes.
    public var window = 256 * 1024
    /// Per-stream send buffer capacity in bytes.
    public var sendBuffer = 256 * 1024
    /// Packets in flight per direction before the network back-pressures the sender.
    public var linkPackets = 64
    /// Messages a receiving application handles per stream per scheduling turn.
    public var receiveBudget = Int.max

    public init(
        name: String, summary: String, streams: Int, messagesPerStream: Int,
        sizes: Sizes, mode: Mode
    ) {
        self.name = name
        self.summary = summary
        self.streams = streams
        self.messagesPerStream = messagesPerStream
        self.sizes = sizes
        self.mode = mode
    }

    public var maxMessageValue: Int {
        switch sizes {
        case .fixed(let n): return max(n, responseSize)
        case .uniform(let r): return max(r.upperBound, responseSize)
        case .bimodal(_, let large, _): return max(large, responseSize)
        }
    }

    public func validate() {
        precondition(maxMessageValue >= 8)
        precondition(maxMessageValue + Wire.tlvHeader <= window / 2, "message must fit in half a window")
        precondition(maxMessageValue + Wire.tlvHeader <= sendBuffer, "message must fit in the send buffer")
    }

    public func scaled(by factor: Double) -> Scenario {
        var s = self
        s.messagesPerStream = max(1, Int(Double(messagesPerStream) * factor))
        return s
    }

    /// Size of the value of request/data message `seq` on `stream` as sent by the client.
    @inlinable
    public func requestSize(stream: Int, seq: Int) -> Int {
        switch sizes {
        case .fixed(let n): return n
        case .uniform(let r):
            let h = mix(UInt64(stream) << 32 | UInt64(seq))
            return r.lowerBound + Int(h % UInt64(r.count))
        case .bimodal(let small, let large, let every):
            return (seq + stream) % every == 0 ? large : small
        }
    }
}

@inlinable
func mix(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

public enum Role: Sendable { case client, server }

/// What one endpoint of a scenario does, derived once so that both stacks'
/// applications follow exactly the same script.
public struct RoleSpec: Sendable {
    public var scenario: Scenario
    public var role: Role

    public init(_ scenario: Scenario, _ role: Role) {
        self.scenario = scenario
        self.role = role
    }

    /// Messages this endpoint originates on each stream (not counting responses).
    public var originates: Int {
        switch (role, scenario.mode) {
        case (.client, _): return scenario.messagesPerStream
        case (.server, .bidirectional): return scenario.messagesPerStream
        case (.server, _): return 0
        }
    }

    /// Messages this endpoint expects to receive on each stream.
    public var expects: Int {
        switch (role, scenario.mode) {
        case (.server, _): return scenario.messagesPerStream
        case (.client, .oneWay): return 0
        case (.client, _): return scenario.messagesPerStream
        }
    }

    /// The server in `echo` mode sends a response for every request it receives.
    public var responds: Bool { role == .server && scenario.mode == .echo }
    /// The client in `echo` mode waits for responses before sending more.
    public var awaitsResponses: Bool { role == .client && scenario.mode == .echo }

    @inlinable
    public func sendSize(stream: Int, seq: Int) -> Int {
        responds ? scenario.responseSize : originatedSize(stream: stream, seq: seq)
    }

    @inlinable
    public func expectedSize(stream: Int, seq: Int) -> Int {
        // What the peer sends: the mirror of our own sizes.
        if awaitsResponses { return scenario.responseSize }
        return scenario.requestSize(stream: stream, seq: seq)
    }

    @inlinable
    func originatedSize(stream: Int, seq: Int) -> Int {
        scenario.requestSize(stream: stream, seq: seq)
    }

    public var sendType: UInt16 { responds ? 2 : 1 }
    public var expectedType: UInt16 { awaitsResponses ? 2 : 1 }

    /// Number of tasks / state machines needed to run this role's streams to completion.
    public var needsSeparateReader: Bool { scenario.mode == .bidirectional }
}

public enum VerifyLevel: Sendable {
    case none
    /// Check type, length, sequence number and stream id of each message.
    case headers
    /// Additionally check every payload byte.
    case full
}

public enum Payload {
    /// value = seq:u32 | stream:u32 | filler..., where the filler byte is derived from seq.
    @inlinable
    public static func fill(_ buffer: UnsafeMutableRawBufferPointer, stream: Int, seq: Int) {
        let p = buffer.baseAddress!
        storeBE32(UInt32(truncatingIfNeeded: seq), p)
        storeBE32(UInt32(truncatingIfNeeded: stream), p + 4)
        if buffer.count > 8 {
            memset(p + 8, Int32(filler(seq)), buffer.count - 8)
        }
    }

    @inlinable
    static func filler(_ seq: Int) -> UInt8 { UInt8(truncatingIfNeeded: seq &* 31 &+ 7) }

    /// Returns true when `message` is the expected one.
    @inlinable
    public static func verify(
        _ m: TLVMessage, stream: Int, seq: Int, type: UInt16, length: Int, level: VerifyLevel
    ) -> Bool {
        if level == .none { return true }
        guard m.type == type, m.length == length, length >= 8 else { return false }
        guard loadBE32(m.value) == UInt32(truncatingIfNeeded: seq),
            loadBE32(m.value + 4) == UInt32(truncatingIfNeeded: stream)
        else { return false }
        if level == .full {
            let f = filler(seq)
            let bytes = UnsafeRawBufferPointer(start: m.value + 8, count: length - 8)
            for b in bytes where b != f { return false }
        }
        return true
    }
}

public struct AppCounters: Sendable {
    public var messagesSent = 0
    public var messagesReceived = 0
    public var bytesSent = 0
    public var bytesReceived = 0
    public var verifyFailures = 0

    public init() {}

    public static func + (a: AppCounters, b: AppCounters) -> AppCounters {
        var r = AppCounters()
        r.messagesSent = a.messagesSent + b.messagesSent
        r.messagesReceived = a.messagesReceived + b.messagesReceived
        r.bytesSent = a.bytesSent + b.bytesSent
        r.bytesReceived = a.bytesReceived + b.bytesReceived
        r.verifyFailures = a.verifyFailures + b.verifyFailures
        return r
    }
}

public struct RunResult: Sendable {
    public var stack: String
    public var scenario: String
    public var nanoseconds: UInt64
    public var app: AppCounters
    public var stackCounters: StackCounters
    public var stalled: Bool
    /// CPU consumed between the same two points the wall time covers.
    public var cpu: CPUCost

    public init(
        stack: String, scenario: String, nanoseconds: UInt64, app: AppCounters,
        stackCounters: StackCounters, stalled: Bool, cpu: CPUCost = .zero
    ) {
        self.cpu = cpu
        self.stack = stack
        self.scenario = scenario
        self.nanoseconds = nanoseconds
        self.app = app
        self.stackCounters = stackCounters
        self.stalled = stalled
    }

    public var messages: Int { app.messagesSent }
    public var bytes: Int { app.bytesSent }
    public var cyclesPerMessage: Double { Double(cpu.cycles) / Double(max(1, messages)) }
    public var instructionsPerMessage: Double { Double(cpu.instructions) / Double(max(1, messages)) }
    public var nsPerMessage: Double { Double(nanoseconds) / Double(max(1, messages)) }
    public var megabytesPerSecond: Double { Double(bytes) / 1e6 / (Double(nanoseconds) / 1e9) }
}

public protocol StackImplementation {
    static var name: String { get }
    /// Whether this stack supports `link`.
    static func supports(_ link: LinkKind) -> Bool
    static func run(_ scenario: Scenario, verify: VerifyLevel, link: LinkKind) -> RunResult
}

extension StackImplementation {
    public static func run(_ scenario: Scenario, verify: VerifyLevel) -> RunResult {
        run(scenario, verify: verify, link: .memory)
    }
}

import Darwin

@inlinable
public func monotonicNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
