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

#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
internal import SwiftNetworkLinuxShim
#elseif !NETWORK_STANDALONE
import Darwin
#endif

/**
 * System APIs and system call wrapper support
 */

#if !NETWORK_STANDALONE || NETWORK_DRIVERKIT
#if !NETWORK_DRIVERKIT
let sysIoctl: @convention(c) (CInt, CUnsignedLong, UnsafeMutableRawPointer) -> CInt = ioctl
#endif
let sysSocket: @convention(c) (CInt, CInt, CInt) -> CInt = socket
#if !NETWORK_DRIVERKIT
let sysFcntl: @Sendable @convention(c) (CInt, CInt, CInt) -> CInt = { fcntl($0, $1, $2) }
#endif
let sysConnect = connect
#if canImport(Darwin)
let sysConnectx = connectx
#endif  // canImport(Darwin)
let sysWrite = write
let sysRead = read
let sysBind = bind
let sysRecvMsg: @convention(c) (CInt, UnsafeMutablePointer<msghdr>?, CInt) -> ssize_t = recvmsg
let sysSendMsg: @convention(c) (CInt, UnsafePointer<msghdr>?, CInt) -> ssize_t = sendmsg
let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex
#endif

#if os(Linux)
// if_indextoname is not in the Glibc Swift interface so it's bridged from c
let sysIfIndexToName: @convention(c) (CInt, UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? =
    SwiftNetworkLinuxShim_if_indextoname
#elseif !NETWORK_STANDALONE || NETWORK_DRIVERKIT
let sysIfIndexToName: @convention(c) (UInt32, UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? =
    if_indextoname
#endif

/// A result for an IO operation that was done on a non-blocking resource.
internal enum IOResult<T: Equatable>: Equatable {

    /// Signals that the IO operation could not be completed as otherwise we would need to block.
    case wouldBlock(T)

    /// Signals that the IO operation was completed.
    case processed(T)
}

extension IOResult where T: FixedWidthInteger {
    var result: T {
        switch self {
        case .processed(let value):
            return value
        case .wouldBlock(_):
            return 0
        }
    }
}

// Availability due to Swift's typed throws (`throws(NetworkError)`)
@available(anyAppleOS 26, *)
extension System {

    #if !NETWORK_STANDALONE || NETWORK_DRIVERKIT

    @inline(always)
    @discardableResult
    static func syscallForbiddingEINVAL<T: FixedWidthInteger>(
        where function: String = #function,
        _ body: () throws(NetworkError) -> T
    )
        throws(NetworkError) -> IOResult<T>
    {
        while true {
            let res = try body()
            if res == -1 {
                #if NETWORK_DRIVERKIT
                let err = get_errno()
                #else
                let err = errno
                #endif
                switch err {
                case EINTR:
                    continue
                case EWOULDBLOCK:
                    return .wouldBlock(0)
                default:
                    throw NetworkError.posix(err)
                }
            }
            return .processed(res)
        }
    }

    @inline(always)
    @discardableResult
    static func syscall<T: FixedWidthInteger>(
        blocking: Bool,
        where function: String = #function,
        _ body: () throws(NetworkError) -> T
    ) throws(NetworkError) -> IOResult<T> {
        while true {
            let res = try body()
            if res == -1 {
                #if NETWORK_DRIVERKIT
                let err = get_errno()
                #else
                let err = errno
                #endif
                switch (err, blocking) {
                case (EINTR, _):
                    continue
                case (EWOULDBLOCK, true):
                    return .wouldBlock(0)
                default:
                    throw NetworkError.posix(err)
                }
            }
            return .processed(res)
        }
    }

    @inline(__always)
    @discardableResult
    static func syscallOptional<T>(
        where function: String = #function,
        _ body: () throws(NetworkError) -> UnsafeMutablePointer<T>?
    )
        throws -> UnsafeMutablePointer<T>?
    {
        while true {
            #if NETWORK_DRIVERKIT
            set_errno(0)
            #else
            errno = 0
            #endif
            if let res = try body() {
                return res
            } else {
                #if NETWORK_DRIVERKIT
                let err = get_errno()
                #else
                let err = errno
                #endif
                switch err {
                case 0:
                    return nil
                case EINTR:
                    continue
                default:
                    throw NetworkError.posix(err)
                }
            }
        }
    }

    @inline(never)
    static func read(
        descriptor: CInt,
        pointer: UnsafeMutableRawPointer,
        size: size_t
    ) throws(NetworkError) -> IOResult<ssize_t> {
        try System.syscallForbiddingEINVAL {
            sysRead(descriptor, pointer, size)
        }
    }

    @inline(never)
    static func write(descriptor: CInt, pointer: UnsafeRawPointer, size: Int) throws(NetworkError) -> Int {
        try syscall(blocking: true) {
            sysWrite(descriptor, pointer, size)
        }.result
    }

    @inline(never)
    static func connect(descriptor: CInt, addr: UnsafePointer<sockaddr>, size: socklen_t) throws(NetworkError) -> Bool {
        do {
            _ = try syscall(blocking: false) {
                sysConnect(descriptor, addr, size)
            }
            return true
        } catch {
            #if NETWORK_DRIVERKIT
            let errCode = get_errno()
            #else
            let errCode = errno
            #endif
            if errCode == EINPROGRESS {
                return false
            }
            throw NetworkError.posix(errCode)
        }
    }

    #if canImport(Darwin)
    @inline(never)
    static func connectx(descriptor: CInt, addr: UnsafePointer<sockaddr>, size: socklen_t) throws(NetworkError) -> Bool
    {
        var endpoints = sa_endpoints_t()
        endpoints.sae_dstaddr = addr
        endpoints.sae_dstaddrlen = size
        do {
            try withUnsafePointer(to: &endpoints) { endpointsPtr in
                _ = try syscall(blocking: false) {
                    sysConnectx(descriptor, endpointsPtr, sae_associd_t(SAE_ASSOCID_ANY), 0, nil, 0, nil, nil)
                }
            }
            return true
        } catch {
            #if NETWORK_DRIVERKIT
            let errCode = get_errno()
            #else
            let errCode = errno
            #endif
            if errCode == EINPROGRESS {
                return false
            }
            throw NetworkError.posix(errCode)
        }
    }
    #endif  // canImport(Darwin)

    static func bind(descriptor: CInt, ptr: UnsafePointer<sockaddr>, bytes: Int) throws(NetworkError) -> Bool {
        do {
            _ = try syscall(blocking: false) {
                sysBind(descriptor, ptr, socklen_t(bytes))
            }
            return true
        } catch {
            #if NETWORK_DRIVERKIT
            let errCode = get_errno()
            #else
            let errCode = errno
            #endif
            if errCode == EINVAL {
                return false
            }
            throw NetworkError.posix(errCode)
        }
    }

    static func setNonBlocking(socket: CInt) throws(NetworkError) {
        #if NETWORK_DRIVERKIT
        let flags = fcntl_getfl(socket)
        guard flags != -1 else {
            throw NetworkError.posix(get_errno())
        }
        let ret = fcntl_setfl(socket, flags | O_NONBLOCK)
        if ret == -1 {
            throw NetworkError.posix(get_errno())
        }
        #else
        let flags = try System.fcntl(descriptor: socket, command: F_GETFL, value: 0)
        do {
            let ret = try System.fcntl(descriptor: socket, command: F_SETFL, value: flags | O_NONBLOCK)
            assert(ret == 0, "unexpectedly, fcntl(\(socket), F_SETFL, \(flags) | O_NONBLOCK) returned \(ret)")
        } catch {
            let errCode = errno
            if errCode == EINVAL {
                throw NetworkError.posix(errCode)
            }
            throw error
        }
        #endif
    }

    #if !NETWORK_DRIVERKIT
    static func fcntl(descriptor: CInt, command: CInt, value: CInt) throws(NetworkError) -> CInt {
        try System.syscall(blocking: false) {
            sysFcntl(descriptor, command, value)
        }.result
    }

    /// Cross platform ioctl interface
    static func ioctl(fd: CInt, request: CUnsignedLong, ptr: UnsafeMutableRawPointer) throws(NetworkError) {
        _ = try System.syscall(blocking: false) {
            sysIoctl(fd, numericCast(request), ptr)
        }
    }
    #endif

    static func recvmsg(
        descriptor: CInt,
        msgHdr: UnsafeMutablePointer<msghdr>,
        flags: CInt
    ) throws(NetworkError) -> IOResult<ssize_t> {
        try syscall(blocking: true) {
            sysRecvMsg(descriptor, msgHdr, flags)
        }
    }

    static func sendmsg(
        descriptor: CInt,
        msgHdr: UnsafePointer<msghdr>,
        flags: CInt
    ) throws(NetworkError) -> IOResult<ssize_t> {
        try syscall(blocking: true) {
            sysSendMsg(descriptor, msgHdr, flags)
        }
    }
    #endif  // #if !NETWORK_EMBEDDED
}
