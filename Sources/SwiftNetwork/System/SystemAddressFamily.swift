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

#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif !NETWORK_STANDALONE
import Darwin
#endif

enum AddressFamily: UInt8, Sendable {
    case unspecified = 0
    case ipv4 = 2
    #if os(Linux) || os(Android)
    case ipv6 = 10  // AF_INET6 is 10 on Linux
    #else
    case ipv6 = 30
    #endif
    case unix = 1
    #if os(Linux) || os(Android)
    case route = 16  // AF_ROUTE is 16 on Linux
    #else
    case route = 17
    #endif

    init(value: UInt8) {
        switch value {
        case 0: self = .unspecified
        case 2: self = .ipv4
        // AF_INET6 is different across platforms
        #if os(Linux) || os(Android)
        case 10: self = .ipv6
        #else
        case 30: self = .ipv6
        #endif
        case 1: self = .unix
        // AF_ROUTE is different across platforms
        #if os(Linux) || os(Android)
        case 16: self = .route
        #else
        case 17: self = .route
        #endif
        default: fatalError("Invalid Address Family specified")
        }
    }
}
