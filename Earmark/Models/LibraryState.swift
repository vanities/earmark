import Foundation

/// Everything Earmark persists about the library, in one JSON document.
struct LibraryState: Codable, Sendable {
    var schemaVersion = 1
    var sources: [LibrarySource] = []
    var books: [Book] = []
    var progress: [String: PlaybackProgress] = [:]
    var hiddenBookIDs: Set<String> = []
    var lastBookID: String?
    var nasServers: [NASServer] = []
    /// Book ID → artwork ID chosen by the user via Find Cover. Survives rescans.
    var customArtwork: [String: String] = [:]
}
