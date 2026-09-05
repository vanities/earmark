import Foundation

/// One audio file belonging to a book. Paths are relative to the owning source's
/// root so a source can be re-resolved (or moved) without rescanning progress.
struct Track: Identifiable, Codable, Hashable, Sendable {
    var id: String { relativePath }

    var relativePath: String
    var fileName: String
    /// Title from tags, if any. Chapter titles fall back to a cleaned file name.
    var title: String?
    /// Seconds. Estimated during scanning, corrected to the precise value on first play.
    var duration: TimeInterval
    var fileSize: Int64
    var modifiedAt: Date?
    var trackNumber: Int?
    var discNumber: Int?
    /// True when the file lives in iCloud (or another provider) and isn't downloaded yet.
    var needsDownload: Bool = false
    /// Container detected from the file header during a remote scan ("mp3", "mp4"); files are
    /// often misnamed (an MP3 called .m4b), and AVFoundation needs the real type when streaming.
    var containerHint: String?

    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
}
