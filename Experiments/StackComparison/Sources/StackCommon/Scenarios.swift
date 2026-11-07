public enum Scenarios {
    public static let all: [Scenario] = {
        var list: [Scenario] = []

        list.append(
            Scenario(
                name: "bulk", summary: "1 stream, 16 KB messages one way: packetization and copy throughput",
                streams: 1, messagesPerStream: 20_000, sizes: .fixed(16_384), mode: .oneWay))

        list.append(
            Scenario(
                name: "small-msgs", summary: "1 stream, 64 B messages one way: per-message overhead",
                streams: 1, messagesPerStream: 1_000_000, sizes: .fixed(64), mode: .oneWay))

        list.append(
            Scenario(
                name: "streams-16", summary: "16 streams, 128 B messages: several streams per packet",
                streams: 16, messagesPerStream: 50_000, sizes: .fixed(128), mode: .oneWay))

        list.append(
            Scenario(
                name: "streams-1000", summary: "1000 streams, 100 B messages: many cold streams",
                streams: 1000, messagesPerStream: 500, sizes: .fixed(100), mode: .oneWay))

        list.append(
            Scenario(
                name: "pingpong-1", summary: "1 stream request/response, 1 outstanding: pure latency path",
                streams: 1, messagesPerStream: 100_000, sizes: .fixed(100), mode: .echo))

        list.append(
            Scenario(
                name: "pingpong-100", summary: "100 streams request/response, 1 outstanding each",
                streams: 100, messagesPerStream: 2_000, sizes: .fixed(100), mode: .echo))

        var pipelined = Scenario(
            name: "pipelined-8", summary: "8 streams request/response, 8 outstanding each",
            streams: 8, messagesPerStream: 25_000, sizes: .uniform(40...400), mode: .echo)
        pipelined.outstanding = 8
        pipelined.responseSize = 200
        list.append(pipelined)

        list.append(
            Scenario(
                name: "mixed", summary: "32 streams, 64 B messages with an occasional 20 KB one",
                streams: 32, messagesPerStream: 4_000,
                sizes: .bimodal(small: 64, large: 20_000, largeEvery: 16), mode: .oneWay))

        list.append(
            Scenario(
                name: "bidi-32", summary: "32 streams, both directions at once, 8-2000 B",
                streams: 32, messagesPerStream: 5_000, sizes: .uniform(8...2_000), mode: .bidirectional))

        var slow = Scenario(
            name: "slow-reader", summary: "8 streams, 16 KB windows, receiver handles 4 msgs per turn",
            streams: 8, messagesPerStream: 20_000, sizes: .fixed(1_000), mode: .oneWay)
        slow.window = 16 * 1024
        slow.sendBuffer = 16 * 1024
        slow.receiveBudget = 4
        list.append(slow)

        var tiny = Scenario(
            name: "tiny-window", summary: "4 streams, 4 KB windows: constant flow-control stalls",
            streams: 4, messagesPerStream: 30_000, sizes: .fixed(1_500), mode: .oneWay)
        tiny.window = 4 * 1024
        tiny.sendBuffer = 8 * 1024
        list.append(tiny)

        return list
    }()

    public static func named(_ name: String) -> Scenario? { all.first { $0.name == name } }
}
