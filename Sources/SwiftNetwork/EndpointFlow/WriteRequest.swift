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

#if canImport(SwiftSystem)
internal import SwiftSystem
#endif

#if canImport(Android)
import Android
internal import Logging
#elseif canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
struct WriteRequest: ~Copyable {
    var frame: Frame
    let completion: (@Sendable (Result<Void, NetworkError>) -> Void)?

    private init(
        frame: consuming Frame,
        isComplete: Bool,
        completion: (@Sendable (Result<Void, NetworkError>) -> Void)?
    ) {
        if isComplete {
            frame.metadataComplete = true
            frame.connectionComplete = true
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
