import SwiftUI
import ShelfKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryModel.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppLock.self) private var lock
    @State private var confirmingRemoveAll = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Library tools") { NavigationLink("Library tools") { LibraryToolsView() } }
                Section("Presets") { NavigationLink("Listening presets") { ListeningPresetsView() } }
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
                    Toggle("Skip Silence", isOn: $settings.skipSilence)
                        .onChange(of: settings.skipSilence) { player.applyPlaybackEffects() }
                    Toggle("Boost Quiet Voices", isOn: $settings.boostQuietVoices)
                        .onChange(of: settings.boostQuietVoices) { player.applyPlaybackEffects() }
                    Picker("Volume Boost", selection: $settings.volumeBoost) {
                        ForEach(AppSettings.boostChoices, id: \.self) { boost in
                            Text(boost == 1 ? "Off" : TransportControls.speedLabel(boost)).tag(boost)
                        }
                    }
                    .onChange(of: settings.volumeBoost) { player.applyPlaybackEffects() }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Skip Silence races through quiet gaps so a book finishes sooner. Boost Quiet Voices evens out loud and soft passages so you can hear it in the car without blasting the loud parts. Volume Boost lifts the whole track. All work on downloaded and streamed books.")
                }

                Section {
                    Toggle("Ambient Cover Background", isOn: $settings.ambientPlayerBackground)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Colors the Now Playing screen from the current book's cover. Turn off for a plain background.")
                }

                Section {
                    Toggle("Open to Now Playing", isOn: $settings.openToNowPlaying)
                } footer: {
                    Text("When you've been listening in the last couple of hours, opening Earmark goes straight to Now Playing with your book ready to play. Turn off to open where you left off.")
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

                downloads

                privacy

                Section {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("License", value: "GPL-3.0")
                    Link(destination: URL(string: "https://am2.biz/earmark/support")!) {
                        Label("Help & Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://am2.biz/earmark/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
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
            .confirmationDialog("Remove all downloads?", isPresented: $confirmingRemoveAll, titleVisibility: .visible) {
                let onDevice = library.downloadsOnDevice
                Button("Remove \(onDevice.count) Download\(onDevice.count == 1 ? "" : "s") (\(Self.bytes(onDevice)))", role: .destructive) {
                    player.removeDownloads(onDevice, in: library)
                }
            } message: {
                Text("They'll play from your NAS again, with your place and bookmarks. A book that's playing keeps its download.")
            }
        }
    }

    /// Space the NAS already has a copy of: see it, and give it back.
    private var downloads: some View {
        @Bindable var settings = settings
        let onDevice = library.downloadsOnDevice
        let finished = library.finishedDownloads
        return Section {
            LabeledContent("On this \(DeviceStorage.device)", value: onDevice.isEmpty ? "None"
                           : "\(onDevice.count) book\(onDevice.count == 1 ? "" : "s") · \(Self.bytes(onDevice))")
            Toggle("Remove When Finished", isOn: $settings.removeFinishedDownloads)
            Button(finished.isEmpty ? "Remove Finished Downloads"
                   : "Remove Finished Downloads (\(finished.count) · \(Self.bytes(finished)))") {
                player.removeDownloads(finished, in: library)
            }
            .disabled(finished.isEmpty)
            Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                .disabled(onDevice.isEmpty)
        } header: {
            Text("Downloads")
        } footer: {
            Text("A removed download plays from your NAS again, with your place and bookmarks. Only books still on a NAS count here — nothing that exists only on this \(DeviceStorage.device) is removed. With Remove When Finished on, a book you finish goes once you start another.")
        }
    }

    private var privacy: some View {
        Section {
            Picker("Lock with Face ID", selection: Binding(
                get: { settings.lockMode },
                set: { mode in
                    Task {
                        // Asks first; the picker snaps back if Face ID says no.
                        if await lock.setMode(mode) { AppEnvironment.shared.nowPlaying.update() }
                    }
                }
            )) {
                ForEach(LockMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(!AppLock.canLock)
            // Beside the lock, as in Mango.
            NavigationLink {
                HiddenBooksView()
            } label: {
                LabeledContent("Hidden", value: "\(library.hiddenBooks.count)")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(AppLock.canLock
                 ? "With the lock on, Earmark asks for Face ID when it opens, covers itself in the app switcher, hides Hidden Books behind Face ID, and the widget stops showing what you're listening to. Playback controls on the Lock Screen and in CarPlay keep working."
                 : "Set a passcode for this \(DeviceStorage.device) to use the lock.")
        }
    }

    private static func bytes(_ books: [Book]) -> String {
        books.reduce(Int64(0)) { $0 + $1.totalBytes }.byteCountString
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}
