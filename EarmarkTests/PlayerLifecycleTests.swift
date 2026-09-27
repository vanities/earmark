import AVFoundation
import XCTest
@testable import Earmark

/// Exercises AVPlayer and the notification handlers, not just the position calculations.
@MainActor
final class PlayerLifecycleTests: XCTestCase {
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
