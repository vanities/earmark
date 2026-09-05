import Foundation

/// A saved spot in a book, stored as an absolute offset from the book's start so it survives
/// track re-splitting. Kept in `LibraryState.bookmarks`, keyed by `Book.id`.
struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    var id: String
    /// Seconds from the start of the whole book.
    var offset: TimeInterval
    var note: String
    var createdAt: Date

    init(id: String = UUID().uuidString, offset: TimeInterval, note: String = "", createdAt: Date = .now) {
        self.id = id
        self.offset = offset
        self.note = note
        self.createdAt = createdAt
    }
}
