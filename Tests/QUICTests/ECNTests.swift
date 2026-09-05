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

// MARK: ECN Initialization Tests
@available(Network 0.1.0, *)
final class ECNTests: XCTestCase {
    var ecn: ECN!
    var ecnPath: ECNPathState!
    var stats: Statistics!
    var conn: QUICConnection!
    let logPrefixer = LogPrefixer("[ECNTests]")

    override func setUp() {
        super.setUp()
        conn = QUICConnection(context: NetworkContext.implicitContext)
        stats = Statistics()
    }

    private func runInitTest(
        echoEnabled: Bool,
        markingEnabled: Bool,
        l4sEnabled: Bool,
        expectedCount: Int,
        expectedFlag: IPProtocol.ECN
    ) {
        ecn = ECN(
            echoEnabled: echoEnabled,
            markingEnabled: markingEnabled,
            l4sEnabled: l4sEnabled,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        let counter = ecnPath.ecnCounters(ecn: ecn, packetNumberSpace: .handshake)

        runProcessIPCodepoint()
        validateECNPackets(counter, expectedCount)

        ecnPath.reset(ecn: &ecn)
        validateECNPackets(counter, 0)

        runProcessIPCodepoint()
        validateECNPackets(counter, expectedCount)

        var packet = SentPacketRecord()
        packet.identifier = .init(space: .handshake, number: 0)
        packet.totalLength = 10 + 10
        packet.isAckEliciting = true
        let flag = ecnPath.outgoingIPCodepoint(ecn: ecn, stats: &stats, packet: &packet)
        XCTAssertEqual(flag, expectedFlag, "Wrong IP ECN flag")
    }

    private func runProcessIPCodepoint() {
        _ = ecnPath.processIPCodepoint(
            ecn: ecn,
            stats: &stats,
            packetNumberSpace: .handshake,
            flag: IPProtocol.ECN.ce
        )
        _ = ecnPath.processIPCodepoint(
            ecn: ecn,
            stats: &stats,
            packetNumberSpace: .handshake,
            flag: IPProtocol.ECN.ect0
        )
        _ = ecnPath.processIPCodepoint(
            ecn: ecn,
            stats: &stats,
            packetNumberSpace: .handshake,
            flag: IPProtocol.ECN.ect1
        )
    }

    private func validateECNPackets(_ counters: ECNCounters, _ count: Int) {
        XCTAssertEqual(counters.rxECNPackets.ce, count, "Wrong CE count")
        XCTAssertEqual(counters.rxECNPackets.ect0, count, "Wrong ECT(0) count")
        XCTAssertEqual(counters.rxECNPackets.ect1, count, "Wrong ECT(1) count")
    }

    func testInit() throws {
        runInitTest(
            echoEnabled: false,
            markingEnabled: false,
            l4sEnabled: false,
            expectedCount: 0,
            expectedFlag: .nonECT
        )
    }

    func testInitEcho() throws {
        runInitTest(
            echoEnabled: true,
            markingEnabled: false,
            l4sEnabled: false,
            expectedCount: 1,
            expectedFlag: .nonECT
        )
    }

    func testInitMarking() throws {
        runInitTest(
            echoEnabled: false,
            markingEnabled: true,
            l4sEnabled: false,
            expectedCount: 1,
            expectedFlag: .ect0
        )
    }

    func testInitEchoMarking() throws {
        runInitTest(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            expectedCount: 1,
            expectedFlag: .ect0
        )
    }

    func testInitL4S() throws {
        runInitTest(
            echoEnabled: false,
            markingEnabled: false,
            l4sEnabled: true,
            expectedCount: 0,
            expectedFlag: .nonECT
        )
    }

    func testInitEchoL4S() throws {
        runInitTest(
            echoEnabled: true,
            markingEnabled: false,
            l4sEnabled: true,
            expectedCount: 1,
            expectedFlag: .nonECT
        )
    }

    func testInitMarkingL4S() throws {
        runInitTest(
            echoEnabled: false,
            markingEnabled: true,
            l4sEnabled: true,
            expectedCount: 1,
            expectedFlag: .ect1
        )
    }

    func testInitEchoMarkingL4S() throws {
        runInitTest(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            expectedCount: 1,
            expectedFlag: .ect1
        )
    }

}

@available(Network 0.1.0, *)
struct ECNTestStepSend {
    let description: String
    let repeats: Int
    let packetNumberSpace: PacketNumberSpace
    let packetNunmberBegin: Int64
    let expectedState: ECNState
    let expectedFlag: IPProtocol.ECN
}

@available(Network 0.1.0, *)
struct ECNTestStepAck: ~Copyable {
    let description: String
    let repeats: Int
    let packetNumberSpace: PacketNumberSpace
    let frame: QUICFrame
    let expectedState: ECNState
    let expectedCECount: Int
    let previousLargestAcked: PacketNumber
    let newlyAckedECNCount: UInt64
}

@available(Network 0.1.0, *)
extension ECNTestStepSend {
    // Convenience constructors since most of the tests follow the same test steps
    static func probingState(flag: IPProtocol.ECN, repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "probing state",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 0,
            expectedState: .probing,
            expectedFlag: flag
        )
    }

    static func probingToValidate(flag: IPProtocol.ECN, repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "probing -> validate",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 0,
            expectedState: .validate,
            expectedFlag: flag
        )
    }

    static func validateState(flag: IPProtocol.ECN, repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "validate state",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 10,
            expectedState: .validate,
            expectedFlag: flag
        )
    }

    static func capableState(flag: IPProtocol.ECN, repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "capable state",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 20,
            expectedState: .capable,
            expectedFlag: flag
        )
    }

    static func capableStateApplicationData(flag: IPProtocol.ECN, repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "capable state application_data",
            repeats: repeats,
            packetNumberSpace: .applicationData,
            packetNunmberBegin: 0,
            expectedState: .capable,
            expectedFlag: flag
        )
    }

    static func manglingDetectedState(repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "mangling detected state",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 0,
            expectedState: .manglingDetected,
            expectedFlag: .nonECT
        )
    }

    static func blackholeState(repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "mangling detected state",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 0,
            expectedState: .blackholed,
            expectedFlag: .nonECT
        )
    }

    static func failedState(repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "failed state",
            repeats: 10,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 0,
            expectedState: .unsupported,
            expectedFlag: .nonECT
        )
    }

    static func handshakeValidationState(flag: IPProtocol.ECN, repeats: Int) -> ECNTestStepSend {
        ECNTestStepSend(
            description: "handshake validation state",
            repeats: repeats,
            packetNumberSpace: .handshake,
            packetNunmberBegin: 0,
            expectedState: .handshakeValidationSuccess,
            expectedFlag: flag
        )
    }
}

@available(Network 0.1.0, *)
extension ECNTestStepAck {
    // Convenience constructors since most of the tests follow the same test steps
    static func validateToCapable(
        frame: consuming QUICFrame,
        previousLargest: PacketNumber,
        newlyAcked: UInt64
    ) -> ECNTestStepAck {
        ECNTestStepAck(
            description: "validate -> capable",
            repeats: 1,
            packetNumberSpace: .handshake,
            frame: frame,
            expectedState: .capable,
            expectedCECount: 2,
            previousLargestAcked: previousLargest,
            newlyAckedECNCount: newlyAcked
        )
    }

    static func validateToManglingDetected(frame: consuming QUICFrame) -> ECNTestStepAck {
        ECNTestStepAck(
            description: "validate -> mangling detected",
            repeats: 1,
            packetNumberSpace: .handshake,
            frame: frame,
            expectedState: .manglingDetected,
            expectedCECount: 0,
            previousLargestAcked: 0,
            newlyAckedECNCount: 20
        )
    }

    static func validateToFailed(frame: consuming QUICFrame) -> ECNTestStepAck {
        ECNTestStepAck(
            description: "validate -> failed",
            repeats: 1,
            packetNumberSpace: .handshake,
            frame: frame,
            expectedState: .unsupported,
            expectedCECount: 0,
            previousLargestAcked: 0,
            newlyAckedECNCount: 10
        )
    }

    static func capableToFailed(
        frame: consuming QUICFrame,
        previousLargest: PacketNumber,
        newlyAcked: UInt64
    ) -> ECNTestStepAck {
        ECNTestStepAck(
            description: "capable -> failed",
            repeats: 1,
            packetNumberSpace: .handshake,
            frame: frame,
            expectedState: .unsupported,
            expectedCECount: 0,
            previousLargestAcked: previousLargest,
            newlyAckedECNCount: newlyAcked
        )
    }

    static func failedState(
        frame: consuming QUICFrame,
        previousLargest: PacketNumber,
        newlyAcked: UInt64
    ) -> ECNTestStepAck {
        ECNTestStepAck(
            description: "failed state",
            repeats: 1,
            packetNumberSpace: .handshake,
            frame: frame,
            expectedState: .unsupported,
            expectedCECount: 0,
            previousLargestAcked: previousLargest,
            newlyAckedECNCount: newlyAcked
        )
    }

    static func handshakeValidationState(frame: consuming QUICFrame) -> ECNTestStepAck {
        ECNTestStepAck(
            description: "handshake validation state",
            repeats: 1,
            packetNumberSpace: .handshake,
            frame: frame,
            expectedState: .handshakeValidationSuccess,
            expectedCECount: 2,
            previousLargestAcked: 0,
            newlyAckedECNCount: 5
        )
    }
}

// MARK: ECN Validation Tests
@available(Network 0.1.0, *)
final class ECNValidateTests: XCTestCase {
    var ecn: ECN!
    var ecnPath: ECNPathState!
    var conn: QUICConnection!
    var stats: Statistics!
    let logPrefixer = LogPrefixer("[ECNValidateTests]")

    override func setUp() {
        super.setUp()
        conn = QUICConnection(context: NetworkContext.implicitContext)
        stats = Statistics()
    }

    private func createFrame(
        type: FrameType,
        largest: PacketNumber,
        ce: Int,
        ect: Int,
        useECT1: Bool
    ) -> QUICFrame {
        if type == .ack {
            let frame = FrameAck(packetNumberSpace: .handshake, largest: largest, delay: 0)
            return QUICFrame.ack(frame: frame)
        } else if type == .ackECN {
            var frame = FrameAck(packetNumberSpace: .handshake, largest: largest, delay: 0)
            frame.ecnCounter = ECNCounter(
                ect0: useECT1 ? 0 : ect,
                ect1: useECT1 ? ect : 0,
                ce: ce
            )
            return QUICFrame.ack(frame: frame)
        } else {
            fatalError("wrong type \(type)")
        }
    }

    func runTestStepSend(_ step: ECNTestStepSend) {
        for i in 0..<step.repeats {
            var packet = SentPacketRecord()
            packet.identifier = .init(space: .handshake, number: PacketNumber(Int64(i) + step.packetNunmberBegin))
            packet.totalLength = 10 + 10
            packet.isAckEliciting = true
            let flag = ecnPath.outgoingIPCodepoint(
                ecn: ecn,
                stats: &stats,
                packet: &packet
            )
            XCTAssertEqual(
                flag,
                step.expectedFlag,
                "\(step.description) at iteration \(i+1) has wrong IP ECN flag"
            )
            XCTAssertEqual(
                ecnPath.state,
                step.expectedState,
                "\(step.description) at iteration \(i+1) has wrong state"
            )
        }
    }

    func runTestStepAck(_ step: consuming ECNTestStepAck) {
        let description = step.description
        let repeats = step.repeats
        let expectedState = step.expectedState
        let expectedCECount = step.expectedCECount
        let previousLargestAcked = step.previousLargestAcked
        let newlyAckedECNCount = step.newlyAckedECNCount
        let frameType = step.frame.frameType
        let ack: FrameAck
        switch consume step.frame {
        case .ack(let frame):
            ack = frame
        default:
            XCTFail("Expected ACK frame, got \(frameType)")
            return
        }
        for i in 0..<repeats {
            let ceCount = ecnPath.validateAck(
                ecn: ecn,
                frame: ack,
                previousLargestAcked: previousLargestAcked,
                newlyAckedECNPackets: newlyAckedECNCount
            )
            XCTAssertEqual(
                ceCount,
                expectedCECount,
                "\(description) at iteration \(i+1) has wrong ce count"
            )
            XCTAssertEqual(
                ecnPath.state,
                expectedState,
                "\(description) at iteration \(i+1) has wrong ce count"
            )

        }
    }

    // probing (10th probe) -> validate (valid ACK_ECN for 5 probes) -> capable
    private func runValidationSuccessTest(flag: IPProtocol.ECN, borrowedECN: borrowing ECN) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        let ack = createFrame(
            type: .ackECN,
            largest: 9,
            ce: 2,
            ect: 8,
            useECT1: borrowedECN.useECT1
        )
        runTestStepAck(.validateToCapable(frame: ack, previousLargest: 0, newlyAcked: 10))
        runTestStepSend(.capableState(flag: flag, repeats: 10))
        runTestStepSend(.capableStateApplicationData(flag: flag, repeats: 1))
    }

    private func runValidationFailCETest(flag: IPProtocol.ECN, borrowedECN: borrowing ECN) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        let ack = createFrame(
            type: .ackECN,
            largest: 19,
            ce: 20,
            ect: 0,
            useECT1: borrowedECN.useECT1
        )
        runTestStepAck(.validateToManglingDetected(frame: ack))
        runTestStepSend(.manglingDetectedState(repeats: 10))
    }

    private func runValidationFailLostTest(flag: IPProtocol.ECN, lossThreshold: Int) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        for _ in 0..<lossThreshold {
            ecnPath.validationPacketLost()  // validate -> blackholed
        }
        runTestStepSend(.blackholeState(repeats: 10))
    }

    private func runValidationFailECTTest(flag: IPProtocol.ECN, borrowedECN: borrowing ECN) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        let ack = createFrame(
            type: .ackECN,
            largest: 9,
            ce: 0,
            ect: 10,
            useECT1: !borrowedECN.useECT1
        )
        runTestStepAck(.validateToFailed(frame: ack))
        runTestStepSend(.failedState(repeats: 10))
    }

    private func runValidationFailWrongAckTypeTest(flag: IPProtocol.ECN, borrowedECN: borrowing ECN) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        var ack = createFrame(
            type: .ackECN,
            largest: 9,
            ce: 2,
            ect: 8,
            useECT1: borrowedECN.useECT1
        )
        runTestStepAck(.validateToCapable(frame: ack, previousLargest: 0, newlyAcked: 10))
        runTestStepSend(.capableState(flag: flag, repeats: 10))
        ack = createFrame(type: .ack, largest: 10, ce: 2, ect: 9, useECT1: borrowedECN.useECT1)
        runTestStepAck(.capableToFailed(frame: ack, previousLargest: 9, newlyAcked: 1))
        runTestStepSend(.failedState(repeats: 10))
    }

    private func runValidationFailWrongACKTypeBeforeCapableTest(
        flag: IPProtocol.ECN,
        borrowedECN: borrowing ECN
    ) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        var ack = createFrame(type: .ack, largest: 9, ce: 2, ect: 8, useECT1: borrowedECN.useECT1)
        runTestStepAck(.validateToFailed(frame: ack))
        ack = createFrame(type: .ackECN, largest: 9, ce: 2, ect: 8, useECT1: borrowedECN.useECT1)
        runTestStepAck(.failedState(frame: ack, previousLargest: 0, newlyAcked: 10))
        runTestStepSend(.failedState(repeats: 10))
    }

    private func runValidationFailWrongSumTest(flag: IPProtocol.ECN, borrowedECN: borrowing ECN) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        let ack = createFrame(
            type: .ackECN,
            largest: 9,
            ce: 1,
            ect: 8,
            useECT1: borrowedECN.useECT1
        )
        runTestStepAck(.validateToFailed(frame: ack))
        runTestStepSend(.failedState(repeats: 10))
    }

    private func runValidationFailCECountTooLargeTest(
        flag: IPProtocol.ECN,
        borrowedECN: borrowing ECN
    ) {
        runTestStepSend(.probingState(flag: flag, repeats: ECNPathState.validationThreshold - 1))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        let ack = createFrame(
            type: .ackECN,
            largest: 19,
            ce: 21,
            ect: 0,
            useECT1: borrowedECN.useECT1
        )
        runTestStepAck(.validateToFailed(frame: ack))
        runTestStepSend(.failedState(repeats: 10))
    }

    // We shouldn't use CE count until capable state
    private func runValidationCECountTest(flag: IPProtocol.ECN, borrowedECN: borrowing ECN) {
        runTestStepSend(.probingState(flag: flag, repeats: 5))
        var ack = createFrame(
            type: .ackECN,
            largest: 4,
            ce: 2,
            ect: 3,
            useECT1: borrowedECN.useECT1
        )
        runTestStepAck(.handshakeValidationState(frame: ack))
        runTestStepSend(.handshakeValidationState(flag: flag, repeats: 4))
        runTestStepSend(.probingToValidate(flag: flag, repeats: 1))
        runTestStepSend(.validateState(flag: flag, repeats: 10))
        ack = createFrame(type: .ackECN, largest: 9, ce: 2, ect: 8, useECT1: borrowedECN.useECT1)
        runTestStepAck(.validateToCapable(frame: ack, previousLargest: 4, newlyAcked: 5))
        runTestStepSend(.capableState(flag: flag, repeats: 5))
        ack = createFrame(type: .ack, largest: 11, ce: 0, ect: 0, useECT1: borrowedECN.useECT1)
        runTestStepAck(.capableToFailed(frame: ack, previousLargest: 9, newlyAcked: 2))
        ack = createFrame(type: .ackECN, largest: 14, ce: 2, ect: 13, useECT1: borrowedECN.useECT1)
        runTestStepAck(.failedState(frame: ack, previousLargest: 11, newlyAcked: 3))
    }

    // run each test using ect(1) and ect(0)

    func testValidationSuccessTest() throws {

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationSuccessTest(flag: .ect1, borrowedECN: ecn)
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationSuccessTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationFailCE() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailCETest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailCETest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationFailLost() throws {
        // There is a higher threshold with packets loss for L4S experiments

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailLostTest(flag: .ect1, lossThreshold: ECNPathState.lossThreshold.ect1)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailLostTest(flag: .ect0, lossThreshold: ECNPathState.lossThreshold.ect0)
    }

    func testValidationFailECT() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailECTTest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailECTTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationFailWrongAckType() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailWrongAckTypeTest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailWrongAckTypeTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationFailWrongACKTypeBeforeCapable() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailWrongACKTypeBeforeCapableTest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailWrongACKTypeBeforeCapableTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationFailWrongSum() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailWrongSumTest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailWrongSumTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationFailCECountTooLarge() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailCECountTooLargeTest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationFailCECountTooLargeTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidationCECount() throws {
        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationCECountTest(flag: .ect1, borrowedECN: ecn)

        ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: false,
            connection: conn,
            logPrefixer: self.logPrefixer
        )
        ecnPath = ECNPathState(ecn: ecn)
        runValidationCECountTest(flag: .ect0, borrowedECN: ecn)
    }

    func testValidateAckReturnsCorrectCECount() async throws {
        let connection = QUICConnection(context: NetworkContext.implicitContext)
        let ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: connection,
            logPrefixer: self.logPrefixer
        )
        var ecnPath = ECNPathState(ecn: ecn)
        let applicationCounter = ecnPath.ecnCounters(ecn: ecn, packetNumberSpace: .applicationData)
        applicationCounter.txECNPackets = 25

        // Make sure CE + ECT1 is less than txECNPackets
        var ackFrame = FrameAck(packetNumberSpace: .applicationData, largest: 10, delay: 0)
        ackFrame.ecnCounter = ECNCounter(
            ect0: 0,
            ect1: 8,
            ce: 7
        )

        let returnedCECount = ecnPath.validateAck(
            ecn: ecn,
            frame: ackFrame,
            previousLargestAcked: 5,
            newlyAckedECNPackets: 5
        )
        XCTAssertTrue(
            returnedCECount == ackFrame.ecnCounter?.ce,
            "validateAck should return the CE count from ACK frame"
        )
        let counters = ecnPath.ecnCounters(ecn: ecn, packetNumberSpace: .applicationData)
        XCTAssertTrue(
            counters.largestCECount == ackFrame.ecnCounter?.ce,
            "largestCECount should match returned CE count"
        )
    }

    func testValidateAckLargestCECount() throws {
        let context = NetworkContext(identifier: #function)
        context.activate()

        let connection = QUICConnection(context: context)
        let ecn = ECN(
            echoEnabled: true,
            markingEnabled: true,
            l4sEnabled: true,
            connection: connection,
            logPrefixer: self.logPrefixer
        )
        var ecnPath = ECNPathState(ecn: ecn)

        var ackFrame1 = FrameAck(packetNumberSpace: .applicationData, largest: 10, delay: 0)
        ackFrame1.ecnCounter = ECNCounter(
            ect0: 0,
            ect1: 8,
            ce: 5
        )

        // txECNPackets set to 25 for all of the scenarios
        let counters = ecnPath.ecnCounters(ecn: ecn, packetNumberSpace: .applicationData)
        counters.txECNPackets = 25

        let returnedCECount1 = ecnPath.validateAck(
            ecn: ecn,
            frame: ackFrame1,
            previousLargestAcked: 0,
            newlyAckedECNPackets: 10
        )
        XCTAssertEqual(returnedCECount1, 5, "validateAck should return CE count from ACK frame")
        XCTAssertEqual(
            counters.largestCECount,
            5,
            "largestCECount should be updated to match ACK frame"
        )

        // Make sure CE is raised not processing another frame
        var ackFrame2 = FrameAck(packetNumberSpace: .applicationData, largest: 15, delay: 0)
        ackFrame2.ecnCounter = ECNCounter(
            ect0: 0,
            ect1: 12,
            ce: 8
        )

        let returnedCECount2 = ecnPath.validateAck(
            ecn: ecn,
            frame: ackFrame2,
            previousLargestAcked: 10,
            newlyAckedECNPackets: 5
        )

        XCTAssertEqual(returnedCECount2, 8, "validateAck should return updated CE count")
        XCTAssertEqual(
            counters.largestCECount,
            8,
            "largestCECount should be updated to higher value"
        )

        // This should return early since largest in FrameAck is lower than previousLargestAcked
        var ackFrame3 = FrameAck(packetNumberSpace: .applicationData, largest: 12, delay: 0)
        ackFrame3.ecnCounter = ECNCounter(
            ect0: 0,
            ect1: 10,
            ce: 6
        )  // Lower than current largestCECount

        let returnedCECount3 = ecnPath.validateAck(
            ecn: ecn,
            frame: ackFrame3,
            previousLargestAcked: 15,  // Previous largest was higher (reordered)
            newlyAckedECNPackets: 0
        )
        XCTAssertEqual(returnedCECount3, 8, "Reordered ACK should return existing largestCECount")
        XCTAssertEqual(
            counters.largestCECount,
            8,
            "largestCECount should remain unchanged for reordered ACKs"
        )
    }
}

#endif
