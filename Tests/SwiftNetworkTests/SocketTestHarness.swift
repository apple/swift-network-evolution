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

import XCTest

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
internal import Darwin
#endif

#if !NETWORK_NO_SWIFT_QUIC

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

// MARK: - Parameter builders
//
// Shared by the harnesses and by the handful of bespoke lifecycle tests that
// build a lone connection.

@available(Network 0.1.0, *)
func makeUDPParams(localPort: UInt16, ipv6: Bool = false) -> ParametersBuilder<UDP> {
    var builder = ParametersBuilder<UDP>.parameters { UDP() }
    if ipv6 {
        builder.parameters.localAddress = Endpoint(address: IPv6Address.loopback, port: localPort)
    } else {
        builder.parameters.localAddress = Endpoint(address: IPv4Address.loopback, port: localPort)
    }
    return builder
}

@available(Network 0.1.0, *)
func makeTCPParams(localPort: UInt16 = 0, ipv6: Bool = false) -> ParametersBuilder<TCP> {
    var builder = ParametersBuilder<TCP>.parameters { TCP() }
    if localPort != 0 {
        if ipv6 {
            builder.parameters.localAddress = Endpoint(address: IPv6Address.loopback, port: localPort)
        } else {
            builder.parameters.localAddress = Endpoint(address: IPv4Address.loopback, port: localPort)
        }
    }
    return builder
}

@available(Network 0.1.0, *)
private func loopbackEndpoint(port: UInt16, ipv6: Bool) -> Endpoint {
    ipv6
        ? Endpoint(address: IPv6Address.loopback, port: port)
        : Endpoint(address: IPv4Address.loopback, port: port)
}

// MARK: - UDP loopback harness
//
// Owns the two peers used by the datagram tests: two UDP connections bound to
// each other's port on loopback. Sets both up, starts them, and cleans them up
// (cancel + wait for the cancelled state) on `teardown()`. The `expect*`
// helpers cover the common send/receive shapes; tests that need something
// bespoke can drive `c1`/`c2` directly and still rely on setup/teardown.

// `@unchecked Sendable`: all stored properties are immutable (`let`) and the
// connections/expectations are themselves thread-safe, so the harness is safe
// to capture in the `@Sendable` receive callbacks its operations schedule.
@available(Network 0.1.0, *)
final class UDPLoopbackHarness: @unchecked Sendable {
    let c1: NetworkConnection<UDP>
    let c2: NetworkConnection<UDP>

    private let c1Ready = XCTestExpectation(description: "c1 ready")
    private let c2Ready = XCTestExpectation(description: "c2 ready")
    private let c1Cancelled = XCTestExpectation(description: "c1 cancelled")
    private let c2Cancelled = XCTestExpectation(description: "c2 cancelled")

    /// Builds two cross-bound peers on kernel-assigned ports: `c1` binds one and targets the
    /// other, `c2` the reverse.
    init(ipv6: Bool = false) {
        let ports = discoverFreeLoopbackPorts(2)

        c1 = NetworkConnection(
            to: loopbackEndpoint(port: ports[0], ipv6: ipv6),
            using: makeUDPParams(localPort: ports[1], ipv6: ipv6)
        )
        c2 = NetworkConnection(
            to: loopbackEndpoint(port: ports[1], ipv6: ipv6),
            using: makeUDPParams(localPort: ports[0], ipv6: ipv6)
        )

        c1.onStateUpdate { [c1Ready, c1Cancelled] _, state in
            if case .ready = state { c1Ready.fulfill() }
            if case .cancelled = state { c1Cancelled.fulfill() }
        }
        c2.onStateUpdate { [c2Ready, c2Cancelled] _, state in
            if case .ready = state { c2Ready.fulfill() }
            if case .cancelled = state { c2Cancelled.fulfill() }
        }
    }

    func start() {
        c1.start()
        c2.start()
    }

    func waitBothReady(timeout: TimeInterval = 5.0) {
        XCTAssertEqual(XCTWaiter.wait(for: [c1Ready, c2Ready], timeout: timeout), .completed)
    }

    func teardown(timeout: TimeInterval = 5.0) {
        c1.cancel()
        c2.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [c1Cancelled, c2Cancelled], timeout: timeout), .completed)
    }

    // MARK: Operations

    /// `c1` sends `payload`; `c2` receives it and verifies it matches.
    func expectDeliver(_ payload: [UInt8], timeout: TimeInterval = 10.0) {
        let done = XCTestExpectation(description: "deliver \(payload.count) bytes")
        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }
        c2.receive { result in
            if case .success(let msg) = result {
                XCTAssertEqual(msg.content, payload)
            } else {
                XCTFail("receive failed")
            }
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: timeout), .completed)
    }

    /// `c1` sends `payload`; `c2` echoes it back; `c1` verifies the echo.
    func expectRoundTripEcho(_ payload: [UInt8], timeout: TimeInterval = 10.0) {
        let done = XCTestExpectation(description: "round-trip echo \(payload.count) bytes")
        c1.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }
        c2.receive { [c1, c2] result in
            switch result {
            case .success(let message):
                XCTAssertEqual(message.content, payload)
                c2.send(.message(content: message.content)) { _ in }
                c1.receive { result in
                    if case .success(let echo) = result {
                        XCTAssertEqual(echo.content, payload)
                    } else {
                        XCTFail("echo receive failed")
                    }
                    done.fulfill()
                }
            case .failure(let error):
                XCTFail("c2 receive failed: \(error)")
                done.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: timeout), .completed)
    }

    /// `c1` sends each message in turn; `c2` receives and verifies each one.
    func expectSequentialDeliver(_ messages: [[UInt8]], timeout: TimeInterval = 15.0) {
        let allDone = XCTestExpectation(description: "sequential deliver \(messages.count)")
        nonisolated(unsafe) var received = 0

        @Sendable func step(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            self.c1.send(.message(content: messages[i])) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
            self.c2.receive { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, messages[i])
                    received += 1
                } else {
                    XCTFail("receive \(i) failed")
                }
                step(i + 1)
            }
        }
        step(0)

        XCTAssertEqual(XCTWaiter.wait(for: [allDone], timeout: timeout), .completed)
        XCTAssertEqual(received, messages.count)
    }

    /// Runs `count` sequential round-trip echoes, using `payloadFor(i)` per iteration.
    func expectSequentialEcho(
        count: Int,
        timeout: TimeInterval = 60.0,
        _ payloadFor: @escaping @Sendable (Int) -> [UInt8]
    ) {
        let allDone = XCTestExpectation(description: "\(count) echoes")
        nonisolated(unsafe) var success = 0

        @Sendable func echoOnce(_ i: Int) {
            guard i < count else {
                allDone.fulfill()
                return
            }
            let payload = payloadFor(i)
            self.c1.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i): \(error)") }
            }
            self.c2.receive { result in
                guard case .success(let msg) = result else {
                    XCTFail("c2 recv \(i)")
                    return
                }
                XCTAssertEqual(msg.content, payload)
                self.c2.send(.message(content: msg.content)) { _ in }
                self.c1.receive { result in
                    guard case .success(let echo) = result else {
                        XCTFail("c1 echo \(i)")
                        return
                    }
                    XCTAssertEqual(echo.content, payload)
                    success += 1
                    echoOnce(i + 1)
                }
            }
        }
        echoOnce(0)

        XCTAssertEqual(XCTWaiter.wait(for: [allDone], timeout: timeout), .completed)
        XCTAssertEqual(success, count)
    }

    /// Sends every payload up front (a burst), then drains and counts all of
    /// them from `c2`. `delayBeforeDrain` lets sends queue up before reading.
    func expectBurstThenDrain(
        _ payloads: [[UInt8]],
        delayBeforeDrain: TimeInterval = 0,
        timeout: TimeInterval = 30.0
    ) {
        let allReceived = XCTestExpectation(description: "drain \(payloads.count)")
        for (i, payload) in payloads.enumerated() {
            c1.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
        }

        let total = payloads.count
        nonisolated(unsafe) var receiveCount = 0
        @Sendable func drain() {
            self.c2.receive { result in
                if case .success = result {
                    receiveCount += 1
                    if receiveCount < total {
                        drain()
                    } else {
                        allReceived.fulfill()
                    }
                } else {
                    XCTFail("receive \(receiveCount) failed")
                }
            }
        }

        if delayBeforeDrain > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delayBeforeDrain) { drain() }
        } else {
            drain()
        }

        XCTAssertEqual(XCTWaiter.wait(for: [allReceived], timeout: timeout), .completed)
        XCTAssertEqual(receiveCount, total)
    }
}

// MARK: - TCP client harness
//
// Owns a server (a TCPEchoServer by default) plus a single NetworkConnection<TCP>
// client. Starts the server, builds the client, and tears everything down
// (cancel client + wait cancelled + stop server) on `teardown()`. The `expect*`
// helpers cover the echo shapes; tests that need a different server pass one in.

// `@unchecked Sendable`: see UDPLoopbackHarness — all stored properties are
// immutable and thread-safe, making `self` safe to capture in the `@Sendable`
// receive callbacks.
@available(Network 0.1.0, *)
final class TCPClientHarness: @unchecked Sendable {
    let conn: NetworkConnection<TCP>
    private let server: (any SocketTestServer)?

    private let ready = XCTestExpectation(description: "tcp ready")
    private let cancelled = XCTestExpectation(description: "tcp cancelled")

    /// Creates the harness around `server` (default: a `TCPEchoServer`), starts the server, and
    /// builds a client targeting whichever port the kernel gave it.
    init(ipv6: Bool = false, server: (any SocketTestServer)? = nil) {
        let server = server ?? TCPEchoServer(ipv6: ipv6)
        self.server = server
        do {
            try server.start()
        } catch {
            XCTFail("test server failed to start: \(error)")
        }

        conn = NetworkConnection(
            to: loopbackEndpoint(port: server.listeningPort, ipv6: ipv6),
            using: makeTCPParams(ipv6: ipv6)
        )
        conn.onStateUpdate { [ready, cancelled] _, state in
            if case .ready = state { ready.fulfill() }
            if case .cancelled = state { cancelled.fulfill() }
        }
    }

    func start() {
        conn.start()
    }

    func waitReady(timeout: TimeInterval = 5.0) {
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }

    /// Blocks until the connection is ready. Safe to call repeatedly — once the
    /// `ready` expectation is fulfilled, waiting on it again returns immediately.
    /// The operations below call this before their first send: on Linux, sending
    /// on a socket that is still connecting fails immediately with ENOBUFS.
    private func ensureReady(timeout: TimeInterval = 5.0) {
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }

    func teardown(timeout: TimeInterval = 5.0) {
        conn.cancel()
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: timeout), .completed)
        server?.stop()
    }

    // MARK: Operations

    /// Sends `payload` and reads exactly `payload.count` bytes back, verifying
    /// the echo. Use `drain: true` when the reply may span multiple receives.
    func expectEcho(_ payload: [UInt8], drain: Bool = false, timeout: TimeInterval = 15.0) {
        ensureReady()
        let done = XCTestExpectation(description: "tcp echo \(payload.count) bytes")
        conn.send(.message(content: payload)) { result in
            if case .failure(let error) = result { XCTFail("send failed: \(error)") }
        }
        receiveEcho(payload, drain: drain) { done.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: timeout), .completed)
    }

    /// Sends and verifies each message in turn.
    func expectSequentialEcho(_ messages: [[UInt8]], drain: Bool = false, timeout: TimeInterval = 30.0) {
        ensureReady()
        let allDone = XCTestExpectation(description: "sequential tcp echo \(messages.count)")
        nonisolated(unsafe) var received = 0

        @Sendable func step(_ i: Int) {
            guard i < messages.count else {
                allDone.fulfill()
                return
            }
            let payload = messages[i]
            self.conn.send(.message(content: payload)) { result in
                if case .failure(let error) = result { XCTFail("send \(i) failed: \(error)") }
            }
            self.receiveEcho(payload, drain: drain) {
                received += 1
                step(i + 1)
            }
        }
        step(0)

        XCTAssertEqual(XCTWaiter.wait(for: [allDone], timeout: timeout), .completed)
        XCTAssertEqual(received, messages.count)
    }

    /// Runs `count` sequential echoes with `payloadFor(i)` per iteration.
    func expectSequentialEcho(
        count: Int,
        drain: Bool = false,
        timeout: TimeInterval = 60.0,
        _ payloadFor: @escaping @Sendable (Int) -> [UInt8]
    ) {
        expectSequentialEcho((0..<count).map(payloadFor), drain: drain, timeout: timeout)
    }

    // MARK: Private

    /// Reads back `payload.count` bytes and verifies them, then calls `completion`.
    private func receiveEcho(_ payload: [UInt8], drain: Bool, completion: @escaping @Sendable () -> Void) {
        if !drain {
            conn.receive(atLeast: payload.count, atMost: payload.count) { result in
                if case .success(let msg) = result {
                    XCTAssertEqual(msg.content, payload)
                } else {
                    XCTFail("receive failed")
                }
                completion()
            }
            return
        }

        // Stream delivery can split the reply across receives; keep reading
        // until the full payload has been collected.
        nonisolated(unsafe) var collected: [UInt8] = []
        @Sendable func readMore() {
            let need = payload.count - collected.count
            self.conn.receive(atLeast: 1, atMost: need) { result in
                switch result {
                case .success(let msg):
                    if let bytes = msg.content { collected.append(contentsOf: bytes) }
                    if collected.count >= payload.count {
                        XCTAssertEqual(collected, payload)
                        completion()
                    } else {
                        readMore()
                    }
                case .failure(let error):
                    XCTFail("receive failed: \(error)")
                    completion()
                }
            }
        }
        readMore()
    }
}

// MARK: - Test TCP servers
//
// Minimal POSIX loopback servers used by the SocketStreamProtocol tests. Each
// accepts a single connection on a background queue.

/// A TCP server the `TCPClientHarness` can own and lifecycle-manage.
@available(Network 0.1.0, *)
protocol SocketTestServer: AnyObject, Sendable {
    func start() throws
    func stop()
    /// The port the kernel assigned, valid once `start()` has returned.
    ///
    /// Assigned at bind rather than chosen up front, which is why the servers' dispatch queue
    /// labels no longer carry it.
    var listeningPort: UInt16 { get }
}

/// Discovers `count` distinct loopback port numbers that are free, by binding a socket to each and
/// releasing them all once the kernel's choices have been read back.
@available(Network 0.1.0, *)
func discoverFreeLoopbackPorts(_ count: Int) -> [UInt16] {
    var descriptors: [CInt] = []
    defer { descriptors.forEach { close($0) } }

    for _ in 0..<count {
        #if canImport(Glibc)
        let descriptor = socket(AF_INET, CInt(SOCK_DGRAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard descriptor >= 0 else {
            XCTFail("could not open a socket to find a free port: errno \(errno)")
            return Array(repeating: 0, count: count)
        }
        descriptors.append(descriptor)

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            XCTFail("could not bind a socket to find a free port: errno \(errno)")
            return Array(repeating: 0, count: count)
        }
    }
    return descriptors.map { boundPortOfDescriptor($0) }
}

/// Discovers one free loopback port number. See `discoverFreeLoopbackPorts(_:)`.
@available(Network 0.1.0, *)
func discoverFreeLoopbackPort() -> UInt16 {
    discoverFreeLoopbackPorts(1)[0]
}

/// Reads back the port `fd` is bound to.
@available(Network 0.1.0, *)
func boundPortOfDescriptor(_ fd: Int32) -> UInt16 {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &length)
        }
    }
    guard result == 0 else {
        XCTFail("could not read back the bound port: errno \(errno)")
        return 0
    }
    if storage.ss_family == sa_family_t(AF_INET6) {
        return withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
        }
    }
    return withUnsafePointer(to: &storage) { ptr in
        ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
    }
}

// Accepts one connection and echoes everything it receives back to the sender
// until the peer half-closes (FIN).
@available(Network 0.1.0, *)
final class TCPEchoServer: SocketTestServer, @unchecked Sendable {
    private(set) var listeningPort: UInt16 = 0
    private let ipv6: Bool
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(ipv6: Bool = false) {
        self.ipv6 = ipv6
        self.queue = DispatchQueue(label: "tcp-echo-server", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let family = ipv6 ? CInt(AF_INET6) : CInt(AF_INET)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let family = ipv6 ? CInt(AF_INET6) : CInt(AF_INET)
        let type = SOCK_STREAM
        #endif
        let fd = socket(family, type, 0)
        guard fd >= 0 else { throw NetworkError.posix(errno) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        let bound: CInt
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = 0
            addr.sin6_addr = in6addr_loopback
            #if canImport(Darwin)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NetworkError.posix(errno)
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NetworkError.posix(errno)
        }

        self.listeningPort = boundPortOfDescriptor(fd)
        self.listenFd = fd
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        if fd >= 0 {
            _ = shutdown(fd, CInt(SHUT_RDWR))
            close(fd)
        }
    }

    private func acceptLoop() {
        let listen = listenFd
        guard listen >= 0 else { return }
        let connFd = accept(listen, nil, nil)
        if connFd < 0 { return }
        defer { close(connFd) }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(connFd, base, raw.count)
            }
            if n <= 0 { break }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(connFd, base.advanced(by: written), n - written)
                }
                if w <= 0 { return }
                written += w
            }
        }
    }
}

// Pushes a payload as two separate NODELAY segments with a gap between them,
// without reading anything from the client. Used to force a receive(atLeast:)
// to span more than one read event.
@available(Network 0.1.0, *)
final class SplitSendServer: SocketTestServer, @unchecked Sendable {
    private(set) var listeningPort: UInt16 = 0
    private let firstChunk: Int
    private let total: Int
    private let gap: TimeInterval
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(firstChunk: Int, total: Int, gap: TimeInterval) {
        self.firstChunk = firstChunk
        self.total = total
        self.gap = gap
        self.queue = DispatchQueue(label: "split-send-server", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let fd = socket(CInt(AF_INET), type, 0)
        guard fd >= 0 else { throw NetworkError.posix(errno) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NetworkError.posix(errno)
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NetworkError.posix(errno)
        }

        self.listeningPort = boundPortOfDescriptor(fd)
        self.listenFd = fd
        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        if fd >= 0 {
            _ = shutdown(fd, CInt(SHUT_RDWR))
            close(fd)
        }
    }

    private func serve() {
        let listen = listenFd
        guard listen >= 0 else { return }
        let connFd = accept(listen, nil, nil)
        if connFd < 0 { return }
        defer { close(connFd) }

        // Disable Nagle so each write leaves as its own segment.
        var one: CInt = 1
        _ = setsockopt(connFd, CInt(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<CInt>.size))

        let payload = [UInt8](repeating: 0xAB, count: total)

        func sendAll(_ bytes: ArraySlice<UInt8>) {
            let array = Array(bytes)
            var off = 0
            while off < array.count {
                let w = array.withUnsafeBytes { raw -> Int in
                    write(connFd, raw.baseAddress!.advanced(by: off), raw.count - off)
                }
                if w <= 0 { break }
                off += w
            }
        }

        // First segment, then a gap so the client processes it (and, if buggy,
        // suspends its read source) before the remainder arrives.
        sendAll(payload.prefix(firstChunk))
        Thread.sleep(forTimeInterval: gap)
        sendAll(payload.suffix(total - firstChunk))

        // Hold the connection open long enough for the client to finish.
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// Sends a payload and immediately closes the connection (sending FIN), so the
// client observes EOF. Used to exercise the bottom's end-of-stream handling.
@available(Network 0.1.0, *)
final class ClosingServer: SocketTestServer, @unchecked Sendable {
    private(set) var listeningPort: UInt16 = 0
    private let payload: [UInt8]
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(payload: [UInt8]) {
        self.payload = payload
        self.queue = DispatchQueue(label: "closing-server", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let fd = socket(CInt(AF_INET), type, 0)
        guard fd >= 0 else { throw NetworkError.posix(errno) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NetworkError.posix(errno)
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NetworkError.posix(errno)
        }

        self.listeningPort = boundPortOfDescriptor(fd)
        self.listenFd = fd
        queue.async { [weak self] in self?.serve() }
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        if fd >= 0 {
            _ = shutdown(fd, CInt(SHUT_RDWR))
            close(fd)
        }
    }

    private func serve() {
        let listen = listenFd
        guard listen >= 0 else { return }
        let connFd = accept(listen, nil, nil)
        if connFd < 0 { return }

        var off = 0
        while off < payload.count {
            let w = payload.withUnsafeBytes { raw -> Int in
                write(connFd, raw.baseAddress!.advanced(by: off), raw.count - off)
            }
            if w <= 0 { break }
            off += w
        }
        // Close immediately, sending FIN so the client sees EOF.
        close(connFd)
    }
}

#endif
