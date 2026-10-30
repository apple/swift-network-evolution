import XCTest

#if !NETWORK_NO_SWIFT_QUIC && !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
final class StreamSendBufferAckTests: XCTestCase {
    /// Random frames and random acknowledgements (whole buffer, prefixes, out of order, duplicates and
    /// overlaps) against a model that tracks which bytes are acknowledged.
    func testAcknowledgementsMatchAModel() {
        var generator = SystemRandomNumberGenerator()
        let log = NetworkLoggerState()
        for _ in 0..<300 {
            var buffer = StreamSendBuffer()
            var total = 0
            var acknowledged: [Bool] = []
            let rounds = Int.random(in: 1...6, using: &generator)
            var last = false
            for round in 0..<rounds {
                let size = Int.random(in: 1...700, using: &generator)
                buffer.addSendData(Frame(count: size), isLast: false)
                total += size
                acknowledged += Array(repeating: false, count: size)
                if round == rounds - 1 {
                    buffer.markStreamFinished()
                    last = true
                }
                // Acknowledge some ranges of what exists so far.
                let acks = Int.random(in: 0...3, using: &generator)
                for _ in 0..<acks {
                    let start: Int
                    let length: Int
                    switch Int.random(in: 0..<4, using: &generator) {
                    case 0:
                        // Everything not yet acknowledged, from the front: the whole-buffer path.
                        start = Int(buffer.storageStartOffset)
                        length = total - start
                    case 1:
                        start = Int(buffer.storageStartOffset)
                        length = Int.random(in: 0...(total - start), using: &generator)
                    default:
                        start = Int.random(in: 0..<total, using: &generator)
                        length = Int.random(in: 0...(total - start), using: &generator)
                    }
                    guard length > 0 else { continue }
                    for i in start..<(start + length) { acknowledged[i] = true }
                    let finished = buffer.acknowledgedSendData(
                        offset: StreamOffset(start),
                        length: StreamLength(length),
                        log: log
                    )
                    let firstUnacknowledged = acknowledged.firstIndex(of: false) ?? total
                    XCTAssertEqual(Int(buffer.storageStartOffset), firstUnacknowledged)
                    XCTAssertEqual(finished, last && firstUnacknowledged == total)
                }
            }
            // Frames must be finalized before they are released.
            buffer.empty()
        }
    }
}

#endif
