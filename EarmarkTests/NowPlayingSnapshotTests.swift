import XCTest
@testable import Earmark

final class NowPlayingSnapshotTests: XCTestCase {
    func testRemainingTimeRefreshesWithinTheSamePercentOfALongBook() {
        let original = NowPlayingSnapshot(bookID: "book", title: "Long book", author: "Author",
                                          fraction: 0.421, remaining: "9h 3m left", isPlaying: false, updatedAt: .now)
        var changed = original
        changed.fraction = 0.422
        changed.remaining = "9h 2m left"
        XCTAssertNotEqual(changed.widgetUpdateKey, original.widgetUpdateKey,
                          "Remaining time changed even though the whole percent did not")
    }

    @MainActor
    func testUnloadingThenReloadingTheSameBookRestoresTheWidget() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = LibraryModel(store: LibraryStore(directory: directory), settings: settings)
        let player = PlayerEngine(library: library, settings: settings)
        let controller = NowPlayingController(player: player, settings: settings)
        controller.activate()
        defer { player.unload() }
        let source = UUID()
        let book = Book(id: Book.makeID(sourceID: source, relativePath: "Book"), sourceID: source,
                        relativePath: "Book", kind: .folder, title: "Book", author: "Author",
                        series: nil, seriesIndex: nil, narrator: nil, year: nil, tracks: [], chapters: [],
                        artworkID: nil, addedAt: .now, totalBytes: 0)
        XCTAssertNotNil(SharedNowPlaying.containerURL)
        player.load(book, autoplay: false)
        controller.update()
        XCTAssertEqual(SharedNowPlaying.read()?.bookID, book.id)
        player.unload()
        XCTAssertNil(SharedNowPlaying.read())
        player.load(book, autoplay: false)
        controller.update()
        XCTAssertEqual(SharedNowPlaying.read()?.bookID, book.id)
    }

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
