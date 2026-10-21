import AVFoundation
import XCTest
@testable import Earmark

/// Exercises AVPlayer and the notification handlers, not just the position calculations.
@MainActor
final class PlayerLifecycleTests: XCTestCase {
    func testChapterTapAtFractionalBoundaryKeepsSelectedChapter() async throws {
        try await withPlayer(embeddedChapters: true) { player, books in
            let book = try XCTUnwrap(books.first { $0.tracks.count == 3 })
            player.load(book, autoplay: false)
            try await self.eventually { !player.isLoading }
            for index in [1, 3, 1, 3] {
                player.jump(to: book.chapters[index])
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertEqual(player.currentChapterIndex, index, "chapter start=\(book.chapters[index].start) actual=\(player.currentTime)")
                player.seek(toChapterTime: 3)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(player.currentChapterIndex, index, "Seeking must be relative to the chosen chapter")
                XCTAssertEqual(player.chapterElapsed, 3, accuracy: 0.1)
            }
        }
    }

    func testChapterChangesFollowedBySeekingKeepTheSelectedChapter() async throws {
        try await withPlayer(embeddedChapters: true) { player, books in
            let book = try XCTUnwrap(books.first { $0.tracks.count == 3 })
            player.load(book, autoplay: false)
            try await self.eventually { !player.isLoading }
            // Exercise the same chapter-relative commands as the Now Playing sheet,
            // allowing AVPlayer callbacks between the chapter tap and slider release.
            for turn in 0..<60 {
                let index = turn.isMultiple(of: 2) ? 4 : 1
                player.jump(to: book.chapters[index])
                try await Task.sleep(for: .milliseconds(5))
                player.seek(toChapterTime: 3)
                for sample in 0..<8 {
                    try await Task.sleep(for: .milliseconds(5))
                    XCTAssertEqual(player.currentChapterIndex, index, "turn=\(turn) sample=\(sample) time=\(player.currentTime)")
                    XCTAssertEqual(player.chapterElapsed, 3, accuracy: 0.1, "turn=\(turn) sample=\(sample)")
                }
            }
        }
    }

    func testTrackChangesFollowedBySeekingKeepTheSelectedChapter() async throws {
        try await withPlayer(embeddedChapters: true) { player, books in
            let book = try XCTUnwrap(books.first { $0.tracks.count == 3 })
            player.load(book, autoplay: false)
            try await self.eventually { !player.isLoading }
            for turn in 0..<20 {
                let index = turn.isMultiple(of: 2) ? 10 : 1
                player.jump(to: book.chapters[index])
                try await self.eventually { !player.isLoading }
                player.seek(toChapterTime: 3)
                for sample in 0..<8 {
                    try await Task.sleep(for: .milliseconds(5))
                    XCTAssertEqual(player.currentChapterIndex, index, "turn=\(turn) sample=\(sample) time=\(player.currentTime)")
                    XCTAssertEqual(player.chapterElapsed, 3, accuracy: 0.1, "turn=\(turn) sample=\(sample)")
                }
            }
        }
    }

    func testPlayingChapterChangesFollowedBySeekingKeepTheSelectedChapter() async throws {
        try await withPlayer(embeddedChapters: true) { player, books in
            let book = try XCTUnwrap(books.first { $0.tracks.count == 3 })
            player.load(book, autoplay: true)
            try await self.eventually { player.isPlaying && player.currentTime > 0.2 }
            for turn in 0..<40 {
                let index = turn.isMultiple(of: 2) ? 4 : 1
                player.jump(to: book.chapters[index])
                if turn.isMultiple(of: 2) { try await Task.sleep(for: .milliseconds(5)) }
                player.seek(toChapterTime: 3)
                for sample in 0..<8 {
                    try await Task.sleep(for: .milliseconds(5))
                    XCTAssertEqual(player.currentChapterIndex, index, "turn=\(turn) sample=\(sample) time=\(player.currentTime)")
                    XCTAssertEqual(player.chapterElapsed, 3, accuracy: 0.3, "turn=\(turn) sample=\(sample)")
                }
            }
            XCTAssertTrue(player.isPlaying)
        }
    }

    func testSeekingAsTheInitialTrackBecomesReadyPreservesAutoplay() async throws {
        try await withPlayer(embeddedChapters: true) { player, books in
            let book = try XCTUnwrap(books.first { $0.tracks.count == 3 })
            var redirected = false
            player.stateDidChange = {
                guard !player.isLoading, !redirected else { return }
                redirected = true
                player.jump(to: book.chapters[4])
                player.seek(toChapterTime: 3)
            }
            defer { player.stateDidChange = nil }
            player.load(book, autoplay: true)
            try await self.eventually { player.isPlaying && player.currentTime > 43.1 }
            XCTAssertTrue(redirected)
            XCTAssertEqual(player.currentChapterIndex, 4)
        }
    }

    func testPauseWhileLoadingCancelsPendingAutoplay() async throws {
        try await withPlayer { player, books in
            player.load(books[0], autoplay: true)
            XCTAssertTrue(player.isLoading)
            player.pause()
            try await self.eventually { !player.isLoading }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(player.isPlaying, "A pause before the file is ready must cancel its queued play")
        }
    }

    func testInterruptionWhileLoadingDefersAutoplayUntilResume() async throws {
        try await withPlayer { player, books in
            player.load(books[0], autoplay: true)
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await self.eventually { !player.isLoading }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(player.isPlaying, "Loading must not start audio during an interruption")
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
            try await self.eventually { player.isPlaying }
        }
    }

    func testHeadphoneDisconnectWhileLoadingCancelsAutoplay() async throws {
        try await withPlayer { player, books in
            player.load(books[0], autoplay: true)
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                                            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            try await self.eventually { !player.isLoading }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(player.isPlaying, "A queued file must not start on the speaker after headphones disconnect")
        }
    }

    func testUserPauseDuringAnInterruptionCancelsAutomaticResume() async throws {
        try await withPlayer { player, books in
            player.load(books[0], autoplay: true)
            try await self.eventually { player.isPlaying }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            player.pause()
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                       AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(player.isPlaying, "An explicit Pause overrides the system's later resume suggestion")
        }
    }

    func testUnavailableBookStopsThePreviousAudioAndKeepsItsRequestedPosition() async throws {
        try await withPlayer { player, books in
            player.load(books[0], autoplay: true)
            try await self.eventually { player.isPlaying && player.currentTime > 0.5 }
            var unavailable = books[1]
            unavailable.sourceID = UUID() // A cached book whose source is no longer configured.
            player.load(unavailable, autoplay: true, startAt: BookPosition(trackIndex: 0, time: 20))
            XCTAssertNotNil(player.errorMessage)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.trackIndex, 0)
            XCTAssertEqual(player.currentTime, 20, accuracy: 0.1,
                           "An unavailable source must not leave the previous AVPlayer item running or lose the retry position")
        }
    }

    func testSwitchingBooksDuringSleepFadeDoesNotPauseTheNewBook() async throws {
        try await withPlayer { player, books in
            player.load(books[0], autoplay: true)
            try await self.eventually { player.isPlaying }
            player.setSleepTimer(.duration(0.1))
            try await self.eventually { player.sleepTimer == .off }
            player.load(books[1], autoplay: true)
            try await self.eventually { !player.isLoading && player.isPlaying }
            try await Task.sleep(for: .seconds(3))
            XCTAssertEqual(player.book?.id, books[1].id)
            XCTAssertTrue(player.isPlaying, "The old book's fade must not pause a different book")
        }
    }

    func testSkipsCrossEveryTrackInBothDirections() async throws {
        try await withPlayer { player, books in
            let book = try XCTUnwrap(books.first { $0.tracks.count == 3 })
            player.load(book, autoplay: false)
            try await self.eventually { !player.isLoading }
            player.skip(by: 130)
            try await self.eventually { !player.isLoading }
            XCTAssertEqual(player.trackIndex, 2)
            XCTAssertEqual(player.currentTime, 10, accuracy: 0.2)
            player.skip(by: -100)
            try await self.eventually { !player.isLoading }
            XCTAssertEqual(player.trackIndex, 0)
            XCTAssertEqual(player.currentTime, 30, accuracy: 0.2)
            XCTAssertFalse(player.isPlaying, "Skipping a paused book must not start playback")
        }
    }

    private func withPlayer(embeddedChapters: Bool = false, _ body: (PlayerEngine, [Book]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.smartRewind = false
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0.001 * sin(Float(index) * 0.1) }
        var files: [ScannedFile] = []
        for name in ["First/01.wav", "First/02.wav", "First/03.wav", "Second/01.wav"] {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            files.append(ScannedFile(relativePath: name, fileSize: 1, modifiedAt: nil, metadata: AudioMetadata(duration: 60)))
        }
        let source = UUID()
        var books = BookGrouper.group(.init(sourceID: source, sourceName: "Test", files: files, imagesByDirectory: [:])).map(\.book)
        if embeddedChapters {
            for index in books.indices {
                books[index].chapters = books[index].tracks.indices.flatMap { track in
                    (0..<6).map { chapter in
                        Chapter(title: "Chapter \(track * 6 + chapter + 1)", trackIndex: track,
                                start: Double(chapter) * 10.000375, duration: chapter == 5 ? 60 - 50.001875 : 10.000375)
                    }
                }
            }
        }
        XCTAssertEqual(books.count, 2)
        guard books.count == 2 else { throw CocoaError(.coderInvalidValue) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: settings)
        library.sources = [.init(id: source, kind: .folder, displayName: "Test", addedAt: .now)]
        library.resolvedRoots[source] = root
        library.books = books
        let player = PlayerEngine(library: library, settings: settings)
        defer { player.unload() }
        try await body(player, books)
    }

    func testPresetsInterruptionsRouteLossAndSleepPersistListening() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PlayerLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.smartRewind = false
        let url = root.appending(path: "test.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 720000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0.001 * sin(Float(index) * 0.1) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let source = UUID()
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let files = [ScannedFile(relativePath: "test.wav", fileSize: Int64(bytes), modifiedAt: nil, metadata: AudioMetadata(duration: 90))]
        let book = try XCTUnwrap(BookGrouper.group(.init(sourceID: source, sourceName: "Test", files: files, imagesByDirectory: [:])).first?.book)
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: settings)
        library.sources = [.init(id: source, kind: .folder, displayName: "Test", addedAt: .now)]
        library.resolvedRoots[source] = root
        library.books = [book]
        let player = PlayerEngine(library: library, settings: settings)
        defer { player.unload() }
        player.load(book, autoplay: false)
        try await eventually { !player.isLoading }
        XCTAssertNil(player.errorMessage)
        player.applyPreset(.init(id: "test", name: "Test", speed: 1.5, boostQuiet: false, volumeBoost: 1,
                                 skipSilence: false, sleepMinutes: 1))
        XCTAssertFalse(player.isPlaying, "Applying a preset must not start playback")
        XCTAssertEqual(player.speed, 1.5)
        XCTAssertEqual(player.sleepTimer, .duration(60))
        player.play()
        // Sessions shorter than fifteen wall-clock seconds are intentionally discarded.
        try await eventually { player.currentTime > 27 }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await eventually { !player.isPlaying }
        XCTAssertFalse(library.sessions.isEmpty)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        try await eventually { player.isPlaying }
        let resumed = player.currentTime
        try await eventually { player.currentTime > resumed + 27 }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await eventually { !player.isPlaying }
        let stopped = player.currentTime
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(player.currentTime, stopped, accuracy: 0.6)
        player.setSleepTimer(.duration(17))
        player.play()
        try await eventually { player.currentTime > stopped + 1 }
        try await eventually { !player.isPlaying }
        XCTAssertEqual(player.sleepTimer, .off)
        XCTAssertGreaterThan(library.progress(for: book.id).time, stopped)
        XCTAssertGreaterThanOrEqual(library.sessions.count, 3)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<350 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Playback condition was not reached within thirty-five seconds")
        throw CocoaError(.coderInvalidValue)
    }
}
