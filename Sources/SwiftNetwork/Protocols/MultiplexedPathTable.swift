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

// A path and its identifier. A free entry has no path and the identifier `.none`.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
@usableFromInline
struct MultiplexedPathTableEntry<Path: ~Copyable>: ~Copyable {
    @usableFromInline var identifier: MultiplexingPathIdentifier
    @usableFromInline var path: Path?
}

// Where an iteration over the paths is. The table is not held between steps, so what the iteration does can look
// paths up, remove them or add them. A path that is removed before the iteration reaches it is not visited,
// and a path added during the iteration is only visited if it takes the place of a removed one.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public struct PathCursor {
    @usableFromInline var position = 0
    @usableFromInline var end: Int
    @usableFromInline init(end: Int) { self.end = end }
}

// A table of the paths a many-to-many protocol multiplexes, keyed by path identifier.
//
// A connection has a handful of paths. The paths live inline in `entries`, each next to its identifier,
// and a removed path leaves a free entry that the next insert reuses.
//
// Paths are only ever reached by borrowing: `withPath` lends out the stored path, in place, for the
// duration of a closure. The table is exclusively accessed for the whole of a borrow, so the closure
// must not reach the table again.
@available(Network 0.1.0, *)
@_spi(ProtocolProvider)
public struct MultiplexedPathTable<Path: ~Copyable>: ~Copyable {
    @usableFromInline var entries = NetworkUniqueArray<MultiplexedPathTableEntry<Path>>()

    private var liveCount = 0

    public init() {}

    public var count: Int { liveCount }

    public var isEmpty: Bool { liveCount == 0 }

    // The position of the entry for `pathID`, if it is in the table.
    //
    // Time: average O(p) for p paths
    @inline(always)
    public func find(_ pathID: MultiplexingPathIdentifier) -> Int? {
        var position = 0
        let end = entries.count
        while position < end {
            if entries[position].identifier == pathID { return position }
            position &+= 1
        }
        return nil
    }

    public func contains(_ pathID: MultiplexingPathIdentifier) -> Bool {
        find(pathID) != nil
    }

    // An arbitrary path identifier, if there is one. It is the first path that was added of those
    // that remain.
    public var firstPathIdentifier: MultiplexingPathIdentifier? {
        for position in 0..<entries.count where entries[position].identifier != MultiplexingPathIdentifier.none {
            return entries[position].identifier
        }
        return nil
    }

    // The number of entries, live or free. An iteration over the identifiers covers the entries up to this
    // number (see `nextPathIdentifier`).
    public var entryCount: Int { entries.count }

    // The identifier of the next path at or after `position`, before `end`, moving `position` past it.
    // An iteration that is not holding the table, so that what it does between steps can reach the table, uses
    // this in place of a snapshot of the identifiers, which would allocate.
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

    // A snapshot of every identifier, safe to iterate while the table is modified.
    public var pathIdentifiers: [MultiplexingPathIdentifier] {
        var identifiers: [MultiplexingPathIdentifier] = []
        identifiers.reserveCapacity(liveCount)
        for position in 0..<entries.count where entries[position].identifier != MultiplexingPathIdentifier.none {
            identifiers.append(entries[position].identifier)
        }
        return identifiers
    }

    public mutating func insert(_ path: consuming Path, for pathID: MultiplexingPathIdentifier) {
        assert(pathID != MultiplexingPathIdentifier.none, "A path cannot have the identifier that means no path")
        assert(find(pathID) == nil, "Path \(pathID) is already in the table")
        for position in 0..<entries.count where entries[position].identifier == MultiplexingPathIdentifier.none {
            entries[position].identifier = pathID
            entries[position].path = consume path
            liveCount += 1
            return
        }
        entries.append(MultiplexedPathTableEntry(identifier: pathID, path: consume path))
        liveCount += 1
    }

    // Removes the path and hands it to the caller.
    public mutating func remove(_ pathID: MultiplexingPathIdentifier) -> Path? {
        guard let entry = find(pathID) else { return nil }
        entries[entry].identifier = MultiplexingPathIdentifier.none
        liveCount -= 1
        return entries[entry].path.take()
    }

    // Lends out the path with the given identifier, in place, or returns `nil` if there is none.
    //
    // Time: average O(p) for p paths, plus whatever `body` takes.
    @inline(always)
    public mutating func withPath<R: ~Copyable, E: Error>(
        _ pathID: MultiplexingPathIdentifier,
        _ body: (inout Path) throws(E) -> R
    ) throws(E) -> R? {
        guard let entry = find(pathID) else { return nil }
        return try body(&entries[entry].path!)
    }

    // Lends out every path in turn.
    public mutating func forEachPath(_ body: (inout Path) -> Void) {
        for position in 0..<entries.count where entries[position].identifier != MultiplexingPathIdentifier.none {
            body(&entries[position].path!)
        }
    }

    // Destroys every path as it is, without any cleanup of its own. A path that holds an event
    // state to unregister (`destroy(in:)`) has to be destroyed before this is called.
    public mutating func removeAll() {
        entries = NetworkUniqueArray<MultiplexedPathTableEntry<Path>>()
        liveCount = 0
    }
}
