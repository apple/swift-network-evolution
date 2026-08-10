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

#if canImport(Dispatch)
import Dispatch

/// Serial execution context for the networking stack, over `DispatchQueue`. Work and event
/// sources are created through the queue rather than a raw `DispatchQueue`.
///
/// Two backends: thread-backed dispatch, and an inline (no-thread) mode with a virtual clock
/// driven by `drain()` / `advance(byMilliseconds:)` for deterministic tests. Inline mode is a
/// single-threaded test tool: it must only be driven from one thread at a time.
@available(Network 0.1.0, *)
final class NetworkQueue: @unchecked Sendable {
    enum SourceType { case read, write, timer }

    private let dispatchQueue: DispatchQueue?
    private let specificKey = DispatchSpecificKey<ObjectIdentifier>()

    // Inline-mode state. Only touched while draining on the single driving thread.
    private var pending: [() -> Void] = []
    private var inlineSources: [NetworkQueueSource] = []
    private var virtualNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var pumping = false

    var isInline: Bool { dispatchQueue == nil }

    init(label: String) {
        let queue = DispatchQueue(label: label)
        self.dispatchQueue = queue
        queue.setSpecific(key: specificKey, value: ObjectIdentifier(self))
    }

    /// Creates an inline (no-thread) queue.
    init() {
        self.dispatchQueue = nil
    }

    /// Real time for dispatch, virtual time for inline.
    var now: DispatchTime {
        isInline ? DispatchTime(uptimeNanoseconds: virtualNanos) : .now()
    }

    var isCurrent: Bool {
        if isInline { return pumping }
        return DispatchQueue.getSpecific(key: specificKey) == ObjectIdentifier(self)
    }

    func async(_ block: @escaping () -> Void) {
        if let dispatchQueue {
            dispatchQueue.async(execute: DispatchWorkItem(block: block))
        } else {
            pending.append(block)
        }
    }

    func barrierAsync(_ block: @escaping () -> Void) {
        if let dispatchQueue {
            dispatchQueue.async(execute: DispatchWorkItem(flags: .barrier, block: block))
        } else {
            pending.append(block)
        }
    }

    /// Runs inline if already on the queue, otherwise enqueues.
    func asyncIfNeeded(_ block: @escaping () -> Void) {
        isCurrent ? block() : async(block)
    }

    func assertQueue() {
        if let dispatchQueue {
            dispatchPrecondition(condition: DispatchPredicate.onQueue(dispatchQueue))
        } else {
            precondition(pumping, "Not running on inline queue")
        }
    }

    // MARK: - Event sources

    /// Creates a suspended source. `fileDescriptor`/`mask` are unused for `.timer`.
    func createSource(
        _ type: SourceType,
        fileDescriptor: Int32 = -1,
        mask: UInt = 0,
        block: @escaping () -> Void,
        cancelBlock: (() -> Void)? = nil
    ) -> NetworkQueueSource {
        if let dispatchQueue {
            let source: any DispatchSourceProtocol
            switch type {
            case .read: source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: dispatchQueue)
            case .write: source = DispatchSource.makeWriteSource(fileDescriptor: fileDescriptor, queue: dispatchQueue)
            case .timer: source = DispatchSource.makeTimerSource(queue: dispatchQueue)
            }
            source.setEventHandler(handler: block)
            if let cancelBlock {
                source.setCancelHandler(handler: cancelBlock)
            }
            return NetworkQueueSource(dispatch: source)
        }
        // Inline mode has no kernel event delivery; only timers are supported.
        precondition(type == .timer, "Inline NetworkQueue supports only timer sources")
        let source = NetworkQueueSource(inlineTimerOn: self, block: block, cancelBlock: cancelBlock)
        inlineSources.append(source)
        return source
    }

    fileprivate func removeInlineSource(_ source: NetworkQueueSource) {
        inlineSources.removeAll { $0 === source }
    }

    // MARK: - Inline pump

    /// Runs pending work and fires timers due at the current virtual time.
    func drain() {
        guard isInline else { return }
        precondition(!pumping, "Reentrant or concurrent drain of inline NetworkQueue")
        pumping = true
        defer { pumping = false }
        while true {
            if !pending.isEmpty {
                pending.removeFirst()()
            } else if let timer = earliestDueTimer() {
                timer.fireInline()
            } else {
                break
            }
        }
    }

    func advance(byMilliseconds milliseconds: Int) {
        guard isInline else { return }
        virtualNanos &+= UInt64(milliseconds) * 1_000_000
        drain()
    }

    private func earliestDueTimer() -> NetworkQueueSource? {
        let deadline = now
        var earliest: NetworkQueueSource?
        for source in inlineSources where source.isDueTimer(at: deadline) {
            if earliest == nil || source.fireTime < earliest!.fireTime {
                earliest = source
            }
        }
        return earliest
    }
}

/// Opaque cancellable event source vended by `NetworkQueue`, backed by a `DispatchSource`
/// or an inline timer.
@available(Network 0.1.0, *)
final class NetworkQueueSource: @unchecked Sendable {
    /// Inline timer state, allocated only for inline sources.
    fileprivate final class Inline {
        weak var queue: NetworkQueue?
        let block: () -> Void
        let cancelBlock: (() -> Void)?
        var fireTime: DispatchTime = .distantFuture
        var interval: UInt64 = .max
        var armed = false
        var cancelled = false

        init(queue: NetworkQueue, block: @escaping () -> Void, cancelBlock: (() -> Void)?) {
            self.queue = queue
            self.block = block
            self.cancelBlock = cancelBlock
        }
    }

    private enum Backend {
        case dispatch(any DispatchSourceProtocol)
        case inline(Inline)
    }

    private let backend: Backend

    fileprivate init(dispatch source: any DispatchSourceProtocol) {
        self.backend = .dispatch(source)
    }

    fileprivate init(inlineTimerOn queue: NetworkQueue, block: @escaping () -> Void, cancelBlock: (() -> Void)?) {
        self.backend = .inline(Inline(queue: queue, block: block, cancelBlock: cancelBlock))
    }

    var data: UInt {
        if case .dispatch(let source) = backend { return source.data }
        return 0
    }

    fileprivate var fireTime: DispatchTime {
        if case .inline(let inline) = backend { return inline.fireTime }
        return .distantFuture
    }

    /// Timer sources only.
    func setTimerValues(fireTime: DispatchTime, interval: UInt64 = .max, leeway: UInt64 = 0) {
        switch backend {
        case .dispatch(let source):
            guard let timer = source as? any DispatchSourceTimer else { return }
            if interval == .max {
                timer.schedule(deadline: fireTime, leeway: .nanoseconds(Int(leeway)))
            } else {
                timer.schedule(deadline: fireTime, repeating: .nanoseconds(Int(interval)), leeway: .nanoseconds(Int(leeway)))
            }
        case .inline(let inline):
            inline.fireTime = fireTime
            inline.interval = interval
        }
    }

    func activate() {
        switch backend {
        case .dispatch(let source): source.activate()
        case .inline(let inline): inline.armed = true
        }
    }

    func resume() {
        switch backend {
        case .dispatch(let source): source.resume()
        case .inline(let inline): inline.armed = true
        }
    }

    func suspend() {
        switch backend {
        case .dispatch(let source): source.suspend()
        case .inline(let inline): inline.armed = false
        }
    }

    func cancel() {
        switch backend {
        case .dispatch(let source):
            source.cancel()
        case .inline(let inline):
            guard !inline.cancelled else { return }
            inline.cancelled = true
            inline.armed = false
            inline.queue?.removeInlineSource(self)
            inline.cancelBlock?()
        }
    }

    fileprivate func isDueTimer(at deadline: DispatchTime) -> Bool {
        guard case .inline(let inline) = backend else { return false }
        return inline.armed && !inline.cancelled && inline.fireTime <= deadline
    }

    fileprivate func fireInline() {
        guard case .inline(let inline) = backend else { return }
        let scheduledAt = inline.fireTime
        inline.block()
        // If the block rescheduled or cancelled, honor that; otherwise consume a one-shot
        // or advance a repeating timer so drain() makes progress.
        guard !inline.cancelled, inline.fireTime == scheduledAt else { return }
        if inline.interval != .max && inline.interval > 0 {
            inline.fireTime = DispatchTime(uptimeNanoseconds: inline.fireTime.uptimeNanoseconds &+ inline.interval)
        } else {
            inline.armed = false
        }
    }
}
#endif  // canImport(Dispatch)
