import Foundation
import ShelfKit

extension LibraryState {
    /// Only unique path matches are eligible; a colliding title or path is never guessed.
    func portableMatches(_ old: LibraryState) -> [(String, String)] {
        let current = Dictionary(grouping: books, by: \.syncKey)
        let previous = Dictionary(grouping: old.books, by: \.syncKey)
        return previous.flatMap { key, copies -> [(String, String)] in
            guard let destinations = current[key], validPortableCopies(destinations), old.validPortableCopies(copies) else { return [] }
            // Copies must describe the same size and format before state can follow them.
            let sizes = Set((copies + destinations).map(\.totalBytes))
            guard sizes.count == 1, !sizes.contains(0) else { return [] }
            let chosen = copies.sorted { (old.progress[$0.id]?.syncStamp ?? .distantPast) > (old.progress[$1.id]?.syncStamp ?? .distantPast) }.first!
            return destinations.map { (chosen.id, $0.id) }
        }
    }
    private func validPortableCopies(_ items: [Book]) -> Bool {
        guard items.count > 1 else { return true }
        guard items.count == 2 else { return false }
        let kinds = items.compactMap { item in sources.first(where: { $0.id == item.sourceID })?.kind }
        return kinds.contains(.appDocuments) && kinds.contains(.smb) && items[0].kind == items[1].kind
    }
    mutating func restorePortable(_ old: LibraryState) {
        preparePortableGrouping(old)
        deletedBookmarks = deletedBookmarks.merging(old.deletedBookmarks)
        for (from, to) in portableMatches(old) {
            if progress[to] == nil { progress[to] = old.progress[from] }
            if metadataOverrides[to] == nil { metadataOverrides[to] = old.metadataOverrides[from] }
            if customArtwork[to] == nil, let book = books.first(where: { $0.id == to }), coverChoices[book.syncKey] == nil { customArtwork[to] = old.customArtwork[from] }
            let known = Set((bookmarks[to] ?? []).map(\.id))
            let incoming = (old.bookmarks[from] ?? []).filter { !known.contains($0.id) && !deletedBookmarks.contains($0.id) }
            bookmarks[to] = ((bookmarks[to] ?? []) + incoming).filter { !deletedBookmarks.contains($0.id) }.sorted { $0.offset < $1.offset }
        }
        let knownLists = Set(bookLists.map(\.id))
        bookLists.append(contentsOf: old.bookLists.filter { !knownLists.contains($0.id) })
        let knownLogs = Set(readingLog.map(\.id))
        readingLog.append(contentsOf: old.readingLog.filter { !knownLogs.contains($0.id) })
        let knownShelves = Set(tools.smartShelves.map(\.id))
        tools.smartShelves.append(contentsOf: old.tools.smartShelves.filter { !knownShelves.contains($0.id) })
    }
}
