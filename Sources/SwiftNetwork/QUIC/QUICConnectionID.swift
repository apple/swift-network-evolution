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

enum QUICConnectionIDError: Int {
    case initialConnectionSetError
    case duplicateConnectionIDSet
}
// QUICConnectionID is stored as an inline array of 20 bytes for performance reasons.
@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public typealias QUICConnectionIDStorage = [20 of UInt8]

@available(Network 0.1.0, *)
extension QUICConnectionIDStorage {
    static var empty: QUICConnectionIDStorage {
        QUICConnectionIDStorage(repeating: 0)
    }

    init(_ span: Span<UInt8>) {
        self = QUICConnectionIDStorage.empty
        for i in 0..<span.count {
            self[i] = span[i]
        }
    }

    static func random(length: Int) -> Self {
        var storage = QUICConnectionIDStorage.empty
        var randomNumberGenerator = SystemRandomNumberGenerator()
        for i in 0..<length {
            storage[i] = UInt8.random(in: 0...255, using: &randomNumberGenerator)
        }
        return storage
    }
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICConnectionID: Sendable, Equatable, CustomStringConvertible {
    static let maximumSize = 20

    static let defaultClientSCIDLength = 0
    static let defaultServerSCIDLength = 8

    private let _connectionID: QUICConnectionIDStorage
    // The actual length represents the number of bytes for the CID stored in the tuple
    private let actualLength: Int

    public var length: Int {
        actualLength
    }

    public var connectionIDStorage: QUICConnectionIDStorage {
        _connectionID
    }

    public var connectionID: [UInt8] {
        [UInt8](copying: _connectionID.span, maxCount: actualLength)
    }

    // Creates a QUICConnectionID from an array.
    public init?(_ connectionID: [UInt8]) {
        guard connectionID.count <= QUICConnectionID.maximumSize else {
            #if !DisableErrorLogging
            let connectionIDCount = connectionID.count
            Logger.proto.error("Invalid QUICConnectionID length \(connectionIDCount)")
            #endif
            return nil
        }
        actualLength = connectionID.count
        _connectionID = QUICConnectionIDStorage(connectionID.span)
    }

    public init(storage: QUICConnectionIDStorage, size: Int) {
        _connectionID = storage
        if size <= QUICConnectionID.maximumSize {
            actualLength = size
        } else {
            #if !DisableErrorLogging
            Logger.proto.error("Invalid QUICConnectionID length \(size)")
            #endif
            actualLength = QUICConnectionID.maximumSize
        }
    }

    public init?(_ connectionID: Span<UInt8>) {
        guard connectionID.count <= QUICConnectionID.maximumSize else {
            #if !DisableErrorLogging
            let connectionIDCount = connectionID.count
            Logger.proto.error("Invalid QUICConnectionID length \(connectionIDCount)")
            #endif
            return nil
        }
        actualLength = connectionID.count
        _connectionID = QUICConnectionIDStorage(connectionID)
    }

    // Creates a random QUICConnectionID of the requestedSize.
    public init(_ size: Int) {
        var size = size
        if size > QUICConnectionID.maximumSize {
            #if !DisableErrorLogging
            Logger.proto.error("Invalid QUICConnectionID length \(size)")
            #endif
            size = QUICConnectionID.maximumSize
        }
        if size != 0 && size < 4 {
            size = 4
        }
        actualLength = size
        _connectionID = QUICConnectionIDStorage.random(length: size)
    }

    // Creates a QUICConnectionID from a buffer with a specific size.
    init?(_ buffer: [UInt8], size: Int) {
        guard size <= QUICConnectionID.maximumSize, buffer.count >= size else {
            #if !DisableErrorLogging
            Logger.proto.error("Invalid QUICConnectionID length \(size)")
            #endif
            return nil
        }
        let cidBytes = Array(buffer[0..<min(size, QUICConnectionID.maximumSize)])
        actualLength = cidBytes.count
        _connectionID = QUICConnectionIDStorage(cidBytes.span)
    }

    var isUninitialized: Bool {
        for i in 0..<actualLength {
            if _connectionID[i] != 0 { return false }
        }
        return true
    }

    public var description: String {
        #if !NETWORK_EMBEDDED
        var accumulator = ""
        for i in 0..<actualLength {
            var thisDigit = String(_connectionID[i], radix: 16)
            if thisDigit.count == 1 {
                thisDigit = "0" + thisDigit
            }
            accumulator += thisDigit
        }
        return accumulator
        #else
        return "CID"
        #endif
    }

    static public func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.actualLength == rhs.actualLength else {
            return false
        }
        #if !NETWORK_EMBEDDED
        return lhs.connectionIDStorage.span.withUnsafeBytes { left in
            rhs.connectionIDStorage.span.withUnsafeBytes { right in
                memcmp(left.baseAddress!, right.baseAddress!, 20)
            }
        } == 0
        #else
        // Fall back to comparing by index
        let lhsSpan = lhs._connectionID.span
        let rhsSpan = rhs._connectionID.span
        for i in 0..<lhs.actualLength {
            if lhsSpan[i] != rhsSpan[i] {
                return false
            }
        }
        return true
        #endif
    }
}

@available(Network 0.1.0, *)
extension QUICConnectionID: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(actualLength)
        for i in 0..<actualLength {
            hasher.combine(_connectionID[i])
        }
    }
}

@available(Network 0.1.0, *)
struct ManagedConnectionID {
    let sequenceNumber: UInt64
    let connectionID: QUICConnectionID
    let token: QUICStatelessResetToken
    struct Flags: OptionSet {
        init(rawValue: Self.RawValue) {
            self.rawValue = rawValue
        }
        var rawValue: UInt8
        static let used = Flags(rawValue: 1 << 0)
        static let preferredAddress = Flags(rawValue: 1 << 1)
    }
    var flags: Flags = Flags()
    var used: Bool {
        get { flags.contains(.used) }
        set { if newValue { flags.insert(.used) } else { flags.remove(.used) } }
    }
    var preferredAddress: Bool {
        get { flags.contains(.preferredAddress) }
        set {
            if newValue { flags.insert(.preferredAddress) } else { flags.remove(.preferredAddress) }
        }
    }
    init(
        sequenceNumber: UInt64,
        connectionID: QUICConnectionID,
        token: QUICStatelessResetToken,
        used: Bool = false
    ) {
        self.sequenceNumber = sequenceNumber
        self.connectionID = connectionID
        self.token = token
        self.used = used
    }
}

@available(Network 0.1.0, *)
struct QUICConnectionIDList: Sequence, IteratorProtocol {
    private(set) var managedConnectionIDs = Deque<ManagedConnectionID>()

    var activeConnectionIDLimit = TransportParameter.defaultValue(
        forType: .activeConnectionIDLimit
    )!

    // The initial connection ID is valid without a Stateless Reset Token (see RFC9000, Section 18.2).
    // If peer's transport parameters include a stateless reset token, use the normal `insert()` call.
    // NOTE: This API may only be called once for this instance of QUICConnectionIDList
    mutating func insertInitialConnectionID(
        _ connectionID: QUICConnectionID,
        token: QUICStatelessResetToken = .init()
    ) throws(QUICError) {
        guard managedConnectionIDs.isEmpty else {
            throw QUICError.connectionID(QUICConnectionIDError.initialConnectionSetError)
        }
        let newCID = ManagedConnectionID(
            sequenceNumber: 0,
            connectionID: connectionID,
            token: token,
            used: true
        )
        managedConnectionIDs.append(newCID)
    }

    static let preferredAddressSequenceNumber: UInt64 = 1

    mutating func insert(
        sequenceNumber: UInt64,
        connectionID: QUICConnectionID,
        token: QUICStatelessResetToken,
        used: Bool = false,
        preferredAddress: Bool = false
    ) throws(QUICError) {
        if sequenceNumber == 0 {
            // Updating the initial CID to include a Stateless Reset Token
            if let initialConnectionID = managedConnectionIDs.first {
                guard initialConnectionID.sequenceNumber == 0,
                    connectionID == initialConnectionID.connectionID
                else {
                    throw QUICError.connectionID(QUICConnectionIDError.initialConnectionSetError)
                }

                // Replace the connection ID entry
                var updatedConnectionID = ManagedConnectionID(
                    sequenceNumber: 0,
                    connectionID: connectionID,
                    token: token,
                    used: true
                )
                updatedConnectionID.preferredAddress = preferredAddress
                managedConnectionIDs.removeFirst()
                managedConnectionIDs.prepend(updatedConnectionID)
                return
            }
        }
        guard find(sequenceNumber: sequenceNumber) == nil,
            find(connectionID: connectionID) == nil
        else {
            throw QUICError.connectionID(QUICConnectionIDError.duplicateConnectionIDSet)
        }

        var managedConnectionID = ManagedConnectionID(
            sequenceNumber: sequenceNumber,
            connectionID: connectionID,
            token: token,
            used: used
        )
        managedConnectionID.preferredAddress = preferredAddress
        managedConnectionIDs.append(managedConnectionID)
    }

    @discardableResult
    mutating func retire(connectionID: QUICConnectionID) -> ManagedConnectionID? {
        var cid: ManagedConnectionID?
        managedConnectionIDs.removeAll {
            if $0.connectionID == connectionID {
                cid = $0
                return true
            }
            return false
        }
        return cid
    }

    mutating func retire(priorTo: UInt64) -> [ManagedConnectionID] {
        var retiredSequenceNumbers = [ManagedConnectionID]()
        managedConnectionIDs.removeAll {
            if $0.sequenceNumber < priorTo {
                retiredSequenceNumbers.append($0)
                return true
            }
            return false
        }
        return retiredSequenceNumbers
    }

    mutating func retire(sequenceNumber: UInt64) -> QUICConnectionID? {
        var connectionID: QUICConnectionID?
        managedConnectionIDs.removeAll {
            if $0.sequenceNumber == sequenceNumber {
                connectionID = $0.connectionID
                return true
            }
            return false
        }
        return connectionID
    }

    func find(connectionID: QUICConnectionID) -> ManagedConnectionID? {
        managedConnectionIDs.first { $0.connectionID == connectionID }
    }

    func find(sequenceNumber: UInt64) -> ManagedConnectionID? {
        managedConnectionIDs.first { $0.sequenceNumber == sequenceNumber }
    }

    func find(statelessResetToken: QUICStatelessResetToken) -> ManagedConnectionID? {
        managedConnectionIDs.first { $0.token == statelessResetToken }
    }

    mutating func markUsed(_ entry: ManagedConnectionID) {
        var entry = entry
        entry.used = true
        managedConnectionIDs.removeAll { $0.sequenceNumber == entry.sequenceNumber }
        managedConnectionIDs.prepend(entry)
    }

    var isEmpty: Bool { managedConnectionIDs.isEmpty }
    var count: Int { managedConnectionIDs.count }

    private var currentIterator = 0
    mutating func next() -> ManagedConnectionID? {
        if managedConnectionIDs.isEmpty {
            return nil
        }

        if currentIterator == managedConnectionIDs.count {
            defer {
                currentIterator = 0
            }
            return nil
        }
        defer {
            currentIterator += 1
        }
        return managedConnectionIDs[currentIterator]
    }
}

// In QUIC, connection IDs are always serialized with a prefixed 8 bit length.
@available(Network 0.1.0, *)
extension Serializer {
    func connectionID(_ value: QUICConnectionID) -> Serializable {
        .buffer([UInt8(value.length)] + value.connectionID)
    }
}
#endif
