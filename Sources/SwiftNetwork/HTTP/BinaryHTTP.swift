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
        var trailers = HTTPFields()
        var body = FrameArray()
        var headerFieldsLength = 0
        var trailerFieldsLength = 0
        var contentLength = 0
    }

    // Define a shared parser definition for TLV messages
    static let parser = FrameArrayStreamDeserializer<BinaryHTTPState>.parser { stream in
        stream.beginState(.readingType)
        stream.parsePartialMessage { read, state throws(DeserializationError) in
            var framingIndicator = 0
            try read.vle(&framingIndicator)
            switch framingIndicator {
            case 0: state.type = .knownLengthRequest
            case 1: state.type = .knownLengthResponse
            case 2: state.type = .indeterminateLengthRequest
            case 3: state.type = .indeterminateLengthResponse
            default: throw .parsingFailed
            }
        }

        stream.beginState(.readingControlData)
        stream.parsePartialMessage(if: { $0.type?.isRequest ?? false }) { read, state throws(DeserializationError) in
            var methodLength = 0
            try read.vle(&methodLength)
            var methodString: String? = nil
            try read.fixedLengthUTF8(&methodString, byteCount: methodLength)
            guard let methodString, let method = HTTPRequest.Method(methodString) else {
                throw .parsingFailed
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

            let status = HTTPResponse.Status(code: statusCode)
            let response = HTTPResponse(status: status)
            state.innerMessage = .response(response)
        }

        stream.beginState(.readingHeaders)
        // Known length headers
        stream.parsePartialMessage(if: { $0.type?.isKnownLength ?? false }) { read, state throws(DeserializationError) in
            try read.vle(&state.headerFieldsLength)
        }
        stream.parsePartialMessage(while: { $0.type?.isKnownLength ?? false }, upTo: { $0.headerFieldsLength }) { read, state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 1 else { throw .parsingFailed }
            var name: String? = nil
            try read.fixedLengthUTF8(&name, byteCount: nameLength)
            guard let name, let fieldName = HTTPField.Name(parsed: name) else { throw .parsingFailed }

            var valueLength = 0
            try read.vle(&valueLength)
            var value: String? = nil
            try read.fixedLengthUTF8(&value, byteCount: valueLength)

            let field = HTTPField(name: fieldName, value: value ?? "")
            switch state.innerMessage {
            case .request(var request):
                request.headerFields.append(field)
                state.innerMessage = .request(request)
            case .response(var response):
                response.headerFields.append(field)
                state.innerMessage = .response(response)
            case .none:
                throw .parsingFailed
            }
            return .continueLoop
        }
        // Indeterminate length headers
        stream.parsePartialMessage(while: { $0.type?.isIndeterminate ?? false }) { read, state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 1 else { return .breakLoop }
            var name: String? = nil
            try read.fixedLengthUTF8(&name, byteCount: nameLength)
            guard let name, let fieldName = HTTPField.Name(parsed: name) else { throw .parsingFailed }

            var valueLength = 0
            try read.vle(&valueLength)
            var value: String? = nil
            try read.fixedLengthUTF8(&value, byteCount: valueLength)

            let field = HTTPField(name: fieldName, value: value ?? "")
            switch state.innerMessage {
            case .request(var request):
                request.headerFields.append(field)
                state.innerMessage = .request(request)
            case .response(var response):
                response.headerFields.append(field)
                state.innerMessage = .response(response)
            case .none:
                throw .parsingFailed
            }
            return .continueLoop
        }

        stream.jumpToState(.readingBodyChunks, if: { $0.type?.isIndeterminate ?? false })

        // Known length content
        stream.beginState(.readingBody)
        stream.parsePartialMessage(if: { $0.type?.isKnownLength ?? false }) { read, state throws(DeserializationError) in
            try read.vle(&state.contentLength)
        }
        stream.forwardPartialMessage(byteCount: { $0.contentLength }) { byteCount, factory, state in
            let drainedFrames = factory.drainArray(maximumByteCount: byteCount)
            let drainedByteCount = drainedFrames.unclaimedLength
            state.body.add(frames: drainedFrames)
            return drainedByteCount
        }
        stream.jumpToState(.readingTrailers, if: { $0.type?.isKnownLength ?? false })

        // Indeterminate content
        stream.beginState(.readingBodyChunks)
        stream.parsePartialMessage(if: { $0.type?.isKnownLength ?? false }) { read, state throws(DeserializationError) in
            try read.vle(&state.contentLength)
        }
        stream.jumpToState(.readingTrailers, if: { $0.contentLength == 0 }) // End of chunks, move onto trailers
        stream.forwardPartialMessage(byteCount: { $0.contentLength }) { byteCount, factory, state in
            let drainedFrames = factory.drainArray(maximumByteCount: byteCount)
            let drainedByteCount = drainedFrames.unclaimedLength
            state.body.add(frames: drainedFrames)
            return drainedByteCount
        }
        stream.jumpToState(.readingBodyChunks, if: { $0.contentLength != 0 }) // Jump back to read the next chunk

        stream.beginState(.readingTrailers)
        // Known length trailers
        stream.parsePartialMessage(if: { $0.type?.isKnownLength ?? false }) { read, state throws(DeserializationError) in
            try read.vle(&state.trailerFieldsLength)
        }
        stream.parsePartialMessage(while: { $0.type?.isKnownLength ?? false }, upTo: { $0.trailerFieldsLength }) { read, state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 1 else { throw .parsingFailed }
            var name: String? = nil
            try read.fixedLengthUTF8(&name, byteCount: nameLength)
            guard let name, let fieldName = HTTPField.Name(parsed: name) else { throw .parsingFailed }

            var valueLength = 0
            try read.vle(&valueLength)
            var value: String? = nil
            try read.fixedLengthUTF8(&value, byteCount: valueLength)

            let field = HTTPField(name: fieldName, value: value ?? "")
            state.trailers.append(field)
            return .continueLoop
        }
        // Indeterminate length trailers
        stream.parsePartialMessage(while: { $0.type?.isIndeterminate ?? false }) { read, state throws(DeserializationError) in
            var nameLength = 0
            try read.vle(&nameLength)
            guard nameLength > 1 else { return .breakLoop }
            var name: String? = nil
            try read.fixedLengthUTF8(&name, byteCount: nameLength)
            guard let name, let fieldName = HTTPField.Name(parsed: name) else { throw .parsingFailed }

            var valueLength = 0
            try read.vle(&valueLength)
            var value: String? = nil
            try read.fixedLengthUTF8(&value, byteCount: valueLength)

            let field = HTTPField(name: fieldName, value: value ?? "")
            state.trailers.append(field)
            return .continueLoop
        }

        stream.finalizeMessage()
    }

    // Instantiate the parser
    var parser = StreamDeserializer(parser: BinaryHTTPProtocol.parser)

    mutating func parse(from frames: inout FrameArray) -> BinaryHTTPState? {
        try? parser.handleFrames(&frames)
    }
}
