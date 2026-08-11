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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

enum SocketType: CUnsignedInt, Sendable {
    case stream
    case datagram
    case raw

    #if !NETWORK_STANDALONE
    var socketType: Int32 {
        switch self {
        case .stream:
            #if os(Linux) && canImport(Glibc)
            return CInt(SOCK_STREAM.rawValue)
            #else
            return SOCK_STREAM
            #endif
        case .datagram:
            #if os(Linux) && canImport(Glibc)
            return CInt(SOCK_DGRAM.rawValue)
            #else
            return SOCK_DGRAM
            #endif
        case .raw:
            #if os(Linux) && canImport(Glibc)
            return CInt(SOCK_RAW.rawValue)
            #else
            return SOCK_RAW
            #endif
        }
    }
    #endif  // Embedded - #if !NETWORK_EMBEDDED

}

/// A type that creates a cross-platform socket.
// Availability due to Swift's typed throws (`throws(NetworkError)`) and `IPAddress`
@available(anyAppleOS 26, *)
class SystemSocket {

    /// Socket file descriptor
    private var sockfd: CInt = -1

    init(
        protocolFamily: AddressFamily,
        sockType: SocketType,
        protocolSubType: Int32,
        nonBlocking: Bool = false
    ) throws(NetworkError) {

        self.sockfd = try SystemSocket.createSocket(
            protocolFamily: protocolFamily,
            sockType: sockType,
            protocolSubType: protocolSubType
        )
        #if !NETWORK_STANDALONE
        if nonBlocking {
            try self.setSocketAsNonBlocking()
        }

        // Make sure the file descriptor is valid
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, could not create socket")
            throw NetworkError.posix(EINVAL)
        }
        #endif
    }

    /// Creates the actual cross-platform descriptor.
    private static func createSocket(
        protocolFamily: AddressFamily,
        sockType: SocketType,
        protocolSubType: Int32
    ) throws(NetworkError) -> CInt {
        #if os(Linux)
        return try System.syscall(blocking: false) {
            sysSocket(CInt(protocolFamily.rawValue), sockType.socketType, protocolSubType)
        }.result
        #elseif !NETWORK_STANDALONE
        return socket(Int32(protocolFamily.rawValue), sockType.socketType, protocolSubType)
        #else  // Embedded case - TODO
        return 0
        #endif
    }

    #if !NETWORK_STANDALONE
    public func withFileDescriptor<ReturnType>(_ body: (CInt) throws -> ReturnType) rethrows -> ReturnType {
        try body(self.sockfd)
    }

    /// Optionally sets the socket as non-blocking.
    private func setSocketAsNonBlocking() throws(NetworkError) {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot set non-blocking")
            throw NetworkError.posix(EINVAL)
        }
        try System.setNonBlocking(socket: self.sockfd)
    }

    #if !NETWORK_PRIVATE
    /// Connects the socket to a remote address and port.
    ///
    /// - Parameters:
    ///   - address: The remote `IPAddress` to connect to.
    ///   - port: The remote port to connect to.
    public func connectSocket(to address: any IPAddress, port: UInt16) throws(NetworkError) -> Bool {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot connect socket")
            throw NetworkError.posix(EINVAL)
        }
        return try address.withSockAddr(port: port) { (ptr, size) in
            #if canImport(Darwin)
            return try System.connectx(descriptor: self.sockfd, addr: ptr, size: socklen_t(size))
            #else
            return try System.connect(descriptor: self.sockfd, addr: ptr, size: socklen_t(size))
            #endif
        }
    }

    /// Binds the socket to an address and port.
    ///
    /// Wraps a call to the system `bind` function.
    public func bindSocket(address: any IPAddress, port: UInt16) throws {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot bind socket")
            throw NetworkError.posix(EINVAL)
        }
        let _ = try address.withSockAddr(port: port) { (ptr, size) in
            try System.bind(descriptor: self.sockfd, ptr: ptr, bytes: size)
        }
    }

    /// Connects the socket to a remote address.
    ///
    /// - Parameter address: The remote `IPAddress` to connect to.
    public func connectSocket(to address: any IPAddress) throws(NetworkError) -> Bool {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot connect socket")
            throw NetworkError.posix(EINVAL)
        }
        return try address.withSockAddr { (ptr, size) in
            try System.connect(descriptor: self.sockfd, addr: ptr, size: socklen_t(size))
        }
    }

    /// Binds the socket.
    ///
    /// Wraps a call to the system `bind` function.
    public func bindSocket(address: any IPAddress, bytes: Int) throws {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot bind socket")
            throw NetworkError.posix(EINVAL)
        }
        let _ = try address.withSockAddr { (ptr, size) in
            try System.bind(descriptor: self.sockfd, ptr: ptr, bytes: bytes)
        }
    }
    #endif

    /// Reads from the socket up to the specified length into the buffer.
    public func read(buffer: UnsafeMutableRawPointer, size: Int) throws -> Int {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot read from socket")
            throw NetworkError.posix(EINVAL)
        }
        return try System.read(descriptor: self.sockfd, pointer: buffer, size: size).result
    }

    func readIOResult(buffer: UnsafeMutableRawPointer, size: Int) throws(NetworkError) -> IOResult<Int> {
        guard self.sockfd > 0 else {
            throw NetworkError.posix(EINVAL)
        }
        return switch try System.read(descriptor: self.sockfd, pointer: buffer, size: size) {
        case .processed(let value): .processed(Int(value))
        case .wouldBlock(let value): .wouldBlock(Int(value))
        }
    }

    /// Performs a basic read on a socket. Use this only for control or routing sockets, not for data read from the actual network.
    public func platformRead(buffer: UnsafeMutableRawPointer, size: Int) throws -> Int {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot read from socket")
            throw NetworkError.posix(EINVAL)
        }
        return sysRead(self.sockfd, buffer, size)
    }

    /// Writes a buffer to the socket up to the specified length.
    public func write(buffer: UnsafeRawPointer, size: Int) throws -> Int {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot write to socket")
            throw NetworkError.posix(EINVAL)
        }
        return try System.write(descriptor: self.sockfd, pointer: buffer, size: size)
    }

    /// Performs a basic write on a socket. Use this only for control or routing sockets, not for data sent to the actual network.
    public func platformWrite(buffer: UnsafeRawPointer, size: Int) throws -> Int {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot write to socket")
            throw NetworkError.posix(EINVAL)
        }
        return sysWrite(self.sockfd, buffer, size)
    }

    /// Sends a message header on a control socket.
    ///
    /// Use this to send a `msghdr` structure on the socket.
    public func sendmsg(msgHdr: UnsafePointer<msghdr>, flags: CInt) throws -> Int {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot send a message on a socket")
            throw NetworkError.posix(EINVAL)
        }
        return try System.sendmsg(descriptor: self.sockfd, msgHdr: msgHdr, flags: flags).result
    }

    /// Receives a message buffer on a control socket.
    public func recvmsg(msgHdr: UnsafeMutablePointer<msghdr>, flags: CInt) throws -> Int {
        guard self.sockfd > 0 else {
            Logger.system.error("File descriptor is bad, cannot receive a message on a socket")
            throw NetworkError.posix(EINVAL)
        }
        return try System.recvmsg(descriptor: self.sockfd, msgHdr: msgHdr, flags: flags).result
    }

    // MARK: - Socket options

    /// Set a fixed-size socket option value.
    public func setSocketOption<T>(level: CInt, name: CInt, value: T) throws(NetworkError) {
        guard self.sockfd > 0 else { throw NetworkError.posix(EINVAL) }
        var copy = value
        let size = socklen_t(MemoryLayout<T>.size)
        let result = withUnsafePointer(to: &copy) { ptr -> CInt in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rebound in
                setsockopt(self.sockfd, level, name, rebound, size)
            }
        }
        if result != 0 {
            throw NetworkError.posix(errno)
        }
    }

    /// Get a fixed-size socket option value.
    public func getSocketOption<T>(level: CInt, name: CInt, defaultValue: T) throws(NetworkError) -> T {
        guard self.sockfd > 0 else { throw NetworkError.posix(EINVAL) }
        var value = defaultValue
        var size = socklen_t(MemoryLayout<T>.size)
        let result = withUnsafeMutablePointer(to: &value) { ptr -> CInt in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rebound in
                getsockopt(self.sockfd, level, name, rebound, &size)
            }
        }
        if result != 0 {
            throw NetworkError.posix(errno)
        }
        return value
    }

    /// Read pending socket error via SO_ERROR (and clear it). Returns 0 if no error.
    public func getSocketError() -> CInt {
        guard let error = try? getSocketOption(level: SOL_SOCKET, name: SO_ERROR, defaultValue: CInt(0)) else {
            return 0
        }
        return error
    }

    #if canImport(Darwin)
    /// Number of bytes available to read in the socket receive buffer (Darwin only).
    public func availableBytesToRead() -> Int {
        guard let value: CInt = try? getSocketOption(level: SOL_SOCKET, name: SO_NREAD, defaultValue: 0) else {
            return 0
        }
        return Int(value)
    }
    #else
    /// Number of bytes available to read in the socket receive buffer (Linux: FIONREAD).
    public func availableBytesToRead() -> Int {
        guard self.sockfd > 0 else { return 0 }
        var value: CInt = 0
        let result = ioctl(self.sockfd, UInt(FIONREAD), &value)
        return result == 0 ? Int(value) : 0
    }
    #endif

    public func getReceiveBufferSize() -> CInt {
        guard let size = try? getSocketOption(level: SOL_SOCKET, name: SO_RCVBUF, defaultValue: CInt(0)) else {
            return 0
        }
        return size
    }

    public func getSendBufferSize() -> CInt {
        guard let size = try? getSocketOption(level: SOL_SOCKET, name: SO_SNDBUF, defaultValue: CInt(0)) else {
            return 0
        }
        return size
    }

    public func setReceiveBufferSize(_ bytes: CInt) throws(NetworkError) {
        try setSocketOption(level: SOL_SOCKET, name: SO_RCVBUF, value: bytes)
    }

    public func setSendBufferSize(_ bytes: CInt) throws(NetworkError) {
        try setSocketOption(level: SOL_SOCKET, name: SO_SNDBUF, value: bytes)
    }

    public func setReceiveLowWatermark(_ bytes: CInt) throws(NetworkError) {
        try setSocketOption(level: SOL_SOCKET, name: SO_RCVLOWAT, value: bytes)
    }

    public func setSendLowWatermark(_ bytes: CInt) throws(NetworkError) {
        try setSocketOption(level: SOL_SOCKET, name: SO_SNDLOWAT, value: bytes)
    }

    public func setNoDelay(_ enabled: Bool) throws(NetworkError) {
        let value: CInt = enabled ? 1 : 0
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_NODELAY, value: value)
    }

    public func setKeepalive(enabled: Bool, idleTime: UInt32, interval: UInt32, count: UInt32) throws(NetworkError) {
        let on: CInt = enabled ? 1 : 0
        try setSocketOption(level: SOL_SOCKET, name: SO_KEEPALIVE, value: on)
        if !enabled { return }
        if idleTime > 0 {
            #if canImport(Darwin)
            try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_KEEPALIVE, value: CInt(idleTime))
            #else
            try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_KEEPIDLE, value: CInt(idleTime))
            #endif
        }
        if interval > 0 {
            try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_KEEPINTVL, value: CInt(interval))
        }
        if count > 0 {
            try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_KEEPCNT, value: CInt(count))
        }
    }

    /// Set the maximum segment size (TCP_MAXSEG). Portable.
    public func setMaximumSegmentSize(_ mss: UInt32) throws(NetworkError) {
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_MAXSEG, value: CInt(mss))
    }

    /// Set TCP_NOTSENT_LOWAT — reduce send-side buffering for latency-sensitive
    /// flows. Portable (Darwin and Linux both define TCP_NOTSENT_LOWAT).
    public func setNotSentLowWatermark(_ bytes: UInt32) throws(NetworkError) {
        #if canImport(Darwin) || canImport(Glibc)
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_NOTSENT_LOWAT, value: CInt(bytes))
        #else
        throw NetworkError.posix(ENOTSUP)
        #endif
    }

    #if canImport(Darwin)
    /// TCP_NOPUSH — delay sending small segments (Darwin-only; Linux has TCP_CORK
    /// with different semantics, not wired here).
    public func setNoPush(_ enabled: Bool) throws(NetworkError) {
        let value: CInt = enabled ? 1 : 0
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_NOPUSH, value: value)
    }

    /// TCP_NOOPT — disable all TCP options in outgoing segments. Darwin-only.
    public func setNoOptions(_ enabled: Bool) throws(NetworkError) {
        let value: CInt = enabled ? 1 : 0
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_NOOPT, value: value)
    }

    /// TCP_SENDMOREACKS — disable ACK stretching. Darwin-only.
    public func setSendMoreAcks(_ enabled: Bool) throws(NetworkError) {
        let value: CInt = enabled ? 1 : 0
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_SENDMOREACKS, value: value)
    }

    /// TCP_RXT_FINDROP — drop connection after unacked FIN. Darwin-only.
    public func setRetransmitFinDrop(_ enabled: Bool) throws(NetworkError) {
        let value: CInt = enabled ? 1 : 0
        try setSocketOption(level: CInt(IPPROTO_TCP), name: TCP_RXT_FINDROP, value: value)
    }
    #endif

    /// Reuse the local port via SO_REUSEPORT.
    public func setReusableLocalPort(_ enabled: Bool) throws(NetworkError) {
        let value: CInt = enabled ? 1 : 0
        try setSocketOption(level: SOL_SOCKET, name: SO_REUSEPORT, value: value)
    }

    deinit {
        close(self.sockfd)
    }
    #endif  // !Embedded
}

#if !NETWORK_PRIVATE && !NETWORK_STANDALONE
// Availability due to Swift's typed throws (`throws(NetworkError)`) and `IPAddress`/`IPv4Address`/`IPv6Address`/`NetlinkAddress`
@available(anyAppleOS 26, *)
extension IPAddress {
    func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, Int) throws -> T) throws(NetworkError) -> T {
        try self.withSockAddr(port: 0, body)
    }

    func withSockAddr<T>(port: UInt16, _ body: (UnsafePointer<sockaddr>, Int) throws -> T) throws(NetworkError) -> T {
        do {
            if self.addressFamily == .ipv4, let v4Address = self as? IPv4Address {
                var sockaddr4 = sockaddr_in()
                #if canImport(Darwin)
                sockaddr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                #endif  // Darwin
                sockaddr4.sin_addr = in_addr(s_addr: v4Address.address)
                sockaddr4.sin_family = sa_family_t(AF_INET)
                sockaddr4.sin_port = port.bigEndian
                return try withUnsafeBytes(of: sockaddr4) { p in
                    try p.withMemoryRebound(
                        to: sockaddr.self,
                        { buffer in
                            try body(buffer.baseAddress!, p.count)
                        }
                    )
                }
            } else if addressFamily == .ipv6, let v6Address = self as? IPv6Address {
                var sockaddr6 = sockaddr_in6()
                #if canImport(Glibc)
                sockaddr6.sin6_addr.__in6_u.__u6_addr32 = v6Address.address
                #elseif canImport(Musl)
                sockaddr6.sin6_addr.__in6_union.__s6_addr32 = v6Address.address
                #elseif canImport(Darwin)
                sockaddr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sockaddr6.sin6_addr.__u6_addr.__u6_addr32 = v6Address.address
                #endif
                sockaddr6.sin6_family = sa_family_t(AF_INET6)
                sockaddr6.sin6_port = port.bigEndian
                return try withUnsafeBytes(of: sockaddr6) { p in
                    try p.withMemoryRebound(
                        to: sockaddr.self,
                        { buffer in
                            try body(buffer.baseAddress!, p.count)
                        }
                    )
                }
            } else if addressFamily == .route, let netlinkAddress = self as? NetlinkAddress {
                return try withUnsafeBytes(of: netlinkAddress.address) { p in
                    try p.withMemoryRebound(
                        to: sockaddr.self,
                        { buffer in
                            try body(buffer.baseAddress!, p.count)
                        }
                    )
                }
            } else {
                Logger.system.error("Sockaddr not a valid address family, invalid unsafe pointer")
                throw NetworkError.posix(EINVAL)
            }
        } catch {
            let e = errno
            throw NetworkError.posix(e)
        }
    }
}
#endif
