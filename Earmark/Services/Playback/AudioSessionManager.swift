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

    /// Only when a book ends — not on pause. Other apps aren't told to resume: pausing an audiobook
    /// (or the sleep timer pausing it) must not start the music it interrupted, and keeping the session
    /// while paused keeps Earmark the Now Playing app, so the car's play button resumes the book.
    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            Logger.player.info("[session] deactivated")
        } catch {
            Logger.player.debug("[session] deactivate: \(error.localizedDescription, privacy: .public)")
        }
    }
}
