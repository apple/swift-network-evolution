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
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(os)
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkInterfaceTests: NetTestCase {

    // Create interface with bad index, Darwin will abort on index 0 so this is guarded
    func testCreateInterfaceByBadIndex() throws {
        XCTAssertThrowsError(try Interface(index: 0))
    }

    func testCreateInterfaceByValidIndex() throws {
        var name = "lo0"
        var mtu = 16384
        #if os(Linux)
        name = "lo"
        mtu = 65536
        #endif
        // Use 1 as the index as this should be lo on even a machine that is not connected to the internet
        let interface = try Interface(index: 1)
        XCTAssertNotNil(interface, "Interface of index 1 should be valid")
        XCTAssertEqual(interface.name, name, "Name should be valid")
        XCTAssertEqual(interface.index, 1, "Index should be equal to 1")
        XCTAssertEqual(interface.details.mtu, mtu, "lo should have a max MTU")
        XCTAssertEqual(interface.interfaceType, .loopback, "Interface should be of loopback type")
    }

    func testCreateInterfaceByValidIndexAndName() throws {
        var name = "lo0"
        #if os(Linux)
        name = "lo"
        #endif
        let interface = try Interface(index: 1, name: name)
        XCTAssertEqual(interface.name, name, "Name should be valid")
        XCTAssertEqual(interface.index, 1, "Index should be equal to 1")
        XCTAssertEqual(interface.interfaceType, .loopback, "Interface should be of loopback type")
        #if canImport(Darwin)
        XCTAssertTrue(interface.details.flags.contains(.supportsMulticast), "supportsMulticast flag should be present")
        #endif
    }

    func testCreateInterfaceWithTooManySockets() throws {
        // `Interface.init` needs a socket to run its ioctls against, and must report a failure to
        // get one rather than trapping. Provoke that by lowering this process's descriptor limit to
        // below what it is already using, so the very next `socket()` fails. The window in which
        // this process cannot open a descriptor is microseconds, and nothing outside it is affected.
        #if canImport(Glibc)
        let descriptorLimit = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        #else
        let descriptorLimit = RLIMIT_NOFILE
        #endif

        // Both of these have to stop the test rather than record and continue. A failed `getrlimit`
        // leaves `original` zeroed, and lowering from that clamps the *hard* limit to zero, which an
        // unprivileged process can never raise again -- every later test would fail to open a
        // descriptor.
        var original = rlimit()
        guard getrlimit(descriptorLimit, &original) == 0 else {
            XCTFail("could not read the descriptor limit: errno \(errno)")
            return
        }

        var restricted = original
        restricted.rlim_cur = 0
        guard setrlimit(descriptorLimit, &restricted) == 0 else {
            XCTFail("could not lower the descriptor limit: errno \(errno)")
            return
        }

        // Check the premise: if the limit did not take effect, `Interface` would fail or succeed for
        // some other reason and the assertion below would prove nothing.
        #if os(Linux)
        let probeType = CInt(SOCK_DGRAM.rawValue)
        #else
        let probeType = SOCK_DGRAM
        #endif
        XCTAssertLessThan(socket(AF_INET, probeType, 0), 0, "the descriptor limit did not take effect")

        // Restore before asserting rather than from a `defer`: XCTest opens files to report a
        // failure, so its reporting must not run while this process cannot open a descriptor.
        let interfaceResult: Result<Interface, any Error>
        do {
            interfaceResult = .success(try Interface(index: 1, name: Self.loopbackInterfaceName))
        } catch {
            interfaceResult = .failure(error)
        }
        XCTAssertEqual(setrlimit(descriptorLimit, &original), 0, "could not restore the descriptor limit")

        switch interfaceResult {
        case .success:
            XCTFail("Interface was created despite the process being unable to open a socket")
        case .failure(let error):
            XCTAssertEqual(error as? NetworkError, NetworkError.posix(EINVAL))
        }
    }

    private static var loopbackInterfaceName: String {
        #if os(Linux)
        "lo"
        #else
        "lo0"
        #endif
    }

    func testCompareTwoInterfaces() throws {
        var name = "lo0"
        #if os(Linux)
        name = "lo"
        #endif
        let interfaceByIndex = try Interface(index: 1)
        let interfaceWithName = try Interface(index: 1, name: name)

        XCTAssertEqual(interfaceByIndex, interfaceWithName)

        XCTAssertEqual(interfaceByIndex.name, name, "Name should be \(name)")
        XCTAssertEqual(interfaceByIndex.name, interfaceWithName.name, "Names should be equal")

        XCTAssertEqual(interfaceByIndex.index, 1, "Index should be 1")
        XCTAssertEqual(interfaceByIndex.index, interfaceWithName.index, "Indices should be equal")

        XCTAssertEqual(interfaceByIndex.interfaceType, .loopback, "Type should be loopback")
        XCTAssertEqual(interfaceByIndex.interfaceType, interfaceWithName.interfaceType, "Types should match")

        XCTAssertEqual(
            interfaceByIndex.details.flags.rawValue,
            interfaceWithName.details.flags.rawValue,
            "Flags should match"
        )
    }

    func testRouteGetInterfaceIndex() throws {
        #if os(Linux) && !NETLINK_ENABLED
        try XCTSkipIf(true)
        #else
        // Very basic localhost test
        let v4Bytes: [UInt8] = [0x7F, 0x00, 0x00, 0x01]

        let address = IPv4Address(v4Bytes)
        XCTAssertNotNil(address)
        let routeIndex1 = try! System.routeGetInterfaceIndex(dst: address!, scopedIndex: 0)

        // Add the Darwin check for now until Linux support is added
        #if canImport(Darwin)
        XCTAssertEqual(routeIndex1, 1)
        #elseif os(Linux)
        XCTAssert(routeIndex1 > 0)
        #endif
        var ipv4Addr2 = sockaddr_in()
        let _ = "10.0.0.1".withCString { p in
            inet_pton(Int32(AddressFamily.ipv4.rawValue), p, &ipv4Addr2.sin_addr)
        }

        let address2 = IPv4Address(ipv4Addr2.sin_addr.s_addr)
        XCTAssertNotNil(address2)
        let routeIndex2 = try! System.routeGetInterfaceIndex(dst: address2, scopedIndex: 0)

        XCTAssert(routeIndex2 > 0)

        let ipv6Address = IPv6Address([
            0xfd, 0x5a, 0x3a, 0x11, 0xd8, 0x84, 0x73, 0x40, 0x08, 0xa7, 0x8a, 0xda, 0x1c, 0x36, 0x68, 0x64,
        ])!
        let routeIndex3 = try! System.routeGetInterfaceIndex(dst: ipv6Address, scopedIndex: 1)
        XCTAssertEqual(routeIndex3, 1)

        // Use a v6 loopback address with a scoped interface index
        let routeIndex4 = try! System.routeGetInterfaceIndex(dst: IPv6Address.loopback, scopedIndex: 1)
        XCTAssertEqual(routeIndex4, 1)
        #endif
    }
}
