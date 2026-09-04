import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.vanities.earmark"

    static let library = Logger(subsystem: subsystem, category: "library")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let metadata = Logger(subsystem: subsystem, category: "metadata")
    static let artwork = Logger(subsystem: subsystem, category: "artwork")
    static let bookmarks = Logger(subsystem: subsystem, category: "bookmarks")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let nowPlaying = Logger(subsystem: subsystem, category: "nowplaying")
    static let carplay = Logger(subsystem: subsystem, category: "carplay")
    static let duplicates = Logger(subsystem: subsystem, category: "duplicates")
    static let nas = Logger(subsystem: subsystem, category: "nas")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Cheap elapsed-time helper for log lines: `let sw = Stopwatch(); ...; sw.ms`.
struct Stopwatch: Sendable {
    let start = Date()
    var seconds: TimeInterval { Date().timeIntervalSince(start) }
    var ms: Double { seconds * 1000 }
}
