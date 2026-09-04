import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryModel.self) private var library

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Skip") {
                    Picker("Skip Back", selection: $settings.skipBackInterval) {
                        ForEach(AppSettings.skipIntervalChoices, id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    Picker("Skip Forward", selection: $settings.skipForwardInterval) {
                        ForEach(AppSettings.skipIntervalChoices, id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Default Speed")
                        Spacer()
                        Text(TransportControls.speedLabel(settings.defaultSpeed))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.defaultSpeed) },
                            set: { settings.defaultSpeed = Float(($0 * 20).rounded() / 20) }
                        ),
                        in: Double(AppSettings.speedRange.lowerBound)...Double(AppSettings.speedRange.upperBound),
                        step: 0.05
                    )
                    Toggle("Remember Speed per Book", isOn: $settings.rememberSpeedPerBook)
                } header: {
                    Text("Speed")
                } footer: {
                    Text("New books start at the default speed. With per-book memory on, each book keeps the speed you last used for it.")
                }

                Section {
                    Toggle("Smart Rewind", isOn: $settings.smartRewind)
                } footer: {
                    Text("After a pause, back up a little so you catch the thread again: 3 seconds after a minute, up to 30 seconds after a couple of hours.")
                }

                Section("Controls") {
                    Picker("Headphone Next / Previous", selection: $settings.headphoneTrackAction) {
                        ForEach(HeadphoneTrackAction.allCases, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Picker("Lock Screen Shows", selection: $settings.lockScreenTimeMode) {
                        ForEach(LockScreenTimeMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section("Library") {
                    Toggle("Show Finished Books", isOn: $settings.showFinishedBooks)
                    Button("Rebuild Cover Art") {
                        ArtworkStore.shared.removeAll()
                        library.rescanAll(reason: "artwork rebuild")
                    }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("License", value: "GPL-3.0")
                    Link(destination: URL(string: "https://github.com/vanities/earmark")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Earmark is free and open source. There is no tip jar, and there never will be.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}
