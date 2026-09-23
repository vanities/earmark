import AVFoundation
import XCTest
@testable import Earmark

/// End-to-end: real files on disk → walk → tags → books. Uses tiny generated AAC files.
final class LibraryScannerTests: XCTestCase {
    private var root: URL!
    private var storeDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "scanner-\(UUID().uuidString)")
        storeDir = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeDir)
    }

    private func writeSilence(_ relativePath: String, seconds: Double = 1.0) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let frames = AVAudioFrameCount(22050 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    private func scan() async throws -> ScanResult {
        let store = LibraryStore(directory: storeDir)
        let scanner = LibraryScanner(cache: MetadataCache(store: store), artwork: ArtworkStore(directory: storeDir.appending(path: "art")))
        let source = LibrarySource(id: UUID(), kind: .folder, displayName: "Test", bookmark: nil, addedAt: .now)
        return try await scanner.scan(source: source, root: root) { _ in }
    }

    /// "Open With Earmark" on one audio file makes a source of just that file: its root *is* the
    /// file. Reading its tags at root + name ("Loomings.wav/Loomings.wav") failed, so it was listed
    /// as Unknown Author, 0m, with no cover.
    func testAFileOpenedOnItsOwnIsRead() async throws {
        try writeSilence("Moby-Dick/Loomings.wav", seconds: 2.0)
        let file = root.appending(path: "Moby-Dick/Loomings.wav")
        let store = LibraryStore(directory: storeDir)
        let scanner = LibraryScanner(cache: MetadataCache(store: store), artwork: ArtworkStore(directory: storeDir.appending(path: "art")))
        let source = LibrarySource(id: UUID(), kind: .file, displayName: "Loomings.wav", bookmark: nil, addedAt: .now)

        let result = try await scanner.scan(source: source, root: file) { _ in }
        let book = try XCTUnwrap(result.books.first)
        XCTAssertEqual(result.books.count, 1)
        XCTAssertEqual(book.title, "Loomings")
        XCTAssertEqual(book.totalDuration, 2.0, accuracy: 0.15, "the file's own length, read from the file itself")
    }

    func testScanGroupsRealFilesAndReadsDurations() async throws {
        try writeSilence("Jane Austen/Emma/01 - Chapter 1.wav", seconds: 1.0)
        try writeSilence("Jane Austen/Emma/02 - Chapter 2.wav", seconds: 1.5)
        try writeSilence("Mary Shelley/Frankenstein.wav", seconds: 2.0)
        try FileManager.default.createDirectory(at: root.appending(path: "Ignored"), withIntermediateDirectories: true)
        try Data(repeating: 0x4F, count: 2048).write(to: root.appending(path: "Ignored/notes.ogg"))
        try "not audio".write(to: root.appending(path: "Jane Austen/Emma/README.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: ".hidden"), withIntermediateDirectories: true)
        try writeSilence(".hidden/secret.wav")

        let result = try await scan()
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.unsupportedFiles, ["Ignored/notes.ogg"])
        XCTAssertEqual(result.books.count, 2)

        let emma = try XCTUnwrap(result.books.first { $0.title == "Emma" })
        XCTAssertEqual(emma.author, "Jane Austen")
        XCTAssertEqual(emma.tracks.count, 2)
        XCTAssertEqual(emma.tracks[0].relativePath, "Jane Austen/Emma/01 - Chapter 1.wav")
        XCTAssertEqual(emma.tracks[0].duration, 1.0, accuracy: 0.15)
        XCTAssertEqual(emma.tracks[1].duration, 1.5, accuracy: 0.15)
        XCTAssertEqual(emma.chapters.map(\.title), ["Chapter 1", "Chapter 2"])

        let frankenstein = try XCTUnwrap(result.books.first { $0.title == "Frankenstein" })
        XCTAssertEqual(frankenstein.kind, .singleFile)
        XCTAssertEqual(frankenstein.author, "Mary Shelley")
        XCTAssertEqual(frankenstein.totalDuration, 2.0, accuracy: 0.15)
    }

    func testSecondScanHitsMetadataCacheAndKeepsIDs() async throws {
        try writeSilence("Book/01.wav")
        try writeSilence("Book/02.wav")
        let first = try await scan()
        let store = LibraryStore(directory: storeDir)
        let cached = store.loadJSON([String: MetadataCache.Entry].self, named: LibraryStore.metadataCacheFile)
        XCTAssertEqual(cached?.count, 2, "metadata cache should be flushed after a scan")
        let second = try await scan()
        XCTAssertEqual(first.books.map(\.relativePath), second.books.map(\.relativePath))
        XCTAssertEqual(second.books[0].tracks.map(\.duration), first.books[0].tracks.map(\.duration))
    }
}
