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

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(Musl)
import Musl
internal import Logging
#elseif canImport(os)
internal import os
#endif

@available(Network 0.1.0, *)
final class SwiftNetworkDemuxTests: NetTestCase {

    // 10.0.0.20
    static let localIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x14]

    // 10.0.0.117
    static let remoteIPv4Address: [UInt8] = [0x0a, 0x00, 0x00, 0x75]

    struct DemuxPatternInput {
        let pattern: [UInt8]
        let offset: Int
        let mask: [UInt8]?

        init(pattern: [UInt8], offset: Int, mask: [UInt8]? = nil) {
            self.pattern = pattern
            self.offset = offset
            self.mask = mask
        }
    }

    // A default-flow fingerprint that is not shared with the test patterns below.
    static let defaultPayloadPrefix: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

    // Build a payload identifiable by (flowIndex, sequence). If `pattern` is provided,
    // the payload contains the pattern bytes at the requested offset so it will match.
    // When the pattern has a mask, bytes outside the mask are set to a per-sequence
    // varying value so that the test proves the receiver is actually applying the mask.
    static func makePayload(
        pattern: DemuxPatternInput?,
        flowIndex: Int,
        sequence: Int
    ) -> [UInt8] {
        // Precompute the bytes that will be written into the pattern region, so the
        // Serializer result-builder body below stays a straight-line composition.
        let patternRegionBytes: [UInt8]
        if let pattern, let mask = pattern.mask {
            let variantByte: UInt8 = 0xA5 &+ UInt8(sequence & 0xff)
            patternRegionBytes = zip(pattern.pattern, mask).map { byte, m in
                (byte & m) | (variantByte & ~m)
            }
        } else if let pattern {
            patternRegionBytes = pattern.pattern
        } else {
            patternRegionBytes = []
        }

        return Serializer.serialize { write in
            if let pattern {
                write.buffer([UInt8](repeating: 0, count: pattern.offset))
                write.buffer(patternRegionBytes)
            } else {
                write.buffer(Self.defaultPayloadPrefix)
            }
            write.uint8(UInt8(flowIndex & 0xff))
            write.uint8(UInt8(sequence & 0xff))
            write.uint8(0xA5)
            write.uint8(0x5A)
        }
    }

    // Wrap a payload in a UDP header for the given ports. Uses checksum=0 which the
    // receiver accepts because we set `ignoreInboundChecksum` on UDP options.
    static func makeUDPPacket(payload: [UInt8], sourcePort: UInt16, destPort: UInt16) -> [UInt8] {
        Serializer.serialize { write in
            write.uint16NetworkByteOrder(sourcePort)
            write.uint16NetworkByteOrder(destPort)
            write.uint16NetworkByteOrder(UInt16(payload.count + 8))
            write.uint16NetworkByteOrder(UInt16(0))
            write.buffer(payload)
        }
    }

    // Array of arrays of demux patterns; each inner array is one upper handler to be added
    func testDemux(
        demuxedFlows: [[DemuxPatternInput]],
        datagramsPerFlow: Int = 3
    ) {

        let context = NetworkContext.implicitContext

        let expectation = XCTestExpectation()

        context.async {
            defer { expectation.fulfill() }

            var parameters = Parameters()
            parameters.context = context

            let localEndpoint = Endpoint(address: IPv4Address(Self.localIPv4Address)!, port: 1234)
            let remoteEndpoint = Endpoint(address: IPv4Address(Self.remoteIPv4Address)!, port: 8080)

            let path = PathProperties(parameters: parameters)

            let udp = UDPProtocol.instance(context: context)
            let udpOptions = UDPProtocol.options()
            udpOptions.noMetadata = true
            // Accept the checksum=0 packets we inject on inbound so we don't need to compute one.
            udpOptions.ignoreInboundChecksum = true
            udpOptions.setLogID(prefix: "D", parent: "1", protocolLogIDNumber: 1)
            udpOptions.setProtocolInstance(udp)
            parameters.defaultStack.transport = .udp(udpOptions)

            let demux = DemuxProtocol.instance(context: context)

            let demuxLinkage = OutboundDatagramLinkage(reference: demux)

            let upperHarness = DatagramUpperHarness(
                identifier: "Default",
                local: localEndpoint,
                remote: remoteEndpoint,
                parameters: parameters,
                path: path,
                context: context,
                lowerProtocol: demuxLinkage
            )
            XCTAssertNotNil(upperHarness, "Failed to attach default upper harness")
            guard let upperHarness else {
                return
            }

            let lowerHarness = DatagramLowerHarness(context: context)

            try! demux.attachLowerDatagramProtocol(
                udp,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: path
            )

            try! udp.attachLowerDatagramProtocol(
                lowerHarness.reference,
                remote: remoteEndpoint,
                local: localEndpoint,
                parameters: parameters,
                path: path
            )

            upperHarness.invokeConnect()

            // Tracks each pattern-based upper harness together with the patterns that
            // control which inbound packets it receives from the demux.
            var patternHarnesses: [(harness: DatagramUpperHarness, patterns: [DemuxPatternInput])] = []

            for demuxedFlow in demuxedFlows {
                var demuxParameters = Parameters()
                demuxParameters.context = context

                guard !demuxedFlow.isEmpty else { continue }

                let demuxOptions = DemuxProtocol.options()
                for patternInput in demuxedFlow {
                    try! demuxOptions.addPattern(
                        patternInput.pattern.span.bytes,
                        at: patternInput.offset,
                        mask: patternInput.mask?.span.bytes
                    )
                }
                demuxOptions.setProtocolInstance(demux)

                demuxParameters.defaultStack.append(applicationProtocol: .custom(demuxOptions))

                let demuxUpperHarness = DatagramUpperHarness(
                    identifier: "Demux",
                    local: localEndpoint,
                    remote: remoteEndpoint,
                    parameters: demuxParameters,
                    path: path,
                    context: context,
                    lowerProtocol: demuxLinkage
                )
                XCTAssertNotNil(demuxUpperHarness, "Failed to attach demux upper harness")
                guard let demuxUpperHarness else {
                    return
                }

                demuxUpperHarness.invokeConnect()

                patternHarnesses.append((harness: demuxUpperHarness, patterns: demuxedFlow))
            }

            // Send datagrams from each attached upper. Every outbound datagram should
            // pass through the demux and UDP to appear on the lower harness in the
            // same order we wrote them.
            var expectedOutboundPayloads: [[UInt8]] = []
            for sequence in 0..<datagramsPerFlow {
                let defaultPayload = Self.makePayload(pattern: nil, flowIndex: 0, sequence: sequence)
                XCTAssertTrue(upperHarness.write(defaultPayload), "Default harness failed to write")
                expectedOutboundPayloads.append(defaultPayload)

                for (flowIndex, entry) in patternHarnesses.enumerated() {
                    let payload = Self.makePayload(
                        pattern: entry.patterns.first,
                        flowIndex: flowIndex + 1,
                        sequence: sequence
                    )
                    XCTAssertTrue(entry.harness.write(payload), "Pattern harness \(flowIndex) failed to write")
                    expectedOutboundPayloads.append(payload)
                }
            }

            for (index, expectedPayload) in expectedOutboundPayloads.enumerated() {
                guard let outbound = lowerHarness.extractLastOutboundPacket() else {
                    XCTFail("Missing outbound packet at index \(index)")
                    return
                }
                XCTAssertTrue(outbound.count >= 8, "Outbound packet at index \(index) too short")
                let payload = Array(outbound.dropFirst(8))
                XCTAssertEqual(payload, expectedPayload, "Outbound payload mismatch at index \(index)")
            }
            XCTAssertFalse(lowerHarness.hasOutboundPackets, "Unexpected extra outbound packets")

            // Inject inbound datagrams for each flow. Default first, then each pattern
            // flow so that FIFO drain from the lower harness lets each upper harness
            // pull exactly the packets that belong to it.
            var expectedInboundFlows: [(harness: DatagramUpperHarness, payloads: [[UInt8]])] = []

            var defaultInboundPayloads: [[UInt8]] = []
            for sequence in 0..<datagramsPerFlow {
                let payload = Self.makePayload(pattern: nil, flowIndex: 0, sequence: sequence)
                defaultInboundPayloads.append(payload)
                let packet = Self.makeUDPPacket(
                    payload: payload,
                    sourcePort: remoteEndpoint.port,
                    destPort: localEndpoint.port
                )
                lowerHarness.setNextInboundPacket(packet)
            }
            expectedInboundFlows.append((harness: upperHarness, payloads: defaultInboundPayloads))

            for (flowIndex, entry) in patternHarnesses.enumerated() {
                var payloads: [[UInt8]] = []
                for pattern in entry.patterns {
                    for sequence in 0..<datagramsPerFlow {
                        let payload = Self.makePayload(
                            pattern: pattern,
                            flowIndex: flowIndex + 1,
                            sequence: sequence
                        )
                        payloads.append(payload)
                        let packet = Self.makeUDPPacket(
                            payload: payload,
                            sourcePort: remoteEndpoint.port,
                            destPort: localEndpoint.port
                        )
                        lowerHarness.setNextInboundPacket(packet)
                    }
                }
                expectedInboundFlows.append((harness: entry.harness, payloads: payloads))
            }

            for (flowIndex, entry) in expectedInboundFlows.enumerated() {
                for (sequence, expected) in entry.payloads.enumerated() {
                    guard let bytes = entry.harness.read() else {
                        XCTFail("Flow \(flowIndex) sequence \(sequence) failed to read")
                        return
                    }
                    XCTAssertEqual(bytes, expected, "Flow \(flowIndex) sequence \(sequence) mismatch")
                }
            }

            // Tear down protocols.
            for entry in patternHarnesses {
                entry.harness.stop()
                entry.harness.teardown()
            }
            upperHarness.stop()
            upperHarness.teardown()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testDemuxNoPatterns() {
        testDemux(demuxedFlows: [])
    }

    func testDemuxBasicPattern() {
        testDemux(demuxedFlows: [[DemuxPatternInput(pattern: [1, 2, 3, 4], offset: 0)]])
    }

    // Largest valid pattern size is 30 bytes (the API rejects patterns > 30 bytes).
    func testDemuxMaxLengthPattern() {
        let pattern = (0..<30).map { UInt8($0) }
        testDemux(demuxedFlows: [[DemuxPatternInput(pattern: pattern, offset: 0)]])
    }

    // Three flows each with a pattern at a distinct non-zero offset.
    func testDemuxOffsetVariations() {
        testDemux(demuxedFlows: [
            [DemuxPatternInput(pattern: [0x11, 0x22, 0x33], offset: 5)],
            [DemuxPatternInput(pattern: [0x44, 0x55, 0x66], offset: 12)],
            [DemuxPatternInput(pattern: [0x77, 0x88, 0x99], offset: 1)],
        ])
    }

    // A single upper protocol that matches two different patterns at two different offsets.
    func testDemuxMultiplePatternsInFlow() {
        testDemux(demuxedFlows: [
            [
                DemuxPatternInput(pattern: [0x10, 0x20, 0x30, 0x40], offset: 0),
                DemuxPatternInput(pattern: [0xAA, 0xBB], offset: 12),
            ]
        ])
    }

    // Three upper protocols each with their own distinct pattern.
    func testDemuxMultipleFlows() {
        testDemux(demuxedFlows: [
            [DemuxPatternInput(pattern: [0x01, 0x02, 0x03], offset: 0)],
            [DemuxPatternInput(pattern: [0x11, 0x12, 0x13], offset: 0)],
            [DemuxPatternInput(pattern: [0x21, 0x22, 0x23], offset: 0)],
        ])
    }

    // Pattern with a mask: only bytes 0 and 2 must match, bytes 1 and 3 are wild.
    func testDemuxMaskedPattern() {
        testDemux(demuxedFlows: [
            [
                DemuxPatternInput(
                    pattern: [0x11, 0x22, 0x33, 0x44],
                    offset: 0,
                    mask: [0xFF, 0x00, 0xFF, 0x00]
                )
            ]
        ])
    }

    // Combination of features: multiple flows, multiple patterns per flow, mixed offsets,
    // and both masked and unmasked patterns living side-by-side.
    func testDemuxComplexMix() {
        testDemux(demuxedFlows: [
            [
                DemuxPatternInput(pattern: [0x01, 0x02, 0x03, 0x04], offset: 0),
                DemuxPatternInput(pattern: [0xAA, 0xBB], offset: 10),
            ],
            [
                DemuxPatternInput(
                    pattern: [0x11, 0x22, 0x33, 0x44],
                    offset: 4,
                    mask: [0xFF, 0x00, 0xFF, 0x00]
                )
            ],
            [
                DemuxPatternInput(pattern: [0x55, 0x66, 0x77], offset: 2),
                DemuxPatternInput(
                    pattern: [0xC0, 0xD0],
                    offset: 15,
                    mask: [0xFF, 0x00]
                ),
            ],
        ])
    }

    func testDemuxPatternTooLong() {
        let demuxOptions = DemuxProtocol.options()
        // Patterns of more than 30 bytes are rejected by the API.
        let tooLongPattern = [UInt8](repeating: 0xAB, count: 31)
        do {
            try demuxOptions.addPattern(tooLongPattern.span.bytes, at: 0)
            XCTFail("Expected patternTooLong to be thrown")
        } catch {
            if case .patternTooLong = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDemuxInvalidMask() {
        let demuxOptions = DemuxProtocol.options()
        // A mask whose length does not match the pattern length must be rejected.
        let pattern: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let shortMask: [UInt8] = [0xFF, 0xFF]
        do {
            try demuxOptions.addPattern(pattern.span.bytes, at: 0, mask: shortMask.span.bytes)
            XCTFail("Expected invalidMask to be thrown for a mask that is too short")
        } catch {
            if case .invalidMask = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // Also verify that a mask that is too long is rejected.
        let longMask: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        do {
            try demuxOptions.addPattern(pattern.span.bytes, at: 0, mask: longMask.span.bytes)
            XCTFail("Expected invalidMask to be thrown for a mask that is too long")
        } catch {
            if case .invalidMask = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

}

#endif
