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
public struct BonjourEndpoint: EndpointProtocol, EndpointCommonProtocol, Sendable {
    public var common: EndpointCommon {
        get { backing.storage.common }
        set {
            if !isKnownUniquelyReferenced(&self.backing) {
                self.backing = self.backing.copy()
            }
            backing.storage.common = newValue
        }
    }
    public var name: String { backing.storage.name }
    public var type: String { backing.storage.type }
    public var domain: String { backing.storage.domain }
    public var composite: String { backing.storage.composite }

    // MARK: -- Initializers --

    init?(name: String, type: String, domain: String) {
        var serviceType = type
        if type.hasSuffix(".") {
            serviceType = String(type.dropLast())
        }
        let composite = Self.compositeString(name: name, type: serviceType, domain: domain)
        guard let composite else {
            return nil
        }
        self.backing = Backing(
            storage: BonjourBackingClass.Storage(
                common: EndpointCommon(),
                name: name,
                type: serviceType,
                domain: domain,
                composite: composite
            )
        )
    }

    private final class BonjourBackingClass: Hashable, Sendable {
        static func == (lhs: BonjourEndpoint.BonjourBackingClass, rhs: BonjourEndpoint.BonjourBackingClass) -> Bool {
            lhs.storage == rhs.storage
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(storage)
        }
        internal struct Storage: Hashable {
            public var common: EndpointCommon
            public let name: String  // Name is informational for application-service endpoints.
            public let type: String
            public let domain: String
            public let composite: String
        }
        func copy() -> Self {
            .init(storage: self.storage)
        }
		var storage: Storage {
			get {
				lock.withLock { _ in
					_storage
				}
			}
			set {
				lock.withLock { _ in
					_storage = newValue
				}
			}
		}
		private nonisolated(unsafe) var _storage: Storage
		private let lock = NetworkMutex(())
        init(storage: Storage) {
            self._storage = storage
        }
    }
    private typealias Backing = BonjourBackingClass
    private var backing: Backing

    // MARK: -- Serialization --

    init?(serializedData: inout [UInt8]) {
        var nameString: String = ""
        var typeString: String = ""
        var domainString: String = ""

        guard let common = EndpointCommon(&serializedData) else {
            return nil
        }

        let result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
            try read.string(&nameString)
            try read.string(&typeString)
            try read.string(&domainString)
        }
        guard result.isValid else {
            return nil
        }
        self.init(name: nameString, type: typeString, domain: domainString)
        self.common = common
    }

    func serialize() -> [UInt8]? {
        let innerBuffer = Serializer.serialize { write in
            write.fixedLengthUTF8(name, byteCount: name.utf8.count + 1)
            write.fixedLengthUTF8(type, byteCount: type.utf8.count + 1)
            write.fixedLengthUTF8(domain, byteCount: domain.utf8.count + 1)
        }

        let length = UInt8(8 + innerBuffer.count)
        return Serializer.serialize { write in
            write.uint8(length)
            write.uint8(UInt8(AddressFamily.unspecified.rawValue))
            write.uint16NetworkByteOrder(0)
            write.uint32(Endpoint.EndpointType.EndpointRawType.bonjour.rawValue)
            write.buffer(innerBuffer)
        }
    }

    var domainForPolicy: String {
        composite
    }

    // MARK: -- Comparisons --

    public static func == (lhs: BonjourEndpoint, rhs: BonjourEndpoint) -> Bool {
        lhs.isEqual(to: rhs)
    }

    func isEqual(to other: BonjourEndpoint, flags: EndpointEqualityFlags = .empty) -> Bool {
        // Do not check for equality between endpoints by their name, type, and domain
        // strings separately. Instead, compare their service composites, whose formats
        // are standardized by DNSServiceConstructFullName().
        guard common.isEqual(to: other.common, flags: flags) else { return false }
        #if !NETWORK_EMBEDDED
        return composite == other.composite
        #else
        return false
        #endif
    }

    // MARK: -- Description --

    public func descriptionInternal(redacted: Bool) -> String {
        var suffix = ""
        if let interface {
            suffix = "@" + interface.name
        }
        if redacted {
            return "Bonjour#" + redactedHash(composite) + suffix
        } else {
            return composite + suffix
        }
    }

    public var description: String {
        descriptionInternal(redacted: false)
    }

    var redactedDescription: String {
        descriptionInternal(redacted: true)
    }

    // MARK: -- Internal --

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.common)
        #if !NETWORK_EMBEDDED
        hasher.combine(self.composite)
        #endif
    }

    #if !NETWORK_PRIVATE
    static func compositeString(name: String, type: String, domain: String) -> String? {
        "\(name).\(type).\(domain)"
    }
    #endif
}
