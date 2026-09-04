import Foundation

/// A navigable section of a book. Multi-file books get one chapter per track (or
/// more if a file carries embedded chapters); M4B files get their embedded chapters.
struct Chapter: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(trackIndex)@\(Int(start * 1000))" }

    var title: String
    var trackIndex: Int
    /// Offset within the track, in seconds.
    var start: TimeInterval
    var duration: TimeInterval

    var end: TimeInterval { start + duration }

    func contains(trackIndex index: Int, time: TimeInterval) -> Bool {
        index == trackIndex && time >= start && time < end
    }
}
