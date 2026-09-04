import Foundation
import os

/// Per-file tag cache keyed by source + relative path, invalidated by size or mtime
/// changes. Makes rescans of a big library take seconds instead of minutes.
actor MetadataCache {
    struct Entry: Codable, Sendable {
        var fileSize: Int64
        var modifiedAt: Date?
        var metadata: AudioMetadata
    }

    private let store: LibraryStore
    private var entries: [String: Entry]?
    private var dirty = false

    init(store: LibraryStore) {
        self.store = store
    }

    private func loadedEntries() -> [String: Entry] {
        if let entries { return entries }
        let loaded = store.loadJSON([String: Entry].self, named: LibraryStore.metadataCacheFile) ?? [:]
        Logger.metadata.info("[metadata-cache] loaded entries=\(loaded.count)")
        entries = loaded
        return loaded
    }

    func metadata(forKey key: String, fileSize: Int64, modifiedAt: Date?) -> AudioMetadata? {
        guard let entry = loadedEntries()[key], entry.fileSize == fileSize else { return nil }
        if let cached = entry.modifiedAt, let current = modifiedAt, abs(cached.timeIntervalSince(current)) > 1 {
            return nil
        }
        return entry.metadata
    }

    func store(_ metadata: AudioMetadata, forKey key: String, fileSize: Int64, modifiedAt: Date?) {
        var all = loadedEntries()
        all[key] = Entry(fileSize: fileSize, modifiedAt: modifiedAt, metadata: metadata)
        entries = all
        dirty = true
    }

    func removeEntries(withPrefix prefix: String) {
        var all = loadedEntries()
        let before = all.count
        all = all.filter { !$0.key.hasPrefix(prefix) }
        entries = all
        dirty = dirty || all.count != before
        Logger.metadata.info("[metadata-cache] removed \(before - all.count) entries for prefix")
    }

    func flush() {
        guard dirty, let entries else { return }
        do {
            try store.saveJSON(entries, named: LibraryStore.metadataCacheFile)
            dirty = false
        } catch {
            Logger.metadata.error("[metadata-cache] flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
