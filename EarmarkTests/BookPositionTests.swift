import XCTest
@testable import Earmark

final class BookPositionTests: XCTestCase {
    private func makeBook() -> Book {
        let sourceID = UUID()
        let tracks = [
            Track(relativePath: "b/1.mp3", fileName: "1.mp3", title: nil, duration: 100, fileSize: 1, modifiedAt: nil, trackNumber: 1, discNumber: nil),
            Track(relativePath: "b/2.mp3", fileName: "2.mp3", title: nil, duration: 200, fileSize: 1, modifiedAt: nil, trackNumber: 2, discNumber: nil),
            Track(relativePath: "b/3.mp3", fileName: "3.mp3", title: nil, duration: 50, fileSize: 1, modifiedAt: nil, trackNumber: 3, discNumber: nil),
        ]
        let chapters = [
            Chapter(title: "One", trackIndex: 0, start: 0, duration: 100),
            Chapter(title: "Two A", trackIndex: 1, start: 0, duration: 120),
            Chapter(title: "Two B", trackIndex: 1, start: 120, duration: 80),
            Chapter(title: "Three", trackIndex: 2, start: 0, duration: 50),
        ]
        return Book(id: Book.makeID(sourceID: sourceID, relativePath: "b"), sourceID: sourceID, relativePath: "b", kind: .folder, title: "B", author: nil, series: nil, seriesIndex: nil, narrator: nil, year: nil, tracks: tracks, chapters: chapters, artworkID: nil, addedAt: .now, totalBytes: 3)
    }

    func testOffsetsRoundTrip() {
        let book = makeBook()
        XCTAssertEqual(book.totalDuration, 350)
        XCTAssertEqual(book.trackStartOffsets, [0, 100, 300])
        XCTAssertEqual(book.absoluteOffset(trackIndex: 1, time: 30), 130)
        let position = book.position(atAbsoluteOffset: 130)
        XCTAssertEqual(position.trackIndex, 1)
        XCTAssertEqual(position.time, 30)
        XCTAssertEqual(book.position(atAbsoluteOffset: 999).trackIndex, 2)
        XCTAssertEqual(book.position(atAbsoluteOffset: -5).time, 0)
    }

    func testChapterLookup() {
        let book = makeBook()
        XCTAssertEqual(book.chapterIndex(trackIndex: 0, time: 10), 0)
        XCTAssertEqual(book.chapterIndex(trackIndex: 1, time: 119.9), 1)
        XCTAssertEqual(book.chapterIndex(trackIndex: 1, time: 120), 2)
        XCTAssertEqual(book.chapterIndex(trackIndex: 2, time: 60), 3, "time past the end of the last chapter in a track still resolves to it")
        XCTAssertEqual(book.absoluteOffset(of: book.chapters[2]), 220)
    }

    func testProgressFractionAndRemaining() {
        let book = makeBook()
        var progress = PlaybackProgress(trackIndex: 1, time: 75)
        XCTAssertEqual(progress.fraction(of: book), 0.5, accuracy: 0.0001)
        XCTAssertEqual(progress.remaining(in: book), 175)
        progress.isFinished = true
        XCTAssertEqual(progress.fraction(of: book), 1)
        XCTAssertEqual(progress.remaining(in: book), 0)
    }

    func testSmartRewindTiers() {
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 10), 0)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 120), 3)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 900), 8)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 3600), 15)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 86400), 30)
    }
}
