import AVFoundation
import Foundation
import Observation
import os

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
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var sleepEndsAt: Date?
    @ObservationIgnored private var sleepArmedChapterIndex: Int?
    @ObservationIgnored private var itemGeneration = 0
    @ObservationIgnored private var didFinishCurrentBook = false
    @ObservationIgnored private var currentLoader: SMBResourceLoader?
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

    // MARK: - Loading

    /// Loads a book at its saved position (or `startAt`). Reloading the current book just
    /// resumes it, or jumps to `startAt` when given.
    func load(_ newBook: Book, autoplay: Bool, startAt: BookPosition? = nil) {
        if book?.id == newBook.id {
            if let startAt {
                if startAt.trackIndex != trackIndex {
                    loadTrack(index: startAt.trackIndex, startAt: startAt.time, autoplay: autoplay || isPlaying)
                } else {
                    seek(toTrackTime: startAt.time)
                    if autoplay { play() }
                }
            } else if autoplay {
                play()
            }
            return
        }
        Logger.player.info("[player] load \(newBook.title, privacy: .public) tracks=\(newBook.tracks.count) chapters=\(newBook.chapters.count) autoplay=\(autoplay)")
        persistPosition()
        cancelSleepTimer(notify: false)
        book = newBook
        upNext = nil
        errorMessage = nil
        didFinishCurrentBook = false
        pausedAt = nil

        var saved = library.progress(for: newBook.id)
        if saved.isFinished {
            Logger.player.info("[player] book was finished — starting over")
            saved = PlaybackProgress(speed: saved.speed)
        }
        speed = settings.rememberSpeedPerBook ? (saved.speed ?? settings.defaultSpeed) : settings.defaultSpeed
        player.defaultRate = speed
        library.setCurrentBook(newBook.id)

        let position = startAt ?? BookPosition(trackIndex: saved.trackIndex, time: saved.time)
        let index = min(max(0, position.trackIndex), max(0, newBook.tracks.count - 1))
        loadTrack(index: index, startAt: position.time, autoplay: autoplay)
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

    func unload() {
        persistPosition()
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
        if isLoading {
            playWhenReady = true
            return
        }
        if let pausedAt, settings.smartRewind {
            let gap = Date().timeIntervalSince(pausedAt)
            let rewind = Self.smartRewindAmount(pausedFor: gap)
            if rewind > 0 {
                Logger.player.info("[player] smart rewind \(rewind, format: .fixed(precision: 0))s after \(gap, format: .fixed(precision: 0))s pause")
                self.pausedAt = nil
                performSeek(max(0, currentTime - rewind), thenPlay: true)
                notify()
                return
            }
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
        player.defaultRate = speed
        player.playImmediately(atRate: speed)
        isPlaying = true
        pausedAt = nil
        didFinishCurrentBook = false
        Logger.player.debug("[player] playing at \(self.speed, format: .fixed(precision: 2))x")
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

    // MARK: - Seeking

    func skipForward() { skip(by: settings.skipForwardInterval) }
    func skipBackward() { skip(by: -settings.skipBackInterval) }

    func skip(by delta: TimeInterval) {
        guard let book else { return }
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

    func seek(toTrackTime time: TimeInterval) {
        performSeek(time, thenPlay: false)
        persistPosition()
        notify()
    }

    func seek(toChapterTime time: TimeInterval) {
        guard let chapter = currentChapter else {
            seek(toTrackTime: time)
            return
        }
        seek(toTrackTime: chapter.start + time)
    }

    func seek(toBookOffset offset: TimeInterval) {
        guard let book else { return }
        let position = book.position(atAbsoluteOffset: offset)
        if position.trackIndex != trackIndex {
            loadTrack(index: position.trackIndex, startAt: position.time, autoplay: isPlaying)
        } else {
            seek(toTrackTime: position.time)
        }
    }

    func jump(to chapter: Chapter) {
        guard let book, book.tracks.indices.contains(chapter.trackIndex) else { return }
        Logger.player.info("[player] jump to chapter \(chapter.title, privacy: .public)")
        if chapter.trackIndex != trackIndex {
            loadTrack(index: chapter.trackIndex, startAt: chapter.start, autoplay: isPlaying)
        } else {
            seek(toTrackTime: chapter.start)
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
        if let item = player.currentItem, item.audioMix == nil, (settings.volumeBoost != 1 || settings.skipSilence || settings.boostQuietVoices) {
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

    private func cancelSleepTimer(notify shouldNotify: Bool) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEndsAt = nil
        sleepRemaining = nil
        sleepArmedChapterIndex = nil
        sleepTimer = .off
        if shouldNotify { notify() }
    }

    private func fadeOutAndPause(reason: String) {
        Logger.player.info("[player] sleep timer fired (\(reason, privacy: .public))")
        cancelSleepTimer(notify: false)
        guard isPlaying else { return }
        Task { [weak self] in
            for step in stride(from: 9, through: 0, by: -1) {
                guard let self, self.isPlaying else { return }
                self.player.volume = Float(step) / 10
                try? await Task.sleep(for: .milliseconds(250))
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
                loadTrack(index: trackIndex + 1, startAt: 0, autoplay: false)
                persistPosition()
            } else {
                loadTrack(index: trackIndex + 1, startAt: 0, autoplay: true)
            }
        } else {
            isPlaying = false
            currentTime = trackDuration
            didFinishCurrentBook = true
            library.markFinished(book.id)
            upNext = library.nextInSeries(after: book)
            if upNext != nil { Logger.player.info("[player] up next: \(self.upNext?.title ?? "-", privacy: .public)") }
            cancelSleepTimer(notify: false)
            AudioSessionManager.deactivate()
            Logger.player.info("[player] finished \(book.title, privacy: .public)")
            notify()
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
        if ticks % 30 == 0 { notify() }
        if sleepTimer == .endOfChapter, let armed = sleepArmedChapterIndex, let now = currentChapterIndex, now != armed {
            fadeOutAndPause(reason: "end of chapter")
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
        }
        notify()
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
                notify()
            }
        case .ended:
            Logger.player.info("[player] interruption ended shouldResume=\(options.contains(.shouldResume))")
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                startPlayback()
                notify()
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

    // MARK: - Persistence

    func persistPosition() {
        guard let book, !didFinishCurrentBook else { return }
        library.recordPosition(bookID: book.id, trackIndex: trackIndex, time: currentTime)
    }

    private func notify() {
        stateDidChange?()
    }
}
