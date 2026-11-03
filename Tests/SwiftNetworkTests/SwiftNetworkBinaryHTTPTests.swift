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

import HTTPTypes
import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetworkTestHarness)
@_spi(TestHarness) @_spi(Essentials) @_spi(ProtocolProvider) import SwiftNetworkTestHarness
#endif

/// Tests for Binary HTTP (RFC 9292) message parsing.
@available(Network 0.1.0, *)
final class SwiftNetworkBinaryHTTPTests: NetTestCase {

    // MARK: - Test message description and encoder

    struct Message {
        var isRequest: Bool
        var isKnownLength: Bool
        // Request control data
        var method = "GET"
        var scheme = "https"
        var authority = "example.com"
        var path = "/hello.txt"
        // Response control data
        var informational: [(code: Int, headers: [(String, String)])] = []
        var status = 200
        var headers: [(String, String)] = []
        var body: [UInt8] = []
        // Indeterminate-length bodies are split into chunks of this size
        var chunkSize = 16
        var trailers: [(String, String)] = []
        var padding = 0
    }

    static func vi(_ value: Int) -> [UInt8] {
        switch value {
        case 0..<(1 << 6): return [UInt8(value)]
        case 0..<(1 << 14): return [0x40 | UInt8(value >> 8), UInt8(value & 0xff)]
        case 0..<(1 << 30):
            return (0..<4).map { i in UInt8((value >> (8 * (3 - i))) & 0xff) | (i == 0 ? 0x80 : 0) }
        default:
            return (0..<8).map { i in UInt8((value >> (8 * (7 - i))) & 0xff) | (i == 0 ? 0xc0 : 0) }
        }
    }

    static func lengthPrefixed(_ string: String) -> [UInt8] {
        vi(string.utf8.count) + Array(string.utf8)
    }

    static func fieldLines(_ fields: [(String, String)]) -> [UInt8] {
        fields.flatMap { lengthPrefixed($0.0) + lengthPrefixed($0.1) }
    }

    static func fieldSection(_ fields: [(String, String)], knownLength: Bool) -> [UInt8] {
        let lines = fieldLines(fields)
        return knownLength ? vi(lines.count) + lines : lines + [0]
    }

    static func encode(_ message: Message) -> [UInt8] {
        let known = message.isKnownLength
        var bytes: [UInt8] = [(message.isRequest ? 0 : 1) + (known ? 0 : 2)]
        if message.isRequest {
            bytes += lengthPrefixed(message.method)
            bytes += lengthPrefixed(message.scheme)
            bytes += lengthPrefixed(message.authority)
            bytes += lengthPrefixed(message.path)
        } else {
            for informational in message.informational {
                bytes += vi(informational.code)
                bytes += fieldSection(informational.headers, knownLength: known)
            }
            bytes += vi(message.status)
        }
        bytes += fieldSection(message.headers, knownLength: known)
        if known {
            bytes += vi(message.body.count) + message.body
        } else {
            var offset = 0
            while offset < message.body.count {
                let end = min(offset + message.chunkSize, message.body.count)
                bytes += vi(end - offset) + message.body[offset..<end]
                offset = end
            }
            bytes += [0]
        }
        bytes += fieldSection(message.trailers, knownLength: known)
        return bytes
    }

    /// The count of bytes before any padding.
    static func messageLength(_ message: Message) -> Int {
        var unpadded = message
        unpadded.padding = 0
        return encode(unpadded).count
    }

    // MARK: - Parse outcome

    enum Outcome: ~Copyable {
        case message(BinaryHTTPProtocol.BinaryHTTPState)
        case needMoreData
        case failed(DeserializationError)
    }

    func attempt(_ parser: inout BinaryHTTPProtocol, _ frames: inout FrameArray) -> Outcome {
        do {
            if let parsed = try parser.parse(from: &frames) {
                return .message(parsed)
            }
            return .needMoreData
        } catch {
            return .failed(error)
        }
    }

    /// Asserts that parsing `frames` fails, and releases everything.
    func assertParseFails(
        _ parser: inout BinaryHTTPProtocol,
        _ frames: inout FrameArray,
        _ what: String,
        line: UInt = #line
    ) {
        switch attempt(&parser, &frames) {
        case .message(var parsed):
            XCTFail("\(what): parsed a message", line: line)
            parsed.body.finalizeAllFramesAsFailed()
        case .needMoreData:
            XCTFail("\(what): wanted more data instead of failing", line: line)
        case .failed:
            break
        }
        frames.finalizeAllFramesAsFailed()
    }

    /// Asserts that parsing `frames` yields no message yet and no failure.
    func assertNeedsMoreData(
        _ parser: inout BinaryHTTPProtocol,
        _ frames: inout FrameArray,
        _ what: String,
        line: UInt = #line
    ) {
        switch attempt(&parser, &frames) {
        case .message(var parsed):
            XCTFail("\(what): parsed a message early", line: line)
            parsed.body.finalizeAllFramesAsFailed()
        case .needMoreData:
            break
        case .failed(let error):
            XCTFail("\(what): failed with \(error)", line: line)
        }
    }

    // MARK: - Feeding strategies

    enum Feed: CustomStringConvertible {
        /// One frame holding every byte, parsed once
        case allAtOnce
        /// Every byte its own frame, all added to a single frame array before parsing once
        case manyFramesOneArray
        /// Frames of the given size, added and parsed one at a time
        case chunks(Int)
        /// Frames of the given size, all added to a single frame array before parsing once
        case manyFramesOfSize(Int)

        var description: String {
            switch self {
            case .allAtOnce: return "allAtOnce"
            case .manyFramesOneArray: return "manyFramesOneArray"
            case .chunks(let size): return "chunks(\(size))"
            case .manyFramesOfSize(let size): return "manyFramesOfSize(\(size))"
            }
        }
    }

    static let allFeeds: [Feed] = [
        .allAtOnce, .manyFramesOneArray, .chunks(1), .chunks(2), .chunks(3), .chunks(7), .chunks(64),
        .manyFramesOfSize(5),
    ]

    static func split(_ bytes: [UInt8], size: Int) -> [[UInt8]] {
        stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<min($0 + size, bytes.count)]) }
    }

    /// Parses `bytes` using the feed strategy. `messageLength` is the number of leading bytes that make up
    /// the message; the parser must not produce a message before they have all been fed.
    func parse(
        _ bytes: [UInt8],
        messageLength: Int,
        feed: Feed,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> BinaryHTTPProtocol.BinaryHTTPState? {
        var parser = BinaryHTTPProtocol()
        var frames = FrameArray()
        var result: BinaryHTTPProtocol.BinaryHTTPState? = nil
        var done = false

        let chunks: [[UInt8]]
        var parseEachChunk = true
        switch feed {
        case .allAtOnce:
            chunks = [bytes]
        case .manyFramesOneArray:
            chunks = Self.split(bytes, size: 1)
            parseEachChunk = false
        case .chunks(let size):
            chunks = Self.split(bytes, size: size)
        case .manyFramesOfSize(let size):
            chunks = Self.split(bytes, size: size)
            parseEachChunk = false
        }

        var fed = 0
        for (index, chunk) in chunks.enumerated() {
            frames.add(frames: FrameArray(frame: Frame(copyBuffer: chunk)))
            fed += chunk.count
            guard !done, parseEachChunk || index == chunks.count - 1 else { continue }

            switch attempt(&parser, &frames) {
            case .message(let parsed):
                XCTAssertGreaterThanOrEqual(
                    fed,
                    messageLength,
                    "\(feed): parsed early, after \(fed) of \(messageLength) bytes",
                    file: file,
                    line: line
                )
                result = consume parsed
                done = true
            case .needMoreData:
                XCTAssertLessThan(
                    fed,
                    messageLength,
                    "\(feed): did not parse after all \(messageLength) message bytes",
                    file: file,
                    line: line
                )
            case .failed(let error):
                XCTFail("\(feed): parse failed with \(error)", file: file, line: line)
            }
        }

        frames.finalizeAllFramesAsFailed()
        return result
    }

    // MARK: - Verification

    func assertFields(
        _ actual: HTTPFields,
        _ expected: [(String, String)],
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(what) count", file: file, line: line)
        for (field, expectation) in zip(actual, expected) {
            XCTAssertEqual(field.name.rawName, expectation.0, "\(what) name", file: file, line: line)
            XCTAssertEqual(field.value, expectation.1, "\(what) value", file: file, line: line)
        }
    }

    /// Encodes `message`, parses it with every feed strategy, and checks the result matches.
    func verify(_ message: Message, feeds: [Feed] = SwiftNetworkBinaryHTTPTests.allFeeds, line: UInt = #line) {
        let bytes = Self.encode(message)
        let messageLength = Self.messageLength(message)
        for feed in feeds {
            guard var parsed = parse(bytes, messageLength: messageLength, feed: feed, line: line) else {
                XCTFail("\(feed): no message parsed", line: line)
                continue
            }
            check(&parsed, against: message, feed: feed, line: line)
        }
    }

    func check(
        _ parsed: inout BinaryHTTPProtocol.BinaryHTTPState,
        against message: Message,
        feed: Feed,
        line: UInt
    ) {
        let expectedType: BinaryHTTPProtocol.BinaryHTTPMessageType =
            message.isRequest
            ? (message.isKnownLength ? .knownLengthRequest : .indeterminateLengthRequest)
            : (message.isKnownLength ? .knownLengthResponse : .indeterminateLengthResponse)
        XCTAssertEqual(parsed.type, expectedType, "\(feed)", line: line)

        switch parsed.innerMessage {
        case .request(let request):
            XCTAssertTrue(message.isRequest, "\(feed): parsed a request", line: line)
            XCTAssertEqual(request.method.rawValue, message.method, "\(feed)", line: line)
            XCTAssertEqual(request.scheme, message.scheme.isEmpty ? nil : message.scheme, "\(feed)", line: line)
            XCTAssertEqual(
                request.authority,
                message.authority.isEmpty ? nil : message.authority,
                "\(feed)",
                line: line
            )
            XCTAssertEqual(request.path, message.path.isEmpty ? nil : message.path, "\(feed)", line: line)
            assertFields(request.headerFields, message.headers, "\(feed) headers", line: line)
        case .response(let response):
            XCTAssertFalse(message.isRequest, "\(feed): parsed a response", line: line)
            XCTAssertEqual(response.status.code, message.status, "\(feed)", line: line)
            assertFields(response.headerFields, message.headers, "\(feed) headers", line: line)
        case .none:
            XCTFail("\(feed): no inner message", line: line)
        }

        XCTAssertEqual(
            parsed.informationalResponses.count,
            message.informational.count,
            "\(feed) informational count",
            line: line
        )
        for (response, expected) in zip(parsed.informationalResponses, message.informational) {
            XCTAssertEqual(response.status.code, expected.code, "\(feed)", line: line)
            assertFields(response.headerFields, expected.headers, "\(feed) informational headers", line: line)
        }

        assertFields(parsed.trailers, message.trailers, "\(feed) trailers", line: line)
        XCTAssertEqual(extractBytes(from: parsed.body), message.body, "\(feed) body", line: line)
        parsed.body.finalizeAllFramesAsFailed()
    }

    func extractBytes(from frameArray: borrowing FrameArray) -> [UInt8] {
        var bytes = [UInt8]()
        frameArray.iterateImmutableFrames { frame in
            if let allBytes = frame.bytes {
                allBytes.withUnsafeBytes { buffer in
                    bytes.append(contentsOf: buffer)
                }
            }
            return true
        }
        return bytes
    }

    // MARK: - Content generators

    static func manyFields(_ count: Int, prefix: String) -> [(String, String)] {
        (0..<count).map { ("\(prefix)-\($0)", "value number \($0)") }
    }

    static func body(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ 7) }
    }

    static let smallBody = Array("Hello World!\r\n".utf8)
    // Large enough for multiple-byte lengths and many chunks
    static let largeBody = body(20_000)

    /// Every request/response and known/indeterminate shape.
    static let shapes: [(name: String, isRequest: Bool, isKnownLength: Bool)] = [
        ("knownRequest", true, true),
        ("knownResponse", false, true),
        ("indeterminateRequest", true, false),
        ("indeterminateResponse", false, false),
    ]

    func forEachShape(_ configure: (inout Message) -> Void, line: UInt = #line) {
        for shape in Self.shapes {
            var message = Message(isRequest: shape.isRequest, isKnownLength: shape.isKnownLength)
            configure(&message)
            verify(message, line: line)
        }
    }

    // MARK: - RFC examples

    func testKnownLengthRequestRFCExample() {
        // RFC 9292 Figure 8
        var bytes: [UInt8] = [0x00, 0x03]
        bytes += Array("GET".utf8)
        bytes += [0x05]
        bytes += Array("https".utf8)
        bytes += [0x00, 0x0a]
        bytes += Array("/hello.txt".utf8)
        bytes += [0x40, 0x6c]
        bytes += Self.fieldLines([
            ("user-agent", "curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3"),
            ("host", "www.example.com"),
            ("accept-language", "en, mi"),
        ])
        bytes += [0x00, 0x00]
        var message = Message(isRequest: true, isKnownLength: true, authority: "")
        message.headers = [
            ("user-agent", "curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3"),
            ("host", "www.example.com"),
            ("accept-language", "en, mi"),
        ]
        XCTAssertEqual(Self.encode(message), bytes)
        verify(message)
    }

    func testIndeterminateLengthResponseWithInformationalRFCExample() {
        // RFC 9292 Figure 11, abbreviated
        var message = Message(isRequest: false, isKnownLength: false)
        message.informational = [
            (102, [("running", "\"sleep 15\"")]),
            (103, [("link", "</style.css>; rel=preload; as=style"), ("link", "</script.js>; rel=preload; as=script")]),
        ]
        message.status = 200
        message.headers = [("date", "Mon, 27 Jul 2009 12:28:53 GMT"), ("content-length", "51")]
        message.body = Array("Hello World! My content includes a trailing CRLF.\r\n".utf8)
        message.chunkSize = 51
        XCTAssertEqual(Self.encode(message).prefix(4), [0x03, 0x40, 0x66, 0x07])
        verify(message)
    }

    func testKnownLengthResponseWithTrailerRFCExample() {
        // RFC 9292 Figure 13
        var message = Message(isRequest: false, isKnownLength: true)
        message.body = Array("This content contains CRLF.\r\n".utf8)
        message.trailers = [("trailer", "text")]
        let bytes = Self.encode(message)
        XCTAssertEqual(bytes.prefix(5), [0x01, 0x40, 0xc8, 0x00, 0x1d])
        var expectedSuffix: [UInt8] = [0x0d, 0x07]
        expectedSuffix += Array("trailer".utf8)
        expectedSuffix += [0x04]
        expectedSuffix += Array("text".utf8)
        XCTAssertEqual(Array(bytes.suffix(expectedSuffix.count)), expectedSuffix)
        verify(message)
    }

    // MARK: - Headers

    func testNoHeaders() {
        forEachShape { $0.headers = [] }
    }

    func testOneHeader() {
        forEachShape { $0.headers = [("content-type", "text/plain")] }
    }

    func testSingleCharacterHeaderName() {
        // A one byte name is valid and must not be mistaken for a terminator
        forEachShape {
            $0.headers = [("x", "1")]
            $0.trailers = [("y", "2")]
        }
    }

    func testEmptyHeaderValue() {
        forEachShape { $0.headers = [("x-empty", ""), ("x-full", "value")] }
    }

    func testManyHeaders() {
        forEachShape { $0.headers = Self.manyFields(100, prefix: "x-header") }
    }

    func testDuplicateHeaders() {
        forEachShape { $0.headers = [("set-cookie", "a=1"), ("set-cookie", "b=2"), ("x-other", "z")] }
    }

    func testLongHeaderValueNeedingMultiByteLength() {
        forEachShape { $0.headers = [("x-long", String(repeating: "v", count: 300))] }
    }

    func testHeaderSectionLongerThan63Bytes() {
        // Known-length section lengths above 63 need a two byte varint
        forEachShape { $0.headers = Self.manyFields(8, prefix: "x-header") }
    }

    // MARK: - Trailers

    func testNoTrailers() {
        forEachShape {
            $0.body = Self.smallBody
            $0.trailers = []
        }
    }

    func testOneTrailer() {
        forEachShape {
            $0.body = Self.smallBody
            $0.trailers = [("x-checksum", "abcdef")]
        }
    }

    func testManyTrailers() {
        forEachShape {
            $0.body = Self.smallBody
            $0.trailers = Self.manyFields(100, prefix: "x-trailer")
        }
    }

    func testHeadersAndTrailersTogether() {
        forEachShape {
            $0.headers = Self.manyFields(10, prefix: "x-header")
            $0.body = Self.smallBody
            $0.trailers = Self.manyFields(10, prefix: "x-trailer")
        }
    }

    func testTrailersWithoutContent() {
        forEachShape {
            $0.headers = [("x-header", "h")]
            $0.body = []
            $0.trailers = [("x-trailer", "t")]
        }
    }

    // MARK: - Content

    func testNoContent() {
        forEachShape { $0.body = [] }
    }

    func testSmallContent() {
        forEachShape { $0.body = Self.smallBody }
    }

    func testOneByteContent() {
        forEachShape { $0.body = [0x2a] }
    }

    func testLargeContent() {
        forEachShape {
            $0.body = Self.largeBody
            $0.chunkSize = 1000
        }
    }

    func testLargeContentWithHeadersAndTrailers() {
        forEachShape {
            $0.headers = Self.manyFields(20, prefix: "x-header")
            $0.body = Self.largeBody
            $0.chunkSize = 4096
            $0.trailers = Self.manyFields(20, prefix: "x-trailer")
        }
    }

    func testContentContainingZeroBytes() {
        // Zero bytes in the content must not be mistaken for terminators or padding
        forEachShape {
            $0.body = [0, 0, 0, 1, 0, 0, 2, 0]
            $0.chunkSize = 3
        }
    }

    func testIndeterminateChunkSizes() {
        for chunkSize in [1, 2, 5, 14, 15, 100] {
            for isRequest in [true, false] {
                var message = Message(isRequest: isRequest, isKnownLength: false)
                message.body = Self.smallBody
                message.chunkSize = chunkSize
                message.trailers = [("x-trailer", "t")]
                verify(message)
            }
        }
    }

    func testIndeterminateSingleChunkLargerThan16KB() {
        // A chunk length needing a four byte varint
        var message = Message(isRequest: false, isKnownLength: false)
        message.body = Self.largeBody
        message.chunkSize = Self.largeBody.count
        verify(message)
    }

    // MARK: - Control data

    func testRequestMethods() {
        for method in ["GET", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "HEAD", "PATCH", "X-CUSTOM"] {
            for known in [true, false] {
                var message = Message(isRequest: true, isKnownLength: known)
                message.method = method
                verify(message, feeds: [.allAtOnce, .chunks(1)])
            }
        }
    }

    func testRequestWithEmptyAuthority() {
        for known in [true, false] {
            verify(Message(isRequest: true, isKnownLength: known, authority: ""))
        }
    }

    func testRequestWithLongPath() {
        for known in [true, false] {
            verify(Message(isRequest: true, isKnownLength: known, path: "/" + String(repeating: "p", count: 500)))
        }
    }

    func testResponseStatusCodes() {
        for status in [200, 201, 204, 301, 304, 400, 404, 500, 503, 599] {
            for known in [true, false] {
                var message = Message(isRequest: false, isKnownLength: known)
                message.status = status
                verify(message, feeds: [.allAtOnce, .chunks(1)])
            }
        }
    }

    func testOneInformationalResponse() {
        for known in [true, false] {
            var message = Message(isRequest: false, isKnownLength: known)
            message.informational = [(100, [])]
            message.headers = [("x-final", "yes")]
            message.body = Self.smallBody
            verify(message)
        }
    }

    func testManyInformationalResponses() {
        for known in [true, false] {
            var message = Message(isRequest: false, isKnownLength: known)
            message.informational = [
                (102, [("running", "step 1")]),
                (103, [("link", "a"), ("link", "b")]),
                (103, []),
                (199, Self.manyFields(10, prefix: "x-info")),
            ]
            message.headers = [("x-final", "yes")]
            message.body = Self.smallBody
            message.trailers = [("x-trailer", "t")]
            verify(message)
        }
    }

    // MARK: - Padding

    func testPaddingAllAtOnce() {
        for padding in [1, 2, 10, 100, 1000] {
            forEachShape {
                $0.headers = [("x-header", "h")]
                $0.body = Self.smallBody
                $0.trailers = [("x-trailer", "t")]
                $0.padding = padding
            }
        }
    }

    func testPaddingWithNoContentNoHeadersNoTrailers() {
        forEachShape { $0.padding = 10 }
    }

    func testPaddingIsConsumed() {
        for shape in Self.shapes {
            var message = Message(isRequest: shape.isRequest, isKnownLength: shape.isKnownLength)
            message.body = Self.smallBody
            message.padding = 10
            var bytes = Self.encode(message)
            bytes += [UInt8](repeating: 0, count: message.padding)

            var frames = FrameArray(frame: Frame(copyBuffer: bytes))
            var parser = BinaryHTTPProtocol()
            switch attempt(&parser, &frames) {
            case .message(var parsed): parsed.body.finalizeAllFramesAsFailed()
            case .needMoreData: XCTFail("\(shape.name): no message")
            case .failed(let error): XCTFail("\(shape.name): \(error)")
            }
            XCTAssertEqual(frames.unclaimedLength, 0, "\(shape.name): padding left over")
            frames.finalizeAllFramesAsFailed()
        }
    }

    func testNonZeroPaddingFails() {
        for shape in Self.shapes {
            let message = Message(isRequest: shape.isRequest, isKnownLength: shape.isKnownLength)
            let bytes = Self.encode(message) + [0, 0, 1]
            var frames = FrameArray(frame: Frame(copyBuffer: bytes))
            var parser = BinaryHTTPProtocol()
            assertParseFails(&parser, &frames, shape.name)
        }
    }

    // MARK: - Feeding

    func testSplitAtEveryOffset() {
        for shape in Self.shapes {
            var message = Message(isRequest: shape.isRequest, isKnownLength: shape.isKnownLength)
            message.informational = shape.isRequest ? [] : [(103, [("link", "a")])]
            message.headers = Self.manyFields(3, prefix: "x-header")
            message.body = Self.body(40)
            message.chunkSize = 9
            message.trailers = Self.manyFields(3, prefix: "x-trailer")

            let bytes = Self.encode(message)
            for split in 1..<bytes.count {
                var parser = BinaryHTTPProtocol()
                var frames = FrameArray(frame: Frame(copyBuffer: Array(bytes[..<split])))
                assertNeedsMoreData(&parser, &frames, "\(shape.name) split \(split)")
                frames.add(frames: FrameArray(frame: Frame(copyBuffer: Array(bytes[split...]))))
                switch attempt(&parser, &frames) {
                case .message(var parsed): check(&parsed, against: message, feed: .chunks(split), line: #line)
                case .needMoreData: XCTFail("\(shape.name) split \(split) did not parse")
                case .failed(let error): XCTFail("\(shape.name) split \(split): \(error)")
                }
                frames.finalizeAllFramesAsFailed()
            }
        }
    }

    func testBackToBackMessagesWithSeparateParsers() {
        // A parser resets after each message, so it can be reused when messages arrive separately
        var parser = BinaryHTTPProtocol()
        for shape in Self.shapes + Self.shapes {
            var message = Message(isRequest: shape.isRequest, isKnownLength: shape.isKnownLength)
            message.headers = [("x-header", shape.name)]
            message.body = Self.smallBody
            var frames = FrameArray(frame: Frame(copyBuffer: Self.encode(message)))
            switch attempt(&parser, &frames) {
            case .message(var parsed): check(&parsed, against: message, feed: .allAtOnce, line: #line)
            case .needMoreData: XCTFail("\(shape.name): no message")
            case .failed(let error): XCTFail("\(shape.name): \(error)")
            }
            frames.finalizeAllFramesAsFailed()
        }
    }

    // MARK: - Invalid messages

    func assertFails(_ bytes: [UInt8], _ what: String, line: UInt = #line) {
        var parser = BinaryHTTPProtocol()
        var frames = FrameArray(frame: Frame(copyBuffer: bytes))
        assertParseFails(&parser, &frames, what, line: line)
    }

    func testInvalidFramingIndicator() {
        assertFails([4, 0, 0, 0], "framing indicator 4")
        assertFails([0x3f, 0, 0, 0], "framing indicator 63")
    }

    func testInvalidStatusCodes() {
        for known in [true, false] {
            let framing: UInt8 = known ? 1 : 3
            assertFails([framing] + Self.vi(99) + [0, 0, 0], "status 99")
            assertFails([framing] + Self.vi(600) + [0, 0, 0], "status 600")
            assertFails([framing] + Self.vi(0), "status 0")
        }
    }

    func testPseudoHeaderFieldFails() {
        for known in [true, false] {
            var message = Message(isRequest: true, isKnownLength: known)
            message.headers = [(":method", "GET")]
            assertFails(Self.encode(message), "pseudo-header in headers, known: \(known)")
        }
    }

    func testPseudoTrailerFieldFails() {
        for known in [true, false] {
            var message = Message(isRequest: false, isKnownLength: known)
            message.trailers = [(":status", "200")]
            assertFails(Self.encode(message), "pseudo-header in trailers, known: \(known)")
        }
    }

    func testEmptyKnownLengthFieldNameFails() {
        // Known-length section of 2 bytes holding a zero length name and a zero length value
        assertFails([0, 0x00, 0x00, 0x00, 0x00] + [0x00, 0x00, 0x02, 0x00, 0x00], "empty field name")
    }

    func testInvalidMethodFails() {
        assertFails([0, 0x01, 0x20, 0, 0, 0, 0, 0, 0], "method with invalid character")
    }

    func testFailedParserStaysFailed() {
        var parser = BinaryHTTPProtocol()
        var frames = FrameArray(frame: Frame(copyBuffer: [9]))
        assertParseFails(&parser, &frames, "bad framing indicator")

        var good = FrameArray(frame: Frame(copyBuffer: Self.encode(Message(isRequest: true, isKnownLength: true))))
        assertParseFails(&parser, &good, "valid message after failure")
    }

    func testIncompleteMessageReturnsNil() {
        for shape in Self.shapes {
            var message = Message(isRequest: shape.isRequest, isKnownLength: shape.isKnownLength)
            message.body = Self.smallBody
            message.trailers = [("x-trailer", "t")]
            let bytes = Self.encode(message)
            var parser = BinaryHTTPProtocol()
            var frames = FrameArray(frame: Frame(copyBuffer: Array(bytes.dropLast())))
            assertNeedsMoreData(&parser, &frames, shape.name)
            frames.finalizeAllFramesAsFailed()
        }
    }
}
