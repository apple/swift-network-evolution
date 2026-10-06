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
internal import Logging
#elseif canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if os(Linux) || os(Android) || (NETWORK_EMBEDDED && !NETWORK_DRIVERKIT)
extension Logger {

    #if DisableDebugLogging
    // Specify the `DisableDebugLogging` trait to compile out info, debug, and datapath logging.
    static let swiftNetworkProtocolLoggingEnabled: Bool = false
    static let swiftNetworkDatapathLoggingEnabled: Bool = false
    #else
    static let swiftNetworkProtocolLoggingEnabled: Bool = true
    #if DatapathLogging
    static let swiftNetworkDatapathLoggingEnabled: Bool = true
    #else
    static let swiftNetworkDatapathLoggingEnabled: Bool = false
    #endif
    #endif

    static let interface = Logger(label: "com.apple.network.interface")
    static let system = Logger(label: "com.apple.network.system")
    static let proto = Logger(label: "com.apple.network.protocol")
    static let path = Logger(label: "com.apple.network.path")
    static let endpoint = Logger(label: "com.apple.network.endpoint")
    static let parameters = Logger(label: "com.apple.network.parameters")
    static let connection = Logger(label: "com.apple.network.connection")
    static let listener = Logger(label: "com.apple.network.listener")
    static let tls = Logger(label: "com.apple.security.swifttls")
    static let migration = Logger(label: "com.apple.network.migration")
    #if !NETWORK_EMBEDDED
    func fault(_ message: String) {
        Logger.system.critical("\(message)")
    }
    #endif
}
#endif

#if canImport(os) || NETWORK_DRIVERKIT
// Availability due to `os`'s `Logger`
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
extension Logger {

    #if DisableDebugLogging
    // Specify the `DisableDebugLogging` trait to compile out info, debug, and datapath logging.
    static let swiftNetworkProtocolLoggingEnabled: Bool = false
    static let swiftNetworkDatapathLoggingEnabled: Bool = false
    #else
    static let swiftNetworkProtocolLoggingEnabled: Bool = true
    #if DatapathLogging
    static let swiftNetworkDatapathLoggingEnabled: Bool = true
    #else
    static let swiftNetworkDatapathLoggingEnabled: Bool = false
    #endif
    #endif

    static let system = Logger(subsystem: "com.apple.network", category: "system")
    static let interface = Logger(subsystem: "com.apple.network", category: "interface")
    static let proto = Logger(subsystem: "com.apple.network", category: "protocol")
    static let path = Logger(subsystem: "com.apple.network", category: "path")
    static let endpoint = Logger(subsystem: "com.apple.network", category: "endpoint")
    static let parameters = Logger(subsystem: "com.apple.network", category: "parameters")
    static let connection = Logger(subsystem: "com.apple.network", category: "connection")
    static let listener = Logger(subsystem: "com.apple.network", category: "listener")
    static let tls = Logger(subsystem: "com.apple.security.swifttls", category: "SwiftTLSProtocol")
    static let migration = Logger(subsystem: "com.apple.network", category: "migration")
}
#endif
