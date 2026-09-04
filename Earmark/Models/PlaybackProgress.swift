import Foundation

/// Where the listener is in a book. Lives outside `Book` so a rescan (or a
/// temporarily offline NAS) never loses it.
struct PlaybackProgress: Codable, Hashable, Sendable {
    var trackIndex: Int = 0
    var time: TimeInterval = 0
    var lastPlayedAt: Date?
    var startedAt: Date?
    var isFinished = false
    /// Per-book speed override. `nil` → app default.
    var speed: Float?

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
