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

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#endif

#if !hasFeature(Embedded) && canImport(Foundation)
import Foundation
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkEndpointTests: NetTestCase {

    func testApplicationServiceEndpointCreation() {
        let serviceID = SystemUUID.empty
        let applicationService = ApplicationServiceEndpoint("imessage", serviceID: serviceID)
        XCTAssertNotNil(applicationService)
        XCTAssertEqual(applicationService.serviceID.uuidString, "00000000-0000-0000-0000-000000000000")
        let uuid = SystemUUID()
        let applicationService2 = ApplicationServiceEndpoint("imessage", serviceID: uuid)
        XCTAssertNotNil(applicationService2)
        XCTAssertNotEqual(applicationService2.serviceID.uuidString, "00000000-0000-0000-0000-000000000000")
    }

    func testAddressEndpoint() {
        let v4Addr = IPv4Address([0x7F, 0x00, 0x00, 0x01])!
        let v4AddrEndpoint = AddressEndpoint(address: v4Addr, port: 8080)
        XCTAssertEqual(v4AddrEndpoint.port, 8080)
        XCTAssertEqual(v4AddrEndpoint.description, "127.0.0.1:8080")

        let v6Addr = IPv6Address([
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x01,
        ])!
        let v6AddrEndpoint = AddressEndpoint(address: v6Addr, port: 8080)
        XCTAssertEqual(v6AddrEndpoint.port, 8080)
        XCTAssertEqual(v6AddrEndpoint.description, "::1.8080")
    }

    func testURLEndpoint() {
        #if !hasFeature(Embedded) && canImport(Foundation)
        let urlEndpoint = URLEndpoint(url: URL(string: "https://www.apple.com")!)
        XCTAssertNotNil(urlEndpoint, "URL Endpoint should not be nil")
        XCTAssertNotNil(urlEndpoint?.name)
        XCTAssertEqual(urlEndpoint?.name, "www.apple.com")
        XCTAssertEqual(urlEndpoint?.port, 443)
        XCTAssertEqual(urlEndpoint?.schemeIsSecure, true)
        #endif
    }

    func testHostEndpoint() {
        let hostEndpoint = HostEndpoint(name: "www.apple.com", port: 443)
        XCTAssertNotNil(hostEndpoint)
        XCTAssertEqual(hostEndpoint.name, "www.apple.com")
        XCTAssertEqual(hostEndpoint.port, 443)
        XCTAssertEqual(hostEndpoint.weight, 0)
        XCTAssertEqual(hostEndpoint.priority, 0)
    }

    func testApplicationServiceEndpiont() {
        let service = "com.example.service_name"
        let serviceID = SystemUUID()
        let name = service + "/" + serviceID.uuidString
        let appSrvEndpoint = ApplicationServiceEndpoint(service, serviceID: serviceID)
        XCTAssertEqual(appSrvEndpoint.serviceID, serviceID)
        XCTAssertEqual(appSrvEndpoint.name, name)
        // Make a copy
        var appSrvEndpointCopy = appSrvEndpoint
        XCTAssertEqual(appSrvEndpointCopy.serviceID, serviceID)
        XCTAssertEqual(appSrvEndpointCopy.name, name)
        // Alter the copy
        let newServiceID = SystemUUID()
        appSrvEndpointCopy.serviceID = newServiceID
        XCTAssertEqual(appSrvEndpointCopy.serviceID, newServiceID)
        // Validate the original
        XCTAssertEqual(appSrvEndpoint.serviceID, serviceID)
        XCTAssertEqual(appSrvEndpoint.name, name)
    }

    // MARK: -- Unix domain address serialization --

    private func unixPath(of endpoint: Endpoint?) -> String? {
        guard let endpoint, case .address(let address) = endpoint.type, case .unix(let path) = address.type else {
            return nil
        }
        return path
    }

    private func roundTripUnixPath(_ path: String) -> String? {
        guard let address = AddressEndpoint(path), var bytes = Endpoint(address).serialize() else {
            return nil
        }
        return unixPath(of: Endpoint(serializedData: &bytes))
    }

    func testUnixAddressSerialization() {
        let path = "/var/run/test.sock"
        guard let bytes = AddressEndpoint(path)?.serialize() else {
            XCTFail("could not serialize a unix address")
            return
        }
        // sa_len, AF_UNIX, then the path with no terminator
        XCTAssertEqual(bytes, [UInt8(path.utf8.count + 2), AddressFamily.unix.rawValue] + Array(path.utf8))
        XCTAssertEqual(roundTripUnixPath(path), path)
        let longestPath = "/" + String(repeating: "m", count: 103)
        XCTAssertEqual(roundTripUnixPath(longestPath), longestPath)
    }

    func testUnixAddressSerializationOfEmptyPath() {
        // sa_len covers at least one byte of sun_path
        XCTAssertEqual(AddressEndpoint("")?.serialize(), [3, AddressFamily.unix.rawValue, 0])
        XCTAssertEqual(roundTripUnixPath(""), "")
    }

    // A sockaddr_un from another encoder can carry the terminator, or be zero-filled out to its full 106 bytes.
    // Neither is part of the path.
    func testUnixAddressDeserializationStopsAtTerminator() {
        let path = "/var/run/test.sock"
        var terminated: [UInt8] = [UInt8(path.utf8.count + 3), AddressFamily.unix.rawValue] + Array(path.utf8) + [0]
        XCTAssertEqual(unixPath(of: Endpoint(serializedData: &terminated)), path)

        var padded: [UInt8] = [106, AddressFamily.unix.rawValue] + Array(path.utf8)
        padded += [UInt8](repeating: 0, count: 106 - padded.count)
        XCTAssertEqual(unixPath(of: Endpoint(serializedData: &padded)), path)
    }

    func testUnixAddressDeserializationRejectsTruncatedPath() {
        // sa_len claims more bytes than were given
        var truncated: [UInt8] = [20, AddressFamily.unix.rawValue] + Array("/tmp/x".utf8)
        XCTAssertNil(Endpoint(serializedData: &truncated))
    }
}
