import XCTest
@testable import Earmark

final class PortableBackupTests: XCTestCase {
    private func item(_ source: UUID, path: String = "Book/one.mp3", bytes: Int64 = 1000) -> Book {
        let files = [ScannedFile(relativePath: path, fileSize: bytes, modifiedAt: nil, metadata: AudioMetadata(duration: 60))]
        return BookGrouper.group(.init(sourceID: source, sourceName: "Test", files: files, imagesByDirectory: [:]))[0].book
    }
    func testRestoreMatchesNewSourceIdentityAndKeepsCurrentProgress() {
        let oldItem = item(UUID()), currentItem = item(UUID())
        var old = LibraryState(books: [oldItem]), current = LibraryState(books: [currentItem])
        old.progress[oldItem.id] = PlaybackProgress(time: 4)
        current.progress[currentItem.id] = PlaybackProgress(time: 12)
        old.bookmarks[oldItem.id] = [Bookmark(id: "mark", offset: 3, note: "Saved")]
        current.restorePortable(old)
        XCTAssertEqual(current.progress[currentItem.id]?.time, 12)
        XCTAssertEqual(current.bookmarks[currentItem.id]?.first?.id, "mark")
        XCTAssertNil(current.progress[oldItem.id])
        current.progress[currentItem.id] = nil
        current.restorePortable(old)
        XCTAssertEqual(current.progress[currentItem.id]?.time, 4)
        XCTAssertEqual(current.bookmarks[currentItem.id]?.count, 1)
    }
    func testRestoreDoesNotResurrectDeletedBookmarksOrMatchChangedFiles() {
        let oldItem = item(UUID()), currentItem = item(UUID())
        var old = LibraryState(books: [oldItem]), current = LibraryState(books: [currentItem])
        old.bookmarks[oldItem.id] = [Bookmark(id: "mark", offset: 3, note: "Saved")]
        current.deletedBookmarks.bury("mark")
        current.restorePortable(old)
        XCTAssertTrue(current.bookmarks[currentItem.id]?.isEmpty ?? true)
        let changed = LibraryState(books: [item(UUID(), bytes: 2000)])
        XCTAssertTrue(changed.portableMatches(old).isEmpty)
    }
    func testRestoreRecreatesSavedArrangementOnAnUntouchedLibrary() {
        let source = UUID(), destination = UUID()
        let files = ["Book/1.mp3", "Book/2.mp3"].map { ScannedFile(relativePath: $0, fileSize: 1000, modifiedAt: nil, metadata: AudioMetadata(duration: 60)) }
        let original = BookGrouper.group(.init(sourceID: source, sourceName: "Test", files: files, imagesByDirectory: [:]))[0].book
        let first = ManualGrouping.makeBook(template: original, tracks: [original.tracks[0]], title: "First")
        let second = ManualGrouping.makeBook(template: original, tracks: [original.tracks[1]], title: "Second")
        var old = LibraryState(sources: [.init(id: source, kind: .appDocuments, displayName: "Phone", addedAt: .now)], books: [first, second])
        old.manualGroupings = [.init(sourceID: source, copySourceIDs: [], original: [original], groups: [first, second])]
        old.progress[second.id] = PlaybackProgress(time: 9)
        var current = LibraryState(sources: [.init(id: destination, kind: .appDocuments, displayName: "Phone", addedAt: .now)],
                                   books: [ManualGrouping.rebase(original, source: destination)])
        current.restorePortable(old)
        XCTAssertEqual(current.books.count, 2)
        XCTAssertEqual(current.manualGroupings.count, 1)
        let restored = current.books.first { $0.syncKey == second.syncKey }
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored.flatMap { current.progress[$0.id]?.time }, 9)
        let existing = ManualGrouping.rebase(original, source: destination)
        var inUse = LibraryState(sources: current.sources, books: [existing])
        inUse.progress[existing.id] = PlaybackProgress(time: 20)
        inUse.restorePortable(old)
        XCTAssertEqual(inUse.books.count, 1)
        XCTAssertTrue(inUse.manualGroupings.isEmpty)
        XCTAssertEqual(inUse.progress[existing.id]?.time, 20)
        var malformed = old
        malformed.manualGroupings[0].groups.append(first)
        var untouched = LibraryState(sources: current.sources, books: [existing])
        untouched.restorePortable(malformed)
        XCTAssertTrue(untouched.manualGroupings.isEmpty, "A track cannot appear in two restored groups")
        XCTAssertEqual(untouched.books.count, 1)
    }

    func testSamePathInUnrelatedSourcesIsAmbiguous() {
        let oldItem = item(UUID())
        let old = LibraryState(books: [oldItem])
        let current = LibraryState(books: [item(UUID()), item(UUID())])
        XCTAssertTrue(current.portableMatches(old).isEmpty)
    }
}
