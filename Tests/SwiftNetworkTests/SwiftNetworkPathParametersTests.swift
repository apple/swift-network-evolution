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

// `Deque` supplies the array-literal initializer the preference fields are written with, so the
// module declaring it has to be imported here even though nothing below names `Deque`.
#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
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

    // Two freshly built values must read their defaults and compare equal; a write that landed on
    // the shared default backing in place would break both for every value built after it.
    func testReadingAPreferenceDoesNotMakeValuesUnequal() {
        let read = PathParameters()
        let untouched = PathParameters()

        XCTAssertNil(read.prohibitedInterfaceTypes)
        XCTAssertNil(read.requiredInterface)

        XCTAssertEqual(read.interfacePreferenceValues, untouched.interfacePreferenceValues)
        XCTAssertEqual(read.protocolValues, untouched.protocolValues)
    }

    // A value set back to its defaults must equal one never written to, and hash the same; otherwise
    // `NWParameters` breaks its `NSObject` hash contract, and it is reachable as an `NSDictionary` key.
    func testPreferenceSetBackToDefaultEqualsUntouched() {
        var reset = PathParameters()
        reset.prohibitedInterfaceTypes = [.wifi]
        reset.prohibitedInterfaceTypes = nil

        let untouched = PathParameters()

        XCTAssertEqual(reset.interfacePreferenceValues, untouched.interfacePreferenceValues)
        XCTAssertEqual(
            reset.interfacePreferenceValues.hashValue,
            untouched.interfacePreferenceValues.hashValue,
            "equal values must hash equally"
        )
    }

    // The same for `ProtocolValues`, which is a separate class-backed store.
    func testTransportOptionsSetBackToNilEqualsUntouched() {
        var reset = PathParameters()
        reset.transportOptions = .udp(
            ProtocolOptions<UDPProtocol>(protocolIdentifier: UDPProtocol.identifier, perProtocolOptions: nil)
        )
        reset.transportOptions = nil

        let untouched = PathParameters()

        XCTAssertEqual(reset.protocolValues, untouched.protocolValues)
        XCTAssertEqual(
            reset.protocolValues.hashValue,
            untouched.protocolValues.hashValue,
            "equal values must hash equally"
        )
    }

    // Protocol options are held by a second class-backed store, `ProtocolValues`, which needs the same
    // copy-on-write; otherwise a copy clearing its transport options clears the original's too.
    func testWritingTransportOptionsDoesNotAffectACopy() {
        var original = PathParameters()
        original.transportOptions = .udp(
            ProtocolOptions<UDPProtocol>(protocolIdentifier: UDPProtocol.identifier, perProtocolOptions: nil)
        )

        var copy = original
        copy.transportOptions = nil

        XCTAssertNotNil(original.transportOptions, "original was cleared through the copy")
        XCTAssertNil(copy.transportOptions, "copy did not take the new value")
    }
}
