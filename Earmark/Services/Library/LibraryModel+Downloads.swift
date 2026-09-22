import Foundation
import os

// MARK: - Removing downloads
//
// A download is a NAS book copied into On My iPhone › Earmark at the same relative path. Removing
// one deletes that copy — only inside Earmark's own folder, only while the book is still on the
// NAS — and the NAS copy carries on from the same place. The rules are in `DownloadRemoval`.

extension LibraryModel {
    /// Every download that's still on a NAS, by `syncKey` — for screens asking about many books.
    func downloadPairs() -> [String: DownloadPair] {
        DownloadRemoval.pairs(in: books) { source(for: $0)?.kind }
    }

    /// The NAS copy of a book: the book itself when it's remote, else the one it was downloaded from.
    func nasCopy(of book: Book) -> Book? {
        if isRemote(book) { return book }
        let key = book.syncKey
        return books.first { isRemote($0) && $0.syncKey == key }
    }

    /// The downloaded copy of a book, when it has one that's still on the NAS.
    func downloadedCopy(of book: Book) -> Book? {
        let key = book.syncKey
        let twins = books.filter { $0.syncKey == key }
        return DownloadRemoval.pairs(in: twins) { source(for: $0)?.kind }[key]?.download
    }

    /// Deletes a book's download; it plays from the NAS again. Returns the bytes freed. Unload
    /// the player first if it holds the download, or its last position lands on a deleted book.
    @discardableResult
    func removeDownload(of book: Book) -> Int64 {
        guard let local = downloadedCopy(of: book), let remote = nasCopy(of: local),
              let root = rootURL(for: local.sourceID)?.standardizedFileURL
        else {
            Logger.downloads.notice("[downloads] nothing to remove for \(book.title, privacy: .public)")
            return 0
        }
        // Only ever inside Earmark's own folder, whatever a path might say.
        let rootPath = LibraryModel.directoryPath(root)
        let tracks = local.tracks.map { root.appending(path: $0.relativePath).standardizedFileURL }
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.path(percentEncoded: false).hasPrefix(rootPath) }) else {
            Logger.downloads.error("[downloads] refusing to remove \(local.relativePath, privacy: .public): outside Earmark's folder")
            return 0
        }
        let sw = Stopwatch()
        let bookURL = root.appending(path: local.relativePath).standardizedFileURL
        let folder = local.kind == .folder ? bookURL : bookURL.deletingLastPathComponent()
        let errors = deleteBookFiles(local)
        guard errors.isEmpty else {
            Logger.downloads.error("[downloads] couldn't remove \(local.relativePath, privacy: .public): \(errors.joined(separator: "; "), privacy: .public)")
            return 0
        }
        if local.kind == .singleFile { DownloadRemoval.removeImages(pairedWith: bookURL, in: folder) }
        DownloadRemoval.pruneEmptyFolders(from: folder, bookFolder: local.kind == .folder, root: root)
        returnDownloadState(from: local.id, to: remote.id)
        // A library salvaged from an older build can carry a second "On My iPhone" source over
        // the same folder; `deleteBookFiles` rescans only this one, and the other would go on
        // listing what was just deleted.
        for other in sources where other.kind == .appDocuments && other.id != local.sourceID {
            Logger.downloads.notice("[downloads] rescanning duplicate On My iPhone source \(other.id.uuidString, privacy: .public)")
            rescan(other.id)
        }
        Logger.downloads.info("[downloads] removed \(local.title, privacy: .public) bytes=\(local.totalBytes) tracks=\(tracks.count) in \(sw.ms, format: .fixed(precision: 0))ms — plays from the NAS again")
        return local.totalBytes
    }

    /// Removes several downloads. Returns how many went and the bytes freed.
    @discardableResult
    func removeDownloads(_ books: [Book]) -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        for book in books {
            let freed = removeDownload(of: book)
            if freed > 0 { count += 1; bytes += freed }
        }
        Logger.downloads.info("[downloads] removed \(count)/\(books.count) downloads bytes=\(bytes)")
        return (count, bytes)
    }
}
