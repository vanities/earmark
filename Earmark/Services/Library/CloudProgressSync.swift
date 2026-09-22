import Foundation
import os
import ShelfKit

/// Earmark's side of iCloud key-value storage: progress keyed by `Book.syncKey`, the reading
/// log, cover choices and bookmarks, one JSON value per key. The rules are ShelfKit's
/// `CloudKeyValueStore`, shared with Mango — a write that changes nothing is skipped (a book saves
/// its place every few seconds, and iCloud throttles an app that writes that often; this layer
/// used to write every time), and nothing over iCloud's size cap is written. No-ops without the
/// iCloud entitlement, so it never crashes — it just doesn't sync there.
@MainActor
final class CloudProgressSync {
    private let store = CloudKeyValueStore()
    private static let key = "progress.v1"
    private static let logKey = "readinglog.v1"
    /// syncKey → cover URL, as builds before cover choices wrote it. Still read, so their covers carry over.
    private static let legacyCoverKey = "covers.v1"
    private static let coverKey = "covers.v2"
    private static let bookmarksKey = "bookmarks.v1"
    /// Bookmark id → when it was deleted, so a deletion reaches every device.
    private static let deletedBookmarksKey = "bookmarks.deleted.v1"
    /// Device ID → that device's listening day totals (Mango's key and format; each device
    /// writes only its own slot, so adding them up never double-counts).
    private static let activityKey = "activity.v1"

    /// Called when another device changes the store.
    var onExternalChange: (() -> Void)? {
        get { store.onExternalChange }
        set { store.onExternalChange = newValue }
    }

    func start() {
        store.start()
    }

    func load() -> [String: PlaybackProgress] {
        store.load([String: PlaybackProgress].self, key: Self.key) ?? [:]
    }

    func save(_ snapshot: [String: PlaybackProgress]) {
        store.save(snapshot, key: Self.key)
    }

    func loadReadingLog() -> [ReadingLogEntry] {
        store.load([ReadingLogEntry].self, key: Self.logKey) ?? []
    }

    func saveReadingLog(_ entries: [ReadingLogEntry]) {
        store.save(entries, key: Self.logKey)
    }

    /// Cover choices by syncKey, with the old URL-only format folded in underneath (any real choice beats it).
    func loadCoverChoices() -> [String: CoverChoice] {
        var choices = store.load([String: String].self, key: Self.legacyCoverKey).map(CoverSync.legacyChoices) ?? [:]
        if let current = store.load([String: CoverChoice].self, key: Self.coverKey) {
            choices.merge(current) { _, new in new }
        }
        return choices
    }

    func saveCoverChoices(_ choices: [String: CoverChoice]) {
        store.save(choices, key: Self.coverKey)
    }

    func loadBookmarks() -> [String: [Bookmark]] {
        store.load([String: [Bookmark]].self, key: Self.bookmarksKey) ?? [:]
    }

    func saveBookmarks(_ bookmarks: [String: [Bookmark]]) {
        store.save(bookmarks, key: Self.bookmarksKey)
    }

    func loadDeletedBookmarks() -> Tombstones {
        store.load(Tombstones.self, key: Self.deletedBookmarksKey) ?? Tombstones()
    }

    func saveDeletedBookmarks(_ tombstones: Tombstones) {
        store.save(tombstones, key: Self.deletedBookmarksKey)
    }

    func loadActivity() -> [String: [String: DayActivity]] {
        store.load([String: [String: DayActivity]].self, key: Self.activityKey) ?? [:]
    }

    func saveActivity(_ activity: [String: [String: DayActivity]]) {
        store.save(activity, key: Self.activityKey)
    }
}
