import Foundation
import os

/// The two public catalogs Find Cover and Look Up both ask: Apple's iTunes Search API and Open
/// Library. One request builder, one decoder and one fetch for each, so the two features can't
/// drift apart. Only ever called when the user taps — never in the background.
enum Catalogs {
    /// One iTunes Search result: an audiobook (`collection…`) or an ebook (`track…`).
    struct AppleItem: Decodable, Sendable {
        var collectionId: Int?
        var trackId: Int?
        var collectionName: String?
        var trackName: String?
        var artistName: String?
        var releaseDate: String?
        var artworkUrl100: String?
    }

    struct OpenLibraryDoc: Decodable, Sendable {
        var key: String?
        var title: String?
        var authorNames: [String]?
        var firstPublishYear: Int?
        var coverID: Int?

        enum CodingKeys: String, CodingKey {
            case key, title
            case authorNames = "author_name"
            case firstPublishYear = "first_publish_year"
            case coverID = "cover_i"
        }
    }

    // MARK: Requests

    /// `media` is "audiobook" or "ebook".
    static func appleURL(term: String, media: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "media", value: media),
                                  URLQueryItem(name: "limit", value: String(limit))]
        return components?.url
    }

    /// `query` is a free-text `q`, or `title` and `author`.
    static func openLibraryURL(_ query: [URLQueryItem], limit: Int) -> URL? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = query + [URLQueryItem(name: "limit", value: String(limit)),
                                          URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i")]
        return components?.url
    }

    /// Open Library cover sizes: "S", "M" or "L".
    static func openLibraryCoverURL(id: Int, size: String) -> URL? {
        URL(string: "https://covers.openlibrary.org/b/id/\(id)-\(size).jpg")
    }

    // MARK: Decoding

    private struct AppleResponse: Decodable { let results: [AppleItem] }
    private struct OpenLibraryResponse: Decodable { let docs: [OpenLibraryDoc] }

    static func appleItems(_ data: Data) -> [AppleItem] {
        do {
            return try JSONDecoder().decode(AppleResponse.self, from: data).results
        } catch {
            Logger.library.error("[catalogs] apple answer undecodable (\(data.count)B): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func openLibraryDocs(_ data: Data) -> [OpenLibraryDoc] {
        do {
            return try JSONDecoder().decode(OpenLibraryResponse.self, from: data).docs
        } catch {
            Logger.library.error("[catalogs] open library answer undecodable (\(data.count)B): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Fetching

    /// The body of a successful GET, or nil — every failure is logged, none is thrown.
    static func get(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        let sw = Stopwatch()
        let host = url.host() ?? "?"
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                Logger.library.error("[catalogs] \(host, privacy: .public) answered \(status)")
                return nil
            }
            Logger.library.debug("[catalogs] \(host, privacy: .public) \(data.count)B in \(sw.ms, format: .fixed(precision: 0))ms")
            return data
        } catch {
            Logger.library.error("[catalogs] \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
