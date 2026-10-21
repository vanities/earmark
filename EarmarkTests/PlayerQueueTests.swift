import AVFoundation
import XCTest
@testable import Earmark

/// Let real AVPlayer items reach their ends; queue policy must hold during a sleep fade too.
@MainActor
final class PlayerQueueTests: XCTestCase {
    func testNaturalBookEndStartsQueuedBookWhenAutoplayIsOn() async throws {
        try await withPlayer { player, library, settings, books in
            settings.autoplayQueue = true
            player.load(books[0], autoplay: false)
            try await self.eventually { !player.isLoading }
            player.enqueue(books[1])
            player.play()
            try await self.eventually { player.book?.id == books[1].id && player.isPlaying }
            XCTAssertTrue(library.isFinished(books[0]))
            XCTAssertTrue(player.queueKeys.isEmpty)
        }
    }

    func testNaturalBookEndOffersQueueWithoutPlayingWhenAutoplayIsOff() async throws {
        try await withPlayer { player, library, settings, books in
            settings.autoplayQueue = false
            player.load(books[0], autoplay: false)
            try await self.eventually { !player.isLoading }
            player.enqueue(books[1])
            player.play()
            try await self.eventually { library.isFinished(books[0]) }
            XCTAssertEqual(player.book?.id, books[0].id)
            XCTAssertEqual(player.upNext?.id, books[1].id)
            XCTAssertEqual(player.queueKeys, [books[1].syncKey])
            XCTAssertFalse(player.isPlaying)
        }
    }

    func testCountdownSleepDoesNotStartQueuedBookWhenAudioEndsDuringFade() async throws {
        try await withPlayer(firstDuration: 1.8) { player, library, settings, books in
            settings.autoplayQueue = true
            player.load(books[0], autoplay: false)
            try await self.eventually { !player.isLoading }
            player.enqueue(books[1])
            player.setSleepTimer(.duration(0.1))
            player.play()
            try await self.eventually { library.isFinished(books[0]) }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(player.book?.id, books[0].id)
            XCTAssertEqual(player.queueKeys, [books[1].syncKey])
            XCTAssertFalse(player.isPlaying)
        }
    }

    func testEndOfChapterSleepDoesNotStartQueuedBookWhenAudioEndsDuringFade() async throws {
        try await withPlayer { player, library, settings, books in
            settings.autoplayQueue = true
            player.load(books[0], autoplay: false)
            try await self.eventually { !player.isLoading }
            player.enqueue(books[1])
            player.setSleepTimer(.endOfChapter)
            player.play()
            // The first generated book is shorter than the fade, so its real end arrives first.
            try await self.eventually { library.isFinished(books[0]) }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(player.book?.id, books[0].id, "A sleep fade must not allow queue autoplay")
            XCTAssertEqual(player.queueKeys, [books[1].syncKey])
            XCTAssertFalse(player.isPlaying)
        }
    }

    func testEndOfChapterSleepDoesNotAutoplayTheNextTrackDuringFade() async throws {
        try await checkTrackBoundarySleep(.endOfChapter, duration: 1)
    }

    func testCountdownSleepDoesNotAutoplayTheNextTrackDuringFade() async throws {
        try await checkTrackBoundarySleep(.duration(0.1), duration: 1.8)
    }

    private func checkTrackBoundarySleep(_ mode: SleepTimerMode, duration: Double) async throws {
        try await withPlayer(firstDuration: duration, firstTrackCount: 2) { player, library, settings, books in
            settings.autoplayQueue = true
            player.load(books[0], autoplay: false)
            try await self.eventually { !player.isLoading }
            player.enqueue(books[1])
            player.setSleepTimer(mode)
            player.play()
            try await self.eventually { player.trackIndex == 1 && !player.isLoading }
            XCTAssertEqual(player.book?.id, books[0].id)
            XCTAssertFalse(player.isPlaying, "The end of a track must honor an in-progress sleep fade")
            XCTAssertEqual(player.currentTime, 0, accuracy: 0.1)
            XCTAssertFalse(library.isFinished(books[0]))
            XCTAssertEqual(player.queueKeys, [books[1].syncKey])
        }
    }

    func testCancellingSleepDuringFadeAllowsQueueAutoplayAgain() async throws {
        try await withPlayer { player, _, settings, books in
            settings.autoplayQueue = true
            player.load(books[0], autoplay: false)
            try await self.eventually { !player.isLoading }
            player.enqueue(books[1])
            player.setSleepTimer(.endOfChapter)
            player.play()
            try await self.eventually { player.sleepTimer == .off }
            player.setSleepTimer(.off) // Explicitly cancel the fade before the audio ends.
            try await self.eventually { player.book?.id == books[1].id && player.isPlaying }
            XCTAssertTrue(player.queueKeys.isEmpty)
        }
    }

    private func withPlayer(firstDuration: Double = 1, firstTrackCount: Int = 1,
                            _ body: (PlayerEngine, LibraryModel, AppSettings, [Book]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PlayerQueue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PlayerQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.smartRewind = false
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        var files: [ScannedFile] = []
        let generatedFiles = (1...firstTrackCount).map { ("First/\($0).wav", firstDuration) } + [("Second/1.wav", 8.0)]
        for (name, duration) in generatedFiles {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 8000)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<Int(buffer.frameLength) { samples[index] = 0.001 * sin(Float(index) * 0.1) }
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            files.append(ScannedFile(relativePath: name, fileSize: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
                                     modifiedAt: nil, metadata: AudioMetadata(duration: duration)))
        }
        let source = UUID()
        let books = BookGrouper.group(.init(sourceID: source, sourceName: "Generated queue fixtures", files: files, imagesByDirectory: [:]))
            .map(\.book).sorted { $0.title < $1.title }
        XCTAssertEqual(books.count, 2)
        guard books.count == 2 else { throw CocoaError(.coderInvalidValue) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: settings)
        library.sources = [.init(id: source, kind: .folder, displayName: "Generated queue fixtures", addedAt: .now)]
        library.resolvedRoots[source] = root
        library.books = books
        let player = PlayerEngine(library: library, settings: settings)
        defer { player.unload() }
        try await body(player, library, settings, books)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Real audio did not reach the expected queue boundary")
        throw CocoaError(.coderInvalidValue)
    }
}
