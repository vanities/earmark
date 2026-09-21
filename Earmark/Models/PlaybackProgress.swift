import Foundation

/// Where the listener is in a book. Lives outside `Book` so a rescan (or a
/// temporarily offline NAS) never loses it.
struct PlaybackProgress: Codable, Hashable, Sendable {
    var trackIndex: Int = 0
    var time: TimeInterval = 0
    var lastPlayedAt: Date?
    var startedAt: Date?
    var isFinished = false
    /// When the book was finished (may be backdated by the user). Falls back to `lastPlayedAt`.
    var finishedAt: Date?
    /// The listener's rating, 1–5 stars. `nil` = unrated.
    var rating: Int?
    /// Per-book speed override. `nil` → app default.
    var speed: Float?
    /// When this entry last changed on any device — a new position, finishing, a rating, a speed, a
    /// reset. Cross-device sync keeps the newest by this, falling back to `lastPlayedAt` for entries
    /// written before it existed; without it a reset or a rating lost to any older copy.
    var modifiedAt: Date?

    /// What sync compares: when the entry last changed.
    var syncStamp: Date { modifiedAt ?? lastPlayedAt ?? .distantPast }

    /// True when saving this spot again changes nothing (a pause, the app going to the background), so
    /// it mustn't be re-dated as new listening — that stamp would beat newer progress from another device.
    func isUnchanged(trackIndex: Int, time: TimeInterval) -> Bool {
        hasStarted && !isFinished && self.trackIndex == trackIndex && abs(self.time - time) < 1
    }

    var hasStarted: Bool { lastPlayedAt != nil }

    func fraction(of book: Book) -> Double {
        guard book.totalDuration > 0 else { return 0 }
        if isFinished { return 1 }
        return min(1, max(0, book.absoluteOffset(trackIndex: trackIndex, time: time) / book.totalDuration))
    }

    func remaining(in book: Book) -> TimeInterval {
        if isFinished { return 0 }
        return max(0, book.totalDuration - book.absoluteOffset(trackIndex: trackIndex, time: time))
    }
}
