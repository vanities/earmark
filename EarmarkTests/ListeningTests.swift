import XCTest
import ShelfKit
@testable import Earmark

/// Stats' time, streak and habit cards count only time a book actually played — not a stall,
/// not a paused book, and not the few seconds of checking where you were.
final class ListeningRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func play(_ recorder: inout ListeningRecorder, book: String = "dune", from start: TimeInterval, to end: TimeInterval) {
        var t = start
        while t <= end {
            _ = recorder.tick(bookID: book, bookKey: book, title: book.capitalized, now: at(t))
            t += 0.5
        }
    }

    func testCountsTheTimeAudioPlayed() throws {
        var recorder = ListeningRecorder()
        play(&recorder, from: 0, to: 60)
        let session = try XCTUnwrap(recorder.finish())
        XCTAssertEqual(session.activeSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(session.startedAt, t0)
        XCTAssertEqual(session.bookTitle, "Dune")
        XCTAssertNil(recorder.open, "finishing closes it")
    }

    /// Buffering stops the playhead and the ticks; the gap only counts up to a few seconds.
    func testAStallIsNotListening() throws {
        var recorder = ListeningRecorder()
        play(&recorder, from: 0, to: 30)
        play(&recorder, from: 50, to: 80)
        XCTAssertEqual(try XCTUnwrap(recorder.finish()).activeSeconds, 60 + ListeningRecorder.maxGap, accuracy: 0.01)
    }

    /// Playback that stopped without the player saying so: the next tick, minutes later, ends
    /// that session where it stopped rather than stretching it (and its day) across the pause.
    func testALongGapEndsTheSession() throws {
        var recorder = ListeningRecorder()
        play(&recorder, from: 0, to: 30)
        let first = try XCTUnwrap(recorder.tick(bookID: "dune", bookKey: "dune", title: "Dune", now: at(3600)))
        XCTAssertEqual(first.activeSeconds, 30, accuracy: 0.01)
        XCTAssertEqual(first.startedAt, t0)
        play(&recorder, from: 3600.5, to: 3630)
        let second = try XCTUnwrap(recorder.finish())
        XCTAssertEqual(second.startedAt, at(3600))
        XCTAssertEqual(second.activeSeconds, 30, accuracy: 0.01)
    }

    func testAFewSecondsIsNotASession() {
        var recorder = ListeningRecorder()
        play(&recorder, from: 0, to: 10)
        XCTAssertNil(recorder.finish())
    }

    /// Another book starting mid-stream closes the first book's session on its own.
    func testAnotherBookClosesTheFirstOnesSession() throws {
        var recorder = ListeningRecorder()
        play(&recorder, book: "dune", from: 0, to: 40)
        let finished = try XCTUnwrap(recorder.tick(bookID: "emma", bookKey: "emma", title: "Emma", now: at(41)))
        XCTAssertEqual(finished.bookID, "dune")
        XCTAssertEqual(finished.activeSeconds, 40, accuracy: 0.01)
        XCTAssertEqual(recorder.open?.bookID, "emma")
    }

    /// The app killed mid-book: the last checkpoint is counted at the next launch, once.
    func testACheckpointIsCountedOnceNextLaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ListeningRecorderTests-\(UUID().uuidString)"))
        var recorder = ListeningRecorder()
        play(&recorder, from: 0, to: 90)
        ListeningCheckpoint.save(recorder.open, defaults: defaults)
        let recovered = try XCTUnwrap(ListeningCheckpoint.take(defaults: defaults))
        XCTAssertEqual(recovered.activeSeconds, 90, accuracy: 0.01)
        XCTAssertNil(ListeningCheckpoint.take(defaults: defaults), "only once")
        ListeningCheckpoint.save(nil, defaults: defaults)
        XCTAssertNil(ListeningCheckpoint.take(defaults: defaults))
    }

    /// A book's copies (on the NAS, downloaded) are one book in "most time spent in".
    func testSessionsGroupByTheBookNotTheCopy() {
        let nas = ListeningSession(bookID: "nas|Dune|", bookKey: "dune", bookTitle: "Dune", startedAt: t0, activeSeconds: 600)
        let download = ListeningSession(bookID: "local|Dune|", bookKey: "dune", bookTitle: "Dune", startedAt: at(3600), activeSeconds: 300)
        let stats = ActivityStats.build(days: DayKey.rollUp([nas, download]), sessions: [nas, download])
        XCTAssertEqual(stats.topByTime.map(\.name), ["Dune"])
        XCTAssertEqual(stats.topByTime.first?.seconds, 900)
        XCTAssertNil(stats.pagesPerMinute, "an audiobook has no pages")
    }
}

/// Sessions live in the library file: older files have none, and a restore brings them back.
final class ListeningStateCompatTests: XCTestCase {
    func testALibraryWithoutSessionsStillDecodes() throws {
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        XCTAssertTrue(state.sessions.isEmpty)
    }

    func testSessionsRoundTripAndComeBackFromAMovedAsideLibrary() throws {
        let session = ListeningSession(bookID: "b", bookKey: "k", bookTitle: "Dune",
                                       startedAt: Date(timeIntervalSince1970: 1_800_000_000), activeSeconds: 120)
        var state = LibraryState()
        state.sessions = [session]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LibraryState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded.sessions, [session])

        var fresh = LibraryState()
        fresh.merge(restoring: decoded)
        XCTAssertEqual(fresh.sessions, [session])
        fresh.merge(restoring: decoded)
        XCTAssertEqual(fresh.sessions.count, 1, "restored once, not twice")
    }
}
