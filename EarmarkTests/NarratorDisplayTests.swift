import MediaPlayer
import XCTest
@testable import Earmark

@MainActor
final class NarratorDisplayTests: XCTestCase {
    func testMissingOrBlankNarratorDoesNotCreateAnEmptyCredit() {
        for narrator in [nil, "", " \n "] as [String?] {
            XCTAssertNil(AudiobookCredits.narratorLine(narrator))
            XCTAssertEqual(AudiobookCredits.summary(author: "Jane Austen", narrator: narrator), "Jane Austen")
            XCTAssertEqual(AudiobookCredits.playbackDetail(author: "Jane Austen", narrator: narrator, chapter: "Chapter 2"), "Chapter 2")
        }
        XCTAssertEqual(AudiobookCredits.narratorLine("  Samantha \n"), "Narrated by Samantha")
    }

    func testLibraryAccessibilityIncludesNarrator() throws {
        try withPlayer { player, _, _ in
            let book = try XCTUnwrap(player.book)
            let label = BookCardView.accessibilityLabel(for: book, progress: PlaybackProgress(), remote: false)
            XCTAssertTrue(label.contains("by Jane Austen"))
            XCTAssertTrue(label.contains("Narrated by Samantha"))
        }
    }

    func testSystemNowPlayingIncludesNarratorAlongsideAuthor() throws {
        try withPlayer { player, _, settings in
            let controller = NowPlayingController(player: player, settings: settings)
            controller.update()
            let credits = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            XCTAssertEqual(credits, "Jane Austen · Narrated by Samantha")
        }
    }

    func testNarratorEditsUpdateWidgetWhilePaused() throws {
        try XCTSkipIf(SharedNowPlaying.containerURL == nil, "The simulator doesn't have the widget App Group capability")
        try withPlayer { player, library, settings in
            let controller = NowPlayingController(player: player, settings: settings)
            controller.update()
            XCTAssertEqual(SharedNowPlaying.read()?.narrator, "Samantha")
            library.books[0].narrator = "Juliet Stevenson"
            player.refreshBookFromLibrary()
            controller.update()
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(SharedNowPlaying.read()?.narrator, "Juliet Stevenson")
        }
    }

    func testLockedWidgetDoesNotExposeNarrator() throws {
        try XCTSkipIf(SharedNowPlaying.containerURL == nil, "The simulator doesn't have the widget App Group capability")
        try withPlayer { player, _, settings in
            let controller = NowPlayingController(player: player, settings: settings)
            controller.update()
            settings.lockMode = .immediately
            controller.update()
            let snapshot = try XCTUnwrap(SharedNowPlaying.read())
            XCTAssertNil(snapshot.narrator)
            XCTAssertNil(snapshot.narratorCredit)
            XCTAssertEqual(snapshot.title, "Continue listening")
            XCTAssertEqual(snapshot.author, "Earmark is locked")
        }
    }

    private func withPlayer(_ check: (PlayerEngine, LibraryModel, AppSettings) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "NarratorDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousSnapshot = SharedNowPlaying.read()
        let previousCover = SharedNowPlaying.coverURL.flatMap { try? Data(contentsOf: $0) }
        let previousInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            SharedNowPlaying.write(previousSnapshot)
            SharedNowPlaying.writeCover(previousCover)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = previousInfo
        }
        let settings = AppSettings(defaults: defaults)
        let library = LibraryModel(store: LibraryStore(directory: directory), settings: settings)
        let book = Book(id: "narrator-test", sourceID: UUID(), relativePath: "test", kind: .folder,
                        title: "Pride and Prejudice", author: "Jane Austen", narrator: "Samantha",
                        tracks: [], chapters: [], addedAt: .now, totalBytes: 0)
        library.books = [book]
        let player = PlayerEngine(library: library, settings: settings)
        defer { player.unload() }
        player.load(book, autoplay: false)
        try check(player, library, settings)
    }
}
