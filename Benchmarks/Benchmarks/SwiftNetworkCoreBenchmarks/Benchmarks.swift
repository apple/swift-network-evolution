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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork

/// The gated counters. These scenarios are synchronous and touch no crypto, so their ARC traffic is
/// ours and is gated exactly.
let coreMetrics: [BenchmarkMetric] = [
    .mallocCountTotal,
    .objectAllocCount,
    .retainCount,
    .releaseCount,
    .syscalls,
]

/// A frame large enough to hold a full-size datagram, which is the size the send path builds.
let pathMTU = 1350

/// The size QUIC pads an Initial packet out to.
let paddedInitialSize = 1200

/// A run of zeros big enough for any padding a packet needs, allocated once.
let sharedZeroBytes = [UInt8](repeating: 0, count: pathMTU)

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(metrics: coreMetrics)

    if #available(anyAppleOS 26, *) {
        coreBenchmarks()
    }
}

@available(Network 0.1.0, *)
private func coreBenchmarks() {
    // Object allocations and ARC counts are gated exactly. Mallocs and syscalls get 50: the
    // allocator makes syscalls as it grows the heap, so the count moves with iteration count, and 50
    // still catches a per-operation regression or a path that starts touching a file.
    let tolerance: [BenchmarkMetric: BenchmarkThresholds] = [
        .mallocCountTotal: .init(absolute: [.p90: 50]),
        .objectAllocCount: .init(absolute: [.p90: 0]),
        .retainCount: .init(absolute: [.p90: 0]),
        .releaseCount: .init(absolute: [.p90: 0]),
        .syscalls: .init(absolute: [.p90: 50]),
    ]

    func configuration(scalingFactor: BenchmarkScalingFactor = .kilo) -> Benchmark.Configuration {
        .init(
            metrics: coreMetrics,
            scalingFactor: scalingFactor,
            maxDuration: .seconds(10),
            maxIterations: 100,
            thresholds: tolerance
        )
    }

    // MARK: - Frame and FrameArray

    // A no-argument initializer must be free; this pins the empty case at zero.
    Benchmark("FrameArray_empty", configuration: configuration()) { benchmark in
        for _ in benchmark.scaledIterations {
            let frames = FrameArray()
            blackHole(frames.isEmpty)
        }
    }

    Benchmark("FrameArray_with_capacity_16", configuration: configuration()) { benchmark in
        for _ in benchmark.scaledIterations {
            let frames = FrameArray(capacity: 16)
            blackHole(frames.isEmpty)
        }
    }

    Benchmark("Frame_allocate_and_finalize", configuration: configuration()) { benchmark in
        for _ in benchmark.scaledIterations {
            var frame = Frame(count: pathMTU)
            blackHole(frame.bufferLength)
            frame.finalize(success: false)
        }
    }

    Benchmark("FrameArray_add_and_drain_8", configuration: configuration()) { benchmark in
        for _ in benchmark.scaledIterations {
            var frames = FrameArray()
            for _ in 0..<8 {
                frames.add(frame: Frame(count: 128))
            }
            while var frame = frames.popFirst() {
                frame.finalize(success: true)
            }
        }
    }

    // MARK: - Serializer

    // Padding written through a heap `[UInt8]`, the shape `FramePadding.write` uses for every
    // Initial packet.
    Benchmark("Serializer_write_1200_byte_buffer", configuration: configuration()) { benchmark in
        var frame = Frame(count: pathMTU)
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let padding = [UInt8](repeating: 0, count: paddedInitialSize)
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.buffer(padding)
            }
            blackHole(result)
        }
        benchmark.stopMeasurement()
    }

    // The same bytes from storage that already exists. `buffer(_:)` only forwards to `span(_:)`, so
    // the array above buys nothing but a span over zeros.
    Benchmark("Serializer_write_1200_bytes_from_shared_span", configuration: configuration()) { benchmark in
        var frame = Frame(count: pathMTU)
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let padding = sharedZeroBytes.span.bytes.extracting(first: paddedInitialSize)
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.span(padding)
            }
            blackHole(result)
        }
        benchmark.stopMeasurement()
    }

    Benchmark("Serializer_write_fixed_width_fields", configuration: configuration()) { benchmark in
        var frame = Frame(count: pathMTU)
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.uint8(0xC0)
                try write.uint32NetworkByteOrder(0x0000_0001)
                try write.uint64NetworkByteOrder(0xDEAD_BEEF_CAFE_F00D)
                try write.uint16NetworkByteOrder(0x1234)
            }
            blackHole(result)
        }
        benchmark.stopMeasurement()
    }

    // The pair differs only in whether the value fits one byte.
    Benchmark("Serializer_write_vle_one_byte", configuration: configuration()) { benchmark in
        var frame = Frame(count: pathMTU)
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.vle(UInt64(1))
            }
            blackHole(result)
        }
        benchmark.stopMeasurement()
    }

    Benchmark("Serializer_write_vle_eight_bytes", configuration: configuration()) { benchmark in
        var frame = Frame(count: pathMTU)
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let result = Serializer.serialize(&frame, claim: false) { write throws(SerializationError) in
                try write.vle(UInt64(0x3FFF_FFFF_FFFF_FFFF))
            }
            blackHole(result)
        }
        benchmark.stopMeasurement()
    }

    // MARK: - Deserializer

    Benchmark("Deserializer_read_fixed_width_fields", configuration: configuration()) { benchmark in
        let bytes: [UInt8] = [
            0xC0,
            0x00, 0x00, 0x00, 0x01,
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D,
            0x12, 0x34,
        ]
        var frame = Frame(copyBuffer: bytes)
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            var first: UInt8 = 0
            var version: UInt32 = 0
            var identifier: UInt64 = 0
            var length: UInt16 = 0
            let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                try read.uint8(&first)
                try read.uint32NetworkByteOrder(&version)
                try read.uint64NetworkByteOrder(&identifier)
                try read.uint16NetworkByteOrder(&length)
            }
            blackHole(result)
            blackHole(identifier)
        }
        benchmark.stopMeasurement()
    }

    Benchmark("Deserializer_read_vle_one_byte", configuration: configuration()) { benchmark in
        var frame = Frame(copyBuffer: [0x01])
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            var value: UInt64 = 0
            let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                try read.vle(&value)
            }
            blackHole(result)
            blackHole(value)
        }
        benchmark.stopMeasurement()
    }

    Benchmark("Deserializer_read_vle_eight_bytes", configuration: configuration()) { benchmark in
        var frame = Frame(copyBuffer: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            var value: UInt64 = 0
            let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                try read.vle(&value)
            }
            blackHole(result)
            blackHole(value)
        }
        benchmark.stopMeasurement()
    }

    Benchmark("Deserializer_read_1024_byte_buffer", configuration: configuration()) { benchmark in
        var frame = Frame(copyBuffer: [UInt8](repeating: 0xAB, count: 1024))
        defer { frame.finalize(success: false) }

        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            var payload = [UInt8]()
            let result = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
                try read.buffer(&payload, length: 1024)
            }
            blackHole(result)
            blackHole(payload.count)
        }
        benchmark.stopMeasurement()
    }
}
