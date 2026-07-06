// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// Availability Macros

let availabilityTags: [_Availability] = [
    _Availability("Network")  // Default Network availability
]
let versionNumbers = ["0.1.0"]

// Availability Macro Utilities

enum _OSAvailability: String {
    // The OS versions in which `Network 0.1.0` APIs first became available.
    case alwaysAvailable = "macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26"
    // Use 10000 for future availability to avoid compiler magic around the 9999 version number but ensure it is greater than 9999
    case future = "macOS 10000, iOS 10000, tvOS 10000, watchOS 10000, visionOS 10000"
}
struct _Availability {
    let name: String
    let osAvailability: _OSAvailability

    init(_ name: String, availability: _OSAvailability = .alwaysAvailable) {
        self.name = name
        self.osAvailability = availability
    }
}
let availabilityMacros: [SwiftSetting] = versionNumbers.flatMap { version in
    availabilityTags.map {
        .enableExperimentalFeature("AvailabilityMacro=\($0.name) \(version):\($0.osAvailability.rawValue)")
    }
}

let allApplePlatforms: [Platform] = [
    .driverKit, .iOS, .macCatalyst, .macOS, .tvOS, .visionOS, .watchOS,
]

// Logging levels, qlog output, and QUIC signposts are configured via package
// traits. See the `traits:` list on the `Package(...)` initializer below.
let settings: [SwiftSetting] = [
    .define("IMPORT_SWIFTTLS"),
    .define("EXPORT_SWIFTTLS"),
    .define("IMPORT_CRYPTO"),
    .define("SWIFTTLS_CERTIFICATE_VERIFICATION"),
    .unsafeFlags(["-Xfrontend", "-experimental-spi-only-imports"]),
    .enableExperimentalFeature("Lifetimes"),
    .enableExperimentalFeature("AnyAppleOSAvailability"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "swift-network-evolution",
    products: [
        .library(
            name: "SwiftNetwork",
            targets: ["SwiftNetwork"]
        ),
        .library(
            name: "SwiftNetworkBenchmarks",
            targets: ["SwiftNetworkBenchmarks"]
        ),
    ],
    traits: [
        .trait(
            name: "DisableDebugLogging",
            description: "Disables the `debug` and `info` logging levels."
        ),
        .trait(
            name: "DisableErrorLogging",
            description: "Disables the `error`, `notice`, and `fault` logging levels."
        ),
        .trait(
            name: "DatapathLogging",
            description:
                "Enables the verbose `datapath` logging level (requires that `DisableDebugLogging` is not enabled)."
        ),
        .trait(
            name: "QlogOutput",
            description: "Enables qlog output from the QUIC implementation."
        ),
        .trait(
            name: "SignpostOutput",
            description: "Enables `OSSignposter` output from the QUIC implementation."
        ),
        // To support back to macOS 26, provide a shim on top of crypto APIs
        // that allows passing spans is provided. This is a less performant path, so for
        // performance-sensitive cases, pass in this trait to disable this shim. 
       .trait(
           name: "DISABLE_SHIM_CRYPTO_SPAN_APIS",
           description: "Disable backwards compatible crypto shim for performance sensitive cases"
       ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0-beta.1"),
        .package(url: "https://github.com/apple/swift-tls.git", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        .target(
            name: "SwiftNetwork",
            dependencies: [
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.linux])),
                .target(name: "SwiftNetworkLinuxShim", condition: .when(platforms: [.linux])),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftTLS", package: "swift-tls"),
            ],
            swiftSettings: availabilityMacros + settings
        ),
        .target(
            name: "SwiftNetworkLinuxShim",
            dependencies: [],
            cSettings: [
                .define("_GNU_SOURCE")
            ],
            swiftSettings: settings
        ),
        .target(
            name: "SwiftNetworkBenchmarks",
            dependencies: [
                "SwiftNetwork",
                .product(name: "SwiftTLS", package: "swift-tls"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: availabilityMacros + settings
        ),
        .testTarget(
            name: "SwiftNetworkTests",
            dependencies: ["SwiftNetwork"],
            swiftSettings: availabilityMacros + settings
        ),
        .testTarget(
            name: "QUICTests",
            dependencies: ["SwiftNetwork"],
            swiftSettings: availabilityMacros + settings
        ),
        .executableTarget(
            name: "QUICHandshake",
            dependencies: ["SwiftNetwork", "SwiftNetworkBenchmarks"],
            path: "Sources/Tools/QUICHandshake",
            exclude: ["README.md"],
            swiftSettings: availabilityMacros + settings,
        ),
        .executableTarget(
            name: "IPUDPTransfer",
            dependencies: ["SwiftNetwork", "SwiftNetworkBenchmarks"],
            path: "Sources/Tools/IPUDPTransfer",
            exclude: ["README.md"],
            swiftSettings: availabilityMacros + settings
        ),
        .executableTarget(
            name: "QUICTransfer",
            dependencies: ["SwiftNetwork", "SwiftNetworkBenchmarks"],
            path: "Sources/Tools/QUICTransfer",
            exclude: ["README.md"],
            swiftSettings: availabilityMacros + settings
        ),
        .executableTarget(
            name: "QUICStreamLoad",
            dependencies: ["SwiftNetwork", "SwiftNetworkBenchmarks"],
            path: "Sources/Tools/QUICStreamLoad",
            exclude: ["README.md"],
            swiftSettings: availabilityMacros + settings
        ),
        .executableTarget(
            name: "SocketTransfer",
            dependencies: ["SwiftNetwork", "SwiftNetworkBenchmarks"],
            path: "Sources/Tools/SocketTransfer",
            exclude: ["README.md"],
            swiftSettings: availabilityMacros + settings
        ),
    ]
)
