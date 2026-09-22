import Foundation
import ShelfKit

/// Pure merge logic for cross-device progress sync, kept separate from the iCloud transport so it
/// can be unit-tested. Conflicts resolve last-writer-wins by `PlaybackProgress.syncStamp`.
enum ProgressSync {
    private static func isNewer(_ a: PlaybackProgress, than b: PlaybackProgress?) -> Bool {
        guard let b else { return true }
        return a.syncStamp > b.syncStamp
    }

    /// Local progress with any newer cloud entries folded in. Cloud is keyed by `Book.syncKey`;
    /// a cloud entry updates every local book sharing that key (a book and its downloaded twin).
    static func merged(local: [String: PlaybackProgress], books: [Book], cloud: [String: PlaybackProgress]) -> [String: PlaybackProgress] {
        guard !cloud.isEmpty else { return local }
        var result = local
        var idsByKey: [String: [String]] = [:]
        for book in books { idsByKey[book.syncKey, default: []].append(book.id) }
        for (key, cloudEntry) in cloud {
            guard let ids = idsByKey[key] else { continue }
            for id in ids where isNewer(cloudEntry, than: result[id]) {
                result[id] = cloudEntry
            }
        }
        return result
    }

    /// The snapshot to write to the cloud: the existing cloud with local entries overlaid wherever
    /// the local copy is newer. Preserves cloud entries for books not present on this device.
    static func cloudSnapshot(local: [String: PlaybackProgress], books: [Book], existingCloud: [String: PlaybackProgress]) -> [String: PlaybackProgress] {
        var cloud = existingCloud
        var keyByID: [String: String] = [:]
        for book in books { keyByID[book.id] = book.syncKey }
        for (id, entry) in local {
            guard let key = keyByID[id] else { continue }
            if isNewer(entry, than: cloud[key]) { cloud[key] = entry }
        }
        return cloud
    }
}

/// Bookmarks across devices: every device's, each once (this device's copy wins a clash),
/// minus any deleted on any of them — a plain union brought deleted ones back, because the
/// other side still had them. Keyed by `Book.syncKey` in the cloud, like progress.
enum BookmarkSync {
    static func merged(local: [String: [Bookmark]], books: [Book], cloud: [String: [Bookmark]],
                       buried: Tombstones) -> [String: [Bookmark]] {
        var result = local
        for book in books {
            guard let remote = cloud[book.syncKey], !remote.isEmpty else { continue }
            result[book.id] = UnionSync.merge(result[book.id] ?? [], remote, without: buried)
        }
        for (id, list) in result {
            let kept = list.filter { !buried.contains($0.id) }.sorted { $0.offset < $1.offset }
            result[id] = kept.isEmpty ? nil : kept
        }
        return result
    }

    static func snapshot(local: [String: [Bookmark]], books: [Book], existingCloud: [String: [Bookmark]],
                         buried: Tombstones) -> [String: [Bookmark]] {
        var cloud = existingCloud.mapValues { $0.filter { !buried.contains($0.id) } }.filter { !$0.value.isEmpty }
        let keyByID = Dictionary(books.map { ($0.id, $0.syncKey) }, uniquingKeysWith: { first, _ in first })
        for (id, marks) in local {
            guard let key = keyByID[id] else { continue }
            let merged = UnionSync.merge(cloud[key] ?? [], marks, without: buried)
            cloud[key] = merged.isEmpty ? nil : merged
        }
        return cloud
    }
}
