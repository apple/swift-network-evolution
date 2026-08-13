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
public struct ApplicationServiceEndpoint: EndpointProtocol, EndpointCommonProtocol, Sendable {
    public var common: EndpointCommon {
        get { backing.storage.common }
        set {
            if !isKnownUniquelyReferenced(&self.backing) {
                self.backing = self.backing.copy()
            }
            backing.storage.common = newValue
        }
    }
    public var name: String { backing.storage.name }  // Name is informational for application-service endpoints.
    public var applicationService: String {
        get { backing.storage.applicationService }
        set {
            if !isKnownUniquelyReferenced(&self.backing) {
                self.backing = self.backing.copy()
            }
            backing.storage.applicationService = newValue
        }
    }
    public var serviceID: SystemUUID {
        get { backing.storage.serviceID }
        set {
            if !isKnownUniquelyReferenced(&self.backing) {
                self.backing = self.backing.copy()
            }
            backing.storage.serviceID = newValue
        }
    }

    internal final class AppSVCBackingClass: Hashable, Sendable {
        static func == (
            lhs: ApplicationServiceEndpoint.AppSVCBackingClass,
            rhs: ApplicationServiceEndpoint.AppSVCBackingClass
        ) -> Bool {
            lhs.storage == rhs.storage
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(storage)
        }
        internal struct Storage: Hashable, Sendable {
            var common: EndpointCommon
            let name: String  // Name is informational for application-service endpoints.
            var applicationService: String
            var serviceID: SystemUUID
            #if NETWORK_PRIVATE
            var privateStorage: PrivateStorage
            #endif
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
    typealias Backing = AppSVCBackingClass
    var backing: Backing

    #if !NETWORK_PRIVATE
    init(
        _ applicationService: String,
        serviceID: SystemUUID
    ) {
        let common = EndpointCommon(interface: nil)
        let name = applicationService + "/" + serviceID.uuidString
        let applicationService = applicationService
        self.backing = Backing(
            storage: AppSVCBackingClass.Storage(
                common: common,
                name: name,
                applicationService: applicationService,
                serviceID: serviceID
            )
        )
    }

    init?(serializedData: inout [UInt8]) {
        var applicationService = ""
        var serviceID = SystemUUID.empty
        var data = serializedData

        guard let common = EndpointCommon(&data) else {
            return nil
        }

        let result = Deserializer.deserialize(&data) { read throws(DeserializationError) in
            try read.string(&applicationService)
            try read.uuid(&serviceID)
        }
        guard result.isValid else {
            return nil
        }
        self.init(
            applicationService,
            serviceID: serviceID
        )
        self.common = common
    }

    func serialize() -> [UInt8]? {
        let innerBuffer = Serializer.serialize { write in
            write.fixedLengthUTF8(applicationService, byteCount: applicationService.utf8.count + 1)
            write.uuid(serviceID)
        }

        let length = UInt8(8 + innerBuffer.count)
        return Serializer.serialize { write in
            write.uint8(length)
            write.uint8(UInt8(AddressFamily.unspecified.rawValue))
            write.uint16NetworkByteOrder(0)
            write.uint32(Endpoint.EndpointType.EndpointRawType.applicationService.rawValue)
            write.buffer(innerBuffer)
        }
    }
    #endif

    // MARK: -- Comparisons --

    public static func == (lhs: ApplicationServiceEndpoint, rhs: ApplicationServiceEndpoint) -> Bool {
        lhs.isEqual(to: rhs)
    }

    #if !NETWORK_PRIVATE
    func isEqual(to other: ApplicationServiceEndpoint, flags: EndpointEqualityFlags = .empty) -> Bool {
        common.isEqual(to: other.common, flags: flags) && applicationService == other.applicationService
            && serviceID == other.serviceID
    }
    #endif

    // MARK: -- Description --

    #if !NETWORK_PRIVATE
    public func descriptionInternal(redacted: Bool) -> String {
        "app_svc: \(applicationService), service_id: \(serviceID)"
    }
    #endif

    public var description: String {
        descriptionInternal(redacted: false)
    }

    public var redactedDescription: String {
        descriptionInternal(redacted: true)
    }

    // MARK: -- Internal --

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.common)
    }
}
