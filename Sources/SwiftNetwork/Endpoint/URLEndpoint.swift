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

#if !NETWORK_EMBEDDED && canImport(Foundation)
import Foundation
#endif

@_spi(Essentials)
@available(Network 0.1.0, *)
public struct URLEndpoint: EndpointProtocol, EndpointCommonProtocol, Sendable {
    public var common: EndpointCommon
    public let url: URL
    public let schemeIsSecure: Bool
    public var inferredPort: UInt16 = 0

    // MARK: -- Initializers --

    init?(url: URL) {
        self.common = EndpointCommon()
        #if canImport(Darwin)
        self.url = autoreleasepool { url.absoluteURL }
        #else
        self.url = url.absoluteURL
        #endif
        guard let scheme = self.url.scheme else {
            return nil
        }
        self.schemeIsSecure = Self.schemeIsSecure(scheme)
        if url.port == nil {
            self.inferredPort = Self.port(for: scheme)
        }
    }

    init?(string: String) {
        guard let url = Self.url(from: string) else {
            return nil
        }
        self.init(url: url)
    }

    init?(copying endpoint: URLEndpoint, url: URL) {
        self.init(url: url)
        // Note that this copies most things by value except backing for memory conservation
        self.common = endpoint.common
        if url.port == nil && endpoint.inferredPort != 0 && self.inferredPort == 0 && url.scheme == endpoint.url.scheme
            && !self.schemeIsUnix
        {
            self.inferredPort = endpoint.inferredPort
        }
    }

    // MARK: -- Serialization --

    init?(serializedData: inout [UInt8]) {
        guard let common = EndpointCommon(&serializedData) else {
            return nil
        }
        self.common = common
        var urlString = ""
        var inferredPort: UInt16 = 0
        let result = Deserializer.deserialize(&serializedData) { read throws(DeserializationError) in
            try read.string(&urlString)
            try read.uint16(&inferredPort)
        }
        guard result.isValid else {
            return nil
        }
        guard let url = Self.url(from: urlString) else {
            return nil
        }
        self.url = url
        self.inferredPort = inferredPort
        if let scheme = self.url.scheme {
            self.schemeIsSecure = URLEndpoint.schemeIsSecure(scheme)
        } else {
            self.schemeIsSecure = false
        }
    }

    #if !NETWORK_PRIVATE
    func serialize() -> [UInt8]? {
        let innerBuffer = Serializer.serialize { write in
            write.fixedLengthUTF8(urlString, byteCount: urlString.utf8.count + 1)
        }

        let length = UInt8(8 + innerBuffer.count)
        return Serializer.serialize { write in
            write.uint8(length)
            write.uint8(UInt8(AddressFamily.unspecified.rawValue))
            write.uint16NetworkByteOrder(self.inferredPort)
            write.uint32(Endpoint.EndpointType.EndpointRawType.url.rawValue)
            write.buffer(innerBuffer)
        }
    }
    #endif

    // MARK: -- Comparisons --

    public static func == (lhs: URLEndpoint, rhs: URLEndpoint) -> Bool {
        lhs.isEqual(to: rhs)
    }

    func isEqual(to other: Self, flags: EndpointEqualityFlags = .empty) -> Bool {
        guard common.isEqual(to: other.common, flags: flags) else { return false }
        #if !NETWORK_EMBEDDED
        return url == other.url
        #else
        return false
        #endif
    }

    // MARK: -- Description --

    public func descriptionInternal(redacted: Bool) -> String {
        if redacted {
            "URL#" + redactedHash(self.urlString)
        } else {
            self.urlString
        }
    }

    public var description: String {
        descriptionInternal(redacted: false)
    }

    var redactedDescription: String {
        descriptionInternal(redacted: true)
    }

    // MARK: -- Computed Properties --

    #if !NETWORK_PRIVATE
    var urlString: String {
        #if canImport(Darwin)
        return autoreleasepool { url.absoluteString }
        #else
        return url.absoluteString
        #endif
    }
    #endif

    var domainForPolicy: String {
        name
    }

    var name: String {
        #if canImport(Darwin)
        return autoreleasepool { url.host(percentEncoded: false) ?? "" }
        #else
        return url.host(percentEncoded: false) ?? ""
        #endif
    }

    var port: UInt16 {
        if let port = url.port {
            return UInt16(truncatingIfNeeded: port)
        } else {
            return inferredPort
        }
    }

    var schemeIsUnix: Bool {
        #if !NETWORK_EMBEDDED
        let scheme = url.scheme?.lowercased()
        #else
        let scheme = url.scheme
        #endif
        return scheme == "https+unix" || scheme == "http+unix" || scheme == "wss+unix" || scheme == "ws+unix"
    }

    // MARK: -- Helpers --

    static func schemeIsSecure(_ scheme: String) -> Bool {
        #if !NETWORK_EMBEDDED
        let scheme = scheme.lowercased()
        #endif
        return scheme == "https" || scheme == "wss" || scheme.hasSuffix("+unix")
    }

    // MARK: -- Internal --

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.common)
        #if !NETWORK_EMBEDDED
        hasher.combine(self.url)
        #endif
    }

    #if !NETWORK_PRIVATE
    static func port(for scheme: String) -> UInt16 {
        if scheme == "https" || scheme == "wss" {
            return 443
        }
        if scheme == "http" || scheme == "ws" {
            return 80
        }
        return 0
    }

    static func url(from string: String) -> URL? {
        URL(string: string)
    }
    #endif
}
