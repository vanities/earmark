import AVFoundation
import os

enum AudioSessionManager {
    /// `.spokenAudio` pauses (rather than ducks) other apps and is what Podcasts/Books use.
    static func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            Logger.player.info("[session] configured playback/spokenAudio")
        } catch {
            Logger.player.error("[session] configure failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Logger.player.error("[session] activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Logger.player.debug("[session] deactivate: \(error.localizedDescription, privacy: .public)")
        }
    }
}
