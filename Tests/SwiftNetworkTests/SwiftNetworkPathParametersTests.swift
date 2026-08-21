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
@_spi(Essentials) @testable import SwiftNetwork
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkPathParametersTests: NetTestCase {
    // `PathParameters` has value semantics, so copies must be independent. Its interface preferences
    // live behind a shared class, so without copy-on-write a write through one copy is visible
    // through the other — callers would observe changes they never made.
    func testWritingInterfacePreferenceDoesNotAffectACopy() {
        var original = PathParameters()
        original.prohibitedInterfaceTypes = [.wifi]

        var copy = original
        copy.prohibitedInterfaceTypes = [.cellular]

        XCTAssertEqual(original.prohibitedInterfaceTypes, [.wifi], "original was mutated through the copy")
        XCTAssertEqual(copy.prohibitedInterfaceTypes, [.cellular], "copy did not take the new value")
    }

    // The whole backing must be copied, not just the field being assigned; otherwise writing one
    // field leaks every other field into the copy that shares the backing.
    func testWritingOneFieldDoesNotLeakOthersIntoACopy() {
        var original = PathParameters()
        original.prohibitedInterfaceTypes = [.wifi]

        var copy = original
        copy.preferredInterfaceSubtypes = [.wifiAWDL]

        XCTAssertNil(original.preferredInterfaceSubtypes, "unrelated field leaked into the original")
        XCTAssertEqual(original.prohibitedInterfaceTypes, [.wifi], "original lost its own value")
        XCTAssertEqual(copy.prohibitedInterfaceTypes, [.wifi], "copy did not inherit the original value")
    }

    // Mutating the original after a copy is taken must not write through to the copy either; the
    // copy-on-write has to trigger whichever side is written first.
    func testWritingTheOriginalDoesNotAffectAnEarlierCopy() {
        var original = PathParameters()
        original.prohibitedInterfaceTypes = [.wifi]

        let copy = original
        original.prohibitedInterfaceTypes = [.cellular]

        XCTAssertEqual(copy.prohibitedInterfaceTypes, [.wifi], "copy was mutated through the original")
        XCTAssertEqual(original.prohibitedInterfaceTypes, [.cellular], "original did not take the new value")
    }

    // Reading must not allocate a backing. An absent backing and an allocated-but-empty one are not
    // equal, so a read that allocates would make two untouched values compare unequal.
    func testReadingAPreferenceDoesNotMakeValuesUnequal() {
        var read = PathParameters()
        let untouched = PathParameters()

        XCTAssertNil(read.prohibitedInterfaceTypes)
        XCTAssertNil(read.requiredInterface)

        XCTAssertEqual(read.interfacePreferenceValues, untouched.interfacePreferenceValues)
    }
}
