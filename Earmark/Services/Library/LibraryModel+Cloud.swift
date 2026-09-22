import Foundation
import ShelfKit

// MARK: - iCloud

/// This device's side of what iCloud carries. The merge the other way, which changes progress
/// and bookmarks, stays in LibraryModel.swift with the state it writes.
extension LibraryModel {
    /// Writes this device's side of everything iCloud carries, merged over what's there.
    func pushToCloud() {
        let snapshot = ProgressSync.cloudSnapshot(local: progress, books: books, existingCloud: cloudSync.load())
        cloudSync.save(snapshot)
        cloudSync.saveReadingLog(mergedReadingLog(with: cloudSync.loadReadingLog()))
        cloudSync.saveCoverChoices(CoverSync.merged(local: coverChoices, cloud: cloudSync.loadCoverChoices()))
        let buried = allDeletedBookmarks()
        cloudSync.saveBookmarks(BookmarkSync.snapshot(local: bookmarks, books: books, existingCloud: cloudSync.loadBookmarks(), buried: buried))
        cloudSync.saveDeletedBookmarks(buried)
    }

    /// Bookmarks deleted here or on any device, forgotten after 180 days (every device has seen
    /// them by then, and iCloud's store is capped near 1 MB).
    func allDeletedBookmarks() -> Tombstones {
        deletedBookmarks.merging(cloudSync.loadDeletedBookmarks()).pruned(before: .now.addingTimeInterval(-180 * 86_400))
    }

    /// Union of local and cloud reading-log entries by id (local wins on conflict).
    func mergedReadingLog(with cloud: [ReadingLogEntry]) -> [ReadingLogEntry] {
        var byID = Dictionary(readingLog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in cloud where byID[entry.id] == nil { byID[entry.id] = entry }
        return byID.values.sorted { $0.finishedAt > $1.finishedAt }
    }
}
