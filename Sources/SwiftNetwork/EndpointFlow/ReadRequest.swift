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

@available(Network 0.1.0, *)
struct ReadRequest: Sendable {
    let minimumBytes: Int
    let maximumBytes: Int
    let maximumFrames: Int
    let completion: @Sendable ([UInt8]?, Bool, Bool, NetworkError?) -> Void

    func complete(content: [UInt8]?, isComplete: Bool, isFinal: Bool, error: NetworkError? = nil) {
        completion(content, isComplete, isFinal, error)
    }
}
