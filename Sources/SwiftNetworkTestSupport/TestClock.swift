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

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Android)
internal import Android
#elseif canImport(Musl)
internal import Musl
#endif

/// The clock tests run on: a mock clock by default, or the system clock when a run asks for it.
@_spi(Essentials)
public enum TestClock {
    /// Whether tests run against the system clock.
    ///
    /// The `SWIFT_NETWORK_TEST_REAL_TIME` environment variable selects: `1` for the system clock,
    /// `0` for a mock clock, and anything else, or nothing, for `buildSelectsRealTime`.
    @_spi(Essentials)
    public static let usesRealTime: Bool = {
        guard let value = getenv("SWIFT_NETWORK_TEST_REAL_TIME") else {
            return buildSelectsRealTime
        }
        switch String(cString: value) {
        case "1": return true
        case "0": return false
        default: return buildSelectsRealTime
        }
    }()

    /// What the build asks for when the environment does not choose a clock: the system clock if
    /// `SWIFT_NETWORK_TEST_REAL_TIME` is defined, and a mock clock otherwise.
    ///
    /// The define is read here and nowhere else. Both clocks are always compiled, so neither can stop
    /// building unnoticed.
    private static let buildSelectsRealTime: Bool = {
        #if SWIFT_NETWORK_TEST_REAL_TIME
        return true
        #else
        return false
        #endif
    }()
}
