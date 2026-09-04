import SwiftUI
import UIKit

/// Uses the numbered SF Symbols (goforward.30 etc.) when one exists for the interval.
struct SkipGlyph: View {
    let seconds: TimeInterval
    let forward: Bool

    var body: some View {
        let base = forward ? "goforward" : "gobackward"
        let numbered = "\(base).\(Int(seconds))"
        if UIImage(systemName: numbered) != nil {
            Image(systemName: numbered)
        } else {
            Image(systemName: base)
                .overlay {
                    Text("\(Int(seconds))")
                        .font(.system(size: 9, weight: .bold))
                        .offset(y: 1)
                }
        }
    }
}

struct TransportControls: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    let openSpeed: () -> Void
    let openSleep: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openSpeed) {
                Text(Self.speedLabel(player.speed))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Playback speed")
            .frame(maxWidth: .infinity)

            Button {
                player.skipBackward()
            } label: {
                SkipGlyph(seconds: settings.skipBackInterval, forward: false)
                    .font(.system(size: 34))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip back \(Int(settings.skipBackInterval)) seconds")
            .frame(maxWidth: .infinity)

            Button {
                player.togglePlayPause()
            } label: {
                Group {
                    if player.isLoading {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 36, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 60, height: 60)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .frame(maxWidth: .infinity)

            Button {
                player.skipForward()
            } label: {
                SkipGlyph(seconds: settings.skipForwardInterval, forward: true)
                    .font(.system(size: 34))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward \(Int(settings.skipForwardInterval)) seconds")
            .frame(maxWidth: .infinity)

            Button(action: openSleep) {
                VStack(spacing: 2) {
                    Image(systemName: player.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz")
                        .font(.body)
                    if let remaining = player.sleepRemaining {
                        Text(remaining.clockString)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                }
                .frame(minWidth: 44, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(player.sleepTimer.isActive ? .accentColor : .secondary)
            .accessibilityLabel("Sleep timer")
            .frame(maxWidth: .infinity)
        }
    }

    nonisolated static func speedLabel(_ speed: Float) -> String {
        String(format: "%g×", speed)
    }
}
