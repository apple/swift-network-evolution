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

    /// A structure that identifies the protocol instance and holds a reference to its containing object.
    var identifier: InstanceIdentifier { get set }

    /// An opaque structure that tracks the internal consistency of any protocol.
    var eventManager: ProtocolEventManager { get set }
}

@available(Network 0.1.0, *)
extension ProtocolInstance where Self: ~Copyable {

    /// Removes this instance's event state from its context.
    ///
    /// Every protocol instance registers an event state when it builds its identifier, and that
    /// state has to be handed back before the instance goes away. A protocol that sits below
    /// another one is unregistered by its lower linkage's `teardown(in:)` as part of being
    /// detached from above, so it never needs to call this. Anything that isn't torn down that
    /// way — a top protocol, or an instance that a linkage doesn't own storage for, such as
    /// an encryption-level handler — must call this itself while tearing down. Not calling it
    /// trips a precondition when the instance is destroyed.
    ///
    /// Safe to call from inside a call this instance is already handling: the event state is only
    /// removed once nothing still holds it, so a retirement requested mid-call runs as the tail of
    /// the work already in flight.
    public mutating func unregisterEventManager(in eventContext: inout NetworkContext.EventContext) {
        eventManager.unregister(in: &eventContext)
        identifier = .init()
    }
}

@available(Network 0.1.0, *)
extension ProtocolInstance where Self: AnyObject {

    /// Removes this instance's event state from its context.
    ///
    /// Class-based instances are usually held through an immutable reference, so this overload
    /// takes `self` non-mutating; see `unregisterEventManager(in:)` on `ProtocolInstance`.
    public func unregisterEventManager(in eventContext: inout NetworkContext.EventContext) {
        var mutableSelf = self
        mutableSelf.eventManager.unregister(in: &eventContext)
        mutableSelf.identifier = .init()
    }
}

@available(Network 0.1.0, *)
extension ProtocolInstance where Self: ~Copyable {

    /// Schedules an asynchronous block from within a protocol implementation.
    ///
    /// The block runs later as a fresh entry into the stack, so it receives the event context
    /// and must thread it into any calls made to other protocols.
    ///
    /// This is an external entry point: call it from code outside the protocol stack. If you
    /// already hold the event context, call the `in:`-taking variant instead so the state
    /// isn't re-derived from the context.
    public func async(_ block: @escaping (inout NetworkContext.EventContext) -> Void) {
        identifier.async(context: context, in: &context.eventContext, block)
    }

    /// Schedules an asynchronous block, using an already-acquired event context.
    ///
    /// The block still receives the state that is current when it runs; see `async(_:)`.
    public func async(
        in eventContext: inout NetworkContext.EventContext,
        _ block: @escaping (inout NetworkContext.EventContext) -> Void
    ) {
        identifier.async(context: context, in: &eventContext, block)
    }

    /// Enters a protocol's execution state from an external source.
    ///
    /// Call this on the context, and call it before the protocol invokes any calls to other protocols.
    /// The block receives the event context, which must be threaded into any calls made to other
    /// protocols so that the state is never re-derived from the context class.
    public func fromExternal<R, E: Error>(
        _ block: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        try identifier.fromExternal(in: &context.eventContext, block)
    }
    public func fromExternal<R: ~Copyable, E: Error>(
        _ block: (inout NetworkContext.EventContext) throws(E) -> R
    ) throws(E) -> R {
        try identifier.fromExternal(in: &context.eventContext, block)
    }
    public func fromExternal<R, T: ~Copyable, E: Error>(
        _ value: consuming T,
        _ block: (inout NetworkContext.EventContext, consuming T) throws(E) -> R
    ) throws(E) -> R {
        try identifier.fromExternal(value, in: &context.eventContext, block)
    }
}

// MARK: Timer Schedulable

/// Indicates that a network protocol can be scheduled using a timer.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol TimerSchedulable: ~Copyable, ProtocolInstance {
    /// Handles a wakeup from a timer.
    ///
    /// The timer is an entry point into the stack, so the framework acquires the event context
    /// and hands it in. Thread it into any calls made to other protocols.
    func wakeup(in eventContext: inout NetworkContext.EventContext)

    /// A reference for a timer, which should be initialized as `TimerReference()`
    var timerReference: TimerReference { get }
}

@available(Network 0.1.0, *)
extension TimerSchedulable {
    /// Schedules a timer wakeup.
    ///
    /// This is an external entry point; see `async(_:)`.
    public func scheduleWakeup(after delay: NetworkDuration) {
        fromExternal { eventContext in
            scheduleWakeup(after: delay, in: &eventContext)
        }
    }

    /// Schedules a timer wakeup, using an already-acquired event context.
    public func scheduleWakeup(after delay: NetworkDuration, in eventContext: inout NetworkContext.EventContext) {
        identifier.scheduleWakeup(
            context: context,
            after: delay,
            timerReference: timerReference,
            in: &eventContext
        ) { timerState in
            self.wakeup(in: &timerState)
        }
    }

    /// Unschedules a timer wakeup.
    ///
    /// This is an external entry point; see `async(_:)`.
    public func unscheduleWakeup() {
        identifier.unscheduleWakeup(timerReference: timerReference, in: &context.eventContext)
    }

    /// Unschedules a timer wakeup, using an already-acquired event context.
    public func unscheduleWakeup(in eventContext: inout NetworkContext.EventContext) {
        identifier.unscheduleWakeup(timerReference: timerReference, in: &eventContext)
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
    @inline(always)
    public func info(_ message: @autoclosure () -> String) {}

    @inline(always)
    public func debug(_ message: @autoclosure () -> String) {}

    @inline(always)
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
    @inline(always)
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
    @inline(always)
    public func datapath(_ message: @autoclosure () -> String, callingFunction: StaticString = #function) {}
    #endif

    #endif
    #endif

    #if DisableErrorLogging
    @inline(always)
    public func notice(_ message: @autoclosure () -> String) {}

    @inline(always)
    public func error(_ message: @autoclosure () -> String) {}

    @inline(always)
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

// MARK: Protocol Instance As Linkage

@available(Network 0.1.0, *)
internal struct ProtocolInstanceBox<Instance: AnyObject>: Hashable {
    let instance: Instance

    init(_ instance: Instance) {
        self.instance = instance
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instance === rhs.instance
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(instance))
    }
}

/// Mark on protocols to allow them to be represented as their own linkage types

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public protocol ProtocolInstanceAsLinkage: ProtocolInstance, AnyObject, ProtocolLinkage {}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension ProtocolInstanceAsLinkage {

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: Protocol Instance Errors

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public enum ProtocolInstanceError: Error {
    case invalidUpperProtocol
    case invalidLowerProtocol
    case invalidNewFlowLinkage
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
extension Parameters {
    public func applicationOptions(for instance: InstanceIdentifier) -> ProtocolStack.ApplicationProtocol? {
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

    public func transportOptions(for instance: InstanceIdentifier) -> ProtocolStack.TransportProtocol? {
        let stack = self.defaultStack
        guard let transportProtocol = stack.transport, transportProtocol.matches(protocolInstance: instance) else {
            return nil
        }
        return transportProtocol
    }

    public func internetOptions(for instance: InstanceIdentifier) -> ProtocolStack.InternetProtocol? {
        let stack = self.defaultStack
        guard let internetProtocol = stack.internet, internetProtocol.matches(protocolInstance: instance) else {
            return nil
        }
        return internetProtocol
    }

    public func linkOptions(for instance: InstanceIdentifier) -> ProtocolStack.LinkProtocol? {
        let stack = self.defaultStack
        guard let linkProtocol = stack.link, linkProtocol.matches(protocolInstance: instance) else {
            return nil
        }
        return linkProtocol
    }

    #if !NETWORK_EMBEDDED
    internal func protocolOptions(for identifier: ProtocolIdentifier) -> AbstractProtocolOptions? {
        self.defaultStack.protocolOptions(for: identifier)
    }

    internal func protocolOptions(for instance: InstanceIdentifier) -> AbstractProtocolOptions? {
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

    public func protocolOptions<T>(for instance: InstanceIdentifier) -> ProtocolOptions<T>? {
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
        _ instance: InstanceIdentifier,
        for handle: UnsafeRawPointer
    ) {
        self.defaultStack.setProtocolInstance(instance, for: handle)
    }
    #endif

    #if !NETWORK_NO_SWIFT_QUIC
    public func quicOptions(for instance: InstanceIdentifier) -> ProtocolOptions<QUICProtocol>? {
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

    public func tlsOptions(for instance: InstanceIdentifier) -> ProtocolOptions<SwiftTLSProtocol>? {
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

    public func udpOptions(for instance: InstanceIdentifier) -> ProtocolOptions<UDPProtocol>? {
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

    public func ipOptions(for instance: InstanceIdentifier) -> ProtocolOptions<IPProtocol>? {
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

    public func customLinkOptions(for instance: InstanceIdentifier) -> ProtocolOptions<CustomLinkProtocol>? {
        if case .customLink(let options) = self.defaultStack.link {
            // The link slot holds exactly one protocol, so options that have not yet
            // been associated with an instance are unambiguously these options.
            if options.protocolInstance == nil || options.matches(protocolInstance: instance) {
                return options
            }
        }
        #if NETWORK_EMBEDDED
        return nil
        #else
        return self.protocolOptions(for: instance)
        #endif
    }
}
