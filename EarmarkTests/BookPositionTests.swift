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

    func testResumeRewindCrossesTrackBoundaryAndClampsAtBookStart() {
        let book = makeBook()
        let target = PlayerEngine.resumePosition(in: book, from: BookPosition(trackIndex: 1, time: 2), pausedFor: 3600)
        XCTAssertEqual(target.trackIndex, 0)
        XCTAssertEqual(target.time, 87)
        let start = PlayerEngine.resumePosition(in: book, from: BookPosition(trackIndex: 0, time: 5), pausedFor: 86400)
        XCTAssertEqual(start.time, 0)
        let quick = PlayerEngine.resumePosition(in: book, from: BookPosition(trackIndex: 1, time: 2), pausedFor: 10)
        XCTAssertEqual(quick.trackIndex, 1)
        XCTAssertEqual(quick.time, 2)
    }

    func testSmartRewindTiers() {
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 10), 0)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 120), 3)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 900), 8)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 3600), 15)
        XCTAssertEqual(PlayerEngine.smartRewindAmount(pausedFor: 86400), 30)
    }

    /// What decides whether opening Earmark goes to Now Playing.
    func testRecentlyPlayedIsPlayingOrPlayedInTheLastCoupleOfHours() {
        let now = Date()
        func recent(_ progress: PlaybackProgress, playing: Bool = false, upNext: Bool = false) -> Bool {
            PlayerEngine.isRecentlyPlayed(isPlaying: playing, progress: progress, hasUpNext: upNext, now: now)
        }
        var progress = PlaybackProgress(trackIndex: 0, time: 30)
        XCTAssertTrue(recent(progress, playing: true))
        XCTAssertFalse(recent(progress), "never played")
        progress.lastPlayedAt = now.addingTimeInterval(-10 * 60)
        XCTAssertTrue(recent(progress), "paused ten minutes ago")
        progress.lastPlayedAt = now.addingTimeInterval(-3 * 3600)
        XCTAssertFalse(recent(progress), "last played this morning")
        progress.lastPlayedAt = now.addingTimeInterval(-10 * 60)
        progress.isFinished = true
        XCTAssertFalse(recent(progress), "finished, with nothing to play next")
        XCTAssertTrue(recent(progress, upNext: true), "finished, with Up Next waiting")
    }

    func testOnlyLongJumpsOfferUndo() {
        XCTAssertFalse(PlayerEngine.isUndoableJump(from: 600, to: 629), "a small scrub isn't worth an undo")
        XCTAssertTrue(PlayerEngine.isUndoableJump(from: 600, to: 1_800), "a chapter tap forward")
        XCTAssertTrue(PlayerEngine.isUndoableJump(from: 1_800, to: 0), "a scrub back to the start")
    }

    func testEndOfChapterFadeStartsSoThePauseLandsOnTheBoundary() {
        // The fade takes 2.5 s of wall time, which covers more of the chapter at higher speeds.
        XCTAssertFalse(PlayerEngine.shouldStartChapterFade(remaining: 3.0, speed: 1))
        XCTAssertTrue(PlayerEngine.shouldStartChapterFade(remaining: 2.4, speed: 1))
        XCTAssertTrue(PlayerEngine.shouldStartChapterFade(remaining: 4.9, speed: 2), "2x speed: 5 s of audio fades in 2.5 s")
        XCTAssertFalse(PlayerEngine.shouldStartChapterFade(remaining: 5.1, speed: 2))
    }
}
