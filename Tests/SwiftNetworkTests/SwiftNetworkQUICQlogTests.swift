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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

#if IMPORT_SWIFTTLS
#if EXPORT_SWIFTTLS
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) import SwiftTLS
#else
@_spi(SwiftTLSOptions) @_spi(SwiftTLSProtocol) @_weakLinked internal import SwiftTLS
#endif
#endif

#if canImport(Crypto)
import Crypto
#elseif canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Android)
import Android
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if QlogOutput

@available(Network 0.1.0, *)
final class SwiftNetworkQUICQlogTests: NetTestCase {
    func testQUICWriteClientQlogFileOnDataTransfer() throws {
        let dataBlock: [UInt8] = Array("Hello World!".utf8)
        let title = "ClientQLog"
        let description = "ClientQLogDescription"
        // NOTE: Test not using a trailing slash at the end of the path name
        let path = try makeQlogDirectory()
        //defer { removeQlogDirectory(path) }
        let harness = QUICTestHarness(realTime: #function)

        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { connectionOptions in
            connectionOptions.qlogConfiguration = QLogConfiguration(
                logTitle: title,
                logDescription: description,
                logPath: path
            )
        }
        harness.runQUICTest(dataBlock: dataBlock, clientOptions: clientOptions)

        // Validate the qlog file is present (based on how it creates the file)
        let finalPath = path + "/qlog_client_\(title)_C1.qlog"

        // The close queues the qlog write on the context; `flush` returns once it has run.
        harness.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath), "qlog file was not written")

        let resultData = FileManager.default.contents(atPath: finalPath)
        guard let resultData else {
            XCTFail("Unable to read contents of file \(finalPath)")
            return
        }
        XCTAssertNotNil(resultData)
    }

    // Opens four client streams, sends 40,000 bytes on each, and checks the qlog against the
    // event schema: the log envelope, event names, time order, and the stream frames each side saw.
    func testQUICQlogFourStreamsWithDataTransfer() throws {
        let streamCount = 4
        let bytesPerStream = 40_000
        let title = "FourStreamQLog"
        let path = try makeQlogDirectory()
        //defer { removeQlogDirectory(path) }
        let harness = QUICTestHarness(realTime: #function)

        let clientOptions = QUICProtocol.options()
        clientOptions.modifyConnectionOptions { connectionOptions in
            connectionOptions.qlogConfiguration = QLogConfiguration(
                logTitle: title,
                logDescription: "Four streams with 40k each",
                logPath: path
            )
        }
        harness.runQUICTest(
            streamCount: streamCount,
            blockSize: 1000,
            blockCount: bytesPerStream / 1000,
            clientOptions: clientOptions
        )

        // The close queues the qlog write on the context; `flush` returns once it has run.
        harness.flush()
        let finalPath = path + "/qlog_client_\(title)_C1.qlog"
        let data = try XCTUnwrap(FileManager.default.contents(atPath: finalPath), "qlog file was not written")
        let log = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The log file: schema and format come first in the file, per the 256 byte guidance.
        XCTAssertEqual(log["file_schema"] as? String, "urn:ietf:params:qlog:file:contained")
        XCTAssertEqual(log["serialization_format"] as? String, "application/qlog+json")
        XCTAssertEqual(log["title"] as? String, title)
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
        XCTAssertTrue(prefix.contains("file_schema") && prefix.contains("serialization_format"))

        // The trace.
        let traces = try XCTUnwrap(log["traces"] as? [[String: Any]])
        XCTAssertEqual(traces.count, 1)
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace["event_schemas"] as? [String], ["urn:ietf:params:qlog:events:quic-14"])
        XCTAssertEqual((trace["vantage_point"] as? [String: Any])?["type"] as? String, "client")
        XCTAssertEqual((trace["implementation"] as? [String: Any])?["name"] as? String, "SwiftQUIC")
        let referenceTime = (trace["common_fields"] as? [String: Any])?["reference_time"] as? [String: Any]
        XCTAssertEqual(referenceTime?["clock_type"] as? String, "monotonic")
        XCTAssertEqual(referenceTime?["epoch"] as? String, "unknown")

        // Every event has time, name and data, in time order, with a name from the quic namespace.
        let events = try XCTUnwrap(trace["events"] as? [[String: Any]])
        XCTAssertFalse(events.isEmpty)
        let knownNames: Set<String> = [
            "quic:parameters_set", "quic:packet_sent", "quic:packet_received", "quic:packet_lost",
            "quic:stream_state_updated", "quic:recovery_metrics_updated",
            "quic:congestion_state_updated",
        ]
        var times: [Double] = []
        for event in events {
            let name = try XCTUnwrap(event["name"] as? String)
            XCTAssertTrue(knownNames.contains(name), "unexpected event name \(name)")
            XCTAssertNotNil(event["data"] as? [String: Any], "\(name) has no data object")
            times.append(try XCTUnwrap(event["time"] as? Double))
        }
        XCTAssertEqual(times, times.sorted(), "events are not in time order")
        XCTAssertGreaterThan(try XCTUnwrap(times.last), 0, "event times should come from the real clock")

        func eventData(named name: String) -> [[String: Any]] {
            events.compactMap { $0["name"] as? String == name ? $0["data"] as? [String: Any] : nil }
        }

        // Both endpoints' parameters are logged, each with the required initiator.
        let initiators = Set(eventData(named: "quic:parameters_set").compactMap { $0["initiator"] as? String })
        XCTAssertEqual(initiators, ["local", "remote"])

        // Packet events: draft header, raw lengths, and no fields outside the draft.
        let sent = eventData(named: "quic:packet_sent")
        let received = eventData(named: "quic:packet_received")
        XCTAssertFalse(sent.isEmpty)
        XCTAssertFalse(received.isEmpty)
        for packet in sent + received {
            let header = try XCTUnwrap(packet["header"] as? [String: Any])
            XCTAssertNotNil(header["packet_type"] as? String)
            XCTAssertEqual(header["version"] as? String, "00000001")
            XCTAssertNotNil(header["packet_number"] as? Int, "packet_number should be a number")
            XCTAssertNil(header["packet_size"])
            XCTAssertGreaterThan(try XCTUnwrap((packet["raw"] as? [String: Any])?["length"] as? Int), 0)
            XCTAssertNil(packet["is_coalesced"])
            XCTAssertNotEqual(packet["trigger"] as? String, "unknown")
        }

        // Metrics report fractional-millisecond RTTs and a congestion window.
        let metrics = eventData(named: "quic:recovery_metrics_updated")
        XCTAssertTrue(metrics.contains { $0["congestion_window"] != nil })
        XCTAssertTrue(metrics.contains { $0["smoothed_rtt"] as? Double != nil })

        // Stream frames: each of the four client-initiated bidirectional streams (IDs 0, 4, 8, 12)
        // carries the full 40,000 bytes in both directions. The end of the data is the largest
        // offset plus length, which holds even if some of it was retransmitted.
        func streamEnds(_ packets: [[String: Any]]) -> [UInt64: Int] {
            var ends: [UInt64: Int] = [:]
            for packet in packets {
                for frame in packet["frames"] as? [[String: Any]] ?? []
                where frame["frame_type"] as? String == "stream" {
                    guard let streamID = frame["stream_id"] as? UInt64,
                        let length = (frame["raw"] as? [String: Any])?["length"] as? Int
                    else {
                        XCTFail("malformed stream frame \(frame)")
                        continue
                    }
                    let offset = frame["offset"] as? Int ?? 0
                    ends[streamID] = max(ends[streamID] ?? 0, offset + length)
                }
            }
            return ends
        }
        let expectedEnds = Dictionary(uniqueKeysWithValues: (0..<streamCount).map { (UInt64($0 * 4), bytesPerStream) })
        XCTAssertEqual(streamEnds(sent), expectedEnds, "client stream data sent")
        XCTAssertEqual(streamEnds(received), expectedEnds, "echoed stream data received")
    }

    func testQUICWriteServerQlogFileOnDataTransfer() throws {
        let dataBlock: [UInt8] = Array("Hello World!".utf8)
        let title = "ServerQLog"
        let description = "ServerQLogDescription"
        // NOTE: Test using a trailing slash at the end of the path name
        let directory = try makeQlogDirectory()
        defer { removeQlogDirectory(directory) }
        let path = directory + "/"
        let harness = QUICTestHarness(realTime: #function)

        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { connectionOptions in
            connectionOptions.qlogConfiguration = QLogConfiguration(
                logTitle: title,
                logDescription: description,
                logPath: path
            )
        }

        harness.runQUICTest(dataBlock: dataBlock, serverOptions: serverOptions)

        // Validate the qlog file is present (based on how it creates the file)
        let finalPath = path + "qlog_server_\(title)_C1.qlog"

        // The close queues the qlog write on the context; `flush` returns once it has run.
        harness.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalPath), "qlog file was not written")

        let resultData = FileManager.default.contents(atPath: finalPath)
        guard let resultData else {
            XCTFail("Unable to read contents of file \(finalPath)")
            return
        }
        XCTAssertNotNil(resultData)
    }

    // When the peer sends CONNECTION_CLOSE, the connection arms a draining timer and only writes its
    // qlog once that timer fires. If the connection is torn down (and its event manager
    // unregistered) while the timer is still pending, the timer must still be able to write the
    // qlog rather than scheduling work against an identifier that has already been reset.
    func testQUICWriteServerQlogFileAfterTeardownWhileDraining() throws {
        let title = "ServerDrainingQLog"
        let directory = try makeQlogDirectory()
        defer { removeQlogDirectory(directory) }
        let finalPath = directory + "/qlog_server_\(title)_C1.qlog"
        let harness = QUICTestHarness(realTime: #function)

        let serverOptions = QUICProtocol.options()
        serverOptions.modifyConnectionOptions { connectionOptions in
            connectionOptions.qlogConfiguration = QLogConfiguration(
                logTitle: title,
                logDescription: "ServerDrainingQLogDescription",
                logPath: directory
            )
        }

        // The client closes the connection with a transport error, which puts the server into
        // draining. The harness then tears down both sides, which unregisters the server's
        // connection before its draining timer has fired.
        harness.runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            applicationError: 10,  // PROTOCOL_VIOLATION
            applicationErrorReason: "Close to start draining",
            serverOptions: serverOptions
        )

        // The qlog is only written by the draining timer, so wait for it to fire.
        harness.wait(
            until: { FileManager.default.fileExists(atPath: finalPath) },
            timeout: 5.0,
            "the draining timer to write the qlog"
        )

        XCTAssertNotNil(FileManager.default.contents(atPath: finalPath), "Unable to read contents of \(finalPath)")
    }

    // MARK: - Helpers

    /// A directory of this run's own, so that a file an earlier run left behind cannot satisfy the
    /// existence checks these tests make.
    ///
    /// Removing the file afterwards is not enough by itself. A crash or a test timeout kills the
    /// process before any cleanup runs, an early return can skip it, and two runs on one machine
    /// would otherwise write the same path.
    private func makeQlogDirectory() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    /// Removes `directory` and whatever was written into it.
    private func removeQlogDirectory(_ directory: String) {
        do {
            try FileManager.default.removeItem(atPath: directory)
        } catch {
            Logger.test.info("Could not remove \(directory): \(error)")
        }
    }
}

#endif
#endif
