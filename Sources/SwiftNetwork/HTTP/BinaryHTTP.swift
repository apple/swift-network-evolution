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

@available(Network 0.1.0, *)
struct BinaryHTTPProtocol: ~Copyable {

    enum BinaryHTTPMessageType: UInt8 {
        case knownLengthRequest = 0
        case knownLengthResponse = 1
        case indeterminateLengthRequest = 2
        case indeterminateLengthResponse = 3

        var isRequest: Bool {
            self == .knownLengthRequest || self == .indeterminateLengthRequest
        }

        var isResponse: Bool {
            !isRequest
        }

        var isKnownLength: Bool {
            self == .knownLengthRequest || self == .knownLengthResponse
        }

        var isIndeterminate: Bool {
            !isKnownLength
        }
    }

    struct BinaryHTTPState: ~Copyable, StreamDeserializerState {
        typealias StateMachineStepIdentifier = TLVStateMachineStep
        enum TLVStateMachineStep: Hashable {
            case readingType
            case readingControlData
            case readingHeaders
            case readingBody
            case readingBodyChunks
            case readingTrailers
        }

        var type: BinaryHTTPMessageType?
        enum BinaryHTTPInnerMessage {
            case request(HTTPRequest)
            case response(HTTPResponse)
        }
        var innerMessage: BinaryHTTPInnerMessage? = nil
        /// 1xx responses that preceded the final response, in order received.
        var informationalResponses = [HTTPResponse]()
        var trailers = HTTPFields()
        var body = FrameArray()
        var statusCode = 0
        var headerFieldsLength = 0
        var trailerFieldsLength = 0
        var contentLength = 0

        /// HTTPFields traps when it holds more fields than this.
        static let maximumFieldCount = Int(UInt16.max) - 1

        /// Whether the response currently being parsed is informational (1xx), and so is
        /// followed by another response control block.
        var isParsingInformationalResponse: Bool {
            (type?.isResponse ?? false) && statusCode < 200
        }

        @discardableResult
        mutating func appendHeaderField(_ field: HTTPField) -> Bool {
            switch innerMessage {
            case .request(var request):
                guard request.headerFields.count < BinaryHTTPState.maximumFieldCount else { return false }
                innerMessage = nil
                request.headerFields.append(field)
                innerMessage = .request(request)
            case .response(var response):
                guard response.headerFields.count < BinaryHTTPState.maximumFieldCount else { return false }
                innerMessage = nil
                response.headerFields.append(field)
                innerMessage = .response(response)
            case .none:
                return false
            }
            return true
        }

        /// Moves the informational response parsed so far aside, ready for the next control block.
        mutating func finishInformationalResponse() {
            if case .response(let response) = innerMessage {
                informationalResponses.append(response)
            }
            innerMessage = nil
            statusCode = 0
            headerFieldsLength = 0
        }
    }

    /// Reads the value half of a field line whose name length has already been read.
    private static func readField(
        nameLength: Int,
        from read: inout Deserializer<FrameArraySpanFactory>
    ) throws(DeserializationError) -> HTTPField {
        var name: String? = nil
        try read.fixedLengthUTF8(&name, byteCount: nameLength)
        // Pseudo-header fields are not allowed in field sections, and HTTPFields traps on them
        guard let name, !name.hasPrefix(":"), let fieldName = HTTPField.Name(parsed: name) else {
            try read.invalidate(.parsingFailed)
        }

        var valueLength = 0
        try read.vle(&valueLength)
        var value: String? = nil
        try read.fixedLengthUTF8(&value, byteCount: valueLength)
        return HTTPField(name: fieldName, value: value ?? "")
    }

    // Define a shared parser definition for binary HTTP messages (RFC 9292)
    static let parser = FrameArrayStreamDeserializer<BinaryHTTPState>.parser { stream in
        stream.beginState(.readingType)
        stream.parsePartialMessage { read, state throws(DeserializationError) in
            var framingIndicator = 0
            try read.vle(&framingIndicator)
            guard (0...3).contains(framingIndicator),
                let type = BinaryHTTPMessageType(rawValue: UInt8(framingIndicator))
            else {
                try read.invalidate(.parsingFailed)
            }
            state.type = type
        }

        // Response control data may be preceded by any number of informational responses,
        // each of which loops back here after its header section.
        stream.beginState(.readingControlData)
        stream.parsePartialMessage(if: { $0.type?.isRequest ?? false }) { read, state throws(DeserializationError) in
            var methodLength = 0
            try read.vle(&methodLength)
            var methodString: String? = nil
            try read.fixedLengthUTF8(&methodString, byteCount: methodLength)
            guard let methodString, let method = HTTPRequest.Method(methodString) else {
                try read.invalidate(.parsingFailed)
            }

            var schemeLength = 0
            try read.vle(&schemeLength)
            var scheme: String? = nil
            try read.fixedLengthUTF8(&scheme, byteCount: schemeLength)

            var authorityLength = 0
            try read.vle(&authorityLength)
            var authority: String? = nil
            try read.fixedLengthUTF8(&authority, byteCount: authorityLength)

            var pathLength = 0
            try read.vle(&pathLength)
            var path: String? = nil
            try read.fixedLengthUTF8(&path, byteCount: pathLength)

            let request = HTTPRequest(method: method, scheme: scheme, authority: authority, path: path)
            state.innerMessage = .request(request)
        }
        stream.parsePartialMessage(if: { $0.type?.isResponse ?? false }) { read, state throws(DeserializationError) in
            var statusCode = 0
            try read.vle(&statusCode)
            // Status codes are varints; only 100-599 are valid
            guard (100...599).contains(statusCode) else { try read.invalidate(.parsingFailed) }

            state.statusCode = statusCode
            state.innerMessage = .response(HTTPResponse(status: HTTPResponse.Status(code: statusCode)))
        }

        stream.beginState(.readingHeaders)
        // Known length headers
        stream.parsePartialMessage(if: { $0.type?.isKnownLength ?? false }) { read, state throws(DeserializationError) in
            try read.vle(&state.headerFieldsLength)
        }
        stream.parsePartialMessage(
            while: { $0.type?.isKnownLength ?? false },
            upTo: { $0.headerFieldsLength }
        ) { read, state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 0 else { try read.invalidate(.parsingFailed) }
            guard state.appendHeaderField(try readField(nameLength: nameLength, from: &read)) else {
                try read.invalidate(.parsingFailed)
            }
            return .continueLoop
        }
        // Indeterminate length headers, ended by a zero length name
        stream.parsePartialMessage(while: { $0.type?.isIndeterminate ?? false }) {
            read,
            state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 0 else { return .breakLoop }
            guard state.appendHeaderField(try readField(nameLength: nameLength, from: &read)) else {
                try read.invalidate(.parsingFailed)
            }
            return .continueLoop
        }

        // An informational response is followed by another control block. This evaluator
        // moves the finished response aside, and only runs once each time it is reached.
        stream.jumpToState(
            .readingControlData,
            if: { state in
                guard state.isParsingInformationalResponse else { return false }
                state.finishInformationalResponse()
                return true
            }
        )

        // RFC 9292 section 3.8: an encoder may omit the content, the trailers, and the zero-length
        // terminators and padding that follow the headers of the final response. The control data and
        // headers are required.
        stream.allowTruncation()

        stream.jumpToState(.readingBodyChunks, if: { $0.type?.isIndeterminate ?? false })

        // Known length content
        stream.beginState(.readingBody)
        stream.parsePartialMessage { read, state throws(DeserializationError) in
            try read.vle(&state.contentLength)
        }
        stream.forwardPartialMessage(byteCount: { $0.contentLength }) { byteCount, factory, state in
            let drainedFrames = factory.drainArray(maximumByteCount: byteCount)
            let drainedByteCount = drainedFrames.unclaimedLength
            state.body.add(frames: drainedFrames)
            return drainedByteCount
        }
        stream.jumpToState(.readingTrailers, if: { _ in true })

        // Indeterminate content: chunks, each with a non-zero length, ended by a zero length
        stream.beginState(.readingBodyChunks)
        stream.parsePartialMessage { read, state throws(DeserializationError) in
            try read.vle(&state.contentLength)
        }
        stream.jumpToState(.readingTrailers, if: { $0.contentLength == 0 })  // End of chunks, move onto trailers
        stream.forwardPartialMessage(byteCount: { $0.contentLength }) { byteCount, factory, state in
            let drainedFrames = factory.drainArray(maximumByteCount: byteCount)
            let drainedByteCount = drainedFrames.unclaimedLength
            state.body.add(frames: drainedFrames)
            return drainedByteCount
        }
        stream.jumpToState(.readingBodyChunks, if: { _ in true })  // Jump back to read the next chunk

        stream.beginState(.readingTrailers)
        // Known length trailers
        stream.parsePartialMessage(if: { $0.type?.isKnownLength ?? false }) { read, state throws(DeserializationError) in
            try read.vle(&state.trailerFieldsLength)
        }
        stream.parsePartialMessage(
            while: { $0.type?.isKnownLength ?? false },
            upTo: { $0.trailerFieldsLength }
        ) { read, state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 0 else { try read.invalidate(.parsingFailed) }
            guard state.trailers.count < BinaryHTTPState.maximumFieldCount else {
                try read.invalidate(.parsingFailed)
            }
            state.trailers.append(try readField(nameLength: nameLength, from: &read))
            return .continueLoop
        }
        // Indeterminate length trailers, ended by a zero length name
        stream.parsePartialMessage(while: { $0.type?.isIndeterminate ?? false }) {
            read,
            state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 0 else { return .breakLoop }
            guard state.trailers.count < BinaryHTTPState.maximumFieldCount else {
                try read.invalidate(.parsingFailed)
            }
            state.trailers.append(try readField(nameLength: nameLength, from: &read))
            return .continueLoop
        }

        stream.finalizeMessage()
    }

    // Instantiate the parser
    var parser = StreamDeserializer(parser: BinaryHTTPProtocol.parser)

    /// Parses one message out of `frames`, returning nil until the whole message has arrived.
    ///
    /// Zero padding that follows the message (RFC 9292 section 3.8) is consumed if it is already
    /// buffered. A truncated message is only completed by `finish(frames:)`.
    deinit {
        // Release any content received for a message that never completed
        var partialState = (consume parser).takePartialValue()
        partialState.body.finalizeAllFramesAsFailed()
    }

    /// Completes the message when no more bytes will arrive, after `parse(from:)` returned nil.
    ///
    /// Succeeds if the message was truncated at a point RFC 9292 section 3.8 allows, treating the omitted
    /// content, trailers and terminators as empty. Throws if the message was cut off anywhere else, and
    /// returns nil if nothing of a message had arrived.
    mutating func finish(frames: inout FrameArray) throws(DeserializationError) -> BinaryHTTPState? {
        try parser.handleEndOfStream(&frames)
    }

    mutating func parse(from frames: inout FrameArray) throws(DeserializationError) -> BinaryHTTPState? {
        guard var state = try parser.handleFrames(&frames) else {
            return nil
        }
        var paddingLength = 0
        var paddingIsZero = true
        frames.iterateImmutableFrames { frame in
            if let bytes = frame.bytes {
                bytes.withUnsafeBytes { buffer in
                    paddingLength += buffer.count
                    paddingIsZero = paddingIsZero && !buffer.contains { $0 != 0 }
                }
            }
            return paddingIsZero
        }
        guard paddingIsZero else {
            state.body.finalizeAllFramesAsFailed()
            throw .parsingFailed
        }
        if paddingLength > 0 {
            _ = frames.claim(fromStart: paddingLength, removeClaimedFrames: true)
        }
        return state
    }
}
