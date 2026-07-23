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

@available(Network 0.1.0, *)
public struct EthernetAddress: Sendable, Hashable, CustomDebugStringConvertible {

    public static var broadcast: EthernetAddress {
        EthernetAddress(EthernetAddressStorage(repeating: 0xff))
    }

    public static var length: Int { 6 }

    internal typealias EthernetAddressStorage = [6 of UInt8]

    // Values stored in network byte order
    internal let address: EthernetAddressStorage

    init(_ address: EthernetAddressStorage) {
        self.address = address
    }

    var span: Span<UInt8> {
        @_lifetime(borrow self)
        get {
            address.span
        }
    }

    /// An Ethernet address as a byte array.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count == MemoryLayout<EthernetAddressStorage>.size else {
            return nil
        }

        var address = EthernetAddressStorage(repeating: 0)
        let span = bytes.span
        for i in 0..<span.count {
            address[i] = span[i]
        }
        self = .init(address)
    }

    static func ethernetAddressString(from address: EthernetAddressStorage) -> String {
        var result = ""
        for i in 0..<address.count {
            if i != 0 {
                result.append(":")
            }
            let string = String(address[i], radix: 16, uppercase: false)
            if string.utf8.count == 1 {
                result.append("0")
            }
            result.append(string)
        }
        return result
    }

    public var debugDescription: String {
        EthernetAddress.ethernetAddressString(from: address)
    }

    static public func == (lhs: EthernetAddress, rhs: EthernetAddress) -> Bool {
        for i in 0..<lhs.address.count {
            if lhs.address[i] != rhs.address[i] {
                return false
            }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        for i in 0..<address.count {
            hasher.combine(address[i])
        }
    }
}
