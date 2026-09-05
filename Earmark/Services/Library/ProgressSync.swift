import Foundation

/// Pure merge logic for cross-device progress sync, kept separate from the iCloud transport so it
/// can be unit-tested. Conflicts resolve last-writer-wins by `lastPlayedAt`.
enum ProgressSync {
    private static func isNewer(_ a: PlaybackProgress, than b: PlaybackProgress?) -> Bool {
        guard let b else { return true }
        return (a.lastPlayedAt ?? .distantPast) > (b.lastPlayedAt ?? .distantPast)
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
