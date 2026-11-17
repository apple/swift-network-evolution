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
import Synchronization
import XCTest

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
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

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
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

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)

@available(Network 0.1.0, *)
final class SwiftNetworkQUICPacketParsingTests: NetTestCase {

    func testMalformedInitial() throws {
        let harness = QUICTestHarness()

        // Attach a server-side QUIC stack to the bridge, mirroring the
        // server half of `QUICTestHarness.quicHandshake`, but never start
        // the client: the server connection stays in `.idle`, exactly as a
        // listening server is before any handshake.
        let server = try attachIdleServer(harness)
        defer {
            harness.onContext {
                server.harness.stop()
                server.harness.teardown()
                harness.storage.releaseHeldInstances()
            }
        }

        XCTAssertEqual(
            server.instance.state,
            .idle,
            "Server connection must still be idle before the injection"
        )

        // 21-byte Initial: long header (0x80) | fixed bit (0x40) | type 0.
        // Version 1, zero-length DCID and SCID, zero-length token,
        // 1-byte payload-length varint claiming the remaining 12 bytes.
        // headerLength == 9, so sampleRange == 13..<29 in a 21-byte buffer.
        var datagram: [UInt8] = [
            0xC0,  // long header | fixed bit | Initial
            0x00, 0x00, 0x00, 0x01,  // version 1
            0x00,  // DCID length
            0x00,  // SCID length
            0x00,  // token length (varint)
            0x0C,  // payload length (varint) — 12 remaining bytes
        ]
        datagram.append(contentsOf: [UInt8](repeating: 0x41, count: 12))
        XCTAssertEqual(datagram.count, Constants.minimumPacketSize)

        let receivedBefore = server.instance.stats.connectionStatistics[.rxPackets] ?? 0

        harness.onContext {
            BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                Frame(copyBuffer: datagram),
                to: harness.serverPort
            )
        }

        // Wait until the server has received the datagram; otherwise the assertion below holds
        // whether or not it saw it.
        harness.wait(
            until: { (server.instance.stats.connectionStatistics[.rxPackets] ?? 0) > receivedBefore },
            timeout: 5.0,
            "the server to receive the injected datagram"
        )

        // A malformed Initial must be discarded without closing the connection. At 21 bytes it is also
        // below the minimum datagram size for an Initial, so it is dropped before it is parsed.
        XCTAssertNil(server.instance.closeError)
        XCTAssertEqual(
            server.instance.state,
            .idle,
            "Server connection must survive a malformed Initial"
        )
    }

    // RFC 9000, Section 14.1: a server MUST discard an Initial packet carried in a datagram smaller than
    // 1200 bytes. It neither replies nor leaves the idle state.
    func testUndersizedInitialIsDropped() throws {
        try assertUndersizedInitialIsDropped(retry: false)
    }

    // A server that validates addresses does not answer a small datagram with a RETRY either.
    func testUndersizedInitialIsNotAnsweredWithRetry() throws {
        try assertUndersizedInitialIsDropped(retry: true)
    }

    private func assertUndersizedInitialIsDropped(retry: Bool) throws {
        let sentDatagrams = Mutex<[(firstByte: UInt8, size: Int)]>([])
        let harness = QUICTestHarness()
        let server = try attachIdleServer(harness, retry: retry) { firstByte, byteCount in
            sentDatagrams.withLock { $0.append((firstByte, byteCount)) }
        }
        defer {
            harness.onContext {
                server.harness.stop()
                server.harness.teardown()
                harness.storage.releaseHeldInstances()
            }
        }

        let receivedBefore = server.instance.stats.connectionStatistics[.rxPackets] ?? 0
        injectClientInitial(datagramSize: 300, harness)
        harness.wait(
            until: { (server.instance.stats.connectionStatistics[.rxPackets] ?? 0) > receivedBefore },
            timeout: 5.0,
            "the server to receive the injected datagram"
        )

        XCTAssertNil(server.instance.closeError)
        XCTAssertEqual(server.instance.state, .idle)
        XCTAssertTrue(sentDatagrams.withLock { $0.isEmpty }, "Expected no reply to a small datagram")
    }

    // The same Initial padded to the minimum datagram size is taken: the server does not close.
    func testMinimumSizeInitialDoesNotClose() throws {
        let harness = QUICTestHarness()
        let server = try attachIdleServer(harness)
        defer {
            harness.onContext {
                server.harness.stop()
                server.harness.teardown()
                harness.storage.releaseHeldInstances()
            }
        }

        let receivedBefore = server.instance.stats.connectionStatistics[.rxPackets] ?? 0
        injectClientInitial(datagramSize: Constants.minimumInitialDatagramSize, harness)
        harness.wait(
            until: { (server.instance.stats.connectionStatistics[.rxPackets] ?? 0) > receivedBefore },
            timeout: 5.0,
            "the server to receive the injected datagram"
        )

        XCTAssertNil(server.instance.closeError)
        XCTAssertEqual(server.instance.state, .initialProcessed)
    }

    // A small Initial that arrives once the handshake has started is dropped too, without closing: anyone
    // who saw the client's connection ID could derive the keys to inject one.
    func testUndersizedInitialAfterFirstIsDropped() throws {
        let harness = QUICTestHarness()
        let server = try attachIdleServer(harness)
        defer {
            harness.onContext {
                server.harness.stop()
                server.harness.teardown()
                harness.storage.releaseHeldInstances()
            }
        }

        let destinationConnectionID = QUICConnectionID(8)
        let sourceConnectionID = QUICConnectionID(8)
        for (packetNumber, datagramSize) in [(0, Constants.minimumInitialDatagramSize), (1, 300)] {
            let receivedBefore = server.instance.stats.connectionStatistics[.rxPackets] ?? 0
            injectClientInitial(
                datagramSize: datagramSize,
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                packetNumber: Int64(packetNumber),
                harness
            )
            harness.wait(
                until: { (server.instance.stats.connectionStatistics[.rxPackets] ?? 0) > receivedBefore },
                timeout: 5.0,
                "the server to receive the injected datagram of \(datagramSize) bytes"
            )
            XCTAssertNil(server.instance.closeError)
            XCTAssertEqual(server.instance.state, .initialProcessed)
        }
    }

    // RFC 9000, Section 5.2.2: a server MUST drop a small packet of an unsupported version rather than
    // answer it with a Version Negotiation packet.
    func testUndersizedInitialOfUnsupportedVersionIsDropped() throws {
        let sentDatagrams = Mutex<[(firstByte: UInt8, size: Int)]>([])
        let harness = QUICTestHarness()
        let server = try attachIdleServer(harness) { firstByte, byteCount in
            sentDatagrams.withLock { $0.append((firstByte, byteCount)) }
        }
        defer {
            harness.onContext {
                server.harness.stop()
                server.harness.teardown()
                harness.storage.releaseHeldInstances()
            }
        }

        let receivedBefore = server.instance.stats.connectionStatistics[.rxPackets] ?? 0
        injectClientInitial(datagramSize: 300, version: .negotiationPattern, harness)
        harness.wait(
            until: { (server.instance.stats.connectionStatistics[.rxPackets] ?? 0) > receivedBefore },
            timeout: 5.0,
            "the server to receive the injected datagram"
        )
        XCTAssertNil(server.instance.closeError)
        XCTAssertEqual(server.instance.state, .idle)
        XCTAssertTrue(sentDatagrams.withLock { $0.isEmpty }, "Expected no reply to a small datagram")

        // The same packet in a datagram of the minimum size is answered with a Version Negotiation packet.
        injectClientInitial(datagramSize: Constants.minimumInitialDatagramSize, version: .negotiationPattern, harness)
        harness.wait(
            until: { sentDatagrams.withLock { !$0.isEmpty } },
            timeout: 5.0,
            "the server to send a Version Negotiation packet"
        )
        XCTAssertEqual(sentDatagrams.withLock { $0.count }, 1)
        XCTAssertEqual(server.instance.state, .versionSent)
    }

    /// Delivers a client Initial of `datagramSize` bytes to the server, sealed with Initial keys so that
    /// it decrypts. It carries a PING padded to fill the datagram, so the server has nothing to process.
    private func injectClientInitial(
        datagramSize: Int,
        destinationConnectionID: QUICConnectionID = QUICConnectionID(8),
        sourceConnectionID: QUICConnectionID = QUICConnectionID(8),
        packetNumber: Int64 = 0,
        version: QUICVersion = .v1,
        _ harness: QUICTestHarness
    ) {
        harness.onContext {
            var protector = Protector(
                isClient: true,
                destinationCID: destinationConnectionID,
                logPrefixer: LogPrefixer("[SwiftNetworkQUICPacketParsingTests]")
            )
            let tagLength = protector.getTagSize(for: .initial)
            var packet = Packet(
                number: PacketNumber(packetNumber),
                lastAcked: .none,
                keyState: .initial,
                destinationConnectionID: destinationConnectionID,
                sourceConnectionID: sourceConnectionID,
                version: version
            )
            packet.tagLength = tagLength

            var frame = Frame(count: datagramSize)
            do throws(QUICError) {
                XCTAssertTrue(frame.claim(fromStart: 0, fromEnd: Int(tagLength)))
                let lengthBeforeHeader = frame.unclaimedLength
                var payloadLengthOffset: Int?
                var truncatedPacketNumberLength = 0
                try packet.writeHeader(
                    into: &frame,
                    lastAcked: .none,
                    token: [],
                    payloadLengthOffset: &payloadLengthOffset,
                    truncatedPacketNumberLength: &truncatedPacketNumberLength
                )
                // A PING, then PADDING to the end of the datagram.
                let body = [0x01] + [UInt8](repeating: 0x00, count: frame.unclaimedLength - 1)
                let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.buffer(body)
                }
                guard case .success = result, let payloadLengthOffset else {
                    XCTFail("Failed to write the Initial")
                    frame.finalize(success: false)
                    return
                }
                XCTAssertTrue(frame.unclaim(fromStart: lengthBeforeHeader, fromEnd: Int(tagLength)))
                packet.payloadLength = UInt16(datagramSize - Int(packet.headerLength))
                try packet.updateLongHeaderPayloadLength(frame: &frame, payloadLengthOffset: payloadLengthOffset)
                XCTAssertEqual(packet.totalLength, datagramSize)
                try protector.seal(&packet, frame: &frame)
            } catch {
                XCTFail("Failed to seal the Initial: \(error.info.description)")
                frame.finalize(success: false)
                return
            }
            BridgeDatagramProtocol.BridgeInstance.injectDatagram(frame, to: harness.serverPort)
        }
    }

    func testMalformedShortHeaderAfterHandshake() throws {
        let harness = QUICTestHarness()
        harness.runQUICTest(
            afterHandshake: { harness in
                let receivedBefore =
                    harness.state?.serverInstance.stats.connectionStatistics[.rxPackets] ?? 0

                harness.onContext {
                    guard let serverInstance = harness.state?.serverInstance else {
                        XCTFail("Server instance missing after handshake")
                        return
                    }

                    // The CID the peer uses to address the server. The
                    // initial SCID (inserted first) is the one the client
                    // keeps using absent migration.
                    guard
                        let serverCID = serverInstance.localCIDs.managedConnectionIDs.first?
                            .connectionID.connectionID
                    else {
                        XCTFail("Server has no local connection IDs")
                        return
                    }
                    XCTAssertEqual(
                        serverCID.count,
                        QUICConnectionID.defaultServerSCIDLength,
                        "Server local CID should have the default length (8)"
                    )

                    // 21-byte short header: fixed bit set, 5-bit spin/keys
                    // unused bits zero. headerLength == 1 + 8 == 9, so
                    // sampleRange == 13..<29 in a 21-byte buffer.
                    var datagram: [UInt8] = [0x40]
                    datagram.append(contentsOf: serverCID)
                    datagram.append(contentsOf: [UInt8](repeating: 0x42, count: 12))
                    XCTAssertEqual(datagram.count, Constants.minimumPacketSize)

                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        Frame(copyBuffer: datagram),
                        to: harness.serverPort
                    )
                }

                // Wait until the server has received the datagram; otherwise the assertion below holds
                // whether or not it saw it, because the server is already `.connected`.
                harness.wait(
                    until: {
                        (harness.state?.serverInstance.stats.connectionStatistics[.rxPackets] ?? 0)
                            > receivedBefore
                    },
                    timeout: 5.0,
                    "the server to receive the injected datagram"
                )

                XCTAssertEqual(
                    harness.state?.serverInstance.state,
                    .connected,
                    "Server connection must survive a truncated short-header datagram"
                )
            }
        )
    }

    func testMalformedShortHeaderInsufficientPacketNumberAndSampleBytes() throws {
        let harness = QUICTestHarness()
        harness.runQUICTest(
            afterHandshake: { harness in
                let receivedBefore =
                    harness.state?.serverInstance.stats.connectionStatistics[.rxPackets] ?? 0

                harness.onContext {
                    guard let serverInstance = harness.state?.serverInstance else {
                        XCTFail("Server instance missing after handshake")
                        return
                    }

                    // The CID the peer uses to address the server. The
                    // initial SCID (inserted first) is the one the client
                    // keeps using absent migration.
                    guard
                        let serverCID = serverInstance.localCIDs.managedConnectionIDs.first?
                            .connectionID.connectionID
                    else {
                        XCTFail("Server has no local connection IDs")
                        return
                    }
                    XCTAssertEqual(
                        serverCID.count,
                        QUICConnectionID.defaultServerSCIDLength,
                        "Server local CID should have the default length (8)"
                    )
                    // 25-byte short header: fixed bit set, headerLength ==
                    // 1 + 8 == 9, leaving 16 bytes of payload+tag. It clears the
                    // payloadAndTagSize check but falls short
                    // of the 4 byte packet number plus 16-byte header
                    // protection sample the parser needs before it can
                    // safely remove header protection.
                    var datagram: [UInt8] = [0x40]
                    datagram.append(contentsOf: serverCID)
                    datagram.append(contentsOf: [UInt8](repeating: 0x42, count: 16))
                    XCTAssertEqual(datagram.count, 25)

                    BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                        Frame(copyBuffer: datagram),
                        to: harness.serverPort
                    )
                }

                // Wait until the server has received the datagram; otherwise the assertion below holds
                // whether or not it saw it, because the server is already `.connected`.
                harness.wait(
                    until: {
                        (harness.state?.serverInstance.stats.connectionStatistics[.rxPackets] ?? 0)
                            > receivedBefore
                    },
                    timeout: 5.0,
                    "the server to receive the injected datagram"
                )

                XCTAssertEqual(
                    harness.state?.serverInstance.state,
                    .connected,
                    "Server connection must survive a short-header datagram with insufficient bytes for the packet number and sample"
                )
            }
        )
    }

    // MARK: - Malformed frames in authenticated packets

    private typealias TransportErrorCode = QUICTransportError.QUICTransportErrorCode

    // RFC 9000, Section 12.4: "An endpoint MUST treat the receipt of a frame of unknown type as a
    // connection error of type FRAME_ENCODING_ERROR."
    func testUnknownFrameTypeClosesWithFrameEncodingError() {
        runLocalCloseTest(payload: [0x21], expectedCode: .frameEncodingError)
    }

    func testUnknownTwoByteFrameTypeClosesWithFrameEncodingError() {
        runLocalCloseTest(payload: [0x7F, 0xFF], expectedCode: .frameEncodingError)
    }

    func testTruncatedFrameTypeClosesWithFrameEncodingError() {
        // PING, then a frame type whose 2-byte varint is cut off by the end of the packet.
        runLocalCloseTest(payload: [0x01, 0x40], expectedCode: .frameEncodingError)
    }

    func testStreamFrameLongerThanPacketClosesWithFrameEncodingError() {
        // STREAM with LEN: stream 0 claims 32 bytes, and carries 1.
        runLocalCloseTest(payload: [0x0A, 0x00, 0x20, 0xAA], expectedCode: .frameEncodingError)
    }

    func testCryptoFrameLongerThanPacketClosesWithFrameEncodingError() {
        // CRYPTO at offset 0 claims 32 bytes, and carries 1.
        runLocalCloseTest(payload: [0x06, 0x00, 0x20, 0xAA], expectedCode: .frameEncodingError)
    }

    // RFC 9000, Section 20.1 gives "an ACK frame that has more acknowledgment ranges than the
    // remainder of the packet could carry" as an example of FRAME_ENCODING_ERROR.
    func testAckWithMoreRangesThanPacketCanCarryClosesWithFrameEncodingError() {
        // Largest 0, delay 0, 16 additional ranges, and only the first range present.
        runLocalCloseTest(payload: [0x02, 0x00, 0x00, 0x10, 0x00], expectedCode: .frameEncodingError)
    }

    func testAckWithHugeRangeCountClosesWithFrameEncodingError() {
        // The range count is above the implementation limit, but it is the packet that cannot carry it.
        let rangeCount: [UInt8] = [0xC0, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        runLocalCloseTest(payload: [0x02, 0x00, 0x00] + rangeCount + [0x00], expectedCode: .frameEncodingError)
    }

    // RFC 9000, Section 19.15: a connection ID length outside 1...20 "MUST be treated as a connection
    // error of type FRAME_ENCODING_ERROR."
    func testNewConnectionIDWithZeroLengthClosesWithFrameEncodingError() {
        let payload: [UInt8] = [0x18, 0x01, 0x00, 0x00] + [UInt8](repeating: 0xBB, count: QUICStatelessResetToken.size)
        runLocalCloseTest(payload: payload, expectedCode: .frameEncodingError)
    }

    func testNewConnectionIDWithOverlongLengthClosesWithFrameEncodingError() {
        let payload: [UInt8] =
            [0x18, 0x01, 0x00, 21]
            + [UInt8](repeating: 0xAA, count: 21)
            + [UInt8](repeating: 0xBB, count: QUICStatelessResetToken.size)
        runLocalCloseTest(payload: payload, expectedCode: .frameEncodingError)
    }

    // RFC 9000, Section 19.7: "A client MUST treat receipt of a NEW_TOKEN frame with an empty Token
    // field as a connection error of type FRAME_ENCODING_ERROR."
    func testEmptyNewTokenClosesWithFrameEncodingError() {
        runLocalCloseTest(payload: [0x07, 0x00], fromClient: false, expectedCode: .frameEncodingError)
    }

    func testTruncatedConnectionCloseReasonClosesWithFrameEncodingError() {
        // The reason phrase claims 32 bytes, and has 1.
        runLocalCloseTest(payload: [0x1C, 0x0A, 0x00, 0x20, 0x61], expectedCode: .frameEncodingError)
    }

    // A close raised while parsing has the more specific error, and the parse failure that follows must
    // not replace it. RFC 9221, Section 3: a DATAGRAM frame over the advertised limit is a PROTOCOL_VIOLATION.
    func testOversizedDatagramKeepsProtocolViolation() {
        let serverOptions = QUICProtocol.options()
        serverOptions.modifyPerProtocolOptions { streamOptions in
            streamOptions.modifyQUICConnectionOptions { $0.maxDatagramFrameSize = 100 }
        }
        // DATAGRAM with length, and 200 bytes that all fit in the packet.
        let payload: [UInt8] = [0x31, 0x40, 0xC8] + [UInt8](repeating: 0xAA, count: 200)
        runLocalCloseTest(payload: payload, expectedCode: .protocolViolation, serverOptions: serverOptions)
    }

    /// Checks that `payload` makes its receiver close the connection with `expectedCode`, and that the
    /// close reaches the sender.
    private func runLocalCloseTest(
        payload: [UInt8],
        fromClient: Bool = true,
        expectedCode: TransportErrorCode,
        serverOptions: ProtocolOptions<QUICProtocol> = QUICProtocol.options(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            afterHandshake: { harness in
                let sender = fromClient ? harness.state?.clientInstance : harness.state?.serverInstance
                let receiver = fromClient ? harness.state?.serverInstance : harness.state?.clientInstance
                self.injectAuthenticatedPacket(payload: payload, fromClient: fromClient, harness)

                harness.wait(
                    until: { receiver?.closeError != nil },
                    timeout: 5.0,
                    "the receiver to close the connection"
                )
                XCTAssertEqual(receiver?.closeError?.code, expectedCode.rawValue, file: file, line: line)
                XCTAssertEqual(receiver?.receivedConnectionClose, false, file: file, line: line)

                harness.wait(
                    until: { sender?.receivedConnectionClose == true },
                    timeout: 5.0,
                    "the sender to receive the CONNECTION_CLOSE"
                )
                XCTAssertEqual(sender?.closeError?.code, expectedCode.rawValue, file: file, line: line)
            }
        )
    }

    /// Delivers `payload` to the other endpoint as a 1-RTT packet sealed with the sender's real keys, so
    /// that it authenticates and reaches frame parsing, which nothing the stack sends itself can.
    private func injectAuthenticatedPacket(payload: [UInt8], fromClient: Bool, _ harness: QUICTestHarness) {
        harness.onContext {
            guard
                let sender = fromClient ? harness.state?.clientInstance : harness.state?.serverInstance,
                let destinationConnectionID = sender.currentPath?.dcid
            else {
                XCTFail("Sender is missing after the handshake")
                return
            }
            let keyState = sender.keyState
            let lastAcked = sender.largestAckedPacketNumber(space: .applicationData)
            let tagLength = sender.protector.getTagSize(for: keyState)
            var packet = Packet(
                number: sender.protector.getPacketNumber(for: .applicationData),
                lastAcked: lastAcked,
                keyState: keyState,
                destinationConnectionID: destinationConnectionID
            )
            packet.tagLength = tagLength

            // Leading PADDING guarantees the bytes header protection samples, however short `payload` is.
            let body = [UInt8](repeating: 0x00, count: 4) + payload
            var frame = Frame(count: body.count + 64)
            let lengthBeforeHeader = frame.unclaimedLength
            do throws(QUICError) {
                var payloadLengthOffset: Int?
                var truncatedPacketNumberLength = 0
                try packet.writeHeader(
                    into: &frame,
                    lastAcked: lastAcked,
                    payloadLengthOffset: &payloadLengthOffset,
                    truncatedPacketNumberLength: &truncatedPacketNumberLength
                )
                let result = Serializer.serialize(&frame, claim: true) { write throws(SerializationError) in
                    try write.buffer(body)
                }
                guard case .success = result else {
                    XCTFail("Failed to write the payload")
                    frame.finalize(success: false)
                    return
                }
                let writtenLength = lengthBeforeHeader - frame.unclaimedLength
                XCTAssertTrue(frame.unclaim(fromStart: writtenLength))
                packet.payloadLength = UInt16(writtenLength + Int(tagLength) - Int(packet.headerLength))
                XCTAssertTrue(frame.claim(fromStart: 0, fromEnd: frame.unclaimedLength - packet.totalLength))
                try sender.protector.seal(&packet, frame: &frame)
            } catch {
                XCTFail("Failed to seal the packet: \(error.info.description)")
                frame.finalize(success: false)
                return
            }
            BridgeDatagramProtocol.BridgeInstance.injectDatagram(
                frame,
                to: fromClient ? harness.serverPort : harness.clientPort
            )
        }
    }

    // MARK: - Helpers

    private struct IdleServer {
        let instance: QUICConnection
        let harness: NewStreamFlowHarness<TestStreamLinkageFamily>
    }

    private func attachIdleServer(
        _ harness: QUICTestHarness,
        retry: Bool = false,
        observeFrameHandler: BridgeObserveFrameHandler = nil
    ) throws -> IdleServer {
        var result: IdleServer?

        harness.onContext {
            var serverParameters = Parameters(context: harness.context)
            serverParameters.isServer = true

            var (serverQUICStreamListener, _, serverQUICMultipath) = harness.storage.createTestQUICInstance()
            guard let serverInstance = harness.storage.quicInstance(for: serverQUICStreamListener.base) else {
                XCTFail("Failed to create the server QUIC instance")
                return
            }

            let serverOptions = QUICProtocol.options()
            harness.updateQUICOptions(serverOptions, server: true)
            if retry {
                serverOptions.modifyConnectionOptions { $0.retry = true }
            }
            serverOptions.setLogID(
                prefix: "L",
                parent: "1",
                protocolLogIDNumber: 1
            )
            serverOptions.setProtocolInstance(serverQUICStreamListener.identifier)
            serverParameters.defaultStack.transport = .quic(serverOptions)

            let serverBridge = harness.storage.createTestBridgeDatagramInstance()
            let serverBridgeOptions = BridgeDatagramProtocol.options()
            serverBridgeOptions.setProtocolInstance(serverBridge.identifier)
            serverBridgeOptions.observeFrameHandler = observeFrameHandler
            serverParameters.defaultStack.link = .custom(serverBridgeOptions)

            var serverPath = PathProperties(parameters: serverParameters)
            serverPath.effectiveMTU = 1500

            let (serverFlowHarness, serverHarnessLinkage) = harness.storage.createNewStreamFlowHarness(
                identifier: "Server",
                local: harness.serverEndpoint,
                remote: harness.clientEndpoint,
                parameters: serverParameters,
                path: serverPath,
                context: harness.context
            )

            do {
                // Attach from the upper linkage so both directions are bound.
                try serverHarnessLinkage.invokeAttachLowerProtocol(
                    serverQUICStreamListener,
                    remote: harness.clientEndpoint,
                    local: harness.serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach the server harness to QUIC: \(error)")
                return
            }

            do {
                try serverQUICMultipath.invokeAttachLowerProtocolForNewPath(
                    serverBridge,
                    remote: harness.clientEndpoint,
                    local: harness.serverEndpoint,
                    parameters: serverParameters,
                    path: serverPath
                )
            } catch {
                XCTFail("Failed to attach QUIC server to datagram bridge: \(error)")
                return
            }

            result = IdleServer(instance: serverInstance, harness: serverFlowHarness)

            // Begin listening, exactly as `quicHandshake` does before the
            // client sends anything. A server-side connect only activates
            // the receive path; it does not initiate a handshake, so the
            // connection stays in `.idle`.
            serverFlowHarness.start()

        }

        guard let result else {
            XCTFail("Failed to attach the idle server")
            struct AttachError: Error {}
            throw AttachError()
        }
        return result
    }
}
#endif
#endif
#endif
