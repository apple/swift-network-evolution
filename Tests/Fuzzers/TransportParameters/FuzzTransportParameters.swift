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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

import Foundation

#if !Fuzzing
@main
struct RefuseToFuzz {
    static func main() {
        print("Refusing to fuzz.  Rebuild with Fuzzing trait.")
        exit(1)
    }
}
#else
#if os(Linux)
// See the equivalent shim in FuzzQUICPackets.swift for why this exists.
@_silgen_name("LLVMFuzzerRunDriver")
private func LLVMFuzzerRunDriver(
    _ argc: UnsafeMutablePointer<Int32>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ userCallback: @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
) -> Int32

@available(Network 0.1.0, *)
@_cdecl("FuzzTransportParameters_main")
func fuzzTransportParametersMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    var argc = argc
    var argv = argv
    return withUnsafeMutablePointer(to: &argc) { argcPointer in
        withUnsafeMutablePointer(to: &argv) { argvPointer in
            LLVMFuzzerRunDriver(argcPointer, argvPointer) { start, count in
                guard let start else { return 0 }
                return fuzzTransportParameters(start, count)
            }
        }
    }
}
#endif

@available(Network 0.1.0, *)
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTransportParameters(_ start: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
    let data = Data(bytes: start, count: count)
    _ = try? TransportParameters.deserialize(data.span, logPrefixer: LogPrefixer())
    return 0
}
#endif
#endif
