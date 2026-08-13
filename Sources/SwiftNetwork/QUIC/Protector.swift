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
#if IMPORT_CRYPTO || IMPORT_SWIFTTLS

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

#if canImport(CryptoKit)
internal import CryptoKit
// Availability due to `CryptoKit`'s `SymmetricKey`
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
typealias SymmetricKey = CryptoKit.SymmetricKey
#elseif canImport(Crypto)
@preconcurrency internal import Crypto
#endif

#if canImport(CryptoExtras)
internal import CryptoExtras
#endif

#if canImport(CommonCrypto)
internal import CommonCrypto
#endif

#if canImport(Foundation) && !NETWORK_EMBEDDED
import Foundation
#endif

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if IMPORT_SWIFTTLS && canImport(SwiftTLS)
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

// Availability due to Swift's `InlineArray` (`[12 of UInt8]`)
@available(anyAppleOS 26, *)
typealias ProtectorNonce = [12 of UInt8]
// Availability due to Swift's `InlineArray` (`[12 of UInt8]`)
@available(anyAppleOS 26, *)
typealias ProtectorIV = [12 of UInt8]

// Crypto returns an IV in SymmetricKey format, but to speed up performance, we convert it to an InlineArray.
@available(Network 0.1.0, *)
extension ProtectorIV {
    init(_ key: SymmetricKey) {
        precondition(key.bitCount == 96)
        self = key.withUnsafeBytes { buf in
            buf.loadUnaligned(as: ProtectorIV.self)
        }
    }
}

enum SecFramerError: Int, Error {
    case unsupportedAlgorithm
    case sealingFailed
    case noFramerFound
    case headerProtectionFailed
    case openFailed
}

@available(Network 0.1.0, *)
enum TLSEncryptionLevel: CaseIterable {
    case initial
    case earlyData
    case handshake
    case application

    init(_ level: SwiftTLSOptions.EncryptionLevel) {
        switch level {
        case .initial:
            self = .initial
        case .earlyData:
            self = .earlyData
        case .handshake:
            self = .handshake
        case .application:
            self = .application
        }
    }

    var keyState: PacketKeyState {
        switch self {
        case .initial:
            return .initial
        case .handshake:
            return .handshake
        case .earlyData:
            return .earlyData
        case .application:
            return .phase0
        }
    }
}

enum TLSCipherSuite: CaseIterable {
    case aesGCM128SHA256
    case aesGCM256SHA384
    case chacha20Poly1350SHA256

    init?(sslCipherSuite: Int) {
        switch sslCipherSuite {
        case 0x1301:
            self = .aesGCM128SHA256
        case 0x1302:
            self = .aesGCM256SHA384
        case 0x1303:
            self = .chacha20Poly1350SHA256
        default:
            return nil
        }
    }

    var keyLength: Int {
        switch self {
        case .aesGCM128SHA256:
            return 16
        case .aesGCM256SHA384, .chacha20Poly1350SHA256:
            return 32
        }
    }

    var ivLength: Int {
        12
    }
}

@available(Network 0.1.0, *)
struct SecFramerKeys: ~Copyable {
    enum KeyType {
        case aesGCM
        case chaChaPoly
    }
    let key: SymmetricKey
    let iv: ProtectorIV
    let headerProtectionKey: SymmetricKey
    var savedWriteSecret: SymmetricKey?
    var savedReadSecret: SymmetricKey?
    let type: KeyType
    let isEmpty: Bool
    let log: LogPrefixer

    init(
        key: SymmetricKey,
        iv: ProtectorIV,
        headerProtectionKey: SymmetricKey,
        savedWriteSecret: SymmetricKey? = nil,
        savedReadSecret: SymmetricKey? = nil,
        type: KeyType,
        log: LogPrefixer,
        isEmpty: Bool = false
    ) {
        self.key = key
        self.iv = iv
        self.headerProtectionKey = headerProtectionKey
        self.savedWriteSecret = savedWriteSecret
        self.savedReadSecret = savedReadSecret
        self.type = type
        self.log = log
        self.isEmpty = isEmpty
    }
    var size: Int {
        key.bitCount
    }
    // Empty value to represent a blank set of keys
    static func empty(type: KeyType) -> SecFramerKeys {
        let emptyKey = SymmetricKey(data: [])
        let emptyIv = ProtectorIV(repeating: 0)
        return SecFramerKeys(
            key: emptyKey,
            iv: emptyIv,
            headerProtectionKey: emptyKey,
            type: type,
            log: LogPrefixer(),
            isEmpty: true
        )
    }
}

@available(Network 0.1.0, *)
protocol SecFramerProtocol: ~Copyable {
    static func createKeyStorage(
        key: SymmetricKey,
        iv: ProtectorIV,
        headerProtectionKey: SymmetricKey,
        savedWriteSecret: SymmetricKey?,
        savedReadSecret: SymmetricKey?,
        log: LogPrefixer
    ) -> SecFramerKeys
    static func seal(
        keys: borrowing SecFramerKeys,
        nonce: ProtectorNonce,
        packet: inout Packet,
        frame: inout Frame
    )
        throws(QUICError)
    static func open(
        keys: borrowing SecFramerKeys,
        nonce: ProtectorNonce,
        packet: inout Packet,
        frame: inout Frame
    )
        throws(QUICError)
    static func headerProtection(
        keys: borrowing SecFramerKeys,
        packet: inout Packet,
        frame: inout Frame,
        mask: inout MutableRawSpan,
        loggingOperation: StaticString
    ) throws(QUICError)
}

@available(Network 0.1.0, *)
struct SecFramerAESGCM: ~Copyable, SecFramerProtocol {

    static func createKeyStorage(
        key: SymmetricKey,
        iv: ProtectorIV,
        headerProtectionKey: SymmetricKey,
        savedWriteSecret: SymmetricKey? = nil,
        savedReadSecret: SymmetricKey? = nil,
        log: LogPrefixer
    ) -> SecFramerKeys {
        guard _slowPath(key.bitCount == headerProtectionKey.bitCount) else {
            fatalError("invalid key or headerProtectionKey")
        }
        guard _slowPath(key.bitCount == 128 || key.bitCount == 256) else {
            fatalError("invalid key size")
        }
        return SecFramerKeys(
            key: key,
            iv: iv,
            headerProtectionKey: headerProtectionKey,
            savedWriteSecret: savedWriteSecret,
            savedReadSecret: savedReadSecret,
            type: .aesGCM,
            log: log
        )
    }

    static func seal(
        keys: borrowing SecFramerKeys,
        nonce: ProtectorNonce,
        packet: inout Packet,
        frame: inout Frame
    ) throws(QUICError) {
        #if !DisableDebugLogging
        let size = keys.size
        let headerLength = packet.headerLength
        let payloadLength = packet.payloadLength
        let tagLength = packet.tagLength
        keys.log.datapath(
            "sealing for AESGCM\(size), nonce len \(nonce.count), header \(headerLength), payload \(payloadLength) tag \(tagLength)"
        )
        #endif

        guard var buffer = frame.mutableSpan else {
            throw QUICError.protector(SecFramerError.sealingFailed)
        }
        do {
            let buffer = buffer.withUnsafeMutableBytes { $0 }
            let payload = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.payloadRange])
            var payloadSpan = payload.mutableBytes
            let headerSpan = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.headerRange])
                .bytes
            let tag = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.tagRange])
            var tagSpan = OutputRawSpan(buffer: tag, initializedCount: 0)
            let nonce = try AES.GCM.Nonce(copying: nonce.span.bytes)
            try AES.GCM.seal(
                inPlace: &payloadSpan,
                using: keys.key,
                nonce: nonce,
                authenticating: headerSpan,
                tag: &tagSpan
            )
            _ = tagSpan.finalize(for: tag)
        } catch {
            throw QUICError.protector(SecFramerError.sealingFailed)
        }
    }

    static func headerProtection(
        keys: borrowing SecFramerKeys,
        packet: inout Packet,
        frame: inout Frame,
        mask: inout MutableRawSpan,
        loggingOperation: StaticString
    ) throws(QUICError) {
        precondition(packet.sampleRange.count == Protector.aes128BlockSize)
        #if !DisableDebugLogging
        let size = keys.size
        let range = packet.sampleRange
        keys.log.datapath("\(loggingOperation) header for AES\(size), sample \(range)")
        #endif

        guard var buffer = frame.mutableSpan else {
            throw QUICError.protector(SecFramerError.headerProtectionFailed)
        }

        #if canImport(CommonCrypto)
        let packetBuffer = buffer.withUnsafeMutableBytes { $0 }
        let result = keys.headerProtectionKey.withUnsafeBytes { headerKeyBuffer in
            Swift.withUnsafeBytes(of: keys.iv) { ivBuffer in
                mask.withUnsafeMutableBytes { maskBuffer in
                    let operation = CCOperation(kCCEncrypt)
                    let algorithm = CCAlgorithm(kCCAlgorithmAES)
                    let options = CCOptions(kCCOptionECBMode)
                    var bytesEncrypted = 0

                    return CCCrypt(
                        operation,
                        algorithm,
                        options,
                        headerKeyBuffer.baseAddress!,
                        keys.headerProtectionKey.bitCount / 8,
                        ivBuffer.baseAddress!,
                        packetBuffer.baseAddress! + packet.sampleRange.lowerBound,
                        packet.sampleRange.count,
                        maskBuffer.baseAddress!,
                        kCCBlockSizeAES128,
                        &bytesEncrypted
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            keys.log.error("Unable to \(loggingOperation) header: \(result)")
            throw QUICError.protector(.headerProtectionFailed)
        }
        #elseif canImport(CryptoExtras) || NETWORK_STANDALONE
        do {
            let buffer = buffer.withUnsafeMutableBytes { $0 }
            // Note that this copy is needed to make sure we are not operating on the buffer directly.
            // It is roughly equivalent to dataIn / dataOut concept from CCCrypt.
            let packetBuffer = UnsafeMutableRawBufferPointer(
                start: buffer.baseAddress! + packet.sampleRange.lowerBound,
                count: packet.sampleRange.count
            )

            // NOTE: Using result here to work around a withUnsafeMutableBytes that
            // uses rethrows rather than typed throws.
            try mask.withUnsafeMutableBytes { (dst) -> Result<(), CryptoKitMetaError> in
                var dst = dst
                dst.copyBytes(from: packetBuffer)
                do throws(CryptoKitMetaError) {
                    return .success(try AES.permute(&dst, key: keys.headerProtectionKey))
                } catch {
                    return .failure(error)
                }
            }.get()
        } catch {
            keys.log.error("Unable to \(loggingOperation) header: \(error)")
            throw QUICError.protector(.headerProtectionFailed)
        }
        #endif
    }

    static func open(
        keys: borrowing SecFramerKeys,
        nonce: ProtectorNonce,
        packet: inout Packet,
        frame: inout Frame
    ) throws(QUICError) {
        #if !DisableDebugLogging
        let size = keys.size
        let headerLength = packet.headerLength
        let payloadLength = packet.payloadLength
        let tagLength = packet.tagLength
        let pn = packet.number.value
        keys.log.datapath(
            "opening for AESGCM\(size), nonce len \(nonce.count), header \(headerLength), payload \(payloadLength), tag \(tagLength), pn \(pn)"
        )
        #endif
        guard var buffer = frame.mutableSpan else {
            keys.log.error("Unclaimed bytes nil")
            throw QUICError.protector(SecFramerError.openFailed)
        }
        do {
            let buffer = buffer.withUnsafeMutableBytes { $0 }
            let header = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.headerRange])
            let payload = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.payloadRange])
            var payloadSpan = payload.mutableBytes
            let tag = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.tagRange])
            let nonce = try AES.GCM.Nonce(copying: nonce.span.bytes)
            try AES.GCM
                .open(
                    inPlace: &payloadSpan,
                    using: keys.key,
                    nonce: nonce,
                    authenticating: header.bytes,
                    tag: tag.bytes
                )
        } catch {
            #if !DisableErrorLogging
            let number = packet.number
            keys.log.error("AES.GCM failed: pn = \(number)")
            #endif
            throw QUICError.protector(SecFramerError.openFailed)
        }
    }
}

#if !NETWORK_EMBEDDED
@available(Network 0.1.0, *)
struct SecFramerChaChaPoly: ~Copyable, SecFramerProtocol {
    static func createKeyStorage(
        key: SymmetricKey,
        iv: ProtectorIV,
        headerProtectionKey: SymmetricKey,
        savedWriteSecret: SymmetricKey? = nil,
        savedReadSecret: SymmetricKey? = nil,
        log: LogPrefixer
    ) -> SecFramerKeys {
        guard _slowPath(key.bitCount == headerProtectionKey.bitCount) else {
            fatalError("invalid key or headerProtectionKey")
        }
        guard _slowPath(key.bitCount == 256) else {
            fatalError("invalid key size")
        }
        return SecFramerKeys(
            key: key,
            iv: iv,
            headerProtectionKey: headerProtectionKey,
            savedWriteSecret: savedWriteSecret,
            savedReadSecret: savedReadSecret,
            type: .chaChaPoly,
            log: log
        )
    }

    static func seal(
        keys: borrowing SecFramerKeys,
        nonce: ProtectorNonce,
        packet: inout Packet,
        frame: inout Frame
    ) throws(QUICError) {
        #if !DisableDebugLogging
        let headerLength = packet.headerLength
        let payloadLength = packet.payloadLength
        let tagLength = packet.tagLength
        keys.log.datapath(
            "sealing for ChaCha20Poly1305, nonce len \(nonce.count), header \(headerLength), payload \(payloadLength) tag \(tagLength)"
        )
        #endif
        guard var buffer = frame.mutableSpan else {
            throw QUICError.protector(SecFramerError.sealingFailed)
        }
        do {
            try buffer.withUnsafeMutableBytes { buffer in
                let payload = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.payloadRange])
                var payloadSpan = payload.mutableBytes
                let headerSpan = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.headerRange])
                    .bytes
                let tag = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.tagRange])
                var tagSpan = OutputRawSpan(buffer: tag, initializedCount: 0)
                let nonce = try ChaChaPoly.Nonce(copying: nonce.span.bytes)
                try ChaChaPoly
                    .seal(
                        inPlace: &payloadSpan,
                        using: keys.key,
                        nonce: nonce,
                        authenticating: headerSpan,
                        tag: &tagSpan
                    )
                _ = tagSpan.finalize(for: tag)
            }
        } catch {
            throw QUICError.protector(SecFramerError.sealingFailed)
        }
    }

    static func headerProtection(
        keys: borrowing SecFramerKeys,
        packet: inout Packet,
        frame: inout Frame,
        mask: inout MutableRawSpan,
        loggingOperation: StaticString
    ) throws(QUICError) {
        precondition(packet.sampleRange.count == 16)
        #if !DisableDebugLogging
        let range = packet.sampleRange
        keys.log.datapath("\(loggingOperation) header for ChaCha20Poly1305, sample \(range)")
        #endif

        guard var buffer = frame.mutableSpan else {
            throw QUICError.protector(.headerProtectionFailed)
        }

        #if canImport(CryptoExtras)
        do {
            let buffer = buffer.withUnsafeMutableBytes { $0 }
            let counter = try Insecure.ChaCha20CTR.Counter(
                data: Array(
                    buffer[packet.sampleRange.lowerBound..<packet.sampleRange.lowerBound + 4]
                )
            )
            let nonce = try Insecure.ChaCha20CTR.Nonce(
                data: Array(
                    buffer[packet.sampleRange.lowerBound + 4..<packet.sampleRange.upperBound]
                )
            )

            let maskStorage = [UInt8](repeating: 0, count: Protector.aes128BlockSize)
            let maskOutput = Array(
                try Insecure.ChaCha20CTR.encrypt(
                    maskStorage,
                    using: keys.headerProtectionKey,
                    counter: counter,
                    nonce: nonce
                )
            )
            mask.withUnsafeMutableBytes { dst in
                dst.copyBytes(from: maskOutput)
            }
        } catch {
            throw QUICError.protector(.headerProtectionFailed)
        }
        #else
        fatalError("not implemented")
        #endif
    }

    static func open(
        keys: borrowing SecFramerKeys,
        nonce: ProtectorNonce,
        packet: inout Packet,
        frame: inout Frame
    ) throws(QUICError) {
        #if !DisableDebugLogging
        let headerLength = packet.headerLength
        let payloadLength = packet.payloadLength
        let tagLength = packet.tagLength
        keys.log.datapath(
            "opening for ChaCha20Poly1305, nonce len \(nonce.count), header \(headerLength), payload \(payloadLength), tag \(tagLength)"
        )
        #endif
        guard var buffer = frame.mutableSpan else {
            keys.log.error("Buffer nil")
            throw QUICError.protector(SecFramerError.openFailed)
        }
        #if !NETWORK_EMBEDDED
        do {
            let buffer = buffer.withUnsafeMutableBytes { $0 }
            let header = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.headerRange]).bytes
            let payload = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.payloadRange])
            var payloadSpan = payload.mutableBytes
            let tag = UnsafeMutableRawBufferPointer(rebasing: buffer[packet.tagRange])
            let nonce = try ChaChaPoly.Nonce(copying: nonce.span.bytes)
            try ChaChaPoly.open(
                inPlace: &payloadSpan,
                using: keys.key,
                nonce: nonce,
                authenticating: header,
                tag: tag.bytes
            )
        } catch {
            keys.log.error("ChaCha dance failed: \(String(describing: error))")
            throw QUICError.protector(SecFramerError.openFailed)
        }
        #endif
    }
}
#endif

@available(Network 0.1.0, *)
struct Protector: ~Copyable, PrefixedLoggable {
    var log: LogPrefixer

    static let initialSecretSize = 32
    static let clientInitialLabel = "client in"
    static let serverInitialLabel = "server in"
    static let keyLabel = "quic key"
    static let ivLabel = "quic iv"
    static let headerProtectionLabel = "quic hp"
    static let keyUpdateLabel = "quic ku"

    static let sha256digestLength = 32

    static let initialKeySize = 16
    static let initialIVSize = 12
    static let initialHeaderProtectionKeySize = 16

    static let aes128BlockSize = 16
    typealias AESBlockStorage = [16 of UInt8]

    // https://www.rfc-editor.org/rfc/rfc9001.html#name-initial-secrets
    static let version1Salt: [UInt8] = [
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c,
        0xad, 0xcc, 0xbb, 0x7f, 0x0a,
    ]

    static let retryKey = SymmetricKey(data: [
        0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68,
        0xc8, 0x4e,
    ])
    // Because AES.GCM.Nonce throws, we have to initialize it in the retryOpen and retrySeal methods.
    static let retryNonceArray: [UInt8] = [
        0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb,
    ]

    private(set) var writeFramer = NetworkRigidArray<SecFramerKeys>(capacity: 5)
    private(set) var readFramer = NetworkRigidArray<SecFramerKeys>(capacity: 5)
    private(set) var isClient: Bool
    private var sequenceNumber = NetworkRigidArray<PacketNumber>(
        repeating: PacketNumber.initial,
        count: PacketNumberSpace.allCases.count
    )

    init(isClient: Bool, destinationCID: QUICConnectionID, logPrefixer: LogPrefixer) {
        self.isClient = isClient
        self.log = logPrefixer
        // N.B. right now the Protector only supports AESGCM
        for _ in 0..<5 {
            writeFramer.append(SecFramerKeys.empty(type: .aesGCM))
            readFramer.append(SecFramerKeys.empty(type: .aesGCM))
        }
        deriveInitialSecrets(destinationCID: destinationCID)
    }

    private func encode(label: String, secretLength: Int) -> [UInt8] {
        let quicLabel = "tls13 "
        let labelLength = quicLabel.utf8.count + label.utf8.count
        // 2 is for the length, 1 byte prefix for each label, 1 byte for context
        let totalLength = 2 + 1 + labelLength + 1
        var result = [UInt8](repeating: 0, count: totalLength)
        var index = 0

        // Encode the length of the secret
        result[index] = UInt8((secretLength >> 8) & 0xff)
        index += 1
        result[index] = UInt8(secretLength & 0xff)
        index += 1
        result[index] = UInt8(labelLength)
        index += 1
        result.replaceSubrange(index..<index + quicLabel.utf8.count, with: quicLabel.utf8)
        index += quicLabel.utf8.count
        result.replaceSubrange(index..<index + label.utf8.count, with: label.utf8)
        index += label.utf8.count
        result[index] = 0

        return result
    }

    private func deriveWithSHA256(
        inputSecret: SymmetricKey,
        label: String,
        outputSecretLength: Int
    ) -> SymmetricKey {
        let encodedLabel = encode(label: label, secretLength: outputSecretLength)
        return HKDF<SHA256>.expand(
            pseudoRandomKey: inputSecret,
            info: encodedLabel,
            outputByteCount: outputSecretLength
        )
    }

    private func deriveWithSHA384(
        inputSecret: SymmetricKey,
        label: String,
        outputSecretLength: Int
    ) -> SymmetricKey {
        let encodedLabel = encode(label: label, secretLength: outputSecretLength)
        return HKDF<SHA384>.expand(
            pseudoRandomKey: inputSecret,
            info: encodedLabel,
            outputByteCount: outputSecretLength
        )
    }

    mutating func deriveInitialSecrets(destinationCID: QUICConnectionID) {

        // QUIC initial packet uses AES-128 SHA256 GCM.
        let inputKeyMaterial = SymmetricKey(data: destinationCID.connectionID)
        let initialSecretExtract = HKDF<SHA256>.extract(
            inputKeyMaterial: inputKeyMaterial,
            salt: Protector.version1Salt
        )
        let initialSecret = SymmetricKey(data: initialSecretExtract)

        precondition(initialSecret.bitCount == 256)
        let exportedLength = Protector.sha256digestLength

        let clientSecret = deriveWithSHA256(
            inputSecret: initialSecret,
            label: Protector.clientInitialLabel,
            outputSecretLength: exportedLength
        )
        let serverSecret = deriveWithSHA256(
            inputSecret: initialSecret,
            label: Protector.serverInitialLabel,
            outputSecretLength: exportedLength
        )

        // Derive the keys
        let clientKey = deriveWithSHA256(
            inputSecret: clientSecret,
            label: Protector.keyLabel,
            outputSecretLength: Protector.initialKeySize
        )
        let serverKey = deriveWithSHA256(
            inputSecret: serverSecret,
            label: Protector.keyLabel,
            outputSecretLength: Protector.initialKeySize
        )

        // Derive the IVs
        let clientIV = ProtectorIV(
            deriveWithSHA256(
                inputSecret: clientSecret,
                label: Protector.ivLabel,
                outputSecretLength: Protector.initialIVSize
            )
        )
        let serverIV = ProtectorIV(
            deriveWithSHA256(
                inputSecret: serverSecret,
                label: Protector.ivLabel,
                outputSecretLength: Protector.initialIVSize
            )
        )

        // Derive the HP key
        let clientHeaderProtectionKey = deriveWithSHA256(
            inputSecret: clientSecret,
            label: Protector.headerProtectionLabel,
            outputSecretLength: Protector.initialHeaderProtectionKeySize
        )
        let serverHeaderProtectionKey = deriveWithSHA256(
            inputSecret: serverSecret,
            label: Protector.headerProtectionLabel,
            outputSecretLength: Protector.initialHeaderProtectionKeySize
        )

        // Install the client (write) keys
        readFramer[PacketKeyState.initial.rawValue] = SecFramerAESGCM.createKeyStorage(
            key: serverKey,
            iv: serverIV,
            headerProtectionKey: serverHeaderProtectionKey,
            log: log
        )
        // Install the server (read) keys
        writeFramer[PacketKeyState.initial.rawValue] = SecFramerAESGCM.createKeyStorage(
            key: clientKey,
            iv: clientIV,
            headerProtectionKey: clientHeaderProtectionKey,
            log: log
        )
        // Swap IVs/framers if we're a server
        if !isClient {
            swapFramers(keyState: .initial)
        }

    }

    mutating func swapFramers(keyState: PacketKeyState) {
        log.debug("Swapping framers since we're a server")
        swap(&readFramer[keyState.rawValue], &writeFramer[keyState.rawValue])
    }

    /// Prepares a nonce from the given IV bytes.
    ///
    /// - Parameters:
    ///   - iv: The IV used to derive the nonce.
    ///   - packetNumber: The packet number XOR'd into the right side of the IV.
    @inline(__always)
    private static func prepareNonce(
        iv: ProtectorIV,
        packetNumber: PacketNumber
    ) -> ProtectorNonce {
        // Algorithm:
        // 1. left-pad the packet number with the path_id to make it the same size as
        // the IV
        // 2. XOR the result with the right IV to form the nonce
        let pn = packetNumber.value
        let nonce: ProtectorNonce = [
            iv[0],
            iv[1],
            iv[2],
            iv[3],
            // Set the 8-right bytes to the packet number.
            // Note that we assume the packet number is in little-endian and
            // convert it to big-endian.
            iv[4] ^ UInt8((pn >> 56) & 0xff),
            iv[5] ^ UInt8((pn >> 48) & 0xff),
            iv[6] ^ UInt8((pn >> 40) & 0xff),
            iv[7] ^ UInt8((pn >> 32) & 0xff),
            iv[8] ^ UInt8((pn >> 24) & 0xff),
            iv[9] ^ UInt8((pn >> 16) & 0xff),
            iv[10] ^ UInt8((pn >> 8) & 0xff),
            iv[11] ^ UInt8(pn & 0xff),
        ]
        return nonce
    }

    private static func processHeaderProtection(
        packet: inout Packet,
        frame: inout Frame,
        mask: RawSpan
    ) {
        guard var buffer = frame.mutableSpan else {
            return
        }

        if packet.longHeader {
            buffer[0] ^= mask[0] & 0x0f
        } else {
            buffer[0] ^= mask[0] & 0x1f
        }

        let packetNumberLength: Int
        let packetNumberOffset: Int
        if packet.number == .none {
            // When opening/decrypting, the packet number is unknown and decoded from the first byte like so:
            packetNumberLength = Int(buffer[0] & 0x03) + 1
            // Packet number offset must always be set, otherwise sampleRange doesn't work before we get here.
            packetNumberOffset = packet.packetNumberOffset!
        } else {
            // When sealing/encrypting, the packet number is known but may be overridden
            if let length = packet.overrideSentNumberSize?.rawValue {
                packetNumberLength = length
            } else {
                // The packet number would not have been written if it doesn't encode
                packetNumberLength = try! packet.number.encode(lastAcked: packet.lastAcked).size
                    .rawValue
            }
            packetNumberOffset = packet.packetNumberOffset!
        }

        for i in 0..<packetNumberLength {
            buffer[packetNumberOffset + i] ^= mask[i + 1]
        }
    }

    private static func sealInner(
        _ packet: inout Packet,
        frame: inout Frame,
        keys: borrowing SecFramerKeys
    ) throws(QUICError) {
        var mask = Protector.AESBlockStorage(repeating: 0)
        switch keys.type {
        case .aesGCM:
            let nonce = prepareNonce(iv: keys.iv, packetNumber: packet.number)
            try SecFramerAESGCM.seal(
                keys: keys,
                nonce: nonce,
                packet: &packet,
                frame: &frame
            )
            var maskSpan = mask.mutableSpan
            var maskRawSpan = maskSpan.mutableBytes
            try SecFramerAESGCM.headerProtection(
                keys: keys,
                packet: &packet,
                frame: &frame,
                mask: &maskRawSpan,
                loggingOperation: "seal"
            )
            Protector.processHeaderProtection(
                packet: &packet,
                frame: &frame,
                mask: mask.span.bytes
            )
        case .chaChaPoly:
            #if !NETWORK_EMBEDDED
            let nonce = prepareNonce(iv: keys.iv, packetNumber: packet.number)
            try SecFramerChaChaPoly.seal(
                keys: keys,
                nonce: nonce,
                packet: &packet,
                frame: &frame
            )
            var maskSpan = mask.mutableSpan
            var maskRawSpan = maskSpan.mutableBytes
            try SecFramerChaChaPoly.headerProtection(
                keys: keys,
                packet: &packet,
                frame: &frame,
                mask: &maskRawSpan,
                loggingOperation: "seal"
            )
            Protector.processHeaderProtection(
                packet: &packet,
                frame: &frame,
                mask: mask.span.bytes
            )
            #else
            throw (.protector(.unsupportedAlgorithm))
            #endif
        }
    }

    mutating func seal(_ packet: inout Packet, frame: inout Frame) throws(QUICError) {
        let signpostInterval = QUICSignpost.sealBegin(
            keyState: packet.keyState!.description,
            packetNumber: packet.number
        )
        guard let keyStateIndex: Int = packet.keyState?.rawValue else {
            throw QUICError.protector(SecFramerError.noFramerFound)
        }
        try Self.sealInner(&packet, frame: &frame, keys: writeFramer[keyStateIndex])
        QUICSignpost.sealEnd(signpostInterval)
        // Upon success, increment the sequence number all the way to the
        // the last recently used one because there could be gaps.
        sequenceNumber[packet.numberSpace] = packet.number + 1
    }

    func openHeaderInner(
        keys: borrowing SecFramerKeys,
        packet: inout Packet,
        frame: inout Frame
    ) throws(QUICError) {
        var mask = Protector.AESBlockStorage(repeating: 0)
        switch keys.type {
        case .aesGCM:
            var maskSpan = mask.mutableSpan
            var maskRawSpan = maskSpan.mutableBytes
            try SecFramerAESGCM.headerProtection(
                keys: keys,
                packet: &packet,
                frame: &frame,
                mask: &maskRawSpan,
                loggingOperation: "open"
            )
            Protector.processHeaderProtection(packet: &packet, frame: &frame, mask: mask.span.bytes)
        case .chaChaPoly:
            #if !NETWORK_EMBEDDED
            var maskSpan = mask.mutableSpan
            var maskRawSpan = maskSpan.mutableBytes
            try SecFramerChaChaPoly.headerProtection(
                keys: keys,
                packet: &packet,
                frame: &frame,
                mask: &maskRawSpan,
                loggingOperation: "open"
            )
            Protector.processHeaderProtection(packet: &packet, frame: &frame, mask: mask.span.bytes)
            #else
            throw (.protector(.unsupportedAlgorithm))
            #endif
        }
    }

    func openHeader(_ packet: inout Packet, frame: inout Frame) throws(QUICError) {
        do throws(QUICError) {
            guard let keyStateIndex: Int = packet.keyState?.rawValue else {
                throw QUICError.protector(SecFramerError.noFramerFound)
            }
            try openHeaderInner(keys: readFramer[keyStateIndex], packet: &packet, frame: &frame)
        } catch QUICError.protector(SecFramerError.noFramerFound) {
            throw QUICError.protector(SecFramerError.noFramerFound)
        } catch {
            log.error("openHeader failed: \(error)")
            throw QUICError.protector(SecFramerError.openFailed)
        }
    }

    static func openInner(
        keys: borrowing SecFramerKeys,
        packet: inout Packet,
        frame: inout Frame
    ) throws(QUICError) {
        switch keys.type {
        case .aesGCM:
            let nonce = prepareNonce(iv: keys.iv, packetNumber: packet.number)
            try SecFramerAESGCM.open(keys: keys, nonce: nonce, packet: &packet, frame: &frame)
        case .chaChaPoly:
            #if !NETWORK_EMBEDDED
            let nonce = prepareNonce(iv: keys.iv, packetNumber: packet.number)
            try SecFramerChaChaPoly.open(keys: keys, nonce: nonce, packet: &packet, frame: &frame)
            #else
            throw (.protector(.unsupportedAlgorithm))
            #endif
        }
    }

    func open(_ packet: inout Packet, frame: inout Frame) throws(QUICError) {
        let signpostInterval = QUICSignpost.openBegin(
            keyState: packet.keyState!.description,
            packetNumber: packet.number
        )
        guard let keyStateIndex: Int = packet.keyState?.rawValue else {
            throw QUICError.protector(SecFramerError.noFramerFound)
        }
        try Self.openInner(keys: readFramer[keyStateIndex], packet: &packet, frame: &frame)
        QUICSignpost.openEnd(signpostInterval)
    }

    mutating func keyUpdate(
        for encryptionLevel: TLSEncryptionLevel,
        cipherSuite: TLSCipherSuite,
        secret: SymmetricKey,
        isWrite: Bool
    ) {
        let keyState = encryptionLevel.keyState
        let key: SymmetricKey
        let iv: ProtectorIV
        let headerKey: SymmetricKey

        if cipherSuite == .aesGCM256SHA384 {
            // Derive the key
            key = deriveWithSHA384(
                inputSecret: secret,
                label: Protector.keyLabel,
                outputSecretLength: cipherSuite.keyLength
            )
            // Derive the IV
            iv = ProtectorIV(
                deriveWithSHA384(
                    inputSecret: secret,
                    label: Protector.ivLabel,
                    outputSecretLength: cipherSuite.ivLength
                )
            )
            // Derive the HP key
            headerKey = deriveWithSHA384(
                inputSecret: secret,
                label: Protector.headerProtectionLabel,
                outputSecretLength: cipherSuite.keyLength
            )
        } else {
            // Derive the key
            key = deriveWithSHA256(
                inputSecret: secret,
                label: Protector.keyLabel,
                outputSecretLength: cipherSuite.keyLength
            )
            // Derive the IV
            iv = ProtectorIV(
                deriveWithSHA256(
                    inputSecret: secret,
                    label: Protector.ivLabel,
                    outputSecretLength: cipherSuite.ivLength
                )
            )
            // Derive the HP key
            headerKey = deriveWithSHA256(
                inputSecret: secret,
                label: Protector.headerProtectionLabel,
                outputSecretLength: cipherSuite.keyLength
            )
        }
        // Create the framer and ave the application secrets so we can rotate keys.
        switch cipherSuite {
        case .aesGCM128SHA256, .aesGCM256SHA384:
            var aesFramer = SecFramerKeys(
                key: key,
                iv: iv,
                headerProtectionKey: headerKey,
                type: .aesGCM,
                log: log
            )
            if isWrite {
                if encryptionLevel == .application {
                    aesFramer.savedWriteSecret = secret
                }
                writeFramer[keyState.rawValue] = aesFramer
            } else {
                if encryptionLevel == .application {
                    aesFramer.savedReadSecret = secret
                }
                readFramer[keyState.rawValue] = aesFramer
            }
        case .chacha20Poly1350SHA256:
            var chachaFramer = SecFramerKeys(
                key: key,
                iv: iv,
                headerProtectionKey: headerKey,
                type: .chaChaPoly,
                log: log
            )
            if isWrite {
                if encryptionLevel == .application {
                    chachaFramer.savedWriteSecret = secret
                }
                writeFramer[keyState.rawValue] = chachaFramer
            } else {
                if encryptionLevel == .application {
                    chachaFramer.savedReadSecret = secret
                }
                readFramer[keyState.rawValue] = chachaFramer
            }
        }
    }

    private mutating func trafficUpdateInner(
        key: SymmetricKey,
        iv: ProtectorIV,
        savedReadSecret: SymmetricKey?,
        savedWriteSecret: SymmetricKey?,
        size: Int,
        headerProtectionKey: SymmetricKey,
        type: SecFramerKeys.KeyType,
        nextKeyState: PacketKeyState,
        previousKeyState: PacketKeyState,
        isWrite: Bool
    ) {
        var sha384 = false
        var keySize: Int  // In bytes
        var ivSize: Int  // In bytes
        let previousSecret: SymmetricKey
        switch type {
        case .aesGCM:
            previousSecret = isWrite ? savedWriteSecret! : savedReadSecret!
            if size == 256 {
                sha384 = true
            }
            keySize = key.bitCount / 8
            ivSize = iv.count
        case .chaChaPoly:
            previousSecret =
                isWrite ? savedWriteSecret! : savedReadSecret!
            keySize = key.bitCount / 8
            ivSize = iv.count
        }
        let keyUpdateSecret: SymmetricKey
        let key: SymmetricKey
        let iv: ProtectorIV
        if sha384 {
            // Derive the new secret
            keyUpdateSecret = deriveWithSHA384(
                inputSecret: previousSecret,
                label: Protector.keyUpdateLabel,
                outputSecretLength: previousSecret.bitCount / 8
            )
            // Derive the key
            key = deriveWithSHA384(
                inputSecret: keyUpdateSecret,
                label: Protector.keyLabel,
                outputSecretLength: keySize
            )
            // Derive the IV
            iv = ProtectorIV(
                deriveWithSHA384(
                    inputSecret: keyUpdateSecret,
                    label: Protector.ivLabel,
                    outputSecretLength: ivSize
                )
            )
        } else {
            // Derive the new secret
            keyUpdateSecret = deriveWithSHA256(
                inputSecret: previousSecret,
                label: Protector.keyUpdateLabel,
                outputSecretLength: previousSecret.bitCount / 8
            )
            // Derive the key
            key = deriveWithSHA256(
                inputSecret: keyUpdateSecret,
                label: Protector.keyLabel,
                outputSecretLength: keySize
            )
            // Derive the IV
            iv = ProtectorIV(
                deriveWithSHA256(
                    inputSecret: keyUpdateSecret,
                    label: Protector.ivLabel,
                    outputSecretLength: ivSize
                )
            )
        }
        // N.B.: we don't derive the HP when rotating keys.
        // Save the application secrets so we can rotate keys.
        switch type {
        case .aesGCM:
            var nextFramer = SecFramerKeys(
                key: key,
                iv: iv,
                headerProtectionKey: headerProtectionKey,
                type: .aesGCM,
                log: log
            )
            if isWrite {
                nextFramer.savedWriteSecret = keyUpdateSecret
                writeFramer[nextKeyState.rawValue] = nextFramer
            } else {
                nextFramer.savedReadSecret = keyUpdateSecret
                readFramer[nextKeyState.rawValue] = nextFramer
            }
        case .chaChaPoly:
            var nextFramer = SecFramerKeys(
                key: key,
                iv: iv,
                headerProtectionKey: headerProtectionKey,
                type: .chaChaPoly,
                log: log
            )
            if isWrite {
                nextFramer.savedWriteSecret = keyUpdateSecret
                writeFramer[nextKeyState.rawValue] = nextFramer
            } else {
                nextFramer.savedReadSecret = keyUpdateSecret
                readFramer[nextKeyState.rawValue] = nextFramer
            }
        }
    }

    private mutating func trafficUpdate(previousKeyState: PacketKeyState, isWrite: Bool) {
        precondition(previousKeyState == .phase0 || previousKeyState == .phase1)
        let nextKeyState: PacketKeyState = previousKeyState == .phase0 ? .phase1 : .phase0
        // N.B. Passing SecFramerKeys by a borrowing reference resulted in an overlapping access issue with self
        if isWrite {
            trafficUpdateInner(
                key: writeFramer[previousKeyState.rawValue].key,
                iv: writeFramer[previousKeyState.rawValue].iv,
                savedReadSecret: writeFramer[previousKeyState.rawValue].savedReadSecret,
                savedWriteSecret: writeFramer[previousKeyState.rawValue].savedWriteSecret,
                size: writeFramer[previousKeyState.rawValue].size,
                headerProtectionKey: writeFramer[previousKeyState.rawValue].headerProtectionKey,
                type: writeFramer[previousKeyState.rawValue].type,
                nextKeyState: nextKeyState,
                previousKeyState: previousKeyState,
                isWrite: isWrite
            )
        } else {
            trafficUpdateInner(
                key: readFramer[previousKeyState.rawValue].key,
                iv: readFramer[previousKeyState.rawValue].iv,
                savedReadSecret: readFramer[previousKeyState.rawValue].savedReadSecret,
                savedWriteSecret: readFramer[previousKeyState.rawValue].savedWriteSecret,
                size: readFramer[previousKeyState.rawValue].size,
                headerProtectionKey: readFramer[previousKeyState.rawValue].headerProtectionKey,
                type: readFramer[previousKeyState.rawValue].type,
                nextKeyState: nextKeyState,
                previousKeyState: previousKeyState,
                isWrite: isWrite
            )
        }
    }

    mutating func trafficUpdate(previousKeyState: PacketKeyState) {
        trafficUpdate(previousKeyState: previousKeyState, isWrite: false)
        trafficUpdate(previousKeyState: previousKeyState, isWrite: true)
    }

    @inline(__always)
    func getPacketNumber(
        for packetNumberSpace: PacketNumberSpace
    ) -> PacketNumber {
        /*
         * TODO? An endpoint that acknowledges packets it has not received might cause
         * a congestion controller to permit sending at rates beyond what the
         * network supports.  An endpoint MAY skip packet numbers when sending
         * packets to detect this behavior.  An endpoint can then immediately
         * close the connection with a connection error of type PROTOCOL_VIOLATION.
         */
        sequenceNumber[packetNumberSpace]
    }

    @inline(__always)
    private func keyType(keys: borrowing SecFramerKeys) -> SecFramerKeys.KeyType {
        keys.type
    }

    mutating func drop(keyState: PacketKeyState) {
        log.info("Dropping keys for state: \(keyState.description)")
        let readType: SecFramerKeys.KeyType = keyType(keys: readFramer[keyState.rawValue])
        let writeType: SecFramerKeys.KeyType = keyType(keys: writeFramer[keyState.rawValue])
        readFramer[keyState.rawValue] = SecFramerKeys.empty(type: readType)
        writeFramer[keyState.rawValue] = SecFramerKeys.empty(type: writeType)
    }

    @inline(__always)
    func sealKeyReady(for keyState: PacketKeyState) -> Bool {
        !keysReadyInner(keys: writeFramer[keyState.rawValue])
    }

    @inline(__always)
    func openKeyReady(for keyState: PacketKeyState) -> Bool {
        !keysReadyInner(keys: readFramer[keyState.rawValue])
    }

    @inline(__always)
    private func keysReadyInner(keys: borrowing SecFramerKeys) -> Bool {
        keys.isEmpty
    }

    @inline(__always)
    func keysReady(for keyState: PacketKeyState) -> Bool {
        !keysReadyInner(keys: readFramer[keyState.rawValue])
            && !keysReadyInner(keys: writeFramer[keyState.rawValue])
    }

    @inline(__always)
    func getTagSize(for keyState: PacketKeyState?) -> UInt8 {
        16
    }

    static func openRetry(retryPseudo: RawSpan, retryTag: RawSpan) throws(QUICError) {
        precondition(retryTag.byteCount == 16)
        do {
            var ciphertext = MutableRawSpan()
            let nonce = try AES.GCM.Nonce(copying: retryNonceArray.span.bytes)
            try AES.GCM.open(
                inPlace: &ciphertext,
                using: retryKey,
                nonce: nonce,
                authenticating: retryPseudo,
                tag: retryTag
            )
        } catch {
            Logger.proto.error("Failed to open retry packet")
            throw QUICError.protector(SecFramerError.openFailed)
        }
    }

    static func sealRetry(_ retryPseudo: RawSpan) throws(QUICError) -> [UInt8] {
        var tag = [UInt8](repeating: 0, count: 16)
        var tagSpan = tag.mutableSpan
        try tagSpan.withUnsafeMutableBytes { (tagBuffer) throws(QUICError) in
            var tagOutputSpan = OutputRawSpan(buffer: tagBuffer, initializedCount: 0)
            var ciphertext = MutableRawSpan()
            do throws(CryptoKitMetaError) {
                let nonce = try AES.GCM.Nonce(copying: retryNonceArray.span.bytes)
                try AES.GCM.seal(
                    inPlace: &ciphertext,
                    using: retryKey,
                    nonce: nonce,
                    authenticating: retryPseudo,
                    tag: &tagOutputSpan
                )
                _ = tagOutputSpan.finalize(for: tagBuffer)
            } catch {
                Logger.proto.error("Failed to seal retry box: \(error)")
                throw QUICError.protector(SecFramerError.sealingFailed)
            }
        }
        return tag
    }
}

#else

// Stub implementation
@available(Network 0.1.0, *)
struct Protector: ~Copyable, PrefixedLoggable {
    var log: LogPrefixer
    private let isClient: Bool
    private var sequenceNumber: [PacketNumberSpace: Int64] = [:]

    init(isClient: Bool, destinationCID: QUICConnectionID, logPrefixer: LogPrefixer) {
        self.isClient = isClient
        self.log = logPrefixer
        for space in PacketNumberSpace.allCases {
            sequenceNumber[space] = 0
        }
    }

    func getPacketNumber(
        for packetNumberSpace: PacketNumberSpace
    ) -> PacketNumber {
        PacketNumber(sequenceNumber[packetNumberSpace]!)
    }

    func getTagSize(for keyState: PacketKeyState?) -> UInt8 {
        16
    }

    func sealKeyReady(for keyState: PacketKeyState) -> Bool {
        true
    }

    func seal(_ packet: inout Packet, frame: inout Frame) throws(QUICError) {
    }

    func deriveInitialSecrets(destinationCID: QUICConnectionID) {
    }

    func openKeyReady(for keyState: PacketKeyState) -> Bool {
        true
    }

    func openHeader(_ packet: inout Packet, frame: inout Frame) throws(QUICError) {
    }

    func trafficUpdate(previousKeyState: PacketKeyState) {
    }

    func open(_ packet: inout Packet, frame: inout Frame) throws(QUICError) {
    }

    func drop(keyState: PacketKeyState) {
    }

    static func sealRetry(_ retryPseudo: RawSpan) throws(QUICError) -> [UInt8] {
        []
    }

    static func openRetry(retryPseudo: RawSpan, retryTag: RawSpan) throws(QUICError) {
    }

    func keysReady(for keyState: PacketKeyState) -> Bool {
        false
    }
}

#endif
#endif

// Availability due to Swift's `RawSpan` type
@available(macOS 10.14.4, iOS 12.2, tvOS 12.2, watchOS 5.2, *)
extension RawSpan {
    @usableFromInline
    subscript(index: Int) -> UInt8 {
        unsafeLoad(fromByteOffset: index, as: UInt8.self)
    }
}

// Availability due to Swift's `MutableRawSpan` type
@available(macOS 10.14.4, iOS 12.2, tvOS 12.2, watchOS 5.2, *)
extension MutableRawSpan {
    subscript(index: Int) -> UInt8 {
        get { unsafeLoad(fromByteOffset: index, as: UInt8.self) }
        set { storeBytes(of: newValue, toByteOffset: index, as: UInt8.self) }
    }
}

// Availability due to Swift's `RawSpan` type
@available(macOS 10.14.4, iOS 12.2, tvOS 12.2, watchOS 5.2, *)
extension Array where Element == UInt8 {
    /// Copies the bytes of the given raw span into this array.
    ///
    /// The span must contain exactly `count` bytes.
    init(copying bytes: RawSpan) {
        self.init(unsafeUninitializedCapacity: bytes.byteCount) { buffer, initializedCount in
            for i in 0..<bytes.byteCount {
                buffer[i] = bytes[i]
            }
            initializedCount += bytes.byteCount
        }
    }
}
