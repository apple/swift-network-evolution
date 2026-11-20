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
#endif

/// A path and its identifier. A free entry has no path and the identifier `.none`.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
@usableFromInline
struct MultiplexedPathEntry<Path: ~Copyable>: ~Copyable {
    @usableFromInline var identifier: MultiplexingPathIdentifier
    @usableFromInline var path: Path?
}

/// The entries are not held between steps, so an iteration may look paths up, remove them or add them.
/// A path that is removed before the iteration reaches it is not visited, and a path added during the
/// iteration is only visited if it takes the place of a removed one.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public struct PathCursor {
    @usableFromInline var position = 0
    @usableFromInline var end: Int
    @usableFromInline init(end: Int) { self.end = end }
}

/// Why a path could not be added to the entries.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public enum MultiplexedPathEntriesError: Error, Equatable {
    /// The identifier is the one that means no path, which marks a free entry.
    case invalidIdentifier
    /// Another path already has the identifier.
    case duplicateIdentifier
}

/// The paths a many-to-many protocol multiplexes, kept in the order they were stored.
///
/// A connection has a handful of paths. The paths live inline in `entries`, each next to its identifier,
/// and a removed path leaves a free entry that the next insert reuses.
///
/// Paths are only ever reached by borrowing: `withPath` lends out the stored path, in place, for the
/// duration of a closure. The entries are exclusively accessed for the whole of a borrow, so the closure
/// must not reach them again.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public struct MultiplexedPathEntries<Path: ~Copyable>: ~Copyable {
    @usableFromInline var entries = NetworkUniqueArray<MultiplexedPathEntry<Path>>()

    private var liveCount = 0

    // The position the most recent path was looked up on.
    // Use this to short circuit several path look-up operation in sequence for performance reasons.
    @usableFromInline var lastCachedPosition = 0

    public init() {}

    public var count: Int { liveCount }

    public var isEmpty: Bool { liveCount == 0 }

    /// The position of the entry for `pathID`, if it is in the entries.
    ///
    /// - Parameter pathID: The identifier of the path to look up.
    /// - Returns: The optional index of that path looked up
    /// Time: O(1) for a path that matches the last cached position, otherwise average O(p) for p paths
    @inline(always)
    public func find(_ pathID: MultiplexingPathIdentifier) -> Int? {
        guard pathID != MultiplexingPathIdentifier.none else { return nil }
        let end = entries.count
        let hint = lastCachedPosition
        if hint < end, entries[hint].identifier == pathID { return hint }
        var position = 0
        while position < end {
            if entries[position].identifier == pathID { return position }
            position &+= 1
        }
        return nil
    }

    public func contains(_ pathID: MultiplexingPathIdentifier) -> Bool {
        find(pathID) != nil
    }

    /// An arbitrary path identifier, if there is one. It is the first path that was added of those
    /// that remain.
    public var firstPathIdentifier: MultiplexingPathIdentifier? {
        for position in 0..<entries.count where entries[position].identifier != MultiplexingPathIdentifier.none {
            return entries[position].identifier
        }
        return nil
    }

    /// The number of entries, live or free. An iteration over the identifiers covers the entries up to this
    /// number (see `nextPathIdentifier`).
    public var entryCount: Int { entries.count }

    /// The identifier of the next path at or after `position`, before `end`, moving `position` past it.
    /// An iteration that is not holding the entries, so that what it does between steps can reach them, uses
    /// this in place of a snapshot of the identifiers, which would allocate.
    ///
    /// - Parameter position: The position to lookup the path by
    /// - Parameter end: The upper bound to search all indices by the end
    /// - Returns: Optional path identifier
    @inline(always)
    public func nextPathIdentifier(from position: inout Int, before end: Int) -> MultiplexingPathIdentifier? {
        let end = min(end, entries.count)
        while position < end {
            let identifier = entries[position].identifier
            position &+= 1
            if identifier != MultiplexingPathIdentifier.none { return identifier }
        }
        return nil
    }

    /// A snapshot of every identifier, safe to iterate while the entries are modified.
    public var pathIdentifiers: [MultiplexingPathIdentifier] {
        var identifiers: [MultiplexingPathIdentifier] = []
        identifiers.reserveCapacity(liveCount)
        for position in 0..<entries.count where entries[position].identifier != MultiplexingPathIdentifier.none {
            identifiers.append(entries[position].identifier)
        }
        return identifiers
    }

    /// Adds a path under its identifier.
    ///
    /// - Parameters:
    ///   - path: The path to add. It is destroyed if it is not added.
    ///   - pathID: The identifier to find the path by.
    /// - Throws: `MultiplexedPathEntriesError` if the identifier is the one that means no path, or if another
    ///   path already has it. Nothing is changed in that case.
    public mutating func insert(
        _ path: consuming Path,
        for pathID: MultiplexingPathIdentifier
    ) throws(MultiplexedPathEntriesError) {
        guard pathID != MultiplexingPathIdentifier.none else {
            throw .invalidIdentifier
        }
        guard find(pathID) == nil else {
            throw .duplicateIdentifier
        }
        for position in 0..<entries.count where entries[position].identifier == MultiplexingPathIdentifier.none {
            entries[position].identifier = pathID
            entries[position].path = consume path
            liveCount += 1
            return
        }
        entries.append(MultiplexedPathEntry(identifier: pathID, path: consume path))
        liveCount += 1
    }

    /// Removes the path and hands it to the caller.
    ///
    /// - Parameter pathID: The identifier of the path to look up.
    /// - Returns: Optional path result
    public mutating func remove(_ pathID: MultiplexingPathIdentifier) -> Path? {
        guard let entry = find(pathID) else { return nil }
        entries[entry].identifier = MultiplexingPathIdentifier.none
        liveCount -= 1
        return entries[entry].path.take()
    }

    /// Lends out the path with the given identifier, in place, or returns `nil` if there is none.
    ///
    /// - Parameter pathID: The identifier of the path to look up.
    /// - Parameter body: The closure to receive the borrowed path
    /// - Returns: Optional result
    /// Time: average O(p) for p paths, plus whatever `body` takes.
    @inline(always)
    public mutating func withPath<R: ~Copyable, E: Error>(
        _ pathID: MultiplexingPathIdentifier,
        _ body: (inout Path) throws(E) -> R
    ) throws(E) -> R? {
        guard let entry = find(pathID) else { return nil }
        lastCachedPosition = entry
        return try body(&entries[entry].path!)
    }

    /// Lends out every path in turn.
    /// - Parameter body: The closure to receive each non-borrowed path
    public mutating func forEachPath(_ body: (inout Path) -> Void) {
        for position in 0..<entries.count where entries[position].identifier != MultiplexingPathIdentifier.none {
            body(&entries[position].path!)
        }
    }

    /// Removes all path entries and clears all state
    public mutating func removeAll() {
        entries = NetworkUniqueArray<MultiplexedPathEntry<Path>>()
        lastCachedPosition = 0
        liveCount = 0
    }
}
