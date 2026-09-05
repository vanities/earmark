import XCTest
@testable import Earmark

/// Old library files must keep decoding when a build adds fields — and a file an older build
/// moved aside as "corrupt" must be recovered once the decoder understands it again.
final class LibraryStateCompatTests: XCTestCase {
    /// A library.json as written before `customArtwork` (and, earlier, `nasServers`) existed.
    private let legacyJSON = """
    {"books":[],"hiddenBookIDs":[],"progress":{"src|Book|k":{"isFinished":false,"time":42.5,"trackIndex":1}},
     "schemaVersion":1,
     "sources":[{"addedAt":"2026-09-01T12:00:00Z","displayName":"On My iPhone","id":"6A2E6E2B-1111-4F1B-9C2B-000000000001","kind":"appDocuments"},
                {"addedAt":"2026-09-02T12:00:00Z","displayName":"NAS","id":"6A2E6E2B-2222-4F1B-9C2B-000000000002","kind":"smb",
                 "serverID":"6A2E6E2B-3333-4F1B-9C2B-000000000003"}]}
    """

    func testDecodesLibraryWrittenByOlderBuild() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LibraryState.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(state.sources.count, 2)
        XCTAssertEqual(state.sources.last?.kind, .smb)
        XCTAssertEqual(state.progress["src|Book|k"]?.time, 42.5)
        XCTAssertTrue(state.nasServers.isEmpty)
        XCTAssertTrue(state.customArtwork.isEmpty)
        XCTAssertTrue(state.hasUserData)
    }

    func testEmptyDocumentDecodesToDefaults() throws {
        let state = try JSONDecoder().decode(LibraryState.self, from: Data("{}".utf8))
        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertFalse(state.hasUserData)
    }

    func testMergesBackLostSourceAndProgressFromMovedAsideFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        try Data(legacyJSON.utf8).write(to: dir.appending(path: "library.json.corrupt-1700000000"))
        // What a fresh launch of the new build saved after the old file was moved aside: just Documents.
        var fresh = LibraryState()
        fresh.sources = [LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My iPhone", bookmark: nil, addedAt: .now)]
        try store.saveLibrary(fresh)

        let loaded = store.loadLibrary()
        XCTAssertEqual(loaded.sources.count, 2, "the NAS source comes back")
        XCTAssertEqual(loaded.sources.last?.kind, .smb)
        XCTAssertEqual(loaded.progress.count, 1, "progress comes back")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertTrue(names.contains("library.json.recovered-1700000000"), "\(names)")
        XCTAssertFalse(names.contains("library.json.corrupt-1700000000"))
        // Second load is a no-op: the moved-aside file was already consumed.
        XCTAssertEqual(store.loadLibrary().sources.count, 2)
    }

    /// The bug that actually shipped: the fresh library had a single chosen cover, so an all-or-nothing
    /// recovery decided it was "real" and never restored the NAS server. Merge must still bring it back.
    func testRestoresNASEvenWhenFreshLibraryAlreadyHasSomeData() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        try Data(legacyJSON.utf8).write(to: dir.appending(path: "library.json.corrupt-1700000000"))
        var fresh = LibraryState()
        fresh.sources = [LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My iPhone", bookmark: nil, addedAt: .now)]
        fresh.customArtwork = ["some|book|id": "artwork-1"]   // makes hasUserData true
        try store.saveLibrary(fresh)

        let loaded = store.loadLibrary()
        XCTAssertTrue(loaded.sources.contains { $0.kind == .smb }, "NAS restored despite existing cover")
        XCTAssertEqual(loaded.customArtwork["some|book|id"], "artwork-1", "the chosen cover is kept")
        XCTAssertEqual(loaded.progress.count, 1)
    }

    func testCurrentWinsOnConflictButMissingKeysAreRestored() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        try Data(legacyJSON.utf8).write(to: dir.appending(path: "library.json.corrupt-1700000000"))
        var live = LibraryState()
        live.sources = [LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My iPhone", bookmark: nil, addedAt: .now)]
        live.progress["src|Book|k"] = PlaybackProgress(trackIndex: 9, time: 999)  // same key as legacy, fresher
        try store.saveLibrary(live)

        let loaded = store.loadLibrary()
        XCTAssertEqual(loaded.progress["src|Book|k"]?.time, 999, "current progress wins the conflict")
        XCTAssertTrue(loaded.sources.contains { $0.kind == .smb }, "the missing NAS source is still restored")
    }

    func testUnreadableFileIsRenamedSoItIsNotRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        try Data("{ this is not json".utf8).write(to: dir.appending(path: "library.json.corrupt-1700000000"))
        _ = store.loadLibrary()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains("library.json.unreadable-1700000000"), "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("library.json.corrupt-") })
    }

}

final class MetadataCacheHintTests: XCTestCase {
    func testContainerHintSurvivesTheCacheAndOldEntriesStillDecode() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earmark-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)
        let cache = MetadataCache(store: store)
        let tags = AudioMetadata(duration: 3_600, title: "City of Dragons")
        await cache.store(tags, forKey: "src|City of Dragons.m4b", fileSize: 10, modifiedAt: nil, containerHint: "mp3")
        await cache.flush()

        let reloaded = MetadataCache(store: store)
        let entry = await reloaded.entry(forKey: "src|City of Dragons.m4b", fileSize: 10, modifiedAt: nil)
        XCTAssertEqual(entry?.containerHint, "mp3")
        XCTAssertEqual(entry?.metadata.title, "City of Dragons")
        let stale = await reloaded.entry(forKey: "src|City of Dragons.m4b", fileSize: 11, modifiedAt: nil)
        XCTAssertNil(stale, "a size change invalidates the entry")

        // An entry written by a build that didn't know about hints.
        let legacy = """
        {"src|old.mp3":{"fileSize":5,"metadata":\(String(decoding: try JSONEncoder().encode(tags), as: UTF8.self))}}
        """
        try Data(legacy.utf8).write(to: dir.appending(path: LibraryStore.metadataCacheFile))
        let old = await MetadataCache(store: store).entry(forKey: "src|old.mp3", fileSize: 5, modifiedAt: nil)
        XCTAssertNotNil(old)
        XCTAssertNil(old?.containerHint)
    }
}
