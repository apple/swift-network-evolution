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
        let path = "/tmp"
        let harness = QUICTestHarness()

        let clientOptions = QUICProtocol.options()
        clientOptions.connectionOptions.qlogConfiguration = QLogConfiguration(
            logTitle: title,
            logDescription: description,
            logPath: path
        )
        harness.runQUICTest(dataBlock: dataBlock, clientOptions: clientOptions)

        let qlogExpectation = XCTestExpectation(description: "Loop until the qlog is written")
        // Validate the qlog file is present (based on how it creates the file)
        let finalPath = path + "/qlog_client_\(title)_C1.qlog"
        func checkQlogFileExists() {
            if FileManager.default.fileExists(atPath: finalPath) {
                qlogExpectation.fulfill()
            }
            harness.context.async {
                checkQlogFileExists()
            }
        }
        harness.context.async {
            checkQlogFileExists()
        }
        wait(for: [qlogExpectation], timeout: 5.0)

        let resultData = FileManager.default.contents(atPath: finalPath)
        guard let resultData else {
            XCTFail("Unable to read contents of file \(finalPath)")
            return
        }
        XCTAssertNotNil(resultData)
        unlink(finalPath)
    }

    func testQUICWriteServerQlogFileOnDataTransfer() throws {
        let dataBlock: [UInt8] = Array("Hello World!".utf8)
        let title = "ServerQLog"
        let description = "ServerQLogDescription"
        // NOTE: Test using a trailing slash at the end of the path name
        let path = "/tmp/"
        let harness = QUICTestHarness()

        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.qlogConfiguration = QLogConfiguration(
            logTitle: title,
            logDescription: description,
            logPath: path
        )

        harness.runQUICTest(dataBlock: dataBlock, serverOptions: serverOptions)

        let qlogExpectation = XCTestExpectation(description: "Loop until the qlog is written")
        // Validate the qlog file is present (based on how it creates the file)
        let finalPath = path + "qlog_server_\(title)_C1.qlog"
        func checkQlogFileExists() {
            if FileManager.default.fileExists(atPath: finalPath) {
                qlogExpectation.fulfill()
            }
            harness.context.async {
                checkQlogFileExists()
            }
        }
        harness.context.async {
            checkQlogFileExists()
        }
        wait(for: [qlogExpectation], timeout: 5.0)

        let resultData = FileManager.default.contents(atPath: finalPath)
        guard let resultData else {
            XCTFail("Unable to read contents of file \(finalPath)")
            return
        }
        XCTAssertNotNil(resultData)
        unlink(finalPath)
    }

    // When the peer sends CONNECTION_CLOSE, the connection arms a draining timer and only writes its
    // qlog once that timer fires. If the connection is torn down (and its event manager
    // unregistered) while the timer is still pending, the timer must still be able to write the
    // qlog rather than scheduling work against an identifier that has already been reset.
    func testQUICWriteServerQlogFileAfterTeardownWhileDraining() throws {
        let title = "ServerDrainingQLog"
        let path = "/tmp/"
        let finalPath = path + "qlog_server_\(title)_C1.qlog"
        unlink(finalPath)
        let harness = QUICTestHarness()

        let serverOptions = QUICProtocol.options()
        serverOptions.connectionOptions.qlogConfiguration = QLogConfiguration(
            logTitle: title,
            logDescription: "ServerDrainingQLogDescription",
            logPath: path
        )

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
        let qlogExpectation = XCTestExpectation(description: "Loop until the draining qlog is written")
        func checkQlogFileExists() {
            if FileManager.default.fileExists(atPath: finalPath) {
                qlogExpectation.fulfill()
                return
            }
            harness.context.async {
                checkQlogFileExists()
            }
        }
        harness.context.async {
            checkQlogFileExists()
        }
        wait(for: [qlogExpectation], timeout: 5.0)

        XCTAssertNotNil(FileManager.default.contents(atPath: finalPath), "Unable to read contents of \(finalPath)")
        unlink(finalPath)
    }
}

#endif
#endif
