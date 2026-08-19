#  Swift Network Evolution

The Network framework provides implementations of transport protocols, such as QUIC, along with types used to communicate network endpoints (like IP addresses) and various parameters and preferences for how to set up transport connections.

This package provides access to the implementations of core networking objects and protocol stack architecture from [Network.framework](https://developer.apple.com/documentation/network) that is available on Apple platforms. This package is intended to be used by cross-platform projects like [SwiftNIO](https://github.com/apple/swift-nio) to be able to access a Swift-based implementation of protocols like QUIC.

On macOS, iOS, and other Apple platforms, apps should use the Network.framework that comes with the operating system.

> [!NOTE]
> At this time, all types exposed in this package are marked as SPI and subject to change at any time.
> There are no support guarantees that can be made until these SPIs transition to stable APIs at a later date.

## Getting Started

## Prerequisites

- [Swift 6.3 and up](https://swift.org/install)
- macOS 26.0 and up or Linux (Ubuntu 22.04+)
- Xcode 26.0 and up (Apple platforms only)

## Building and Testing

To build via the command line (for all platforms), run  at the root of package:
```
swift build
```

To run all unit tests, run: 
```
swift test
```

Unit tests can also be run by filtering a specific class or function:

```
% swift test --filter SwiftNetworkUDPTests
% swift test --filter SwiftNetworkUDPTests.testUDPEcho
```

Some tests depend on hooks that are compiled into the library only on demand, because they cost a small amount of performance on hot paths.
Pass the define on the command line to compile them in:

```
% swift test -Xswiftc -DNETWORK_INTERNAL_TESTS
```

All unit tests are run automatically upon creation or update of a Pull Request. See [CONTRIBUTING](https://github.com/apple/swift-network-evolution/blob/main/CONTRIBUTING.md) for details.

### Versioning

While the library is in the `0.x.x` version range, you should adopt it using the `.upToNextMinor(from: "0.1.0")` specifier. During this period, breaking changes are intended to map to minor version bumps, so depending on the library this way picks up smaller, non-breaking changes automatically while protecting against API-breaking ones.

### Logging Levels

By default, Swift Network will emit logs at `debug`, `info`, `notice`, `error`, and `fault` levels. There are also datapath-specific debug logs, referred to as `datapath` logs, that are disabled by default.

Logging configuration is exposed via [package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md):

| Trait | Default | Effect |
|---|---|---|
| `DisableDebugLogging` | not specified | When specified, compiles out the `debug` and `info` logging levels. |
| `DisableErrorLogging` | not specified | When specified, compiles out the `error`, `notice`, and `fault` logging levels. |
| `DatapathLogging` | not specified | When specified, compiles in the verbose `datapath` logging level. Has no effect if `DisableDebugLogging` is also specified. |

The level traits are expressed as suppression flags so that they compose well across a dependency graph. SwiftPM unifies trait selections by union, so a leaf package can always specify a `*Disabled` trait to suppress a level that an intermediate left compiled in, but cannot re-introduce a level that an intermediate suppressed.

Intermediate libraries that depend on Swift Network should therefore not modify the default trait set when declaring the dependency. Specifying `DisableDebugLogging` or `DisableErrorLogging` in a library's `Package.swift` would force the corresponding levels to be suppressed for every leaf application that consumes the library, regardless of what those leaves want. The choice belongs to the leaf, where the deployment context is known.

A dependent package opts in to suppression when declaring the dependency, e.g. to compile out all logging:

```swift
.package(
    url: "https://github.com/apple/swift-network-evolution",
    branch: "main",
    traits: ["DisableDebugLogging", "DisableErrorLogging"]
)
```

When building this package directly, the `swift` CLI accepts the same traits:

```
swift test --traits DisableDebugLogging,DisableErrorLogging
```

### QUIC Logs

QUIC log output in the [qlog](https://datatracker.ietf.org/doc/draft-ietf-quic-qlog-main-schema/) format is controlled by the `QlogOutput` trait, and `os_signpost` output by `SignpostOutput`. Both are *positive* traits and neither is in the default trait set, so qlog and signpost code is compiled out by default.

Either feature is enabled by specifying the trait when declaring the dependency:

```swift
.package(
    url: "https://github.com/apple/swift-network-evolution",
    branch: "main",
    traits: ["QlogOutput", "SignpostOutput"]
)
```

For builds driven by Xcode rather than SwiftPM, add the equivalent compilation condition to the relevant xcconfig:

```
OTHER_SWIFT_FLAGS = $(inherited) -DQlogOutput -DSignpostOutput
```

When building or running this package directly from the `swift` CLI, the same trait names are accepted via `--traits`:

```
swift build --traits QlogOutput,SignpostOutput
swift test --traits QlogOutput
swift run --traits QlogOutput QUICHandshake
```

Trait composition is by union across the dependency graph, so once any package in the chain enables `QlogOutput` or `SignpostOutput`, every other package consuming Swift Network through that graph will also be built with the trait specified. A leaf package cannot suppress qlog or signpost output that an intermediate dependency turned on.

Intermediate libraries should not specify `QlogOutput` or `SignpostOutput` on their Swift Network dependency. These are diagnostic features which incur a performance cost; the decision to enable them belongs to the leaf or to test and benchmark targets that need the output.

## Performance Benchmarking Tools

This package builds several tools that can be used for benchmarking performance.

- `IPUDPTransfer` measures processing UDP/IP packets through the stack, for packet/second metrics.
- `QUICHandshake` measures parallel QUIC handshakes, for handshake/second metrics.
- `QUICStreamLoad` measures parallel data transfers over parallel QUIC streams, for requests/second metrics.
- `QUICTransfer` measures large data transfers over single QUIC streams, for throughput metrics.

## Contributing

The [Swift Network Contributing Guide](CONTRIBUTING.md) includes detailed information about participating in the project. 

We welcome the following contributions:
* Reporting bugs with clear, reproducible steps via [GitHub Issues](https://github.com/apple/swift-network-evolution/issues)
* Improving documentation to make the project more accessible
* Adding or enhancing tests to improve reliability and coverage
* Adding ports to new platforms
* Triaging issues by providing feedback, testing, and validation
* Participating in the [Networking category on the Swift Forums](https://forums.swift.org/c/development/networking/129)

Swift Network has a limited scope and is focused on supporting specific projects, such as QUIC in SwiftNIO. Please start with an Issue before opening a Pull Request that adds new functionality or expands the surface.
