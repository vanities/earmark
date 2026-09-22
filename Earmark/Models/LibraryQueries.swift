import Foundation

enum LibraryGrouping: String, CaseIterable, Codable, Sendable {
    case all, author, series, folder

    var title: String {
        switch self {
        case .all: "All Books (flat)"
        case .author: "Authors → Series"
        case .series: "Series"
        case .folder: "Folders"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .author: "person.2"
        case .series: "books.vertical"
        case .folder: "folder"
        }
    }
}

enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case recent, title, author, added, duration

    var title: String {
        switch self {
        case .recent: "Recently Played"
        case .title: "Title"
        case .author: "Author"
        case .added: "Date Added"
        case .duration: "Length"
        }
    }
}

enum LibraryLayout: String, CaseIterable, Codable, Sendable {
    case grid, list
}

/// A shelf of books sharing an author, series, or top-level folder.
struct LibraryGroup: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let books: [Book]
}

/// What a shelf's page offers to play, as Mango's series page offers the next volume: the book
/// in it you were listening to last, else the first one (in the page's order) you haven't
/// finished. Nothing when every book is finished.
enum NextUp {
    static func pick(in books: [Book], progress: (String) -> PlaybackProgress?) -> (book: Book, resuming: Bool)? {
        let underway = books.compactMap { book -> (Book, Date)? in
            guard let entry = progress(book.id), let played = entry.lastPlayedAt, !entry.isFinished else { return nil }
            return (book, played)
        }
        if let latest = underway.max(by: { $0.1 < $1.1 }) {
            return (latest.0, true)
        }
        return books.first { progress($0.id)?.isFinished != true }.map { ($0, false) }
    }
}
