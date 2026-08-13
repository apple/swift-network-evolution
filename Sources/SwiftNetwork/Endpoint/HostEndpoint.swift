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

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct HostEndpoint: EndpointProtocol, EndpointCommonProtocol, Sendable {
    public var common: EndpointCommon
    public let name: String
    public let port: UInt16
    var priority: UInt16 = 0
    var weight: UInt16 = 0

    // MARK: -- Initializers --

    public init(name: String, port: UInt16) {
        self.common = EndpointCommon()
        self.name = name
        self.port = port
    }

    public init(copying endpoint: HostEndpoint, name: String, port: UInt16) {
        // Note that this copies most things by value except backing for memory conservation
        self.common = endpoint.common
        self.name = name
        self.port = port
        self.priority = endpoint.priority
        self.weight = endpoint.weight
    }

    // MARK: -- Serialization --

    init?(serializedData: inout [UInt8]) {
        var nameString = ""
        var port: UInt16 = 0
        var priority: UInt16 = 0
        var weight: UInt16 = 0
        guard let common = EndpointCommon(&serializedData) else {
            return nil
        }
        let result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
            try read.string(&nameString)
            try read.uint16(&port)
            try read.uint16(&priority)
            try read.uint16(&weight)
        }
        guard result.isValid else {
            return nil
        }
        guard !nameString.isEmpty, port != 0 else {
            return nil
        }
        self.init(name: nameString, port: port)
        self.common = common
        self.priority = priority
        self.weight = weight
    }

    #if !NETWORK_PRIVATE
    func serialize() -> [UInt8]? {
        let innerBuffer = Serializer.serialize { write in
            write.fixedLengthUTF8(name, byteCount: name.utf8.count + 1)
        }

        let length = UInt8(8 + innerBuffer.count)
        return Serializer.serialize { write in
            write.uint8(length)
            write.uint8(AddressFamily.unspecified.rawValue)
            write.uint16NetworkByteOrder(self.port)
            write.uint32(Endpoint.EndpointType.EndpointRawType.host.rawValue)
            write.buffer(innerBuffer)
        }
    }
    #endif

    // MARK: -- Comparisons --

    public static func == (lhs: HostEndpoint, rhs: HostEndpoint) -> Bool {
        lhs.isEqual(to: rhs)
    }

    func isEqual(to other: HostEndpoint, flags: EndpointEqualityFlags = .empty) -> Bool {
        guard common.isEqual(to: other.common, flags: flags) else { return false }
        #if !NETWORK_EMBEDDED
        return name == other.name && port == other.port
        #else
        return port == other.port
        #endif
    }

    // MARK: -- Description --

    public func descriptionInternal(redacted: Bool) -> String {
        let description = self.name + ":" + String(self.port)
        if redacted {
            return "Hostname#" + redactedHash(description) + ":" + String(self.port)
        } else {
            return description
        }
    }

    public var description: String {
        descriptionInternal(redacted: false)
    }

    var redactedDescription: String {
        descriptionInternal(redacted: true)
    }

    // MARK: -- Computed Properties --

    var domainForPolicy: String {
        name
    }

    // MARK: -- Internal --

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.common)
        #if !NETWORK_EMBEDDED
        hasher.combine(self.name)
        #endif
        hasher.combine(self.port)
    }

    public func matchesHostname(_ hostName: String, _ port: UInt16) -> Bool {
        self.name == hostName && self.port == port
    }
}
