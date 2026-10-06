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

#if os(Linux) || os(Android)
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#endif
#elseif !NETWORK_STANDALONE
import Darwin
#endif

#if NETWORK_DRIVERKIT
#if canImport(errno_h)
internal import errno_h
#endif
#endif

/// An extension that adds system-interface APIs.
///
/// Extends `System` with system-interface functions.
@available(Network 0.1.0, *)
extension System {

    static func interfaceGetMTU(socket: Int32, name: String) throws -> Int {
        Int(try SystemInterface.interfaceGetMTU(socket: socket, name: name))
    }

    static func interfaceHasFlag(socket: Int32, name: String, flag: Interface.Details.Flags) throws -> Bool {
        try SystemInterface.interfaceHasFlag(socket: socket, name: name, flag: flag)
    }

    static func interfaceGetInterfaceType(socket: Int32, name: String) throws -> InterfaceType {
        try SystemInterface.interfaceGetInterfaceType(socket: socket, name: name)
    }

    static func interfaceGetInterfaceSubType(
        socket: Int32,
        name: String,
        interfaceType: InterfaceType
    ) throws -> InterfaceSubtype {
        #if os(Linux) || os(Android)
        return SystemInterface.interfaceGetInterfaceSubType(interfaceType: interfaceType)
        #else
        return try SystemInterface.interfaceGetInterfaceSubType(socket: socket, name: name)
        #endif
    }

    #if !NETWORK_STANDALONE || NETWORK_DRIVERKIT
    static func interfaceGetNameFromIndex(index: UInt32) throws -> String? {
        try SystemInterface.interfaceGetNameFromIndex(index: index)
    }
    #endif

    static func interfaceNameToIndex(name: String) throws -> UInt32 {
        #if os(Linux)
        return try SystemInterface.if_nametoindex(name)
        #elseif !NETWORK_STANDALONE || NETWORK_DRIVERKIT
        // Darwin and Android just have if_nametoindex exposed.
        let index = if_nametoindex(name)
        guard index > 0 else {
            throw NetworkError.posix(ENOENT)
        }
        return index
        #else
        return 0
        #endif
    }
    #if !NETWORK_PRIVATE && !NETWORK_STANDALONE
    static func routeGetInterfaceIndex(dst: any IPAddress, scopedIndex: UInt32) throws -> UInt32 {
        try SystemRoute.routeGetInterfaceIndex(dst: dst, scopedIndex: scopedIndex)
    }
    #endif
}
