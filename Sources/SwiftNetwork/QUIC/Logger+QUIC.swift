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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// This class won't be shared across thread boundaries.
@available(Network 0.1.0, *)
final class LogPrefixer: @unchecked Sendable {
    var log: NetworkLoggerState
    var logIDString: String {
        get {
            log.logPrefix
        }
        set {
            log.logPrefix = log.logPrefix + newValue
        }
    }
    init(_ logPrefix: String = "") {
        self.log = NetworkLoggerState(logPrefix)
    }

    #if DisableDebugLogging
    @inline(always)
    public func info(_ message: @autoclosure () -> String) {}

    @inline(always)
    public func debug(_ message: @autoclosure () -> String) {}

    @inline(always)
    public func datapath(_ message: @autoclosure () -> String) {}
    #else
    #if !NETWORK_EMBEDDED
    public func info(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        log.info(message(), callingFunction: callingFunction)
    }
    public func debug(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        log.debug(message(), callingFunction: callingFunction)
    }
    public func datapath(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        log.datapath(message(), callingFunction: callingFunction)
    }
    #else
    public func info(_ message: String, callingFunction: StaticString = #function) {
        log.info(message, callingFunction: callingFunction)
    }
    public func debug(_ message: String, callingFunction: StaticString = #function) {
        log.debug(message, callingFunction: callingFunction)
    }
    public func datapath(_ message: String, callingFunction: StaticString = #function) {
        log.datapath(message, callingFunction: callingFunction)
    }
    #endif
    #endif

    #if DisableErrorLogging
    @inline(always)
    public func fault(_ message: @autoclosure () -> String) {}

    @inline(always)
    public func error(_ message: @autoclosure () -> String) {}

    @inline(always)
    public func notice(_ message: @autoclosure () -> String) {}
    #else
    #if !NETWORK_EMBEDDED
    public func fault(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        log.fault(message(), callingFunction: callingFunction)
    }
    public func error(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        log.error(message(), callingFunction: callingFunction)
    }
    public func notice(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        log.notice(message(), callingFunction: callingFunction)
    }
    #else
    public func fault(_ message: String, callingFunction: StaticString = #function) {
        log.fault(message, callingFunction: callingFunction)
    }
    public func error(_ message: String, callingFunction: StaticString = #function) {
        log.error(message, callingFunction: callingFunction)
    }
    public func notice(_ message: String, callingFunction: StaticString = #function) {
        log.notice(message, callingFunction: callingFunction)
    }
    #endif
    #endif
}

#if !NETWORK_NO_SWIFT_QUIC
@available(Network 0.1.0, *)
protocol PrefixedLoggable: ~Copyable {
    var log: LogPrefixer { get }
}
#endif
