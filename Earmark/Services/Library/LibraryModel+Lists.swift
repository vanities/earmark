import Foundation
import os

// MARK: - Lists

extension LibraryModel {
    /// What a list entry is today: the copy of the book in the library (a download in place of
    /// its NAS copy), or nothing when it's left the library — it stays listed, and comes back with it.
    enum ListEntry: Identifiable {
        case book(Book)
        case missing(String)

        var id: String { key }

        var key: String {
            switch self {
            case .book(let book): book.syncKey
            case .missing(let key): key
            }
        }
    }

    func entries(of list: BookList) -> [ListEntry] {
        let visible = Dictionary(visibleBooks.map { ($0.syncKey, $0) }, uniquingKeysWith: { first, _ in first })
        return list.items.map { key in visible[key].map(ListEntry.book) ?? .missing(key) }
    }

    func bookList(id: UUID) -> BookList? { bookLists.first { $0.id == id } }

    @discardableResult
    func createList(named name: String) -> UUID {
        let list = BookList(name: name)
        bookLists.append(list)
        save()
        Logger.library.info("[lists] created \"\(name, privacy: .public)\"")
        return list.id
    }

    func deleteList(_ id: UUID) {
        bookLists.removeAll { $0.id == id }
        save()
    }

    func renameList(_ id: UUID, to name: String) {
        guard let index = bookLists.firstIndex(where: { $0.id == id }) else { return }
        bookLists[index].name = name
        save()
    }

    func addToList(_ id: UUID, _ book: Book) {
        bookLists.add(book.syncKey, to: id)
        save()
    }

    func removeFromList(_ id: UUID, key: String) {
        bookLists.remove(key, from: id)
        save()
    }

    func moveInList(_ id: UUID, from offsets: IndexSet, to destination: Int) {
        bookLists.move(in: id, from: offsets, to: destination)
        save()
    }

    func isListed(_ book: Book, in id: UUID) -> Bool {
        bookList(id: id)?.items.contains(book.syncKey) ?? false
    }
}
