import XCTest
@testable import Earmark
import ShelfKit

/// Bookmarks follow you between devices, and a deleted one stays deleted everywhere.
final class BookmarkSyncTests: XCTestCase {
    private let phone = UUID(), pad = UUID()

    private func book(_ path: String, in source: UUID) -> Book {
        Book(id: Book.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path, kind: .folder,
             title: path, author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil,
             tracks: [], chapters: [], artworkID: nil, addedAt: .now, totalBytes: 0)
    }

    func testABookmarkFollowsTheBookToAnotherDevice() {
        let onPhone = book("Dune", in: phone), onPad = book("Dune", in: pad)
        let cloud = BookmarkSync.snapshot(local: [onPhone.id: [Bookmark(id: "m", offset: 90)]], books: [onPhone],
                                          existingCloud: [:], buried: Tombstones())
        let merged = BookmarkSync.merged(local: [onPad.id: [Bookmark(id: "p", offset: 30)]], books: [onPad], cloud: cloud, buried: Tombstones())
        XCTAssertEqual(merged[onPad.id]?.map(\.id), ["p", "m"], "both, in book order")
    }

    /// Without tombstones this is the bug Mango had: delete here, and iCloud's copy brings it back.
    func testADeletedBookmarkDoesNotComeBack() {
        let dune = book("Dune", in: phone)
        var buried = Tombstones()
        buried.bury("gone")
        let cloudCopy = [dune.syncKey: [Bookmark(id: "gone", offset: 10), Bookmark(id: "kept", offset: 20)]]
        let merged = BookmarkSync.merged(local: [dune.id: [Bookmark(id: "kept", offset: 20)]], books: [dune], cloud: cloudCopy, buried: buried)
        XCTAssertEqual(merged[dune.id]?.map(\.id), ["kept"])
        let pushed = BookmarkSync.snapshot(local: merged, books: [dune], existingCloud: cloudCopy, buried: buried)
        XCTAssertEqual(pushed[dune.syncKey]?.map(\.id), ["kept"], "and it leaves iCloud's copy")
    }

    func testABookmarkDeletedOnAnotherDeviceGoesHereToo() {
        let dune = book("Dune", in: phone)
        var buried = Tombstones()
        buried.bury("gone")
        let merged = BookmarkSync.merged(local: [dune.id: [Bookmark(id: "gone", offset: 10)]], books: [dune], cloud: [:], buried: buried)
        XCTAssertNil(merged[dune.id])
    }

    func testTheDeletionsAreSavedAndOldLibrariesStillLoad() throws {
        var state = LibraryState()
        state.deletedBookmarks.bury("gone", at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertTrue(try decoder.decode(LibraryState.self, from: encoder.encode(state)).deletedBookmarks.contains("gone"))
        XCTAssertTrue(try decoder.decode(LibraryState.self, from: Data(#"{"progress":{}}"#.utf8)).deletedBookmarks.isEmpty)
    }

    /// A library restored from an older file keeps its deletions: nothing deleted since returns.
    func testRestoringAnOldLibraryDoesNotBringADeletedBookmarkBack() {
        var current = LibraryState()
        current.deletedBookmarks.bury("gone")
        var old = LibraryState()
        old.bookmarks["b"] = [Bookmark(id: "gone", offset: 5), Bookmark(id: "lost", offset: 9)]
        current.merge(restoring: old)
        XCTAssertEqual(current.bookmarks["b"]?.map(\.id), ["lost"])
    }
}
