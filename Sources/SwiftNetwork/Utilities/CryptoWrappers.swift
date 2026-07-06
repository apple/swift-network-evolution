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

// Wrappers over older Crypto functions when span-based APIs are not available.
// This path exists for compatibility, but is significantly less efficient.

#if !SHIM_CRYPTO_SPAN_APIS
#if canImport(Foundation)
import Foundation
#elseif canImport(SwiftSystem)
import SwiftSystem
#endif

#if canImport(CryptoKit)
internal import CryptoKit
#elseif canImport(Crypto)
@preconcurrency internal import Crypto
#endif

// Availability due to `SwiftCrypto`'s `SymmetricKey`
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension SymmetricKey {
    var bytes: RawSpan {
        @_lifetime(self)
        _read {
            // This hack only works when we're very careful to keep the key
            // alive in the caller.
            let buffer = self.withUnsafeBytes { $0 }
            yield buffer.bytes
        }
    }
}

// Availability due to `SwiftCrypto`'s `AES.GCM.Nonce`
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AES.GCM.Nonce {
    init(copying bytes: RawSpan) throws(CryptoKitMetaError) {
        self = try bytes.withUnsafeBytes { nonceBuffer throws(CryptoKitMetaError) in
            try AES.GCM.Nonce(data: nonceBuffer)
        }
    }
}

// Availability due to `SwiftCrypto`'s `AES.GCM`
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AES.GCM {
    static func seal(
        inPlace message: inout MutableRawSpan,
        using key: SymmetricKey,
        nonce: AES.GCM.Nonce,
        authenticating authenticatedData: RawSpan? = nil,
        tag: inout OutputRawSpan
    ) throws(CryptoKitMetaError) {
        let sealedBox = try message.withUnsafeBytes { messageBufferIn throws(CryptoKitMetaError) in
            let messageBuffer: any DataProtocol
            if messageBufferIn.count > 0 {
                messageBuffer = messageBufferIn
            } else {
                messageBuffer = [UInt8]()
            }
            if let authenticatedData {
                return try authenticatedData.withUnsafeBytes { authenticatedDataBuffer throws(CryptoKitMetaError) in
                    try seal(messageBuffer, using: key, nonce: nonce, authenticating: authenticatedDataBuffer)
                }
            } else {
                return try seal(messageBuffer, using: key, nonce: nonce)
            }
        }

        message.withUnsafeMutableBytes { messageBytes in
            if messageBytes.isEmpty {
                return
            }
            sealedBox.ciphertext.copyBytes(to: messageBytes)
        }

        tag.withUnsafeMutableBytes { tagBuffer, initializedCount in
            sealedBox.tag.copyBytes(to: tagBuffer)
            initializedCount += sealedBox.tag.count
        }
    }

    static func open(
        inPlace message: inout MutableRawSpan,
        using key: SymmetricKey,
        nonce: AES.GCM.Nonce,
        authenticating authenticatedData: RawSpan? = nil,
        tag: RawSpan
    ) throws(CryptoKitMetaError) {
        let sealedBox = try message.withUnsafeBytes { messageBuffer in
            try tag.withUnsafeBytes { tagBuffer throws(CryptoKitMetaError) in
                try AES.GCM.SealedBox(nonce: nonce, ciphertext: messageBuffer, tag: tagBuffer)
            }
        }

        let plaintext: Data
        if let authenticatedData {
            plaintext = try authenticatedData.withUnsafeBytes { authenticatedDataBuffer throws(CryptoKitMetaError) in
                try open(sealedBox, using: key, authenticating: authenticatedDataBuffer)
            }
        } else {
            plaintext = try open(sealedBox, using: key)
        }

        message.withUnsafeMutableBytes { messageBuffer in
            if messageBuffer.isEmpty {
                return
            }
            plaintext.copyBytes(to: messageBuffer)
        }
    }
}

// Availability due to `SwiftCrypto`'s `ChaChaPoly.Nonce`
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension ChaChaPoly.Nonce {
    init(copying bytes: RawSpan) throws(CryptoKitMetaError) {
        self = try bytes.withUnsafeBytes { nonceBuffer throws(CryptoKitMetaError) in
            try ChaChaPoly.Nonce(data: nonceBuffer)
        }
    }
}

// Availability due to `SwiftCrypto`'s `ChaChaPoly`
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension ChaChaPoly {
    static func seal(
        inPlace message: inout MutableRawSpan,
        using key: SymmetricKey,
        nonce: ChaChaPoly.Nonce,
        authenticating authenticatedData: RawSpan? = nil,
        tag: inout OutputRawSpan
    ) throws(CryptoKitMetaError) {
        let sealedBox = try message.withUnsafeBytes { messageBufferIn throws(CryptoKitMetaError) in
            let messageBuffer: any DataProtocol
            if messageBufferIn.count > 0 {
                messageBuffer = messageBufferIn
            } else {
                messageBuffer = [UInt8]()
            }
            if let authenticatedData {
                return try authenticatedData.withUnsafeBytes { authenticatedDataBuffer throws(CryptoKitMetaError) in
                    try seal(messageBuffer, using: key, nonce: nonce, authenticating: authenticatedDataBuffer)
                }
            } else {
                return try seal(messageBuffer, using: key, nonce: nonce)
            }
        }

        _ = message.withUnsafeMutableBytes { messageBytes in
            sealedBox.ciphertext.copyBytes(to: messageBytes)
        }

        tag.withUnsafeMutableBytes { tagBuffer, initializedCount in
            sealedBox.tag.copyBytes(to: tagBuffer)
            initializedCount += sealedBox.tag.count
        }
    }

    static func open(
        inPlace message: inout MutableRawSpan,
        using key: SymmetricKey,
        nonce: ChaChaPoly.Nonce,
        authenticating authenticatedData: RawSpan? = nil,
        tag: RawSpan
    ) throws(CryptoKitMetaError) {
        let sealedBox = try message.withUnsafeBytes { messageBuffer in
            try tag.withUnsafeBytes { tagBuffer throws(CryptoKitMetaError) in
                try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: messageBuffer, tag: tagBuffer)
            }
        }

        let plaintext: Data
        if let authenticatedData {
            plaintext = try authenticatedData.withUnsafeBytes { authenticatedDataBuffer throws(CryptoKitMetaError) in
                try open(sealedBox, using: key, authenticating: authenticatedDataBuffer)
            }
        } else {
            plaintext = try open(sealedBox, using: key)
        }

        _ = message.withUnsafeMutableBytes { messageBuffer in
            plaintext.copyBytes(to: messageBuffer)
        }
    }
}
#endif
