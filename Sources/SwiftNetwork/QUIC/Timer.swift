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

#if !NETWORK_NO_SWIFT_QUIC

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

@available(Network 0.1.0, *)
protocol TimerUser {
    var timerID: Timer.TimerID? { get set }
    func timerFired(timeNow: NetworkClock.Instant)
}

@available(Network 0.1.0, *)
protocol NonCopyableTimerUser: ~Copyable {
    var timerID: Timer.TimerID? { get set }
    mutating func timerFired(timeNow: NetworkClock.Instant)
}

@available(Network 0.1.0, *)
private struct TimerEntry: ~Copyable {
    let identifier: Timer.TimerID
    var deadline: NetworkClock.Instant = .zero
    let description: String
    let closure: () -> Void

    init(identifier: Timer.TimerID, description: String, closure: @escaping () -> Void) {
        self.identifier = identifier
        self.description = description
        self.closure = closure
    }
    var isEnabled: Bool {
        deadline != .zero
    }
    mutating func disable() {
        deadline = .zero
    }
    mutating func schedule(fromNow: NetworkDuration, timerNow: NetworkClock.Instant = .now) {
        precondition(fromNow != .zero)
        self.deadline = timerNow.advanced(by: fromNow)
    }
}

// TODO: convert timer to ~Copyable
@available(Network 0.1.0, *)
final class Timer: PrefixedLoggable {
    typealias TimerID = UInt8

    var log: LogPrefixer
    private var reference: ProtocolInstanceReference? = nil
    private var timerReference: TimerReference
    private var nextID: TimerID = 1
    private var timerCancelled = false
    private var avoidRecalculate = false
    private var entries: NetworkUniqueDeque<TimerEntry> = .init(minimumCapacity: 4)
    #if DatapathLogging
    private let extraDebugging = true
    #else
    private let extraDebugging = false
    #endif
    var nextDeadline: NetworkClock.Instant {
        switch wakeup {
        case .armed(let instant):
            return instant
        case .idle:
            return .zero
        }
    }
    private var wakeup: WakeupState = .idle

    private enum WakeupState {
        case idle
        case armed(NetworkClock.Instant)
    }

    static let timerThreshold = NetworkDuration.milliseconds(1)

    init(reference: ProtocolInstanceReference, timerReference: TimerReference, logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        self.reference = reference
        self.timerReference = timerReference
    }

    internal init(timerReference: TimerReference, logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        self.timerReference = timerReference
    }
    func insert(
        description: String,
        fromNow: NetworkDuration = .zero,
        timerNow: NetworkClock.Instant = .now,
        closure: @escaping () -> Void
    ) -> TimerID {
        let identifier = nextID
        var entry = TimerEntry(identifier: nextID, description: description, closure: closure)
        if fromNow != .zero {
            entry.schedule(fromNow: fromNow, timerNow: timerNow)
        }
        entries.append(entry)
        nextID += 1
        if !avoidRecalculate {
            recalculate(timerNow)
        }
        log.datapath("added timer [T\(identifier)]")
        return identifier
    }

    func remove(_ identifier: TimerID) {
        // In theory, this should use find(), but that swaps entries which we don't want to do here.
        let entryCount = entries.count
        for i in 0..<entryCount {
            if entries[i].identifier == identifier {
                entries.remove(at: i)
                break
            }
        }
        log.datapath("removing timer [T\(identifier)]")
    }

    func stop(final: Bool = true) {
        if !timerCancelled {
            log.debug("Stopping timer")
            timerCancelled = true
            wakeup = .idle
            reference?.unscheduleWakeup(timerReference: timerReference)
        }
        if final {
            entries.removeAll()
            reference = nil
        }
    }

    private func recalculate(_ now: NetworkClock.Instant) {
        if extraDebugging {
            let entryCount = entries.count
            for i in 0..<entryCount {
                if entries[i].isEnabled {
                    var fromNow: NetworkDuration = .zero
                    if entries[i].deadline > now {
                        fromNow = now.duration(to: entries[i].deadline)
                    }
                    log.datapath(
                        "timer [T\(entries[i].identifier)] desc \(entries[i].description) deadline \(entries[i].deadline) (\(fromNow) from now)"
                    )
                } else {
                    log.datapath(
                        "timer [T\(entries[i].identifier)] desc \(entries[i].description) (no deadline)"
                    )
                }
            }
        }
        let entryCount = entries.count
        var earliestDeadline: NetworkClock.Instant? = nil
        for i in 0..<entryCount {
            if !entries[i].isEnabled {
                continue
            }
            if earliestDeadline == nil {
                earliestDeadline = entries[i].deadline
            } else if let compareDeadline = earliestDeadline, compareDeadline > entries[i].deadline {
                earliestDeadline = entries[i].deadline
            }
        }

        guard let earliestDeadline else {
            log.debug("No more timers to run")
            stop(final: false)
            return
        }

        var delta = now.duration(to: earliestDeadline)

        // Don't allow times in the past
        if delta < .zero {
            delta = .zero
        }

        // If the timer is over one millisecond in the future,
        // check if it is redundant with the existing deadline (nextDeadline).
        // This optimisation is only valid if there's a pending wakeup, otherwise
        // the timer may never fire.
        if case .armed(let nextDeadline) = wakeup, delta > Timer.timerThreshold {
            let deadlineDifference = earliestDeadline.duration(to: nextDeadline)
            if deadlineDifference < Timer.timerThreshold && deadlineDifference > (Timer.timerThreshold * -1) {
                // Timer is already set to within a millisecond of where it needs to be, don't schedule it
                log.datapath("timer already scheduled")
                return
            }
        }

        timerCancelled = false
        let oldDeadline = nextDeadline
        wakeup = .armed(now + delta)
        log.datapath(
            "arming timer for the next \(delta) (now \(now)), new deadline \(nextDeadline) old deadline \(oldDeadline)"
        )
        reference?.scheduleWakeup(milliseconds: UInt64(delta.milliseconds), timerReference: timerReference)
    }

    private func find(_ identifier: TimerID) -> Int? {
        let entryCount = entries.count
        for i in 0..<entryCount {
            if entries[i].identifier == identifier {
                if i != 0 {
                    entries.swapAt(0, i)
                }
                return 0
            }
        }
        return nil
    }

    func reschedule(
        identifier: TimerID,
        fromNow: NetworkDuration,
        timerNow: NetworkClock.Instant = .now
    ) {
        guard let index = find(identifier) else {
            return
        }
        if fromNow == .zero {
            guard entries[index].isEnabled else {
                return
            }
            entries[index].disable()
        } else {
            entries[index].schedule(fromNow: fromNow, timerNow: timerNow)
        }
        if !avoidRecalculate {
            recalculate(timerNow)
        }
    }

    public func timerFired(timeNow: NetworkClock.Instant = .now) {
        // Timer fired means the kernel woke us up.
        wakeup = .idle

        if _slowPath(timerCancelled) {
            log.fault("Timer fired after it was cancelled")
            return
        }
        // Due to timer leeway, we might actually be running a bit early, so
        // allow 1ms of leeway.
        let now = timeNow.advanced(by: Timer.timerThreshold)
        var ranOne = false

        avoidRecalculate = true
        if extraDebugging {
            log.datapath("running quic timer, now \(now)")
        }
        var index = 0
        while index < entries.count {
            if extraDebugging {
                if entries[index].isEnabled && entries[index].deadline > now {
                    log.datapath(
                        "timer [T\(entries[index].identifier)] desc \(entries[index].description) has deadline \(entries[index].deadline) > now \(now)"
                    )
                }
            }

            if entries[index].isEnabled && entries[index].deadline <= now {
                if extraDebugging {
                    log.datapath(
                        "calling timer closure for [T\(entries[index].identifier)] (\(entries[index].description)) (deadline \(entries[index].deadline) <= now \(now))"
                    )
                }
                entries[index].disable()
                entries[index].closure()
                ranOne = true
            }
            index += 1
        }

        if _slowPath(!ranOne) {
            let entryCount = entries.count
            for i in 0..<entryCount {
                log.error(
                    "Timer [T\(entries[i].identifier)] deadline \(entries[i].deadline), now \(now)"
                )
            }
            log.fault(
                "Spurious timer at \(now)), next deadline \(nextDeadline), cancelled? \(timerCancelled)"
            )
        }
        recalculate(timeNow)
        avoidRecalculate = false
    }
}
#endif
