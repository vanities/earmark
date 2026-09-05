import Foundation

/// The tiny bit of state the Home/Lock Screen widget needs, shared from the app to the widget
/// through the App Group container. Kept deliberately small (no audio, just what to draw).
struct NowPlayingSnapshot: Codable, Equatable {
    var bookID: String
    var title: String
    var author: String
    var fraction: Double
    var remaining: String
    var isPlaying: Bool
    var updatedAt: Date
}

/// Read/write the snapshot (and a small cover image) in the shared App Group container. Everything
/// no-ops gracefully when the group isn't available (device builds before the capability is enabled),
/// so the widget simply shows its empty state there instead of crashing.
enum SharedNowPlaying {
    static let appGroup = "group.com.vanities.earmark"
    private static let jsonName = "nowplaying.json"
    private static let coverName = "nowplaying.jpg"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var coverURL: URL? { containerURL?.appending(path: coverName) }

    static func write(_ snapshot: NowPlayingSnapshot?) {
        guard let dir = containerURL else { return }
        let url = dir.appending(path: jsonName)
        guard let snapshot else { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    static func read() -> NowPlayingSnapshot? {
        guard let dir = containerURL,
              let data = try? Data(contentsOf: dir.appending(path: jsonName)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NowPlayingSnapshot.self, from: data)
    }

    static func writeCover(_ jpegData: Data?) {
        guard let url = coverURL else { return }
        guard let jpegData else { try? FileManager.default.removeItem(at: url); return }
        try? jpegData.write(to: url, options: .atomic)
    }
}
