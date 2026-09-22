import Foundation

/// A list of your own across the library — "Up next", "Road trip", a pile to get to.
struct BookList: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Books by `Book.syncKey` (their path), so a download, a rescan or another device's copy of
    /// the same book never drops one.
    var items: [String]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, items: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
    }
}

extension [BookList] {
    /// Adds to the end; a book already on the list stays where it is.
    mutating func add(_ key: String, to id: UUID) {
        guard let index = firstIndex(where: { $0.id == id }), !self[index].items.contains(key) else { return }
        self[index].items.append(key)
    }

    mutating func remove(_ key: String, from id: UUID) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        self[index].items.removeAll { $0 == key }
    }

    mutating func move(in id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        self[index].items.move(fromOffsets: offsets, toOffset: destination)
    }
}
