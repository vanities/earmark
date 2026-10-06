import Foundation
import MediaPlayer
import WidgetKit
import UIKit
import os
import ShelfKit

/// Mirrors player state to the lock screen, Control Center, CarPlay Now Playing,
/// headphones, and the car's steering-wheel buttons.
@MainActor
final class NowPlayingController {
    private let player: PlayerEngine
    private let settings: AppSettings
    private var artworkImage: UIImage?
    private var artworkBookID: String?
    /// The cover `artworkImage` is for — a replaced cover changes it without changing the book.
    private var artworkID: String?
    /// True until the current book's artwork has finished loading (it may turn out to have none).
    private var artworkLoading = false
    /// The cover last written for the widget ("" = none), so a change is written even when nothing else moved.
    private var widgetCoverID: String?

    init(player: PlayerEngine, settings: AppSettings) {
        self.player = player
        self.settings = settings
    }

    func activate() {
        registerCommands()
        player.stateDidChange = { [weak self] in
            self?.update()
        }
        update()
        Logger.nowPlaying.info("[nowplaying] activated")
    }

    // MARK: - Remote commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.pause() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.togglePlayPause() }
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForwardInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.skipForward() }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBackInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.skipBackward() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.settings.headphoneTrackAction {
                case .skip: self.player.skipForward()
                case .chapter: self.player.nextChapter()
                }
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.settings.headphoneTrackAction {
                case .skip: self.player.skipBackward()
                case .chapter: self.player.previousChapter()
                }
            }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.settings.lockScreenTimeMode {
                case .chapter: self.player.seek(toChapterTime: position)
                case .book: self.player.seek(toBookOffset: position)
                }
            }
            return .success
        }

        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates = AppSettings.speedPresets.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            MainActor.assumeIsolated { self?.player.setSpeed(rate) }
            return .success
        }

        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.bookmarkCommand.isEnabled = false
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.enableLanguageOptionCommand.isEnabled = false
        center.disableLanguageOptionCommand.isEnabled = false
    }

    // MARK: - Now playing info

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let book = player.book else {
            center.nowPlayingInfo = nil
            artworkImage = nil
            artworkBookID = nil
            artworkID = nil
            artworkLoading = false
            widgetCoverID = nil
            SharedNowPlaying.write(nil)
            SharedNowPlaying.writeCover(nil)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        if artworkBookID != book.id || artworkID != book.artworkID {
            if artworkBookID == book.id {
                Logger.nowPlaying.info("[nowplaying] cover changed for \(book.title, privacy: .public) — reloading artwork")
            }
            artworkBookID = book.id
            artworkID = book.artworkID
            artworkImage = nil
            artworkLoading = true
            let wanted = book.artworkID
            Task { [weak self] in
                let image = await ArtworkStore.shared.loadImage(for: wanted)
                guard let self, self.artworkBookID == book.id, self.artworkID == wanted else { return }
                self.artworkImage = image
                self.artworkLoading = false
                self.update()
            }
        }

        let chapter = player.currentChapter
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter?.title ?? book.title,
            MPMediaItemPropertyAlbumTitle: book.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.speed),
        ]
        if book.author != nil || book.narratorCredit != nil {
            info[MPMediaItemPropertyArtist] = book.displayCredits
        }
        let elapsed: TimeInterval
        let duration: TimeInterval
        switch settings.lockScreenTimeMode {
        case .chapter:
            elapsed = player.chapterElapsed
            duration = player.chapterDuration
        case .book:
            elapsed = player.bookElapsed
            duration = player.bookDuration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPMediaItemPropertyPlaybackDuration] = duration
        if let index = player.currentChapterIndex {
            info[MPNowPlayingInfoPropertyChapterNumber] = index + 1
            info[MPNowPlayingInfoPropertyChapterCount] = book.chapters.count
        }
        if let image = artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info

        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForwardInterval)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBackInterval)]

        publishWidgetSnapshot(book: book)

        Logger.nowPlaying.debug("[nowplaying] \(chapter?.title ?? book.title, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 0)) dur=\(duration, format: .fixed(precision: 0)) playing=\(self.player.isPlaying)")
    }

    private var lastWidgetSnapshot: NowPlayingSnapshot?

    /// Shares the minimal state the Continue Listening widget draws, and refreshes it — but only when
    /// something it shows actually changed, so we don't reload the widget on every playback tick.
    private func publishWidgetSnapshot(book: Book) {
        // With the lock on, the Home Screen mustn't say what's being listened to; the widget
        // still opens the book, after Face ID.
        let locked = settings.lockMode != .off
        let snapshot = NowPlayingSnapshot(
            bookID: book.id,
            title: locked ? "Continue listening" : book.title,
            author: locked ? "Earmark is locked" : book.displayAuthor,
            narrator: locked ? nil : book.narrator,
            fraction: locked ? 0 : player.bookFraction,
            remaining: locked ? "" : player.bookRemaining.shortDurationString + " left",
            isPlaying: player.isPlaying,
            updatedAt: .now
        )
        // Once the artwork has loaded, a new cover — or none, for a book without art — counts as a
        // change even when nothing else moved; otherwise the widget kept the previous book's cover.
        let cover: String? = locked ? "" : artworkLoading ? nil : (artworkImage == nil ? "" : artworkID ?? "")
        let coverChanged = cover != nil && cover != widgetCoverID
        guard coverChanged || lastWidgetSnapshot?.widgetUpdateKey != snapshot.widgetUpdateKey else { return }
        lastWidgetSnapshot = snapshot
        SharedNowPlaying.write(snapshot)
        if coverChanged, let cover {
            SharedNowPlaying.writeCover(locked ? nil : artworkImage?.jpegData(compressionQuality: 0.8))
            widgetCoverID = cover
            Logger.nowPlaying.debug("[nowplaying] widget cover → \(cover.isEmpty ? "none" : cover, privacy: .public)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
