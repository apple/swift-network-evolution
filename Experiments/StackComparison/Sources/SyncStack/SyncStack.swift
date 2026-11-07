import StackCommon

/// One end of the connection: the protocol layers and the application on top.
public struct SyncEndpoint: ~Copyable {
    var mux: SyncMux
    var tlv = SyncTLV()
    var app: SyncApplication
    let side: Side

    init(side: Side, spec: RoleSpec, verify: VerifyLevel) {
        let s = spec.scenario
        mux = SyncMux(streams: s.streams, window: s.window, sendBuffer: s.sendBuffer)
        app = SyncApplication(spec: spec, verify: verify)
        self.side = side
    }

    var isFinished: Bool { app.isFinished }

    mutating func start() { app.start(tlv: &tlv, mux: &mux) }

    /// One pass of this endpoint's event loop. Returns true if it did anything.
    mutating func turn<L: SyncLinkProtocol & ~Copyable>(link: inout L) -> Bool {
        var progress = false
        while let packet = link.receive(at: side) {
            mux.receive(packet)
            link.release(packet, receivedAt: side)
            progress = true
        }
        while true {
            // Events are only ever drained here, never from inside a layer.
            repeat {
                while let event = mux.nextEvent() {
                    app.handle(event, tlv: &tlv, mux: &mux)
                    progress = true
                }
                if mux.hasSendable && mux.flush(&link, side: side) { progress = true }
            } while mux.hasEvents
            guard app.hasDeferred else { break }
            app.runDeferred(tlv: &tlv, mux: &mux)
            progress = true
        }
        return progress
    }
}

public enum SyncStackImpl: StackImplementation {
    public static let name = "sync"

    public static func supports(_ link: LinkKind) -> Bool { true }

    public static func run(_ scenario: Scenario, verify: VerifyLevel, link kind: LinkKind) -> RunResult {
        scenario.validate()
        if kind == .socket { return runOverSockets(scenario, verify: verify) }
        var link = SyncLink(packetsPerDirection: scenario.linkPackets)
        var client = SyncEndpoint(side: .a, spec: RoleSpec(scenario, .client), verify: verify)
        var server = SyncEndpoint(side: .b, spec: RoleSpec(scenario, .server), verify: verify)

        let cpuStart = CPUCost.now()
        let start = monotonicNanoseconds()
        client.start()
        server.start()
        var stalled = false
        while !(client.isFinished && server.isFinished) {
            let c = client.turn(link: &link)
            let s = server.turn(link: &link)
            if !c && !s {
                stalled = true
                break
            }
        }
        let elapsed = monotonicNanoseconds() - start
        let cpu = CPUCost.now() - cpuStart

        return RunResult(
            stack: name, scenario: scenario.name, nanoseconds: elapsed,
            app: client.app.counters + server.app.counters,
            stackCounters: client.mux.counters + server.mux.counters,
            stalled: stalled, cpu: cpu)
    }
}
