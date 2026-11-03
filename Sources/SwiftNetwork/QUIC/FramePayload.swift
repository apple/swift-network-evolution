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

/// A heap box for a `Frame`, for a payload that cannot be a view of the datagram it came from.
@available(Network 0.1.0, *)
final class FrameBox {
    var frame: Frame

    init(_ frame: consuming Frame) {
        self.frame = frame
    }
}

/// The bytes a received STREAM, CRYPTO or DATAGRAM frame carries.
///
/// A `Frame` is a large value (over a hundred bytes), and the frame types that held one were large
/// enough that every move of a `QUICFrame` was a call to `memmove`. The payload is a few words
/// instead: usually a view of the datagram the frame arrived in, which it keeps alive, so a frame
/// that does not end its packet no longer costs a copy either. A datagram whose storage cannot be
/// shared (it is owned by a `Frame` as bytes, or by a finalizer) is copied or moved into a box, as
/// those frames always were.
@available(Network 0.1.0, *)
struct FramePayload: ~Copyable {
    private enum Storage {
        case empty
        case view(owner: AnyObject, start: UnsafeMutableRawPointer, count: Int)
        case boxed(FrameBox)
    }

    private var storage: Storage = .empty

    init() {}

    /// A payload that is `frame`, whole.
    init(frame: consuming Frame) {
        var frame = frame
        frame.takeOwnershipOfBytes()
        self.storage = .boxed(FrameBox(frame))
    }

    private init(owner: AnyObject, start: UnsafeMutableRawPointer, count: Int) {
        self.storage = .view(owner: owner, start: start, count: count)
    }

    /// Takes the next `length` bytes out of `frame`, claiming them there.
    ///
    /// - Parameters:
    ///   - copy: Whether more of `frame` follows the payload. If not, a payload that cannot be a
    ///     view takes the whole of `frame`, which is left empty.
    ///   - preservingMetadata: Whether the payload has to be the frame itself (with what it carries,
    ///     such as its receive time) when it ends the packet, so a view is not an option then.
    /// - Returns: The payload, or `nil` if `frame` does not hold `length` bytes.
    static func extract(
        from frame: inout Frame,
        length: Int,
        copy: Bool,
        preservingMetadata: Bool = false
    ) -> FramePayload? {
        if copy || !preservingMetadata,
            let owner = frame.sharedOwner,
            let unclaimed = frame.unsafeUnclaimedBuffer,
            let start = unclaimed.baseAddress,
            length >= 0, unclaimed.count >= length
        {
            guard frame.claim(fromStart: length) else { return nil }
            return FramePayload(owner: owner, start: start, count: length)
        }
        if copy {
            var copied = Frame(count: length)
            let bytesCopied = frame.copyInto(&copied, length: length)
            guard frame.claim(fromStart: length), bytesCopied == length else {
                copied.finalize(success: false)
                return nil
            }
            return FramePayload(frame: copied)
        }
        // The payload is the rest of the frame: take it whole.
        var whole = Frame()
        swap(&whole, &frame)
        return FramePayload(frame: whole)
    }

    /// The payload as a frame of its own, leaving this one empty.
    mutating func takeFrame() -> Frame {
        var old = Storage.empty
        swap(&old, &self.storage)
        switch consume old {
        case .empty:
            return Frame()
        case .view(let owner, let start, let count):
            return Frame(customBuffer: UnsafeMutableRawBufferPointer(start: start, count: count), owner: owner)
        case .boxed(let box):
            var taken = Frame()
            swap(&taken, &box.frame)
            return taken
        }
    }

    /// Lets go of the payload.
    mutating func finalize(success: Bool) {
        var old = Storage.empty
        swap(&old, &self.storage)
        switch consume old {
        case .empty, .view:
            break
        case .boxed(let box):
            box.frame.finalize(success: success)
        }
    }

    /// A copy of the payload's bytes. For tests and logging.
    func copyBytes() -> [UInt8] {
        switch self.storage {
        case .empty:
            return []
        case .view(_, let start, let count):
            return [UInt8](UnsafeRawBufferPointer(start: start, count: count))
        case .boxed(let box):
            var frame = Frame()
            swap(&frame, &box.frame)
            defer { swap(&frame, &box.frame) }
            guard let span = frame.span else { return [] }
            return .init(copying: span, maxCount: span.count)
        }
    }
}

#endif
