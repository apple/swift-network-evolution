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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// MARK: Protocol Instance

/// The base Swift protocol for any networking protocol instance you can connect in a stack.
///
/// Most protocols conform to either `OneToOneProtocolHandler`
/// or `ManyToManyProtocolHandler`. Protocols that occupy only the top or bottom of
/// a stack conform to `UpperProtocolHandler` or `LowerProtocolHandler`.
///
/// For data handling, see `ProtocolDatagramHandlers` and `ProtocolStreamHandlers`.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ProtocolInstance: ~Copyable {

    /// The scheduling context on which the protocol instance must run.
    var context: NetworkContext { get }

    /// A structure that refers to the protocol instance and holds a reference to its containing object.
    var reference: ProtocolInstanceReference { get }

    /// An opaque structure that tracks the internal consistency of any protocol.
    var eventManager: ProtocolEventManager { get set }
}

@available(Network 0.1.0, *)
extension ProtocolInstance where Self: ~Copyable {

    /// Schedules an asynchronous block from within a protocol implementation.
    public func async(_ block: @escaping () -> Void) {
        reference.async(block)
    }

    /// Enters a protocol's execution state from an external source.
    ///
    /// Call this on the context, and call it before the protocol invokes any calls to other protocols.
    public func fromExternal<R, E: Error>(_ block: () throws(E) -> R) throws(E) -> R {
        try reference.fromExternal(block)
    }
    public func fromExternal<R: ~Copyable, E: Error>(_ block: () throws(E) -> R) throws(E) -> R {
        try reference.fromExternal(block)
    }
    public func fromExternal<R, T: ~Copyable, E: Error>(
        _ value: consuming T,
        _ block: (consuming T) throws(E) -> R
    ) throws(E) -> R {
        try reference.fromExternal(value, block)
    }
}

// MARK: Timer Schedulable

/// Indicates that a network protocol can be scheduled using a timer.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TimerSchedulable: ~Copyable, ProtocolInstance {
    /// Handles a wakeup from a timer.
    func wakeup()

    /// A reference for a timer, which should be initialized as `TimerSchedulable()`
    var timerReference: TimerReference { get }
}

@available(Network 0.1.0, *)
extension TimerSchedulable {
    public func scheduleWakeup(after delay: NetworkDuration) {
        reference.scheduleWakeup(after: delay, timerReference: timerReference)
    }

    public func unscheduleWakeup() {
        reference.unscheduleWakeup(timerReference: timerReference)
    }
}

// MARK: Loggable Protocol

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol LoggableProtocol: ~Copyable, ProtocolInstance {
    var log: NetworkLoggerState { get set }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct NetworkLoggerState: ~Copyable {
    public var logPrefix: String

    public init(_ prefix: String = "") {
        logPrefix = prefix
    }

    #if DisableDebugLogging
    @inline(__always)
    public func info(_ message: @autoclosure () -> String) {}

    @inline(__always)
    public func debug(_ message: @autoclosure () -> String) {}

    @inline(__always)
    public func datapath(_ message: @autoclosure () -> String) {}
    #else
    #if !NETWORK_EMBEDDED
    public func info(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        if !Logger.swiftNetworkProtocolLoggingEnabled {
            return
        }
        let logPrefix = logPrefix
        let message = message()
        Logger.proto.info("\(callingFunction) \(logPrefix) \(message)")
    }
    public func debug(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        if !Logger.swiftNetworkProtocolLoggingEnabled {
            return
        }
        let logPrefix = logPrefix
        let message = message()
        Logger.proto.debug("\(callingFunction) \(logPrefix) \(message)")
    }
    #if !NETWORK_PRIVATE
    #if DatapathLogging
    public func datapath(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        if !Logger.swiftNetworkDatapathLoggingEnabled {
            return
        }
        let logPrefix = logPrefix
        let message = message()
        Logger.proto.debug("\(callingFunction) \(logPrefix) \(message)")
    }
    #else
    @inline(__always)
    public func datapath(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {}
    #endif
    #endif
    #else
    public func info(_ message: String, callingFunction: StaticString = #function) {
        if !Logger.swiftNetworkProtocolLoggingEnabled {
            return
        }
        let logPrefix = logPrefix
        Logger.proto.info("\(callingFunction) \(logPrefix) \(message)")
    }

    public func debug(_ message: String, callingFunction: StaticString = #function) {
        if !Logger.swiftNetworkProtocolLoggingEnabled {
            return
        }
        let logPrefix = logPrefix
        Logger.proto.debug("\(callingFunction) \(logPrefix) \(message)")
    }

    #if DatapathLogging
    public func datapath(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        if !Logger.swiftNetworkDatapathLoggingEnabled {
            return
        }
        let logPrefix = logPrefix
        let message = message()
        Logger.proto.debug("\(callingFunction) \(logPrefix) \(message)")
    }
    #else
    @inline(__always)
    public func datapath(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {}
    #endif

    #endif
    #endif

    #if DisableErrorLogging
    @inline(__always)
    public func notice(_ message: @autoclosure () -> String) {}

    @inline(__always)
    public func error(_ message: @autoclosure () -> String) {}

    @inline(__always)
    public func fault(_ message: @autoclosure () -> String) {}
    #else
    #if !NETWORK_EMBEDDED
    public func fault(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        let logPrefix = logPrefix
        let message = message()
        Logger.proto.fault("\(callingFunction) \(logPrefix) \(message)")
    }
    public func error(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        let logPrefix = logPrefix
        let message = message()
        Logger.proto.error("\(callingFunction) \(logPrefix) \(message)")
    }
    public func notice(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {
        let logPrefix = logPrefix
        let message = message()
        #if os(Linux)
        Logger.proto.notice("\(callingFunction) \(logPrefix) \(message)")
        #else
        Logger.proto.log("\(callingFunction) \(logPrefix) \(message)")
        #endif
    }
    #else
    public func fault(_ message: String, callingFunction: StaticString = #function) {
        let logPrefix = logPrefix
        Logger.proto.fault("\(callingFunction) \(logPrefix) \(message)")
    }

    public func error(_ message: String, callingFunction: StaticString = #function) {
        let logPrefix = logPrefix
        Logger.proto.error("\(callingFunction) \(logPrefix) \(message)")
    }

    public func notice(_ message: String, callingFunction: StaticString = #function) {
        let logPrefix = logPrefix
        #if os(Linux)
        Logger.proto.notice("\(callingFunction) \(logPrefix) \(message)")
        #else
        Logger.proto.log("\(callingFunction) \(logPrefix) \(message)")
        #endif
    }
    #endif
    #endif
}

// MARK: Protocol Instance Errors

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum ProtocolInstanceError: Error {
    case invalidUpperProtocol
    case invalidLowerProtocol
    case invalidNewFlowLinkage
}

// MARK: Protocol Instance Container

/// A container that hosts one or more custom protocol implementations.
///
/// Conform to `ProtocolInstanceContainer` to implement a custom protocol.
/// Use the index to host multiple protocols within one object.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ProtocolInstanceContainer: AnyObject {
    #if !NETWORK_EMBEDDED
    func accessInstance<R, E: Error>(at index: Int?, _ body: (inout any ProtocolInstance) throws(E) -> R) throws(E) -> R
    func accessTimerSchedulable<R, E: Error>(
        at index: Int?,
        _ body: (inout any TimerSchedulable) throws(E) -> R
    ) throws(E) -> R
    func accessLower<R, E: Error>(
        at index: Int?,
        _ body: (inout any LowerProtocolHandler) throws(E) -> R
    ) throws(E) -> R
    func accessUpper<R, E: Error>(
        at index: Int?,
        _ body: (inout any UpperProtocolHandler) throws(E) -> R
    ) throws(E) -> R
    func accessManyToMany<R, E: Error>(
        at index: Int?,
        _ body: (inout any ManyToManyProtocolHandler) throws(E) -> R
    ) throws(E) -> R
    func accessInboundFlowHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundFlowHandler) throws(E) -> R
    ) throws(E) -> R
    func accessListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any ListenerHandler) throws(E) -> R
    ) throws(E) -> R
    func accessDatagramListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any DatagramListenerHandler) throws(E) -> R
    ) throws(E) -> R
    func accessStreamListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any StreamListenerHandler) throws(E) -> R
    ) throws(E) -> R
    func accessInboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDataHandler) throws(E) -> R
    ) throws(E) -> R
    func accessInboundDatagramHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDatagramHandler) throws(E) -> R
    ) throws(E) -> R
    func accessInboundStreamHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundStreamHandler) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundDataHandler) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundDatagramHandler<R: ~Copyable, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundDatagramHandler) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundDatagramHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundDatagramHandler, consuming T) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundStreamHandler<R: ~Copyable, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundStreamHandler) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundStreamHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundStreamHandler, consuming T) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundStreamEarlyDataHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundStreamEarlyDataHandler, consuming T) throws(E) -> R
    ) throws(E) -> R
    func accessOutboundStreamUnidirectionalAbortHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundStreamUnidirectionalAbortHandler) throws(E) -> R
    ) throws(E) -> R
    #endif
}

#if !NETWORK_EMBEDDED
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer {
    public func accessLower<R, E: Error>(
        at index: Int?,
        _ body: (inout any LowerProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessTimerSchedulable<R, E: Error>(
        at index: Int?,
        _ body: (inout any TimerSchedulable) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessUpper<R, E: Error>(
        at index: Int?,
        _ body: (inout any UpperProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessManyToMany<R, E: Error>(
        at index: Int?,
        _ body: (inout any ManyToManyProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessInboundFlowHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundFlowHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any ListenerHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessDatagramListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any DatagramListenerHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessStreamListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any StreamListenerHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessInboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDataHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessInboundDatagramHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDatagramHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessInboundStreamHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundStreamHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundDataHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundDatagramHandler<R: ~Copyable, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundDatagramHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundDatagramHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundDatagramHandler, consuming T) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundStreamHandler<R: ~Copyable, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundStreamHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundStreamHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundStreamHandler, consuming T) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundStreamUnidirectionalAbortHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundStreamUnidirectionalAbortHandler) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
    public func accessOutboundStreamEarlyDataHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundStreamEarlyDataHandler, consuming T) throws(E) -> R
    ) throws(E) -> R {
        fatalError("Unimplemented container function")
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: ProtocolInstance {
    var reference: ProtocolInstanceReference { ProtocolInstanceReference(custom: self) }

    public func accessInstance<R, E: Error>(
        at index: Int?,
        _ body: (inout any ProtocolInstance) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any ProtocolInstance) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: LowerProtocolHandler {
    public func accessLower<R, E: Error>(
        at index: Int?,
        _ body: (inout any LowerProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any LowerProtocolHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: TimerSchedulable {
    public func accessTimerSchedulable<R, E: Error>(
        at index: Int?,
        _ body: (inout any TimerSchedulable) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any TimerSchedulable) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: UpperProtocolHandler {
    public func accessUpper<R, E: Error>(
        at index: Int?,
        _ body: (inout any UpperProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any UpperProtocolHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: ManyToManyProtocolHandler {
    public func accessManyToMany<R, E: Error>(
        at index: Int?,
        _ body: (inout any ManyToManyProtocolHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any ManyToManyProtocolHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: InboundFlowHandler {
    public func accessInboundFlowHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundFlowHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any InboundFlowHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: ListenerHandler {
    public func accessListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any ListenerHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any ListenerHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: DatagramListenerHandler {
    public func accessDatagramListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any DatagramListenerHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any DatagramListenerHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: StreamListenerHandler {
    public func accessStreamListenerHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any StreamListenerHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any StreamListenerHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: InboundDataHandler {
    public func accessInboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDataHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any InboundDataHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: InboundDatagramHandler {
    public func accessInboundDatagramHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundDatagramHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any InboundDatagramHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: InboundStreamHandler {
    public func accessInboundStreamHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any InboundStreamHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any InboundStreamHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: OutboundDataHandler {
    public func accessOutboundDataHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundDataHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundDataHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: OutboundDatagramHandler {
    public func accessOutboundDatagramHandler<R: ~Copyable, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundDatagramHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundDatagramHandler) = self
        return try body(&selfAccess)
    }
    public func accessOutboundDatagramHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundDatagramHandler, consuming T) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundDatagramHandler) = self
        return try body(&selfAccess, value)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: OutboundStreamHandler {
    public func accessOutboundStreamHandler<R: ~Copyable, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundStreamHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundStreamHandler) = self
        return try body(&selfAccess)
    }
    public func accessOutboundStreamHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundStreamHandler, consuming T) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundStreamHandler) = self
        return try body(&selfAccess, value)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: OutboundStreamUnidirectionalAbortHandler {
    public func accessOutboundStreamUnidirectionalAbortHandler<R, E: Error>(
        at index: Int?,
        _ body: (inout any OutboundStreamUnidirectionalAbortHandler) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundStreamUnidirectionalAbortHandler) = self
        return try body(&selfAccess)
    }
}
@available(Network 0.1.0, *)
extension ProtocolInstanceContainer where Self: OutboundStreamEarlyDataHandler {
    public func accessOutboundStreamEarlyDataHandler<R, T: ~Copyable, E: Error>(
        at index: Int?,
        _ value: consuming T,
        _ body: (inout any OutboundStreamEarlyDataHandler, consuming T) throws(E) -> R
    ) throws(E) -> R {
        var selfAccess: (any OutboundStreamEarlyDataHandler) = self
        return try body(&selfAccess, value)
    }
}
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension Parameters {
    public func applicationOptions(for instance: ProtocolInstanceReference) -> ProtocolStack.ApplicationProtocol? {
        let stack = self.defaultStack
        for applicationProtocol in stack.persistentApplication {
            if applicationProtocol.matches(protocolInstance: instance) {
                return applicationProtocol
            }
        }
        for applicationProtocol in stack.application {
            if applicationProtocol.matches(protocolInstance: instance) {
                return applicationProtocol
            }
        }
        return nil
    }

    public func transportOptions(for instance: ProtocolInstanceReference) -> ProtocolStack.TransportProtocol? {
        let stack = self.defaultStack
        guard let transportProtocol = stack.transport, transportProtocol.matches(protocolInstance: instance) else {
            return nil
        }
        return transportProtocol
    }

    public func internetOptions(for instance: ProtocolInstanceReference) -> ProtocolStack.InternetProtocol? {
        let stack = self.defaultStack
        guard let internetProtocol = stack.internet, internetProtocol.matches(protocolInstance: instance) else {
            return nil
        }
        return internetProtocol
    }

    #if !NETWORK_EMBEDDED
    internal func protocolOptions(for identifier: ProtocolIdentifier) -> AbstractProtocolOptions? {
        self.defaultStack.protocolOptions(for: identifier)
    }

    internal func protocolOptions(for instance: ProtocolInstanceReference) -> AbstractProtocolOptions? {
        self.defaultStack.protocolOptions(for: instance)
    }

    internal func protocolOptionsWithLevel(for handle: UnsafeRawPointer) -> (AbstractProtocolOptions, ProtocolLevel)? {
        self.defaultStack.protocolOptionsWithLevel(for: handle)
    }

    internal func protocolOptions(for handle: UnsafeRawPointer) -> AbstractProtocolOptions? {
        protocolOptionsWithLevel(for: handle)?.0 ?? nil
    }

    #if !NETWORK_PRIVATE
    internal func protocolOptions<T>(from options: AbstractProtocolOptions) -> ProtocolOptions<T>? {
        guard let options = options as? ProtocolOptions<T> else {
            return nil
        }
        return options
    }
    #endif

    public func protocolOptions<T>(for instance: ProtocolInstanceReference) -> ProtocolOptions<T>? {
        guard let options = self.protocolOptions(for: instance) else {
            return nil
        }
        return protocolOptions(from: options)
    }

    public func protocolOptions<T>(for handle: UnsafeRawPointer) -> ProtocolOptions<T>? {
        guard let options = self.protocolOptions(for: handle) else {
            return nil
        }
        return protocolOptions(from: options)
    }

    public func protocolOptions<T>(for handle: UnsafeRawPointer, type: T) -> ProtocolOptions<T>? {
        protocolOptions(for: handle)
    }

    public func setProtocolInstance(
        _ instance: ProtocolInstanceReference,
        for handle: UnsafeRawPointer
    ) {
        self.defaultStack.setProtocolInstance(instance, for: handle)
    }
    #endif

    #if !NETWORK_NO_SWIFT_QUIC
    public func quicOptions(for instance: ProtocolInstanceReference) -> ProtocolOptions<QUICProtocol>? {
        if let applicationProtocol = applicationOptions(for: instance),
            case .quic(let options) = applicationProtocol
        {
            return options
        } else if let transportProtocol = transportOptions(for: instance),
            case .quic(let options) = transportProtocol
        {
            return options
        }
        #if NETWORK_EMBEDDED
        return nil
        #else
        return self.protocolOptions(for: instance)
        #endif
    }
    #endif

    public func tlsOptions(for instance: ProtocolInstanceReference) -> ProtocolOptions<SwiftTLSProtocol>? {
        if let applicationProtocol = applicationOptions(for: instance),
            case .swiftTLS(let options) = applicationProtocol
        {
            return options
        }
        #if NETWORK_EMBEDDED
        return nil
        #else
        return self.protocolOptions(for: instance)
        #endif
    }

    public func udpOptions(for instance: ProtocolInstanceReference) -> ProtocolOptions<UDPProtocol>? {
        if let transportProtocol = transportOptions(for: instance),
            case .udp(let options) = transportProtocol
        {
            return options
        }
        #if NETWORK_EMBEDDED
        return nil
        #else
        return self.protocolOptions(for: instance)
        #endif
    }

    public func ipOptions(for instance: ProtocolInstanceReference) -> ProtocolOptions<IPProtocol>? {
        if let internetProtocol = internetOptions(for: instance),
            case .ip(let options) = internetProtocol
        {
            return options
        }
        #if NETWORK_EMBEDDED
        return nil
        #else
        return self.protocolOptions(for: instance)
        #endif
    }
}
