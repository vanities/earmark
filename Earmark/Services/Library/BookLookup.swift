import Foundation
import os
import ShelfKit

/// A book as a catalog knows it: what it's called, by whom, in which series.
struct BookMatch: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var author: String?
    var series: String?
    var seriesIndex: Double?
    var year: Int?
    var artworkURL: URL?
    var source: String

    init(id: String, title: String, author: String?, series: String? = nil, seriesIndex: Double? = nil,
         year: Int? = nil, artworkURL: URL?, source: String) {
        self.id = id
        self.title = title
        self.author = author
        self.series = series
        self.seriesIndex = seriesIndex
        self.year = year
        self.artworkURL = artworkURL
        self.source = source
    }
}

/// Look Up: fills a book's details from a real catalog, picked by the user. Sends the words
/// typed (a title and author) to Apple's iTunes Search API and to Open Library when tapped —
/// the same services, and the same words, as Find Cover. Never in the background.
///
/// Grounded on purpose: Mango tried Apple's on-device model for names and it made them up.
enum BookLookup {
    static func search(_ query: String) async -> [BookMatch] {
        let sw = Stopwatch()
        let terms = query.trimmingCharacters(in: .whitespaces)
        guard !terms.isEmpty else { return [] }
        async let apple = fetch(appleURL(terms), parse: parseApple)
        async let openLibrary = fetch(openLibraryURL(terms), parse: parseOpenLibrary)
        let matches = relevant((await apple) + (await openLibrary), to: terms)
        Logger.library.info("[lookup] \(matches.count) match(es) for \(terms, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        return matches
    }

    // MARK: Requests

    static func appleURL(_ terms: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: terms), URLQueryItem(name: "media", value: "audiobook"),
                                  URLQueryItem(name: "limit", value: "15")]
        return components?.url
    }

    static func openLibraryURL(_ terms: String) -> URL? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [URLQueryItem(name: "q", value: terms), URLQueryItem(name: "limit", value: "10"),
                                  URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i")]
        return components?.url
    }

    private static func fetch(_ url: URL?, parse: @Sendable (Data) -> [BookMatch]) async -> [BookMatch] {
        guard let url else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return [] }
            return parse(data)
        } catch {
            Logger.library.error("[lookup] \(url.host() ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Parsing

    private struct AppleResponse: Decodable {
        struct Item: Decodable {
            let collectionId: Int?
            let collectionName: String?
            let artistName: String?
            let releaseDate: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    static func parseApple(_ data: Data) -> [BookMatch] {
        guard let response = try? JSONDecoder().decode(AppleResponse.self, from: data) else { return [] }
        return response.results.compactMap { item in
            guard let name = item.collectionName else { return nil }
            let parts = splitTitle(name)
            return BookMatch(id: "apple-\(item.collectionId ?? name.hashValue)", title: parts.title, author: item.artistName,
                             series: parts.series, seriesIndex: parts.index,
                             year: item.releaseDate.flatMap { Int($0.prefix(4)) },
                             artworkURL: item.artworkUrl100.flatMap(URL.init(string:)), source: "Apple Books")
        }
    }

    private struct OpenLibraryResponse: Decodable {
        struct Doc: Decodable {
            let key: String?
            let title: String?
            let author_name: [String]?   // swiftlint:disable:this identifier_name
            let first_publish_year: Int? // swiftlint:disable:this identifier_name
            let cover_i: Int?            // swiftlint:disable:this identifier_name
        }
        let docs: [Doc]
    }

    static func parseOpenLibrary(_ data: Data) -> [BookMatch] {
        guard let response = try? JSONDecoder().decode(OpenLibraryResponse.self, from: data) else { return [] }
        return response.docs.compactMap { doc in
            guard let title = doc.title else { return nil }
            return BookMatch(id: "openlibrary-\(doc.key ?? title)", title: title, author: doc.author_name?.first,
                             series: nil, seriesIndex: nil, year: doc.first_publish_year,
                             artworkURL: doc.cover_i.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-S.jpg") },
                             source: "Open Library")
        }
    }

    /// "The Way of Kings: The Stormlight Archive, Book 1 (Unabridged)" → "The Way of Kings",
    /// "The Stormlight Archive", 1. Edition tags go; a subtitle that isn't a series stays.
    static func splitTitle(_ name: String) -> (title: String, series: String?, index: Double?) {
        let cleaned = name.replacingOccurrences(of: #"\s*[\(\[](un)?abridged[\)\]]\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^(?<title>.+?):\s*(?<series>.+?),\s*(?:Book|Volume|Vol\.|Part)\s*(?<index>\d+(?:\.\d+)?)$"#,
            #"^(?<title>.+?)\s*\((?<series>.+?),?\s*(?:Book|Volume|Vol\.|#)\s*(?<index>\d+(?:\.\d+)?)\)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  let title = Range(match.range(withName: "title"), in: cleaned),
                  let series = Range(match.range(withName: "series"), in: cleaned),
                  let index = Range(match.range(withName: "index"), in: cleaned) else { continue }
            return (String(cleaned[title]), String(cleaned[series]), Double(cleaned[index]))
        }
        return (cleaned, nil, nil)
    }

    /// Apple lists an audiobook's artist as "Author & Narrator". When the part before "&" is the
    /// author already known, the rest is the narrator; otherwise it's left whole for the user.
    static func splitArtist(_ artist: String, knownAuthor: String) -> (author: String, narrator: String?) {
        let parts = artist.components(separatedBy: " & ")
        guard parts.count >= 2, !knownAuthor.isEmpty,
              parts[0].normalizedForMatching == knownAuthor.normalizedForMatching else { return (artist, nil) }
        return (parts[0], parts.dropFirst().joined(separator: " & "))
    }

    /// Catalogs answer loosely ("Dune" finds dune buggy manuals): a match must contain every word
    /// searched in its title, series or author. Duplicates across the two catalogs are dropped.
    static func relevant(_ matches: [BookMatch], to terms: String) -> [BookMatch] {
        let words = Set(terms.normalizedForMatching.split(separator: " ").map(String.init))
        var seen = Set<String>()
        return matches.filter { match in
            let text = [match.title, match.series, match.author].compactMap { $0 }.joined(separator: " ").normalizedForMatching
            let have = Set(text.split(separator: " ").map(String.init))
            let key = "\(match.title.normalizedForMatching)|\(match.author?.normalizedForMatching ?? "")"
            return words.isSubset(of: have) && seen.insert(key).inserted
        }
    }
}
