import Foundation
import os

/// Security-scoped bookmarks let Earmark keep read access to folders the user picked
/// across launches without copying anything into the app sandbox.
enum BookmarkStore {
    struct Resolved: Sendable {
        var url: URL
        var isStale: Bool
        var didStartAccess: Bool
    }

    static func makeBookmark(for url: URL) throws -> Data {
        let sw = Stopwatch()
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        Logger.bookmarks.info("[bookmark] created for \(url.lastPathComponent, privacy: .public) bytes=\(data.count) in \(sw.ms, format: .fixed(precision: 1))ms")
        return data
    }

    /// Resolves the bookmark and starts security-scoped access. The caller owns the
    /// scope and must call `stopAccessingSecurityScopedResource()` when done with it.
    static func resolveAndStartAccess(_ data: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        let started = url.startAccessingSecurityScopedResource()
        Logger.bookmarks.info("[bookmark] resolved \(url.lastPathComponent, privacy: .public) stale=\(isStale) accessStarted=\(started)")
        return Resolved(url: url, isStale: isStale, didStartAccess: started)
    }
}
