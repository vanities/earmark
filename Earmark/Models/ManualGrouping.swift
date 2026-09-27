import Foundation

/// A device-local, reversible arrangement of existing tracks. Never writes audio or tags.
struct ManualGrouping: Codable, Sendable {
    var sourceID: UUID
    var copySourceIDs: Set<UUID>
    var original: [Book]
    var groups: [Book]
    var previous: [Book]?

    func applies(to source: UUID) -> Bool { source == sourceID || copySourceIDs.contains(source) }

    func applied(to scanned: [Book], source: UUID) -> [Book] {
        guard applies(to: source) else { return scanned }
        let files = Dictionary(scanned.flatMap(\.tracks).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = Set(groups.flatMap(\.tracks).map(\.relativePath))
        var result: [Book] = []
        for template in groups {
            guard template.tracks.contains(where: { files[$0.relativePath] != nil }) else { continue }
            // A partial scan must not shift track indexes or erase a saved position.
            var book = Self.rebase(template, source: source)
            book.tracks = template.tracks.map { files[$0.relativePath] ?? $0 }
            book.totalBytes = book.tracks.reduce(0) { $0 + $1.fileSize }
            result.append(book)
        }
        for book in scanned {
            let remainder = book.tracks.filter { !paths.contains($0.relativePath) }
            if remainder.count == book.tracks.count { result.append(book) } else if !remainder.isEmpty {
                result.append(Self.makeBook(template: book, tracks: remainder, title: book.title + " — new tracks", token: "new-tracks"))
            }
        }
        return result
    }

    static func rebase(_ book: Book, source: UUID) -> Book {
        Book(id: Book.makeID(sourceID: source, relativePath: book.relativePath, groupKey: book.groupKey ?? ""),
             sourceID: source, relativePath: book.relativePath, kind: book.kind, title: book.title, author: book.author,
             series: book.series, seriesIndex: book.seriesIndex, narrator: book.narrator, year: book.year,
             tracks: book.tracks, chapters: book.chapters, artworkID: book.artworkID, addedAt: book.addedAt, totalBytes: book.totalBytes)
    }

    static func makeBook(template: Book, tracks: [Track], title: String, token: String = UUID().uuidString) -> Book {
        let parent = (tracks.first?.relativePath as NSString?)?.deletingLastPathComponent ?? template.relativePath
        let mapping = Dictionary(tracks.enumerated().map { ($0.element.relativePath, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let chapters = template.chapters.compactMap { chapter -> Chapter? in
            guard template.tracks.indices.contains(chapter.trackIndex), let index = mapping[template.tracks[chapter.trackIndex].relativePath] else { return nil }
            var chapter = chapter; chapter.trackIndex = index; return chapter
        }
        return Book(id: Book.makeID(sourceID: template.sourceID, relativePath: parent, groupKey: "manual-" + token),
                    sourceID: template.sourceID, relativePath: parent, kind: .folder, title: title, author: template.author,
                    series: template.series, seriesIndex: template.seriesIndex, narrator: template.narrator, year: template.year,
                    tracks: tracks, chapters: tracks.indices.flatMap { index -> [Chapter] in
                        let existing = chapters.filter { $0.trackIndex == index }
                        return existing.isEmpty ? [Chapter(title: tracks[index].title ?? tracks[index].fileName, trackIndex: index, start: 0, duration: tracks[index].duration)] : existing
                    }, artworkID: template.artworkID, addedAt: template.addedAt, totalBytes: tracks.reduce(0) { $0 + $1.fileSize })
    }
}

extension LibraryState {
    /// Move positions and notes by track identity, not by their old index or absolute offset.
    mutating func regroup(from old: [Book], to new: [Book]) {
        let saved = self
        let oldIDs = Set(old.map(\.id))
        for book in old {
            progress[book.id] = nil; bookmarks[book.id] = nil; metadataOverrides[book.id] = nil
            customArtwork[book.id] = nil; hiddenBookIDs.remove(book.id)
        }
        for target in new {
            let related = old.filter { original in
                original.sourceID == target.sourceID && !Set(original.tracks.map(\.relativePath)).isDisjoint(with: target.tracks.map(\.relativePath))
            }.sorted { (saved.progress[$0.id]?.syncStamp ?? .distantPast) > (saved.progress[$1.id]?.syncStamp ?? .distantPast) }
            for origin in related {
                if let entry = saved.progress[origin.id], origin.tracks.indices.contains(entry.trackIndex),
                   let index = target.tracks.firstIndex(where: { $0.relativePath == origin.tracks[entry.trackIndex].relativePath }), progress[target.id] == nil {
                    var moved = entry; moved.trackIndex = index; moved.modifiedAt = .now
                    moved.isFinished = related.allSatisfy { saved.progress[$0.id]?.isFinished == true }
                    progress[target.id] = moved
                    if saved.lastBookID == origin.id { lastBookID = target.id }
                }
                for var mark in saved.bookmarks[origin.id] ?? [] {
                    let position = origin.position(atAbsoluteOffset: mark.offset)
                    guard origin.tracks.indices.contains(position.trackIndex),
                          let index = target.tracks.firstIndex(where: { $0.relativePath == origin.tracks[position.trackIndex].relativePath }) else { continue }
                    mark.offset = target.absoluteOffset(trackIndex: index, time: position.time)
                    if bookmarks[target.id]?.contains(where: { $0.id == mark.id }) != true { bookmarks[target.id, default: []].append(mark) }
                }
                if saved.hiddenBookIDs.contains(origin.id) { hiddenBookIDs.insert(target.id) }
                if metadataOverrides[target.id] == nil, var correction = saved.metadataOverrides[origin.id] {
                    correction.title = target.title; metadataOverrides[target.id] = correction
                }
                if customArtwork[target.id] == nil { customArtwork[target.id] = saved.customArtwork[origin.id] }
            }
            if progress[target.id] == nil, let origin = related.first, var entry = saved.progress[origin.id] {
                entry.trackIndex = 0; entry.time = 0; entry.modifiedAt = .now
                entry.isFinished = related.allSatisfy { saved.progress[$0.id]?.isFinished == true }
                progress[target.id] = entry
            }
        }
        if let lastBookID, oldIDs.contains(lastBookID), !new.contains(where: { $0.id == lastBookID }) { self.lastBookID = nil }
        for i in bookLists.indices {
            var seen: Set<String> = []
            bookLists[i].items = bookLists[i].items.flatMap { key -> [String] in
                let originals = old.filter { $0.syncKey == key }
                guard !originals.isEmpty else { return [key] }
                let paths = Set(originals.flatMap(\.tracks).map(\.relativePath))
                return new.filter { !paths.isDisjoint(with: $0.tracks.map(\.relativePath)) }.map(\.syncKey)
            }.filter { seen.insert($0).inserted }
        }
    }
}
