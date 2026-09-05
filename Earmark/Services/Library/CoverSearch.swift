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
        async let apple = appleCandidates(query: query)
        async let openLibrary = openLibraryCandidates(title: title, author: author)
        var seen = Set<URL>()
        var results: [CoverCandidate] = []
        for candidate in (await apple) + (await openLibrary) where !seen.contains(candidate.fullURL) {
            seen.insert(candidate.fullURL)
            results.append(candidate)
        }
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

    // MARK: - Apple (iTunes Search)

    private struct AppleResponse: Decodable {
        struct Item: Decodable {
            let collectionName: String?
            let trackName: String?
            let artistName: String?
            let artworkUrl100: String?
            let collectionId: Int?
            let trackId: Int?
        }
        let results: [Item]
    }

    private static func appleCandidates(query: String) async -> [CoverCandidate] {
        var out: [CoverCandidate] = []
        for media in ["audiobook", "ebook"] {
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: query),
                URLQueryItem(name: "media", value: media),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components.url else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(AppleResponse.self, from: data)
                for item in decoded.results {
                    guard let art = item.artworkUrl100, let thumb = URL(string: art) else { continue }
                    let full = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) ?? thumb
                    let name = item.collectionName ?? item.trackName ?? query
                    out.append(CoverCandidate(id: "apple-\(media)-\(item.collectionId ?? item.trackId ?? out.count)", title: name, author: item.artistName, thumbnailURL: thumb, fullURL: full, source: media == "audiobook" ? "Apple Books · Audiobook" : "Apple Books"))
                }
            } catch {
                Logger.artwork.error("[covers] apple \(media, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return out
    }

    // MARK: - Open Library

    private struct OpenLibraryResponse: Decodable {
        struct Doc: Decodable {
            let title: String?
            let author_name: [String]?
            let cover_i: Int?
        }
        let docs: [Doc]
    }

    private static func openLibraryCandidates(title: String, author: String?) async -> [CoverCandidate] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "fields", value: "title,author_name,cover_i")]
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        components.queryItems = items
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenLibraryResponse.self, from: data)
            return decoded.docs.compactMap { doc in
                guard let cover = doc.cover_i, let thumb = URL(string: "https://covers.openlibrary.org/b/id/\(cover)-M.jpg"), let full = URL(string: "https://covers.openlibrary.org/b/id/\(cover)-L.jpg") else { return nil }
                return CoverCandidate(id: "openlibrary-\(cover)", title: doc.title ?? title, author: doc.author_name?.first, thumbnailURL: thumb, fullURL: full, source: "Open Library")
            }
        } catch {
            Logger.artwork.error("[covers] open library failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
