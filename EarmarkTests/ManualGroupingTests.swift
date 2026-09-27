import XCTest
@testable import Earmark

final class ManualGroupingTests: XCTestCase {
    private func book() -> Book {
        let source = UUID()
        let files = ["Book/01.mp3", "Book/02.mp3", "Book/03.mp3"].map {
            ScannedFile(relativePath: $0, fileSize: 1000, modifiedAt: nil, metadata: AudioMetadata(duration: 60))
        }
        return BookGrouper.group(.init(sourceID: source, sourceName: "Test", files: files, imagesByDirectory: [:]))[0].book
    }
    func testReorderingMovesPositionAndBookmarkByTrackAndUndoKeepsThem() {
        let original = book()
        let reordered = ManualGrouping.makeBook(template: original, tracks: Array(original.tracks.reversed()), title: original.title)
        var state = LibraryState(books: [original])
        var progress = PlaybackProgress(); progress.trackIndex = 0; progress.time = 17; progress.lastPlayedAt = .now
        state.progress[original.id] = progress
        state.bookmarks[original.id] = [Bookmark(id: "mark", offset: 12, note: "Keep this")]
        state.metadataOverrides[original.id] = .init(author: "Correct author")
        state.hiddenBookIDs.insert(original.id)
        state.lastBookID = original.id
        state.bookLists = [BookList(name: "Trip", items: [original.syncKey])]
        state.regroup(from: [original], to: [reordered])
        XCTAssertEqual(state.progress[reordered.id]?.trackIndex, 2)
        XCTAssertEqual(state.progress[reordered.id]?.time, 17)
        XCTAssertEqual(state.bookmarks[reordered.id]?.first?.offset, 132)
        XCTAssertEqual(state.metadataOverrides[reordered.id]?.author, "Correct author")
        XCTAssertTrue(state.hiddenBookIDs.contains(reordered.id))
        XCTAssertEqual(state.lastBookID, reordered.id)
        XCTAssertEqual(state.bookLists[0].items, [reordered.syncKey])
        state.regroup(from: [reordered], to: [original])
        XCTAssertEqual(state.progress[original.id]?.trackIndex, 0)
        XCTAssertEqual(state.bookmarks[original.id]?.first?.offset, 12)
        XCTAssertEqual(state.bookmarks[original.id]?.first?.note, "Keep this")
    }
    func testSplitSendsBookmarkAndCurrentPositionToCorrectPart() {
        let original = book()
        let first = ManualGrouping.makeBook(template: original, tracks: [original.tracks[0]], title: "First")
        let second = ManualGrouping.makeBook(template: original, tracks: Array(original.tracks.dropFirst()), title: "Second")
        var state = LibraryState()
        var progress = PlaybackProgress(); progress.trackIndex = 2; progress.time = 9; progress.lastPlayedAt = .now
        state.progress[original.id] = progress; state.lastBookID = original.id
        state.bookmarks[original.id] = [Bookmark(id: "one", offset: 20), Bookmark(id: "two", offset: 80)]
        state.regroup(from: [original], to: [first, second])
        XCTAssertEqual(state.progress[second.id]?.trackIndex, 1)
        XCTAssertEqual(state.progress[second.id]?.time, 9)
        XCTAssertEqual(state.lastBookID, second.id)
        XCTAssertEqual(state.bookmarks[first.id]?.map(\.id), ["one"])
        XCTAssertEqual(state.bookmarks[second.id]?.first?.offset, 20)
    }
    func testRuleSurvivesRescanAndAppliesToDownloadedTwin() {
        let original = book(), local = UUID()
        let reordered = ManualGrouping.makeBook(template: original, tracks: Array(original.tracks.reversed()), title: "Chosen title")
        let rule = ManualGrouping(sourceID: original.sourceID, copySourceIDs: [local], original: [original], groups: [reordered])
        let copy = ManualGrouping.rebase(original, source: local)
        let result = rule.applied(to: [copy], source: local)
        XCTAssertEqual(result[0].tracks.map(\.relativePath), reordered.tracks.map(\.relativePath))
        XCTAssertEqual(result[0].syncKey, reordered.syncKey)
        XCTAssertEqual(result[0].sourceID, local)
        XCTAssertEqual(result[0].chapters.map(\.trackIndex), [0, 1, 2])
    }
}
