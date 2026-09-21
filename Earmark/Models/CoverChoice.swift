import Foundation

/// The cover the user picked for a book, synced across devices by `Book.syncKey`. When devices
/// disagree, the newest choice wins everywhere (see `CoverSync`).
struct CoverChoice: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Found with Find Cover; every device downloads it from `url`.
        case online
        /// Back to the art the book's own files provide, on every device.
        case original
        /// Picked from Photos or Files. There's nothing to download, so other devices keep what they show.
        case deviceOnly
    }

    var kind: Kind
    var url: String?
    var chosenAt: Date

    init(kind: Kind, url: String? = nil, chosenAt: Date = CoverChoice.now()) {
        self.kind = kind
        self.url = url
        self.chosenAt = chosenAt
    }

    /// Now, to the second. Choices round-trip through ISO 8601 JSON, which drops fractions — a finer
    /// time would make a choice look newer than its own saved copy.
    static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private enum CodingKeys: String, CodingKey { case kind, url, chosenAt }

    /// Lenient like `LibraryState`: a kind from a newer build reads as `deviceOnly` (changes nothing
    /// here), and a missing date as the distant past, which any real choice beats.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .deviceOnly
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        chosenAt = (try? c.decode(Date.self, forKey: .chosenAt)) ?? .distantPast
    }
}
