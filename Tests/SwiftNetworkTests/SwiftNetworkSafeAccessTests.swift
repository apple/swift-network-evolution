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

#if canImport(Android)
import Android
#endif

@testable import SwiftNetwork

#if !hasFeature(Embedded)

final class SwiftNetworkSafeAccessTests: NetTestCase {

    func testLoadingValidCStructure() throws {
        var ipv4Addr = sockaddr_in()
        ipv4Addr.sin_family = sa_family_t(AF_INET)
        let myStruct = withUnsafeBytes(
            of: &ipv4Addr,
            { rawBufferPointer in
                SafeAccess.loadCStructure(buffer: rawBufferPointer, type: sockaddr_in.self)
            }
        )
        XCTAssertNotNil(myStruct)
        XCTAssertTrue(myStruct?.sin_family == 2)

    }

    func testLoadingNonConformingTypes() throws {
        // The size here should make the type return nil
        var test: [Double] = [0.44]
        let myStruct = withUnsafeBytes(
            of: &test,
            { rawBufferPointer in
                SafeAccess.loadCStructure(buffer: rawBufferPointer, type: sockaddr_in.self)
            }
        )
        XCTAssertNil(myStruct)  // This should return nil because of the size of the buffer

        // This should crash if calling load() directly on it.
        var bytes: [UInt8] = [0x01, 0x02]
        let myStruct2 = withUnsafeBytes(
            of: &bytes,
            { rawBufferPointer in
                let misalignedBuffer = UnsafeRawBufferPointer(
                    start: rawBufferPointer.baseAddress!.advanced(by: 1),
                    count: rawBufferPointer.count
                )
                return SafeAccess.loadCStructure(buffer: misalignedBuffer, type: [UInt16].self)
            }
        )
        XCTAssertNil(myStruct2)  // This should return nil because its misaligned
    }
}
#endif
