import XCTest

#if !NETWORK_NO_SWIFT_QUIC && !targetEnvironment(simulator) && (os(iOS) || os(macOS) || os(Linux) || os(Android))

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

@available(Network 0.1.0, *)
final class QUICStreamIDIndexTests: XCTestCase {
    /// Random inserts and removals, in and out of order and far apart, against a dictionary.
    func testMatchesADictionary() {
        var generator = SystemRandomNumberGenerator()
        for seed in 0..<20 {
            var index = QUICStreamIDIndex<Int>()
            var model: [UInt64: Int] = [:]
            var next: [UInt64] = [0, 1, 2, 3]
            var live: [UInt64] = []
            for step in 0..<4000 {
                switch Int.random(in: 0..<10, using: &generator) {
                case 0..<5:
                    // The next stream of a kind, or sometimes one far ahead or below the window.
                    let kind = Int.random(in: 0..<4, using: &generator)
                    var id = next[kind]
                    switch Int.random(in: 0..<20, using: &generator) {
                    case 0: id &+= UInt64.random(in: 20_000..<80_000, using: &generator) * 4
                    case 1: id = UInt64(kind) + UInt64.random(in: 0..<next[kind] / 4 + 1, using: &generator) * 4
                    default: next[kind] += 4
                    }
                    index[QUICStreamID(id)!] = step
                    if model[id] == nil { live.append(id) }
                    model[id] = step
                case 5..<9:
                    guard !live.isEmpty else { continue }
                    let at = Int.random(in: 0..<live.count, using: &generator)
                    let id = live.remove(at: at)
                    XCTAssertEqual(index.removeValue(forKey: QUICStreamID(id)!), model.removeValue(forKey: id))
                default:
                    let id = UInt64.random(in: 0..<next.max()! + 8, using: &generator)
                    XCTAssertEqual(index[QUICStreamID(id)!], model[id], "seed \(seed) step \(step)")
                }
            }
            for id in live {
                XCTAssertEqual(index[QUICStreamID(id)!], model[id])
            }
            index.removeAll()
            for id in live {
                XCTAssertNil(index[QUICStreamID(id)!])
            }
        }
    }
}

#endif
