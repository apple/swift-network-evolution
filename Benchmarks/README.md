# Benchmarks

Allocation and ARC benchmarks for `swift-network`, built on
[package-benchmark](https://github.com/ordo-one/package-benchmark).

This is a separate SwiftPM package so that the benchmark dependency does not become a dependency of
the library. CI runs it through the `benchmarks` job in `.github/workflows/pull_request.yml`.

Each scenario counts allocations, ARC traffic and syscalls, and compares them with numbers checked
in under `Thresholds/`.

## Quick start

SwiftPM runs the benchmark plugin in a sandbox that cannot write to the package directory. A command
that writes files therefore needs `--allow-writing-to-package-directory`: `thresholds update` writes
`Thresholds/`, and `baseline update` writes `.benchmarkBaselines/`. Without the flag, `baseline
update` prints "Lacking permissions to write" and records nothing. Running, `thresholds check` and
`baseline compare` write nothing and need no flag. `package-benchmark` also documents
`--disable-sandbox`, as a workaround for benchmarks that use the network or hit disk-permission
failures; these benchmarks do neither, so no command here uses it.

Swift seeds its hash functions randomly for each process, which changes how many retains and
releases collection code performs. Set `SWIFT_DETERMINISTIC_HASHING=1` for every command here, as CI
does; counts recorded or checked without it vary from run to run.

```sh
export SWIFT_DETERMINISTIC_HASHING=1

# Run everything and print the numbers.
swift package --package-path Benchmarks benchmark

# One target, or one scenario (`--filter` takes a regex that must match the whole name).
swift package --package-path Benchmarks benchmark --target QUICBenchmarks
swift package --package-path Benchmarks benchmark --filter QUICHandshake

# Check against the recorded thresholds, as CI does.
swift package --package-path Benchmarks benchmark thresholds check \
    --format metricP90AbsoluteThresholds --path Benchmarks/Thresholds/latest-beta/

# Record the current numbers, after a change you have decided is correct.
swift package --package-path Benchmarks --allow-writing-to-package-directory \
    benchmark thresholds update \
    --format metricP90AbsoluteThresholds --path Benchmarks/Thresholds/latest-beta/
```

`--path` is resolved against the directory you run the command from, which is why it repeats
`Benchmarks/`. It must name the directory of the toolchain whose numbers you are checking against.
Use `Thresholds/latest-beta/` for local runs on a Mac; it holds the macOS numbers. A toolchain with
no directory has nothing to check against.

When the check fails with `is BETTER than the defined absolute baseline thresholds`, record the new
number; do not widen the tolerance. See [The check is two-sided](#the-check-is-two-sided).

To add a scenario, see [Adding a scenario](#adding-a-scenario).

Each benchmark target is an ordinary executable, so to profile one with an external tool such as
Instruments, build it in release mode and launch the binary from the tool. The
`DisableDebugLogging` and `DisableErrorLogging` traits are enabled by `Benchmarks/Package.swift`, so
this build has them without extra flags:

```sh
swift build --package-path Benchmarks -c release --product QUICBenchmarks
# The binary is at Benchmarks/.build/release/QUICBenchmarks.
```

## Thresholds

We use thresholds for deterministic counters:

| Metric | Why |
| --- | --- |
| `mallocCountTotal` | The headline number. |
| `objectAllocCount`, `retainCount`, `releaseCount` | ARC traffic and allocation count move independently. Code can allocate nothing and still burn millions of retain/release pairs, and an allocation counter would call that clean. |
| `syscalls`, `writeSyscalls` | This harness has no socket, so a step change is what "something on this path started doing I/O" looks like. `writeSyscalls` is gated by `QUICBenchmarks` only. |

Every tolerance is an absolute count, in the units stored in `Thresholds/`:

| Target | `mallocCountTotal` | `objectAllocCount` | `retainCount`, `releaseCount` | `syscalls`, `writeSyscalls` |
| --- | ---: | ---: | ---: | ---: |
| `QUICBenchmarks` | 2 | 2 | 4 (32 for `QUICConnectionSetup`, `QUICHandshake` and `QUICStreamEcho_16KB_with_loss`) | 50 |
| `SwiftNetworkCoreBenchmarks` | 50 | 0 | 0 | 50 |

The tolerances are in `Benchmarks.swift` for each target: `Allowances` for `QUICBenchmarks` and
`tolerance` for `SwiftNetworkCoreBenchmarks`. `QUICStreamEcho_*` and `QUICStreamChurn` run 1,000
operations per measurement, so their allowances and their files in `Thresholds/` are totals over
1,000 operations, and the files hold about 1,000 times the per-operation counts that `benchmark`
prints.

For a one-off comparison of e.g. timing, `--metric` overrides the list for that run without
touching the thresholds:

```sh
swift package --package-path Benchmarks benchmark --metric wallClock
swift package --package-path Benchmarks benchmark --metric instructions
```

### Why the numbers are checked in

`Thresholds/` holds one JSON file per benchmark per toolchain, for example
`Thresholds/6.4/QUICBenchmarks.QUICHandshake.p90.json`. Each file records the p90 for the gated
metrics. These files are used as the baseline when checking for deltas.

### The check is intentionally two-sided

`thresholds check` fails when a benchmark gets **better** as well as when it gets worse. That is not
a bug to work around.

Code improves and without updates to the threshold, the measured count drifts lower meaning a
future regression that nothing catches. Failing on improvement forces the ceiling down to whatever
the code actually costs now, so the gate keeps its resolution.

## Adding a scenario

1. Add a `Benchmark(...)` to the target's `Benchmarks.swift`. In `QUICBenchmarks`, build its
   configuration with `configuration(scalingFactor:maxDuration:maxIterations:allowances:)`; in
   `SwiftNetworkCoreBenchmarks`, with the local `configuration(scalingFactor:)`.
2. Keep setup outside the measurement window. In QUIC scenarios that means building the loopback
   and finishing the handshake before `benchmark.startMeasurement()`; per-iteration setup, as in
   `QUICHandshake`, is part of what the scenario measures.
3. Run it, and check the p0 to p100 spread is as small as the other scenarios'. A scenario whose
   count moves between runs cannot be gated. `Benchmarks/Scripts/measure-spread.sh` records the
   thresholds several times and prints how far each metric moved across the runs.
4. Record its thresholds with `thresholds update`, and add the new file to the commit.

## Baselines per toolchain

An allocation count is a property of the tuple (source, compiler, standard library, libc, operating
system), not of the source alone. A single shared ceiling either fails on the oldest supported
compiler or stops catching anything on the newest.

So `Thresholds/` has one directory per toolchain. Adding a toolchain to the benchmark matrix means
adding a directory, and bumping a toolchain means re-recording. Skipping a re-baseline is how a
suite stops working.

| Directory | Contents | Used by |
| --- | --- | --- |
| `Thresholds/latest-beta/` | Recorded on macOS 26, arm64, with a Swift 6.5 toolchain | Local runs on an Apple-silicon Mac, and the macOS `latest-beta` CI job |
| `Thresholds/6.4/` | Copy of `latest-beta/`, not yet recorded on Linux | The Linux `6.4` CI job |
| `Thresholds/nightly-release/` | Copy of `latest-beta/`, not yet recorded on Linux | The Linux job on the nightly for the upcoming release |
| `Thresholds/nightly-main/` | Copy of `latest-beta/`, not yet recorded on Linux | The Linux `nightly-main` CI job |

### CI

The `benchmarks-linux` and `benchmarks-macos` jobs call the shared
[`swiftlang/github-workflows`](https://github.com/swiftlang/github-workflows) `benchmarks.yml`
workflow, which runs `.github/workflows/scripts/check-benchmark-thresholds.sh` once per toolchain in
the matrix. The script runs `thresholds check` against `Benchmarks/Thresholds/<version>/`. If that
fails, it runs `thresholds update` to tell a regression from a build failure, and prints the
recalculated numbers as a diff after a `=== BEGIN DIFF (Benchmarks) ===` marker in the job log. To
correct a baseline, open the failed job, apply that diff to `Thresholds/<version>/`, and commit it.

The threshold path has no operating-system component, so Linux and macOS jobs on the same Swift
version would expect different numbers in the same files. The macOS job therefore names an Xcode
(`macos_xcode_versions`) rather than a Swift version, which makes its directory the Xcode version
instead of a Swift version, and the two operating systems never share one.

## How the package is wired

`QUICBenchmarks` depends on three products of the library package, which it reaches through a path
dependency:

- `SwiftNetwork`, the stack under test.
- `SwiftNetworkTestSupport`, which provides `ManualTimeContext` and `ManualScheduler`, so the
  benchmark owns the clock.
- `SwiftNetworkTestHarness`, which provides the stream and datagram harness types the loopback
  attaches to QUIC.

The `DisableDebugLogging` and `DisableErrorLogging` traits are enabled by default in the package manifest.
