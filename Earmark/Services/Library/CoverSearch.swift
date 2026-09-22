import Foundation
import os

/// A cover art candidate from an online catalog.
struct CoverCandidate: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var author: String?
    var thumbnailURL: URL
    var fullURL: URL
    var source: String
}

/// Looks up cover art for a book. Only runs when the user taps "Find Cover"; sends the title
/// and author to Apple's iTunes Search API (audiobooks + ebooks) and Open Library.
enum CoverSearch {
    static func search(title: String, author: String?) async -> [CoverCandidate] {
        let sw = Stopwatch()
        let query = [title, author].compactMap { $0 }.joined(separator: " ")
        var byTitle = [URLQueryItem(name: "title", value: title)]
        if let author { byTitle.append(URLQueryItem(name: "author", value: author)) }
        async let audiobooks = Catalogs.get(Catalogs.appleURL(term: query, media: "audiobook", limit: 10))
        async let ebooks = Catalogs.get(Catalogs.appleURL(term: query, media: "ebook", limit: 10))
        async let openLibrary = Catalogs.get(Catalogs.openLibraryURL(byTitle, limit: 10))
        let found = ((await audiobooks).map { appleCandidates($0, media: "audiobook", query: query) } ?? [])
            + ((await ebooks).map { appleCandidates($0, media: "ebook", query: query) } ?? [])
            + ((await openLibrary).map { openLibraryCandidates($0, title: title) } ?? [])
        var seen = Set<URL>()
        let results = found.filter { seen.insert($0.fullURL).inserted }
        Logger.artwork.info("[covers] \(results.count) candidates for \(query, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        return results
    }

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Parsing

    /// Apple's 100px artwork URL also serves 1200px when asked for it by name.
    static func appleCandidates(_ data: Data, media: String, query: String) -> [CoverCandidate] {
        Catalogs.appleItems(data).enumerated().compactMap { index, item in
            guard let art = item.artworkUrl100, let thumb = URL(string: art) else { return nil }
            let full = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) ?? thumb
            return CoverCandidate(id: "apple-\(media)-\(item.collectionId ?? item.trackId ?? index)",
                                  title: item.collectionName ?? item.trackName ?? query, author: item.artistName,
                                  thumbnailURL: thumb, fullURL: full,
                                  source: media == "audiobook" ? "Apple Books · Audiobook" : "Apple Books")
        }
    }

    static func openLibraryCandidates(_ data: Data, title: String) -> [CoverCandidate] {
        Catalogs.openLibraryDocs(data).compactMap { doc in
            guard let cover = doc.coverID, let thumb = Catalogs.openLibraryCoverURL(id: cover, size: "M"),
                  let full = Catalogs.openLibraryCoverURL(id: cover, size: "L") else { return nil }
            return CoverCandidate(id: "openlibrary-\(cover)", title: doc.title ?? title, author: doc.authorNames?.first,
                                  thumbnailURL: thumb, fullURL: full, source: "Open Library")
        }
    }
}
