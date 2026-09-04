import Foundation

enum AudioFileTypes {
    /// Extensions AVFoundation can play natively.
    static let playable: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "mp4", "wav", "aif", "aiff", "aifc", "caf", "flac", "3gp", "amr",
    ]

    /// Common audiobook containers iOS cannot decode. Surfaced in Folders so the user knows why they're missing.
    static let unsupported: Set<String> = ["ogg", "oga", "opus", "wma", "webm", "mka", "ape", "wv"]

    static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif", "bmp", "tif", "tiff"]

    /// File stems that almost always mean "this is the cover", best first.
    static let coverStems: [String] = ["cover", "folder", "front", "album", "artwork", "art", "book"]

    static func isPlayable(_ url: URL) -> Bool {
        playable.contains(url.pathExtension.lowercased())
    }
}
