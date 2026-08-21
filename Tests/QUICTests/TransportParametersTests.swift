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

#if !NETWORK_NO_SWIFT_QUIC

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
let tpTestsLogPrefixer = LogPrefixer("[TransportParametersTests]")

@available(Network 0.1.0, *)
final class TransportParametersTests: XCTestCase {
    var transportParameters = TransportParameters(logPrefixer: tpTestsLogPrefixer)

    func testDefaultParameter() {
        var parameter: TransportParameter

        parameter = .maxUDPPayloadSize(value: 65527)
        XCTAssertTrue(parameter.usingDefaultValue)
        parameter = .maxIdleTimeout(value: 0)
        XCTAssertTrue(parameter.usingDefaultValue)
        parameter = .ackDelayExponent(value: 3)
        XCTAssertTrue(parameter.usingDefaultValue)
        parameter = .maxAckDelay(value: 25)
        XCTAssertTrue(parameter.usingDefaultValue)
        parameter = .disableActiveMigration()
        XCTAssertFalse(parameter.usingDefaultValue)
        XCTAssertNil(transportParameters[.disableActiveMigration])
    }

    func testUint64Serialization1() throws {
        let maxIdleTimeout = TransportParameter.maxIdleTimeout(value: 55)
        transportParameters.append(maxIdleTimeout)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [0x01, 0x01, 0x37]
        XCTAssertEqual(data, expectedData)
    }

    func testUint64Serialization2() throws {
        let maxAckDelay = TransportParameter.maxAckDelay(value: 555)
        transportParameters.append(maxAckDelay)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [0x0b, 0x02, 0x42, 0x2b]
        XCTAssertEqual(data, expectedData)
    }

    func testUint64Serialization4() throws {
        let initialMaxData = TransportParameter.initialMaxData(value: 73_741_823)
        transportParameters.append(initialMaxData)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [0x04, 0x04, 0x84, 0x65, 0x35, 0xff]
        XCTAssertEqual(data, expectedData)
    }

    func testUint64Serialization8() throws {
        let initialMaxStreamDataBidirectionalRemote =
            TransportParameter.initialMaxStreamDataBidirectionalRemote(
                value: 611_686_018_427_387_903
            )
        transportParameters.append(initialMaxStreamDataBidirectionalRemote)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [
            0x06, 0x08, 0xc8, 0x7d, 0x25, 0x31, 0x62, 0x6f, 0xff, 0xff,
        ]
        XCTAssertEqual(data, expectedData)
    }

    func testOriginalDCIDSerialization() throws {
        let originalDCID = TransportParameter.originalDCID(
            connectionID: QUICConnectionID([0x12, 0x33, 0x55, 0x67])!
        )
        transportParameters.append(originalDCID)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [
            0x00, 0x04, 0x12, 0x33, 0x55, 0x67,
        ]
        XCTAssertEqual(data, expectedData)
    }

    func testInitialSCIDSerialization() throws {
        let initialSCID = TransportParameter.initialSCID(
            connectionID: QUICConnectionID([0xaa, 0x99, 0xc5, 0x17])!
        )
        transportParameters.append(initialSCID)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [
            0x0f, 0x04, 0xaa, 0x99, 0xc5, 0x17,
        ]
        XCTAssertEqual(data, expectedData)
    }

    func testRetrySCIDSerialization() throws {
        let retrySCID = TransportParameter.retrySCID(
            connectionID: QUICConnectionID([0xba, 0x99, 0xc5, 0x27])!
        )
        transportParameters.append(retrySCID)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [0x10, 0x04, 0xba, 0x99, 0xc5, 0x27]
        XCTAssertEqual(data, expectedData)
    }
    func testDisableMigrationSerialization() throws {
        let disableMigration = TransportParameter.disableActiveMigration()
        transportParameters.append(disableMigration)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [0x0c, 0x00]
        XCTAssertEqual(data, expectedData)
    }
    func testDisableMigrationDeserialization() throws {
        let serializedBytes: [UInt8] = [0x0c, 0x00]
        let transportParameters = try TransportParameters.deserialize(
            serializedBytes.span,
            logPrefixer: tpTestsLogPrefixer
        )
        XCTAssertNotNil(transportParameters[.disableActiveMigration])
    }

    func testStatelessResetTokenSerialization() throws {
        let statelessResetToken = TransportParameter.statelessResetToken(
            statelessResetToken: QUICStatelessResetToken([
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            ])!
        )
        transportParameters.append(statelessResetToken)
        let data = try transportParameters.serialize()
        let expectedData: [UInt8] = [
            0x02, 0x10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        ]
        XCTAssertEqual(data, expectedData)
    }

    func testPreferredAddressSerialization() throws {
        let address = PreferredAddress(
            connectionID: QUICConnectionID([5, 6, 7, 8])!,
            statelessResetToken: QUICStatelessResetToken([
                1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ])!,
            ipv4Port: 55,
            ipv4Address: 0xaabb_ccdd,
            ipv6Port: 123,
            ipv6Address: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        let preferredAddress = TransportParameter.preferredAddress(preferredAddress: address)
        transportParameters.append(preferredAddress)
        let data = try transportParameters.serialize()

        let expectedData: [UInt8] = [
            0x0d, 0x2d,
            0xaa, 0xbb, 0xcc, 0xdd, 0x00,
            0x37, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x7b, 0x04, 0x05, 0x06,
            0x07, 0x08, 0x01, 0x02, 0x03, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ]
        XCTAssertEqual(data, expectedData)
    }

    func testSerializeAndDeserialize() throws {
        let originalDCID = TransportParameter.originalDCID(
            connectionID: QUICConnectionID([1, 2, 3, 9])!
        )
        transportParameters.append(originalDCID)

        let initialSCID = TransportParameter.initialSCID(
            connectionID: QUICConnectionID([22, 33, 13, 9])!
        )
        transportParameters.append(initialSCID)

        let retrySCID = TransportParameter.retrySCID(
            connectionID: QUICConnectionID([10, 33, 33, 9])!
        )
        transportParameters.append(retrySCID)

        let maxIdleTimeout = TransportParameter.maxIdleTimeout(value: 22)
        transportParameters.append(maxIdleTimeout)

        let statelessResetToken = TransportParameter.statelessResetToken(
            statelessResetToken: QUICStatelessResetToken([
                9, 11, 66, 12, 77, 22, 99, 100, 1, 22, 33, 33, 13, 17, 99, 200,
            ])!
        )
        transportParameters.append(statelessResetToken)

        let maxUDPPayloadSize = TransportParameter.maxUDPPayloadSize(value: 1200)
        transportParameters.append(maxUDPPayloadSize)

        let initialMaxData = TransportParameter.initialMaxData(value: 4444)
        transportParameters.append(initialMaxData)

        let initialMaxStreamDataBidirectionalLocal =
            TransportParameter.initialMaxStreamDataBidirectionalLocal(value: 33333)
        transportParameters.append(initialMaxStreamDataBidirectionalLocal)

        let initialMaxStreamDataBidirectionalRemote =
            TransportParameter.initialMaxStreamDataBidirectionalRemote(value: 9999)
        transportParameters.append(initialMaxStreamDataBidirectionalRemote)

        let initialMaxStreamDataUnidirectional =
            TransportParameter.initialMaxStreamDataUnidirectional(value: 757532)
        transportParameters.append(initialMaxStreamDataUnidirectional)

        let initialMaxStreamsBidirectional = TransportParameter.initialMaxStreamsBidirectional(
            value: 2335
        )
        transportParameters.append(initialMaxStreamsBidirectional)

        let initialMaxStreamsUnidirectional = TransportParameter.initialMaxStreamsUnidirectional(
            value: 877
        )
        transportParameters.append(initialMaxStreamsUnidirectional)

        let ackDelayExponent = TransportParameter.ackDelayExponent(value: 20)
        transportParameters.append(ackDelayExponent)

        let maxAckDelay = TransportParameter.maxAckDelay(value: 7755)
        transportParameters.append(maxAckDelay)

        let disableActiveMigration = TransportParameter.disableActiveMigration()
        transportParameters.append(disableActiveMigration)

        let maxDatagramFrameSize = TransportParameter.maxDatagramFrameSize(value: 65527)
        transportParameters.append(maxDatagramFrameSize)

        let preferredAddress = PreferredAddress(
            connectionID: QUICConnectionID([20, 30, 40, 50])!,
            statelessResetToken: QUICStatelessResetToken([
                7, 33, 11, 33, 44, 67, 99, 62, 12, 44, 11, 17, 9, 55, 110, 2,
            ])!,
            ipv4Port: 535,
            ipv4Address: 0xcafe_babe,
            ipv6Port: 1233,
            ipv6Address: [44, 1, 2, 6, 1, 33, 11, 200, 21, 99, 24, 15, 77, 33, 91, 2]
        )
        let preferredAddressParameter = TransportParameter.preferredAddress(
            preferredAddress: preferredAddress
        )
        transportParameters.append(preferredAddressParameter)

        let activeConnectionIDLimit = TransportParameter.activeConnectionIDLimit(value: 128)
        transportParameters.append(activeConnectionIDLimit)

        let minAckDelay = TransportParameter.minAckDelay(value: 1000)
        transportParameters.append(minAckDelay)

        let data = try transportParameters.serialize()
        let newParameters = try TransportParameters.deserialize(
            data.span,
            logPrefixer: tpTestsLogPrefixer
        )

        XCTAssertEqual(newParameters[.originalDCID]!, originalDCID)
        XCTAssertEqual(newParameters[.initialSCID]!, initialSCID)
        XCTAssertEqual(newParameters[.retrySCID]!, retrySCID)
        XCTAssertEqual(newParameters[.maxIdleTimeout]!, maxIdleTimeout)
        XCTAssertEqual(
            newParameters[.statelessResetToken]!,
            statelessResetToken
        )
        XCTAssertEqual(newParameters[.maxUDPPayloadSize]!, maxUDPPayloadSize)
        XCTAssertEqual(newParameters[.initialMaxData]!, initialMaxData)
        XCTAssertEqual(
            newParameters[.initialMaxStreamDataBidirectionalLocal]!,
            initialMaxStreamDataBidirectionalLocal
        )
        XCTAssertEqual(
            newParameters[.initialMaxStreamDataBidirectionalRemote]!,
            initialMaxStreamDataBidirectionalRemote
        )
        XCTAssertEqual(
            newParameters[.initialMaxStreamDataUnidirectional]!,
            initialMaxStreamDataUnidirectional
        )
        XCTAssertEqual(
            newParameters[.initialMaxStreamsBidirectional]!,
            initialMaxStreamsBidirectional
        )
        XCTAssertEqual(
            newParameters[.initialMaxStreamsUnidirectional]!,
            initialMaxStreamsUnidirectional
        )
        XCTAssertEqual(newParameters[.ackDelayExponent]!, ackDelayExponent)
        XCTAssertEqual(newParameters[.preferredAddress]!, preferredAddressParameter)
        XCTAssertEqual(newParameters[.maxAckDelay]!, maxAckDelay)
        XCTAssertEqual(newParameters[.disableActiveMigration]!, disableActiveMigration)
        XCTAssertEqual(newParameters[.maxDatagramFrameSize]!, maxDatagramFrameSize)
    }

    func testPreferredAddressEqualityComparesBothSides() {
        let addressA = PreferredAddress(
            connectionID: QUICConnectionID([1, 2, 3, 4])!,
            statelessResetToken: QUICStatelessResetToken(Array(repeating: 0xAA, count: 16))!,
            ipv4Port: 1111,
            ipv4Address: 0x0000_0001,
            ipv6Port: 1111,
            ipv6Address: Array(repeating: 0xAA, count: 16)
        )
        let addressB = PreferredAddress(
            connectionID: QUICConnectionID([5, 6, 7, 8])!,
            statelessResetToken: QUICStatelessResetToken(Array(repeating: 0xBB, count: 16))!,
            ipv4Port: 2222,
            ipv4Address: 0x0000_0002,
            ipv6Port: 2222,
            ipv6Address: Array(repeating: 0xBB, count: 16)
        )
        let paramA = TransportParameter.preferredAddress(preferredAddress: addressA)
        let paramB = TransportParameter.preferredAddress(preferredAddress: addressB)
        XCTAssertNotEqual(paramA, paramB)
    }

    func testDeserializeUnknown() {
        let serializedBytes: [UInt8] = [
            0x01, /* type */ 0x04, /* len */
            0x80, 0x00, 0x75, 0x30, /* value */
            0x51, 0x5c, /* type */ 0x04, /* len */
            0x57, 0x57, 0x57, 0x57 /* value */,
        ]

        XCTAssertNoThrow(
            try TransportParameters.deserialize(
                serializedBytes.span,
                logPrefixer: tpTestsLogPrefixer
            )
        )
    }

    func testDeserializeInvalid1() {
        let serializedBytes: [UInt8] = [
            0x00, 0x80,
        ]
        XCTAssertThrowsError(
            try TransportParameters.deserialize(
                serializedBytes.span,
                logPrefixer: tpTestsLogPrefixer
            )
        )

    }

    func testDeserializeInvalid2() {
        let serializedBytes: [UInt8] = [
            0x02,
            0x16, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            10, 11, 12, 13, 14, 15, 16,
        ]
        XCTAssertThrowsError(
            try TransportParameters.deserialize(
                serializedBytes.span,
                logPrefixer: tpTestsLogPrefixer
            )
        )

    }

    func testDeserializeInvalid3() {
        let serializedBytes: [UInt8] = [
            0x01,
            0x16, 1, 2, 3, 4, 5, 6, 7, 8, 9,
            10, 11, 12, 13, 14, 15, 16,
        ]
        XCTAssertThrowsError(
            try TransportParameters.deserialize(
                serializedBytes.span,
                logPrefixer: tpTestsLogPrefixer
            )
        )

    }
    func testDeserializeATS() throws {
        // A test vector from the ATS QUIC implementation.
        let serializedBytes: [UInt8] = [
            0x01, 0x04, 0x80, 0x00, 0x75, 0x30,
            0x02, 0x10, 0x57, 0x57, 0x0e, 0x6b, 0x76, 0xc9, 0x6b, 0x81,
            0x10, 0x7b, 0x7b, 0xa2, 0x5d, 0x5c, 0x9b, 0x1d,
            0x04, 0x04, 0x80, 0x01, 0x00, 0x00,
            0x06, 0x02, 0x50, 0x00,
            0x07, 0x02, 0x50, 0x00,
            0x08, 0x02, 0x40, 0x64,
            0x09, 0x02, 0x40, 0x64,
            0x0a, 0x01, 0x03,
            0x0d, 0x3b, 0x43, 0xc0, 0xf6, 0x9f, 0x11, 0x51, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12,
            0xcf, 0x2e, 0x7e, 0xe2, 0x7f, 0x10, 0x53, 0x97,
            0x39, 0xb2, 0xf1, 0x4e, 0xba, 0x33, 0x22, 0xe6,
            0x4f, 0x6b, 0x08, 0x17, 0x82, 0xc2, 0x5d, 0x9b,
            0x94, 0x62, 0x87, 0x7d, 0x92, 0x51, 0x92, 0xef,
            0x21, 0xb3,
        ]
        let transportParameters = try TransportParameters.deserialize(
            serializedBytes.span,
            logPrefixer: tpTestsLogPrefixer
        )
        XCTAssertEqual(transportParameters[.maxIdleTimeout]!.value, 30000)
        XCTAssertEqual(transportParameters[.initialMaxData]!.value, 65536)
        XCTAssertEqual(transportParameters[.initialMaxStreamDataBidirectionalRemote]!.value, 4096)
        XCTAssertEqual(transportParameters[.initialMaxStreamDataUnidirectional]!.value, 4096)
        XCTAssertEqual(transportParameters[.initialMaxStreamsBidirectional]!.value, 100)
        XCTAssertEqual(transportParameters[.initialMaxStreamsUnidirectional]!.value, 100)
        XCTAssertEqual(transportParameters[.ackDelayExponent]!.value, 3)
        XCTAssertEqual(
            transportParameters[.statelessResetToken]!.statelessResetToken,
            QUICStatelessResetToken([
                0x57, 0x57, 0x0e, 0x6b, 0x76, 0xc9, 0x6b, 0x81, 0x10, 0x7b, 0x7b, 0xa2, 0x5d, 0x5c,
                0x9b, 0x1d,
            ])
        )
        XCTAssertEqual(transportParameters[.preferredAddress]!.preferredAddress.ipv4Port, 4433)
        XCTAssertEqual(
            transportParameters[.preferredAddress]!.preferredAddress.ipv4Address,
            0x43c0_f69f
        )
        XCTAssertEqual(transportParameters[.preferredAddress]!.preferredAddress.ipv6Port, 0)
        XCTAssertEqual(
            transportParameters[.preferredAddress]!.preferredAddress.ipv6Address,
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(
            transportParameters[.preferredAddress]!.preferredAddress.connectionID,
            QUICConnectionID([
                0xcf, 0x2e, 0x7e, 0xe2, 0x7f, 0x10, 0x53, 0x97, 0x39, 0xb2, 0xf1, 0x4e, 0xba, 0x33,
                0x22, 0xe6, 0x4f, 0x6b,
            ])
        )
        XCTAssertEqual(
            transportParameters[.preferredAddress]!.preferredAddress.statelessResetToken,
            QUICStatelessResetToken([
                0x08, 0x17, 0x82, 0xc2, 0x5d, 0x9b,
                0x94, 0x62, 0x87, 0x7d, 0x92, 0x51,
                0x92, 0xef, 0x21, 0xb3,
            ])
        )

    }

    func testDeserializeGoogle() throws {
        // A test vector from the Google QUIC implementation.
        // Includes a couple of private extensions.
        let serializedBytes: [UInt8] = [
            0x01, 0x04, 0x80, 0x00, 0x75, 0x30,
            0x02, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x03, 0x02, 0x45, 0xc0,
            0x04, 0x04, 0x80, 0x10, 0x00, 0x00,
            0x05, 0x04, 0x80, 0x01, 0x00, 0x00,
            0x06, 0x04, 0x80, 0x01, 0x00, 0x00,
            0x07, 0x04, 0x80, 0x01, 0x00, 0x00,
            0x08, 0x02, 0x40, 0x64,
            0x09, 0x02, 0x40, 0x64,
            0x47, 0x51, 0x14, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x53, 0x43, 0x4c, 0x53, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00,
            0x47, 0x52, 0x19, 0xff, 0x00, 0x00, 0x16, 0x14, 0x51, 0x30,
            0x39, 0x39, 0x51, 0x30, 0x34, 0x36, 0x51, 0x30, 0x34, 0x33,
            0x51, 0x30, 0x33, 0x39, 0xff, 0x00, 0x00, 0x16,
        ]

        let transportParameters = try TransportParameters.deserialize(
            serializedBytes.span,
            logPrefixer: tpTestsLogPrefixer
        )
        XCTAssertEqual(transportParameters[.maxIdleTimeout]!.value, 30000)
        XCTAssertEqual(transportParameters[.maxUDPPayloadSize]!.value, 1472)
        XCTAssertEqual(transportParameters[.initialMaxData]!.value, 1_048_576)
        XCTAssertEqual(transportParameters[.initialMaxStreamDataBidirectionalLocal]!.value, 65536)
        XCTAssertEqual(transportParameters[.initialMaxStreamDataBidirectionalRemote]!.value, 65536)
        XCTAssertEqual(transportParameters[.initialMaxStreamDataUnidirectional]!.value, 65536)
        XCTAssertEqual(transportParameters[.initialMaxStreamsBidirectional]!.value, 100)
        XCTAssertEqual(transportParameters[.initialMaxStreamsUnidirectional]!.value, 100)

    }

    func testGREASE() throws {
        let maxUDPPayloadSize = TransportParameter.maxUDPPayloadSize(value: 1200)
        let initialMaxData = TransportParameter.initialMaxData(value: 4444)
        let initialMaxStreamDataBidirectionalLocal =
            TransportParameter.initialMaxStreamDataBidirectionalLocal(value: 33333)
        let initialMaxStreamDataUnidirectional =
            TransportParameter.initialMaxStreamDataUnidirectional(value: 757532)
        let initialMaxStreamsBidirectional = TransportParameter.initialMaxStreamsBidirectional(
            value: 2335
        )
        let initialMaxStreamsUnidirectional = TransportParameter.initialMaxStreamsUnidirectional(
            value: 877
        )
        let ackDelayExponent = TransportParameter.ackDelayExponent(value: 20)
        let maxAckDealy = TransportParameter.maxAckDelay(value: 7755)
        let disableActiveMigration = TransportParameter.disableActiveMigration()

        transportParameters.append(maxUDPPayloadSize)
        transportParameters.append(initialMaxData)
        transportParameters.append(initialMaxStreamDataBidirectionalLocal)
        transportParameters.append(initialMaxStreamDataUnidirectional)
        transportParameters.append(initialMaxStreamsBidirectional)
        transportParameters.append(initialMaxStreamsUnidirectional)
        transportParameters.append(ackDelayExponent)
        transportParameters.append(maxAckDealy)
        transportParameters.append(disableActiveMigration)

        let data1 = try transportParameters.serialize()
        let data2 = try transportParameters.serialize()
        XCTAssertNotEqual(data1, data2)

    }

    func testParameterTypesHaveContiguousIndices() {
        // Each value should contribute a unique index, the order doesn't matter. Check
        // against 'allCases' as that's guaranteed to have one unique index per element.
        let indices = TransportParameterTypes.allCases.map { $0.index }.sorted()
        XCTAssertEqual(Array(TransportParameterTypes.allCases.indices), indices)
    }
}

#endif
