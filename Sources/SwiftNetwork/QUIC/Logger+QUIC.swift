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

@available(Network 0.1.0, *)
struct LogPrefixer {
    var logIDString: String

    init(_ logPrefix: String = "") {
        self.logIDString = logPrefix
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
        if !Logger.swiftNetworkProtocolLoggingEnabled {
            return
        }
        let logIDString = logIDString
        let message = message()
        Logger.proto.info("\(callingFunction) \(logIDString) \(message)")
    }
    public func debug(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        if !Logger.swiftNetworkProtocolLoggingEnabled {
            return
        }
        let logIDString = logIDString
        let message = message()
        Logger.proto.debug("\(callingFunction) \(logIDString) \(message)")
    }
    public func datapath(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        if !Logger.swiftNetworkDatapathLoggingEnabled {
            return
        }
        let logIDString = logIDString
        let message = message()
        Logger.proto.debug("\(callingFunction) \(logIDString) \(message)")
    }
    #else
    public func info(_ message: String, callingFunction: StaticString = #function) {
        Logger.proto.info(message, callingFunction: callingFunction)
    }
    public func debug(_ message: String, callingFunction: StaticString = #function) {
        Logger.proto.debug(message, callingFunction: callingFunction)
    }
    public func datapath(_ message: String, callingFunction: StaticString = #function) {
        Logger.proto.debug(message, callingFunction: callingFunction)
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
        let logIDString = logIDString
        let message = message()
        Logger.proto.fault("\(callingFunction) \(logIDString) \(message)")
    }
    public func error(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        let logIDString = logIDString
        let message = message()
        Logger.proto.error("\(callingFunction) \(logIDString) \(message)")
    }
    public func notice(
        _ message: @autoclosure () -> String,
        callingFunction: StaticString = #function
    ) {
        let logIDString = logIDString
        let message = message()
        #if os(Linux)
        Logger.proto.notice("\(callingFunction) \(logIDString) \(message)")
        #else
        Logger.proto.log("\(callingFunction) \(logIDString) \(message)")
        #endif
    }
    #else
    public func fault(_ message: String, callingFunction: StaticString = #function) {
        let logIDString = logIDString
        Logger.proto.fault("\(callingFunction) \(logIDString) \(message)")
    }
    public func error(_ message: String, callingFunction: StaticString = #function) {
        let logIDString = logIDString
        Logger.proto.error("\(callingFunction) \(logIDString) \(message)")
    }
    public func notice(_ message: String, callingFunction: StaticString = #function) {
        let logIDString = logIDString
        #if os(Linux)
        Logger.proto.notice("\(callingFunction) \(logIDString) \(message)")
        #else
        Logger.proto.log("\(callingFunction) \(logIDString) \(message)")
        #endif
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
