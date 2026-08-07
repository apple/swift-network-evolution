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
@_spi(ProtocolProvider) import SwiftNetworkBenchmarks
import Dispatch

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

// MARK: - Minimal POSIX TCP echo server
//
// Used for in-process TCP transfer mode. Listens on loopback, accepts a single
// connection, and either echoes or drains (depending on `echo`) until the
// client half-closes.

final class TCPEchoServer: @unchecked Sendable {
    struct ServerError: Error {
        let step: String
        let errno: Int32
    }

    private let port: UInt16
    private let echo: Bool
    private let queue: DispatchQueue
    private var listenFd: Int32 = -1

    init(port: UInt16, echo: Bool) {
        self.port = port
        self.echo = echo
        self.queue = DispatchQueue(label: "socket-transfer-tcp-echo-\(port)", qos: .userInitiated)
    }

    func start() throws {
        #if canImport(Glibc)
        let type = CInt(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let fd = socket(CInt(AF_INET), type, 0)
        guard fd >= 0 else { throw ServerError(step: "socket", errno: errno) }

        var yes: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<CInt>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
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
            throw ServerError(step: "bind", errno: errno)
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw ServerError(step: "listen", errno: errno)
        }
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

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(connFd, base, raw.count)
            }
            if n <= 0 { break }
            guard echo else { continue }
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

// MARK: - SocketTransfer

@available(Network 0.1.0, *)
final class SocketTransfer {

    static let NSEC_PER_MSEC = UInt64(Duration.milliseconds(1) / Duration.nanoseconds(1))

    let clientPort: UInt16 = 9100
    let serverPort: UInt16 = 9101

    // MARK: UDP round-trip / one-way (existing behavior)

    func runUDP(iterations: Int, sendSize: Int, echo: Bool) -> Double {
        let clientLocal = Endpoint(address: IPv4Address.loopback, port: clientPort)
        let clientRemote = Endpoint(address: IPv4Address.loopback, port: serverPort)
        let serverLocal = Endpoint(address: IPv4Address.loopback, port: serverPort)
        let serverRemote = Endpoint(address: IPv4Address.loopback, port: clientPort)

        let payload = (0..<sendSize).map { _ in UInt8.random(in: 0...255) }
        nonisolated(unsafe) var successCount = 0
        let mode = echo ? "round-trip echo" : "one-way send"
        print("Running UDP \(mode), transferring \(iterations) datagram\(iterations > 1 ? "s" : "")")
        let timestart = DispatchTime.now().uptimeNanoseconds

        let group = DispatchGroup()
        group.enter()

        let client = makeUDPConnection(to: clientRemote, localEndpoint: clientLocal)
        let server = makeUDPConnection(to: serverRemote, localEndpoint: serverLocal)

        nonisolated(unsafe) let done = { [group] in
            client.cancel()
            server.cancel()
            group.leave()
        }

        client.start()
        server.start()

        if echo {
            @Sendable func echoIteration(_ i: Int) {
                guard i < iterations else {
                    done()
                    return
                }

                client.send(.message(content: payload)) { result in
                    if case .failure(let error) = result {
                        print("Client send failed at \(i): \(error)")
                        done()
                        return
                    }
                }

                server.receive { result in
                    guard case .success(let msg) = result else {
                        print("Server receive failed at \(i)")
                        done()
                        return
                    }

                    server.send(.message(content: msg.content)) { result in
                        if case .failure(let error) = result {
                            print("Server echo failed at \(i): \(error)")
                            done()
                            return
                        }
                    }

                    client.receive { result in
                        guard case .success(let echo) = result else {
                            print("Client echo receive failed at \(i)")
                            done()
                            return
                        }

                        if echo.content == payload {
                            successCount += 1
                        } else {
                            print("Echo mismatch at \(i)")
                        }
                        echoIteration(i + 1)
                    }
                }
            }
            echoIteration(0)
        } else {
            for i in 0..<iterations {
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var failed = false
                client.send(.message(content: payload)) { result in
                    if case .failure = result { failed = true }
                    sem.signal()
                }
                sem.wait()
                if failed {
                    print("Client send failed at \(i)")
                    break
                }
                successCount += 1
            }
            done()
        }

        group.wait()
        print("Completed \(successCount) / \(iterations) transfers")
        guard successCount == iterations else { return 0 }
        let endTime = DispatchTime.now().uptimeNanoseconds
        return Double(endTime - timestart) / Double(SocketTransfer.NSEC_PER_MSEC) / 1000.0
    }

    func sendToRemoteUDP(
        ipString: String,
        port: UInt16,
        localPort: UInt16,
        iterations: Int,
        sendSize: Int
    ) -> Double {
        guard let endpoints = parseEndpoints(ipString: ipString, port: port, localPort: localPort) else {
            print("Invalid IP address: \(ipString)")
            return 0
        }

        let payload = (0..<sendSize).map { _ in UInt8.random(in: 0...255) }
        var successCount = 0
        print("Sending \(iterations) UDP datagram\(iterations > 1 ? "s" : "") to \(ipString):\(port)")
        let timestart = DispatchTime.now().uptimeNanoseconds

        let group = DispatchGroup()
        group.enter()

        let client = makeUDPConnection(to: endpoints.remote, localEndpoint: endpoints.local)
        client.start()

        for i in 0..<iterations {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var failed = false
            client.send(.message(content: payload)) { result in
                if case .failure = result { failed = true }
                sem.signal()
            }
            sem.wait()
            if failed {
                print("Failed to send at iteration \(i)")
                break
            }
            successCount += 1
        }

        client.cancel()
        group.leave()
        group.wait()

        print("Completed \(successCount) / \(iterations) sends")
        guard successCount == iterations else { return 0 }
        let endTime = DispatchTime.now().uptimeNanoseconds
        return Double(endTime - timestart) / Double(SocketTransfer.NSEC_PER_MSEC) / 1000.0
    }

    // MARK: TCP round-trip / one-way

    func runTCP(iterations: Int, sendSize: Int, echo: Bool, settings: TCPSettings) -> Double {
        let serverEndpoint = Endpoint(address: IPv4Address.loopback, port: serverPort)

        let mode = echo ? "round-trip echo" : "one-way send"
        print(
            "Running TCP \(mode), transferring \(iterations) message\(iterations > 1 ? "s" : ""), options: \(settings.describe())"
        )

        let server = TCPEchoServer(port: serverPort, echo: echo)
        do {
            try server.start()
        } catch {
            print("TCPEchoServer failed to start on port \(serverPort): \(error)")
            return 0
        }
        defer { server.stop() }

        let payload = (0..<sendSize).map { _ in UInt8.random(in: 0...255) }
        nonisolated(unsafe) var successCount = 0
        let timestart = DispatchTime.now().uptimeNanoseconds

        let group = DispatchGroup()
        group.enter()

        let client = makeTCPConnection(to: serverEndpoint, localEndpoint: nil, settings: settings)
        nonisolated(unsafe) let done = { [group] in
            client.cancel()
            group.leave()
        }

        client.start()

        if echo {
            @Sendable func echoIteration(_ i: Int) {
                guard i < iterations else {
                    done()
                    return
                }

                client.send(.message(content: payload)) { result in
                    if case .failure(let error) = result {
                        print("Client send failed at \(i): \(error)")
                        done()
                        return
                    }
                }

                // The server echoes exactly what it receives, so we expect
                // `sendSize` bytes back per iteration. Stream delivery can
                // split the reply across receives, so drain until complete.
                nonisolated(unsafe) var collected: [UInt8] = []
                @Sendable func drain() {
                    let need = sendSize - collected.count
                    client.receive(atLeast: 1, atMost: need) { result in
                        switch result {
                        case .success(let msg):
                            if let bytes = msg.content {
                                collected.append(contentsOf: bytes)
                            }
                            if collected.count >= sendSize {
                                if collected == payload {
                                    successCount += 1
                                } else {
                                    print("Echo mismatch at \(i)")
                                }
                                echoIteration(i + 1)
                            } else {
                                drain()
                            }
                        case .failure(let error):
                            print("Client echo receive failed at \(i): \(error)")
                            done()
                        }
                    }
                }
                drain()
            }
            echoIteration(0)
        } else {
            for i in 0..<iterations {
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var failed = false
                client.send(.message(content: payload)) { result in
                    if case .failure = result { failed = true }
                    sem.signal()
                }
                sem.wait()
                if failed {
                    print("Client send failed at \(i)")
                    break
                }
                successCount += 1
            }
            done()
        }

        group.wait()
        print("Completed \(successCount) / \(iterations) transfers")
        guard successCount == iterations else { return 0 }
        let endTime = DispatchTime.now().uptimeNanoseconds
        return Double(endTime - timestart) / Double(SocketTransfer.NSEC_PER_MSEC) / 1000.0
    }

    func sendToRemoteTCP(
        ipString: String,
        port: UInt16,
        localPort: UInt16,
        iterations: Int,
        sendSize: Int,
        settings: TCPSettings
    ) -> Double {
        guard let endpoints = parseEndpoints(ipString: ipString, port: port, localPort: localPort) else {
            print("Invalid IP address: \(ipString)")
            return 0
        }

        let payload = (0..<sendSize).map { _ in UInt8.random(in: 0...255) }
        var successCount = 0
        print(
            "Sending \(iterations) TCP message\(iterations > 1 ? "s" : "") to \(ipString):\(port), options: \(settings.describe())"
        )
        let timestart = DispatchTime.now().uptimeNanoseconds

        let client = makeTCPConnection(
            to: endpoints.remote,
            localEndpoint: localPort != 0 ? endpoints.local : nil,
            settings: settings
        )
        client.start()

        for i in 0..<iterations {
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var failed = false
            client.send(.message(content: payload)) { result in
                if case .failure = result { failed = true }
                sem.signal()
            }
            sem.wait()
            if failed {
                print("Failed to send at iteration \(i)")
                break
            }
            successCount += 1
        }

        client.cancel()

        print("Completed \(successCount) / \(iterations) sends")
        guard successCount == iterations else { return 0 }
        let endTime = DispatchTime.now().uptimeNanoseconds
        return Double(endTime - timestart) / Double(SocketTransfer.NSEC_PER_MSEC) / 1000.0
    }
}

// MARK: - Argument parsing

if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
    enum TransferProtocol: String {
        case udp
        case tcp
    }

    var proto: TransferProtocol = .udp
    var iterations = 100
    var sendSize = 1000
    var echo = true
    var remoteIP: String? = nil
    var remotePort: UInt16? = nil
    var localPort: UInt16 = 0
    var tcpSettings = TCPSettings()
    let arguments = CommandLine.arguments

    func parseArg<T>(_ flag: String, parse: (String) -> T?) -> T? {
        guard let index = arguments.firstIndex(of: flag),
            arguments.count > index + 1
        else { return nil }
        return parse(arguments[index + 1])
    }

    if let v: String = parseArg("-proto", parse: { $0 }) {
        guard let parsed = TransferProtocol(rawValue: v.lowercased()) else {
            print("Error: -proto must be 'udp' or 'tcp' (got '\(v)')")
            exit(1)
        }
        proto = parsed
    }
    if arguments.contains("-tcp") { proto = .tcp }
    if arguments.contains("-udp") { proto = .udp }

    if let v: Int = parseArg("-iterations", parse: { Int($0) }) { iterations = v }
    if let v: Int = parseArg("-size", parse: { Int($0) }) { sendSize = v }
    if let v: String = parseArg("-ip", parse: { $0 }) { remoteIP = v }
    if let v: UInt16 = parseArg("-port", parse: { UInt16($0) }) { remotePort = v }
    if let v: UInt16 = parseArg("-localport", parse: { UInt16($0) }) { localPort = v }
    if arguments.contains("-oneway") { echo = false }

    // TCP-specific options — only effective when -proto tcp (or -tcp) is set.
    if arguments.contains("-no-delay") { tcpSettings.noDelay = true }
    if arguments.contains("-keepalive") { tcpSettings.enableKeepalive = true }
    if let v: UInt32 = parseArg("-keepalive-idle", parse: { UInt32($0) }) {
        tcpSettings.keepaliveIdle = v
        tcpSettings.enableKeepalive = true
    }
    if let v: UInt32 = parseArg("-keepalive-interval", parse: { UInt32($0) }) {
        tcpSettings.keepaliveInterval = v
        tcpSettings.enableKeepalive = true
    }
    if let v: UInt32 = parseArg("-keepalive-count", parse: { UInt32($0) }) {
        tcpSettings.keepaliveCount = v
        tcpSettings.enableKeepalive = true
    }

    // MARK: - Run

    let socketTransfer = SocketTransfer()

    if let remoteIP {
        guard let remotePort else {
            print("Error: -port is required when using -ip")
            exit(1)
        }
        print("Starting \(iterations) \(proto.rawValue.uppercased()) sends to \(remoteIP):\(remotePort)")
        let totalTime: Double
        switch proto {
        case .udp:
            totalTime = socketTransfer.sendToRemoteUDP(
                ipString: remoteIP,
                port: remotePort,
                localPort: localPort,
                iterations: iterations,
                sendSize: sendSize
            )
        case .tcp:
            totalTime = socketTransfer.sendToRemoteTCP(
                ipString: remoteIP,
                port: remotePort,
                localPort: localPort,
                iterations: iterations,
                sendSize: sendSize,
                settings: tcpSettings
            )
        }
        if totalTime > 0 {
            print("Finished all (\(iterations)) sends in \(totalTime) seconds")
        } else {
            print("Error running all (\(iterations)) sends, something failed")
        }
    } else {
        let mode = echo ? "round-trip echo" : "one-way send"
        print("Starting \(iterations) \(proto.rawValue.uppercased()) \(mode) transfers")
        let totalTime: Double
        switch proto {
        case .udp:
            totalTime = socketTransfer.runUDP(iterations: iterations, sendSize: sendSize, echo: echo)
        case .tcp:
            totalTime = socketTransfer.runTCP(
                iterations: iterations,
                sendSize: sendSize,
                echo: echo,
                settings: tcpSettings
            )
        }
        if totalTime > 0 {
            print("Finished all (\(iterations)) transfers in \(totalTime) seconds")
        } else {
            print("Error running all (\(iterations)) transfers, something failed")
        }
    }
} else {
    fatalError("This tool requires macOS 26 or newer")
}
