import StackCommon

final class ResultBox: @unchecked Sendable {
    var result: RunResult?
}

public enum AsyncActorStackImpl: StackImplementation {
    public static let name = "async-actor"

    public static func supports(_ link: LinkKind) -> Bool { link == .memory }

    public static func run(_ scenario: Scenario, verify: VerifyLevel, link: LinkKind) -> RunResult {
        precondition(link == .memory, "the actor variant only runs over the in-memory link")
        scenario.validate()
        let box = ResultBox()
        RunLoop.shared.liveTasks += 1
        Task { @StackActor in
            box.result = await execute(scenario, verify: verify)
            RunLoop.shared.liveTasks -= 1
        }
        // The calling thread is the executor: run until every task has finished.
        RunLoop.shared.runUntilIdle()
        guard let result = box.result else {
            return RunResult(
                stack: name, scenario: scenario.name, nanoseconds: 0, app: AppCounters(),
                stackCounters: StackCounters(), stalled: true)
        }
        return result
    }

    @StackActor
    static func execute(_ scenario: Scenario, verify: VerifyLevel) async -> RunResult {
        let link = AsyncLink(packetsPerDirection: scenario.linkPackets)
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
        spawn { await clientMux.runReceivePump(link: link, side: .a) }
        spawn { await clientMux.runSendPump(link: link, side: .a) }
        spawn { await serverMux.runReceivePump(link: link, side: .b) }
        spawn { await serverMux.runSendPump(link: link, side: .b) }
        client.start()
        server.start()
        await completion.wait()
        let elapsed = completion.endTime - start

        link.close()
        clientMux.close()
        serverMux.close()

        var stack = clientMux.counters + serverMux.counters
        stack.wakeups += link.suspensions
        return RunResult(
            stack: name, scenario: scenario.name, nanoseconds: elapsed,
            app: client.counters + server.counters, stackCounters: stack, stalled: false,
            cpu: completion.endCPU - cpuStart)
    }
}
