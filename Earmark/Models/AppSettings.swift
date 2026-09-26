import Foundation
import Observation
import ShelfKit

enum HeadphoneTrackAction: String, CaseIterable, Codable, Sendable {
    /// Next/previous-track gestures (AirPods double/triple press) skip by the configured interval.
    case skip
    /// They jump to the next/previous chapter instead.
    case chapter

    var title: String {
        switch self {
        case .skip: "Skip 30s / 15s"
        case .chapter: "Next / previous chapter"
        }
    }
}

enum LockScreenTimeMode: String, CaseIterable, Codable, Sendable {
    case chapter, book

    var title: String {
        switch self {
        case .chapter: "Current chapter"
        case .book: "Whole book"
        }
    }
}

/// User preferences, backed by UserDefaults so they survive reinstalls via iCloud backup.
@MainActor @Observable
final class AppSettings {
    static let skipIntervalChoices: [TimeInterval] = [5, 10, 15, 20, 30, 45, 60, 90]
    static let speedPresets: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let speedRange: ClosedRange<Float> = 0.5...3.0
    static let boostChoices: [Float] = [1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    @ObservationIgnored private let defaults: UserDefaults

    var skipBackInterval: TimeInterval { didSet { defaults.set(skipBackInterval, forKey: Key.skipBack) } }
    var skipForwardInterval: TimeInterval { didSet { defaults.set(skipForwardInterval, forKey: Key.skipForward) } }
    var bedtimeBookmarks: Bool { didSet { defaults.set(bedtimeBookmarks, forKey: "playback.bedtimeBookmarks") } }
    var autoplayQueue: Bool { didSet { defaults.set(autoplayQueue, forKey: "playback.autoplayQueue") } }
    var queueKeys: [String] { didSet { defaults.set(queueKeys, forKey: "playback.queue") } }
    var defaultSpeed: Float { didSet { defaults.set(defaultSpeed, forKey: Key.defaultSpeed) } }
    var rememberSpeedPerBook: Bool { didSet { defaults.set(rememberSpeedPerBook, forKey: Key.rememberSpeed) } }
    /// Rewind a little on resume, scaled by how long playback was paused.
    var smartRewind: Bool { didSet { defaults.set(smartRewind, forKey: Key.smartRewind) } }
    var headphoneTrackAction: HeadphoneTrackAction { didSet { defaults.set(headphoneTrackAction.rawValue, forKey: Key.headphoneAction) } }
    var lockScreenTimeMode: LockScreenTimeMode { didSet { defaults.set(lockScreenTimeMode.rawValue, forKey: Key.lockScreenTime) } }
    var libraryGrouping: LibraryGrouping { didSet { defaults.set(libraryGrouping.rawValue, forKey: Key.grouping) } }
    var librarySort: LibrarySort { didSet { defaults.set(librarySort.rawValue, forKey: Key.sort) } }
    var libraryLayout: LibraryLayout { didSet { defaults.set(libraryLayout.rawValue, forKey: Key.layout) } }
    var showFinishedBooks: Bool { didSet { defaults.set(showFinishedBooks, forKey: Key.showFinished) } }
    /// Amplifies quiet narration. 1.0 = untouched; up to 3x with a limiter to avoid clipping.
    var volumeBoost: Float { didSet { defaults.set(volumeBoost, forKey: Key.volumeBoost) } }
    /// Speeds through silent gaps in real time (Smart Speed).
    var skipSilence: Bool { didSet { defaults.set(skipSilence, forKey: Key.skipSilence) } }
    /// Upward compression (Night Mode): lifts quiet narration, evens out loud spikes.
    var boostQuietVoices: Bool { didSet { defaults.set(boostQuietVoices, forKey: Key.boostQuiet) } }
    /// Color the Now Playing background from the book's cover. Default on.
    var ambientPlayerBackground: Bool { didSet { defaults.set(ambientPlayerBackground, forKey: Key.ambientBg) } }
    /// Opening the app (or coming back to it) in the middle of listening — the book playing, or
    /// played in the last couple of hours (`PlayerEngine.isRecentlyPlayed`) — shows Now Playing.
    /// Default on.
    var openToNowPlaying: Bool { didSet { defaults.set(openToNowPlaying, forKey: Key.openToNowPlaying) } }
    /// Books-per-year target shown on the Stats ring. 0 = no goal.
    var yearlyBookGoal: Int { didSet { defaults.set(yearlyBookGoal, forKey: Key.yearlyGoal) } }
    /// When Earmark asks for Face ID again (ShelfKit's AppLock reads it here). Default off.
    var lockMode: LockMode { didSet { defaults.set(lockMode.rawValue, forKey: Key.lockMode) } }
    /// A download listened to the end goes back to the NAS once another book starts. Default off.
    var removeFinishedDownloads: Bool { didSet { defaults.set(removeFinishedDownloads, forKey: Key.removeFinished) } }
    /// This device's slot in iCloud's listening totals — each device writes only its own, as in Mango.
    @ObservationIgnored let deviceID: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skipBackInterval = defaults.object(forKey: Key.skipBack) as? TimeInterval ?? 15
        skipForwardInterval = defaults.object(forKey: Key.skipForward) as? TimeInterval ?? 30
        bedtimeBookmarks = defaults.object(forKey: "playback.bedtimeBookmarks") as? Bool ?? true
        autoplayQueue = defaults.object(forKey: "playback.autoplayQueue") as? Bool ?? false
        queueKeys = defaults.stringArray(forKey: "playback.queue") ?? []
        defaultSpeed = defaults.object(forKey: Key.defaultSpeed) as? Float ?? 1.0
        rememberSpeedPerBook = defaults.object(forKey: Key.rememberSpeed) as? Bool ?? true
        smartRewind = defaults.object(forKey: Key.smartRewind) as? Bool ?? true
        headphoneTrackAction = HeadphoneTrackAction(rawValue: defaults.string(forKey: Key.headphoneAction) ?? "") ?? .skip
        lockScreenTimeMode = LockScreenTimeMode(rawValue: defaults.string(forKey: Key.lockScreenTime) ?? "") ?? .chapter
        libraryGrouping = LibraryGrouping(rawValue: defaults.string(forKey: Key.grouping) ?? "") ?? .author // Author → Series → Book by default
        librarySort = LibrarySort(rawValue: defaults.string(forKey: Key.sort) ?? "") ?? .recent
        libraryLayout = LibraryLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .grid
        showFinishedBooks = defaults.object(forKey: Key.showFinished) as? Bool ?? true
        volumeBoost = defaults.object(forKey: Key.volumeBoost) as? Float ?? 1.0
        skipSilence = defaults.object(forKey: Key.skipSilence) as? Bool ?? false
        boostQuietVoices = defaults.object(forKey: Key.boostQuiet) as? Bool ?? false
        ambientPlayerBackground = defaults.object(forKey: Key.ambientBg) as? Bool ?? true
        openToNowPlaying = defaults.object(forKey: Key.openToNowPlaying) as? Bool ?? true
        yearlyBookGoal = defaults.object(forKey: Key.yearlyGoal) as? Int ?? 12
        removeFinishedDownloads = defaults.object(forKey: Key.removeFinished) as? Bool ?? false
        lockMode = LockMode(rawValue: defaults.string(forKey: Key.lockMode) ?? "") ?? .off
        if let existing = defaults.string(forKey: Key.deviceID) {
            deviceID = existing
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Key.deviceID)
            deviceID = fresh
        }
    }

    private enum Key {
        static let skipBack = "playback.skipBack"
        static let skipForward = "playback.skipForward"
        static let defaultSpeed = "playback.defaultSpeed"
        static let rememberSpeed = "playback.rememberSpeedPerBook"
        static let smartRewind = "playback.smartRewind"
        static let headphoneAction = "controls.headphoneTrackAction"
        static let lockScreenTime = "controls.lockScreenTimeMode"
        static let grouping = "library.grouping"
        static let sort = "library.sort"
        static let layout = "library.layout"
        static let showFinished = "library.showFinished"
        static let volumeBoost = "playback.volumeBoost"
        static let skipSilence = "playback.skipSilence"
        static let boostQuiet = "playback.boostQuietVoices"
        static let ambientBg = "appearance.ambientPlayerBackground"
        static let openToNowPlaying = "appearance.openToNowPlaying"
        static let yearlyGoal = "stats.yearlyBookGoal"
        static let removeFinished = "downloads.removeFinished"
        static let lockMode = "privacy.lockMode"
        static let deviceID = "sync.deviceID"
    }
}

/// The lock (ShelfKit's `AppLock`) reads and saves its mode here, under `privacy.lockMode`.
extension AppSettings: LockSettings {}
