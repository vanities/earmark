import Foundation
import ShelfKit

extension LibraryModel {
    var toolItems: [LibraryToolItem] {
        visibleBooks.map { book in
            let entry = progress[book.id] ?? PlaybackProgress()
            return LibraryToolItem(id: book.syncKey, title: book.title, detail: book.displayCredits, bytes: book.totalBytes,
                             isLocal: !isRemote(book), started: entry.hasStarted, finished: entry.isFinished,
                             lastOpened: entry.lastPlayedAt,
                             remainingSeconds: book.totalDuration > 0 ? entry.remaining(in: book) / Double(entry.speed ?? settings.defaultSpeed) : nil)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var tripGroups: [String: Set<String>] {
        var result = Dictionary(bookLists.map { ("\($0.name) · \($0.id.uuidString.prefix(4))", Set($0.items)) }, uniquingKeysWith: { first, _ in first })
        result["Continue listening"] = Set(inProgressBooks.map(\.syncKey))
        result["Playback queue"] = Set(settings.queueKeys)
        return result
    }
    func checkOffline(key: String) async -> OfflineReadiness {
        guard let book = visibleBooks.first(where: { $0.syncKey == key }) else { return .unavailable }
        if isRemote(book) { return .needsDownload }
        let tracks = nasCopy(of: book)?.tracks ?? book.tracks
        let files = tracks.compactMap { track in
            url(forTrack: track, in: book).map { OfflineReadiness.File(url: $0, expectedBytes: track.fileSize) }
        }
        guard files.count == tracks.count else { return .unavailable }
        let managed = source(for: book)?.kind == .appDocuments
        return await Task.detached(priority: .utility) { OfflineReadiness.check(files: files, managedCopy: managed) }.value
    }
}
