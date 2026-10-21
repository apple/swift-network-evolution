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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct WriteRequest: ~Copyable {
    struct Flags: OptionSet {
        let rawValue: UInt8

        static let isComplete = Flags(rawValue: 1 << 0)
        static let isReported = Flags(rawValue: 1 << 1)
        static let isIdempotent = Flags(rawValue: 1 << 2)
        static let isWriteClose = Flags(rawValue: 1 << 3)

        mutating func set(_ flag: Flags, to value: Bool) {
            if value {
                insert(flag)
            } else {
                remove(flag)
            }
        }
    }

    var frame: Frame
    let completion: (@Sendable (Result<Void, NetworkError>) -> Void)?
    var flags: Flags = []

    /// Orders queued requests; a higher value is sent first and equal values keep their order.
    var relativePriority: Double = 0.5
    var privateStorage = WriteRequestPrivateStorage()

    private init(
        frame: consuming Frame,
        isComplete: Bool,
        completion: (@Sendable (Result<Void, NetworkError>) -> Void)?
    ) {
        if isComplete {
            frame.metadataComplete = true
            frame.connectionComplete = true
            self.flags.insert(.isComplete)
        }
        self.frame = frame
        self.completion = completion
    }

    init(content: [UInt8]?, isComplete: Bool, completion: (@Sendable (Result<Void, NetworkError>) -> Void)?) {
        guard let content else {
            self.init(frame: Frame(copyBuffer: []), isComplete: isComplete, completion: completion)
            return
        }
        self.init(frame: Frame(copyBuffer: content), isComplete: isComplete, completion: completion)
    }

    init(
        buffer: UnsafeMutableRawBufferPointer,
        owner: AnyObject,
        isComplete: Bool,
        completion: (@Sendable (Result<Void, NetworkError>) -> Void)?
    ) {
        self.init(frame: Frame(customBuffer: buffer, owner: owner), isComplete: isComplete, completion: completion)
    }

    internal static func runCompletion(_ completion: (@Sendable (Result<Void, NetworkError>) -> Void)?, success: Bool) {
        if let completion {
            if success {
                completion(Result.success(()))
            } else {
                completion(Result.failure(NetworkError.posix(ENOBUFS)))
            }
        }
    }
}

@available(Network 0.1.0, *)
extension NetworkUniqueDeque where Element == WriteRequest {
    /// Queues `request` behind every request of equal or higher priority.
    mutating func appendOrderedByPriority(_ request: consuming WriteRequest) {
        let priority = request.relativePriority
        // The common case is joining the end; otherwise find the last request that is not lower.
        var index = count
        while index > 0 && self[index - 1].relativePriority < priority {
            index -= 1
        }
        insert(request, at: index)
    }
}
