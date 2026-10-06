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
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
internal import SwiftNetworkLinuxShim

/// A set of Linux system APIs for interacting with the system resources.
internal enum SystemResources {

    static func getFDLimit() -> UInt64 {
        SwiftNetworkLinuxShim_getFDLimit()
    }
}

#endif
