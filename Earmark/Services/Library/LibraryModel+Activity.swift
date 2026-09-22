import Foundation
import os
import ShelfKit

// MARK: - Listening activity

/// Time spent listening, as Mango counts time spent reading: this device's sessions in the library
/// file, day totals in the user's own iCloud (one slot per device), and ShelfKit's `ActivityStats`
/// for Stats' time, streak, calendar and habit cards.
extension LibraryModel {
    /// Two years of sessions is plenty for Stats, and the file is loaded on every launch.
    static let sessionRetention: TimeInterval = 730 * 86_400

    func recordSession(_ session: ListeningSession) {
        sessions.append(session)
        let cutoff = Date().addingTimeInterval(-Self.sessionRetention)
        sessions.removeAll { $0.startedAt < cutoff }
        Logger.library.info("[activity] session \(Int(session.activeSeconds))s of \(session.bookTitle, privacy: .public) sessions=\(self.sessions.count)")
        save()
        pushActivity()
    }

    /// Day totals from every device: this one's sessions plus the other devices' slots.
    var allDayActivity: [String: DayActivity] {
        DeviceActivity.combined(own: DayKey.rollUp(sessions), cloud: cloudSync.loadActivity(), deviceID: settings.deviceID)
    }

    var activityStats: ActivityStats {
        ActivityStats.build(days: allDayActivity, sessions: sessions)
    }

    /// This device's day totals into its own iCloud slot.
    func pushActivity() {
        let updated = DeviceActivity.updated(cloud: cloudSync.loadActivity(), own: DayKey.rollUp(sessions),
                                             deviceID: settings.deviceID, since: Date().addingTimeInterval(-Self.sessionRetention))
        cloudSync.saveActivity(updated)
    }

    /// A session a previous launch left open (the app was killed mid-book) is counted now.
    func recoverInterruptedListening() {
        guard let session = ListeningCheckpoint.take() else { return }
        Logger.library.info("[activity] recovered a session cut off by the last launch")
        recordSession(session)
    }
}
