import Foundation
import os
import ShelfKit

/// Composition root shared by the phone UI and the CarPlay scene.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let library: LibraryModel
    let player: PlayerEngine
    let nowPlaying: NowPlayingController
    let downloads: DownloadManager
    let lock: AppLock

    private init() {
        let sw = Stopwatch()
        settings = AppSettings()
        library = LibraryModel(store: LibraryStore(), settings: settings)
        player = PlayerEngine(library: library, settings: settings)
        nowPlaying = NowPlayingController(player: player, settings: settings)
        downloads = DownloadManager(library: library)
        lock = AppLock(appName: "Earmark", settings: settings)

        library.onBooksChanged = { [weak player] in
            player?.refreshBookFromLibrary()
        }
        library.onSavedPositionChanged = { [weak player] ids in
            player?.savedPositionChanged(for: ids)
        }
        nowPlaying.activate()
        library.bootstrap()

        if let id = library.lastBookID, let book = library.book(id: id) {
            Logger.library.info("[app] restoring last book \(book.title, privacy: .public)")
            player.load(book, autoplay: false)
        }
        Logger.library.info("[app] environment ready in \(sw.ms, format: .fixed(precision: 1))ms")
    }

    /// Resume the current book, or the most recent one, or the first available — shared by the
    /// Resume Siri intent and the widget's deep link.
    func resumePlayback() {
        if player.book != nil {
            player.play()
        } else if let id = library.lastBookID, let book = library.book(id: id) {
            player.load(book, autoplay: true)
        } else if let book = library.inProgressBooks.first ?? library.visibleBooks.first {
            player.load(book, autoplay: true)
        }
    }

    func playBook(id: String) {
        guard let book = library.book(id: id) else { return }
        player.load(book, autoplay: true)
    }
}
