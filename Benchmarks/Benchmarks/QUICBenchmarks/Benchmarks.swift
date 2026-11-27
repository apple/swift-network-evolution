//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Benchmark

@_spi(Essentials) import SwiftNetwork

/// Time and instruction count are left out because they cannot hold a line.
let quicMetrics: [BenchmarkMetric] = [
    .mallocCountTotal,
    .objectAllocCount,
    .retainCount,
    .releaseCount,
    .syscalls,
    .writeSyscalls,
]

/// How far each gated counter may move before `thresholds check` fails, in the units stored in
/// `Thresholds/`: for a scenario that runs 1,000 operations per measurement, totals over all 1,000.
///
/// Syscalls get a wide band because most of what they count is the allocator growing the heap.
struct Allowances {
    var mallocs = 2
    var objectAllocations = 2
    var retains = 4
    var releases = 4
    var syscalls = 50

    /// ARC counts through a handshake shift by tens between runs of the same source, as the
    /// dependencies it runs through float.
    static let handshake = Allowances(retains: 32, releases: 32)
}

func gate(_ allowances: Allowances) -> [BenchmarkMetric: BenchmarkThresholds] {
    [
        .mallocCountTotal: .init(absolute: [.p90: allowances.mallocs]),
        .objectAllocCount: .init(absolute: [.p90: allowances.objectAllocations]),
        .retainCount: .init(absolute: [.p90: allowances.retains]),
        .releaseCount: .init(absolute: [.p90: allowances.releases]),
        .syscalls: .init(absolute: [.p90: allowances.syscalls]),
        .writeSyscalls: .init(absolute: [.p90: allowances.syscalls]),
    ]
}

func configuration(
    scalingFactor: BenchmarkScalingFactor,
    maxDuration: Duration,
    maxIterations: Int,
    allowances: Allowances = Allowances()
) -> Benchmark.Configuration {
    .init(
        metrics: quicMetrics,
        scalingFactor: scalingFactor,
        maxDuration: maxDuration,
        maxIterations: maxIterations,
        thresholds: gate(allowances)
    )
}

/// The client datagram the loss scenario loses, counted from zero over the connection. It must
/// fall inside the 16 KB transfer, which the scenario checks.
let lossIndex = 8

/// Small enough that a stream's cost is stream setup rather than payload.
let smallRequest = [UInt8](repeating: 0xEF, count: 100)

/// Small enough to fit one packet.
let oneKilobytePayload = [UInt8](repeating: 0xAB, count: 1024)

/// Larger than the path MTU, so a write has to span packets.
let sixteenKilobytePayload = [UInt8](repeating: 0xCD, count: 16 * 1024)

/// The payload of a TCP segment on a 1500 byte MTU with the timestamp option.
let tcpSegmentSize = 1448

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(metrics: quicMetrics)

    if #available(anyAppleOS 26, *) {
        quicBenchmarks()
    }
}

@available(Network 0.1.0, *)
private func quicBenchmarks() {
    // No handshake, so a change in handshake cost can be placed in setup or on the wire.
    Benchmark(
        "QUICConnectionSetup",
        configuration: configuration(
            scalingFactor: .one,
            maxDuration: .seconds(20),
            maxIterations: 200,
            allowances: .handshake
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let loopback = try QUICLoopback()
            loopback.tearDown()
        }
    }

    // A full handshake. Teardown is inside the window; otherwise it drifts across iterations and
    // looks like a regression.
    Benchmark(
        "QUICHandshake",
        configuration: configuration(
            scalingFactor: .one,
            maxDuration: .seconds(20),
            maxIterations: 200,
            allowances: .handshake
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let loopback = try QUICLoopback()
            try loopback.completeHandshake()
            loopback.tearDown()
        }
    }

    Benchmark(
        "QUICStreamEcho_1KB",
        configuration: configuration(
            scalingFactor: .kilo,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let loopback = try QUICLoopback()
        try loopback.completeHandshake()
        let serverStream = try loopback.primeServerStream(with: oneKilobytePayload)

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            try loopback.send(oneKilobytePayload, to: serverStream)
        }
        benchmark.stopMeasurement()

        loopback.tearDown()
    }

    // As above, but a write spans packets.
    Benchmark(
        "QUICStreamEcho_16KB",
        configuration: configuration(
            scalingFactor: .kilo,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let loopback = try QUICLoopback()
        try loopback.completeHandshake()
        let serverStream = try loopback.primeServerStream(with: sixteenKilobytePayload)

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            try loopback.send(sixteenKilobytePayload, to: serverStream)
        }
        benchmark.stopMeasurement()

        loopback.tearDown()
    }

    // Needs the virtual clock: on a real one the retransmission timeout costs real milliseconds.
    Benchmark(
        "QUICStreamEcho_16KB_with_loss",
        configuration: configuration(
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 50,
            allowances: .handshake
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let loopback = try QUICLoopback(linkDelay: .milliseconds(1), clientDropIndex: lossIndex)
            try loopback.completeHandshake()
            let serverStream = try loopback.primeServerStream(with: oneKilobytePayload)

            // The loss must land inside the 16 KB transfer, or this measures a different path.
            if loopback.clientDatagramsDelivered > lossIndex {
                throw QUICLoopbackError.expectedLossDidNotOccur
            }

            try loopback.send(sixteenKilobytePayload, to: serverStream)
            if loopback.clientDatagramsDelivered <= lossIndex {
                throw QUICLoopbackError.expectedLossDidNotOccur
            }

            loopback.tearDown()
        }
    }

    // The connection is set up outside the window, so this is the per-stream cost.
    Benchmark(
        "QUICStreamChurn",
        configuration: configuration(
            scalingFactor: .kilo,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let loopback = try QUICLoopback(maximumConcurrentStreams: 16)
        try loopback.completeHandshake()
        // Use up the stream the connection opened with, so the loop measures only streams opened
        // on an established connection.
        let serverStream = try loopback.primeServerStream(with: smallRequest)
        blackHole(serverStream)

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            try loopback.exchangeOnNewStream(request: smallRequest, response: oneKilobytePayload)
        }
        benchmark.stopMeasurement()

        loopback.tearDown()
    }

    // The content form of `receive`, which `QUICStreamEcho_*` bypasses by reading at the QUIC
    // stream. Delivering the bytes is outside the window. The window holds the `receive` call and one
    // turn of the scheduler, so the counts include the machinery of `receive` and are meant to be
    // compared with the recorded thresholds, not with zero.
    Benchmark(
        "EndpointFlowContentReceive_16KB",
        configuration: configuration(
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 200
        )
    ) { benchmark in
        let receiver = try ContentReceiveHarness()

        for _ in benchmark.scaledIterations {
            try receiver.deliver(sixteenKilobytePayload, frameSize: tcpSegmentSize)

            benchmark.startMeasurement()
            try receiver.receive(byteCount: sixteenKilobytePayload.count)
            benchmark.stopMeasurement()
        }

        receiver.tearDown()
    }

    // Needs the virtual clock: ten seconds of idle time passes instantly.
    Benchmark(
        "QUICIdle_10s",
        configuration: configuration(
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        // Long enough that the connection outlives every iteration's ten seconds.
        let loopback = try QUICLoopback(idleTimeout: .seconds(3600))
        try loopback.completeHandshake()

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            loopback.idle(for: .seconds(10))
        }
        benchmark.stopMeasurement()

        loopback.tearDown()
    }
}
