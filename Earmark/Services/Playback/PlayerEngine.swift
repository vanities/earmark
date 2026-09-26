import AVFoundation
import Foundation
import Observation
import os

// One state machine around one AVPlayer. Every section drives that player and its private
// state, so splitting the file would mean opening both to the whole app; it runs past the
// 700-line lint warning on purpose.
// swiftlint:disable file_length

enum SleepTimerMode: Hashable, Sendable {
    case off
    case duration(TimeInterval)
    case endOfChapter

    var title: String {
        switch self {
        case .off: "Off"
        case .duration(let seconds): seconds.shortDurationString
        case .endOfChapter: "End of chapter"
        }
    }

    var isActive: Bool { self != .off }
}

/// Single `AVPlayer` driving one book at a time. Multi-file books advance track by
/// track; positions are persisted through `LibraryModel`.
@MainActor @Observable
final class PlayerEngine {
    private(set) var book: Book?
    /// Set when a book finishes and the next in its series is available — drives the Up Next offer.
    private(set) var upNext: Book?
    private(set) var trackIndex = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var trackDuration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var speed: Float = 1.0
    private(set) var sleepTimer: SleepTimerMode = .off
    private(set) var sleepRemaining: TimeInterval?
    /// Where the listener was before the last long jump — a chapter tap, a scrub, a bookmark, a position
    /// from another device — so a mis-tap in the car is one tap to undo. Cleared once they listen on.
    private(set) var jumpOrigin: BookPosition?
    /// True while the current track streams from a NAS instead of local storage.
    private(set) var isRemote = false
    private(set) var remoteServerName: String?

    /// Fired on discrete changes (load/play/pause/seek/speed/track), not every tick.
    @ObservationIgnored var stateDidChange: (() -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var routeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pendingSeek: TimeInterval?
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var ticks = 0
    /// Ticks of playback since the last long jump; the undo goes away after `jumpUndoWindow` of listening.
    @ObservationIgnored private var ticksSinceJump = 0
    /// The chapter the lock screen / CarPlay last heard about, so a new chapter is announced right away.
    @ObservationIgnored private var notifiedChapterIndex: Int?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var sleepEndsAt: Date?
    @ObservationIgnored private var sleepArmedChapterIndex: Int?
    @ObservationIgnored private var itemGeneration = 0
    @ObservationIgnored private var didFinishCurrentBook = false
    /// Downloads listened to the end here, with Remove when finished on. They go once another
    /// book starts — not at the end itself, where Listen Again and Up Next still want the file.
    @ObservationIgnored private var finishedDownloadIDs: Set<String> = []
    @ObservationIgnored private var currentLoader: SMBResourceLoader?
    /// Time actually listened, for Stats (`ListeningRecorder`, recorded through the library).
    @ObservationIgnored private var listening = ListeningRecorder()
    @ObservationIgnored private let audioProcessor = PlaybackAudioProcessor()

    init(library: LibraryModel, settings: AppSettings) {
        self.library = library
        self.settings = settings
        player.automaticallyWaitsToMinimizeStalling = false
        AudioSessionManager.configure()
        installObservers()
        audioProcessor.onRateChange = { [weak self] rate in
            // Only nudge the rate while actually playing; never resume a paused book.
            guard let self, self.isPlaying else { return }
            self.player.rate = rate
        }
    }

    // MARK: - Derived state

    var currentChapterIndex: Int? { book?.chapterIndex(trackIndex: trackIndex, time: currentTime) }
    var currentChapter: Chapter? { currentChapterIndex.flatMap { book?.chapters[$0] } }
    var chapterElapsed: TimeInterval { currentChapter.map { max(0, currentTime - $0.start) } ?? currentTime }
    var chapterDuration: TimeInterval { currentChapter?.duration ?? trackDuration }
    var bookElapsed: TimeInterval { book?.absoluteOffset(trackIndex: trackIndex, time: currentTime) ?? 0 }
    var bookDuration: TimeInterval { book?.totalDuration ?? 0 }
    var bookRemaining: TimeInterval { max(0, bookDuration - bookElapsed) }
    var bookFraction: Double { bookDuration > 0 ? min(1, bookElapsed / bookDuration) : 0 }
    var hasBook: Bool { book != nil }
    /// The book in the player is playing, or was played recently enough to pick up again — see
    /// `isRecentlyPlayed`. Opening Earmark then goes to Now Playing.
    var wasRecentlyPlayed: Bool {
        guard let book else { return false }
        return Self.isRecentlyPlayed(isPlaying: isPlaying, progress: library.progress(for: book.id),
                                     hasUpNext: upNext != nil, now: .now)
    }

    var queueKeys: [String] { settings.queueKeys }
    func queuedBook(for key: String) -> Book? { library.visibleBooks.first { $0.syncKey == key } }
    func enqueue(_ book: Book) {
        guard self.book?.syncKey != book.syncKey, !settings.queueKeys.contains(book.syncKey) else { return }
        settings.queueKeys.append(book.syncKey)
        refreshQueueOffer()
    }
    func removeQueued(at offsets: IndexSet) {
        settings.queueKeys.remove(atOffsets: offsets)
        refreshQueueOffer()
    }
    func moveQueued(from offsets: IndexSet, to destination: Int) {
        settings.queueKeys.move(fromOffsets: offsets, toOffset: destination)
        refreshQueueOffer()
    }
    private func refreshQueueOffer() {
        guard didFinishCurrentBook, let book else { return }
        upNext = settings.queueKeys.first.flatMap { queuedBook(for: $0) }
            ?? (settings.queueKeys.isEmpty ? library.nextInSeries(after: book) : nil)
    }

    var bedtimeBookmark: Bookmark? {
        guard let book else { return nil }
        return library.bookmarks(for: book).filter { $0.note.hasPrefix("Bedtime · ") }.max { $0.createdAt < $1.createdAt }
    }

    // MARK: - Loading

    /// Loads a book at its saved position (or `startAt`). Reloading the current book just
    /// resumes it, or jumps to `startAt` when given.
    func load(_ newBook: Book, autoplay: Bool, startAt: BookPosition? = nil) {
        settings.queueKeys.removeAll { $0 == newBook.syncKey }
        if book?.id == newBook.id {
            if let startAt {
                pausedAt = nil   // a chosen spot (a chapter tap): don't smart-rewind back out of it
                let crossesTrack = startAt.trackIndex != trackIndex
                jumping {
                    if crossesTrack {
                        loadTrack(index: startAt.trackIndex, startAt: startAt.time, autoplay: autoplay || isPlaying)
                    } else {
                        seek(toTrackTime: startAt.time)
                    }
                }
                if autoplay, !crossesTrack { play() }
            } else if autoplay {
                play()
            }
            return
        }
        Logger.player.info("[player] load \(newBook.title, privacy: .public) tracks=\(newBook.tracks.count) chapters=\(newBook.chapters.count) autoplay=\(autoplay)")
        persistPosition()
        finishListening()
        cancelSleepTimer(notify: false)
        book = newBook
        upNext = nil
        errorMessage = nil
        didFinishCurrentBook = false
        pausedAt = nil
        jumpOrigin = nil

        var saved = library.progress(for: newBook.id)
        if saved.isFinished {
            Logger.player.info("[player] book was finished — starting over")
            saved = PlaybackProgress(speed: saved.speed)
        }
        speed = settings.rememberSpeedPerBook ? (saved.speed ?? settings.defaultSpeed) : settings.defaultSpeed
        player.defaultRate = speed
        library.setCurrentBook(newBook.id)

        var position = startAt ?? BookPosition(trackIndex: saved.trackIndex, time: saved.time)
        if startAt == nil, settings.smartRewind, let lastPlayed = saved.lastPlayedAt {
            if autoplay {
                position = Self.resumePosition(in: newBook, from: position, pausedFor: Date().timeIntervalSince(lastPlayed))
            } else {
                pausedAt = lastPlayed
            }
        }
        let index = min(max(0, position.trackIndex), max(0, newBook.tracks.count - 1))
        loadTrack(index: index, startAt: position.time, autoplay: autoplay)
        // Only now, with the new book's file in the player, can the finished one's go.
        removeFinishedDownloads(startingOver: newBook.id)
    }

    /// Picks up scan changes (precise durations, new chapters) without interrupting playback.
    func refreshBookFromLibrary() {
        guard let current = book else { return }
        if let fresh = library.book(id: current.id) {
            if fresh != current {
                book = fresh
                notify()   // the lock screen picks up edits (e.g. a replaced cover) now, not on the next tick
            }
        } else {
            Logger.player.notice("[player] current book disappeared from library — unloading")
            unload()
        }
    }

    /// A saved position changed outside the player: iCloud brought a newer one from another device, or
    /// the book was reset. Unless it's playing here, move there — otherwise this device's next save would
    /// write its stale spot back over it. A device that's playing is where the listening is; it keeps its place.
    func savedPositionChanged(for bookIDs: Set<String>) {
        guard let book, bookIDs.contains(book.id), !isPlaying else { return }
        let saved = library.progress(for: book.id)
        guard !saved.isFinished, book.tracks.indices.contains(saved.trackIndex),
              saved.trackIndex != trackIndex || abs(saved.time - currentTime) >= 1 else { return }
        Logger.player.info("[player] following saved position track=\(saved.trackIndex) time=\(saved.time, format: .fixed(precision: 1)) (was track=\(self.trackIndex) time=\(self.currentTime, format: .fixed(precision: 1)))")
        pausedAt = nil
        jumping {
            if saved.trackIndex != trackIndex {
                loadTrack(index: saved.trackIndex, startAt: saved.time, autoplay: playWhenReady)
            } else {
                performSeek(saved.time, thenPlay: false)
                notify()
            }
        }
    }

    func unload() {
        persistPosition()
        finishListening()
        jumpOrigin = nil
        detachItemObservers()
        player.replaceCurrentItem(with: nil)
        currentLoader = nil
        isRemote = false
        remoteServerName = nil
        book = nil
        upNext = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        trackDuration = 0
        cancelSleepTimer(notify: false)
        notify()
    }

    /// Accept the Up Next offer: play the next book in the series.
    func playUpNext() {
        guard let next = upNext else { return }
        upNext = nil
        load(next, autoplay: true)
    }

    func dismissUpNext() { upNext = nil }

    private func loadTrack(index: Int, startAt time: TimeInterval, autoplay: Bool) {
        guard let book, book.tracks.indices.contains(index) else { return }
        let track = book.tracks[index]
        guard let source = library.playbackSource(forTrack: track, in: book) else {
            fail(library.isRemote(book) ? "This NAS isn't set up anymore. Add it again under Folders." : "This book's folder isn't available. Re-add it under Folders.")
            return
        }
        let sw = Stopwatch()
        itemGeneration += 1
        let generation = itemGeneration
        detachItemObservers()

        trackIndex = index
        currentTime = time
        trackDuration = track.duration
        isLoading = true
        errorMessage = nil
        pendingSeek = time
        playWhenReady = autoplay
        didFinishCurrentBook = false

        currentLoader = source.loader
        isRemote = source.isRemote
        remoteServerName = source.serverName
        player.automaticallyWaitsToMinimizeStalling = source.isRemote
        let item = AVPlayerItem(asset: source.asset)
        item.audioTimePitchAlgorithm = .timeDomain
        attachAudioProcessor(to: item, asset: source.asset, generation: generation)
        if source.isRemote { item.preferredForwardBufferDuration = 30 }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.handleItemStatus(generation: generation) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackDidEnd() }
        }
        player.replaceCurrentItem(with: item)
        Logger.player.info("[player] loadTrack index=\(index) file=\(track.fileName, privacy: .public) start=\(time, format: .fixed(precision: 1)) autoplay=\(autoplay) in \(sw.ms, format: .fixed(precision: 1))ms")
        notify()
    }

    private func handleItemStatus(generation: Int) {
        guard generation == itemGeneration, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let seconds = CMTimeGetSeconds(item.duration)
            if seconds.isFinite, seconds > 0 {
                trackDuration = seconds
                if let book {
                    library.updateTrackDuration(bookID: book.id, trackIndex: trackIndex, duration: seconds)
                    refreshBookFromLibrary()
                }
            }
            isLoading = false
            let shouldPlay = playWhenReady
            playWhenReady = false
            if let target = pendingSeek {
                pendingSeek = nil
                performSeek(target, thenPlay: shouldPlay)
            } else if shouldPlay {
                startPlayback()
            }
            Logger.player.info("[player] ready track=\(self.trackIndex) duration=\(seconds, format: .fixed(precision: 1))")
            notify()
        case .failed:
            isLoading = false
            isPlaying = false
            finishListening()
            if isRemote {
                errorMessage = "Couldn't reach \(remoteServerName ?? "your NAS"). Make sure this iPhone is on the same network (or VPN) as the NAS, then tap play to retry."
            } else {
                errorMessage = item.error?.localizedDescription ?? "Couldn't play this file."
            }
            Logger.player.error("[player] item failed track=\(self.trackIndex): \(item.error?.localizedDescription ?? "unknown", privacy: .public)")
            notify()
        default:
            break
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        isLoading = false
        isPlaying = false
        finishListening()
        Logger.player.error("[player] \(message, privacy: .public)")
        notify()
    }

    // MARK: - Transport

    func play() {
        guard book != nil else { return }
        if errorMessage != nil, let book {
            // Retry the current track (e.g. the folder came back).
            loadTrack(index: trackIndex, startAt: currentTime, autoplay: true)
            _ = book
            return
        }
        if didFinishCurrentBook {
            // Play on a finished book starts it over, as opening it from the Library does. AVPlayer
            // can't play on from the end, so without this the button did nothing.
            Logger.player.info("[player] book was finished — starting over")
            loadTrack(index: 0, startAt: 0, autoplay: true)
            notify()
            return
        }
        if let pausedAt, settings.smartRewind {
            let gap = Date().timeIntervalSince(pausedAt)
            let rewind = Self.smartRewindAmount(pausedFor: gap)
            if rewind > 0 {
                Logger.player.info("[player] smart rewind \(rewind, format: .fixed(precision: 0))s after \(gap, format: .fixed(precision: 0))s pause")
                self.pausedAt = nil
                if let book {
                    let target = Self.resumePosition(in: book, from: BookPosition(trackIndex: trackIndex, time: currentTime), pausedFor: gap)
                    if target.trackIndex != trackIndex {
                        loadTrack(index: target.trackIndex, startAt: target.time, autoplay: true)
                    } else {
                        performSeek(target.time, thenPlay: true)
                    }
                }
                notify()
                return
            }
        }
        if isLoading {
            playWhenReady = true
            return
        }
        startPlayback()
        notify()
    }

    func pause() {
        guard isPlaying || player.rate != 0 else { return }
        player.pause()
        isPlaying = false
        pausedAt = .now
        persistPosition()
        finishListening()
        Logger.player.info("[player] paused at \(self.currentTime, format: .fixed(precision: 1))")
        notify()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    private func startPlayback() {
        AudioSessionManager.activate()
        player.volume = 1
        player.defaultRate = speed
        player.playImmediately(atRate: speed)
        isPlaying = true
        pausedAt = nil
        didFinishCurrentBook = false
        Logger.player.debug("[player] playing at \(self.speed, format: .fixed(precision: 2))x")
    }

    /// End-of-chapter sleep starts fading when the chapter has one fade's worth of listening left, so the
    /// pause lands on the boundary instead of a few seconds into the next chapter.
    nonisolated static func shouldStartChapterFade(remaining: TimeInterval, speed: Float) -> Bool {
        remaining <= sleepFadeDuration * Double(max(speed, 0.5))
    }

    nonisolated static func resumePosition(in book: Book, from position: BookPosition, pausedFor gap: TimeInterval) -> BookPosition {
        let rewind = smartRewindAmount(pausedFor: gap)
        guard rewind > 0 else { return position }
        let offset = book.absoluteOffset(trackIndex: position.trackIndex, time: position.time)
        return book.position(atAbsoluteOffset: max(0, offset - rewind))
    }

    nonisolated static func smartRewindAmount(pausedFor gap: TimeInterval) -> TimeInterval {
        switch gap {
        case ..<60: 0
        case ..<300: 3
        case ..<1800: 8
        case ..<7200: 15
        default: 30
        }
    }

    /// How long after listening a book still counts as the one you're in the middle of.
    nonisolated static let recentListeningWindow: TimeInterval = 2 * 60 * 60

    /// Playing, or last played within `recentListeningWindow` with more to hear — or finished with
    /// an Up Next offer waiting. A finished book with nothing next isn't one to press play on.
    nonisolated static func isRecentlyPlayed(isPlaying: Bool, progress: PlaybackProgress, hasUpNext: Bool, now: Date) -> Bool {
        if isPlaying { return true }
        guard let last = progress.lastPlayedAt, now.timeIntervalSince(last) < recentListeningWindow else { return false }
        return !progress.isFinished || hasUpNext
    }

    // MARK: - Seeking

    func skipForward() { skip(by: settings.skipForwardInterval) }
    func skipBackward() { skip(by: -settings.skipBackInterval) }

    func skip(by delta: TimeInterval) {
        guard let book else { return }
        pausedAt = nil
        var target = currentTime + delta
        if target < 0 {
            if trackIndex > 0 {
                let previous = book.tracks[trackIndex - 1]
                loadTrack(index: trackIndex - 1, startAt: max(0, previous.duration + target), autoplay: isPlaying)
                return
            }
            target = 0
        } else if trackDuration > 0, target >= trackDuration {
            if trackIndex + 1 < book.tracks.count {
                loadTrack(index: trackIndex + 1, startAt: target - trackDuration, autoplay: isPlaying)
                return
            }
            target = max(0, trackDuration - 1)
        }
        seek(toTrackTime: target)
    }

    /// A spot the listener chose (scrub, skip, chapter). Smart rewind is only for resuming where you
    /// paused, so it's cleared — otherwise playing after a chapter tap rewound into the previous chapter.
    func seek(toTrackTime time: TimeInterval) {
        pausedAt = nil
        performSeek(time, thenPlay: false)
        persistPosition()
        notify()
    }

    func seek(toChapterTime time: TimeInterval) {
        jumping {
            guard let chapter = currentChapter else {
                seek(toTrackTime: time)
                return
            }
            seek(toTrackTime: chapter.start + time)
        }
    }

    func seek(toBookOffset offset: TimeInterval) {
        guard let book else { return }
        pausedAt = nil
        let position = book.position(atAbsoluteOffset: offset)
        jumping {
            if position.trackIndex != trackIndex {
                loadTrack(index: position.trackIndex, startAt: position.time, autoplay: isPlaying)
            } else {
                seek(toTrackTime: position.time)
            }
        }
    }

    func jump(to chapter: Chapter) {
        guard let book, book.tracks.indices.contains(chapter.trackIndex) else { return }
        pausedAt = nil
        Logger.player.info("[player] jump to chapter \(chapter.title, privacy: .public)")
        jumping {
            if chapter.trackIndex != trackIndex {
                loadTrack(index: chapter.trackIndex, startAt: chapter.start, autoplay: isPlaying)
            } else {
                seek(toTrackTime: chapter.start)
            }
        }
    }

    // MARK: - Undo jump

    /// A move this far (either way) is worth offering to undo; skips and small scrubs aren't.
    nonisolated static let undoableJumpDistance: TimeInterval = 30
    /// Listening this long after a jump means it was wanted, and the undo goes away.
    nonisolated static let jumpUndoWindow: TimeInterval = 120

    nonisolated static func isUndoableJump(from: TimeInterval, to: TimeInterval) -> Bool {
        abs(to - from) >= undoableJumpDistance
    }

    /// Runs a navigation, remembering where it started when it went far.
    private func jumping(_ move: () -> Void) {
        guard let book else { return move() }
        let origin = BookPosition(trackIndex: trackIndex, time: currentTime)
        let from = book.absoluteOffset(trackIndex: trackIndex, time: currentTime)
        move()
        let to = book.absoluteOffset(trackIndex: trackIndex, time: currentTime)
        guard Self.isUndoableJump(from: from, to: to) else { return }
        jumpOrigin = origin
        ticksSinceJump = 0
        Logger.player.info("[player] jumped \(from, format: .fixed(precision: 0))s → \(to, format: .fixed(precision: 0))s; undo available")
    }

    /// Goes back to where the listener was before the last long jump.
    func undoJump() {
        guard let origin = jumpOrigin, let book, book.tracks.indices.contains(origin.trackIndex) else { return }
        jumpOrigin = nil
        pausedAt = nil
        Logger.player.info("[player] undo jump → track=\(origin.trackIndex) time=\(origin.time, format: .fixed(precision: 1))")
        if origin.trackIndex != trackIndex {
            loadTrack(index: origin.trackIndex, startAt: origin.time, autoplay: isPlaying)
            persistPosition()
        } else {
            seek(toTrackTime: origin.time)
        }
    }

    func nextChapter() {
        guard let book, let index = currentChapterIndex, index + 1 < book.chapters.count else { return }
        jump(to: book.chapters[index + 1])
    }

    /// Restarts the current chapter, or goes back one if we're within its first 3 seconds.
    func previousChapter() {
        guard let book, let index = currentChapterIndex else { return }
        if chapterElapsed > 3 || index == 0 {
            jump(to: book.chapters[index])
        } else {
            jump(to: book.chapters[index - 1])
        }
    }

    private func performSeek(_ time: TimeInterval, thenPlay: Bool) {
        let upper = trackDuration > 0 ? max(0, trackDuration - 0.25) : time
        let clamped = max(0, min(time, upper))
        currentTime = clamped
        if isLoading {
            // The item isn't ready yet; apply once it is.
            pendingSeek = clamped
            if thenPlay { playWhenReady = true }
            return
        }
        let generation = itemGeneration
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, generation == self.itemGeneration else { return }
                if finished, thenPlay { self.startPlayback() }
                self.notify()
            }
        }
    }

    // MARK: - Speed

    /// Routes the current item through the volume-boost / skip-silence tap. No-op on failure, so a
    /// book always plays even if the effect can't attach.
    private func attachAudioProcessor(to item: AVPlayerItem, asset: AVAsset, generation: Int) {
        audioProcessor.update(gain: settings.volumeBoost, skipSilence: settings.skipSilence, baseRate: speed, boostQuiet: settings.boostQuietVoices)
        // Only build the (CPU-touching) tap when an effect is actually on.
        guard settings.volumeBoost != 1 || settings.skipSilence || settings.boostQuietVoices else { return }
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            await MainActor.run {
                guard let self, generation == self.itemGeneration,
                      self.player.currentItem === item,
                      let mix = self.audioProcessor.makeAudioMix(for: track) else { return }
                item.audioMix = mix
            }
        }
    }

    /// Pushes the latest boost / skip-silence settings to the live tap (called when the user changes
    /// them in Settings). If the current item has no tap yet and an effect just turned on, reattach.
    func applyPlaybackEffects() {
        audioProcessor.update(gain: settings.volumeBoost, skipSilence: settings.skipSilence, baseRate: speed, boostQuiet: settings.boostQuietVoices)
        if let item = player.currentItem, item.audioMix == nil, settings.volumeBoost != 1 || settings.skipSilence || settings.boostQuietVoices {
            attachAudioProcessor(to: item, asset: item.asset, generation: itemGeneration)
        }
        notify()
    }

    func setSpeed(_ value: Float) {
        let range = AppSettings.speedRange
        let clamped = (min(max(value, range.lowerBound), range.upperBound) * 100).rounded() / 100
        speed = clamped
        player.defaultRate = clamped
        if isPlaying { player.rate = clamped }
        audioProcessor.update(gain: settings.volumeBoost, skipSilence: settings.skipSilence, baseRate: clamped, boostQuiet: settings.boostQuietVoices)
        if let book, settings.rememberSpeedPerBook {
            library.setSpeed(clamped, for: book.id)
        }
        Logger.player.info("[player] speed=\(clamped, format: .fixed(precision: 2))")
        notify()
    }

    func cycleSpeed() {
        let presets = AppSettings.speedPresets
        let next = presets.first { $0 > speed + 0.001 } ?? presets[0]
        setSpeed(next)
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ mode: SleepTimerMode) {
        if mode != .off, sleepTimer == .off, settings.bedtimeBookmarks, let book {
            let note = "Bedtime · " + Date.now.formatted(.dateTime.year().month().day())
            if !library.bookmarks(for: book).contains(where: { $0.note == note }) {
                _ = library.addBookmark(for: book, offset: bookElapsed, note: note)
            }
        }
        cancelSleepTimer(notify: false)
        sleepTimer = mode
        switch mode {
        case .off:
            break
        case .endOfChapter:
            sleepArmedChapterIndex = currentChapterIndex
        case .duration(let seconds):
            sleepEndsAt = Date().addingTimeInterval(seconds)
            sleepRemaining = seconds
            sleepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, let endsAt = self.sleepEndsAt else { return }
                    guard self.isPlaying else {
                        // Paused: hold the countdown, so a pause mid-timer doesn't eat into it.
                        self.sleepEndsAt = endsAt.addingTimeInterval(1)
                        continue
                    }
                    let remaining = endsAt.timeIntervalSinceNow
                    self.sleepRemaining = max(0, remaining)
                    if remaining <= 0 {
                        self.fadeOutAndPause(reason: "timer")
                        return
                    }
                }
            }
        }
        Logger.player.info("[player] sleep timer \(mode.title, privacy: .public)")
        notify()
    }

    /// Adds time to a running countdown ("+5 min" at bedtime) without restarting it.
    func extendSleepTimer(by seconds: TimeInterval) {
        guard case .duration = sleepTimer, let endsAt = sleepEndsAt else { return }
        sleepEndsAt = endsAt.addingTimeInterval(seconds)
        sleepRemaining = max(0, endsAt.timeIntervalSinceNow) + seconds
        Logger.player.info("[player] sleep timer +\(Int(seconds / 60)) min → \(self.sleepRemaining ?? 0, format: .fixed(precision: 0))s left")
        notify()
    }

    private func cancelSleepTimer(notify shouldNotify: Bool) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEndsAt = nil
        sleepRemaining = nil
        sleepArmedChapterIndex = nil
        sleepTimer = .off
        if shouldNotify { notify() }
    }

    /// How long the sleep timer's fade takes, in wall-clock seconds.
    nonisolated static let sleepFadeDuration: TimeInterval = 2.5

    private func fadeOutAndPause(reason: String) {
        Logger.player.info("[player] sleep timer fired (\(reason, privacy: .public))")
        cancelSleepTimer(notify: false)
        guard isPlaying else { return }
        Task { [weak self] in
            for step in stride(from: 9, through: 0, by: -1) {
                guard let self else { return }
                guard self.isPlaying else {
                    // Paused mid-fade: put the volume back, or the next play starts quiet.
                    self.player.volume = 1
                    return
                }
                self.player.volume = Float(step) / 10
                try? await Task.sleep(for: .milliseconds(Int(Self.sleepFadeDuration * 100)))
            }
            guard let self else { return }
            self.pause()
            self.player.volume = 1
        }
        notify()
    }

    // MARK: - Track boundaries

    private func trackDidEnd() {
        guard let book else { return }
        Logger.player.info("[player] track ended index=\(self.trackIndex)/\(book.tracks.count)")
        let sleepAtChapterEnd = sleepTimer == .endOfChapter
        if trackIndex + 1 < book.tracks.count {
            if sleepAtChapterEnd {
                cancelSleepTimer(notify: false)
                isPlaying = false
                finishListening()
                loadTrack(index: trackIndex + 1, startAt: 0, autoplay: false)
                persistPosition()
            } else {
                loadTrack(index: trackIndex + 1, startAt: 0, autoplay: true)
            }
        } else {
            isPlaying = false
            finishListening()
            currentTime = trackDuration
            didFinishCurrentBook = true
            library.markFinished(book.id)
            if settings.removeFinishedDownloads, library.downloadedCopy(of: book)?.id == book.id {
                finishedDownloadIDs.insert(book.id)
                Logger.downloads.info("[downloads] \(book.title, privacy: .public) finished — removing its download when another book starts")
            }
            let continueQueue = settings.autoplayQueue && sleepTimer == .off
            let queued = settings.queueKeys.first.flatMap { queuedBook(for: $0) }
            upNext = queued ?? (settings.queueKeys.isEmpty ? library.nextInSeries(after: book) : nil)
            if upNext != nil { Logger.player.info("[player] up next: \(self.upNext?.title ?? "-", privacy: .public)") }
            cancelSleepTimer(notify: false)
            AudioSessionManager.deactivate()
            Logger.player.info("[player] finished \(book.title, privacy: .public)")
            notify()
            if continueQueue, let queued { load(queued, autoplay: true) }
        }
    }

    // MARK: - Observers

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(CMTimeGetSeconds(time)) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncPlayingState() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.handleRouteChange(reason) }
        }
    }

    private func detachItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func tick(_ seconds: TimeInterval) {
        guard !isLoading, pendingSeek == nil, seconds.isFinite else { return }
        currentTime = seconds
        ticks += 1
        if ticks % 10 == 0 { persistPosition() }
        if isPlaying, let book {
            if let finished = listening.tick(bookID: book.id, bookKey: book.syncKey, title: book.title) {
                library.recordSession(finished)
            }
            // Every minute: a session cut off by the app being killed still counts next launch.
            if ticks % 120 == 0 { ListeningCheckpoint.save(listening.open) }
        }
        if ticks % 30 == 0 || currentChapterIndex != notifiedChapterIndex { notify() }
        if jumpOrigin != nil, isPlaying {
            ticksSinceJump += 1
            if Double(ticksSinceJump) / 2 >= Self.jumpUndoWindow { jumpOrigin = nil }
        }
        if sleepTimer == .endOfChapter, let armed = sleepArmedChapterIndex, let now = currentChapterIndex {
            if now != armed {
                // Skipped or scrubbed to another chapter: stop at the end of that one instead.
                sleepArmedChapterIndex = now
                Logger.player.info("[player] sleep timer re-armed for chapter \(now + 1)")
            } else if isPlaying, Self.shouldStartChapterFade(remaining: chapterDuration - chapterElapsed, speed: speed) {
                fadeOutAndPause(reason: "end of chapter")
            }
        }
    }

    private func syncPlayingState() {
        guard player.currentItem != nil, !isLoading else { return }
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying else { return }
        Logger.player.debug("[player] timeControlStatus → playing=\(playing)")
        isPlaying = playing
        if !playing {
            pausedAt = .now
            persistPosition()
            finishListening()
        }
        notify()
    }

    /// Playback stopped (or moved to another book): the session so far goes to the library.
    /// Every path that sets `isPlaying = false` calls this itself — `syncPlayingState` sees no
    /// change after one of them, so it can't be left to catch those.
    private func finishListening() {
        if let session = listening.finish() { library.recordSession(session) }
        ListeningCheckpoint.save(nil)
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            Logger.player.info("[player] interruption began (wasPlaying=\(self.isPlaying))")
            if isPlaying {
                player.pause()
                isPlaying = false
                pausedAt = .now
                persistPosition()
                finishListening()
                notify()
            }
        case .ended:
            Logger.player.info("[player] interruption ended shouldResume=\(options.contains(.shouldResume))")
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                play()
            }
            wasPlayingBeforeInterruption = false
        default:
            break
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable, isPlaying else { return }
        Logger.player.info("[player] audio route lost — pausing")
        pause()
    }

    /// Moving on from a book finished here removes its download (unless it's the one starting).
    private func removeFinishedDownloads(startingOver nextID: String) {
        let finished = finishedDownloadIDs.subtracting([nextID]).compactMap { library.book(id: $0) }
        finishedDownloadIDs.removeAll()
        guard !finished.isEmpty, settings.removeFinishedDownloads else { return }
        let result = library.removeDownloads(finished)
        Logger.downloads.info("[downloads] removed \(result.count) finished download(s) bytes=\(result.bytes) on moving on")
    }

    // MARK: - Persistence

    func persistPosition() {
        guard let book, !didFinishCurrentBook else { return }
        library.recordPosition(bookID: book.id, trackIndex: trackIndex, time: currentTime)
    }

    private func notify() {
        notifiedChapterIndex = currentChapterIndex
        stateDidChange?()
    }
}
