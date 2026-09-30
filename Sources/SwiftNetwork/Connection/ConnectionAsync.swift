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

// Async entry points for the outer surface of a channel.
//
// These sit on top of the existing callback machinery rather than reaching into the stack
// themselves: queuing still happens through `endpointFlow.async` and the event context is still
// threaded synchronously inside. An `await` here only replaces the completion handler, so nothing
// within the isolation region ever suspends.
//
// A non-throwing continuation carrying the `Result` the callbacks already produce is used in
// place of `withCheckedThrowingContinuation`, so the thrown type stays `NetworkError` rather
// than widening to `any Error`.

#if canImport(BasicContainers)
import BasicContainers
#endif

// `StreamMessage` and `DatagramMessage` are nested in the generic `NetworkChannel`, so naming
// either of them inside a `@Sendable` closure captures `ApplicationProtocol.Type` -- and the
// concrete option types (`TLS` holds non-`@Sendable` handlers, `IP` holds a `DatagramBridge`)
// are not `Sendable`, so that capture warns. These non-generic payloads carry the same fields,
// which lets the read requests below complete without ever mentioning the generic type in a
// sendable position. Whether `NetworkProtocolOptions` should imply `Sendable` is a separate API
// question; until it is answered, the async surface stays unconstrained by going through these.
@available(Network 0.1.0, *)
struct StreamPayload: Sendable {
    let content: [UInt8]?
    let isComplete: Bool
}

@available(Network 0.1.0, *)
struct DatagramPayload: Sendable {
    let content: [UInt8]?
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension NetworkChannel where ApplicationProtocol: StreamProtocol {

    /// Sends a message, returning once the transport has taken it.
    ///
    /// Equivalent to `send(_:completion:)`. Queuing happens on the context, so this may be
    /// called before the channel is ready; the message is sent once establishment completes.
    ///
    /// > Note: Task cancellation is not propagated to an individual send. See
    /// `receive(atLeast:atMost:)` for the details and the escape hatch.
    public func send(_ message: StreamMessage) async throws(NetworkError) {
        let result: Result<Void, NetworkError> = await withCheckedContinuation { continuation in
            self.send(message, completion: { result in continuation.resume(returning: result) })
        }
        try result.get()
    }

    /// Receives a message, returning once enough data has arrived.
    ///
    /// Equivalent to `receive(atLeast:atMost:completion:)`.
    ///
    /// > Note: Task cancellation is not propagated to an individual receive: the stack's
    /// `ReadRequest` carries no identity, so a single queued read cannot yet be withdrawn. A
    /// cancelled task therefore stays suspended here until the read completes on its own or the
    /// channel goes away. To unblock every pending operation, call `cancel()` on the channel --
    /// `failPendingRequests()` fails all queued reads and writes with `ECANCELED`. Per-operation
    /// cancellation needs a token on `ReadRequest`/`WriteRequest` and is follow-on work.
    public func receive(
        atLeast minBytes: Int,
        atMost maxBytes: Int
    ) async throws(NetworkError) -> StreamMessage {
        let result: Result<StreamPayload, NetworkError> = await withCheckedContinuation { continuation in
            self.receivePayload(atLeast: minBytes, atMost: maxBytes) { payload in
                continuation.resume(returning: payload)
            }
        }
        let payload = try result.get()
        return .message(content: payload.content, isComplete: payload.isComplete)
    }

    // Mirrors `receive(atLeast:atMost:completion:)` but completes with the non-generic
    // `StreamPayload`. Built as its own read request rather than wrapping the message-typed
    // overload so that no `@Sendable` closure here names `StreamMessage`.
    private func receivePayload(
        atLeast minBytes: Int,
        atMost maxBytes: Int,
        completion: @escaping @Sendable (Result<StreamPayload, NetworkError>) -> Void
    ) {
        let endpointFlow = self.endpointFlow
        endpointFlow.async {
            let readRequest = ReadRequest(minimumBytes: minBytes, maximumBytes: maxBytes) {
                (content, isComplete, isFinal, error) in
                if let error = error {
                    completion(.failure(error))
                } else {
                    completion(.success(StreamPayload(content: content, isComplete: isComplete)))
                }
            }
            endpointFlow.addReadRequestOnContext(readRequest)
        }
    }

    // The `StreamSpanMessage` variant of `receive` has no async form on purpose: it is
    // `~Escapable` and carries a `RawSpan` borrowed from a frame that is only valid for the
    // duration of the completion. A continuation would have to let that span outlive its owner,
    // so span receives stay callback-only.
}

@_spi(Essentials)
@available(Network 0.1.0, *)
extension NetworkChannel where ApplicationProtocol: DatagramProtocol {

    /// Sends a datagram, returning once the transport has taken it.
    ///
    /// Equivalent to `send(_:completion:)`.
    ///
    /// > Note: Task cancellation is not propagated; see `receive()`.
    public func send(_ message: DatagramMessage) async throws(NetworkError) {
        let result: Result<Void, NetworkError> = await withCheckedContinuation { continuation in
            self.send(message, completion: { result in continuation.resume(returning: result) })
        }
        try result.get()
    }

    /// Receives a single datagram.
    ///
    /// Equivalent to `receive(completion:)`.
    ///
    /// > Note: Task cancellation is not propagated to an individual receive. Call `cancel()` on
    /// the channel to unblock every pending operation with `ECANCELED`.
    public func receive() async throws(NetworkError) -> DatagramMessage {
        let result: Result<DatagramPayload, NetworkError> = await withCheckedContinuation { continuation in
            self.receivePayload { payload in continuation.resume(returning: payload) }
        }
        return .message(content: try result.get().content)
    }

    // Mirrors `receive(completion:)` with the non-generic payload; see the stream variant.
    private func receivePayload(
        completion: @escaping @Sendable (Result<DatagramPayload, NetworkError>) -> Void
    ) {
        let endpointFlow = self.endpointFlow
        endpointFlow.async {
            let readRequest = ReadRequest(maximumFrames: 1) {
                (content, isComplete, isFinal, error) in
                if let error = error {
                    completion(.failure(error))
                } else {
                    completion(.success(DatagramPayload(content: content)))
                }
            }
            endpointFlow.addReadRequestOnContext(readRequest)
        }
    }
}
