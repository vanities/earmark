import Foundation
import ShelfKit

/// Everything Earmark persists about the library, in one JSON document.
///
/// Decoding is lenient on purpose: every field falls back to its default when the key is
/// missing, so a build that adds a field can still read the file the previous build wrote.
/// (Synthesized `Codable` does *not* do this — a missing key fails the whole document, and
/// that once cost a test library its NAS server and progress.)
struct LibraryState: Codable, Sendable {
    var schemaVersion = 1
    var sources: [LibrarySource] = []
    var books: [Book] = []
    var progress: [String: PlaybackProgress] = [:]
    var hiddenBookIDs: Set<String> = []
    var lastBookID: String?
    var nasServers: [NASServer] = []
    /// Book ID → artwork ID chosen by the user via Find Cover. Survives rescans.
    var customArtwork: [String: String] = [:]
    /// Book syncKey → the cover the user picked (or went back from). Synced, so every device shows the same one.
    var coverChoices: [String: CoverChoice] = [:]
    /// Book ID → SHA-256 of the cover image Earmark wrote next to that book's audio, so it only ever
    /// replaces or deletes an image it wrote itself — never the user's own cover.jpg.
    var writtenCovers: [String: String] = [:]
    /// Book ID → user corrections to detected title/author/series/etc. Survives rescans.
    var metadataOverrides: [String: BookMetadataOverride] = [:]
    /// Book ID → saved spots. Survives rescans.
    var bookmarks: [String: [Bookmark]] = [:]
    /// Bookmarks deleted here or on another device, by id, so an iCloud merge can't bring them back.
    var deletedBookmarks = Tombstones()
    /// Books finished before/outside the app, for Stats history.
    var readingLog: [ReadingLogEntry] = []

    init(sources: [LibrarySource] = [], books: [Book] = [], progress: [String: PlaybackProgress] = [:],
         hiddenBookIDs: Set<String> = [], lastBookID: String? = nil, nasServers: [NASServer] = [],
         customArtwork: [String: String] = [:], coverChoices: [String: CoverChoice] = [:], writtenCovers: [String: String] = [:], metadataOverrides: [String: BookMetadataOverride] = [:], bookmarks: [String: [Bookmark]] = [:], readingLog: [ReadingLogEntry] = []) {
        self.sources = sources
        self.books = books
        self.progress = progress
        self.hiddenBookIDs = hiddenBookIDs
        self.lastBookID = lastBookID
        self.nasServers = nasServers
        self.customArtwork = customArtwork
        self.coverChoices = coverChoices
        self.writtenCovers = writtenCovers
        self.metadataOverrides = metadataOverrides
        self.bookmarks = bookmarks
        self.readingLog = readingLog
    }

    /// User state worth protecting: anything beyond the always-present Documents source.
    var hasUserData: Bool {
        !progress.isEmpty || !nasServers.isEmpty || !customArtwork.isEmpty || !coverChoices.isEmpty
            || sources.contains { $0.kind != .appDocuments }
    }

    /// Adds back user state from a library that an older build moved aside (see `LibraryStore`).
    /// `self` always wins on conflicts — it is the current, freshly-scanned library — so this only
    /// ever *restores* things the current file is missing: a NAS source and its server, saved
    /// progress, hidden flags, chosen covers. Books are intentionally not merged: they are rederived
    /// by the next scan once their source is back.
    mutating func merge(restoring old: LibraryState) {
        // The Documents source is a singleton created fresh on each install (its id differs), so it is
        // never restored — only real added sources (a folder or a NAS share) can go missing.
        let sourceIDs = Set(sources.map(\.id))
        sources.append(contentsOf: old.sources.filter { $0.kind != .appDocuments && !sourceIDs.contains($0.id) })
        let serverIDs = Set(nasServers.map(\.id))
        nasServers.append(contentsOf: old.nasServers.filter { !serverIDs.contains($0.id) })
        for (key, value) in old.progress where progress[key] == nil { progress[key] = value }
        for (key, value) in old.customArtwork where customArtwork[key] == nil { customArtwork[key] = value }
        for (key, value) in old.coverChoices where coverChoices[key] == nil { coverChoices[key] = value }
        for (key, value) in old.writtenCovers where writtenCovers[key] == nil { writtenCovers[key] = value }
        for (key, value) in old.metadataOverrides where metadataOverrides[key] == nil { metadataOverrides[key] = value }
        let logIDs = Set(readingLog.map(\.id))
        readingLog.append(contentsOf: old.readingLog.filter { !logIDs.contains($0.id) })
        deletedBookmarks = deletedBookmarks.merging(old.deletedBookmarks)
        for (key, oldList) in old.bookmarks {
            var list = bookmarks[key] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: oldList.filter { !known.contains($0.id) && !deletedBookmarks.contains($0.id) })
            bookmarks[key] = list.sorted { $0.offset < $1.offset }
        }
        hiddenBookIDs.formUnion(old.hiddenBookIDs)
        if lastBookID == nil { lastBookID = old.lastBookID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, books, progress, hiddenBookIDs, lastBookID, nasServers, customArtwork, coverChoices, writtenCovers, metadataOverrides, bookmarks, readingLog, deletedBookmarks
    }

    /// Fields older builds wrote that now live elsewhere; read once, never written.
    private enum LegacyKeys: String, CodingKey {
        /// syncKey → cover URL, before `coverChoices` carried a date and a kind.
        case customCoverURLs
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sources = try c.decodeIfPresent([LibrarySource].self, forKey: .sources) ?? []
        books = try c.decodeIfPresent([Book].self, forKey: .books) ?? []
        progress = try c.decodeIfPresent([String: PlaybackProgress].self, forKey: .progress) ?? [:]
        hiddenBookIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenBookIDs) ?? []
        lastBookID = try c.decodeIfPresent(String.self, forKey: .lastBookID)
        nasServers = try c.decodeIfPresent([NASServer].self, forKey: .nasServers) ?? []
        customArtwork = try c.decodeIfPresent([String: String].self, forKey: .customArtwork) ?? [:]
        coverChoices = try c.decodeIfPresent([String: CoverChoice].self, forKey: .coverChoices) ?? [:]
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let urls = try? legacy.decodeIfPresent([String: String].self, forKey: .customCoverURLs) {
            coverChoices = CoverSync.legacyChoices(urls).merging(coverChoices) { _, current in current }
        }
        writtenCovers = try c.decodeIfPresent([String: String].self, forKey: .writtenCovers) ?? [:]
        metadataOverrides = try c.decodeIfPresent([String: BookMetadataOverride].self, forKey: .metadataOverrides) ?? [:]
        bookmarks = try c.decodeIfPresent([String: [Bookmark]].self, forKey: .bookmarks) ?? [:]
        deletedBookmarks = try c.decodeIfPresent(Tombstones.self, forKey: .deletedBookmarks) ?? Tombstones()
        readingLog = try c.decodeIfPresent([ReadingLogEntry].self, forKey: .readingLog) ?? []
    }
}
