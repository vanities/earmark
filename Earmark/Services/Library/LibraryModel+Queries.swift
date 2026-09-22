import Foundation
import ShelfKit

extension LibraryModel {
    /// Everything not hidden — and remote books step aside once a downloaded copy exists.
    var visibleBooks: [Book] {
        let localPaths = Set(books.filter { source(for: $0)?.kind == .appDocuments }.map(\.relativePath))
        return books.filter { book in
            guard !hiddenBookIDs.contains(book.id) else { return false }
            if isRemote(book), localPaths.contains(book.relativePath) { return false }
            return true
        }
    }

    var hiddenBooks: [Book] {
        books.filter { hiddenBookIDs.contains($0.id) }
    }

    /// Started but not finished, most recently played first.
    var inProgressBooks: [Book] {
        visibleBooks
            .filter { book in
                guard let entry = progress[book.id] else { return false }
                return entry.hasStarted && !entry.isFinished
            }
            .sorted { (progress[$0.id]?.lastPlayedAt ?? .distantPast) > (progress[$1.id]?.lastPlayedAt ?? .distantPast) }
    }

    /// A remote (NAS) book mirroring the same relative path as a local one, if any.
    func remoteTwin(of book: Book) -> Book? {
        guard !isRemote(book) else { return nil }
        return books.first { isRemote($0) && $0.relativePath == book.relativePath }
    }

    /// The next unfinished book in the same series (by series index), for the end-of-book "Up Next"
    /// offer. Returns nil when the book isn't in a series or nothing follows it.
    func nextInSeries(after book: Book) -> Book? {
        guard let series = book.series?.normalizedForMatching, !series.isEmpty else { return nil }
        let author = book.author?.normalizedForMatching
        let currentIndex = book.seriesIndex ?? -.greatestFiniteMagnitude
        let candidates = visibleBooks.filter { other in
            other.id != book.id
                && other.series?.normalizedForMatching == series
                && (author == nil || other.author?.normalizedForMatching == author)
                && !(progress[other.id]?.isFinished ?? false)
                && (other.seriesIndex ?? -.greatestFiniteMagnitude) > currentIndex
        }
        return candidates.min { ($0.seriesIndex ?? .greatestFiniteMagnitude) < ($1.seriesIndex ?? .greatestFiniteMagnitude) }
    }

    func book(id: String) -> Book? {
        books.first { $0.id == id }
    }

    func books(inSource id: UUID) -> [Book] {
        visibleBooks.filter { $0.sourceID == id }
    }

    func isFinished(_ book: Book) -> Bool {
        progress[book.id]?.isFinished ?? false
    }

    func sorted(_ books: [Book], by sort: LibrarySort) -> [Book] {
        switch sort {
        case .recent:
            return books.sorted {
                let a = progress[$0.id]?.lastPlayedAt ?? $0.addedAt
                let b = progress[$1.id]?.lastPlayedAt ?? $1.addedAt
                return a > b
            }
        case .title:
            return books.sorted { $0.title.naturallyPrecedes($1.title) }
        case .author:
            return books.sorted {
                let a = $0.author ?? "\u{FFFF}", b = $1.author ?? "\u{FFFF}"
                if a != b { return a.naturallyPrecedes(b) }
                if let sa = $0.seriesIndex, let sb = $1.seriesIndex, $0.series == $1.series, sa != sb { return sa < sb }
                return $0.title.naturallyPrecedes($1.title)
            }
        case .added:
            return books.sorted { $0.addedAt > $1.addedAt }
        case .duration:
            return books.sorted { $0.totalDuration > $1.totalDuration }
        }
    }

    func groups(_ grouping: LibraryGrouping, from books: [Book]) -> [LibraryGroup] {
        switch grouping {
        case .all:
            return [LibraryGroup(id: "all", title: "All Books", subtitle: nil, books: books)]
        case .author:
            let buckets = Dictionary(grouping: books) { $0.author?.normalizedForMatching ?? "" }
            return buckets.map { key, members in
                let title = key.isEmpty ? "Unknown Author" : (members.first?.author ?? key)
                return LibraryGroup(id: "author:\(key)", title: title, subtitle: countLabel(members), books: sorted(members, by: .author))
            }.sorted { $0.title.naturallyPrecedes($1.title) }
        case .series:
            let inSeries = books.filter { $0.series != nil }
            let buckets = Dictionary(grouping: inSeries) { $0.series?.normalizedForMatching ?? "" }
            var groups = buckets.map { key, members in
                let ordered = members.sorted {
                    if let a = $0.seriesIndex, let b = $1.seriesIndex, a != b { return a < b }
                    return $0.title.naturallyPrecedes($1.title)
                }
                return LibraryGroup(id: "series:\(key)", title: members.first?.series ?? key, subtitle: members.first?.author, books: ordered)
            }.sorted { $0.title.naturallyPrecedes($1.title) }
            let standalone = books.filter { $0.series == nil }
            if !standalone.isEmpty {
                groups.append(LibraryGroup(id: "series:none", title: "Not in a Series", subtitle: countLabel(standalone), books: sorted(standalone, by: .title)))
            }
            return groups
        case .folder:
            let buckets = Dictionary(grouping: books) { book -> String in
                let top = book.relativePath.split(separator: "/").first.map(String.init) ?? ""
                return "\(book.sourceID.uuidString)/\(top)"
            }
            return buckets.map { key, members in
                let book = members[0]
                let top = book.relativePath.split(separator: "/").first.map(String.init)
                let sourceName = sourceName(for: book.sourceID)
                let title = top.map { "\(sourceName) › \($0)" } ?? sourceName
                return LibraryGroup(id: "folder:\(key)", title: title, subtitle: countLabel(members), books: sorted(members, by: .title))
            }.sorted { $0.title.naturallyPrecedes($1.title) }
        }
    }

    func search(_ query: String, in books: [Book]) -> [Book] {
        let needle = query.normalizedForMatching
        guard !needle.isEmpty else { return books }
        return books.filter { book in
            [book.title, book.author ?? "", book.series ?? "", book.narrator ?? ""]
                .contains { $0.normalizedForMatching.contains(needle) }
        }
    }

    private func countLabel(_ books: [Book]) -> String {
        books.count == 1 ? "1 book" : "\(books.count) books"
    }

    // MARK: Files and twins

    func url(forBook book: Book) -> URL? {
        guard let root = rootURL(for: book.sourceID), !isRemote(book) else { return nil }
        if book.kind == .singleFile, sources.first(where: { $0.id == book.sourceID })?.kind == .file {
            return root
        }
        return root.appending(path: book.relativePath)
    }

    func url(forTrack track: Track, in book: Book) -> URL? {
        guard let root = rootURL(for: book.sourceID), !isRemote(book) else { return nil }
        if sources.first(where: { $0.id == book.sourceID })?.kind == .file {
            return root
        }
        return root.appending(path: track.relativePath)
    }

    func sourceName(for id: UUID) -> String {
        sources.first { $0.id == id }?.displayName ?? "Unknown"
    }

    func source(for book: Book) -> LibrarySource? {
        sources.first { $0.id == book.sourceID }
    }

    /// A downloaded copy of a remote book, matched by its path relative to the library root.
    func localTwin(of book: Book) -> Book? {
        guard isRemote(book) else { return nil }
        return books.first { candidate in
            candidate.id != book.id && candidate.relativePath == book.relativePath && source(for: candidate)?.kind == .appDocuments
        }
    }
}
