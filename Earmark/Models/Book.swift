import Foundation

/// A book as derived from the files on disk. Rebuilt on every scan; user state
/// (progress, hidden flag) is stored separately and keyed by the stable `id`.
struct Book: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A folder of audio files, each one a chapter (or a disc of chapters).
        case folder
        /// A single file: an .m4b with chapters, or a lone .mp3/.m4a.
        case singleFile
    }

    /// Stable across rescans while the file layout doesn't change:
    /// `"<sourceID>|<relativePath>|<groupKey>"`.
    let id: String
    var sourceID: UUID
    /// Book root relative to the source root: the folder for `.folder`, the file for `.singleFile`.
    var relativePath: String
    var kind: Kind

    var title: String
    var author: String?
    var series: String?
    var seriesIndex: Double?
    var narrator: String?
    var year: Int?

    var tracks: [Track]
    var chapters: [Chapter]
    /// Key into `ArtworkStore`. Thumbnails are the only thing Earmark ever writes itself.
    var artworkID: String?

    var addedAt: Date
    var totalBytes: Int64

    // MARK: Derived

    var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }

    var displayAuthor: String { author ?? "Unknown Author" }

    /// "MP3 · 12 files" / "M4B" — what the user actually has on disk.
    var formatLabel: String {
        let exts = Set(tracks.map(\.fileExtension)).sorted()
        let format = exts.map { $0.uppercased() }.joined(separator: "/")
        return tracks.count == 1 ? format : "\(format) · \(tracks.count) files"
    }

    /// Cumulative start offset of each track within the whole book.
    var trackStartOffsets: [TimeInterval] {
        var offsets: [TimeInterval] = []
        var running: TimeInterval = 0
        for track in tracks {
            offsets.append(running)
            running += track.duration
        }
        return offsets
    }

    func absoluteOffset(trackIndex: Int, time: TimeInterval) -> TimeInterval {
        guard tracks.indices.contains(trackIndex) else { return 0 }
        return trackStartOffsets[trackIndex] + time
    }

    func position(atAbsoluteOffset offset: TimeInterval) -> BookPosition {
        let offsets = trackStartOffsets
        guard !tracks.isEmpty else { return BookPosition(trackIndex: 0, time: 0) }
        let clamped = max(0, min(offset, totalDuration))
        var index = 0
        for (i, start) in offsets.enumerated() where start <= clamped {
            index = i
        }
        return BookPosition(trackIndex: index, time: clamped - offsets[index])
    }

    func chapterIndex(trackIndex: Int, time: TimeInterval) -> Int? {
        if let exact = chapters.firstIndex(where: { $0.contains(trackIndex: trackIndex, time: time) }) {
            return exact
        }
        // Time past the last chapter boundary of a track (rounding) → last chapter in that track.
        return chapters.lastIndex(where: { $0.trackIndex == trackIndex && $0.start <= time })
    }

    func chapter(at trackIndex: Int, time: TimeInterval) -> Chapter? {
        chapterIndex(trackIndex: trackIndex, time: time).map { chapters[$0] }
    }

    func absoluteOffset(of chapter: Chapter) -> TimeInterval {
        absoluteOffset(trackIndex: chapter.trackIndex, time: chapter.start)
    }

    static func makeID(sourceID: UUID, relativePath: String, groupKey: String = "") -> String {
        "\(sourceID.uuidString)|\(relativePath)|\(groupKey)"
    }
}

struct BookPosition: Hashable, Sendable {
    var trackIndex: Int
    var time: TimeInterval
}
