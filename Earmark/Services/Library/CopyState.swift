import Foundation

/// What the listener did to a book, as it follows the book from one copy to another — a NAS
/// book and its download, or a picked folder's book and the one moved into Earmark's folder.
/// Kept apart from `LibraryModel` so the rules are tested; the model reads and writes it whole.
struct CopyState: Equatable {
    var progress: [String: PlaybackProgress]
    var bookmarks: [String: [Bookmark]]
    var corrections: [String: BookMetadataOverride]
    var hidden: Set<String>
    var lastBookID: String?

    /// One copy leaves the library and another stays: a download is removed (the NAS copy stays),
    /// or a book moves into Earmark's folder (the moved copy stays). The staying copy gets the
    /// newer place, both copies' bookmarks, the leaving copy's corrections over its own — that's
    /// the copy the listener was looking at — hidden, and "last played". The leaving copy's go.
    mutating func handOver(from old: String, to new: String) {
        progress[new] = DownloadRemoval.place(from: progress[old], onto: progress[new])
        if let marks = bookmarks[old] { bookmarks[new] = DownloadRemoval.bookmarks(from: marks, onto: bookmarks[new] ?? []) }
        if let leaving = corrections[old] { corrections[new] = (corrections[new] ?? BookMetadataOverride()).merged(with: leaving) }
        if hidden.remove(old) != nil { hidden.insert(new) }
        if lastBookID == old { lastBookID = new }
        progress[old] = nil
        bookmarks[old] = nil
        corrections[old] = nil
    }

    /// A new copy arrived — a download landed — and its twin stays: the new copy fills its gaps
    /// from the twin (anything it already has is its own). Returns whether anything came over.
    @discardableResult
    mutating func adopt(into new: String, from twin: String) -> Bool {
        var changed = false
        if progress[new] == nil, let carried = progress[twin] { progress[new] = carried; changed = true }
        if bookmarks[new] == nil, let marks = bookmarks[twin] { bookmarks[new] = marks; changed = true }
        if corrections[new] == nil, let override = corrections[twin] { corrections[new] = override; changed = true }
        // Hiding the NAS copy hides its download too, or the book reappears the moment it lands.
        if hidden.contains(twin), hidden.insert(new).inserted { changed = true }
        // Continue Listening follows the copy that's on the shelf now.
        if lastBookID == twin { lastBookID = new; changed = true }
        return changed
    }

    /// The NAS copy each newly arrived book came from: the same `syncKey`, or — when grouping
    /// gave the two different keys — the same path, if exactly one NAS book has it. A folder
    /// holding several books is ambiguous by path, and a wrong twin is worse than none.
    /// `downloaded` names the NAS books just downloaded: when two shares hold the same book,
    /// the one it actually came from wins.
    static func remoteTwins(of arrivals: [Book], among remote: [Book], downloaded: Set<String> = []) -> [(arrival: Book, twin: Book)] {
        let ordered = remote.filter { downloaded.contains($0.id) } + remote.filter { !downloaded.contains($0.id) }
        let byKey = Dictionary(ordered.map { ($0.syncKey, $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(grouping: ordered, by: \.relativePath)
        return arrivals.compactMap { book in
            if let twin = byKey[book.syncKey] { return (book, twin) }
            guard let sharing = byPath[book.relativePath] else { return nil }
            if let source = sharing.first(where: { downloaded.contains($0.id) }) { return (book, source) }
            return sharing.count == 1 ? (book, sharing[0]) : nil
        }
    }
}
