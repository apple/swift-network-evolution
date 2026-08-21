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
public struct SRVEndpoint: EndpointProtocol, EndpointCommonProtocol, Sendable {
    public var common: EndpointCommon
    let name: String

    // MARK: -- Initializers --

    init(name: String) {
        self.common = EndpointCommon()
        self.name = name
    }

    init(copying endpoint: SRVEndpoint, name: String) {
        // Note that this copies most things by value except backing for memory conservation
        self.common = endpoint.common
        self.name = name
    }

    // MARK: -- Serialization --

    init?(serializedData: inout [UInt8]) {
        guard let common = EndpointCommon(&serializedData) else {
            return nil
        }
        self.common = common
        var name = ""
        let result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
            try read.string(&name)
        }
        guard result.isValid else {
            return nil
        }
        self.name = name
    }

    #if !NETWORK_PRIVATE
    func serialize() -> [UInt8]? {
        let innerBuffer = Serializer.serialize { write in
            write.fixedLengthUTF8(name, byteCount: name.utf8.count + 1)
        }

        let length = UInt8(8 + innerBuffer.count)
        return Serializer.serialize { write in
            write.uint8(length)
            write.uint8(UInt8(AddressFamily.unspecified.rawValue))
            write.uint16NetworkByteOrder(0)
            write.uint32(Endpoint.EndpointType.EndpointRawType.srv.rawValue)
            write.buffer(innerBuffer)
        }
    }
    #endif

    // MARK: -- Comparisons --

    public static func == (lhs: SRVEndpoint, rhs: SRVEndpoint) -> Bool {
        lhs.isEqual(to: rhs)
    }

    func isEqual(to other: SRVEndpoint, flags: EndpointEqualityFlags = .empty) -> Bool {
        guard common.isEqual(to: other.common, flags: flags) else { return false }
        #if !NETWORK_EMBEDDED
        return name == other.name
        #else
        return false
        #endif
    }

    // MARK: -- Description --

    public var description: String {
        String()
    }

    public var redactedDescription: String {
        String()
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
    }
}
