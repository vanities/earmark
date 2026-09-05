import Foundation
import os

/// Per-file tag cache keyed by source + relative path, invalidated by size or mtime
/// changes. Makes rescans of a big library take seconds instead of minutes.
actor MetadataCache {
    struct Entry: Codable, Sendable {
        var fileSize: Int64
        var modifiedAt: Date?
        var metadata: AudioMetadata
        /// Container sniffed from the file header during a remote scan ("mp3", "mp4"). Kept with the
        /// tags so a cache hit still knows a misnamed file's real type; `nil` for older entries.
        var containerHint: String?
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
        entry(forKey: key, fileSize: fileSize, modifiedAt: modifiedAt)?.metadata
    }

    /// The whole cached entry (tags + container hint), or `nil` when the file changed size or mtime.
    func entry(forKey key: String, fileSize: Int64, modifiedAt: Date?) -> Entry? {
        guard let entry = loadedEntries()[key], entry.fileSize == fileSize else { return nil }
        if let cached = entry.modifiedAt, let current = modifiedAt, abs(cached.timeIntervalSince(current)) > 1 {
            return nil
        }
        return entry
    }

    func store(_ metadata: AudioMetadata, forKey key: String, fileSize: Int64, modifiedAt: Date?, containerHint: String? = nil) {
        var all = loadedEntries()
        all[key] = Entry(fileSize: fileSize, modifiedAt: modifiedAt, metadata: metadata, containerHint: containerHint)
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
