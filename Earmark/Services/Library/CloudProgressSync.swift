import Foundation
import os
import ShelfKit

/// Thin wrapper over iCloud key-value storage that holds one JSON blob of progress keyed by
/// `Book.syncKey`. No-ops safely when the iCloud entitlement isn't present (device builds before
/// the capability is enabled), so it never crashes — it just doesn't sync there.
@MainActor
final class CloudProgressSync {
    private let store = NSUbiquitousKeyValueStore.default
    private static let key = "progress.v1"
    private static let logKey = "readinglog.v1"
    /// syncKey → cover URL, as builds before cover choices wrote it. Still read, so their covers carry over.
    private static let legacyCoverKey = "covers.v1"
    private static let coverKey = "covers.v2"
    private static let bookmarksKey = "bookmarks.v1"
    /// Bookmark id → when it was deleted, so a deletion reaches every device.
    private static let deletedBookmarksKey = "bookmarks.deleted.v1"
    private static let maxBytes = 900_000  // KVS caps a value near 1 MB; stay under it.
    private var observer: (any NSObjectProtocol)?
    /// Called when another device changes the store.
    var onExternalChange: (() -> Void)?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
        store.synchronize()
    }

    func load() -> [String: PlaybackProgress] {
        guard let data = store.data(forKey: Self.key) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: PlaybackProgress].self, from: data)) ?? [:]
    }

    func loadReadingLog() -> [ReadingLogEntry] {
        guard let data = store.data(forKey: Self.logKey) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ReadingLogEntry].self, from: data)) ?? []
    }

    func saveReadingLog(_ entries: [ReadingLogEntry]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries), data.count <= Self.maxBytes else { return }
        store.set(data, forKey: Self.logKey)
        store.synchronize()
    }

    /// Cover choices by syncKey, with the old URL-only format folded in underneath (any real choice beats it).
    func loadCoverChoices() -> [String: CoverChoice] {
        var choices: [String: CoverChoice] = [:]
        if let data = store.data(forKey: Self.legacyCoverKey),
           let urls = try? JSONDecoder().decode([String: String].self, from: data) {
            choices = CoverSync.legacyChoices(urls)
        }
        if let data = store.data(forKey: Self.coverKey) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let current = try? decoder.decode([String: CoverChoice].self, from: data) {
                choices.merge(current) { _, new in new }
            } else {
                Logger.store.error("[cloud] cover choices bytes=\(data.count) undecodable — ignoring")
            }
        }
        return choices
    }

    func saveCoverChoices(_ choices: [String: CoverChoice]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(choices), data.count <= Self.maxBytes else {
            Logger.store.error("[cloud] cover choices too large or unencodable — not syncing")
            return
        }
        store.set(data, forKey: Self.coverKey)
        store.synchronize()
    }

    func loadBookmarks() -> [String: [Bookmark]] {
        loadJSON([String: [Bookmark]].self, Self.bookmarksKey) ?? [:]
    }

    func saveBookmarks(_ bookmarks: [String: [Bookmark]]) {
        saveJSON(bookmarks, Self.bookmarksKey)
    }

    func loadDeletedBookmarks() -> Tombstones {
        loadJSON(Tombstones.self, Self.deletedBookmarksKey) ?? Tombstones()
    }

    func saveDeletedBookmarks(_ tombstones: Tombstones) {
        saveJSON(tombstones, Self.deletedBookmarksKey)
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger.store.error("[cloud] \(key, privacy: .public) bytes=\(data.count) undecodable — ignoring")
            return nil
        }
    }

    /// Skips identical writes: KVS rate-limits chatty apps, and most saves change nothing here.
    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), data.count <= Self.maxBytes else {
            Logger.store.error("[cloud] \(key, privacy: .public) too large or unencodable — not syncing")
            return
        }
        guard store.data(forKey: key) != data else { return }
        store.set(data, forKey: key)
        store.synchronize()
    }

    func save(_ snapshot: [String: PlaybackProgress]) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        guard data.count <= Self.maxBytes else {
            Logger.store.error("[cloud] progress snapshot \(data.count) bytes exceeds KVS limit — not syncing")
            return
        }
        store.set(data, forKey: Self.key)
        store.synchronize()
    }
}
