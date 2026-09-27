import SwiftUI

struct ListeningPresetsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player
    var body: some View {
        @Bindable var settings = settings
        Form {
            ForEach($settings.listeningPresets) { $preset in
                Section(preset.name) {
                    Picker("Speed", selection: $preset.speed) {
                        ForEach(AppSettings.speedPresets, id: \.self) { Text(TransportControls.speedLabel($0)).tag($0) }
                    }
                    Toggle("Boost quiet voices", isOn: $preset.boostQuiet)
                    Toggle("Skip silence", isOn: $preset.skipSilence)
                    Picker("Volume boost", selection: $preset.volumeBoost) {
                        ForEach(AppSettings.boostChoices, id: \.self) { Text(TransportControls.speedLabel($0)).tag($0) }
                    }
                    Stepper(preset.sleepMinutes == 0 ? "Sleep timer off" : "Sleep in \(preset.sleepMinutes) minutes",
                            value: $preset.sleepMinutes, in: 0...180, step: 5)
                    Button("Apply \(preset.name)") { player.applyPreset(preset) }.disabled(player.book == nil)
                }
            }
            Text("Applying a preset updates the current book's speed and audio controls, and replaces its sleep timer. It doesn't start playback.")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Listening presets")
    }
}
