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

#if QlogOutput

@available(Network 0.1.0, *)
let qlogTestsLogPrefixer = LogPrefixer("[QLogTests]")

@available(Network 0.1.0, *)
final class QLogTests: XCTestCase {
    var qlog: QLog = QLog()

    override func setUp() {
        qlog = QLog()
    }

    func assertStringJSONContent(
        _ result: String,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resultData = result.data(using: String.Encoding.utf8)!
        let expectedData = expected.data(using: String.Encoding.utf8)!

        let resultJsonObject: Any
        do {
            resultJsonObject = try JSONSerialization.jsonObject(with: resultData)
        } catch {
            XCTFail(
                "Error while JSON-serializing result string:\n\(result)\n Error details: \(error)",
                file: file,
                line: line
            )
            return
        }
        // Expected data should always be valid JSON and a Dictionary
        let expectedJsonObject =
            try! JSONSerialization.jsonObject(with: expectedData) as! NSDictionary

        guard let resultJsonObject = resultJsonObject as? NSDictionary else {
            XCTFail(
                "JSON-serialized result \(resultJsonObject) is not a dictionary",
                file: file,
                line: line
            )
            return
        }

        XCTAssertEqual(resultJsonObject, expectedJsonObject, file: file, line: line)
    }

    func testWriteToFile() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        let mutableFileName = strdup("/tmp/qlog.XXXXXX")!
        close(mkstemp(mutableFileName))
        defer {
            unlink(mutableFileName)
            free(mutableFileName)
        }
        let fileName = String(cString: mutableFileName)

        qlog.dumpJSONToFile(atPath: fileName, forFlowType: .client)
        let resultData = FileManager.default.contents(atPath: fileName)
        guard let resultData else {
            XCTFail("Unable to read contents of file \(fileName)")
            return
        }
        XCTAssertEqual(resultData.count, expected_data.count)
        let result = String(data: resultData, encoding: String.defaultCStringEncoding)
        guard let result else {
            XCTFail("File contents of file \(fileName) is not a string")
            return
        }
        assertStringJSONContent(result, expected: expected_data)
    }

    func testClientView() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }
        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testServerView() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[],
                        \"vantage_point\":{\"flow\":\"server\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }
        let result = qlog.dumpJSONString(forFlowType: .server)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testRTT() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[
                            [0,\"RECOVERY\",\"METRICS_UPDATED\",{\"latest_rtt\":20,\"min_rtt\":20,\"rtt_variance\":10,\"smoothed_rtt\":20}]
                        ],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        var rtt = RTT(logPrefixer: qlogTestsLogPrefixer)
        rtt.processNewSample(
            ackDuration: .microseconds(20),
            packetAckedTime: .init(microseconds: 120),
            ackDelay: .microseconds(10)
        )
        qlog.rttUpdated(
            minRTT: .milliseconds(20),
            smoothedRTT: .milliseconds(20),
            latestRTT: .milliseconds(20),
            rttVariance: .milliseconds(10),
            timestamp: .zero
        )

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }
    func testRecovery() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[
                            [0,\"RECOVERY\",\"METRICS_UPDATED\",{\"in_recovery\":\"true\",\"pto_count\":44}]
                        ],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }
        qlog.recoveryUpdated(ptoCount: 44, inRecovery: true, timestamp: .zero)

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testCC() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[
                            [0,\"RECOVERY\",\"METRICS_UPDATED\",{\"bytes_in_flight\":1000,\"congestion_window\":44000,\"packets_in_flight\":1,\"ssthresh\":3000}]
                        ],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        qlog.congestionControlUpdated(
            congestionWindow: 44000,
            bytesInFlight: 1000,
            slowStartThresh: 3000,
            packetsInFlight: 1,
            timestamp: .zero
        )

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testCongestionState() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[
                            [0,\"RECOVERY\",\"CONGESTION_STATE_UPDATED\",{\"new\":\"recovery\",\"trigger\":\"ecn\"}]
                        ],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        qlog.logCongestionStateUpdated(
            oldState: nil,
            newState: .recovery,
            trigger: .ecn,
            timestamp: .zero
        )

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testParameters() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[
                            [0,\"TRANSPORT\",\"PARAMETERS_SET\",
                                {
                                    \"ack_delay_exponent\":3,
                                    \"active_connection_id_limit\":0,
                                    \"disable_active_migration\":\"false\",
                                    \"initial_max_data\":1024,
                                    \"initial_max_stream_data_bidi_local\":0,
                                    \"initial_max_stream_data_bidi_remote\":0,
                                    \"initial_max_stream_data_uni\":0,
                                    \"initial_max_streams_bidi\":0,
                                    \"initial_max_streams_uni\":0,
                                    \"initial_source_connection_id\":\"\",
                                    \"max_ack_delay\":25,
                                    \"max_idle_timeout\":0,
                                    \"max_udp_payload_size\":65527,
                                    \"original_destination_connection_id\":\"\",
                                    \"owner\":\"local\",
                                    \"retry_source_connection_id\":\"\",
                                    \"tls_cipher\":\"\"}]
                        ],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        // Setup default values for TransportParameters
        var transportParameters = TransportParameters(logPrefixer: qlogTestsLogPrefixer)
        let ackDelayExponent = TransportParameter.ackDelayExponent(value: 3)
        transportParameters.append(ackDelayExponent)
        let activeConnectionIDLimit = TransportParameter.activeConnectionIDLimit(value: 0)
        transportParameters.append(activeConnectionIDLimit)
        let initialMaxStreamDataBidiLocal =
            TransportParameter.initialMaxStreamDataBidirectionalLocal(value: 0)
        transportParameters.append(initialMaxStreamDataBidiLocal)
        let initialMaxStreamDataBidiRemote =
            TransportParameter.initialMaxStreamDataBidirectionalRemote(value: 0)
        transportParameters.append(initialMaxStreamDataBidiRemote)
        let initialMaxStreamDataUni = TransportParameter.initialMaxStreamDataUnidirectional(
            value: 0
        )
        transportParameters.append(initialMaxStreamDataUni)
        let initialMaxStreamsBidi = TransportParameter.initialMaxStreamsBidirectional(value: 0)
        transportParameters.append(initialMaxStreamsBidi)
        let initialMaxStreamsUni = TransportParameter.initialMaxStreamsUnidirectional(value: 0)
        transportParameters.append(initialMaxStreamsUni)
        let emptyConnectionID = QUICConnectionID(0)
        let initialSCID = TransportParameter.initialSCID(connectionID: emptyConnectionID)
        transportParameters.append(initialSCID)
        let maxAckDelay = TransportParameter.maxAckDelay(value: 25)
        transportParameters.append(maxAckDelay)
        let maxIdleTimeout = TransportParameter.maxIdleTimeout(value: 0)
        transportParameters.append(maxIdleTimeout)
        let maxUDPPayloadSize = TransportParameter.maxUDPPayloadSize(value: 65527)
        transportParameters.append(maxUDPPayloadSize)
        let originalDCID = TransportParameter.originalDCID(connectionID: emptyConnectionID)
        transportParameters.append(originalDCID)
        let retrySCID = TransportParameter.retrySCID(connectionID: emptyConnectionID)
        transportParameters.append(retrySCID)
        let initialMaxData = TransportParameter.initialMaxData(value: 1024)
        transportParameters.append(initialMaxData)

        qlog.parametersSet(
            owner: .local,
            resumptionAllowed: nil,
            earlyDataEnabled: nil,
            tlsCipher: "",
            originalDCID: transportParameters[TransportParameterTypes.originalDCID]?.connectionID,
            initialSCID: transportParameters[TransportParameterTypes.initialSCID]?.connectionID,
            retrySCID: transportParameters[TransportParameterTypes.retrySCID]?.connectionID,
            disableActiveMigration: transportParameters[
                TransportParameterTypes.disableActiveMigration
            ] != nil ? true : false,
            maxIdleTimeout: transportParameters[TransportParameterTypes.maxIdleTimeout]?.value,
            maxUDPPayloadSize: transportParameters[TransportParameterTypes.maxUDPPayloadSize]?
                .value,
            ackDelayExponent: transportParameters[TransportParameterTypes.ackDelayExponent]?
                .value,
            maxAckDelay: transportParameters[TransportParameterTypes.maxAckDelay]?.value,
            activeConnectionIDLimit: transportParameters[
                TransportParameterTypes.activeConnectionIDLimit
            ]?.value,
            initialMaxData: transportParameters[TransportParameterTypes.initialMaxData]?.value,
            initialMaxStreamDataBidirectionalRemote: transportParameters[
                TransportParameterTypes.initialMaxStreamDataBidirectionalRemote
            ]?.value,
            initialMaxStreamDataBidirectionalLocal: transportParameters[
                TransportParameterTypes.initialMaxStreamDataBidirectionalLocal
            ]?.value,
            initialMaxStreamDataUnidirectional: transportParameters[
                TransportParameterTypes.initialMaxStreamDataUnidirectional
            ]?.value,
            initialMaxStreamsBidirectional: transportParameters[
                TransportParameterTypes.initialMaxStreamsBidirectional
            ]?.value,
            initialMaxStreamsUnidirectional: transportParameters[
                TransportParameterTypes.initialMaxStreamsUnidirectional
            ]?.value,
            preferredAddress: nil,
            timestamp: .zero
        )

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testMultipleEvents() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[
                            [0,\"RECOVERY\",\"METRICS_UPDATED\",{\"in_recovery\":\"true\",\"pto_count\":44}],
                            [0,\"RECOVERY\",\"METRICS_UPDATED\",{\"bytes_in_flight\":1000,\"congestion_window\":44000,\"packets_in_flight\":1,\"ssthresh\":3000}]
                        ],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        qlog.recoveryUpdated(ptoCount: 44, inRecovery: true, timestamp: .zero)
        qlog.congestionControlUpdated(
            congestionWindow: 44000,
            bytesInFlight: 1000,
            slowStartThresh: 3000,
            packetsInFlight: 1,
            timestamp: .zero
        )

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }

    func testSetTopLevelEntry() {
        let expected_data = """
            {
                \"qlog_version\":\"draft-01\",
                \"title\":\"ClientQLog\",
                \"description\":\"ClientQLogDescription\",
                \"traces\":[
                    {
                        \"configuration\":{\"time_units\":\"us\"},
                        \"event_fields\":[\"time\",\"CATEGORY\",\"EVENT_TYPE\",\"DATA\"],
                        \"events\":[],
                        \"vantage_point\":{\"flow\":\"client\",\"type\":\"network\"}
                    }
                ]
            }
            """.filter { $0 != " " && $0 != "\n" && $0 != "\t" }

        qlog.setTopLevelObjectEntry("title", to: "ClientQLog")
        qlog.setTopLevelObjectEntry("description", to: "ClientQLogDescription")

        let result = qlog.dumpJSONString(forFlowType: .client)!
        XCTAssertEqual(result.count, expected_data.count)
        assertStringJSONContent(result, expected: expected_data)
    }
}
#endif

#endif
