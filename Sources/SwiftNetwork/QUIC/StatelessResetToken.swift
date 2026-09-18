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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public struct QUICStatelessResetToken: Equatable, Sendable, CustomStringConvertible {
    typealias TokenStorage = [16 of UInt8]
    private let _token: TokenStorage
    static let size = Constants.statelessResetTokenSize

    var token: [UInt8] {
        [UInt8](copying: _token.span, maxCount: QUICStatelessResetToken.size)
    }

    public init() {
        _token = TokenStorage.random()
    }

    public init?(_ token: [UInt8]) {
        guard token.count == QUICStatelessResetToken.size else {
            #if !DisableErrorLogging
            Logger.proto.fault("Invalid Stateless Reset Token")
            #endif
            return nil
        }
        _token = TokenStorage(tokenSpan: token.span)
    }

    public init?(_ token: Span<UInt8>) {
        guard token.count == QUICStatelessResetToken.size else {
            #if !DisableErrorLogging
            Logger.proto.fault("Invalid Stateless Reset Token")
            #endif
            return nil
        }
        _token = TokenStorage(tokenSpan: token)
    }

    public var description: String {
        #if !NETWORK_EMBEDDED
        var accumulator = ""
        for i in _token.indices {
            var thisDigit = String(_token[i], radix: 16)
            if thisDigit.count == 1 {
                thisDigit = "0" + thisDigit
            }
            accumulator += thisDigit
        }
        return accumulator
        #else
        "Stateless Reset Token"
        #endif
    }

    var isValid: Bool {
        if _token.count != QUICStatelessResetToken.size {
            return false
        }

        for i in _token.indices {
            if _token[i] != 0 {
                return true
            }
        }
        return false
    }

    static public func == (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<QUICStatelessResetToken.size {
            if lhs._token[i] != rhs._token[i] {
                return false
            }
        }
        return true
    }
}

@available(Network 0.1.0, *)
extension QUICStatelessResetToken.TokenStorage {
    fileprivate static var emptyToken: QUICStatelessResetToken.TokenStorage {
        QUICStatelessResetToken.TokenStorage(repeating: 0)
    }

    fileprivate init(tokenSpan span: Span<UInt8>) {
        self = QUICStatelessResetToken.TokenStorage.emptyToken
        for i in 0..<span.count {
            self[i] = span[i]
        }
    }

    fileprivate static func random() -> Self {
        var storage = QUICStatelessResetToken.TokenStorage.emptyToken
        var randomNumberGenerator = SystemRandomNumberGenerator()
        for i in 0..<storage.count {
            storage[i] = UInt8.random(in: 0...255, using: &randomNumberGenerator)
        }
        return storage
    }
}

#endif
