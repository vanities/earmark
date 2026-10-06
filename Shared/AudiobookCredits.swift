import Foundation

/// The same narrator credit is used by the app, system playback UI, and widgets.
enum AudiobookCredits {
    static func narratorLine(_ narrator: String?) -> String? {
        guard let name = narrator?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return "Narrated by \(name)"
    }

    static func summary(author: String, narrator: String?) -> String {
        [author, narratorLine(narrator)].compactMap { $0 }.joined(separator: " · ")
    }

    static func playbackDetail(author: String, narrator: String?, chapter: String?) -> String {
        // Put the narrator first in the mini player's single secondary line.
        [narratorLine(narrator), chapter ?? author].compactMap { $0 }.joined(separator: " · ")
    }
}
