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
struct ReadRequest: ~Copyable {
    typealias DataCompletion = ([UInt8]?, Bool, Bool, NetworkError?) -> Void
    typealias SpanCompletion = (RawSpan, Bool, Bool, NetworkError?) -> Void

    enum ReadRequestType {
        case stream(minimumBytes: Int, maximumBytes: Int, dataCompletion: DataCompletion)
        case datagram(maximumFrames: Int, dataCompletion: DataCompletion)
        case streamSpan(minimumBytes: Int, maximumBytes: Int, maximumFrames: Int, spanCompletion: SpanCompletion)
    }

    let type: ReadRequestType

    init(minimumBytes: Int, maximumBytes: Int, completion: @escaping DataCompletion) {
        type = ReadRequestType.stream(minimumBytes: minimumBytes, maximumBytes: maximumBytes, dataCompletion: completion)
    }

    init(maximumFrames: Int, completion: @escaping DataCompletion) {
        type = ReadRequestType.datagram(maximumFrames: maximumFrames, dataCompletion: completion)
    }

    init(minimumBytes: Int, maximumBytes: Int, maximumFrames: Int, completion: @escaping SpanCompletion) {
        type = ReadRequestType.streamSpan(minimumBytes: minimumBytes, maximumBytes: maximumBytes, maximumFrames: maximumFrames, spanCompletion: completion)
    }

    func complete(content: [UInt8]?, isComplete: Bool, isFinal: Bool, error: NetworkError? = nil) {
        switch type {
        case .stream(_, _, let completion): completion(content, isComplete, isFinal, error)
        case .datagram(_, let completion): completion(content, isComplete, isFinal, error)
        default: break
        }
    }

    func complete(bytes: RawSpan, isComplete: Bool, isFinal: Bool, error: NetworkError? = nil) {
        switch type {
        case .streamSpan(_, _, _, let completion): completion(bytes, isComplete, isFinal, error)
        default: break
        }
    }

    var expectsSpan: Bool {
        switch type {
        case .streamSpan: return true
        default: return false
        }
    }

    var minimumBytes: Int {
        switch type {
        case .stream(let minimumBytes, _, _): return minimumBytes
        case .datagram(_, _): return 1
        case .streamSpan(let minimumBytes, _, _, _): return minimumBytes
        }
    }

    var maximumBytes: Int {
        switch type {
        case .stream(_, let maximumBytes, _): return maximumBytes
        case .datagram(_, _): return Int.max
        case .streamSpan(_, let maximumBytes, _, _): return maximumBytes
        }
    }

    var maximumFrames: Int {
        switch type {
        case .stream(_, _, _): return Int.max
        case .datagram(let maximumFrames, _): return maximumFrames
        case .streamSpan(_, _, let maximumFrames, _): return maximumFrames
        }
    }
}
