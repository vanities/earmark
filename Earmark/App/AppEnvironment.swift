import Foundation
import os

/// Composition root shared by the phone UI and the CarPlay scene.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let library: LibraryModel
    let player: PlayerEngine
    let nowPlaying: NowPlayingController
    let downloads: DownloadManager

    private init() {
        let sw = Stopwatch()
        settings = AppSettings()
        library = LibraryModel(store: LibraryStore(), settings: settings)
        player = PlayerEngine(library: library, settings: settings)
        nowPlaying = NowPlayingController(player: player, settings: settings)
        downloads = DownloadManager(library: library)

        library.onBooksChanged = { [weak player] in
            player?.refreshBookFromLibrary()
        }
        nowPlaying.activate()
        library.bootstrap()

        if let id = library.lastBookID, let book = library.book(id: id) {
            Logger.library.info("[app] restoring last book \(book.title, privacy: .public)")
            player.load(book, autoplay: false)
        }
        Logger.library.info("[app] environment ready in \(sw.ms, format: .fixed(precision: 1))ms")
    }
}
