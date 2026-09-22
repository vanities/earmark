import Foundation
import os

/// A book that's on a NAS and downloaded too.
struct DownloadPair: Hashable, Sendable {
    let nas: Book
    let download: Book
}

/// The rules for removing a download, apart from `LibraryModel` so they're tested: which books
/// are twins, what the NAS copy inherits, and which leftovers go with the files.
enum DownloadRemoval {
    /// Downloads whose NAS copy is still there, by `syncKey`. Twins match on path *and* group
    /// (one folder can hold several books), and the copy must be in Earmark's own folder — a
    /// book in a folder the user picked is theirs, never a download to remove.
    static func pairs(in books: [Book], kind: (Book) -> LibrarySource.Kind?) -> [String: DownloadPair] {
        var nas: [String: Book] = [:], local: [String: Book] = [:]
        for book in books {
            switch kind(book) {
            case .smb: nas[book.syncKey] = nas[book.syncKey] ?? book
            case .appDocuments: local[book.syncKey] = local[book.syncKey] ?? book
            default: break
            }
        }
        return local.reduce(into: [:]) { pairs, entry in
            if let remote = nas[entry.key] { pairs[entry.key] = DownloadPair(nas: remote, download: entry.value) }
        }
    }

    /// Where the NAS copy carries on from: the download's place when it's the newer one.
    static func place(from download: PlaybackProgress?, onto nas: PlaybackProgress?) -> PlaybackProgress? {
        guard let download else { return nas }
        return download.syncStamp >= (nas?.syncStamp ?? .distantPast) ? download : nas
    }

    /// Both copies' bookmarks, each once, in book order.
    static func bookmarks(from download: [Bookmark], onto nas: [Bookmark]) -> [Bookmark] {
        let known = Set(nas.map(\.id))
        return (nas + download.filter { !known.contains($0.id) }).sorted { $0.offset < $1.offset }
    }

    /// After a single file is deleted: its own cover ("Book.jpg" beside "Book.m4b") goes with it;
    /// a cover the folder shares ("cover.jpg") only once no audio is left beside it.
    static func removeImages(pairedWith file: URL, in folder: URL) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let stem = file.deletingPathExtension().lastPathComponent.normalizedForMatching
        let audioLeft = names.contains { AudioFileTypes.isPlayable(folder.appending(path: $0)) }
        for name in names where AudioFileTypes.images.contains((name as NSString).pathExtension.lowercased()) {
            let imageStem = (name as NSString).deletingPathExtension.normalizedForMatching
            guard imageStem == stem || (!audioLeft && AudioFileTypes.coverStems.contains(where: { imageStem.hasPrefix($0) })) else { continue }
            try? fileManager.removeItem(at: folder.appending(path: name))
            Logger.downloads.debug("[downloads] removed image \(name, privacy: .public)")
        }
    }

    /// Folders a removal left empty go too: a book's disc folders, then the book's own folder once
    /// only its cover is left (as `LibraryModel.deleteBookFiles` does), then its author's — never
    /// `root` itself, and never a folder with anything else in it.
    static func pruneEmptyFolders(from folder: URL, bookFolder: Bool, root: URL) {
        let fileManager = FileManager.default
        func contents(_ url: URL) -> [String]? { try? fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false)) }
        func isEmpty(_ url: URL) -> Bool { contents(url)?.allSatisfy { $0.hasPrefix(".") } ?? false }
        var current = folder
        if bookFolder {
            if let inside = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) {
                let discs = inside.compactMap { $0 as? URL }
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.pathComponents.count > $1.pathComponents.count }
                for disc in discs where isEmpty(disc) { try? fileManager.removeItem(at: disc) }
            }
            if let left = contents(folder),
               left.allSatisfy({ $0.hasPrefix(".") || AudioFileTypes.images.contains(($0 as NSString).pathExtension.lowercased()) }) {
                try? fileManager.removeItem(at: folder)
            }
            current = folder.deletingLastPathComponent()
        }
        let rootPath = LibraryModel.directoryPath(root)
        while LibraryModel.directoryPath(current).hasPrefix(rootPath), LibraryModel.directoryPath(current) != rootPath, isEmpty(current) {
            try? fileManager.removeItem(at: current)
            Logger.downloads.debug("[downloads] removed empty folder \(current.lastPathComponent, privacy: .public)")
            current = current.deletingLastPathComponent()
        }
    }
}
