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

import Foundation
#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

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
// On Linux SwiftPM renames an executable target's entry point to
// `<Module>_main` and links with `--defsym main=<Module>_main`, so the module
// can also be imported. Under the Fuzzing trait this file deliberately has no
// Swift entry point (libFuzzer's runtime supplies `main`), so that symbol does
// not exist and the link fails with:
//
//     ld.gold: error: undefined symbol 'FuzzQUICPackets_main' referenced in expression
//
// Supply it, and drive libFuzzer explicitly. `main` then resolves here via the
// `--defsym`, which also means libFuzzer's own `main` - a member of the static
// libclang_rt.fuzzer archive - is never extracted, so there is no duplicate
// `main`. macOS does not do this renaming, so it is left untouched.
@_silgen_name("LLVMFuzzerRunDriver")
private func LLVMFuzzerRunDriver(
    _ argc: UnsafeMutablePointer<Int32>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ userCallback: @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
) -> Int32

@available(Network 0.1.0, *)
@_cdecl("FuzzQUICPackets_main")
func fuzzQUICPacketsMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    var argc = argc
    var argv = argv
    return withUnsafeMutablePointer(to: &argc) { argcPointer in
        withUnsafeMutablePointer(to: &argv) { argvPointer in
            LLVMFuzzerRunDriver(argcPointer, argvPointer) { start, count in
                guard let start else { return 0 }
                return fuzzPacketParser(start, count)
            }
        }
    }
}
#endif

@available(Network 0.1.0, *)
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzPacketParser(_ start: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
    guard count > 0 else {
        return 0
    }
    var start = start
    var count = count
    let cidLength = Int(start[0]) % (QUICConnectionID.maximumSize + 1)
    start += 1
    count -= 1

    guard count > cidLength else {
        return 0
    }

    let context = NetworkContext(identifier: "FuzzPP")
    let connection = QUICConnection(context: context)
    let path = QUICPath(parent: connection)

    context.queue.sync {
        connection.state = .connected
        for keyState in PacketKeyState.allCases {
            connection.protector.installNullProtector(for: keyState)
        }
        connection.crypto.parentConnection = connection
        if cidLength != 0 {
            let cidBytes = Array(UnsafeBufferPointer(start: start, count: cidLength))
            if let cid = QUICConnectionID(cidBytes) {
                // Store the CID on the connection and path to avoid CID mismatches.
                connection.localCIDLength = cid.length
                path.setSCID(cid)
            }
            start += cidLength
            count -= cidLength
        }

        let data = Data(bytes: start, count: count)
        let frame = Frame(copyBuffer: data.span)
        connection.reference.fromExternal(frame) { frame in
            var frame = frame
            connection.handleInbound(frame: &frame, from: path, inConnectedState: true, isServerConnection: false)
        }

        connection.crypto.stop()
        for (_, stream) in connection.multiplexedFlows {
            stream.upperSendQueue.finalizeAllFramesAsFailed()
            stream.upperReceiveQueue.finalizeAllFramesAsFailed()
            stream.reassemblyQueue.dequeueAll()
            stream.reference.discardPendingEventsForUpperProtocol()
        }
        for (_, secondaryFlow) in connection.multiplexedSecondaryFlows {
            secondaryFlow.upperSendQueue.finalizeAllFramesAsFailed()
            secondaryFlow.upperReceiveQueue.finalizeAllFramesAsFailed()
            secondaryFlow.reference.discardPendingEventsForUpperProtocol()
        }
        connection.multiplexedFlows.removeAll()
        connection.multiplexedSecondaryFlows.removeAll()
        connection.reference.discardPendingEventsForUpperProtocol()
    }

    return 0
}
#endif
#endif
