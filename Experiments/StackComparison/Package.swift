// swift-tools-version: 6.2

import PackageDescription

// Standalone package: nothing here depends on the SwiftNetwork stack.
//
// Both stacks are built with identical compiler settings. Dynamic exclusivity
// enforcement is disabled for both so that the class-based (async) stack does not
// pay runtime access checks that the struct-based (sync) stack gets for free
// statically; that difference is real, but it is a compiler-flag detail and is
// removable, so we keep it out of the headline comparison.
let common: [SwiftSetting] = [
    .unsafeFlags(["-enforce-exclusivity=unchecked", "-cross-module-optimization"]),
]

let package = Package(
    name: "StackComparison",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "stack-bench", targets: ["stack-bench"]),
    ],
    targets: [
        .target(name: "StackCommon", swiftSettings: common),
        .target(name: "SyncStack", dependencies: ["StackCommon"], swiftSettings: common),
        .target(name: "AsyncStack", dependencies: ["StackCommon"], swiftSettings: common),
        .executableTarget(
            name: "stack-bench",
            dependencies: ["StackCommon", "SyncStack", "AsyncStack"],
            swiftSettings: common
        ),
        .testTarget(
            name: "StackComparisonTests",
            dependencies: ["StackCommon", "SyncStack", "AsyncStack"]
        ),
    ]
)
