import XCTest
@testable import Earmark

final class NowPlayingSnapshotTests: XCTestCase {
    func testRoundTrips() throws {
        let snap = NowPlayingSnapshot(bookID: "s|p|k", title: "Assassin's Apprentice",
            author: "Robin Hobb", fraction: 0.42, remaining: "9h 3m left", isPlaying: true, updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(NowPlayingSnapshot.self, from: data), snap)
    }
}
