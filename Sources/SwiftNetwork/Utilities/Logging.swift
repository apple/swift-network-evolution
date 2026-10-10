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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
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

// MARK: - Reporting from small functions

// Building a log message is many times the size of the arithmetic a small function performs, and
// that code counts against the inliner's budget and occupies instruction footprint on the hot path
// whether or not the message is ever emitted. A function that reports an unexpected condition
// inline therefore stops being inlinable, and its callers pay for a diagnostic they never see.
//
// Reporting through these helpers keeps the message, and the logging metadata and
// once-initialisation with it, in one out-of-line place. Callers keep a compare and a branch.
// The names say so: being out of line is the point, not an implementation detail. They also
// name the category, because a helper that defaulted to one would quietly send a diagnostic
// from another subsystem to the wrong place. Passing the `Logger` instead would materialise it
// at the call site, which is the cost these helpers exist to avoid.
//
// The message is a `StaticString` so nothing is interpolated at the call site, and the values are
// parameters rather than an autoclosure, which would put the interpolation back in the caller.
//
// `DisableErrorLogging` and `DisableDebugLogging` empty the body and switch the helper to
// `@inline(always)`, so a disabled level leaves nothing at all behind.

#if os(Linux) || os(Android) || (NETWORK_EMBEDDED && !NETWORK_DRIVERKIT) || canImport(os) || NETWORK_DRIVERKIT
#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogError(_ message: StaticString) {
    #if !DisableErrorLogging
    Logger.proto.error("\(message)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogError<Value: FixedWidthInteger>(
    _ message: StaticString,
    _ value: Value
) {
    #if !DisableErrorLogging
    Logger.proto.error("\(message): \(value)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogError<First: FixedWidthInteger, Second: FixedWidthInteger>(
    _ message: StaticString,
    _ first: First,
    _ second: Second
) {
    #if !DisableErrorLogging
    Logger.proto.error("\(message): \(first), \(second)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogError<First: FixedWidthInteger, Second: FixedWidthInteger, Third: FixedWidthInteger>(
    _ message: StaticString,
    _ first: First,
    _ second: Second,
    _ third: Third
) {
    #if !DisableErrorLogging
    Logger.proto.error("\(message): \(first), \(second), \(third)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogFault(_ message: StaticString) {
    #if !DisableErrorLogging
    Logger.proto.fault("\(message)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogFault<Value: FixedWidthInteger>(
    _ message: StaticString,
    _ value: Value
) {
    #if !DisableErrorLogging
    Logger.proto.fault("\(message): \(value)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogFault<First: FixedWidthInteger, Second: FixedWidthInteger>(
    _ message: StaticString,
    _ first: First,
    _ second: Second
) {
    #if !DisableErrorLogging
    Logger.proto.fault("\(message): \(first), \(second)")
    #endif
}

#if DisableErrorLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogFault<First: FixedWidthInteger, Second: FixedWidthInteger, Third: FixedWidthInteger>(
    _ message: StaticString,
    _ first: First,
    _ second: Second,
    _ third: Third
) {
    #if !DisableErrorLogging
    Logger.proto.fault("\(message): \(first), \(second), \(third)")
    #endif
}

#if DisableDebugLogging
@inline(always)
#else
@inline(never)
#endif
@available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
func outlinedProtoLogInfo(_ message: StaticString) {
    #if !DisableDebugLogging
    Logger.proto.info("\(message)")
    #endif
}
#endif
