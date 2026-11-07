import Darwin
import Dispatch
import StackCommon

final class ResultBox: @unchecked Sendable {
    var result: RunResult?
}

public enum AsyncStackImpl: StackImplementation {
    public static let name = "async"

    public static func supports(_ link: LinkKind) -> Bool { true }

    public static func run(_ scenario: Scenario, verify: VerifyLevel, link kind: LinkKind) -> RunResult {
        scenario.validate()
        let box = ResultBox()
        switch kind {
        case .memory:
            RunLoop.shared.owner = pthread_self()
            spawn {
                let link = AsyncLink(packetsPerDirection: scenario.linkPackets)
                box.result = await execute(scenario, verify: verify, clientLink: link, serverLink: link)
            }
            // The calling thread is the executor: run until every task has finished.
            RunLoop.shared.runUntilIdle()
        case .socket:
            // Tasks run on a serial dispatch queue, and so do the read/write sources
            // that resume them, so a readiness event and the work it unblocks run on
            // the same thread with no hand-off.
            let queue = DispatchQueue(label: "AsyncSocketRun")
            let finished = DispatchSemaphore(value: 0)
            RunLoop.shared.owner = nil
            queue.async {
                let (a, b) = makeDatagramPorts(packets: scenario.linkPackets)
                let clientLink = AsyncSocketLink(port: a, queue: queue)
                let serverLink = AsyncSocketLink(port: b, queue: queue)
                spawn {
                    box.result = await execute(
                        scenario, verify: verify, clientLink: clientLink, serverLink: serverLink)
                    finished.signal()
                }
                RunLoop.shared.drain()
            }
            if finished.wait(timeout: .now() + 60) != .success { box.result = nil }
            queue.sync {}
            queue.sync {}  // let cancelled sources finish and close their descriptors
        }
        guard let result = box.result else {
            return RunResult(
                stack: name, scenario: scenario.name, nanoseconds: 0, app: AppCounters(),
                stackCounters: StackCounters(), stalled: true)
        }
        return result
    }

    static func execute<L: AsyncLinkProtocol>(
        _ scenario: Scenario, verify: VerifyLevel, clientLink: L, serverLink: L
    ) async -> RunResult {
        let clientMux = AsyncMux(streams: scenario.streams, window: scenario.window, sendBuffer: scenario.sendBuffer)
        let serverMux = AsyncMux(streams: scenario.streams, window: scenario.window, sendBuffer: scenario.sendBuffer)
        let clientSpec = RoleSpec(scenario, .client)
        let serverSpec = RoleSpec(scenario, .server)
        let tasks = scenario.streams * (AsyncApplication.tasksPerStream(clientSpec) + AsyncApplication.tasksPerStream(serverSpec))
        let completion = Completion(tasks: tasks)
        let client = AsyncApplication(spec: clientSpec, verify: verify, mux: clientMux, completion: completion)
        let server = AsyncApplication(spec: serverSpec, verify: verify, mux: serverMux, completion: completion)

        let cpuStart = CPUCost.now()
        let start = monotonicNanoseconds()
        spawn { await clientMux.runReceivePump(link: clientLink, side: .a) }
        spawn { await clientMux.runSendPump(link: clientLink, side: .a) }
        spawn { await serverMux.runReceivePump(link: serverLink, side: .b) }
        spawn { await serverMux.runSendPump(link: serverLink, side: .b) }
        client.start()
        server.start()
        await completion.wait()
        let elapsed = completion.endTime - start

        clientLink.close()
        if serverLink !== clientLink { serverLink.close() }
        clientMux.close()
        serverMux.close()

        var stack = clientMux.counters + serverMux.counters
        stack.wakeups += clientLink.suspensions
        if serverLink !== clientLink { stack.wakeups += serverLink.suspensions }
        stack.linkBlocked = clientLink.blockedSends + (serverLink !== clientLink ? serverLink.blockedSends : 0)
        return RunResult(
            stack: name, scenario: scenario.name, nanoseconds: elapsed,
            app: client.counters + server.counters, stackCounters: stack, stalled: false,
            cpu: completion.endCPU - cpuStart)
    }
}
