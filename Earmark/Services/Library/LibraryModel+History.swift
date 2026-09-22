import Foundation
import os

// MARK: - Reading log (books finished outside the app)

extension LibraryModel {
    @discardableResult
    func addReadingLogEntry(title: String, author: String?, finishedAt: Date, rating: Int? = nil, hours: Double? = nil) -> ReadingLogEntry {
        let entry = ReadingLogEntry(title: title, author: author?.isEmpty == true ? nil : author, finishedAt: finishedAt,
                                    rating: rating.map { min(5, max(1, $0)) }, hours: hours)
        readingLog.append(entry)
        Logger.library.info("[library] logged past book \(title, privacy: .public)")
        scheduleSave()
        return entry
    }

    func updateReadingLogEntry(_ entry: ReadingLogEntry) {
        guard let index = readingLog.firstIndex(where: { $0.id == entry.id }) else { return }
        readingLog[index] = entry
        scheduleSave()
    }

    func removeReadingLogEntry(_ id: String) {
        readingLog.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Aggregated history for the Stats tab: finished library books plus hand-logged past books.
    var readingStats: ReadingStats {
        var items: [ReadingStatsBuilder.Item] = []
        for book in visibleBooks {
            guard let entry = progress[book.id], entry.isFinished else { continue }
            let when = entry.finishedAt ?? entry.lastPlayedAt ?? book.addedAt
            items.append(.init(finishedAt: when, hours: book.totalDuration / 3600, rating: entry.rating, author: book.author))
        }
        for entry in readingLog {
            items.append(.init(finishedAt: entry.finishedAt, hours: entry.hours ?? 0, rating: entry.rating, author: entry.author))
        }
        return ReadingStatsBuilder.build(items)
    }

    // MARK: Import reading history

    private struct HistoryItem: Decodable {
        var title: String
        var author: String?
        var year: Int
        var month: Int?
        var rating: Int?
        var hours: Double?
    }

    private static func normTitle(_ t: String) -> String {
        String(t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Imports a reading history (e.g. parsed from a blog): backdates matching library books as
    /// finished with their rating, and logs the rest as past books. Skips anything already recorded.
    /// Returns (books backdated, past books logged).
    @discardableResult
    func importReadingHistory(_ data: Data) -> (matched: Int, logged: Int) {
        guard let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return (0, 0) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let libraryByTitle = Dictionary(books.map { (Self.normTitle($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        var loggedTitles = Set(readingLog.map { Self.normTitle($0.title) })
        var matched = 0, logged = 0
        for item in items {
            let key = Self.normTitle(item.title)
            guard !key.isEmpty else { continue }
            let date = calendar.date(from: DateComponents(year: item.year, month: item.month ?? 6, day: 15)) ?? .now
            if let book = libraryByTitle[key] ?? books.first(where: { let n = Self.normTitle($0.title); return !n.isEmpty && (n.hasPrefix(key) || key.hasPrefix(n)) }) {
                if progress[book.id]?.isFinished != true {
                    markFinished(book.id, on: date)
                    matched += 1
                }
                if let rating = item.rating, progress[book.id]?.rating == nil { setRating(book.id, rating) }
            } else if !loggedTitles.contains(key) {
                addReadingLogEntry(title: item.title, author: item.author, finishedAt: date, rating: item.rating, hours: item.hours)
                loggedTitles.insert(key)
                logged += 1
            }
        }
        Logger.library.info("[library] imported reading history: matched=\(matched) logged=\(logged)")
        return (matched, logged)
    }
}
