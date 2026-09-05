import Foundation

/// A book finished before it was in Earmark (or one the user never had files for), logged by hand so
/// it counts in Stats. Library books track their own finished state in `PlaybackProgress`; these are
/// the historical backfill — e.g. years of reading from a blog.
struct ReadingLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var author: String?
    var finishedAt: Date
    /// 1–5 stars, or nil if unrated.
    var rating: Int?
    /// Optional hand-entered length in hours, so Stats' listening-time total can include it.
    var hours: Double?
    var note: String?

    init(id: String = UUID().uuidString, title: String, author: String? = nil, finishedAt: Date,
         rating: Int? = nil, hours: Double? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.finishedAt = finishedAt
        self.rating = rating
        self.hours = hours
        self.note = note
    }
}
