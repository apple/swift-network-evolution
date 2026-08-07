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

#if !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) import Network
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
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

#if canImport(Dispatch)
import Dispatch
#endif

#if IMPORT_SWIFTTLS
#if canImport(SwiftTLS)
@available(Network 0.1.0, *)
final class SwiftNetworkQUICHarnessTests: NetTestCase {

    // MARK: Handshake tests

    func testQUICHandshake() {
        QUICTestHarness().runQUICTest()
    }

    #if canImport(Dispatch)
    func testQUICHandshakeConcurrent() {
        let context = NetworkContext(identifier: "concurrent")
        let queue = DispatchQueue(label: "concurrent queue", attributes: .concurrent)
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            queue.async {
                QUICTestHarness(context: context).runQUICTest(identifier: "Concurrent\(i)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: DispatchTime.now() + .seconds(5)), .success)
    }
    #endif

    func testQUICHandshakeWithShortPackets() {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.testSendingShortPackets = true
        QUICTestHarness().runQUICTest(clientOptions: clientOptions)
    }

    func testQUICHandshakeWithGiantALPNList() {
        var alpnList = ["network_test"]
        for i in 0..<100 {
            alpnList.append("network_test_\(i)")
        }

        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.applicationProtocols = alpnList
        clientOptions.tlsOptions = tlsOptions

        QUICTestHarness().runQUICTest(clientOptions: clientOptions)
    }

    func testQUICHandshakeWithBadALPNList() {
        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.applicationProtocols = ["bad_alpn"]
        clientOptions.tlsOptions = tlsOptions

        QUICTestHarness().runQUICTest(
            expectHandshakeError: .init(quicTransportError: QUICTransportError(Int64(0x0100), "TLS error")!),
            timeout: 10.0,
            clientOptions: clientOptions
        )
    }

    #if EXPORT_SWIFTTLS
    func testQUICHandshakeForceAES128() {
        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.tlsOptions.supportedCipherSuites = [.AES128GCM_SHA256]
        clientOptions.tlsOptions = tlsOptions

        let serverOptions = QUICProtocol.options()
        var serverTLSOptions = serverOptions.tlsOptions
        serverTLSOptions.tlsOptions.supportedCipherSuites = [.AES128GCM_SHA256]
        serverOptions.tlsOptions = serverTLSOptions

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions
        )
    }

    func testQUICHandshakeForceAES256() {
        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.tlsOptions.supportedCipherSuites = [.AES256GCM_SHA384]
        clientOptions.tlsOptions = tlsOptions

        let serverOptions = QUICProtocol.options()
        var serverTLSOptions = serverOptions.tlsOptions
        serverTLSOptions.tlsOptions.supportedCipherSuites = [.AES256GCM_SHA384]
        serverOptions.tlsOptions = serverTLSOptions

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions
        )
    }

    func testQUICHandshakeForceChaCha() {
        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.tlsOptions.supportedCipherSuites = [.chacha20Poly1305_SHA256]
        clientOptions.tlsOptions = tlsOptions

        let serverOptions = QUICProtocol.options()
        var serverTLSOptions = serverOptions.tlsOptions
        serverTLSOptions.tlsOptions.supportedCipherSuites = [.chacha20Poly1305_SHA256]
        serverOptions.tlsOptions = serverTLSOptions

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions
        )
    }

    func testQUICHandshakeNegotiateChaCha() {
        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.tlsOptions.supportedCipherSuites = [.chacha20Poly1305_SHA256]
        clientOptions.tlsOptions = tlsOptions

        let serverOptions = QUICProtocol.options()
        var serverTLSOptions = serverOptions.tlsOptions
        serverTLSOptions.tlsOptions.supportedCipherSuites = [.AES256GCM_SHA384, .chacha20Poly1305_SHA256]
        serverOptions.tlsOptions = serverTLSOptions

        QUICTestHarness().runQUICTest(
            clientOptions: clientOptions,
            serverOptions: serverOptions
        )
    }

    func testQUICHandshakeCiphersuiteMismatch() {
        let clientOptions = QUICProtocol.options()
        var tlsOptions = clientOptions.tlsOptions
        tlsOptions.tlsOptions.supportedCipherSuites = [.chacha20Poly1305_SHA256]
        clientOptions.tlsOptions = tlsOptions

        let serverOptions = QUICProtocol.options()
        var serverTLSOptions = serverOptions.tlsOptions
        serverTLSOptions.tlsOptions.supportedCipherSuites = [.AES256GCM_SHA384]
        serverOptions.tlsOptions = serverTLSOptions

        QUICTestHarness().runQUICTest(
            expectHandshakeError: .init(quicTransportError: QUICTransportError(Int64(0x0100), "TLS error")!),
            clientOptions: clientOptions,
            serverOptions: serverOptions
        )
    }
    #endif

    func testQUICHandshakeWithSCIDLength() {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.sourceConnectionIDLength = 10
        QUICTestHarness().runQUICTest(clientOptions: clientOptions)
    }

    func testQUICHandshakeWithInitialServerSCID() {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialSourceConnectionID = QUICConnectionID(10)
        serverOptions.connectionOptions.initialStatelessResetToken = QUICStatelessResetToken()
        QUICTestHarness().runQUICTest(serverOptions: serverOptions)
    }

    func testQUICHandshakeWithManualServerCIDs() {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialSourceConnectionID = QUICConnectionID(10)
        serverOptions.connectionOptions.initialStatelessResetToken = QUICStatelessResetToken()
        serverOptions.connectionOptions.disableAutomaticNewConnectionIDs = true
        QUICTestHarness().runQUICTest(
            serverOptions: serverOptions,
            extraServerCIDs: [
                (QUICConnectionID(10), QUICStatelessResetToken()),
                (QUICConnectionID(10), QUICStatelessResetToken()),
                (QUICConnectionID(10), QUICStatelessResetToken()),
            ]
        )
    }

    func testQUICHandshakeWithDelay() {
        QUICTestHarness().runQUICTest(
            clientLinkDelay: .milliseconds(50),
            serverLinkDelay: .milliseconds(50)
        )
    }

    // MARK: Data transfer tests

    func testQUICEchoHelloWorld() {
        QUICTestHarness().runQUICTest(dataBlock: Array("Hello World!".utf8))
    }

    func testQUICEchoHelloWorldMultistream() {
        QUICTestHarness().runQUICTest(
            streamCount: 4,
            dataBlock: Array("Hello World!".utf8)
        )
    }

    func testQUICEchoHelloWorldMarkIdle() {
        QUICTestHarness().runQUICTest(
            dataBlock: Array("Hello World!".utf8),
            shouldMarkIdle: true
        )
    }

    func testQUICEchoHelloWorldMultistreamMarkIdle() {
        QUICTestHarness().runQUICTest(
            streamCount: 4,
            dataBlock: Array("Hello World!".utf8),
            shouldMarkIdle: true
        )
    }

    func testQUICEchoHelloWorldMultistreamWithMaxStreamsIncreasing() {
        // In this test the client should start with an initial max of 8 bidirectional streams.
        // We are telling the client to open 16 bidirectional streams and so the server should
        // detect that the client is about to hit the remote stream limit and provide a MAX_STREAMS
        // update to 16 streams so the client should be able finish opening all 16 streams.
        QUICTestHarness().runQUICTest(
            streamCount: 16,
            dataBlock: Array("Hello World!".utf8),
            sendMaxStreamUpdate: true
        )
    }

    func testQUICEchoHelloWorldMultistreamWithPendingStreams() {
        // In this test the client should start with an initial max streams of 8.
        // The client will open 8 streams and then open 1 more stream and have it go into pending because the client has reached its local max.
        // Send a MAX_STREAMS frame from the server to raise the client's stream limit and start the pending stream.
        // The pending stream should then go into ready and send / receive data.
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialMaxStreamsBidirectional = 8
        QUICTestHarness().runQUICServerTestForPendingBidirectional(
            dataBlock: Array("Hello World!".utf8),
            serverOptions: serverOptions
        )
    }

    func testQUIC50BidirectionalStreams() {
        // Server advertises that the client can open 50 bidirectional streams
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialMaxStreamsBidirectional = 50
        QUICTestHarness().runQUICTest(
            streamCount: 50,
            dataBlock: Array("Hello World!".utf8),
            serverOptions: serverOptions
        )
    }

    func testQUIC1000BidirectionalStreamsEcho1k() {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialMaxStreamsBidirectional = 1000
        QUICTestHarness().runQUICTest(
            streamCount: 1000,
            blockSize: 1000,
            blockCount: 1,
            serverOptions: serverOptions
        )
    }

    func testQUICConnectionCloseError() {
        QUICTestHarness().runQUICTest(
            streamCount: 2,
            dataBlock: Array("Hello World!".utf8),
            applicationError: 10,  // PROTOCOL_VIOLATION
            applicationErrorReason: "QUIC Error thrown from test"
        )
    }

    func testQUICApplicationCloseError() {
        QUICTestHarness().runQUICTest(
            streamCount: 2,
            dataBlock: Array("Hello World!".utf8),
            applicationError: 102,  // Application specific error code (Not a code from ConnectionCloseError)
            applicationErrorReason: "Application error reason to test",
            sendApplicationCloseError: true
        )
    }

    func testQUICApplicationCloseErrorWithOverlappingCode() {
        QUICTestHarness().runQUICTest(
            streamCount: 2,
            dataBlock: Array("Hello World!".utf8),
            // Application specific error code (SHOULD *NOT* map to a code from ConnectionCloseError)
            applicationError: 8,
            applicationErrorReason: "Application error reason to test",
            sendApplicationCloseError: true
        )
    }

    func testQUICStreamResetError() {
        QUICTestHarness().runQUICTest(
            streamCount: 2,
            dataBlock: Array("Hello World!".utf8),
            sendFIN: false,  // Don't send a FIN, to allow the stream to reset
            applicationError: 10,  // Application error code
            sendStreamResetError: true
        )
    }

    func testQUICStreamStopSendingError() {
        QUICTestHarness().runQUICTest(
            streamCount: 2,
            dataBlock: Array("Hello World!".utf8),
            sendFIN: false,  // Don't send a FIN, to allow the stream to have stop-sending
            applicationError: 102,  // Application error code
            sendStreamStopSendingError: true
        )
    }

    func testQUICNewStreamRaceWithResetStream() {
        QUICTestHarness().runQUICNewStreamWithImmediateAbort(abortKind: .reset)
    }

    func testQUICNewStreamRaceWithStopSending() {
        QUICTestHarness().runQUICNewStreamWithImmediateAbort(abortKind: .stopSending)
    }

    func testQUICResetStreamFirstFrameOnNewStream() {
        QUICTestHarness().runQUICResetStreamFirstFrameOnNewStream()
    }

    func testQUICEmptyFinCleanCloseSendsFinNotReset() {
        QUICTestHarness().runEmptyFinCleanCloseSendsFinNotReset()
    }

    func testQUICResetStreamDoesNotAffectOppositeDirection() {
        QUICTestHarness().runQUICTest(
            streamCount: 1,
            dataBlock: Array("Hello World!".utf8),
            sendFIN: false,
            applicationError: 42,
            sendStreamResetError: true,
            verifyResetStreamHalfClosure: true
        )
    }

    func testQUICEcho40KiB() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4)
    }

    func testQUICEcho40KiBBatched() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, shouldBatchSends: true)
    }

    func testQUICEcho40KiBSmallReads() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, clientReadChunkSize: 1000)
    }

    func testQUICEcho40KiBWithDelay() {
        QUICTestHarness().runQUICTest(
            blockSize: 10240,
            blockCount: 4,
            clientLinkDelay: .milliseconds(50),
            serverLinkDelay: .milliseconds(50)
        )
    }

    func testQUICEcho40KiBNoPMTUD() {
        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.pmtud = false

        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.pmtud = false

        QUICTestHarness().runQUICTest(
            blockSize: 10240,
            blockCount: 4,
            clientOptions: clientOptions,
            serverOptions: serverOptions
        )
    }

    func testQUICEcho40KiBMultistream() {
        QUICTestHarness().runQUICTest(streamCount: 4, blockSize: 10240, blockCount: 4)
    }

    func testQUICEcho40KiBMultistreamWithMetrics() {
        QUICTestHarness().runQUICTest(
            streamCount: 8,
            blockSize: 10240,
            blockCount: 8,
            validateMetrics: true
        )
    }

    func testQUIC13AutomaticStreams() {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialMaxStreamsBidirectional = 5
        serverOptions.connectionOptions.maximumConcurrentBidirectionalStreams = 5
        QUICTestHarness().runQUICTest(
            streamCount: 13,
            blockSize: 10240,
            blockCount: 4,
            serverOptions: serverOptions
        )
    }

    func testQUIC100AutomaticStreams() {
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialMaxStreamsBidirectional = 8
        serverOptions.connectionOptions.maximumConcurrentBidirectionalStreams = 8
        QUICTestHarness().runQUICTest(
            streamCount: 100,
            blockSize: 10240,
            blockCount: 4,
            serverOptions: serverOptions
        )
    }

    func testQUICEcho100KiB() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 10)
    }

    // 1MiB == 1,048,576, this is 1,024,000
    func testQUICEcho1MiB() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 100)
    }

    #if !NETWORK_PRIVATE
    // Note: These tests takes too long to in for automation
    // Changed to 30 seconds to give it leeway to run locally
    // This passes "swift test" built default, ie. non-release, after ~9sec
    // Built release "swift test -c release" it passes in ~0.15sec
    func testQUICEcho10MiB() {
        // This is big enough to hit MAX_STREAM_DATA limits/Congestion
        QUICTestHarness().runQUICTest(blockSize: 10_240, blockCount: 1024, timeout: 30.0)
    }

    #if !DEBUG
    // These tests are big enough to hit MAX_DATA limits/Congestion

    // Built release "swift test -c release" it passes in ~0.3sec
    func testQUICEcho20MiB() throws {
        try XCTSkipIf(true)
        QUICTestHarness().runQUICTest(blockSize: 10_240, blockCount: 2 * 1024, timeout: 1000.0)
    }

    // Built release "swift test -c release" it passes in ~1.5sec
    func testQUICEcho100MiB() throws {
        try XCTSkipIf(true)
        QUICTestHarness().runQUICTest(blockSize: 10_240, blockCount: 10_240, timeout: 2000.0)
    }

    // Built release "swift test -c release" it passes in ~15sec
    func testQUICEcho1GiB() throws {
        try XCTSkipIf(true)
        QUICTestHarness().runQUICTest(blockSize: 10_240, blockCount: 100 * 1_024, timeout: 20000.0)
    }
    #endif
    #endif

    // MARK: Loss tests

    func testQUICDrop1ClientPacket() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, clientDrops: .init(10))
    }

    func testQUICDrop1ServerPacket() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, serverDrops: .init(10))
    }

    func testQUICDrop2ClientPackets() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, clientDrops: .init(20...21))
    }

    func testQUICDrop2ServerPackets() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, serverDrops: .init(20...21))
    }

    func testQUICDrop10ClientPackets() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, clientDrops: .init(20...29))
    }

    func testQUICDrop10ServerPackets() {
        QUICTestHarness().runQUICTest(blockSize: 10240, blockCount: 4, serverDrops: .init(20...29))
    }

    func testQUICDropClientInitial() {
        QUICTestHarness().runQUICTest(blockSize: 1000, blockCount: 4, clientDrops: .init(0))
    }

    func testQUICDropServerInitial() {
        QUICTestHarness().runQUICTest(blockSize: 1000, blockCount: 4, serverDrops: .init(0))
    }

    func testQUICDropBothInitials() {
        QUICTestHarness().runQUICTest(
            blockSize: 5000,
            blockCount: 1,
            clientDrops: .init([0...1, 6...6]),
            serverDrops: .init([0...0])
        )
    }

    func testQUICDropServerHandshake() {
        QUICTestHarness().runQUICTest(blockSize: 1000, blockCount: 4, serverDrops: .init(1))
    }

    func testQUICDropServerInitialAndHandshake() {
        QUICTestHarness().runQUICTest(blockSize: 1000, blockCount: 4, serverDrops: .init([0...0, 3...3]))
    }

    func testQUICDropScenario1() {
        QUICTestHarness().runQUICTest(
            blockSize: 5000,
            blockCount: 1,
            clientDrops: .init([0...1]),
            serverDrops: .init([0...0, 2...3]),
            timeout: 10
        )
    }

    func testQUICDropScenario2() {
        QUICTestHarness().runQUICTest(
            blockSize: 5000,
            blockCount: 1,
            clientDrops: .init([3...3, 6...6]),
            serverDrops: .init([0...0, 2...2, 6...6]),
            timeout: 10
        )
    }

    func testQUICDropScenario3() {
        QUICTestHarness().runQUICTest(
            blockSize: 5000,
            blockCount: 1,
            clientLinkDelay: .milliseconds(10),
            serverLinkDelay: .milliseconds(10),
            clientDrops: .init([1...7]),
            serverDrops: .init([1...9]),
            timeout: 15
        )
    }

    #if !os(Linux)
    func testQUICSevereDrops() throws {
        // Induce severe drops (100 in each direction) to heavily exercise recovery
        // The patterns of drops were generated randomly, but shown to hit pathological cases.
        // They are statically included here to ensure that behavior is hit consistently.
        let streamCount = 4
        let blockSize = 10240
        let blockCount = 100
        let clientDrops = DatagramDrops([
            35...39, 185...189,
            357...361, 413...417,
            446...450, 843...847,
            1002...1006, 1458...1462,
            1537...1541, 1578...1582,
            1858...1862, 1986...1990,
            2041...2045, 2205...2209,
            2236...2240, 2252...2256,
            2297...2301, 2446...2450,
            2855...2859, 2893...2897,
            2950...2954, 2953...2957,
            2955...2959, 3121...3125,
            3478...3482, 3567...3571,
            3584...3588, 3704...3708,
            3892...3896, 3912...3916,
        ])
        let serverDrops = DatagramDrops([
            90...94, 137...141,
            295...299, 536...540,
            738...742, 953...957,
            1143...1147, 1314...1318,
            1462...1466, 1536...1540,
            1539...1543, 1617...1621,
            1716...1720, 1841...1845,
            1912...1916, 1970...1974,
            2076...2080, 2393...2397,
            2573...2577, 2900...2904,
            3001...3005, 3099...3103,
            3165...3169, 3213...3217,
            3310...3314, 3311...3315,
            3367...3371, 3522...3526,
            3563...3567, 3594...3598,
        ])

        QUICTestHarness().runQUICTest(
            streamCount: streamCount,
            blockSize: blockSize,
            blockCount: blockCount,
            clientDrops: clientDrops,
            serverDrops: serverDrops,
            timeout: 20
        )
    }
    #endif

    func testQUICBlockClientPacketGeneration() {
        var clientDrops = DatagramDrops(10)
        clientDrops.blockPacketGeneration = true
        QUICTestHarness().runQUICTest(blockSize: 500000, blockCount: 1, clientDrops: clientDrops)
    }

    // MARK: Datagram tests

    func testQUICDatagramHelloWorld() {
        QUICTestHarness().runQUICTest(datagram: true, dataBlock: Array("Hello World!".utf8))
    }

    func testQUICDatagram1() {
        QUICTestHarness().runQUICTest(datagram: true, blockSize: 1000, blockCount: 1)
    }

    func testQUICDatagram10() {
        QUICTestHarness().runQUICTest(datagram: true, blockSize: 1000, blockCount: 10)
    }

    func testQUICDatagramRemoteMaxDatagramFrameSize() {
        QUICTestHarness().runQUICTest(
            datagram: true,
            blockSize: 1000,
            blockCount: 1,
            afterData: { harness in
                let expectation = XCTestExpectation(description: "Wait for remote datagram frame size to be fetched")
                harness.context.async {
                    let clientMetadata: ProtocolMetadata<QUICProtocol>? = harness.state?.clientHarness.getMetadata()
                    XCTAssertNotNil(clientMetadata)
                    if let clientMetadata {
                        let clientRemoteSize = clientMetadata.connectionMetadata?.remoteMaxDatagramFrameSize
                        XCTAssertNotNil(clientRemoteSize)
                        XCTAssertEqual(clientRemoteSize, 65535)
                    }
                    let serverMetadata: ProtocolMetadata<QUICProtocol>? = harness.state?.serverHarness.getMetadata()
                    XCTAssertNotNil(serverMetadata)
                    if let serverMetadata {
                        let serverRemoteSize = serverMetadata.connectionMetadata?.remoteMaxDatagramFrameSize
                        XCTAssertNotNil(serverRemoteSize)
                        XCTAssertEqual(serverRemoteSize, 65535)
                    }
                    expectation.fulfill()
                }
                let waitResult = XCTWaiter.wait(for: [expectation], timeout: 2.0)
                XCTAssertEqual(waitResult, .completed, "Remote datagram frame size fetch should complete")
            }
        )
    }

    // MARK: Unidirectional tests

    func testQUICHelloWorldUnidirectional() {
        QUICTestHarness().runQUICServerTestWithUnidirectionalStreams(
            streamCount: 4,
            dataBlock: Array("Hello World!".utf8),
            streamIDsToValidate: [2, 6, 10, 14]
        )
    }

    func testQUICHelloWorldUnidirectionalWithMaxStreamsUpdate() {
        // In this test the client should start with an initial max of 8 unidirectional streams.
        // We are telling the client to open 16 unidirectional streams so the server should
        // detect this and provide a MAX_STREAMS update to 16 and the client should be able to finish.
        QUICTestHarness().runQUICServerTestWithUnidirectionalStreams(
            streamCount: 16,
            dataBlock: Array("Hello World!".utf8),
            sendMaxStreamUpdate: true
        )
    }

    func testQUICHelloWorldUnidirectional50() {
        // Server advertises that the client can open 50 unidirectional streams
        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.initialMaxStreamsUnidirectional = 50
        QUICTestHarness().runQUICServerTestWithUnidirectionalStreams(
            streamCount: 50,
            dataBlock: Array("Hello World!".utf8),
            serverOptions: serverOptions
        )
    }

    func testQUICHelloWorldUnidirectionalServerInitiated() {
        // Make sure that the server is able to initiate a outbound unidirectional stream to the client
        QUICTestHarness().runQUICServerInitiatedUnidirectionalStreams(
            streamCount: 2,
            dataBlock: Array("Hello World!".utf8),
            streamIDsToValidate: [3, 7]
        )
    }

    func testQUICHelloWorldUnidirectionalServerInitiated50() {
        // Make sure that the server is able to initiate 50 outbound unidirectional stream to the client
        // Server advertises that the client can open 50 unidirectional streams
        let clientOptions = QUICProtocol.options()
        // Set to 51 because the test starts creating streams at index 0 (not 1 like the other tests)
        clientOptions.connectionOptions.initialMaxStreamsUnidirectional = 51
        QUICTestHarness().runQUICServerInitiatedUnidirectionalStreams(
            streamCount: 50,
            dataBlock: Array("Hello World!".utf8),
            clientOptions: clientOptions
        )
    }

    func testQUICClientUnidirectionalAndBidirectionalStreams() {
        // This test opens unidirectional and bidirectional streams on the same connection, similar to how HTTP3 would.
        QUICTestHarness().runQUICTestUnidirectionalAndBidirectionalStreams(
            streamCount: 4,
            dataBlock: Array("Hello World!".utf8)
        )
    }
}
#endif
#endif
#endif
