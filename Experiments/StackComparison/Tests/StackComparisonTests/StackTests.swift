import AsyncActorStack
import AsyncStack
import Foundation
import Testing

@testable import StackCommon
import SyncStack

let allStacks: [any StackImplementation.Type] = [SyncStackImpl.self, AsyncStackImpl.self, AsyncActorStackImpl.self]

// The async stacks share one process-wide run loop (and the actor variant needs the cooperative
// thread pool), so all stack tests run one at a time.
@Suite(.serialized) enum StackSuites {
    @Suite struct StackTests {
        /// Every scenario, on every stack, delivers every message intact and completes.
        @Test(arguments: Scenarios.all.map(\.name))
        func scenarioCompletes(name: String) {
            let scenario = Scenarios.named(name)!.scaled(by: name == "small-msgs" ? 0.002 : 0.02)
            let expected = expectedMessages(scenario)
            for impl in allStacks {
                let r = runExclusively(impl, scenario, verify: .full)
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
                let r = runExclusively(impl, scenario, verify: .full)
                #expect(!r.stalled && r.app.verifyFailures == 0)
                #expect(r.stackCounters.creditFrames > 100, "\(impl.name) sent \(r.stackCounters.creditFrames) credit updates")
            }
        }

        @Test func packetsCarryMultipleStreams() {
            let scenario = Scenarios.named("streams-16")!.scaled(by: 0.02)
            for impl in allStacks {
                let r = runExclusively(impl, scenario, verify: .headers)
                let framesPerPacket = Double(r.stackCounters.streamFrames) / Double(r.stackCounters.packetsSent)
                #expect(framesPerPacket > 1.5, "\(impl.name): \(framesPerPacket) stream frames per packet")
            }
        }

        @Test func stacksAgreeOnAppLevelResults() {
            let scenario = Scenarios.named("bidi-32")!.scaled(by: 0.02)
            let results = allStacks.map { runExclusively($0, scenario, verify: .full) }
            for r in results.dropFirst() {
                #expect(r.app.messagesSent == results[0].app.messagesSent)
                #expect(r.app.bytesSent == results[0].app.bytesSent)
            }
        }

        @Test func repeatedRunsAreIndependent() {
            let scenario = Scenarios.named("pingpong-100")!.scaled(by: 0.05)
            for impl in allStacks {
                for _ in 0..<3 {
                    let r = runExclusively(impl, scenario, verify: .full)
                    #expect(!r.stalled && r.app.verifyFailures == 0)
                }
            }
        }
    }

    @Suite struct SocketStackTests {
        @Test(arguments: Scenarios.all.map(\.name))
        func scenarioCompletesOverSockets(name: String) {
            let scenario = Scenarios.named(name)!.scaled(by: name == "small-msgs" ? 0.002 : 0.02)
            let expected = expectedMessages(scenario)
            for impl in socketStacks {
                let r = runExclusively(impl, scenario, verify: .full, link: .socket)
                #expect(!r.stalled, "\(impl.name) stalled on \(name)")
                #expect(r.app.verifyFailures == 0, "\(impl.name) delivered bad data on \(name)")
                #expect(r.stackCounters.flowViolations == 0)
                #expect(r.app.messagesSent == expected && r.app.messagesReceived == expected)
            }
        }

        @Test func fullSocketBufferIsHandledByWriteSignalling() {
            var scenario = Scenarios.named("bulk")!.scaled(by: 0.1)
            scenario.linkPackets = 4  // a socket buffer of ~5 KB: the sender must hit EAGAIN
            for impl in socketStacks {
                let r = runExclusively(impl, scenario, verify: .full, link: .socket)
                #expect(!r.stalled && r.app.verifyFailures == 0)
                #expect(r.stackCounters.linkBlocked > 0, "\(impl.name) never saw a full socket")
            }
        }

        @Test func repeatedSocketRunsDoNotLeakOrInterfere() {
            let scenario = Scenarios.named("pingpong-100")!.scaled(by: 0.02)
            for impl in socketStacks {
                for _ in 0..<5 {
                    let r = runExclusively(impl, scenario, verify: .full, link: .socket)
                    #expect(!r.stalled && r.app.verifyFailures == 0)
                }
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

// Same checks over a real datagram socketpair, with readiness signalled by dispatch sources.
let socketStacks: [any StackImplementation.Type] = [SyncStackImpl.self, AsyncStackImpl.self]

/// The async stacks share one process-wide run loop, and Swift Testing runs suites in
/// parallel, so every stack run takes this lock.
let runLock = NSLock()

func runExclusively(
    _ impl: any StackImplementation.Type, _ scenario: Scenario, verify: VerifyLevel, link: LinkKind = .memory
) -> RunResult {
    runLock.lock()
    defer { runLock.unlock() }
    return impl.run(scenario, verify: verify, link: link)
}
