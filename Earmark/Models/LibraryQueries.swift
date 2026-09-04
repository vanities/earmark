import Foundation

enum LibraryGrouping: String, CaseIterable, Codable, Sendable {
    case all, author, series, folder

    var title: String {
        switch self {
        case .all: "All Books"
        case .author: "Authors"
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
