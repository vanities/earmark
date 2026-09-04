import Foundation

extension TimeInterval {
    /// "1:02:03" or "2:03" — for scrubbers and chapter rows.
    var clockString: String {
        guard isFinite else { return "0:00" }
        let total = Int(Swift.max(0, self).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "9h 41m", "41m", "45s" — for lengths and time remaining.
    var shortDurationString: String {
        guard isFinite, self > 0 else { return "0m" }
        if self < 60 { return "\(Int(rounded()))s" }
        let totalMinutes = Int((self / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Wall-clock time this much audio takes at the given playback speed.
    func adjusted(forSpeed speed: Float) -> TimeInterval {
        speed > 0 ? self / Double(speed) : self
    }
}

extension Int64 {
    var byteCountString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
