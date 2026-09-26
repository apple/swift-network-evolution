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

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

@available(Network 0.1.0, *)
final class QUICConnectionTests: XCTestCase {
    var connection: QUICConnection!
    override func setUp() {
        connection = QUICConnection(context: NetworkContext.implicitContext)
    }

    override func tearDown() {
        // The connection was built directly rather than attached to a stack, so nothing else
        // hands its event state back.
        connection.context.onQueue { self.connection.destroyFromExternalTest() }
        connection = nil
    }

    /// A call nested inside a pinned scope must leave the outer readings in place; otherwise the
    /// pin is gone when the nested call returns, `getSendTime` reads the two clocks separately,
    /// and `Pacer` derives the offset between the clock domains from a mismatched pair.
    func testANestedCallLeavesTheOuterReadingsInPlace() {
        connection.context.onQueue {
            self.connection.withPinnedClock {
                let readingsAtEntry = self.connection.pinnedClock
                XCTAssertNotNil(readingsAtEntry)

                self.connection.fromExternal { eventContext in
                    self.connection.serviceReceivedDatagrams(path: 0, in: &eventContext)
                }

                XCTAssertEqual(self.connection.pinnedClock?.continuous, readingsAtEntry?.continuous)
                XCTAssertEqual(self.connection.pinnedClock?.absolute, readingsAtEntry?.absolute)
            }

            XCTAssertNil(self.connection.pinnedClock)
        }
    }

    /// The outermost call releases the pin on the way out; otherwise the connection answers every
    /// later read with the same instant for the rest of its life.
    func testTheOutermostCallReleasesThePin() {
        connection.context.onQueue {
            self.connection.fromExternal { eventContext in
                self.connection.serviceReceivedDatagrams(path: 0, in: &eventContext)
            }

            XCTAssertNil(self.connection.pinnedClock)
        }
    }

    func testCreateInboundStreams() throws {
        self.connection.context.onQueue {
            let zeroStreamID: QUICStreamID = QUICStreamID(0)
            NetworkContext.implicitContext.async {
                self.connection.fromExternal { eventContext in
                    let _ = self.connection.createInboundStreams(
                        streamID: zeroStreamID,
                        in: &eventContext
                    )
                }
            }
        }
    }

    func testParseInboundPacket() {
        typealias TestVector = (
            input: [UInt8], version: UInt32?, expectedDCID: QUICConnectionID?,
            expectedSCID: QUICConnectionID?, expectedRetryToken: [UInt8]?, description: String
        )
        // 8 byte dcid
        let scidData: [UInt8] = [
            0x92, 0x0a, 0xac, 0x45,
            0xd8, 0xf1, 0x01, 0xa3,
        ]
        let dcidData: [UInt8] = [
            0x91, 0x0b, 0xab, 0x41,
            0xd8, 0xf1, 0x01, 0xa2,
        ]
        let retryTokenShort: [UInt8] = [
            0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x72, 0x65, 0x74, 0x72,
            0x79, 0x20,
            0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64, 0x65, 0x20, 0x66, 0x6F, 0x72,
            0x20, 0x74,
            0x65, 0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20,
            0x69, 0x73,
            0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x72, 0x65, 0x74, 0x72,
            0x79, 0x20,
            0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64, 0x65, 0x20, 0x66, 0x6F, 0x72,
            0x20, 0x74,
            0x65, 0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20,
            0x69, 0x73,
        ]
        let retryTokenLong: [UInt8] = [
            0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x72, 0x65, 0x74, 0x72,
            0x79, 0x20,
            0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64, 0x65, 0x20, 0x66, 0x6F, 0x72,
            0x20, 0x74,
            0x65, 0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20,
            0x69, 0x73,
            0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x72, 0x65, 0x74, 0x72,
            0x79, 0x20,
            0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64, 0x65, 0x20, 0x66, 0x6F, 0x72,
            0x20, 0x74,
            0x65, 0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20,
            0x69, 0x73,
            0x68, 0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61, 0x20, 0x72, 0x65, 0x74, 0x72,
            0x79, 0x20,
            0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64, 0x65, 0x20, 0x66, 0x6F, 0x72,
            0x20, 0x74,
        ]
        var dcids: [QUICConnectionID] = []
        var scids: [QUICConnectionID] = []
        for i in 1...8 {
            // incoming dcids are the connection's scid
            dcids.append(.init(scidData, size: i)!)
            scids.append(.init(dcidData, size: i)!)
        }

        let vectors: [TestVector] = [
            // short headers
            (
                [
                    0x60, 0x92, 0x0a, 0xac, 0x45, 0xd8, 0xf1, 0x01,
                    0xa3, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ],
                nil,
                dcids[7],
                nil,
                [],
                "Valid short header, 8b dcid"
            ),
            // long headers - contains version, DCID length, DCID, SCID length, SCID
            (
                [
                    0xc0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x92, 0x0a,
                    0xac, 0x45, 0xd8, 0xf1, 0x01, 0xa3, 0x08, 0x91,
                    0x0b, 0xab, 0x41, 0xd8, 0xf1, 0x01, 0xa2, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0xcd,
                ],
                UInt32(1),
                dcids[7],
                scids[7],
                [],
                "Valid long header, 8b dcid"
            ),
            // long header - retry packet - contains version, DCID length, DCID, SCID length, SCID, retry token, retry tag, padding
            (
                [
                    0xF0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x92, 0x0a,
                    0xac, 0x45, 0xd8, 0xf1, 0x01, 0xa3, 0x08, 0x91,
                    0x0b, 0xab, 0x41, 0xd8, 0xf1, 0x01, 0xa2, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x65,
                    0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72,
                    0x65, 0x20, 0x69, 0x73, 0x20, 0x69, 0x73, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x65,
                    0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72,
                    0x65, 0x20, 0x69, 0x73, 0x20, 0x69, 0x73, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x01,
                    0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x01,
                    0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                ],
                UInt32(1),
                dcids[7],
                scids[7],
                retryTokenLong,
                "Valid long header, 8b dcid"
            ),
            // long header - retry packet - contains version, DCID length, DCID, SCID length, SCID, retry token, retry tag, no padding
            (
                [
                    0xF0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x92, 0x0a,
                    0xac, 0x45, 0xd8, 0xf1, 0x01, 0xa3, 0x08, 0x91,
                    0x0b, 0xab, 0x41, 0xd8, 0xf1, 0x01, 0xa2, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x65,
                    0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72,
                    0x65, 0x20, 0x69, 0x73, 0x20, 0x69, 0x73, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x65,
                    0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72,
                    0x65, 0x20, 0x69, 0x73, 0x20, 0x69, 0x73, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x01,
                    0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x01,
                    0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04,
                ],
                UInt32(1),
                dcids[7],
                scids[7],
                retryTokenLong,
                "Valid long header, 8b dcid"
            ),
            // long header - retry packet - contains version, DCID length, DCID, SCID length, SCID, retry token short, retry tag, no padding
            (
                [
                    0xF0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x92, 0x0a,
                    0xac, 0x45, 0xd8, 0xf1, 0x01, 0xa3, 0x08, 0x91,
                    0x0b, 0xab, 0x41, 0xd8, 0xf1, 0x01, 0xa2, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x65,
                    0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72,
                    0x65, 0x20, 0x69, 0x73, 0x20, 0x69, 0x73, 0x68,
                    0x65, 0x72, 0x65, 0x20, 0x69, 0x73, 0x20, 0x61,
                    0x20, 0x72, 0x65, 0x74, 0x72, 0x79, 0x20, 0x74,
                    0x6F, 0x6B, 0x65, 0x6E, 0x20, 0x6D, 0x61, 0x64,
                    0x65, 0x20, 0x66, 0x6F, 0x72, 0x20, 0x74, 0x65,
                    0x73, 0x74, 0x69, 0x6E, 0x67, 0x68, 0x65, 0x72,
                    0x65, 0x20, 0x69, 0x73, 0x20, 0x69, 0x73, 0x01,
                    0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x01,
                    0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04,
                ],
                UInt32(1),
                dcids[7],
                scids[7],
                retryTokenShort,
                "Valid long header, 8b dcid"
            ),
            // failure modes
            (
                [
                    0xc0, 0x00, 0x00, 0x00, 0x01, 0x08, 0x92, 0x0a,
                    0xac, 0x45, 0xd8, 0xf1, 0x01, 0xa3, 0x00, 0x00,
                ],
                nil,
                nil,
                nil,
                nil,
                "long header, too short"
            ),
            ([] as [UInt8], nil, nil, nil, nil, "invalid quic packet"),
        ]

        for vector in vectors {
            var routingHeader: QUICRoutingHeader?
            let testData = vector.input
            testData.withUnsafeBufferPointer { bufferPointer in
                let rawBufferPointer = UnsafeRawBufferPointer(bufferPointer)
                routingHeader =
                    QUICConnectionUtilities
                    .parseInboundPacket(
                        rawBufferPointer,
                        shortHeaderDestinationCIDLength: vector.expectedDCID?.length ?? 0
                    )
            }
            XCTAssertTrue(
                vector.expectedDCID == routingHeader?.destinationConnectionID,
                "\(vector.description) (static api)"
            )
            XCTAssertTrue(
                vector.expectedSCID == routingHeader?.sourceConnectionID,
                "\(vector.description) (static api)"
            )
            XCTAssertTrue(
                vector.version == routingHeader?.version,
                "\(vector.description) (static api)"
            )
            XCTAssertTrue(
                vector.expectedRetryToken == routingHeader?.token,
                "\(vector.description) (static api)"
            )
        }
    }

    /// The parts of a stack that a handshake-completion test drives: a connection with a path and one
    /// pending stream, plus the harness above that stream.
    private struct AsynchronousHandshakeStack {
        let storage: TestNetworkProtocolStorage
        let connection: QUICConnection
        let harness: StreamUpperHarness<TestStreamLinkageFamily>
    }

    /// Builds a connection as it stands while a handshake is still in flight: a path to send on, and
    /// one stream that was opened early and so has no stream ID yet.
    ///
    /// The connection is a server, so the peer's transport parameters only have to carry the
    /// connection ID of the path they arrived on; a client would also check the original destination
    /// connection ID it generated, which it keeps to itself.
    private func makeAsynchronousHandshakeStack() -> AsynchronousHandshakeStack? {
        let storage = TestNetworkProtocolStorage(context: .implicitContext)
        let (streamListener, _, _) = storage.createTestQUICInstance()
        guard let connection = storage.quicInstance(for: streamListener.base) else {
            XCTFail("Failed to create a QUIC connection")
            return nil
        }

        var parameters = Parameters()
        let quicOptions = QUICStreamProtocol.options()
        quicOptions.setProtocolInstance(streamListener.identifier)
        parameters.defaultStack.prepend(applicationProtocol: .quic(quicOptions))
        parameters.isServer = true
        let path = PathProperties(parameters: parameters)
        let local = Endpoint(hostname: "10.0.0.1", port: 4433)
        let remote = Endpoint(hostname: "10.0.0.2", port: 1234)
        let peerConnectionID = QUICConnectionID([0xC1, 0xC2, 0xC3, 0xC4])!

        var upperHarness: StreamUpperHarness<TestStreamLinkageFamily>?
        let setUp = XCTestExpectation(description: "connection set up with a pending stream")
        connection.context.async {
            do {
                try connection.setup(remote: remote, local: local, parameters: parameters, path: path)
            } catch {
                XCTFail("Failed to set up the connection: \(error)")
            }
            // What `crypto.start` wires up, without starting a handshake: the events under test only
            // need the parent reference, but closing the connection tears the TLS linkage down, so
            // that has to be bound too.
            let crypto = connection.crypto
            crypto.parentConnection = connection
            var tlsParameters = Parameters()
            tlsParameters.isServer = true
            let tlsOptions = SwiftTLSProtocol.options()
            tlsOptions.setProtocolInstance(crypto.tlsInstance.identifier)
            // The TLS instance's own setup insists on the transport parameters it would carry into
            // the handshake, which is all it reads here.
            var tlsPerProtocolOptions = SwiftTLSProtocol.Options()
            tlsPerProtocolOptions.quicTransportParameters =
                (try? connection.localTransportParameters.serialize()) ?? []
            tlsOptions.perProtocolOptions = tlsPerProtocolOptions
            tlsParameters.defaultStack.append(applicationProtocol: .swiftTLS(tlsOptions))
            do {
                try crypto.invokeAttachLowerProtocol(
                    crypto.tlsInstance,
                    remote: nil,
                    local: nil,
                    parameters: tlsParameters,
                    path: nil
                )
            } catch {
                XCTFail("Failed to attach the TLS instance below crypto: \(error)")
            }

            let (lower, lowerLinkage) = storage.createDatagramLowerHarness(
                identifier: "Lower",
                context: .implicitContext
            )
            lower.fromExternal { eventContext in
                lower.connect(in: &eventContext)
            }
            var quicPath = QUICPath.makeFromExternalTest(parent: connection)
            quicPath.set(interface: nil, priority: 1, isInitial: true)
            quicPath.assignDCID(peerConnectionID)
            _ = try? quicPath.attachLowerProtocol(lowerLinkage.base)
            try? lowerLinkage.base.invokeAttachUpperProtocol(
                quicPath.asUpperLinkage(),
                remote: remote,
                local: local,
                parameters: parameters,
                path: path
            )
            connection.currentPath = quicPath
            connection.multiplexingPaths[quicPath.pathIdentifier] = quicPath

            // A stream opened while the handshake is in flight has no stream ID yet, so it is one
            // of the pending streams that completion has to ready.
            let (harness, harnessLinkage) = storage.createStreamUpperHarness(
                identifier: "Client",
                local: local,
                remote: remote,
                parameters: parameters,
                path: path,
                context: .implicitContext
            )
            upperHarness = harness
            do {
                try streamListener.invokeAttachUpperProtocolToNewFlow(
                    harnessLinkage,
                    remote: remote,
                    local: local,
                    parameters: parameters,
                    path: path
                )
            } catch {
                XCTFail("Failed to attach an upper harness to a new flow: \(error)")
            }

            // The peer's transport parameters arrive with its handshake data, so the connection
            // has them before verification finishes.
            var peerTransportParameters = TransportParameters(logPrefixer: LogPrefixer())
            peerTransportParameters.append(.initialSCID(connectionID: peerConnectionID))
            peerTransportParameters.append(.initialMaxStreamsBidirectional(value: 4))
            peerTransportParameters.append(.initialMaxStreamsUnidirectional(value: 4))
            peerTransportParameters.append(.initialMaxData(value: 1 << 20))
            peerTransportParameters.append(.initialMaxStreamDataBidirectionalLocal(value: 1 << 16))
            peerTransportParameters.append(.initialMaxStreamDataBidirectionalRemote(value: 1 << 16))
            peerTransportParameters.append(.initialMaxStreamDataUnidirectional(value: 1 << 16))
            connection.fromExternal { eventContext in
                connection.setRemoteTransportParameters(
                    peerTransportParameters,
                    earlyData: false,
                    in: &eventContext
                )
            }
            setUp.fulfill()
        }
        wait(for: [setUp], timeout: 5.0)
        guard let upperHarness else {
            XCTFail("Failed to build an upper harness")
            return nil
        }
        return .init(storage: storage, connection: connection, harness: upperHarness)
    }

    private func destroy(_ stack: AsynchronousHandshakeStack) {
        let connection = stack.connection
        connection.context.onQueue {
            // Strictly top down, and the harness goes first: detaching it takes the stream flow with
            // it, and a connection whose last upper protocol has gone tears itself down, paths and
            // all. That cascade is what breaks the cycle between a connection and its flows — a
            // connection torn down with flows still attached stays alive, because the closing side of
            // that only finishes once a peer answers and a test has no peer.
            stack.harness.teardown()
            if !connection.identifier.isNone {
                connection.destroyFromExternalTest()
            }
            connection.currentPath = nil
            for path in connection.multiplexingPaths.values where !path.identifier.isNone {
                path.destroyFromExternalTest()
            }
            connection.multiplexingPaths.removeAll()
            stack.storage.releaseHeldInstances()
        }
    }

    /// Runs `body` the way an asynchronous certificate verification completing does: on the TLS
    /// instance's event state, a turn of its own, with the connection's own state idle. Returns once
    /// the events that turn queued have been delivered.
    private func onAsynchronousHandshakeTurn(
        _ connection: QUICConnection,
        _ body: @escaping (QUICCrypto, inout NetworkContext.EventContext) -> Void
    ) {
        let finished = XCTestExpectation(description: "handshake turn delivered")
        connection.context.async {
            let crypto = connection.crypto
            crypto.tlsInstance.async { eventContext in
                body(crypto, &eventContext)
            }
            // What that turn queued is delivered as it unwinds, so wait for a turn after it.
            connection.context.async {
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5.0)
    }

    /// A handshake that finishes from an asynchronous certificate verification reports ready on a
    /// turn of its own: the continuation runs on the TLS instance's event state, and crypto reaches
    /// the connection through a direct reference rather than a linkage, so the connection's own
    /// state is idle. Readying the streams that were opened while the handshake was still in flight
    /// delivers `connected` up from each of them, which the connection can only do while it is in a
    /// call -- synchronous verification only gets that for free because it lands inside packet
    /// processing.
    func testPendingStreamReadiedWhenHandshakeCompletesAsynchronously() {
        guard let stack = makeAsynchronousHandshakeStack() else { return }
        defer { destroy(stack) }

        XCTAssertFalse(stack.harness.receivedConnected)

        onAsynchronousHandshakeTurn(stack.connection) { crypto, eventContext in
            crypto.handleConnectedEvent(in: &eventContext)
        }

        XCTAssertTrue(stack.harness.receivedConnected, "The pending stream never saw connected")
    }

    /// An asynchronous certificate verification that *rejects* the peer takes the same turn of its
    /// own, and closing the connection from there has to stay inside the event state that turn
    /// acquired: reaching for it a second time — which the external `async(_:)` entry point does —
    /// is an exclusivity violation, and the deferred close runs through exactly that path.
    func testConnectionClosesWhenAsynchronousCertificateVerificationRejects() {
        guard let stack = makeAsynchronousHandshakeStack() else { return }
        defer { destroy(stack) }

        XCTAssertFalse(stack.harness.receivedDisconnected)

        // Closing is deferred onto a further turn, so wait for the stream's event rather than for a
        // fixed number of turns.
        let disconnected = XCTestExpectation(description: "the rejected handshake reached the stream")
        stack.connection.context.onQueue {
            stack.harness.completions.disconnected = { disconnected.fulfill() }
        }

        onAsynchronousHandshakeTurn(stack.connection) { crypto, eventContext in
            crypto.handleDisconnectedEvent(error: .tls(.handshakeFailed), in: &eventContext)
        }
        wait(for: [disconnected], timeout: 5.0)

        XCTAssertTrue(
            stack.harness.receivedDisconnected,
            "The pending stream never saw the rejected handshake"
        )
        stack.connection.context.onQueue {
            XCTAssertNotNil(stack.connection.closeError, "The connection kept no close error")
            XCTAssertFalse(
                stack.connection.deferClosing,
                "The deferred close never ran, so the close was left half done"
            )
        }
    }
}

#endif
