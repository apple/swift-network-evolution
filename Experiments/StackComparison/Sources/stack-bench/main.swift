import AsyncActorStack
import AsyncStack
import Foundation
import StackCommon
import SyncStack

struct Options {
    var stacks: [any StackImplementation.Type] = [SyncStackImpl.self, AsyncStackImpl.self, AsyncActorStackImpl.self]
    var scenarios: [Scenario] = Scenarios.all
    var iterations = 5
    var scale = 1.0
    var verify = VerifyLevel.headers
    var repeatSeconds: Double?
    var link = LinkKind.memory
    var cpu = false
}

func usage() -> Never {
    print(
        """
        usage: stack-bench [options]
          --list                     list scenarios and exit
          --scenario NAME            run only this scenario (repeatable)
          --stack sync|async|async-actor|sync-async|all  which stack(s) (default all)
          --iterations N             timed runs per scenario/stack (default 5, after one warm-up)
          --scale F                  multiply every scenario's message count by F
          --verify none|headers|full payload verification (default headers)
          --cpu                      report CPU cycles and instructions (whole process, via
                                     proc_pid_rusage) instead of the timing columns
          --link memory|socket       memory: in-memory queue polled by the driver (default)
                                     socket: datagram socketpair signalled by dispatch sources
                                     (async-actor supports memory only)
          --repeat-seconds S         run the selected stack/scenario in a loop for S seconds
                                     (for attaching Instruments / sample); prints nothing per run
        """)
    exit(2)
}

func parse() -> Options {
    var o = Options()
    var names: [String] = []
    var args = CommandLine.arguments.dropFirst()
    func value() -> String {
        guard let v = args.popFirst() else { usage() }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--list":
            for s in Scenarios.all { print("\(s.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.summary)") }
            exit(0)
        case "--scenario": names.append(value())
        case "--stack":
            switch value() {
            case "sync": o.stacks = [SyncStackImpl.self]
            case "async": o.stacks = [AsyncStackImpl.self]
            case "async-actor": o.stacks = [AsyncActorStackImpl.self]
            case "sync-async": o.stacks = [SyncStackImpl.self, AsyncStackImpl.self]
            case "all": break
            default: usage()
            }
        case "--iterations": o.iterations = Int(value()) ?? 5
        case "--scale": o.scale = Double(value()) ?? 1
        case "--verify":
            switch value() {
            case "none": o.verify = .none
            case "headers": o.verify = .headers
            case "full": o.verify = .full
            default: usage()
            }
        case "--cpu": o.cpu = true
        case "--link":
            switch value() {
            case "memory": o.link = .memory
            case "socket": o.link = .socket
            default: usage()
            }
        case "--repeat-seconds": o.repeatSeconds = Double(value())
        default: usage()
        }
    }
    if !names.isEmpty {
        o.scenarios = names.map {
            guard let s = Scenarios.named($0) else {
                print("unknown scenario \($0); try --list")
                exit(2)
            }
            return s
        }
    }
    o.stacks = o.stacks.filter { $0.supports(o.link) }
    o.scenarios = o.scenarios.map { $0.scaled(by: o.scale) }
    return o
}

func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
func pad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }

let options = parse()

if let seconds = options.repeatSeconds {
    let impl = options.stacks[0]
    let scenario = options.scenarios[0]
    let deadline = monotonicNanoseconds() + UInt64(seconds * 1e9)
    var runs = 0
    while monotonicNanoseconds() < deadline {
        _ = impl.run(scenario, verify: options.verify, link: options.link)
        runs += 1
    }
    print("\(impl.name) \(scenario.name): \(runs) runs")
    exit(0)
}

if options.cpu {
    print("scenario       stack        cycles(M)  instr(M)  cycles/msg  instr/msg   IPC  GHz  ok")
} else {
    print("scenario       stack        ms(min)  ms(med)  ns/msg(med)    MB/s  pkts(k)  wakeups(k)  blocked(k)  ok")
}
var failures = 0
for scenario in options.scenarios {
    var medians: [Double] = []
    for impl in options.stacks {
        _ = impl.run(scenario.scaled(by: 0.1), verify: options.verify, link: options.link)  // warm-up
        var runs: [RunResult] = []
        for _ in 0..<options.iterations { runs.append(impl.run(scenario, verify: options.verify, link: options.link)) }
        runs.sort { $0.nanoseconds < $1.nanoseconds }
        let med = runs[runs.count / 2]
        let min = runs[0]
        let bad = runs.contains { $0.stalled || $0.app.verifyFailures != 0 || $0.stackCounters.flowViolations != 0 }
        if bad { failures += 1 }
        medians.append(Double(med.nanoseconds))
        if options.cpu {
            runs.sort { $0.cpu.cycles < $1.cpu.cycles }
            let c = runs[runs.count / 2]
            medians[medians.count - 1] = Double(c.cpu.cycles)
            let ghz = Double(c.cpu.cycles) / Double(max(1, c.nanoseconds))
            print(
                "\(scenario.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(impl.name.padding(toLength: 12, withPad: " ", startingAt: 0))"
                    + " \(pad(fmt(Double(c.cpu.cycles) / 1e6), 9)) \(pad(fmt(Double(c.cpu.instructions) / 1e6), 9))"
                    + " \(pad(fmt(c.cyclesPerMessage), 11)) \(pad(fmt(c.instructionsPerMessage), 10))"
                    + " \(pad(fmt(Double(c.cpu.instructions) / Double(max(1, c.cpu.cycles)), 2), 5)) \(pad(fmt(ghz, 2), 4))"
                    + "  \(bad ? "FAIL" : "ok")")
            continue
        }
        print(
            "\(scenario.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(impl.name.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + " \(pad(fmt(Double(min.nanoseconds) / 1e6), 8)) \(pad(fmt(Double(med.nanoseconds) / 1e6), 8))"
                + " \(pad(fmt(med.nsPerMessage), 12)) \(pad(fmt(med.megabytesPerSecond, 0), 7))"
                + " \(pad(fmt(Double(med.stackCounters.packetsSent) / 1e3), 8)) \(pad(fmt(Double(med.stackCounters.wakeups) / 1e3), 11))"
                + " \(pad(fmt(Double(med.stackCounters.linkBlocked) / 1e3), 11))  \(bad ? "FAIL" : "ok")")
    }
    if medians.count > 1 {
        let ratios = medians.dropFirst().map { fmt($0 / medians[0], 2) + "x" }
        print("                vs \(options.stacks[0].name): \(ratios.joined(separator: ", "))")
    }
}
exit(failures == 0 ? 0 : 1)
