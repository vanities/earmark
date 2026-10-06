import XCTest
@testable import Earmark

final class NowPlayingSnapshotTests: XCTestCase {
    func testRoundTrips() throws {
        let snap = NowPlayingSnapshot(bookID: "s|p|k", title: "Assassin's Apprentice",
            author: "Robin Hobb", narrator: "Paul Boehmer", fraction: 0.42, remaining: "9h 3m left", isPlaying: true, updatedAt: Date(timeIntervalSince1970: 1_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(NowPlayingSnapshot.self, from: data), snap)
    }

    func testReadsSnapshotsWrittenBeforeNarratorWasAdded() throws {
        let json = """
        {"bookID":"s|p|k","title":"Assassin's Apprentice","author":"Robin Hobb",
         "fraction":0.42,"remaining":"9h 3m left","isPlaying":true,"updatedAt":"2026-10-01T12:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(NowPlayingSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.narrator)
        XCTAssertNil(snapshot.narratorCredit)
        XCTAssertEqual(snapshot.author, "Robin Hobb")
    }

    func testNarratorEditsRefreshWidgetWithoutPlaybackMovement() {
        let original = NowPlayingSnapshot(bookID: "book", title: "Dune", author: "Frank Herbert",
                                          fraction: 0.42, remaining: "9h left", isPlaying: false, updatedAt: .now)
        var changed = original
        changed.narrator = "Simon Vance"
        XCTAssertNotEqual(changed.widgetUpdateKey, original.widgetUpdateKey)
        let withNarrator = changed
        changed.updatedAt = .distantFuture
        XCTAssertEqual(changed.widgetUpdateKey, withNarrator.widgetUpdateKey)
        changed.narrator = nil
        XCTAssertEqual(changed.widgetUpdateKey, original.widgetUpdateKey)
    }
}
