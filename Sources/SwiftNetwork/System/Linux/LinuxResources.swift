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

#if os(Linux) || os(Android)
#if canImport(Glibc)
import Glibc
internal import SwiftNetworkLinuxShim
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
internal import SwiftNetworkLinuxShim
#endif

/// A set of Linux system APIs for interacting with the system resources.
internal enum SystemResources {
    #if canImport(Android)
    static func getFDLimit() -> UInt64 {
        var existing = rlimit()
        if getrlimit(RLIMIT_NOFILE, &existing) == 0 {
            return UInt64(existing.rlim_cur)
        }
        return 0
    }
    #else
    static func getFDLimit() -> UInt64 {
        SwiftNetworkLinuxShim_getFDLimit()
    }
    #endif
}

#endif
