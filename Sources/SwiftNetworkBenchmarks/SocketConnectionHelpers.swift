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

@_spi(Essentials) import SwiftNetwork

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - IP address parsing

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func parseIPv4(_ string: String) -> IPv4Address? {
    let parts = string.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var bytes = [UInt8]()
    for part in parts {
        guard let value = UInt8(part) else { return nil }
        bytes.append(value)
    }
    return IPv4Address(bytes)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func parseIPv6(_ string: String) -> IPv6Address? {
    var addr = in6_addr()
    guard string.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
        return nil
    }
    let bytes = withUnsafeBytes(of: &addr) { Array($0) }
    return IPv6Address(bytes)
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func parseEndpoints(ipString: String, port: UInt16, localPort: UInt16) -> (remote: Endpoint, local: Endpoint)? {
    if let v4 = parseIPv4(ipString) {
        return (
            Endpoint(address: v4, port: port),
            Endpoint(address: IPv4Address.loopback, port: localPort)
        )
    } else if let v6 = parseIPv6(ipString) {
        return (
            Endpoint(address: v6, port: port),
            Endpoint(address: IPv6Address.loopback, port: localPort)
        )
    }
    return nil
}

// MARK: - UDP helpers

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func makeUDPParams(localEndpoint: Endpoint) -> ParametersBuilder<UDP> {
    let builder = ParametersBuilder<UDP>.parameters { UDP() }
        .localEndpoint(localEndpoint)
    return builder
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func makeUDPConnection(to remote: Endpoint, localEndpoint: Endpoint) -> NetworkConnection<UDP> {
    NetworkConnection(to: remote, using: makeUDPParams(localEndpoint: localEndpoint))
}

// MARK: - TCP settings

// Only the knobs that actually translate through to SocketStreamProtocolOptions
// today. noPush / maximumSegmentSize / fast-open / etc. are accepted on the
// TCP() builder but silently no-op on the kernel-socket path, so they're not
// exposed here to avoid misleading users.
@_spi(ProtocolProvider)
public struct TCPSettings {
    public var noDelay: Bool = false
    public var enableKeepalive: Bool = false
    public var keepaliveIdle: UInt32 = 0
    public var keepaliveInterval: UInt32 = 0
    public var keepaliveCount: UInt32 = 0

    public init() {}

    public func describe() -> String {
        var parts: [String] = []
        if noDelay { parts.append("noDelay") }
        if enableKeepalive {
            parts.append("keepalive(idle=\(keepaliveIdle)s, interval=\(keepaliveInterval)s, count=\(keepaliveCount))")
        }
        return parts.isEmpty ? "defaults" : parts.joined(separator: ", ")
    }
}

// MARK: - TCP helpers

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func configureTCP(_ tcp: TCP, from settings: TCPSettings) -> TCP {
    var mutableTCP = tcp
    if settings.noDelay {
        mutableTCP = mutableTCP.noDelay(true)
    }
    if settings.enableKeepalive {
        // Values of 0 tell the kernel to use its defaults, so passing them through is safe.
        mutableTCP = mutableTCP.keepalive(
            idleTime: settings.keepaliveIdle,
            count: settings.keepaliveCount,
            interval: settings.keepaliveInterval
        )
    }
    return mutableTCP
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func makeTCPParams(localEndpoint: Endpoint?, settings: TCPSettings) -> ParametersBuilder<TCP> {
    let tcp = configureTCP(TCP(), from: settings)
    var builder = ParametersBuilder<TCP>.parameters { tcp }
    if let localEndpoint {
        builder = builder.localEndpoint(localEndpoint)
    }
    return builder
}

@_spi(ProtocolProvider)
@available(Network 0.1.0, *)
public func makeTCPConnection(
    to remote: Endpoint,
    localEndpoint: Endpoint?,
    settings: TCPSettings
) -> NetworkConnection<TCP> {
    NetworkConnection(to: remote, using: makeTCPParams(localEndpoint: localEndpoint, settings: settings))
}
