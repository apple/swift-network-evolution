import Dispatch
import StackCommon

/// Runs a scenario with the endpoints connected by a datagram socketpair and driven
/// by dispatch sources. Each endpoint's read source fires when a packet arrives and
/// runs one `turn` of that endpoint (drain the socket, deliver events up to the
/// application, flush what it wrote). When a send hits a full socket the endpoint's
/// write source is armed, and fires when there is room. Nothing polls.
final class SyncSocketRun: @unchecked Sendable {
    var client: SyncEndpoint
    var server: SyncEndpoint
    var clientLink: SyncSocketLink
    var serverLink: SyncSocketLink
    var clientWatcher: FDWatcher!
    var serverWatcher: FDWatcher!
    let queue = DispatchQueue(label: "SyncSocketRun")
    let done = DispatchSemaphore(value: 0)
    var finished = false
    var start: UInt64 = 0
    var end: UInt64 = 0

    init(_ scenario: Scenario, verify: VerifyLevel) {
        let (a, b) = makeDatagramPorts(packets: scenario.linkPackets)
        client = SyncEndpoint(side: .a, spec: RoleSpec(scenario, .client), verify: verify)
        server = SyncEndpoint(side: .b, spec: RoleSpec(scenario, .server), verify: verify)
        clientLink = SyncSocketLink(port: a)
        serverLink = SyncSocketLink(port: b)
        clientWatcher = FDWatcher(
            fd: a.fd, queue: queue, onReadable: { [unowned self] in self.serviceClient() },
            onWritable: { [unowned self] in self.clientWritable() })
        serverWatcher = FDWatcher(
            fd: b.fd, queue: queue, onReadable: { [unowned self] in self.serviceServer() },
            onWritable: { [unowned self] in self.serverWritable() })
    }

    func serviceClient() {
        _ = client.turn(link: &clientLink)
        if clientLink.hasPending { clientWatcher.armWrite() }
        checkDone()
    }

    func serviceServer() {
        _ = server.turn(link: &serverLink)
        if serverLink.hasPending { serverWatcher.armWrite() }
        checkDone()
    }

    func clientWritable() {
        guard clientLink.retryPending() else { return }
        clientWatcher.disarmWrite()
        serviceClient()
    }

    func serverWritable() {
        guard serverLink.retryPending() else { return }
        serverWatcher.disarmWrite()
        serviceServer()
    }

    func checkDone() {
        if !finished && client.isFinished && server.isFinished {
            finished = true
            end = monotonicNanoseconds()
            done.signal()
        }
    }

    /// Starts both applications from the queue (the sources take it from there) and
    /// waits for completion.
    func run() -> Bool {
        queue.async { [self] in
            start = monotonicNanoseconds()
            client.start()
            server.start()
            serviceClient()
            serviceServer()
        }
        let completed = done.wait(timeout: .now() + 60) == .success
        clientWatcher.cancel()
        serverWatcher.cancel()
        queue.sync {}  // everything that was going to run has run
        return completed
    }

    var counters: StackCounters {
        var c = client.mux.counters + server.mux.counters
        c.linkBlocked = clientLink.port.blockedSends + serverLink.port.blockedSends
        return c
    }

    deinit {
        clientLink.port.freeBuffers()
        serverLink.port.freeBuffers()
    }
}

extension SyncStackImpl {
    static func runOverSockets(_ scenario: Scenario, verify: VerifyLevel) -> RunResult {
        let run = SyncSocketRun(scenario, verify: verify)
        let completed = run.run()
        return RunResult(
            stack: name, scenario: scenario.name, nanoseconds: completed ? run.end - run.start : 0,
            app: run.client.app.counters + run.server.app.counters,
            stackCounters: run.counters,
            stalled: !completed)
    }
}
