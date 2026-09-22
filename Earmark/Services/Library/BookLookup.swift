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
        async let apple = Catalogs.get(Catalogs.appleURL(term: terms, media: "audiobook", limit: 15))
        async let openLibrary = Catalogs.get(Catalogs.openLibraryURL([URLQueryItem(name: "q", value: terms)], limit: 10))
        let found = ((await apple).map(parseApple) ?? []) + ((await openLibrary).map(parseOpenLibrary) ?? [])
        let matches = relevant(found, to: terms)
        Logger.library.info("[lookup] \(matches.count) match(es) for \(terms, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        return matches
    }

    // MARK: Parsing

    static func parseApple(_ data: Data) -> [BookMatch] {
        Catalogs.appleItems(data).compactMap { item in
            guard let name = item.collectionName else { return nil }
            let parts = splitTitle(name)
            return BookMatch(id: "apple-\(item.collectionId ?? name.hashValue)", title: parts.title, author: item.artistName,
                             series: parts.series, seriesIndex: parts.index,
                             year: item.releaseDate.flatMap { Int($0.prefix(4)) },
                             artworkURL: item.artworkUrl100.flatMap(URL.init(string:)), source: "Apple Books")
        }
    }

    static func parseOpenLibrary(_ data: Data) -> [BookMatch] {
        Catalogs.openLibraryDocs(data).compactMap { doc in
            guard let title = doc.title else { return nil }
            return BookMatch(id: "openlibrary-\(doc.key ?? title)", title: title, author: doc.authorNames?.first,
                             series: nil, seriesIndex: nil, year: doc.firstPublishYear,
                             artworkURL: doc.coverID.flatMap { Catalogs.openLibraryCoverURL(id: $0, size: "S") },
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
