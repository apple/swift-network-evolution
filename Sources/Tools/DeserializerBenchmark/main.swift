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

@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetwork
@_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkBenchmarks

private let testBytes: [UInt8] = [
    0x01,  // UInt8
    0x02, 0x03,  // UInt16 big-endian
    0x04, 0x05, 0x06, 0x07,  // UInt32 big-endian
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,  // UInt64 big-endian
    0x10,  // UInt8
]

let iterationCount = 10_000_000

@available(Network 0.1.0, *)
func runtest() {
    var frame = Frame(copyBuffer: testBytes)
    defer { frame.finalize(success: false) }
    for _ in 0..<iterationCount {
        var f1: UInt8 = 0
        var f2: UInt16 = 0
        var f3: UInt32 = 0
        var f4: UInt64 = 0
        var f5: UInt8 = 0
        _ = Deserializer.deserialize(&frame, claim: false) { read throws(DeserializationError) in
            try read.uint8(&f1)
            try read.uint16NetworkByteOrder(&f2)
            try read.uint32NetworkByteOrder(&f3)
            try read.uint64NetworkByteOrder(&f4)
            try read.uint8(&f5)
        }
    }
}
if #available(anyAppleOS 26, *) {
    runtest()
}
