import Foundation
import ShelfKit

/// Time actually spent listening, one session per stretch of playback — what Stats' time,
/// streak and habit cards are built from, as Mango's reading sessions are.
///
/// Wall-clock time while audio plays: an hour at 2× is an hour of listening. A stall (buffering)
/// or anything else that stops the playhead doesn't count.
struct ListeningSession: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var bookID: String
    /// `Book.syncKey`, so a book's copies (on the NAS, downloaded) count as one book.
    var bookKey: String
    var bookTitle: String
    var startedAt: Date
    var activeSeconds: Double

    init(id: String = UUID().uuidString, bookID: String, bookKey: String, bookTitle: String,
         startedAt: Date, activeSeconds: Double) {
        self.id = id
        self.bookID = bookID
        self.bookKey = bookKey
        self.bookTitle = bookTitle
        self.startedAt = startedAt
        self.activeSeconds = activeSeconds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        bookID = try c.decodeIfPresent(String.self, forKey: .bookID) ?? ""
        bookKey = try c.decodeIfPresent(String.self, forKey: .bookKey) ?? ""
        bookTitle = try c.decodeIfPresent(String.self, forKey: .bookTitle) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? .now
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
    }
}

/// How ShelfKit's `ActivityStats` sees a listening session: grouped by book, no pages.
extension ListeningSession: ActivitySession {
    var activityGroupKey: String { bookKey }
    var activityGroupName: String { bookTitle }
    var activityPages: Int { 0 }
}

/// Measures listening as it happens, fed by the player's half-second ticks while audio plays.
/// A gap between ticks counts only up to `maxGap` — longer means playback stalled — and a
/// session shorter than `minimumSession` isn't one: it's checking where you were.
struct ListeningRecorder: Sendable {
    static let maxGap: TimeInterval = 5
    /// A gap longer than this ends the session where the last tick left it and starts another:
    /// playback stopped without anything saying so, and one session mustn't stretch across
    /// hours (or into tomorrow, which would move that time to the wrong day).
    static let splitGap: TimeInterval = 60
    static let minimumSession: TimeInterval = 15

    /// The session under way.
    struct Open: Codable, Equatable, Sendable {
        var bookID: String
        var bookKey: String
        var bookTitle: String
        var startedAt: Date
        var activeSeconds: Double

        var session: ListeningSession? {
            guard activeSeconds >= ListeningRecorder.minimumSession else { return nil }
            return ListeningSession(bookID: bookID, bookKey: bookKey, bookTitle: bookTitle,
                                    startedAt: startedAt, activeSeconds: activeSeconds)
        }
    }

    private(set) var open: Open?
    private var lastTick: Date?

    /// Audio played up to `now`. Starts a session if none is open; a tick for another book, or
    /// after a gap longer than `splitGap`, finishes the open one first and returns it.
    mutating func tick(bookID: String, bookKey: String, title: String, now: Date = .now) -> ListeningSession? {
        var finished: ListeningSession?
        let stopped = lastTick.map { now.timeIntervalSince($0) > Self.splitGap } ?? false
        if let current = open, current.bookID != bookID || stopped {
            finished = finish()
        }
        guard open != nil else {
            open = Open(bookID: bookID, bookKey: bookKey, bookTitle: title, startedAt: now, activeSeconds: 0)
            lastTick = now
            return finished
        }
        if let lastTick {
            open?.activeSeconds += min(max(0, now.timeIntervalSince(lastTick)), Self.maxGap)
        }
        lastTick = now
        return finished
    }

    /// Playback stopped: the session, if it was long enough to be one.
    mutating func finish() -> ListeningSession? {
        defer {
            open = nil
            lastTick = nil
        }
        return open?.session
    }
}

/// The open session, saved every minute of playback so a session cut off — the app killed
/// mid-book — is still counted at the next launch rather than lost.
enum ListeningCheckpoint {
    private static let key = "activity.openListeningSession"

    static func save(_ open: ListeningRecorder.Open?, defaults: UserDefaults = .standard) {
        guard let open, let data = try? JSONEncoder().encode(open) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    /// The session a previous launch left open, removed so it's only ever counted once.
    static func take(defaults: UserDefaults = .standard) -> ListeningSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return (try? JSONDecoder().decode(ListeningRecorder.Open.self, from: data))?.session
    }
}
