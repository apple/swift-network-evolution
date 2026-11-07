import AsyncActorStack
import AsyncStack
import Testing

@testable import StackCommon
import SyncStack

let allStacks: [any StackImplementation.Type] = [SyncStackImpl.self, AsyncStackImpl.self, AsyncActorStackImpl.self]

// The async stacks share one process-wide run loop, so runs must not overlap.
@Suite(.serialized) struct StackTests {
    /// Every scenario, on every stack, delivers every message intact and completes.
    @Test(arguments: Scenarios.all.map(\.name))
    func scenarioCompletes(name: String) {
        let scenario = Scenarios.named(name)!.scaled(by: name == "small-msgs" ? 0.002 : 0.02)
        let expected = expectedMessages(scenario)
        for impl in allStacks {
            let r = impl.run(scenario, verify: .full)
            #expect(!r.stalled, "\(impl.name) stalled on \(name)")
            #expect(r.app.verifyFailures == 0, "\(impl.name) delivered bad data on \(name)")
            #expect(r.stackCounters.flowViolations == 0, "\(impl.name) violated flow control on \(name)")
            #expect(r.app.messagesSent == expected, "\(impl.name) sent \(r.app.messagesSent) on \(name)")
            #expect(r.app.messagesReceived == expected, "\(impl.name) received \(r.app.messagesReceived) on \(name)")
            #expect(r.app.bytesSent == r.app.bytesReceived)
        }
    }

    @Test func flowControlEngagesWithSmallWindows() {
        let scenario = Scenarios.named("tiny-window")!.scaled(by: 0.05)
        for impl in allStacks {
            let r = impl.run(scenario, verify: .full)
            #expect(!r.stalled && r.app.verifyFailures == 0)
            #expect(r.stackCounters.creditFrames > 100, "\(impl.name) sent \(r.stackCounters.creditFrames) credit updates")
        }
    }

    @Test func packetsCarryMultipleStreams() {
        let scenario = Scenarios.named("streams-16")!.scaled(by: 0.02)
        for impl in allStacks {
            let r = impl.run(scenario, verify: .headers)
            let framesPerPacket = Double(r.stackCounters.streamFrames) / Double(r.stackCounters.packetsSent)
            #expect(framesPerPacket > 1.5, "\(impl.name): \(framesPerPacket) stream frames per packet")
        }
    }

    @Test func stacksAgreeOnAppLevelResults() {
        let scenario = Scenarios.named("bidi-32")!.scaled(by: 0.02)
        let results = allStacks.map { $0.run(scenario, verify: .full) }
        for r in results.dropFirst() {
            #expect(r.app.messagesSent == results[0].app.messagesSent)
            #expect(r.app.bytesSent == results[0].app.bytesSent)
        }
    }

    @Test func repeatedRunsAreIndependent() {
        let scenario = Scenarios.named("pingpong-100")!.scaled(by: 0.05)
        for impl in allStacks {
            for _ in 0..<3 {
                let r = impl.run(scenario, verify: .full)
                #expect(!r.stalled && r.app.verifyFailures == 0)
            }
        }
    }
}

func expectedMessages(_ s: Scenario) -> Int {
    let n = s.streams * s.messagesPerStream
    switch s.mode {
    case .oneWay: return n
    case .echo: return 2 * n
    case .bidirectional: return 2 * n
    }
}
