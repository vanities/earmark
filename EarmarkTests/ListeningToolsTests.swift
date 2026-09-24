import XCTest
@testable import Earmark

@MainActor
final class ListeningToolsTests: XCTestCase {
    private func book(_ path: String) -> Book {
        let source = UUID()
        return Book(id: Book.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path,
                    kind: .folder, title: path, author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil,
                    tracks: [], chapters: [], artworkID: nil, addedAt: .now, totalBytes: 0)
    }

    func testQueueDeduplicatesCopiesReordersAndSurvivesRelaunch() throws {
        let suite = "ListeningToolsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = LibraryModel(store: LibraryStore(directory: dir), settings: settings)
        let player = PlayerEngine(library: library, settings: settings)
        player.enqueue(book("A")); player.enqueue(book("B")); player.enqueue(book("A"))
        XCTAssertEqual(player.queueKeys, ["a", "b"])
        player.moveQueued(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(AppSettings(defaults: defaults).queueKeys, ["b", "a"])
        player.removeQueued(at: IndexSet(integer: 1))
        XCTAssertEqual(AppSettings(defaults: defaults).queueKeys, ["b"])
        XCTAssertFalse(settings.autoplayQueue)
    }

    func testBedtimeBookmarkIsNotDuplicatedWhenTimerChanges() throws {
        let suite = "ListeningToolsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = LibraryModel(store: LibraryStore(directory: dir), settings: settings)
        let player = PlayerEngine(library: library, settings: settings)
        let item = book("Bedtime")
        player.load(item, autoplay: false)
        player.setSleepTimer(.duration(900))
        player.setSleepTimer(.duration(1800))
        player.setSleepTimer(.off)
        player.setSleepTimer(.endOfChapter)
        XCTAssertEqual(library.bookmarks(for: item).count, 1)
        XCTAssertTrue(player.bedtimeBookmark?.note.hasPrefix("Bedtime · ") == true)
        player.setSleepTimer(.off)
        settings.bedtimeBookmarks = false
        let other = book("Other")
        player.load(other, autoplay: false)
        player.setSleepTimer(.endOfChapter)
        XCTAssertTrue(library.bookmarks(for: other).isEmpty)
        player.setSleepTimer(.off)
    }
}
