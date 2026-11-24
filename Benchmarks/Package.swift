// swift-tools-version: 6.4
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

import PackageDescription

let settings: [SwiftSetting] = [
    .enableExperimentalFeature(
        "AvailabilityMacro=Network 0.1.0:macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26"
    ),
    .enableExperimentalFeature("AnyAppleOSAvailability"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "benchmarks",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            name: "swift-network",
            path: "../",
            traits: ["DisableDebugLogging", "DisableErrorLogging"]
        ),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0-beta.1"),
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.36.2"),
    ],
    targets: [
        .executableTarget(
            name: "QUICBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "SwiftNetwork", package: "swift-network"),
                .product(name: "SwiftNetworkTestHarness", package: "swift-network"),
                .product(name: "SwiftNetworkTestSupport", package: "swift-network"),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .android])
                ),
            ],
            path: "Benchmarks/QUICBenchmarks",
            swiftSettings: settings,
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .executableTarget(
            name: "SwiftNetworkCoreBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "SwiftNetwork", package: "swift-network"),
            ],
            path: "Benchmarks/SwiftNetworkCoreBenchmarks",
            swiftSettings: settings,
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
    ]
)
