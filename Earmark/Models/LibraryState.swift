import Foundation

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
    /// Book ID → user corrections to detected title/author/series/etc. Survives rescans.
    var metadataOverrides: [String: BookMetadataOverride] = [:]
    /// Book ID → saved spots. Survives rescans.
    var bookmarks: [String: [Bookmark]] = [:]

    init(sources: [LibrarySource] = [], books: [Book] = [], progress: [String: PlaybackProgress] = [:],
         hiddenBookIDs: Set<String> = [], lastBookID: String? = nil, nasServers: [NASServer] = [],
         customArtwork: [String: String] = [:], metadataOverrides: [String: BookMetadataOverride] = [:], bookmarks: [String: [Bookmark]] = [:]) {
        self.sources = sources
        self.books = books
        self.progress = progress
        self.hiddenBookIDs = hiddenBookIDs
        self.lastBookID = lastBookID
        self.nasServers = nasServers
        self.customArtwork = customArtwork
        self.metadataOverrides = metadataOverrides
        self.bookmarks = bookmarks
    }

    /// User state worth protecting: anything beyond the always-present Documents source.
    var hasUserData: Bool {
        !progress.isEmpty || !nasServers.isEmpty || !customArtwork.isEmpty
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
        for (key, value) in old.metadataOverrides where metadataOverrides[key] == nil { metadataOverrides[key] = value }
        for (key, oldList) in old.bookmarks {
            var list = bookmarks[key] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: oldList.filter { !known.contains($0.id) })
            bookmarks[key] = list.sorted { $0.offset < $1.offset }
        }
        hiddenBookIDs.formUnion(old.hiddenBookIDs)
        if lastBookID == nil { lastBookID = old.lastBookID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, books, progress, hiddenBookIDs, lastBookID, nasServers, customArtwork, metadataOverrides, bookmarks
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
        metadataOverrides = try c.decodeIfPresent([String: BookMetadataOverride].self, forKey: .metadataOverrides) ?? [:]
        bookmarks = try c.decodeIfPresent([String: [Bookmark]].self, forKey: .bookmarks) ?? [:]
    }
}
